namespace EaConsole.Api.Data.Entities;

// ตรงกับตาราง account_snapshots ใน Backend/Database/schema.sql
public class AccountSnapshot
{
    public long SnapshotId { get; set; }
    public int AccountId { get; set; }
    public DateTime CapturedAtBroker { get; set; }
    public decimal Balance { get; set; }
    public decimal Equity { get; set; }
    public decimal Margin { get; set; }
    public decimal FreeMargin { get; set; }
    public decimal? MarginLevelPct { get; set; }
    public int? SpreadPoints { get; set; }
    public ConnectionState ConnectionState { get; set; } = ConnectionState.Connected;
    public DateTime CreatedAt { get; set; }

    public Account? Account { get; set; }
}
