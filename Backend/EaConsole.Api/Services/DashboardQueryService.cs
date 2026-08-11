using EaConsole.Api.Data;
using EaConsole.Api.Data.Entities;
using EaConsole.Api.Dtos;
using Microsoft.EntityFrameworkCore;

namespace EaConsole.Api.Services;

// ประกอบ DashboardSnapshotDto จาก DB — 1 method ต่อ 1 คำขอจาก
// DashboardController เทียบเท่ากับ query แต่ละก้อนใน
// Backend/Database/dashboard_queries.sql (ไฟล์นั้นไว้อ่านอ้างอิง/รันมือ
// เวลาอยากเช็คตรงๆ ส่วนตัวนี้คือ production path จริงที่ frontend ใช้)
public class DashboardQueryService(EaConsoleDbContext db) : IDashboardQueryService
{
    private static readonly TimeSpan HistoryWindow = TimeSpan.FromDays(30);

    public async Task<DashboardSnapshotDto?> GetSnapshotAsync(int accountId, CancellationToken ct = default)
    {
        var account = await db.Accounts.AsNoTracking().FirstOrDefaultAsync(a => a.AccountId == accountId, ct);
        if (account is null) return null;

        var latestSnapshot = await db.AccountSnapshots.AsNoTracking()
            .Where(s => s.AccountId == accountId)
            .OrderByDescending(s => s.CapturedAtBroker)
            .FirstOrDefaultAsync(ct);
        if (latestSnapshot is null) return null;

        // "วันนี้" ตาม broker time ไม่ใช่เวลาเครื่อง server — คำนวณจาก
        // broker_gmt_offset_minutes ที่ตั้งไว้ต่อบัญชี
        var brokerNow = DateTime.UtcNow.AddMinutes(account.BrokerGmtOffsetMinutes);
        var brokerTodayStart = brokerNow.Date;
        var brokerTodayEnd = brokerTodayStart.AddDays(1);
        var historyStart = brokerTodayStart - HistoryWindow;

        var accountSummary = await BuildAccountSummaryAsync(accountId, latestSnapshot, brokerTodayStart, brokerTodayEnd, ct);
        var equityCurve = await BuildEquityCurveAsync(accountId, DateOnly.FromDateTime(historyStart), ct);
        var openPositions = await BuildOpenPositionsAsync(accountId, ct);
        var closedTrades = await BuildClosedTradesAsync(accountId, historyStart, ct);
        var eaStatuses = await BuildEaStatusesAsync(accountId, brokerTodayStart, brokerTodayEnd, ct);
        var risk = await BuildRiskSnapshotAsync(accountId, latestSnapshot, brokerTodayStart, brokerTodayEnd, historyStart, ct);
        var activityLog = await BuildActivityLogAsync(accountId, ct);

        var offsetLabel = FormatGmtOffset(account.BrokerGmtOffsetMinutes);

        return new DashboardSnapshotDto(
            Connection: latestSnapshot.ConnectionState.ToDb(),
            LastSyncedAt: latestSnapshot.CreatedAt,
            BrokerTime: $"{brokerNow:HH:mm:ss} {offsetLabel}",
            Account: accountSummary,
            EquityCurve: equityCurve,
            OpenPositions: openPositions,
            ClosedTrades: closedTrades,
            EaStatuses: eaStatuses,
            Risk: risk,
            ActivityLog: activityLog
        );
    }

    private async Task<AccountSummaryDto> BuildAccountSummaryAsync(
        int accountId, AccountSnapshot latest, DateTime dayStart, DateTime dayEnd, CancellationToken ct)
    {
        // เดิมแยก 4 query (count/sum/count/max) — พอต่อ DB จริงที่ round trip
        // ละ 300ms-1s+ (เจอจริงตอนทดสอบกับ DB บน 94.237.76.153) การรวมเป็น
        // 1 query ด้วย correlated subquery ลดเวลาได้ตรงๆ ตามจำนวน round trip
        // ที่หายไป — ดีกว่าปล่อยให้อ่านง่ายแบบ LINQ แยกก้อนเวลา latency สูงขนาดนี้
        var summary = await db.Database.SqlQuery<SummaryRow>($@"
            SELECT
              (SELECT IFNULL(SUM(pnl), 0) FROM trades
                 WHERE account_id = {accountId} AND status = 'CLOSED'
                   AND close_time_broker >= {dayStart} AND close_time_broker < {dayEnd}) AS TodayRealizedPnl,
              (SELECT COUNT(*) FROM trades
                 WHERE account_id = {accountId} AND status = 'CLOSED'
                   AND close_time_broker >= {dayStart} AND close_time_broker < {dayEnd}) AS TodayClosedCount,
              (SELECT COUNT(*) FROM trades
                 WHERE account_id = {accountId}
                   AND open_time_broker >= {dayStart} AND open_time_broker < {dayEnd}) AS TradesToday,
              (SELECT IFNULL(MAX(max_trades_per_day), 0) FROM eas
                 WHERE account_id = {accountId} AND status <> 'not_deployed') AS MaxTradesPerDay")
            .SingleAsync(ct);

        return new AccountSummaryDto(
            Balance: latest.Balance,
            Equity: latest.Equity,
            FloatingPnl: latest.Equity - latest.Balance,
            TodayRealizedPnl: summary.TodayRealizedPnl,
            TodayClosedCount: summary.TodayClosedCount,
            MarginLevelPct: latest.MarginLevelPct ?? 0,
            FreeMargin: latest.FreeMargin,
            TradesToday: summary.TradesToday,
            MaxTradesPerDay: summary.MaxTradesPerDay
        );
    }

    private record SummaryRow(
        decimal TodayRealizedPnl,
        int TodayClosedCount,
        int TradesToday,
        int MaxTradesPerDay);

    private async Task<List<EquityPointDto>> BuildEquityCurveAsync(int accountId, DateOnly since, CancellationToken ct)
    {
        var rows = await db.EquityCurveRows.AsNoTracking()
            .Where(r => r.AccountId == accountId && r.SnapDate >= since)
            .OrderBy(r => r.SnapDate)
            .ToListAsync(ct);

        return rows
            .Select(r => new EquityPointDto(r.SnapDate.ToString("MM/dd"), r.Equity, r.Balance))
            .ToList();
    }

    private async Task<List<PositionDto>> BuildOpenPositionsAsync(int accountId, CancellationToken ct)
    {
        var trades = await db.Trades.AsNoTracking()
            .Include(t => t.Ea)
            .Where(t => t.AccountId == accountId && t.Status == TradeStatus.Open)
            .OrderByDescending(t => t.OpenTimeBroker)
            .ToListAsync(ct);

        return trades.Select(t => new PositionDto(
            Id: t.TradeId.ToString(),
            EaId: t.EaId.ToString(),
            EaName: t.Ea!.Name,
            Symbol: t.Symbol,
            Side: t.Side.ToDb(),
            Lot: t.Lot,
            OpenPrice: t.OpenPrice,
            CurrentPrice: t.CurrentPrice,
            StopLoss: t.StopLoss,
            TakeProfit: t.TakeProfit,
            Pnl: t.UnrealizedPnl,
            OpenedAtBroker: t.OpenTimeBroker.ToString("HH:mm")
        )).ToList();
    }

    private async Task<List<ClosedTradeDto>> BuildClosedTradesAsync(int accountId, DateTime since, CancellationToken ct)
    {
        var trades = await db.Trades.AsNoTracking()
            .Include(t => t.Ea)
            .Where(t => t.AccountId == accountId && t.Status == TradeStatus.Closed
                     && t.CloseTimeBroker != null && t.CloseTimeBroker >= since)
            .OrderByDescending(t => t.CloseTimeBroker)
            .Take(200)
            .ToListAsync(ct);

        return trades.Select(t => new ClosedTradeDto(
            Id: t.TradeId.ToString(),
            EaId: t.EaId.ToString(),
            EaName: t.Ea!.Name,
            Symbol: t.Symbol,
            Side: t.Side.ToDb(),
            Lot: t.Lot,
            OpenPrice: t.OpenPrice,
            ClosePrice: t.ClosePrice,
            Pnl: t.Pnl,
            ClosedAtBroker: t.CloseTimeBroker!.Value.ToString("HH:mm"),
            CloseReason: t.CloseReason?.ToDisplayText()
        )).ToList();
    }

    private async Task<List<EaStatusDto>> BuildEaStatusesAsync(
        int accountId, DateTime dayStart, DateTime dayEnd, CancellationToken ct)
    {
        var eas = await db.Eas.AsNoTracking()
            .Where(e => e.AccountId == accountId)
            .OrderBy(e => e.EaId)
            .ToListAsync(ct);

        // เดิม loop query 2 ครั้งต่อ 1 EA (N+1) — พอเชื่อมกับ DB จริงที่หน่วง
        // 300ms-1s ต่อ round trip ต่อครั้ง มี EA ไม่กี่ตัวก็ทำให้ endpoint
        // ช้าลงเห็นได้ชัด เลยรวบเหลือ 2 query สำหรับทุก EA แล้วจับคู่ในหน่วยความจำแทน
        var tradesTodayByEa = await db.Trades.AsNoTracking()
            .Where(t => t.OpenTimeBroker >= dayStart && t.OpenTimeBroker < dayEnd
                     && eas.Select(e => e.EaId).Contains(t.EaId))
            .GroupBy(t => t.EaId)
            .Select(g => new { EaId = g.Key, Count = g.Count() })
            .ToDictionaryAsync(x => x.EaId, x => x.Count, ct);

        var recentLogs = await db.ActivityLog.AsNoTracking()
            .Where(l => l.AccountId == accountId
                     && (l.Level == ActivityLevel.Ok || l.Level == ActivityLevel.Info)
                     && l.EaId != null)
            .OrderByDescending(l => l.EventTimeBroker)
            .Take(200)
            .Select(l => new { l.EaId, l.Message, l.EventTimeBroker })
            .ToListAsync(ct);
        var lastSignalByEa = recentLogs
            .GroupBy(l => l.EaId!.Value)
            .ToDictionary(g => g.Key, g => g.First()); // แถวแรกในแต่ละกลุ่ม = ล่าสุด เพราะ query เรียง desc มาแล้ว

        var result = new List<EaStatusDto>();
        foreach (var ea in eas)
        {
            var tradesToday = tradesTodayByEa.GetValueOrDefault(ea.EaId, 0);
            var hasLastSignal = lastSignalByEa.TryGetValue(ea.EaId, out var lastSignal);

            var sessionWindow = ea.SessionStartHour is null || ea.SessionEndHour is null
                ? "-"
                : $"{ea.SessionStartHour:00}:00–{ea.SessionEndHour:00}:00 (Broker)";

            result.Add(new EaStatusDto(
                Id: ea.EaId.ToString(),
                Name: ea.Name,
                Symbol: ea.Symbol,
                Timeframe: ea.Timeframe,
                State: ea.Status.ToDb(),
                SessionWindow: sessionWindow,
                LastSignal: hasLastSignal ? $"{lastSignal!.Message} · {lastSignal.EventTimeBroker:HH:mm}" : "-",
                TradesToday: tradesToday,
                MaxTradesPerDay: ea.MaxTradesPerDay ?? 0,
                Note: ea.Notes
            ));
        }
        return result;
    }

    private async Task<RiskSnapshotDto> BuildRiskSnapshotAsync(
        int accountId, AccountSnapshot latest, DateTime dayStart, DateTime dayEnd, DateTime historyStart, CancellationToken ct)
    {
        // Max drawdown วันนี้ ใช้ running-peak เทียบ equity แต่ละจุด (ไม่ใช่
        // แค่ max/min ทั้งวัน) — คำนวณด้วย window function ตรงๆ ใน SQL
        // เพราะ LINQ-to-Entities ไม่รองรับ running window aggregate แบบนี้
        //
        // หมายเหตุบั๊กที่เจอจริง (ทดสอบกับ DB จริง): Database.SqlQuery<T>()
        // ของ EF Core 8 ตอน compose ต่อด้วย LINQ (แม้แค่ FirstOrDefaultAsync)
        // จะห่อ SQL เดิมเป็น subquery แล้วอ้างอิงคอลัมน์ผลลัพธ์ด้วยชื่อตายตัว
        // "Value" เช่น SELECT t.Value FROM (...) AS t — ถ้า SQL ต้นฉบับไม่ได้
        // alias คอลัมน์ว่า Value จะเจอ "Unknown column 't.Value'" ทันที (ใช้ได้
        // เฉพาะตอน T เป็น scalar เดี่ยวๆ — พอเป็น record หลายคอลัมน์แบบ RiskRow
        // ด้านล่าง EF แมปด้วยชื่อ property ตรงๆ ไม่ต้องมี Value)
        //
        // รวม 4 query เดิม (max drawdown, SL รวม, TP รวม, avg R:R) เหลือ
        // round trip เดียว ด้วยเหตุผลเดียวกับ BuildAccountSummaryAsync — DB
        // จริงที่ทดสอบด้วยหน่วง 300ms-1s+ ต่อ round trip
        var risk = await db.Database.SqlQuery<RiskRow>($@"
            SELECT
              (SELECT IFNULL(MIN(dd_pct), 0) FROM (
                  SELECT
                    ROUND(
                      (equity - MAX(equity) OVER (ORDER BY captured_at_broker))
                      / MAX(equity) OVER (ORDER BY captured_at_broker) * 100
                    , 2) AS dd_pct
                  FROM account_snapshots
                  WHERE account_id = {accountId}
                    AND captured_at_broker >= {dayStart} AND captured_at_broker < {dayEnd}
                ) dd) AS MaxDrawdownTodayPct,
              (SELECT IFNULL(SUM(sl_amount), 0) FROM trades
                 WHERE account_id = {accountId} AND status = 'OPEN') AS OpenSlTotal,
              (SELECT IFNULL(SUM(tp_amount), 0) FROM trades
                 WHERE account_id = {accountId} AND status = 'OPEN') AS OpenTpTotal,
              (SELECT IFNULL(AVG(ABS(take_profit - open_price) / ABS(open_price - stop_loss)), 0)
                 FROM trades
                 WHERE account_id = {accountId} AND status = 'CLOSED'
                   AND stop_loss IS NOT NULL AND take_profit IS NOT NULL
                   AND open_price <> stop_loss
                   AND close_time_broker IS NOT NULL AND close_time_broker >= {historyStart}) AS AvgRiskRewardRatio,
              (SELECT COUNT(*) FROM trades
                 WHERE account_id = {accountId} AND status = 'CLOSED'
                   AND stop_loss IS NOT NULL AND take_profit IS NOT NULL
                   AND open_price <> stop_loss
                   AND close_time_broker IS NOT NULL AND close_time_broker >= {historyStart}) AS RrTradeCount")
            .SingleAsync(ct);

        var avgRiskReward = risk.RrTradeCount > 0 ? $"1 : {risk.AvgRiskRewardRatio:0.0#}" : "-";

        return new RiskSnapshotDto(
            MaxDrawdownTodayPct: risk.MaxDrawdownTodayPct,
            OpenSlTotal: risk.OpenSlTotal,
            OpenTpTotal: risk.OpenTpTotal,
            AvgRiskReward: avgRiskReward,
            CurrentSpreadPts: latest.SpreadPoints ?? 0
        );
    }

    private record RiskRow(
        decimal MaxDrawdownTodayPct,
        decimal OpenSlTotal,
        decimal OpenTpTotal,
        decimal AvgRiskRewardRatio,
        int RrTradeCount);

    private async Task<List<ActivityLogEntryDto>> BuildActivityLogAsync(int accountId, CancellationToken ct)
    {
        var logs = await db.ActivityLog.AsNoTracking()
            .Include(l => l.Ea)
            .Where(l => l.AccountId == accountId)
            .OrderByDescending(l => l.EventTimeBroker)
            .Take(20)
            .ToListAsync(ct);

        return logs.Select(l => new ActivityLogEntryDto(
            Id: l.LogId.ToString(),
            TimeBroker: l.EventTimeBroker.ToString("HH:mm"),
            EaName: l.Ea?.Name ?? "System",
            Message: l.Message,
            Level: l.Level.ToDb()
        )).ToList();
    }

    private static string FormatGmtOffset(short offsetMinutes)
    {
        var hours = offsetMinutes / 60.0;
        var sign = hours >= 0 ? "+" : "";
        return $"GMT{sign}{hours:0.##}";
    }
}
