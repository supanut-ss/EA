namespace EaConsole.Api.Data.Entities;

// ตรงกับตาราง trades ใน Backend/Database/schema.sql — ticket-based
// 1 แถวต่อ 1 position ครอบคลุมทั้งช่วงเปิด-ปิด
public class Trade
{
    public long TradeId { get; set; }
    public int AccountId { get; set; }
    public int EaId { get; set; }
    public long Mt5Ticket { get; set; }
    public string Symbol { get; set; } = default!;
    public TradeSide Side { get; set; }
    public decimal Lot { get; set; }

    public decimal OpenPrice { get; set; }
    public decimal? ClosePrice { get; set; }
    public decimal? StopLoss { get; set; }
    public decimal? TakeProfit { get; set; }

    public decimal? CurrentPrice { get; set; }
    public decimal? UnrealizedPnl { get; set; }

    public decimal? SlAmount { get; set; }
    public decimal? TpAmount { get; set; }

    public DateTime OpenTimeBroker { get; set; }
    public DateTime? CloseTimeBroker { get; set; }
    public TradeStatus Status { get; set; } = TradeStatus.Open;
    public decimal? Pnl { get; set; }
    public decimal Swap { get; set; }
    public decimal Commission { get; set; }
    public TradeCloseReason? CloseReason { get; set; }

    public DateTime CreatedAt { get; set; }
    public DateTime UpdatedAt { get; set; }

    public Account? Account { get; set; }
    public Ea? Ea { get; set; }
}
