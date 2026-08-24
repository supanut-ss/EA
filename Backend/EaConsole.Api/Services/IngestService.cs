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
        await UpsertDailySnapshotAsync(
            request.AccountId, request.CapturedAtBroker, request.Balance, request.Equity,
            request.Margin, request.FreeMargin, request.MarginLevelPct, request.SpreadPoints,
            EnumDbMaps.ConnectionStateFromDb(request.ConnectionState), ct);
    }

    // Real incident (2026-08-21): account_snapshots inserted a brand new row
    // on every heartbeat (every ~10-30s, x3 EAs) and grew to 58k+ rows within
    // days - nothing on the dashboard reads finer than "latest snapshot per
    // day" (see SnapshotRetentionService's comment: the equity curve and the
    // Balance/Equity card both only ever use the latest row), so all that
    // insert volume was pure overhead that slowed the dashboard down for no
    // benefit. Upsert the same (account, broker day) row instead - keeps
    // "latest value wins" semantics identical to before, just without
    // re-inserting. SnapshotRetentionService still runs to thin the rows
    // already accumulated the old way and to prune ancient daily rows.
    public async Task UpsertDailySnapshotAsync(
        int accountId, DateTime capturedAtBroker, decimal balance, decimal equity,
        decimal margin, decimal freeMargin, decimal? marginLevelPct, int? spreadPoints,
        ConnectionState connectionState, CancellationToken ct = default)
    {
        var dayStart = capturedAtBroker.Date;
        var dayEnd = dayStart.AddDays(1);

        var snapshot = await db.AccountSnapshots.FirstOrDefaultAsync(
            s => s.AccountId == accountId && s.CapturedAtBroker >= dayStart && s.CapturedAtBroker < dayEnd, ct);

        if (snapshot is null)
        {
            snapshot = new AccountSnapshot { AccountId = accountId, CreatedAt = DateTime.UtcNow };
            db.AccountSnapshots.Add(snapshot);
        }

        snapshot.CapturedAtBroker = capturedAtBroker;
        snapshot.Balance = balance;
        snapshot.Equity = equity;
        snapshot.Margin = margin;
        snapshot.FreeMargin = freeMargin;
        snapshot.MarginLevelPct = marginLevelPct;
        snapshot.SpreadPoints = spreadPoints;
        snapshot.ConnectionState = connectionState;

        await db.SaveChangesAsync(ct);
    }

    // Upsert ด้วย (AccountId, Mt5Ticket) — EA ยิง ticket เดิมซ้ำได้ทุกครั้งที่
    // สถานะไม้เปลี่ยน (ราคาปัจจุบันขยับ, ปิดไม้ ฯลฯ) โดยไม่ต้องรู้ trade_id
    // ภายในของเรา
    public async Task IngestTradeAsync(TradeIngestRequest request, CancellationToken ct = default)
    {
        var trade = await db.Trades.FirstOrDefaultAsync(
            t => t.AccountId == request.AccountId && t.Mt5Ticket == request.Mt5Ticket, ct);

        // Dashboard contract: retain only trades whose lifecycle is managed
        // entirely by an EA. A manual close is authoritative proof that this
        // trade does not belong in EA performance/history. Remove an existing
        // OPEN row instead of converting it to CLOSED, and ignore a standalone
        // manual-close report that has no row to remove.
        if (string.Equals(request.Status, "CLOSED", StringComparison.OrdinalIgnoreCase)
            && string.Equals(request.CloseReason, "MANUAL", StringComparison.OrdinalIgnoreCase))
        {
            if (trade is not null)
            {
                db.Trades.Remove(trade);
                await db.SaveChangesAsync(ct);
            }
            return;
        }

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
        trade.CloseReason = request.CloseReason;
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
