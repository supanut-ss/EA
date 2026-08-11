using EaConsole.Api.Dtos;
using EaConsole.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EaConsole.Api.Controllers;

// Endpoint ฝั่ง "เขียน" ที่ EA (ผ่าน MQL5 WebRequest ไปยังตัวกลาง หรือ
// service เล็กๆ ที่ bridge ให้) ยิงเข้ามาเติมข้อมูลระหว่างวัน
//
// หมายเหตุ: ยังไม่มี authentication/authorization ใดๆ — endpoint พวกนี้เปิด
// กว้างเพื่อความง่ายตอน dev เท่านั้น ก่อนใช้งานจริง (โดยเฉพาะถ้า backend นี้
// เข้าถึงได้จากอินเทอร์เน็ต) ต้องใส่ API key หรือ auth scheme ให้ EA/bridge
// ก่อนเสมอ
[ApiController]
[Route("api/ingest")]
public class IngestController(IIngestService ingestService) : ControllerBase
{
    [HttpPost("snapshot")]
    public async Task<IActionResult> IngestSnapshot([FromBody] SnapshotIngestRequest request, CancellationToken ct)
    {
        await ingestService.IngestSnapshotAsync(request, ct);
        return Accepted();
    }

    [HttpPost("trade")]
    public async Task<IActionResult> IngestTrade([FromBody] TradeIngestRequest request, CancellationToken ct)
    {
        await ingestService.IngestTradeAsync(request, ct);
        return Accepted();
    }

    [HttpPost("log")]
    public async Task<IActionResult> IngestLog([FromBody] ActivityLogIngestRequest request, CancellationToken ct)
    {
        await ingestService.IngestActivityLogAsync(request, ct);
        return Accepted();
    }

    [HttpPut("ea/{eaId:int}/status")]
    public async Task<IActionResult> UpdateEaStatus(int eaId, [FromBody] EaStatusUpdateRequest request, CancellationToken ct)
    {
        var updated = await ingestService.UpdateEaStatusAsync(eaId, request.State, ct);
        return updated ? NoContent() : NotFound();
    }
}
