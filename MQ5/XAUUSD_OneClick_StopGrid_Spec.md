# XAUUSD One-Click Stop Grid EA

## Deterministic behavior

- Attach `XAUUSD_OneClick_StopGrid_EA.mq5` to the intended gold-symbol chart on an MT5 hedging account.
- A newly filled manual market order (`Magic = 0`) on that chart symbol is the trigger and level 1 of its direction.
- With `InpOrdersPerSide = 7` (default), a manual buy creates six Buy Stops above the manual fill and seven Sell Stops below it. A manual sell creates six Sell Stops below and seven Buy Stops above.
- `InpPriceStepCents` uses price cents rather than broker points. Its default `300` is a direct `3.000` price distance and creates levels such as 4000, 4003, and 4006 regardless of quote digits. The step is deliberately wide relative to the exit distances below: at gold near 4000 a `2.000` step is only 0.05% of price, which is noise rather than direction, and a grid that tight is consumed by ordinary intraday swings instead of by a real trend.
- Opening lots: level 1 on each side (the manual entry, and the opposite side's first pending order) always uses the manual entry's own lot — open it at whatever size you want, and the opposite side's first Stop matches it exactly. Level 2 and beyond use a fixed lot progression that is independent of the manual lot: odd multiples of `InpFixedLotUnit` (default `0.01`) — `3, 5, 7, 9, 11, 13, 15, 17, ...` i.e. `0.03, 0.05, 0.07, 0.09, 0.11, 0.13, 0.15, 0.17 lot`. Both sides follow the same fixed progression from level 2 onward.
### Basket exit rules

Exit distances use the same price-cent unit as the grid: `200` means a `2.000` price move, `140` means `1.400`. Every rule below measures the move of the **newest position on the profitable side**, not of the basket as a whole.

**Invariant — every exit distance must stay below `InpPriceStepCents`.** With the defaults the exits fire at `2.000` while the next grid level only fills at `3.000`, leaving `1.000` of margin. If an exit distance ever reaches the step, the grid opens another position while the EA is still waiting to exit, and the basket grows faster than it can be closed.

**Main gate — `N = 2k+1`.** Evaluated first on every tick. `k` is the number of currently losing positions in the basket and `N` the number of positions on the profitable side. Nothing is armed or closed until `N >= 2k + 1`. Setting `InpUseRecoveryFormula = false` disables the gate; the case rules below then stand on their own.

**Loser cut — hard loss stop.** Evaluated before every other rule. Once the basket holds `InpMaxLosersBeforeCut = 3` losing positions **and** price has run `InpLoserCutMoveCents = 200` (`2.000`) past the entry of the **newest** of them, the whole basket is closed at market — winners and losers alike, no gate check, no net-P/L check. With the default `3.000` grid this fires at `2.000` adverse, i.e. before the next adverse level at `3.000` can fill, so the losing side is structurally prevented from growing to a 4th position. Set `InpMaxLosersBeforeCut = 0` to disable.

**Safety breaker — gate unreachable.** `N` can never exceed `InpOrdersPerSide` (the grid's own level cap), so once `k` grows past `(InpOrdersPerSide - 1) / 2` the gate's `N >= 2k + 1` requirement can never be satisfied again: with `InpOrdersPerSide = 7`, that is `k >= 4` (needs `N >= 9`, but at most 7 winners can ever exist). Before that becomes a permanently stuck basket, the EA closes the whole basket at market immediately — the same action as CASE 2, but fired the instant `2k + 1 > InpOrdersPerSide` rather than waiting for a price-move condition that can never legitimately arrive. This only runs while `InpUseRecoveryFormula = true`. With the loser cut firing first at `k = 3` this breaker is a backstop that should rarely be reached.

**Why `InpOrdersPerSide = 7` and the loser cut are a matched pair.** The gate needs `2k + 1` winners, so at `k = 3` it would need all 7 winning levels filled and profitable at once — a `21.000` one-way run that rarely happens. The loser cut resolves that case at `k = 3` before the gate is ever consulted, which leaves the gate handling only `k = 1` (3 winners, a `9.000` run) and `k = 2` (5 winners, `15.000`) — both reachable. Disabling the loser cut without also raising `InpOrdersPerSide` leaves the `k = 3` case with no practical exit but the breaker.

**CASE 1 — `k = 0` (profit lock).** With no losing position, the winning side needs `InpConsecutiveWinners = 3` positions (a 3-0 basket) and its last winner must move past `InpWinnerMoveCents = 200`. The EA then arms a locked exit at `InpProfitLockCents = 140` from that position's entry price: a Buy opened at 4000 qualifies once Bid passes 4002, and the locked line is 4001.4. `InpProfitLockCents` must stay below `InpWinnerMoveCents`; `OnInit` rejects any other combination. `InpCloseMinProfitMoney` applies to this case only.

**CASE 2 — `k > 0` (market exit).** With at least one losing position, the basket is closed entirely at market — winners and losers alike, no net-P/L check — once the last winner moves past `InpLossExitMoveCents = 200`. A Buy opened at 4000 triggers this at 4002.

Both cases delete the basket's remaining tagged pending orders when they act, and both latch:

- CASE 1 sets an SL on winning-direction positions at the locked price and a TP at the same price on opposite-direction positions, because MT5 cannot place their SL on the other side of the current market.
- CASE 2 deletes pending orders first, then closes each position, so a fill cannot re-enter the basket mid-exit.
- Failed modifications and failed closes are retried on following ticks until the basket is empty.
- Latches persist through restart (state version 4). A restored CASE 2 latch closes its basket on the next tick.

## Safety and limitations

### Exit safety and persistence

- The loser cut is the EA's only loss-triggered exit and it is measured in price distance, not money: it bounds how far the losing side may run, not the account's currency drawdown. There is still no equity-percentage ceiling and no daily-loss protection, and every rule is **per basket** — opening several manual entries creates several independent baskets whose risk adds up. `InpStopLossDistance` remains the only optional per-position loss exit, and its default `0.0` disables that SL.
- The four basket exit rules (loser cut, safety breaker, CASE 1, CASE 2) are the only portfolio-management path, and all of them live inside `ManageFormulaClose()`, so `InpUseFormulaClose = false` disables the loss-triggered exits too. CASE 1 modifies owned positions with a common SL/TP line and submits no market close; the loser cut, the safety breaker, and CASE 2 are the places where the EA closes positions at market, and each closes the whole basket at once.
- Basket ownership, the CASE 1 protection line, and the market-exit latch persist through restart. Version 1.26 ignores and removes legacy percentage, fixed-loss, daily-loss, and liquidation fields, so attaching it cannot resume an old risk-triggered closure.
- Use one EA instance per account/server/symbol/magic scope. Persistence uses terminal Global Variables; copying the EA to another terminal or deleting these variables does not transfer or preserve saved basket state.
- With `InpUseFormulaClose = false` and no per-order SL, open positions have no EA-managed automatic loss exit. Increasing grid lots can therefore create unbounded losses; evaluate only in an isolated demo/test environment until independently validated.

- The EA refuses to initialize on a netting account because independent grid positions require hedging mode.
- Prices and volumes are normalized to the symbol tick size and broker volume step. A level is skipped rather than moved if its intended stop price is already behind the market or violates the broker stop distance.
- `InpStopLossDistance` and `InpTakeProfitDistance` default to zero, meaning no SL or TP. Configure both before live evaluation if bounded per-order risk is required.
- Pending orders are not automatically cancelled merely because the opposite side triggers. They remain until filled, deleted by either basket exit rule or manually, or expired by `InpExpirationHours`.
- The in-memory duplicate guard prevents repeated processing during one EA run. Existing manual positions are deliberately not multiplied after restart or reattachment.
- Basket tags and persisted adopted-root records allow management to be reconstructed after restart, including a tracked basket whose only remaining position is its manual root.
- Increasing opening lots are high risk. Verify the maximum generated lot and margin requirement before enabling AutoTrading, then forward-test on a demo account.

## Example

For a manual Buy at 4000 with 0.02 lot, seven levels per side, `InpPriceStepCents = 300`, and `InpFixedLotUnit = 0.01`:

| Side | Prices | Lots |
| --- | --- | --- |
| Buy | 4000 manual, then Buy Stops at 4003, 4006, 4009, 4012, 4015, 4018 | 0.02, 0.03, 0.05, 0.07, 0.09, 0.11, 0.13 |
| Sell | Sell Stops at 3997, 3994, 3991, 3988, 3985, 3982, 3979 | 0.02, 0.03, 0.05, 0.07, 0.09, 0.11, 0.13 |

The manual lot (`0.02` here) sets only level 1 on both sides; levels 2-7 are the same fixed `0.03, 0.05, 0.07, 0.09, 0.11, 0.13` regardless of what the manual lot was.

If every level on both sides fills, the basket carries roughly `1.00` lot in total. On a standard 100-ounce XAUUSD contract that is about `$100` of P/L per `1.000` of price movement, so verify margin against the account size before enabling AutoTrading.

### Exit examples

| Basket state | Gate `N >= 2k+1` | Rule | Action |
| --- | --- | --- | --- |
| 3 Buy winners, 0 losers, last Buy opened 4000, Bid 4002.1 | 3 >= 1 | CASE 1 | Delete pendings, lock exit at 4001.4 |
| 3 Buy winners, 0 losers, last Buy opened 4000, Bid 4001.9 | 3 >= 1 | CASE 1 | Wait; 1.9 has not passed 2.0 |
| 2 Buy winners, 0 losers, Bid far above | 2 >= 1 | CASE 1 | Wait; `InpConsecutiveWinners` needs 3 |
| 3 Buy winners, 1 Sell loser, last Buy opened 4000, Bid 4002.1 | 3 >= 3 | CASE 2 | Delete pendings, close all 4 positions at market |
| 2 Buy winners, 1 Sell loser, last Buy opened 4000, Bid 4002.1 | 2 < 3 | gate | Wait; the winning side is too small |
| 3 losers, newest loser is a Sell opened 3988, Ask 3989.9 | not evaluated | loser cut | Wait; 1.9 has not passed 2.0 |
| 3 losers, newest loser is a Sell opened 3988, Ask 3990.1 | not evaluated | loser cut | Delete pendings, close the whole basket at market |
| 3 Buy winners, 4 Sell losers, any price | needs `N >= 9`, max possible is 7 | safety breaker | Delete pendings, close everything at market immediately, no price condition |
