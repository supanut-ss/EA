using System.Text.Json.Serialization;

namespace EaConsole.Api.Dtos;

// DTOs for EA3's (XAUUSD_COUNTER_TREND.mq5, "ATS" protocol) webhook contract -
// see Controllers/SignalsController.cs. Field names are dictated by the EA's
// hardcoded StringFormat() calls (snake_case, ticket sent as a quoted string),
// not something we control on this side.

// POST /api/signals/pending - sent every InpPollInterval ms with account state.
// We don't run a remote signal dispatcher, so this doubles as EA3's heartbeat:
// SignalsController writes an AccountSnapshot from it and always responds "[]"
// (no pending signals), which the EA treats as "nothing to do" and continues
// trading from its own internal strategy logic untouched.
public record SignalPendingRequest(
    [property: JsonPropertyName("token")] string? Token,
    [property: JsonPropertyName("balance")] decimal Balance,
    [property: JsonPropertyName("equity")] decimal Equity,
    [property: JsonPropertyName("free_margin")] decimal FreeMargin,
    [property: JsonPropertyName("bid")] decimal Bid,
    [property: JsonPropertyName("ask")] decimal Ask,
    // Which account this EA3 instance is reporting for. Null from any build
    // older than 2026-08-28 (the field did not exist and the account was
    // hardcoded on both sides), so SignalsController falls back to its
    // DefaultAccountId - letting a demo instance point itself somewhere else
    // without disturbing an already-attached live one.
    [property: JsonPropertyName("account_id")] int? AccountId = null
    // "positions" array intentionally omitted - each position is already
    // reported individually via /api/signals/local on open/close, and
    // System.Text.Json ignores JSON properties with no matching DTO member.
);

// POST /api/signals/local - EA3 reporting its OWN internally-generated trade
// (opened by its own structure logic, not a webhook signal). Sent once on open
// (status="OPEN") and once on close (status="WIN"|"LOSS" based on profit sign).
// close_reason (added 2026-08-14): MT5's own DEAL_REASON when it's
// authoritative (TP/SL/Manual), else EA3's own tracked exit rule
// ("Structure Break", "Bearish CHoCH", "Time Stop", "Force Close
// (Session End)", ...) - free text, not a fixed set, see Trade.CloseReason.
public record SignalLocalTradeRequest(
    [property: JsonPropertyName("token")] string? Token,
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("action")] string Action, // "BUY" | "SELL"
    [property: JsonPropertyName("symbol")] string Symbol,
    [property: JsonPropertyName("volume")] decimal Volume,
    [property: JsonPropertyName("entry_price")] decimal EntryPrice,
    [property: JsonPropertyName("sl")] decimal Sl,
    [property: JsonPropertyName("tp")] decimal Tp,
    [property: JsonPropertyName("status")] string Status, // "OPEN" | "WIN" | "LOSS"
    [property: JsonPropertyName("ticket")] string Ticket,
    [property: JsonPropertyName("exit_price")] decimal ExitPrice,
    [property: JsonPropertyName("profit")] decimal Profit,
    [property: JsonPropertyName("close_reason")] string? CloseReason = null,
    // See SignalPendingRequest.AccountId - null on pre-2026-08-28 EA builds.
    [property: JsonPropertyName("account_id")] int? AccountId = null,
    // An eas row belongs to exactly one account, so moving an instance to a
    // different account means a different ea_id too - the dashboard lists EAs
    // by account and filters trades to that account's ea_ids, so a trade
    // carrying an ea_id registered under some OTHER account is dropped from
    // every per-EA view. Null on older builds -> DefaultEa3Id.
    [property: JsonPropertyName("ea_id")] int? EaId = null
);

// POST /api/signals/update - lifecycle status for a WEBHOOK-sourced signal
// (keyed by the signal id from a /pending response, not an MT5 ticket). Since
// /pending always returns no signals, this path is unreachable in practice;
// implemented to respond cleanly rather than 404 if it ever is called.
public record SignalUpdateRequest(
    [property: JsonPropertyName("token")] string? Token,
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("ticket")] string? Ticket,
    [property: JsonPropertyName("entry_price")] decimal EntryPrice,
    [property: JsonPropertyName("exit_price")] decimal ExitPrice,
    [property: JsonPropertyName("profit")] decimal Profit,
    // See SignalPendingRequest.AccountId - null on pre-2026-08-28 EA builds.
    [property: JsonPropertyName("account_id")] int? AccountId = null,
    // See SignalLocalTradeRequest.EaId.
    [property: JsonPropertyName("ea_id")] int? EaId = null
);
