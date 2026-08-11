using EaConsole.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EaConsole.Api.Controllers;

[ApiController]
[Route("api/dashboard")]
public class DashboardController(IDashboardQueryService dashboardQueryService) : ControllerBase
{
    // GET /api/dashboard/snapshot?accountId=1
    // ตอบ shape เดียวกับ Frontend/src/types/dashboard.ts::DashboardSnapshot
    // เป๊ะๆ — Frontend/src/hooks/useDashboardData.ts เรียก endpoint นี้ตรงๆ
    [HttpGet("snapshot")]
    public async Task<IActionResult> GetSnapshot([FromQuery] int accountId, CancellationToken ct)
    {
        var snapshot = await dashboardQueryService.GetSnapshotAsync(accountId, ct);
        if (snapshot is null)
            return NotFound(new { message = $"ไม่พบข้อมูลบัญชี {accountId} หรือยังไม่มี snapshot เข้ามาเลย" });

        return Ok(snapshot);
    }
}
