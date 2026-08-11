namespace EaConsole.Api.Dtos;

// Request DTO สำหรับ endpoint ที่ EA (ผ่าน WebRequest ใน MQL5) หรือตัวกลาง
// จะยิงเข้ามาเติมข้อมูลลง DB — ดู Controllers/IngestController.cs

public record SnapshotIngestRequest(
    int AccountId,
    DateTime CapturedAtBroker,
    decimal Balance,
    decimal Equity,
    decimal Margin,
    decimal FreeMargin,
    decimal? MarginLevelPct,
    int? SpreadPoints,
    string ConnectionState // "connected" | "disconnected"
);

public record TradeIngestRequest(
    int AccountId,
    int EaId,
    long Mt5Ticket,
    string Symbol,
    string Side,           // "BUY" | "SELL"
    decimal Lot,
    decimal OpenPrice,
    decimal? ClosePrice,
    decimal? StopLoss,
    decimal? TakeProfit,
    decimal? CurrentPrice,
    decimal? UnrealizedPnl,
    decimal? SlAmount,
    decimal? TpAmount,
    DateTime OpenTimeBroker,
    DateTime? CloseTimeBroker,
    string Status,          // "OPEN" | "CLOSED"
    decimal? Pnl,
    decimal Swap,
    decimal Commission,
    string? CloseReason     // "TP" | "SL" | "TRAILING_STOP" | "MANUAL" | "EA_LOGIC" | "OTHER"
);

public record ActivityLogIngestRequest(
    int AccountId,
    int? EaId,
    string Level,   // "ok" | "info" | "warn" | "error"
    string Message,
    DateTime EventTimeBroker
);

public record EaStatusUpdateRequest(
    string State   // "active" | "standby" | "error" | "not_deployed"
);
