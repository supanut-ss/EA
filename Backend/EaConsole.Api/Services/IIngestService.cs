using EaConsole.Api.Data.Entities;
using EaConsole.Api.Dtos;

namespace EaConsole.Api.Services;

public interface IIngestService
{
    Task IngestSnapshotAsync(SnapshotIngestRequest request, CancellationToken ct = default);
    Task IngestTradeAsync(TradeIngestRequest request, CancellationToken ct = default);
    Task IngestActivityLogAsync(ActivityLogIngestRequest request, CancellationToken ct = default);
    Task<bool> UpdateEaStatusAsync(int eaId, string state, CancellationToken ct = default);

    // Shared by IngestController's /api/ingest/snapshot (EA1/EA2) and
    // SignalsController's /api/signals/pending (EA3's heartbeat-in-disguise -
    // see that controller's comment) so both stop inserting a brand new row
    // every ~10-30s. Nothing on the dashboard reads finer than "latest per
    // day" (see SnapshotRetentionService's comment), so upsert one row per
    // (account, broker day) instead of insert-then-thin-later.
    Task UpsertDailySnapshotAsync(
        int accountId, DateTime capturedAtBroker, decimal balance, decimal equity,
        decimal margin, decimal freeMargin, decimal? marginLevelPct, int? spreadPoints,
        ConnectionState connectionState, CancellationToken ct = default);
}
