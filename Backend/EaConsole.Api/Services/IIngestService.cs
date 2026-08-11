using EaConsole.Api.Dtos;

namespace EaConsole.Api.Services;

public interface IIngestService
{
    Task IngestSnapshotAsync(SnapshotIngestRequest request, CancellationToken ct = default);
    Task IngestTradeAsync(TradeIngestRequest request, CancellationToken ct = default);
    Task IngestActivityLogAsync(ActivityLogIngestRequest request, CancellationToken ct = default);
    Task<bool> UpdateEaStatusAsync(int eaId, string state, CancellationToken ct = default);
}
