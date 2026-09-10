# XAUUSD One-Click Stop Grid EA

## Deterministic behavior

- Attach `XAUUSD_OneClick_StopGrid_EA.mq5` to the intended gold-symbol chart on an MT5 hedging account.
- A newly filled manual market order (`Magic = 0`) on that chart symbol is the trigger and level 1 of its direction.
- With `InpOrdersPerSide = 7` (default), a manual buy creates six Buy Stops above the manual fill and seven Sell Stops below it. A manual sell creates six Sell Stops below and seven Buy Stops above.
- `InpPriceStepCents` uses price cents rather than broker points. Its default `300` is a direct `3.000` price distance and creates levels such as 4000, 4003, and 4006 regardless of quote digits. The step is deliberately wide relative to the exit distances below: at gold near 4000 a `2.000` step is only 0.05% of price, which is noise rather than direction, and a grid that tight is consumed by ordinary intraday swings instead of by a real trend.
- Opening lots: level 1 on each side (the manual entry, and the opposite side's first pending order) always uses the manual entry's own lot — open it at whatever size you want, and the opposite side's first Stop matches it exactly. Level 2 and beyond use a fixed lot progression that is independent of the manual lot: odd multiples of `InpFixedLotUnit` (default `0.01`) — `3, 5, 7, 9, 11, 13, 15, 17, ...` i.e. `0.03, 0.05, 0.07, 0.09, 0.11, 0.13, 0.15, 0.17 lot`. Both sides follow the same fixed progression from level 2 onward.
### Basket exit rules

Exit distances use the same price-cent unit as the grid: `200` means a `2.000` price move, `150` means `1.500`. Every rule below measures against the **newest position on the relevant side**, not against the basket as a whole.

**Invariant — every exit distance must stay below `InpPriceStepCents`.** With the defaults the rules fire at `1.500`-`2.000` while the next grid level only fills at `3.000`. `OnInit` rejects `InpTrailArmCents >= InpPriceStepCents`. If a loss-side distance ever reached the step, the grid would open another position while the EA was still waiting to act, and the basket would grow faster than it could be closed.

### Trailing protection (two layers)

The basket carries **one** protective price line, applied to every position at once: an SL on positions in the winning direction and a TP at the same price on opposite-direction positions, because MT5 cannot place an SL on the far side of the market. When price touches the line the whole basket closes together.

Two layers compete to set that line, and the better of the two wins:

- **Layer 1 — the previous position's entry.** Available the moment a second position exists on the winning side, with no price movement required, so the basket is never left unprotected. It costs the newest position one grid step, which the older positions' gains cover.
- **Layer 2 — `InpTrailArmCents` (`1.500`) past the newest entry.** Applies once price has actually travelled that far, and locks profit on every position including the newest.

Two properties make this work:

- **The line only moves away from the market, never back toward it.** Protection once gained is never given up.
- **Pending orders are left alive.** The grid keeps extending while the basket is protected, so a long trend keeps adding levels instead of being cut short. Only a market exit (loser cut or safety breaker) deletes pendings — plus a one-off cleanup after the line closes the last position, so a later fill cannot silently restart a finished basket.

**Loser cut — hard loss stop.** Evaluated before every other rule. Once the basket holds `InpMaxLosersBeforeCut = 3` losing positions **and** price has run `InpLoserCutMoveCents = 200` (`2.000`) past the entry of the **newest** of them, the whole basket is closed at market — winners and losers alike, no gate check, no net-P/L check. With the default `3.000` grid this fires at `2.000` adverse, i.e. before the next adverse level at `3.000` can fill, so the losing side is structurally prevented from growing to a 4th position. Set `InpMaxLosersBeforeCut = 0` to disable.

**Safety breaker — recovery unreachable.** A basket trades its way out when the winning side reaches `2k + 1` positions, but that count can never exceed `InpOrdersPerSide`. Once `k` grows past `(InpOrdersPerSide - 1) / 2` the recovery is arithmetically out of reach: with `InpOrdersPerSide = 7`, that is `k >= 4` (needs 9 winners, but at most 7 can ever exist). Rather than hold an unrecoverable basket, the EA closes it at market the instant `2k + 1 > InpOrdersPerSide`. This only runs while `InpUseRecoveryFormula = true`, and with the loser cut firing first at `k = 3` it is a backstop that should rarely be reached.

**Why `InpOrdersPerSide = 7` and the loser cut are a matched pair.** At `k = 3` a recovery would need all 7 winning levels filled and profitable at once — a `21.000` one-way run that rarely happens. The loser cut resolves that case at `k = 3`, leaving only `k = 1` (3 winners, a `9.000` run) and `k = 2` (5 winners, `15.000`) to recover on their own — both reachable. Disabling the loser cut without also raising `InpOrdersPerSide` leaves the `k = 3` case with no practical exit but the breaker.

Behaviour common to the market exits:

- Both delete the basket's remaining tagged pending orders first, then close each position, so a fill cannot re-enter the basket mid-exit.
- Failed modifications and failed closes are retried on following ticks until the basket is empty.
- The trailing line and the market-exit latch persist through restart (state version 4). A restored latch closes its basket on the next tick; a restored line keeps trailing from where it was.

## Safety and limitations

### Exit safety and persistence

- The loser cut is the EA's only loss-triggered exit and it is measured in price distance, not money: it bounds how far the losing side may run, not the account's currency drawdown. There is still no equity-percentage ceiling and no daily-loss protection, and every rule is **per basket** — opening several manual entries creates several independent baskets whose risk adds up. `InpStopLossDistance` remains the only optional per-position loss exit, and its default `0.0` disables that SL.
- The three basket exit rules (trailing protection, loser cut, safety breaker) are the only portfolio-management path, and all of them live inside `ManageFormulaClose()`, so `InpUseFormulaClose = false` disables the loss-triggered exits too. Trailing protection modifies owned positions with a common SL/TP line and submits no market close; the loser cut and the safety breaker are the places where the EA closes positions at market, and each closes the whole basket at once.
- Basket ownership, the trailing protection line, and the market-exit latch persist through restart. Version 1.30 ignores and removes legacy percentage, fixed-loss, daily-loss, and liquidation fields, so attaching it cannot resume an old risk-triggered closure.
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

### How the line trails a rising Buy grid

| Event | Line sits at | Set by |
| --- | --- | --- |
| Only the manual position is open | no line yet | there is no previous entry to use |
| Level 2 fills at 4003 | 4000 | layer 1 |
| Bid passes 4004.5 | 4004.5 | layer 2 (`4003 + 1.500`) |
| Level 3 fills at 4006 | 4004.5 | unchanged; layer 1 would say 4003, which is worse |
| Bid passes 4007.5 | 4007.5 | layer 2 (`4006 + 1.500`) |
| Level 4 fills at 4009 | 4007.5 | unchanged |
| Bid passes 4010.5 | 4010.5 | layer 2 (`4009 + 1.500`) |
| Bid falls back to the line | basket closes | every position exits together |

### Exit examples

| Basket state | Rule | Action |
| --- | --- | --- |
| 2 Buy positions, newest opened 4003, Bid 4004.4 | trailing | Line held at 4000 (layer 1); layer 2 needs 4004.5 |
| 3 Buy positions, newest opened 4006, Bid 4007.6 | trailing | Line raised to 4007.5; pendings stay alive |
| Line at 4007.5, Bid drops through it | trailing | All positions close at 4007.5, then leftover pendings are deleted |
| 3 losers, newest loser is a Sell opened 3988, Ask 3989.9 | loser cut | Wait; 1.9 has not passed 2.0 |
| 3 losers, newest loser is a Sell opened 3988, Ask 3990.1 | loser cut | Delete pendings, close the whole basket at market |
| 3 Buy winners, 4 Sell losers, any price | safety breaker | Needs 9 winners, only 7 possible; close everything at market, no price condition |
