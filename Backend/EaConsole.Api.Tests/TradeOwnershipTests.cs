using EaConsole.Api.Controllers;
using EaConsole.Api.Data;
using EaConsole.Api.Data.Entities;
using EaConsole.Api.Dtos;
using EaConsole.Api.Services;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using Xunit;

namespace EaConsole.Api.Tests;

public class TradeOwnershipTests
{
    [Fact]
    public async Task GenericIngest_RejectsAccountAndEaMismatch()
    {
        await using var db = CreateDb();
        SeedEa(db, eaId: 3, accountId: 2, "Counter Trend");
        await db.SaveChangesAsync();
        var service = new IngestService(db);

        var result = await service.IngestTradeAsync(CreateTradeRequest(accountId: 1, eaId: 3, ticket: 1001));

        Assert.Equal(TradeIngestResult.InvalidOwner, result);
        Assert.Empty(db.Trades);
    }

    [Fact]
    public async Task GenericIngest_DoesNotOverwriteAnotherEasTrade()
    {
        await using var db = CreateDb();
        SeedEa(db, eaId: 2, accountId: 1, "Scalping");
        SeedEa(db, eaId: 5, accountId: 1, "Counter Trend Demo");
        db.Trades.Add(CreateTrade(accountId: 1, eaId: 5, ticket: 1002, lot: 0.05m));
        await db.SaveChangesAsync();
        var service = new IngestService(db);

        var result = await service.IngestTradeAsync(CreateTradeRequest(accountId: 1, eaId: 2, ticket: 1002));

        Assert.Equal(TradeIngestResult.OwnershipConflict, result);
        var trade = await db.Trades.SingleAsync();
        Assert.Equal(5, trade.EaId);
        Assert.Equal(0.05m, trade.Lot);
    }

    [Fact]
    public async Task CounterTrendLocalReport_ReclaimsMisattributedTicket()
    {
        await using var db = CreateDb();
        SeedEa(db, eaId: 2, accountId: 1, "Scalping");
        SeedEa(db, eaId: 5, accountId: 1, "Counter Trend Demo");
        var originalOpenTime = new DateTime(2026, 9, 4, 10, 0, 0, DateTimeKind.Utc);
        var trade = CreateTrade(accountId: 1, eaId: 2, ticket: 1003, lot: 0.05m);
        trade.OpenTimeBroker = originalOpenTime;
        db.Trades.Add(trade);
        await db.SaveChangesAsync();
        var controller = new SignalsController(db, new IngestService(db));

        var result = await controller.Local(CreateLocalRequest(accountId: 1, eaId: 5, ticket: "1003"), default);

        Assert.IsType<OkResult>(result);
        trade = await db.Trades.SingleAsync();
        Assert.Equal(5, trade.EaId);
        Assert.Equal(0.05m, trade.Lot);
        Assert.Equal(originalOpenTime, trade.OpenTimeBroker);
    }

    [Fact]
    public async Task CounterTrendLocalReport_RejectsAccountAndEaMismatch()
    {
        await using var db = CreateDb();
        SeedEa(db, eaId: 3, accountId: 2, "Counter Trend Live");
        await db.SaveChangesAsync();
        var controller = new SignalsController(db, new IngestService(db));

        var result = await controller.Local(CreateLocalRequest(accountId: 1, eaId: 3, ticket: "1004"), default);

        Assert.IsType<BadRequestObjectResult>(result);
        Assert.Empty(db.Trades);
    }

    private static EaConsoleDbContext CreateDb()
    {
        var options = new DbContextOptionsBuilder<EaConsoleDbContext>()
            .UseInMemoryDatabase(Guid.NewGuid().ToString())
            .Options;
        return new EaConsoleDbContext(options);
    }

    private static void SeedEa(EaConsoleDbContext db, int eaId, int accountId, string name)
    {
        db.Eas.Add(new Ea
        {
            EaId = eaId,
            AccountId = accountId,
            MagicNumber = (uint)(88000 + eaId),
            Name = name,
            Symbol = "XAUUSD",
            Timeframe = "M15",
        });
    }

    private static Trade CreateTrade(int accountId, int eaId, long ticket, decimal lot) => new()
    {
        AccountId = accountId,
        EaId = eaId,
        Mt5Ticket = ticket,
        Symbol = "XAUUSD",
        Side = TradeSide.Buy,
        Lot = lot,
        OpenPrice = 4400m,
        OpenTimeBroker = DateTime.UtcNow,
        Status = TradeStatus.Open,
    };

    private static TradeIngestRequest CreateTradeRequest(int accountId, int eaId, long ticket) => new(
        accountId, eaId, ticket, "XAUUSD", "BUY", 0.01m, 4400m,
        null, 4390m, 4410m, 4401m, 1m, -10m, 10m,
        DateTime.UtcNow, null, "OPEN", null, 0m, 0m, null);

    private static SignalLocalTradeRequest CreateLocalRequest(int accountId, int eaId, string ticket) => new(
        null, "local-test", "BUY", "XAUUSD", 0.05m, 4400m, 4390m, 4410m,
        "OPEN", ticket, 0m, 0m, null, accountId, eaId);
}
