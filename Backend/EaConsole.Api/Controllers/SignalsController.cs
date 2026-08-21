using EaConsole.Api.Data;
using EaConsole.Api.Data.Entities;
using EaConsole.Api.Dtos;
using EaConsole.Api.Services;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace EaConsole.Api.Controllers;

// Endpoint ฝั่ง "เขียน" ที่ XAUUSD_COUNTER_TREND.mq5 (EA3, "ATS" protocol) ยิงเข้ามา
// — โปรโตคอลคนละแบบกับ IngestController (snake_case, ticket เป็น string, ไม่มี
// accountId/eaId ในตัว payload เลย) เพราะ EA3 hardcode path/shape พวกนี้ไว้แล้ว
// จากโปรเจกต์ ATS เดิม เราแค่ทำ backend ฝั่งนี้ให้เข้ากันได้ ไม่ได้แก้ EA
//
// - accountId คงที่ (EA3's payload ไม่มี accountId ให้เลือกเอง ต่างจาก
//   IngestController ที่ EA1/EA2 ส่ง accountId มาเอง) — ผูกกับ account_id=2
//   (Exness-MT5Real8 login 411757774, บัญชี Live แยกจาก EA1/EA2)
// - eaId คงที่ที่ EA3_ID (ต้องมีแถวใน eas table รอไว้แล้ว ea_id=3, magic=88188)
// - ไม่มี authentication แบบเดียวกับ IngestController — ใช้ Ingest:ApiKey gate
//   เดียวกันที่ Program.cs (ขยาย path ให้ครอบคลุม /api/signals ด้วยแล้ว)
[ApiController]
[Route("api/signals")]
public class SignalsController(EaConsoleDbContext db, IIngestService ingestService) : ControllerBase
{
    // 2026-08-14: moved to its own real Live account (Exness-MT5Real8,
    // login 411757774, account_id=2) - was account_id=1 (shared with
    // EA1/EA2's Exness demo) before this account existed.
    private const int AccountId = 2;
    private const int Ea3Id = 3;

    // EA3 polls this every InpPollInterval ms (default 10s) with account state.
    // We have no remote signal dispatcher, so this doubles as EA3's heartbeat:
    // log an AccountSnapshot and always answer "no signals pending" - the EA
    // treats "" or "[]" identically and just keeps running its own strategy.
    [HttpPost("pending")]
    public async Task<IActionResult> Pending([FromBody] SignalPendingRequest request, CancellationToken ct)
    {
        // Upsert one row per (account, broker day) instead of inserting a
        // fresh row every poll - see IIngestService.UpsertDailySnapshotAsync's
        // comment (2026-08-21 account_snapshots growth incident, same fix
        // applied here since this endpoint doubles as EA3's heartbeat too).
        await ingestService.UpsertDailySnapshotAsync(
            AccountId, DateTime.UtcNow, request.Balance, request.Equity,
            request.Equity - request.FreeMargin, request.FreeMargin,
            marginLevelPct: null,
            spreadPoints: null, // EA3 reports bid/ask as price, not points - not comparable to EA1/EA2's spread
            ConnectionState.Connected, ct);

        return Content("[]", "application/json");
    }

    // EA3 reporting a trade it opened/closed on its own (not from a webhook
    // signal). Upsert by (AccountId, ticket) same convention as IngestController,
    // but unlike that endpoint we must NOT blindly overwrite OpenTimeBroker on
    // the close call - EA3 doesn't resend it, so we preserve whatever the OPEN
    // call recorded instead of stamping the close time over it.
    [HttpPost("local")]
    public async Task<IActionResult> Local([FromBody] SignalLocalTradeRequest request, CancellationToken ct)
    {
        if (!long.TryParse(request.Ticket, out var ticket))
            return BadRequest("ticket must be numeric");

        var trade = await db.Trades.FirstOrDefaultAsync(
            t => t.AccountId == AccountId && t.Mt5Ticket == ticket, ct);

        bool isOpen = string.Equals(request.Status, "OPEN", StringComparison.OrdinalIgnoreCase);
        var now = DateTime.UtcNow;

        if (trade is null)
        {
            trade = new Trade
            {
                AccountId = AccountId,
                EaId = Ea3Id,
                Mt5Ticket = ticket,
                OpenTimeBroker = now, // EA3 does not send a broker open time; receipt time is the best we have
                CreatedAt = now,
            };
            db.Trades.Add(trade);
        }

        trade.Symbol = request.Symbol;
        trade.Side = EnumDbMaps.TradeSideFromDb(request.Action);
        trade.Lot = request.Volume;
        trade.OpenPrice = request.EntryPrice;
        trade.StopLoss = request.Sl;
        trade.TakeProfit = request.Tp;
        trade.UpdatedAt = now;

        if (isOpen)
        {
            trade.Status = TradeStatus.Open;
            trade.CurrentPrice = request.EntryPrice;
        }
        else
        {
            // "WIN" | "LOSS" - close_reason (2026-08-14+) carries the actual
            // exit rule (TP/SL/Manual from MT5's own DEAL_REASON, or EA3's
            // own tracked reason for EA-initiated closes).
            trade.Status = TradeStatus.Closed;
            trade.ClosePrice = request.ExitPrice;
            trade.Pnl = request.Profit;
            trade.CurrentPrice = null;
            trade.CloseTimeBroker = now;
            trade.CloseReason = request.CloseReason;
        }

        await db.SaveChangesAsync(ct);
        return Ok();
    }

    // Lifecycle status for a webhook-SOURCED signal (keyed by signal id, not an
    // MT5 ticket). Unreachable while /pending always returns no signals -
    // accepted and logged rather than left to 404 if that ever changes.
    [HttpPost("update")]
    public async Task<IActionResult> Update([FromBody] SignalUpdateRequest request, CancellationToken ct)
    {
        db.ActivityLog.Add(new ActivityLogEntry
        {
            AccountId = AccountId,
            EaId = Ea3Id,
            Level = ActivityLevel.Info,
            Message = $"Webhook signal {request.Id} status={request.Status} ticket={request.Ticket} profit={request.Profit}",
            EventTimeBroker = DateTime.UtcNow,
            CreatedAt = DateTime.UtcNow,
        });
        await db.SaveChangesAsync(ct);
        return Ok();
    }
}
