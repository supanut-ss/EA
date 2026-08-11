using EaConsole.Api.Dtos;

namespace EaConsole.Api.Services;

public interface IDashboardQueryService
{
    Task<DashboardSnapshotDto?> GetSnapshotAsync(int accountId, CancellationToken ct = default);
}
