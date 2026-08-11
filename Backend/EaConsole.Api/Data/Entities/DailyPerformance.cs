namespace EaConsole.Api.Data.Entities;

// ตรงกับตาราง daily_performance ใน Backend/Database/schema.sql
// (rollup รายวัน เติมด้วย sp_refresh_daily_performance — ยังไม่มี API
// อ่านตารางนี้ตรงๆ ในตอนนี้ เตรียมไว้สำหรับ endpoint วิเคราะห์ย้อนหลังต่อไป)
public class DailyPerformance
{
    public int EaId { get; set; }
    public DateOnly TradeDate { get; set; }
    public int TradesCount { get; set; }
    public int WinCount { get; set; }
    public int LossCount { get; set; }
    public decimal GrossProfit { get; set; }
    public decimal GrossLoss { get; set; }
    public decimal NetPnl { get; set; }
    public decimal WinRatePct { get; set; }
    public decimal? ProfitFactor { get; set; }

    public Ea? Ea { get; set; }
}
