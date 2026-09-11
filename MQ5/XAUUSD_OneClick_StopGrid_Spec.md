# XAUUSD One-Click Stop Grid EA

## Deterministic behavior

- Attach `XAUUSD_OneClick_StopGrid_EA.mq5` to the intended gold-symbol chart on an MT5 hedging account.
- A newly filled manual market order (`Magic = 0`) on that chart symbol is the trigger and level 1 of its direction.
- With `InpOrdersPerSide = 5` (default), a manual buy creates four Buy Stops above the manual fill and five Sell Stops below it. A manual sell creates four Sell Stops below and five Buy Stops above.
- `InpPriceStepCents` uses price cents rather than broker points. Its default `300` is a direct `3.000` price distance and creates levels such as 4000, 4003, and 4006 regardless of quote digits. The step is deliberately wide relative to the exit distances below: at gold near 4000 a `2.000` step is only 0.05% of price, which is noise rather than direction, and a grid that tight is consumed by ordinary intraday swings instead of by a real trend.
- Opening lots: level 1 on each side (the manual entry, and the opposite side's first pending order) always uses the manual entry's own lot — open it at whatever size you want, and the opposite side's first Stop matches it exactly. Level 2 and beyond use a fixed lot progression that is independent of the manual lot: odd multiples of `InpFixedLotUnit` (default `0.01`) — `3, 5, 7, 9, 11, 13, 15, 17, ...` i.e. `0.03, 0.05, 0.07, 0.09, 0.11, 0.13, 0.15, 0.17 lot`. Both sides follow the same fixed progression from level 2 onward.
### Basket exit rules

Exit distances use the same price-cent unit as the grid: `300` means a `3.000` price move, `200` means `2.000`. Every rule below measures against the **newest position on the relevant side**, not against the basket as a whole.

**Invariant — a loss-side exit distance must stay below `InpPriceStepCents`.** The loser cut fires at `2.000` while the next adverse level only fills at `3.000`: if a loss-side distance ever reached the step, the grid would open another position while the EA was still waiting to act, and the basket would grow faster than it could be closed.

The trailing arm is the one distance allowed to equal the step, and `OnInit` only rejects `InpTrailArmCents > InpPriceStepCents`. At exactly one step (`300`, the default) the armed stage deliberately stops firing mid-grid — the next level always fills before price can travel that far, which moves the anchor out from under it — so the line stays a full step behind the market instead of jumping up under the newest entry. That is the point: a line parked `1.950` under the market is taken out by ordinary gold noise long before the trend is done.

### Trailing protection (base + armed stage)

The basket carries **one** protective price line, applied to every position at once: an SL on positions in the winning direction and a TP at the same price on opposite-direction positions, because MT5 cannot place an SL on the far side of the market. When price touches the line the whole basket closes together.

**Neither stage runs until the winning side holds two positions.** A lone manual entry is not a grid yet: trailing it would park the line behind that entry and close the basket for a token profit before level 2 could fill at `3.000`, so the grid would never develop. The manual position therefore carries no trailing line of its own — the first line appears when the second position on its side fills.

Two stages then compete to set that line, and the better of the two wins:

- **Base — the previous position's entry + `InpProtectSpreadBuffer` (`0.050`).** Available the moment that second position exists, with no price movement required, so an established grid is never left unprotected. It costs the newest position one grid step (minus the small spread cushion), which the older positions' gains cover.
- **Armed — the newest entry + `InpProtectSpreadBuffer`, once price has run `InpTrailArmCents` (`3.000`) past that newest entry.** Note this locks only the small spread cushion past the newest entry, not the whole arm distance — the arm distance is just the trigger for ratcheting the line forward, not the profit it locks in. At the default arm of one full grid step this stage is dormant for every level except the last, since the next pending fills first and moves the anchor. It therefore only bites once the grid is fully extended and nothing is left to fill.

Two properties make this work:

- **The line only moves away from the market, never back toward it.** Protection once gained is never given up.
- **Pending orders are left alive** (on the side still gridding). The grid keeps extending while the basket is protected, so a long trend keeps adding levels instead of being cut short. Only a market exit (loser cut, safety breaker, or the winner cut budget backstop below) deletes pendings — plus a cleanup whenever a basket is left holding no positions at all, whether the line took them out or the user closed them by hand, so live stop orders can never silently re-enter a basket that is already finished.

**Winner cut — bank the edge (`k > 0` only).** Once the winning side reaches `InpWinnerCutCount = 3` positions, the losing side — its open positions and its remaining pending orders — closes at market immediately, no ratio check and no extra price-move requirement. The number of losing positions closed at that moment is banked as `k` for this basket, along with the winning side's newest entry price at that instant (the "cut anchor"). The winning side is left running with no hedge left on the other side; the trailing line above takes over protecting it from there. A **clean `k = 0` basket never triggers this** and is left entirely to the trailing line so a genuine trend is not cut short. Set `InpWinnerCutCount = 0` to disable.

**Winner cut budget — the backstop after the cut (`k > 0` only).** Since the loser side is gone for good once the winner cut fires, the surviving side has no hedge left if price reverses hard. As compensation for the loss it already banked, the surviving side is allowed to extend `k` grid steps past its cut-anchor price; once price reaches that limit — in either direction, whether still trending or now retracing — the whole remaining side is closed at market. This is what stops a hard pullback right after the cut from turning the banked edge into a loss: the ladder above still trails as price advances, but if it reverses far enough to hit the budget limit before the trailing line has caught up, the budget forces the exit. A `k = 0` basket (no winner cut yet) has no such ceiling.

**Loser cut — hard loss stop.** Evaluated before every other rule. Once one side holds `InpMaxLosersBeforeCut = 2` **positions** — open positions on that side, whatever their P/L — **and** price has run `InpLoserCutMoveCents = 250` (`2.500`) against the entry of the **newest** of them, the whole basket is closed at market: winners and losers alike, no gate check, no net-P/L check. Both sides are tested separately, since a developed basket holds positions on each and stopping at the first side over the count would leave the other unexamined. Set `InpMaxLosersBeforeCut = 0` to disable.

**Why the count ignores P/L.** A position only counts as losing while its own P/L is negative, and grid levels sit `3.000` apart, so a side's second position cannot be underwater until price is already a full step against the newer one. Counting losers would therefore pin the real trigger at `3.000` and make any distance below `300` dead configuration. Counting open positions instead puts the distance in charge: with two positions on a side, the cut fires exactly `2.500` past the newer one — with two Buys at 4000 and 4003 that is Bid `4000.500`, while the 4000 Buy is still in profit. The distance must stay under one grid step so the exit always lands **before the basket's next level can fill**: at Bid `4000.500` the opposite side's first Sell Stop at 3997 is still `3.500` away.

**This makes the loser cut the binding stop, ahead of the trailing line.** The rule applies to whichever side price is moving against, including one that was winning a moment ago. At two positions it fires at Bid `4000.500` against a line at `4000.050`; at three it fires at `4003.500` against a line at `4003.050`. The line therefore sits `0.450` behind the cut at every level and will rarely be the exit that triggers. Two consequences follow: effective room behind the market is `2.500` rather than the line's `2.950`, and the exit is an EA-side market close instead of a broker-side stop — so it needs the terminal running, where the trailing SL would have protected the basket on its own.

**Safety breaker — recovery unreachable.** A basket trades its way out when the winning side reaches `2k + 1` positions, but that count can never exceed `InpOrdersPerSide`. Once `k` grows past `(InpOrdersPerSide - 1) / 2` the recovery is arithmetically out of reach: with `InpOrdersPerSide = 5`, that is `k >= 3` (needs 7 winners, but at most 5 can ever exist). Rather than hold an unrecoverable basket, the EA closes it at market the instant `2k + 1 > InpOrdersPerSide`. This only runs while `InpUseRecoveryFormula = true`. With the loser cut now firing at `k = 2`, a third loser can no longer accumulate, so this rule is unreachable in practice and only matters if the loser cut is disabled.

**The loser cut now pre-empts the winner cut in whipsaw baskets.** The winner cut needs three winners on one side while the other side still holds losers, but that other side reaching two positions puts it one `2.500` move away from closing the basket outright. In practice the winner cut therefore mostly fires against a **single** loser, so the banked `k` is usually `1` and the budget one grid step past the cut anchor. That is the deliberate trade: a two-sided basket that has already gone wrong is cut rather than nursed.

Behaviour common to the full-basket market exits (loser cut, safety breaker, winner cut budget):

- All delete the basket's remaining tagged pending orders first, then close each position, so a fill cannot re-enter the basket mid-exit.
- Failed modifications and failed closes are retried on following ticks until the basket is empty.
- The trailing line, the market-exit latch, and the winner cut's banked `k` + cut-anchor price + cut direction persist through restart (state version 5). A restored latch closes its basket on the next tick; a restored line keeps trailing from where it was; a restored `k`/anchor/direction keeps the budget ceiling in force. The three cut fields are written together or not at all — a restored set missing any of them is discarded, and the surviving side then runs without its budget ceiling.

The winner cut itself is different: it closes only the losing side, not the whole basket. It banks `k`, the cut anchor and the surviving side's direction **before** sending any close, so the decision survives a mid-exit restart. From then on that stored direction — not a live P/L or position-count read — is what identifies the surviving side, and the cut side is re-closed on every following tick until it holds no positions or pendings at all. Without that stored direction, a single failed close would leave a position on the cut side and make the EA mistake it for the survivor: the budget would be measured in the wrong direction, the leftover would never be retried, and the trailing line would follow the wrong side.

## Safety and limitations

### Exit safety and persistence

- The loser cut is the EA's only loss-triggered exit and it is measured in price distance, not money: it bounds how far the losing side may run, not the account's currency drawdown. There is still no equity-percentage ceiling and no daily-loss protection, and every rule is **per basket** — opening several manual entries creates several independent baskets whose risk adds up. `InpStopLossDistance` remains the only optional per-position loss exit, and its default `0.0` disables that SL.
- The five basket exit rules (trailing protection, winner cut, winner cut budget, loser cut, safety breaker) are the only portfolio-management path, and all of them live inside `ManageFormulaClose()`, so `InpUseFormulaClose = false` disables every one of them. Trailing protection modifies owned positions with a common SL/TP line and submits no market close; the loser cut, the safety breaker, and the winner cut budget close the whole basket at once; the winner cut itself closes only the losing side, leaving the winning side open under the trailing line.
- Basket ownership, the trailing protection line, and the market-exit latch persist through restart. Version 1.33 ignores and removes legacy percentage, fixed-loss, daily-loss, and liquidation fields, so attaching it cannot resume an old risk-triggered closure.
- Use one EA instance per account/server/symbol/magic scope. Persistence uses terminal Global Variables; copying the EA to another terminal or deleting these variables does not transfer or preserve saved basket state.
- With `InpUseFormulaClose = false` and no per-order SL, open positions have no EA-managed automatic loss exit. Increasing grid lots can therefore create unbounded losses; evaluate only in an isolated demo/test environment until independently validated.

- The EA refuses to initialize on a netting account because independent grid positions require hedging mode.
- Prices and volumes are normalized to the symbol tick size and broker volume step. A level is skipped rather than moved if its intended stop price is already behind the market or violates the broker stop distance.
- `InpStopLossDistance` and `InpTakeProfitDistance` default to zero, meaning no SL or TP. Configure both before live evaluation if bounded per-order risk is required.
- `InpMaxSpreadPrice` defaults to `0.20` **in price units, not points** (the check is a raw `ask - bid`). A manual entry filled while the spread is wider gets **no grid at all** — the manual position stays open on its own, unhedged and with no pending levels behind it. That is deliberate, since a grid laid out on a news-blown spread prices every level badly, but `0.20` is tight for XAUUSD: raw/ECN accounts typically sit at `0.10`-`0.20` while standard accounts often run `0.20`-`0.40`, where this default would reject nearly every grid. Confirm the live spread before trusting it, and note that a lone manual position has no trailing line (that needs a second position on its side) and no loser cut (that needs `k >= 3`), so nothing closes it automatically.
- Pending orders are not automatically cancelled merely because the opposite side triggers. They remain until filled, deleted by either basket exit rule or manually, or expired by `InpExpirationHours`.
- The in-memory duplicate guard prevents repeated processing during one EA run. Existing manual positions are deliberately not multiplied after restart or reattachment.
- Basket tags and persisted adopted-root records allow management to be reconstructed after restart, including a tracked basket whose only remaining position is its manual root.
- Increasing opening lots are high risk. Verify the maximum generated lot and margin requirement before enabling AutoTrading, then forward-test on a demo account.

## Example

For a manual Buy at 4000 with 0.02 lot, five levels per side, `InpPriceStepCents = 300`, and `InpFixedLotUnit = 0.01`:

| Side | Prices | Lots |
| --- | --- | --- |
| Buy | 4000 manual, then Buy Stops at 4003, 4006, 4009, 4012 | 0.02, 0.03, 0.05, 0.07, 0.09 |
| Sell | Sell Stops at 3997, 3994, 3991, 3988, 3985 | 0.02, 0.03, 0.05, 0.07, 0.09 |

The manual lot (`0.02` here) sets only level 1 on both sides; levels 2-5 are the same fixed `0.03, 0.05, 0.07, 0.09` regardless of what the manual lot was.

If every level on both sides fills, the basket carries roughly `0.52` lot in total. On a standard 100-ounce XAUUSD contract that is about `$52` of P/L per `1.000` of price movement, so verify margin against the account size before enabling AutoTrading.

### How the line trails a rising Buy grid

(`InpPriceStepCents = 300`, `InpTrailArmCents = 300`, `InpProtectSpreadBuffer = 0.050`)

| Event | Line sits at | Room below Bid | Set by |
| --- | --- | --- | --- |
| Only the manual position is open | no line yet | — | trailing needs two positions on the side |
| Level 2 fills at 4003 | 4000.050 | 2.950 | base (`4000 + 0.050`) |
| Bid drifts to 4005.900 | 4000.050 | 5.850 | unchanged; the armed stage would need Bid past 4006, where level 3 fills first |
| Level 3 fills at 4006 | 4003.050 | 2.950 | base (`4003 + 0.050`) |
| Level 4 fills at 4009 | 4006.050 | 2.950 | base (`4006 + 0.050`) |
| Level 5 fills at 4012 | 4009.050 | 2.950 | base (`4009 + 0.050`) |
| Bid passes 4015.000 (`4012 + 3.000`) | 4012.050 | 2.950 | armed — only reachable now that no pending is left to fill |
| Bid falls back to the line | basket closes | — | every position exits together |

The line therefore never sits closer than one grid step minus the cushion (`2.950`) and widens to nearly two steps (`5.950`) just before the next level fills. With `InpTrailArmCents = 200` the armed stage would instead have pulled the line up to `2.000` under the market at every level.

### Exit examples

| Basket state | Rule | Action |
| --- | --- | --- |
| 2 Buy positions, newest opened 4003, Bid 4005.9 | trailing | Line held at 4000.050 (base); the armed stage would need Bid past 4006, where level 3 fills first |
| 3 Buy positions, newest opened 4006, Bid 4008.1 | trailing | Line at 4003.050 (base), `5.050` of room; pendings stay alive |
| Line at 4003.050, Bid drops through it | trailing | All positions close at 4003.050, then leftover pendings are deleted |
| 3 winners, 0 losers, newest opened 4006, Bid 4008.1 | trailing | No winner cut at `k = 0`; line simply sits at 4003.050 and the grid runs on |
| 3 winners, 1 loser, any price | winner cut | `3 >= InpWinnerCutCount`; close the losing side's position and pendings now, bank `k = 1` and the cut-anchor = 4006 (winner's newest entry), winner keeps running |
| 2 winners, 1 loser, any price | trailing (no winner cut yet) | Wait; winner side has not reached `InpWinnerCutCount = 3` yet |
| 3 winners, 2 losers, any price | loser cut (not winner cut) | The loser cut is evaluated first and `k = 2` is already met, so the whole basket closes rather than the losing side being banked |
| After winner cut with `k = 1`, anchor 4006, Bid reaches 4009 (`4006 + 1 x 3.000`) | winner cut budget | Budget exhausted; close the whole remaining side at market even though price is still advancing |
| Buys at 4000 and 4003, Bid 4000.6 | none yet | The side holds 2 positions, but the newest (4003) is only `2.400` against — short of `2.500` |
| Buys at 4000 and 4003, Bid 4000.5 | loser cut | Newest entry 4003 is now `2.500` against; delete pendings and close the whole basket at market. The 4000 Buy is still in profit here and closes with it |
| Sells at 3997 and 3994, Ask 3996.5 | loser cut | The mirror case on the Sell side, `2.500` past the newest Sell |
