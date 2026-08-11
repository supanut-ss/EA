namespace EaConsole.Api.Data.Entities;

// ตรงกับตาราง accounts ใน Backend/Database/schema.sql
public class Account
{
    public int AccountId { get; set; }
    public long Mt5Login { get; set; }
    public string BrokerName { get; set; } = default!;
    public string ServerName { get; set; } = default!;
    public string Currency { get; set; } = "USD";
    public bool IsDemo { get; set; } = true;
    public short BrokerGmtOffsetMinutes { get; set; }
    public DateTime CreatedAt { get; set; }

    public List<Ea> Eas { get; set; } = [];
    public List<Trade> Trades { get; set; } = [];
    public List<AccountSnapshot> Snapshots { get; set; } = [];
    public List<ActivityLogEntry> ActivityLogs { get; set; } = [];
}
