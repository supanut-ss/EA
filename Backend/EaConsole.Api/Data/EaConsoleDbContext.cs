using EaConsole.Api.Data.Entities;
using Microsoft.EntityFrameworkCore;

namespace EaConsole.Api.Data;

// DbContext นี้แค่ "แมป" เข้ากับ schema ที่มีอยู่แล้วใน
// Backend/Database/schema.sql — schema.sql เป็นเจ้าของโครงสร้างตารางตัวจริง
// (รวม views/stored procedure/event) ไม่ได้ใช้ EF Migrations สร้างตาราง
// เพื่อเลี่ยงปัญหา EF Core ไม่รองรับ MySQL native ENUM/VIEW/EVENT ได้ตรงๆ
public class EaConsoleDbContext(DbContextOptions<EaConsoleDbContext> options) : DbContext(options)
{
    public DbSet<Account> Accounts => Set<Account>();
    public DbSet<Ea> Eas => Set<Ea>();
    public DbSet<Trade> Trades => Set<Trade>();
    public DbSet<AccountSnapshot> AccountSnapshots => Set<AccountSnapshot>();
    public DbSet<ActivityLogEntry> ActivityLog => Set<ActivityLogEntry>();
    public DbSet<DailyPerformance> DailyPerformance => Set<DailyPerformance>();
    public DbSet<EquityCurveRow> EquityCurveRows => Set<EquityCurveRow>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<Account>(e =>
        {
            e.ToTable("accounts");
            e.HasKey(x => x.AccountId);
            e.Property(x => x.AccountId).HasColumnName("account_id");
            e.Property(x => x.Mt5Login).HasColumnName("mt5_login");
            e.Property(x => x.BrokerName).HasColumnName("broker_name").HasMaxLength(100);
            e.Property(x => x.ServerName).HasColumnName("server_name").HasMaxLength(100);
            e.Property(x => x.Currency).HasColumnName("currency").HasMaxLength(3);
            e.Property(x => x.IsDemo).HasColumnName("is_demo");
            e.Property(x => x.BrokerGmtOffsetMinutes).HasColumnName("broker_gmt_offset_minutes");
            e.Property(x => x.CreatedAt).HasColumnName("created_at");
        });

        modelBuilder.Entity<Ea>(e =>
        {
            e.ToTable("eas");
            e.HasKey(x => x.EaId);
            e.Property(x => x.EaId).HasColumnName("ea_id");
            e.Property(x => x.AccountId).HasColumnName("account_id");
            e.Property(x => x.MagicNumber).HasColumnName("magic_number");
            e.Property(x => x.Name).HasColumnName("name").HasMaxLength(100);
            e.Property(x => x.Symbol).HasColumnName("symbol").HasMaxLength(20);
            e.Property(x => x.Timeframe).HasColumnName("timeframe").HasMaxLength(20);
            e.Property(x => x.SessionStartHour).HasColumnName("session_start_hour");
            e.Property(x => x.SessionEndHour).HasColumnName("session_end_hour");
            e.Property(x => x.MaxTradesPerDay).HasColumnName("max_trades_per_day");
            e.Property(x => x.DeployedAt).HasColumnName("deployed_at");
            e.Property(x => x.Notes).HasColumnName("notes").HasMaxLength(255);
            e.Property(x => x.CreatedAt).HasColumnName("created_at");
            e.Property(x => x.UpdatedAt).HasColumnName("updated_at");

            e.Property(x => x.Status)
                .HasColumnName("status")
                .HasConversion(v => v.ToDb(), v => EnumDbMaps.EaRuntimeStateFromDb(v))
                .HasColumnType("enum('active','standby','error','not_deployed')");

            e.HasOne(x => x.Account).WithMany(a => a.Eas)
                .HasForeignKey(x => x.AccountId).OnDelete(DeleteBehavior.Cascade);

            e.HasIndex(x => new { x.AccountId, x.MagicNumber }).IsUnique();
        });

        modelBuilder.Entity<Trade>(e =>
        {
            e.ToTable("trades");
            e.HasKey(x => x.TradeId);
            e.Property(x => x.TradeId).HasColumnName("trade_id");
            e.Property(x => x.AccountId).HasColumnName("account_id");
            e.Property(x => x.EaId).HasColumnName("ea_id");
            e.Property(x => x.Mt5Ticket).HasColumnName("mt5_ticket");
            e.Property(x => x.Symbol).HasColumnName("symbol").HasMaxLength(20);
            e.Property(x => x.Lot).HasColumnName("lot").HasColumnType("decimal(10,2)");

            e.Property(x => x.OpenPrice).HasColumnName("open_price").HasColumnType("decimal(18,5)");
            e.Property(x => x.ClosePrice).HasColumnName("close_price").HasColumnType("decimal(18,5)");
            e.Property(x => x.StopLoss).HasColumnName("stop_loss").HasColumnType("decimal(18,5)");
            e.Property(x => x.TakeProfit).HasColumnName("take_profit").HasColumnType("decimal(18,5)");
            e.Property(x => x.CurrentPrice).HasColumnName("current_price").HasColumnType("decimal(18,5)");

            e.Property(x => x.UnrealizedPnl).HasColumnName("unrealized_pnl").HasColumnType("decimal(14,2)");
            e.Property(x => x.SlAmount).HasColumnName("sl_amount").HasColumnType("decimal(14,2)");
            e.Property(x => x.TpAmount).HasColumnName("tp_amount").HasColumnType("decimal(14,2)");
            e.Property(x => x.Pnl).HasColumnName("pnl").HasColumnType("decimal(14,2)");
            e.Property(x => x.Swap).HasColumnName("swap").HasColumnType("decimal(14,2)");
            e.Property(x => x.Commission).HasColumnName("commission").HasColumnType("decimal(14,2)");

            e.Property(x => x.OpenTimeBroker).HasColumnName("open_time_broker");
            e.Property(x => x.CloseTimeBroker).HasColumnName("close_time_broker");
            e.Property(x => x.CreatedAt).HasColumnName("created_at");
            e.Property(x => x.UpdatedAt).HasColumnName("updated_at");

            e.Property(x => x.Side)
                .HasColumnName("side")
                .HasConversion(v => v.ToDb(), v => EnumDbMaps.TradeSideFromDb(v))
                .HasColumnType("enum('BUY','SELL')");

            e.Property(x => x.Status)
                .HasColumnName("status")
                .HasConversion(v => v.ToDb(), v => EnumDbMaps.TradeStatusFromDb(v))
                .HasColumnType("enum('OPEN','CLOSED')");

            // Free text, not an enum - see Trade.cs::CloseReason for why
            // (EA3 sends its own descriptive reasons that don't fit a
            // fixed set).
            e.Property(x => x.CloseReason)
                .HasColumnName("close_reason")
                .HasColumnType("varchar(50)");

            e.HasOne(x => x.Account).WithMany(a => a.Trades)
                .HasForeignKey(x => x.AccountId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne(x => x.Ea).WithMany(a => a.Trades)
                .HasForeignKey(x => x.EaId).OnDelete(DeleteBehavior.Cascade);

            e.HasIndex(x => new { x.AccountId, x.Mt5Ticket }).IsUnique();
            e.HasIndex(x => new { x.AccountId, x.Status });
            e.HasIndex(x => new { x.EaId, x.CloseTimeBroker });
        });

        modelBuilder.Entity<AccountSnapshot>(e =>
        {
            e.ToTable("account_snapshots");
            e.HasKey(x => x.SnapshotId);
            e.Property(x => x.SnapshotId).HasColumnName("snapshot_id");
            e.Property(x => x.AccountId).HasColumnName("account_id");
            e.Property(x => x.CapturedAtBroker).HasColumnName("captured_at_broker");
            e.Property(x => x.Balance).HasColumnName("balance").HasColumnType("decimal(14,2)");
            e.Property(x => x.Equity).HasColumnName("equity").HasColumnType("decimal(14,2)");
            e.Property(x => x.Margin).HasColumnName("margin").HasColumnType("decimal(14,2)");
            e.Property(x => x.FreeMargin).HasColumnName("free_margin").HasColumnType("decimal(14,2)");
            e.Property(x => x.MarginLevelPct).HasColumnName("margin_level_pct").HasColumnType("decimal(9,2)");
            e.Property(x => x.SpreadPoints).HasColumnName("spread_points");
            e.Property(x => x.CreatedAt).HasColumnName("created_at");

            e.Property(x => x.ConnectionState)
                .HasColumnName("connection_state")
                .HasConversion(v => v.ToDb(), v => EnumDbMaps.ConnectionStateFromDb(v))
                .HasColumnType("enum('connected','disconnected')");

            e.HasOne(x => x.Account).WithMany(a => a.Snapshots)
                .HasForeignKey(x => x.AccountId).OnDelete(DeleteBehavior.Cascade);

            e.HasIndex(x => new { x.AccountId, x.CapturedAtBroker });
        });

        modelBuilder.Entity<ActivityLogEntry>(e =>
        {
            e.ToTable("activity_log");
            e.HasKey(x => x.LogId);
            e.Property(x => x.LogId).HasColumnName("log_id");
            e.Property(x => x.AccountId).HasColumnName("account_id");
            e.Property(x => x.EaId).HasColumnName("ea_id");
            e.Property(x => x.Message).HasColumnName("message").HasMaxLength(500);
            e.Property(x => x.EventTimeBroker).HasColumnName("event_time_broker");
            e.Property(x => x.CreatedAt).HasColumnName("created_at");

            e.Property(x => x.Level)
                .HasColumnName("level")
                .HasConversion(v => v.ToDb(), v => EnumDbMaps.ActivityLevelFromDb(v))
                .HasColumnType("enum('ok','info','warn','error')");

            e.HasOne(x => x.Account).WithMany(a => a.ActivityLogs)
                .HasForeignKey(x => x.AccountId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne(x => x.Ea).WithMany(a => a.ActivityLogs)
                .HasForeignKey(x => x.EaId).OnDelete(DeleteBehavior.SetNull);

            e.HasIndex(x => new { x.AccountId, x.EventTimeBroker });
        });

        modelBuilder.Entity<DailyPerformance>(e =>
        {
            e.ToTable("daily_performance");
            e.HasKey(x => new { x.EaId, x.TradeDate });
            e.Property(x => x.EaId).HasColumnName("ea_id");
            e.Property(x => x.TradeDate).HasColumnName("trade_date");
            e.Property(x => x.TradesCount).HasColumnName("trades_count");
            e.Property(x => x.WinCount).HasColumnName("win_count");
            e.Property(x => x.LossCount).HasColumnName("loss_count");
            e.Property(x => x.GrossProfit).HasColumnName("gross_profit").HasColumnType("decimal(14,2)");
            e.Property(x => x.GrossLoss).HasColumnName("gross_loss").HasColumnType("decimal(14,2)");
            e.Property(x => x.NetPnl).HasColumnName("net_pnl").HasColumnType("decimal(14,2)");
            e.Property(x => x.WinRatePct).HasColumnName("win_rate_pct").HasColumnType("decimal(5,2)");
            e.Property(x => x.ProfitFactor).HasColumnName("profit_factor").HasColumnType("decimal(8,2)");

            e.HasOne(x => x.Ea).WithMany()
                .HasForeignKey(x => x.EaId).OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<EquityCurveRow>(e =>
        {
            e.HasNoKey();
            e.ToView("v_equity_curve_daily");
            e.Property(x => x.AccountId).HasColumnName("account_id");
            e.Property(x => x.SnapDate).HasColumnName("snap_date");
            e.Property(x => x.Equity).HasColumnName("equity").HasColumnType("decimal(14,2)");
            e.Property(x => x.Balance).HasColumnName("balance").HasColumnType("decimal(14,2)");
            e.Property(x => x.CapturedAtBroker).HasColumnName("captured_at_broker");
        });
    }
}
