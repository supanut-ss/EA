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

public enum TradeCloseReason
{
    TakeProfit,
    StopLoss,
    TrailingStop,
    Manual,
    EaLogic,
    Other,
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

    public static string ToDb(this TradeCloseReason v) => v switch
    {
        TradeCloseReason.TakeProfit => "TP",
        TradeCloseReason.StopLoss => "SL",
        TradeCloseReason.TrailingStop => "TRAILING_STOP",
        TradeCloseReason.Manual => "MANUAL",
        TradeCloseReason.EaLogic => "EA_LOGIC",
        TradeCloseReason.Other => "OTHER",
        _ => throw new ArgumentOutOfRangeException(nameof(v)),
    };

    public static TradeCloseReason TradeCloseReasonFromDb(string v) => v switch
    {
        "TP" => TradeCloseReason.TakeProfit,
        "SL" => TradeCloseReason.StopLoss,
        "TRAILING_STOP" => TradeCloseReason.TrailingStop,
        "MANUAL" => TradeCloseReason.Manual,
        "EA_LOGIC" => TradeCloseReason.EaLogic,
        "OTHER" => TradeCloseReason.Other,
        _ => throw new ArgumentOutOfRangeException(nameof(v)),
    };

    // ข้อความอ่านง่ายสำหรับโชว์บน Trade History card (Frontend คาดหวัง
    // free-text เช่น "Trailing stop", "Stop loss", "Take profit")
    public static string ToDisplayText(this TradeCloseReason v) => v switch
    {
        TradeCloseReason.TakeProfit => "Take profit",
        TradeCloseReason.StopLoss => "Stop loss",
        TradeCloseReason.TrailingStop => "Trailing stop",
        TradeCloseReason.Manual => "Manual close",
        TradeCloseReason.EaLogic => "EA logic",
        TradeCloseReason.Other => "Other",
        _ => v.ToString(),
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
