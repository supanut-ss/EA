using EaConsole.Api.Data;
using Microsoft.EntityFrameworkCore;

namespace EaConsole.Api.Services;

// account_snapshots รับแถวใหม่ทุก ~10 วินาทีต่อ EA (heartbeat) - ปล่อยไว้เฉยๆ
// โตไม่มีที่สิ้นสุด (EA เดียวก็ ~8,640 แถว/วันแล้ว) ทั้งที่ฟีเจอร์เดียวที่ใช้
// ข้อมูลเก่าจริงๆ คือกราฟ Equity Curve ซึ่งดึงผ่าน v_equity_curve_daily -
// เอาแค่ snapshot ล่าสุดของแต่ละวันมาโชว์ ไม่เคยแตะ resolution ระดับวินาที
// เลยสักจุด (การ์ด Balance/Equity ด้านบนก็ใช้แค่แถวล่าสุดแถวเดียวเหมือนกัน)
//
// เลยเก็บแบบ tiered retention: ข้อมูลละเอียด (ทุก ~10 วิ) เก็บไว้เฉพาะ
// RawRetentionWindow ล่าสุด (ยังพอใช้ debug/ตรวจสอบปัญหาย้อนหลังสั้นๆ ได้ -
// เพิ่งใช้วิธีนี้เจอบั๊ก accountId ผิดของ EA2 ไปเมื่อกี้) ส่วนที่เก่ากว่านั้น
// thin เหลือวันละ 1 แถว (แถวล่าสุดของวันนั้น) ให้กราฟ Equity Curve ยังใช้งาน
// ได้ปกติ 100% แต่ตารางไม่โตไม่มีที่สิ้นสุด
//
// ทำเป็น BackgroundService ในแอปเอง แทนที่จะใช้ MySQL EVENT (แบบที่
// sp_refresh_daily_performance ใช้) เพราะเช็คแล้ว event_scheduler บน host
// นี้ปิดอยู่ (SHOW VARIABLES LIKE 'event_scheduler' = OFF) และ shared
// hosting ทั่วไปมักไม่ให้ตั้งค่านี้ให้ persist ข้าม MySQL restart ได้ -
// ฝากงานนี้ไว้กับแอปที่รันอยู่ตลอดอยู่แล้วน่าเชื่อถือกว่า
public class SnapshotRetentionService(
    IServiceScopeFactory scopeFactory,
    ILogger<SnapshotRetentionService> logger) : BackgroundService
{
    private static readonly TimeSpan RawRetentionWindow = TimeSpan.FromDays(3);
    private static readonly TimeSpan RunInterval = TimeSpan.FromHours(6);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        // หน่วงตอน startup กันชนกับงาน startup อื่นๆ ของแอป ไม่ต้องรีบวิ่งทันที
        try { await Task.Delay(TimeSpan.FromMinutes(2), stoppingToken); }
        catch (TaskCanceledException) { return; }

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await CleanupAsync(stoppingToken);
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Snapshot retention cleanup failed");
            }

            try { await Task.Delay(RunInterval, stoppingToken); }
            catch (TaskCanceledException) { break; }
        }
    }

    private async Task CleanupAsync(CancellationToken ct)
    {
        using var scope = scopeFactory.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<EaConsoleDbContext>();

        var cutoffUtc = DateTime.UtcNow - RawRetentionWindow;

        // เก็บแถวเดียวต่อ (account_id, วัน) สำหรับข้อมูลที่เก่ากว่า cutoff -
        // เลือกด้วย MAX(snapshot_id) แทน MAX(captured_at_broker) เพราะ
        // snapshot_id เป็น AUTO_INCREMENT ที่แอปนี้ insert-only เรียงตามเวลา
        // เขียนจริงเสมอ ไม่มีทางเสมอกันแบบ captured_at_broker ที่เป็นเวลา
        // จาก EA (อาจซ้ำกันได้ในทางทฤษฎี)
        var deleted = await db.Database.ExecuteSqlInterpolatedAsync($@"
            DELETE s FROM account_snapshots s
            LEFT JOIN (
                SELECT account_id, DATE(captured_at_broker) AS d, MAX(snapshot_id) AS keep_id
                FROM account_snapshots
                WHERE captured_at_broker < {cutoffUtc}
                GROUP BY account_id, DATE(captured_at_broker)
            ) keep
              ON keep.account_id = s.account_id
             AND keep.d = DATE(s.captured_at_broker)
             AND keep.keep_id = s.snapshot_id
            WHERE s.captured_at_broker < {cutoffUtc}
              AND keep.keep_id IS NULL", ct);

        if (deleted > 0)
            logger.LogInformation("Snapshot retention: thinned {Count} rows older than {Cutoff:o} to daily resolution", deleted, cutoffUtc);
    }
}
