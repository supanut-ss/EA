namespace EaConsole.Api.Data.Entities;

// ตรงกับตาราง activity_log ใน Backend/Database/schema.sql
public class ActivityLogEntry
{
    public long LogId { get; set; }
    public int AccountId { get; set; }
    public int? EaId { get; set; }
    public ActivityLevel Level { get; set; } = ActivityLevel.Info;
    public string Message { get; set; } = default!;
    public DateTime EventTimeBroker { get; set; }
    public DateTime CreatedAt { get; set; }

    public Account? Account { get; set; }
    public Ea? Ea { get; set; }
}
