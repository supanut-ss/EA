# XAUUSD One-Click Stop Grid EA

## Deterministic behavior

- Attach `XAUUSD_OneClick_StopGrid_EA.mq5` to the intended gold-symbol chart on an MT5 hedging account.
- A newly filled manual market order (`Magic = 0`) on that chart symbol is the trigger and level 1 of its direction.
- With `InpOrdersPerSide = 7` (default), a manual buy creates six Buy Stops above the manual fill and seven Sell Stops below it. A manual sell creates six Sell Stops below and seven Buy Stops above.
- `InpPriceStepCents` uses price cents rather than broker points. Its default `200` is a direct `2.000` price distance and creates levels such as 4000, 4002, and 4004 regardless of quote digits.
- Opening lots: level 1 on each side (the manual entry, and the opposite side's first pending order) always uses the manual entry's own lot — open it at whatever size you want, and the opposite side's first Stop matches it exactly. Level 2 and beyond use a fixed lot progression that is independent of the manual lot: odd multiples of `InpFixedLotUnit` (default `0.01`) — `3, 5, 7, 9, 11, 13, 15, 17, ...` i.e. `0.03, 0.05, 0.07, 0.09, 0.11, 0.13, 0.15, 0.17 lot`. Both sides follow the same fixed progression from level 2 onward.
### Basket exit rules

Exit distances use the same price-cent unit as the grid: `150` means a `1.500` price move, `100` means `1.000`. Every rule below measures the move of the **newest position on the profitable side**, not of the basket as a whole.

**Main gate — `N = 2k+1`.** Evaluated first on every tick. `k` is the number of currently losing positions in the basket and `N` the number of positions on the profitable side. Nothing is armed or closed until `N >= 2k + 1`. Setting `InpUseRecoveryFormula = false` disables the gate; the case rules below then stand on their own.

**CASE 1 — `k = 0` (profit lock).** With no losing position, the winning side needs `InpConsecutiveWinners = 3` positions (a 3-0 basket) and its last winner must move past `InpWinnerMoveCents = 150`. The EA then arms a locked exit at `InpProfitLockCents = 100` from that position's entry price: a Buy opened at 4000 qualifies once Bid passes 4001.5, and the locked line is 4001. `InpProfitLockCents` must stay below `InpWinnerMoveCents`; `OnInit` rejects any other combination. `InpCloseMinProfitMoney` applies to this case only.

**CASE 2 — `k > 0` (market exit).** With at least one losing position, the basket is closed entirely at market — winners and losers alike, no net-P/L check — once the last winner moves past `InpLossExitMoveCents = 150`. A Buy opened at 4000 triggers this at 4001.5.

Both cases delete the basket's remaining tagged pending orders when they act, and both latch:

- CASE 1 sets an SL on winning-direction positions at the locked price and a TP at the same price on opposite-direction positions, because MT5 cannot place their SL on the other side of the current market.
- CASE 2 deletes pending orders first, then closes each position, so a fill cannot re-enter the basket mid-exit.
- Failed modifications and failed closes are retried on following ticks until the basket is empty.
- Latches persist through restart (state version 4). A restored CASE 2 latch closes its basket on the next tick.

## Safety and limitations

### Exit safety and persistence

- The EA has no automatic maximum-loss ceiling, basket liquidation, or daily-loss protection. No rule is triggered by loss: CASE 2 submits a market close only after the winning side satisfies the gate and the profit distance, so a basket that never produces that winner is never closed by the EA. `InpStopLossDistance` is the only optional loss exit created for each EA pending order, and its default `0.0` disables that SL.
- The two basket exit rules are the only portfolio-management path. CASE 1 modifies owned positions with a common SL/TP line and submits no market close; CASE 2 is the only place where the EA closes positions at market, and it closes the whole basket at once.
- Basket ownership, the CASE 1 protection line, and the CASE 2 exit latch persist through restart. Version 1.23 ignores and removes legacy percentage, fixed-loss, daily-loss, and liquidation fields, so attaching it cannot resume an old risk-triggered closure.
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

For a manual Buy at 4000 with 0.02 lot, seven levels per side, `InpPriceStepCents = 200`, and `InpFixedLotUnit = 0.01`:

| Side | Prices | Lots |
| --- | --- | --- |
| Buy | 4000 manual, then Buy Stops at 4002, 4004, 4006, 4008, 4010, 4012 | 0.02, 0.03, 0.05, 0.07, 0.09, 0.11, 0.13 |
| Sell | Sell Stops at 3998, 3996, 3994, 3992, 3990, 3988, 3986 | 0.02, 0.03, 0.05, 0.07, 0.09, 0.11, 0.13 |

The manual lot (`0.02` here) sets only level 1 on both sides; levels 2-7 are the same fixed `0.03, 0.05, 0.07, 0.09, 0.11, 0.13` regardless of what the manual lot was.

With a standard 100-ounce XAUUSD contract, three straight Buy winners at 4000/4002/4004 and a close just above 4005 produce approximately `$5 + $9 + $5 = $19` gross before spread, commission, swap, slippage, and any opposite-side loss.

### Exit examples

| Basket state | Gate `N >= 2k+1` | Rule | Action |
| --- | --- | --- | --- |
| 3 Buy winners, 0 losers, last Buy opened 4000, Bid 4001.6 | 3 >= 1 | CASE 1 | Delete pendings, lock exit at 4001 |
| 3 Buy winners, 0 losers, last Buy opened 4000, Bid 4001.4 | 3 >= 1 | CASE 1 | Wait; 1.4 has not passed 1.5 |
| 2 Buy winners, 0 losers, Bid far above | 2 >= 1 | CASE 1 | Wait; `InpConsecutiveWinners` needs 3 |
| 3 Buy winners, 1 Sell loser, last Buy opened 4000, Bid 4001.6 | 3 >= 3 | CASE 2 | Delete pendings, close all 4 positions at market |
| 2 Buy winners, 1 Sell loser, last Buy opened 4000, Bid 4001.6 | 2 < 3 | gate | Wait; the winning side is too small |
