using EaConsole.Api.Data;
using EaConsole.Api.Data.Entities;
using EaConsole.Api.Dtos;
using Microsoft.EntityFrameworkCore;

namespace EaConsole.Api.Services;

// รับข้อมูลที่ EA (ผ่านตัวกลางที่คุย WebRequest กับ endpoint พวกนี้) ยิงเข้ามา
// แล้ว insert/update ลง DB — เป็นฝั่ง "เขียน" คู่กับ DashboardQueryService
// ที่เป็นฝั่ง "อ่าน"
public class IngestService(EaConsoleDbContext db) : IIngestService
{
    public async Task IngestSnapshotAsync(SnapshotIngestRequest request, CancellationToken ct = default)
    {
        var snapshot = new AccountSnapshot
        {
            AccountId = request.AccountId,
            CapturedAtBroker = request.CapturedAtBroker,
            Balance = request.Balance,
            Equity = request.Equity,
            Margin = request.Margin,
            FreeMargin = request.FreeMargin,
            MarginLevelPct = request.MarginLevelPct,
            SpreadPoints = request.SpreadPoints,
            ConnectionState = EnumDbMaps.ConnectionStateFromDb(request.ConnectionState),
            CreatedAt = DateTime.UtcNow,
        };
        db.AccountSnapshots.Add(snapshot);
        await db.SaveChangesAsync(ct);
    }

    // Upsert ด้วย (AccountId, Mt5Ticket) — EA ยิง ticket เดิมซ้ำได้ทุกครั้งที่
    // สถานะไม้เปลี่ยน (ราคาปัจจุบันขยับ, ปิดไม้ ฯลฯ) โดยไม่ต้องรู้ trade_id
    // ภายในของเรา
    public async Task IngestTradeAsync(TradeIngestRequest request, CancellationToken ct = default)
    {
        var trade = await db.Trades.FirstOrDefaultAsync(
            t => t.AccountId == request.AccountId && t.Mt5Ticket == request.Mt5Ticket, ct);

        if (trade is null)
        {
            trade = new Trade
            {
                AccountId = request.AccountId,
                EaId = request.EaId,
                Mt5Ticket = request.Mt5Ticket,
                CreatedAt = DateTime.UtcNow,
            };
            db.Trades.Add(trade);
        }

        trade.Symbol = request.Symbol;
        trade.Side = EnumDbMaps.TradeSideFromDb(request.Side);
        trade.Lot = request.Lot;
        trade.OpenPrice = request.OpenPrice;
        trade.ClosePrice = request.ClosePrice;
        trade.StopLoss = request.StopLoss;
        trade.TakeProfit = request.TakeProfit;
        trade.CurrentPrice = request.CurrentPrice;
        trade.UnrealizedPnl = request.UnrealizedPnl;
        trade.SlAmount = request.SlAmount;
        trade.TpAmount = request.TpAmount;
        trade.OpenTimeBroker = request.OpenTimeBroker;
        trade.CloseTimeBroker = request.CloseTimeBroker;
        trade.Status = EnumDbMaps.TradeStatusFromDb(request.Status);
        trade.Pnl = request.Pnl;
        trade.Swap = request.Swap;
        trade.Commission = request.Commission;
        trade.CloseReason = request.CloseReason is null
            ? null
            : EnumDbMaps.TradeCloseReasonFromDb(request.CloseReason);
        trade.UpdatedAt = DateTime.UtcNow;

        await db.SaveChangesAsync(ct);
    }

    public async Task IngestActivityLogAsync(ActivityLogIngestRequest request, CancellationToken ct = default)
    {
        db.ActivityLog.Add(new ActivityLogEntry
        {
            AccountId = request.AccountId,
            EaId = request.EaId,
            Level = EnumDbMaps.ActivityLevelFromDb(request.Level),
            Message = request.Message,
            EventTimeBroker = request.EventTimeBroker,
            CreatedAt = DateTime.UtcNow,
        });
        await db.SaveChangesAsync(ct);
    }

    public async Task<bool> UpdateEaStatusAsync(int eaId, string state, CancellationToken ct = default)
    {
        var ea = await db.Eas.FirstOrDefaultAsync(e => e.EaId == eaId, ct);
        if (ea is null) return false;

        ea.Status = EnumDbMaps.EaRuntimeStateFromDb(state);
        ea.UpdatedAt = DateTime.UtcNow;
        if (ea.Status != EaRuntimeState.NotDeployed && ea.DeployedAt is null)
            ea.DeployedAt = DateTime.UtcNow;

        await db.SaveChangesAsync(ct);
        return true;
    }
}
