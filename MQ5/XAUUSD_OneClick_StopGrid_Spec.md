# XAUUSD One-Click Stop Grid EA v1.36

## Scope and defaults

Each newly filled manual entry (Magic 0) on the chart symbol starts an independent basket. Use a hedging account and one EA instance per account/server/symbol/magic scope.

| Setting | Default | Meaning |
| --- | --- | --- |
| Levels per side | 5 | The manual position counts as level 1 on its side |
| Grid step | 300 price cents = 3.000 | Independent of broker point size |
| Lots | Manual lot, 0.03, 0.05, 0.07, 0.09 | Level 1 on each side mirrors the manual lot; later levels use odd multiples of 0.01 |
| Price-following trailing distance | 300 price cents = 3.000 | Distance behind executable Bid/Ask for clean and post-cut baskets |
| Base-line cushion | 0.050 | Used by the initial/pre-cut ladder, not by the fixed recovery SL |
| Recovery SL milestone distance | 200 price cents = 2.000 | Measured from the intended recovery SL level; trailing is already active before this milestone |
| Winner cut count | 3 | Winning-side open positions needed while opposite losing positions exist |
| Pre-SL loser cut | 2 positions and 2.500 adverse | Superseded for the managed side once clean trailing or the fixed recovery SL is active |
| Maximum opening spread | 0.20 | Reject grid creation above this spread |
| Pending cap | 100 | Per symbol/magic; reject a new grid if its full pending count does not fit |
| Optional per-pending SL/TP | 0.0 / 0.0 | Disabled by default; does not install an initial stop on the manual root position |
| Formula master switch | true | Enables EA-side basket exits and retries |
| Recovery safety breaker | true | Exit when a side's losing count cannot satisfy 2k+1 within the level cap |

## Opening example

Manual Buy at 4000, 0.02 lot:

| Level | Buy price | Sell price | Lot per position |
| --- | --- | --- | --- |
| 1 | 4000 manual entry | 3997 Sell Stop | 0.02 |
| 2 | 4003 Buy Stop | 3994 Sell Stop | 0.03 |
| 3 | 4006 Buy Stop | 3991 Sell Stop | 0.05 |
| 4 | 4009 Buy Stop | 3988 Sell Stop | 0.07 |
| 5 | 4012 Buy Stop | 3985 Sell Stop | 0.09 |

A manual Sell mirrors the layout. Grid placement is not transactional: a rejected individual request can leave a partial grid, and rejected levels are not automatically recreated. A spread/cap rejection leaves the manual position open. Pending expiration is GTC by default.

## Mode 1: clean winning streak

A clean basket has no opposite-side positions and has not undergone winner cut. Once the profitable side has at least two positions and its initial trailing line is established:

1. Persist the clean-trend decision and protection direction.
2. Delete **all pending orders belonging to this basket**, on both sides.
3. Retry failed deletions on later ticks without suspending protection.
4. Keep the selected direction authoritative even if its profit later turns negative.
5. Continue price-following trailing without needing more grid fills.

The initial line uses the previous position's entry plus 0.050 for Buy, or minus 0.050 for Sell. Thereafter the clean candidate follows Bid minus 3.000 for Buy, or Ask plus 3.000 for Sell, retaining whichever line is tighter. An existing tighter stop is never loosened. The legacy armed-ladder candidate may also tighten the line when applicable. No fixed budget target exists in this clean mode.

| Clean Buy example | Behavior |
| --- | --- |
| Only Buy at 4000 | No trailing yet |
| Second Buy fills at 4003; Buy side is profitable | Initial line 4000.050; latch clean mode and delete all basket pendings |
| Bid advances to 4007 | Price-following candidate 4004.000; raise SL if it improves the existing line |
| Bid advances to 4008 | Candidate 4005.000; continue trailing |
| Bid returns to the active line | Latch a full-basket market exit and retry until empty |

The previous 2.500 loser-cut rule is skipped for the clean direction once this mode is active, allowing the requested trailing SL to control its pullback exit. Other safety checks remain. A failed cancellation can still fill an order; the latch continues pending retirement and the basket retains protection. It does not silently resume grid expansion.

## Mode 2: winner cut, approach trailing, and recovery SL milestone

Before winner cut, the winning direction is selected by positive aggregate position profit plus swap (if both sides are positive, choose the larger). The count on the winning side is its open-position count, not the number of individually profitable positions.

Winner cut starts when that side has at least three positions and the opposite side has at least one losing position, unless a higher-priority exit has already triggered. It records:

- k: the opposite-side losing-position count at cut time;
- anchor: the newest winning-side position's entry at cut time;
- direction: the surviving side.

It persists the decision before attempting to close every position and pending order on the opposite side. The surviving side's pending orders remain until another exit deletes them. Failed side closes are retried; budget and protection continue in the same tick.

### Exact recovery levels

| Quantity | Buy survivor | Sell survivor |
| --- | --- | --- |
| Full-basket budget target | anchor + k * grid step | anchor - k * grid step |
| Intended fixed SL | anchor + (k-1) * grid step | anchor - (k-1) * grid step |
| SL arming quote | Bid >= fixed SL + 2.000 | Ask <= fixed SL - 2.000 |

The arming comparison is inclusive. No 0.050 cushion is added to the recovery SL milestone. Before price actually reaches the intended fixed SL level (anchor for k=1, anchor + (k-1) grid steps for higher k), a post-cut basket trails exactly like an ordinary mixed basket - the same previous-entry/newest-entry ladder, no price-following - so K-mode is never tighter than the no-cut case during that approach. Only once price reaches that level does price-following take over: Buy follows Bid minus 3.000; Sell follows Ask plus 3.000. The existing ladder candidate and any tighter protection are retained throughout, so the switch can only improve the line, never loosen it. Trailing remains active even with just one surviving position, and it continues after the milestone without moving the SL backward. The milestone is therefore a minimum protection level in the profitable direction, not an instruction to replace a tighter line.

For example, with Buy anchor 4006 and unchanged Buy entries 4000/4003/4006: for k=1 (intended SL = anchor = 4006), Bid 4005 still trails on the ladder alone (candidate 4003.050, identical to a no-cut basket at that quote); once Bid reaches 4006 price-following joins in, and Bid 4008 arms the milestone at 4006, with the budget still at 4009. For k=2 (intended SL = anchor + 3.000 = 4009), the ladder alone governs all the way through Bid 4008; Bid 4009 brings price-following into the comparison, Bid 4011 arms the milestone at 4009, and the budget still exits at 4012. New fills can produce a tighter ladder candidate on their own, independent of this switch. Only clean mode retires all pending orders; K-mode trailing does not delete surviving-side pending orders.

With anchor 4006 and grid step 3.000:

| Survivor | k | Budget target | Intended SL | First quote that arms SL |
| --- | --- | --- | --- | --- |
| Buy | 1 | Bid 4009 | 4006 | Bid 4008 |
| Buy | 2 | Bid 4012 | 4009 | Bid 4011 |
| Sell | 1 | Ask 4003 | 4006 | Ask 4004 |
| Sell | 2 | Ask 4000 | 4003 | Ask 4001 |

Later fills do not move the saved cut anchor, milestone, or budget target, though they may tighten the actual trailing line. Budget is checked before trailing and the milestone, so a quote that jumps directly past the target starts a full exit immediately.

Before the recovery SL is armed, the existing loser cut remains active. After arming, loser cut is skipped only for the surviving direction; the cut side is still checked if a failed close left positions behind. This prevents new survivor fills from moving the old loser-cut anchor ahead of the requested fixed SL. Other existing stops and safety exits can still close earlier; the target is not a guaranteed fill or a promise of net profit after banked losses and costs.

## Shared exits and priority

With the formula master enabled, the per-tick order is:

1. Detect a touched existing protective line; honor/retry a settled full-basket exit even after a price rebound.
2. Retry clean pending retirement; if no positions remain, delete leftover pendings.
3. Evaluate pre-SL loser cut independently per side, except the side already governed by clean trailing or an armed recovery SL.
4. Evaluate the recovery safety breaker: 2 * losing count + 1 > levels per side.
5. Retry/start winner cut (a latched clean basket does not switch to winner cut).
6. Check the saved winner-cut budget target.
7. Update the applicable protection: approach trailing followed by the recovery SL milestone after cut, otherwise ladder/clean trailing.
8. Check the new line against the latest quote, then submit SL/TP modifications.

Loser cut counts **all open positions** on a side and measures the adverse distance from its newest position. Two positions alone do not trigger it. With the default five levels, the safety breaker triggers at three losing positions on a side, when enabled.

Buy-direction protection triggers when Bid is at or below the line; Sell-direction protection triggers when Ask is at or above it. The EA persists the full-exit latch, attempts pending deletion, and closes remaining positions at market. SL on the winning direction and TP on the opposite direction are also installed at the common line where broker constraints permit.

A settled full exit can keep failing - broker FROZEN, disconnect, requote rejection - while price keeps moving, and by then the recorded protection line is already behind current price (that is what triggered the exit) so the broker would reject re-installing it at that same level. Whenever the market close leaves positions open, a failsafe stop refreshes each one to the tightest level the broker's stop/freeze distance currently allows, moving only tighter than any existing stop and never back. It is not trailing and does not replace the retry itself; it exists purely to bound further loss while the exit keeps being retried.

A broker SL/TP exit at the formula line is handled in OnTradeTransaction even if price has bounced before the next tick. Ownership uses the manual position identifier or the tagged original opening order. The exit reason, original position direction, and historical DEAL_SL/DEAL_TP must match the current formula line or the retained pre-recovery line with its original direction. The first post-cut trailing change retains that older line before replacing it, and the later milestone does not overwrite it. It can be restored even before the milestone has armed. The retained line covers a delayed modification or a direction change that leaves the older broker SL/TP installed. Unrelated optional stops at other levels do not trigger this callback path.

## Failure handling, restart, and limits

| Case | Behavior |
| --- | --- |
| Failed close or pending deletion during full exit | Retry while the basket still has state; price rebound does not cancel the decision; a failsafe stop refreshes any positions still open toward current price on every retry |
| Failed losing-side close | Retry the saved cut side while continuing budget/protection |
| Failed SL modification | Keep the intended line and retry; an armed state does not prove the broker accepted every modification |
| No positions left | Delete leftover pending orders; prune the basket when fully empty |
| Restart with complete saved state | Restore the basket, line, market-exit latch, cut data, clean-retirement flag, and recovery-SL flag |
| Older saved state (versions 1-5) | Read supported legacy ownership/protection/cut fields; new flags default to false |
| Incomplete cut state | Cannot restore that budget; terminal discovery does not reconstruct the historical cut decision |
| Formula master false | EA-side decisions/retries stop; already-installed broker SL/TP remain; grid entry handling is separate |
| Terminal offline | EA-side trailing, cancellation and market exits do not run; accepted broker stops remain |
| Manual partial close | Remaining positions are still managed; no automatic full exit solely for a manual partial close |

State version 6 stores clean retirement as field C, recovery SL arming as field J, and the retained pre-recovery line/direction as fields Y/Z. Every actual line change and mode decision is persisted; unchanged trailing candidates do not flush state repeatedly. Persistence uses terminal Global Variables and does not transfer to another terminal automatically.

No equity-percentage or daily-loss limit exists. Stops and targets are price thresholds, not guaranteed fill prices or monetary profit guarantees. Multiple baskets add exposure. Use demo validation for actual execution behavior.

## Verification

Run the deterministic mocked-broker regression checks in MQ5/Tests/stopgrid_exit_tests.cjs and compile the EA with MetaEditor. The harness executes adapted production function bodies but is not a broker integration test, restart durability test, or performance backtest.
