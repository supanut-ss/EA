# XAUUSD 9x9 Stop Grid EA

## Defaults

- On attach, the EA records the current Bid/Ask midpoint as the grid anchor.
- It places nine Buy Stops at `anchor + level * $2.00` and nine Sell Stops at `anchor - level * $2.00`, for levels 1 through 9. The step is a price distance, so it does not depend on the broker's point size or number of digits.
- Before level 3 fills, pending orders use the configured anchor stop. Buy positions target `anchor + $20.00`; Sell positions target `anchor - $20.00` by default.
- The special `3-0` exit applies only when level 3 fills with exactly three open EA positions on that side and zero open EA positions on the opposite side. Only then does the EA cancel all its pending orders and manage the filled side as one basket: initial Buy SL is level 1 + `$1.00`; initial Sell SL is mirrored. Thereafter, each additional `$1.00` of favorable movement advances the SL by `$1.00`. For a `$2.00` grid, Buy at level 3 + `$1.00` moves SL to level 2; at level 4 it moves to level 2 + `$1.00`.
- The fixed exit cases are evaluated from the triggering side's open-position counts. On a `3-1`, `3-2`, or `3-3` level-3 fill, the EA sets TP on the main side to level 4 + `$1.00`, level 5 + `$1.00`, or level 7 + `$1.00`, respectively. On a `5-4` level-5 fill, it sets the main-side TP to level 9 + `$1.00`.
- For those fixed cases, when the target level fills, the EA deletes all of its pending orders and sets a fixed SL on the main side: level 3 + `$1.00` for `3-1`, level 4 + `$1.00` for `3-2`, level 6 + `$1.00` for `3-3`, and level 8 + `$1.00` for `5-4`. It keeps the target TP and does not trail this SL. Positions on the opposite side retain their existing SL/TP.
- If price gaps past the case TP before a newly filled main-side position receives that TP, the EA cancels pending orders and retries closing the main-side basket. When all main-side positions already carry the target TP, the server-side TP handles the exit without duplicate market-close requests.
- Case `6-5` is not enabled because the grid remains at nine levels per side, so level 11 cannot fill. If a count pattern does not match one of the configured cases, the existing grid exits/mode continue unchanged.
- `InpStopLossBeyondAnchor` controls the pre-level-3 stop. `InpTakeProfitBeyondLast` controls the TP, which remains at `anchor +/- $20.00` by default after trailing starts.
- The level-1 Buy Stop and level-1 Sell Stop always have the same lot. The user confirmed that 1x/2x means `0.01`/`0.02` lot; set `InpFirstLevelLot` to either value.
- Default lot mode is equal size at every level. The optional odd-multiple mode uses `base, 3*base, 5*base, ..., 17*base`.
- Custom mode accepts a comma-separated sequence with one value per level. Its first value must match `InpFirstLevelLot`; the same sequence is mirrored on both sides.
- Default opposite-side mode is `KEEP`, matching the existing Stop Grid plan. `DELETE` cancels the opposite pending ladder as soon as the first position fills.
- Once the cycle has no positions or pending orders, the EA starts a new grid after five seconds. This can be disabled with `InpAutoRearmAfterCycle`.

## Lot and loss estimates

The estimates below are conservative static-anchor-stop comparisons, not a simulation of the level-3 trailing exit. They assume a USD account, a standard XAUUSD contract size of 100 oz per lot, and no spread, commission, swap, or stop slippage. Under that contract, 0.01 lot gains or loses about $1 for each $1 move in gold. The EA uses the broker's `OrderCalcProfit` result for its live risk check instead of relying on this table.

| Lot mode | Base lot | Lots per side, levels 1–9 | Gross loss if one full side returns to the anchor | Gross loss if both sides stop in a KEEP cycle | Gross profit for one side at its $20 target |
| --- | ---: | --- | ---: | ---: | ---: |
| Equal | 0.01 | 0.01 × 9 | $90 | $180 | $90 |
| Equal | 0.02 | 0.02 × 9 | $180 | $360 | $180 |
| Odd multiples | 0.01 | 0.01, 0.03, …, 0.17 | $1,050 | $2,100 | $570 |
| Odd multiples | 0.02 | 0.02, 0.06, …, 0.34 | $2,100 | $4,200 | $1,140 |

Equal lots are the default because increasing each level does not add an edge by itself and expands full-grid exposure sharply. With odd multiples, the modeled full-side stop loss is much larger than the profit at the target. If “1 and 2” means actual `1.00` and `2.00` lots, not `0.01` and `0.02`, equal-size full-cycle loss estimates are about `$18,000` and `$36,000` respectively under the same contract assumption.

## Runtime guards and limitations

- A grid is rejected if the broker cannot represent every requested volume exactly, the modeled full-cycle static-anchor stop loss exceeds `InpMaxRiskPercent` of equity (default 2%), or projected margin level is below `InpMinMarginLevelPct` (default 300%). This guard does not credit the tighter level-3 trailing stop, so it can reject grids that would fit the modeled risk after trailing starts. Risk is computed for both directions, even in `DELETE` mode, to allow for simultaneous fills before cancellation completes.
- With the default 0.05 price-unit slippage buffer, equal 0.01 lots project to about `$180.90` full-cycle risk and equal 0.02 lots to `$361.80` under the standard contract assumption; the default 2% cap therefore needs roughly `$9,045`/`$18,090` equity before costs.
- Entry spread above `InpMaxSpreadPrice` (default `$0.20`) rejects placement and retries later. Prices are rounded to the broker tick size.
- This EA requires an MT5 hedging account. It preserves server-side orders when the EA is removed; the pending orders already carry SL and TP.
- Stop orders can slip or gap through the anchor, so realized loss can exceed the estimate. The lot table is a gross scenario calculation, not evidence of profitability. Costs and performance still require broker-specific backtests and forward observation.
