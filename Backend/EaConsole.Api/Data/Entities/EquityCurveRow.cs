namespace EaConsole.Api.Data.Entities;

// Keyless entity แมปกับ VIEW v_equity_curve_daily ใน schema.sql — ใช้ view
// แทนที่จะเขียน window function ซ้ำเป็น LINQ เพราะ SQL ฝั่งนั้นถูกรีวิว/
// ทดสอบไวยากรณ์ไว้แล้ว และกันไม่ให้ตรรกะ "1 จุดต่อวัน" ไปเพี้ยนคนละทางกัน
public class EquityCurveRow
{
    public int AccountId { get; set; }
    public DateOnly SnapDate { get; set; }
    public decimal Equity { get; set; }
    public decimal Balance { get; set; }
    public DateTime CapturedAtBroker { get; set; }
}
