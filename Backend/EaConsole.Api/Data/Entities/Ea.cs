namespace EaConsole.Api.Data.Entities;

// ตรงกับตาราง eas ใน Backend/Database/schema.sql
public class Ea
{
    public int EaId { get; set; }
    public int AccountId { get; set; }
    public uint MagicNumber { get; set; }
    public string Name { get; set; } = default!;
    public string Symbol { get; set; } = default!;
    public string Timeframe { get; set; } = default!;
    public byte? SessionStartHour { get; set; }
    public byte? SessionEndHour { get; set; }
    public byte? MaxTradesPerDay { get; set; }
    public EaRuntimeState Status { get; set; } = EaRuntimeState.NotDeployed;
    public DateTime? DeployedAt { get; set; }
    public string? Notes { get; set; }
    public DateTime CreatedAt { get; set; }
    public DateTime UpdatedAt { get; set; }

    public Account? Account { get; set; }
    public List<Trade> Trades { get; set; } = [];
    public List<ActivityLogEntry> ActivityLogs { get; set; } = [];
}
