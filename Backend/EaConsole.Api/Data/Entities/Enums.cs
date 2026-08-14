namespace EaConsole.Api.Data.Entities;

public enum EaRuntimeState
{
    Active,
    Standby,
    Error,
    NotDeployed,
}

public enum TradeSide
{
    Buy,
    Sell,
}

public enum TradeStatus
{
    Open,
    Closed,
}

public enum ConnectionState
{
    Connected,
    Disconnected,
}

public enum ActivityLevel
{
    Ok,
    Info,
    Warn,
    Error,
}

// แปลง enum ฝั่ง C# <-> ค่า string ของ MySQL ENUM column ตามที่กำหนดไว้ใน
// Backend/Database/schema.sql (ตั้งชื่อ enum แบบ PascalCase ให้ตรง C#
// convention แทนที่จะบังคับให้ชื่อ enum ตรงกับ DB ตรงๆ)
public static class EnumDbMaps
{
    public static string ToDb(this EaRuntimeState v) => v switch
    {
        EaRuntimeState.Active => "active",
        EaRuntimeState.Standby => "standby",
        EaRuntimeState.Error => "error",
        EaRuntimeState.NotDeployed => "not_deployed",
        _ => throw new ArgumentOutOfRangeException(nameof(v)),
    };

    public static EaRuntimeState EaRuntimeStateFromDb(string v) => v switch
    {
        "active" => EaRuntimeState.Active,
        "standby" => EaRuntimeState.Standby,
        "error" => EaRuntimeState.Error,
        "not_deployed" => EaRuntimeState.NotDeployed,
        _ => throw new ArgumentOutOfRangeException(nameof(v)),
    };

    public static string ToDb(this TradeSide v) => v == TradeSide.Buy ? "BUY" : "SELL";

    public static TradeSide TradeSideFromDb(string v) => v switch
    {
        "BUY" => TradeSide.Buy,
        "SELL" => TradeSide.Sell,
        _ => throw new ArgumentOutOfRangeException(nameof(v)),
    };

    public static string ToDb(this TradeStatus v) => v == TradeStatus.Open ? "OPEN" : "CLOSED";

    public static TradeStatus TradeStatusFromDb(string v) => v switch
    {
        "OPEN" => TradeStatus.Open,
        "CLOSED" => TradeStatus.Closed,
        _ => throw new ArgumentOutOfRangeException(nameof(v)),
    };

    // close_reason เป็น free text ใน DB แล้ว (ไม่ใช่ enum) เพราะ EA3 ส่ง
    // ข้อความอธิบายเอง ("Structure Break", "Bearish CHoCH", ...) ที่ไม่เข้า
    // ชุดค่าคงที่แบบ EA1/EA2 (TP/SL/TRAILING_STOP/MANUAL/EA_LOGIC/OTHER) -
    // ฟังก์ชันนี้แค่แปลง short code ที่รู้จักให้อ่านง่ายขึ้น ส่วนข้อความอื่น
    // (ของ EA3) อ่านง่ายอยู่แล้วเลยส่งผ่านตรงๆ
    public static string? PrettifyCloseReason(string? v) => v switch
    {
        null => null,
        "TP" => "Take profit",
        "SL" => "Stop loss",
        "TRAILING_STOP" => "Trailing stop",
        "MANUAL" => "Manual close",
        "EA_LOGIC" => "EA logic",
        "OTHER" => "Other",
        _ => v,
    };

    public static string ToDb(this ConnectionState v) =>
        v == ConnectionState.Connected ? "connected" : "disconnected";

    public static ConnectionState ConnectionStateFromDb(string v) => v switch
    {
        "connected" => ConnectionState.Connected,
        "disconnected" => ConnectionState.Disconnected,
        _ => throw new ArgumentOutOfRangeException(nameof(v)),
    };

    public static string ToDb(this ActivityLevel v) => v switch
    {
        ActivityLevel.Ok => "ok",
        ActivityLevel.Info => "info",
        ActivityLevel.Warn => "warn",
        ActivityLevel.Error => "error",
        _ => throw new ArgumentOutOfRangeException(nameof(v)),
    };

    public static ActivityLevel ActivityLevelFromDb(string v) => v switch
    {
        "ok" => ActivityLevel.Ok,
        "info" => ActivityLevel.Info,
        "warn" => ActivityLevel.Warn,
        "error" => ActivityLevel.Error,
        _ => throw new ArgumentOutOfRangeException(nameof(v)),
    };
}
