namespace EaConsole.Api.Dtos;

// โครงสร้าง DTO พวกนี้ต้องตรงกับ Frontend/src/types/dashboard.ts แบบ
// field-ต่อ-field (System.Text.Json ใช้ camelCase โดย default อยู่แล้ว
// จาก Program.cs เลยไม่ต้องแปลงชื่อเอง) ถ้าจะแก้ type ฝั่ง frontend ต้องมา
// แก้ไฟล์นี้คู่กันเสมอ

// หมายเหตุ: ตั้งใจไม่มี field "localTime" — เวลาท้องถิ่นของผู้ดูเป็นเรื่อง
// ของ browser ฝั่ง client เท่านั้น backend ไม่มีทางรู้ timezone ของคนเปิดหน้า
// จอ จึงไม่ควรส่งค่านี้มาจากฝั่งเซิร์ฟเวอร์ (ของเดิมที่ hardcode ไว้ใน
// mockData.ts เป็นความเข้าใจผิดที่แก้ไปแล้วทั้งฝั่ง frontend/backend)
// LastSyncedAt ส่งเป็น ISO timestamp ดิบ ให้ frontend คำนวณ "กี่วินาทีที่แล้ว"
// เองตอน render แทนที่จะ freeze ข้อความไว้ตั้งแต่ตอนตอบ response
public record DashboardSnapshotDto(
    string Connection,
    DateTime LastSyncedAt,
    string BrokerTime,
    AccountInfoDto AccountInfo,
    AccountSummaryDto Account,
    List<EquityPointDto> EquityCurve,
    List<PositionDto> OpenPositions,
    List<ClosedTradeDto> ClosedTrades,
    List<EaStatusDto> EaStatuses,
    RiskSnapshotDto Risk,
    PerformanceDto Performance,
    List<ActivityLogEntryDto> ActivityLog
);

// Identity of the account this snapshot belongs to - lets the frontend
// show which real MT5 account/broker is being viewed instead of a
// hardcoded label (see AccountListItemDto below for the picker list).
public record AccountInfoDto(
    int AccountId,
    long Mt5Login,
    string BrokerName,
    bool IsDemo
);

// One row for the account picker (GET /api/dashboard/accounts) - every
// account currently registered in the accounts table, regardless of
// whether it has any snapshots/trades yet.
public record AccountListItemDto(
    int AccountId,
    long Mt5Login,
    string BrokerName,
    string ServerName,
    bool IsDemo
);

public record AccountSummaryDto(
    decimal Balance,
    decimal Equity,
    decimal FloatingPnl,
    decimal TodayRealizedPnl,
    int TodayClosedCount,
    decimal MarginLevelPct,
    decimal FreeMargin,
    int TradesToday,
    int MaxTradesPerDay
);

public record PositionDto(
    string Id,
    string EaId,
    string EaName,
    string Symbol,
    string Side,
    decimal Lot,
    decimal OpenPrice,
    decimal? CurrentPrice,
    decimal? StopLoss,
    decimal? TakeProfit,
    decimal? Pnl,
    string OpenedAtBroker
);

public record ClosedTradeDto(
    string Id,
    string EaId,
    string EaName,
    string Symbol,
    string Side,
    decimal Lot,
    decimal OpenPrice,
    decimal? ClosePrice,
    decimal? Pnl,
    string ClosedAtBroker,
    string? CloseReason
);

public record EaStatusDto(
    string Id,
    string Name,
    string Symbol,
    string Timeframe,
    string State,
    string SessionWindow,
    string LastSignal,
    int TradesToday,
    int MaxTradesPerDay,
    string? Note
);

public record EquityPointDto(
    string Label,
    decimal Equity,
    decimal Balance
);

public record ActivityLogEntryDto(
    string Id,
    string TimeBroker,
    string EaName,
    string Message,
    string Level
);

public record RiskSnapshotDto(
    decimal MaxDrawdownTodayPct,
    decimal MaxDrawdown30dPct,
    decimal OpenSlTotal,
    decimal OpenTpTotal,
    string AvgRiskReward,
    int CurrentSpreadPts
);

// สถิติผลงานต่อช่วงเวลา (วันนี้/7 วัน/30 วัน) — คำนวณจาก trades ตรงๆ ไม่พึ่ง
// daily_performance เพราะตารางนั้นเติมผ่าน MySQL EVENT ซึ่ง event_scheduler
// ปิดอยู่บน shared host นี้ (ดูหมายเหตุใน schema.sql) เชื่อถือไม่ได้ว่าจะมีข้อมูลครบ
public record PerformanceRangeDto(
    int TradesCount,
    decimal WinRatePct,
    decimal ProfitFactor,
    decimal Expectancy,
    decimal AvgWin,
    decimal AvgLoss
);

public record PerformanceDto(
    PerformanceRangeDto Today,
    PerformanceRangeDto Last7d,
    PerformanceRangeDto Last30d
);
