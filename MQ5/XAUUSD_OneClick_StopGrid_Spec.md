# XAUUSD One-Click Stop Grid EA v1.43

## Scope and defaults

Each newly filled manual entry (Magic 0) on the chart symbol starts an independent basket, unless the manual entry filter below excludes it. A basket is adopted only once real orders exist to manage it. Use a hedging account and one EA instance per account/server/symbol/magic scope.

As of v1.40 the default grid step is 200 cents (2.000), tuned to close baskets faster (and more often via ordinary noise, not just real reversals) than the 300-cent default v1.36-v1.39 shipped with. The four arm/move distances below all move together with the step - each keeps the same ratio to it that it had at 300 cents - because InpTrailArmCents is validated to never exceed InpPriceStepCents and InpRecoverySLArmCents to always stay strictly below it; changing the step without rescaling these throws INIT_PARAMETERS_INCORRECT. Every worked example elsewhere in this document (the opening ladder, the Mode 2 recovery-level tables) still uses the older 300-cent/3.000 step for its numbers, since rewriting every example to 200 cents changes no relationship being illustrated - do the same substitution (2.000 for 3.000, and rescale the other three inputs the same way) before comparing an example's numbers to a live 200-cent basket.

| Setting | Default | Meaning |
| --- | --- | --- |
| Levels per side | 5 | The manual position counts as level 1 on its side |
| Grid step | 200 price cents = 2.000 | Independent of broker point size |
| Lots | Manual lot, 0.03, 0.05, 0.07, 0.09 | Level 1 on each side mirrors the manual lot; later levels use odd multiples of 0.01 |
| Price-following trailing distance | 200 price cents = 2.000 | Distance behind executable Bid/Ask for clean and post-cut baskets |
| Base-line cushion | 0.050 | Used by the initial/pre-cut ladder, not by the fixed recovery SL |
| Recovery SL milestone distance | 130 price cents = 1.300 | Measured from the intended recovery SL level; trailing is already active before this milestone |
| Winner cut count | 3 | Winning-side open positions needed while opposite losing positions exist |
| Clean trail minimum positions | 3 | Winning-side position count needed, opposite side still empty, before all remaining pendings are cancelled |
| Pre-SL loser cut | 2 positions and 1.650 adverse | Superseded for the managed side once clean trailing is active, or from the moment a winner cut leaves that side surviving |
| Post-cut grace | 0 (disabled) | Widens the survivor's starting protection floor to (grid step + this) behind the cut anchor, once per cut |
| Maximum opening spread | 0.20 | Reject grid creation above this spread |
| Pending cap | 100 | Per symbol/magic; reject a new grid if its full pending count does not fit |
| Minimum margin level | 300% | 0 disables; reject a new grid whose fully filled levels would leave margin level below this |
| Manual lot filter | 0.0 / 0.0 | Both 0 disables; otherwise only manual entries inside this lot range start a grid |
| Concurrent basket cap | 0 | 0 is unlimited; otherwise ignore a manual entry while that many baskets already run |
| Grid retry window | 60s | 0 disables retries; otherwise retry a transiently rejected grid this long, while price stays within one grid step of the entry |
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

A manual Sell mirrors the layout. Grid placement is not transactional: a rejected individual request can leave a partial grid, and rejected levels are not automatically recreated. Pending expiration is GTC by default.

### Adoption and the retry window

A manual position the EA has claimed but placed nothing around is worse than an unclaimed one: no exit rule acts on a lone position, so the claim only hides it from the user. The basket is therefore adopted **after** the grid is placed, and a manual entry that produced no orders stays entirely the user's.

Marking the deal as seen is likewise separate from having built anything. A grid refused for a passing condition - no readable quote, a spread spike, margin briefly tied up, the pending cap momentarily full, or a broker that accepted no level - is queued and retried on later ticks. The queue drops a request when:

- the retry window runs out (default 60 seconds, measured from the first attempt);
- price leaves one grid step of the manual entry, since beyond that the levels would sit behind the market and be refused one at a time, producing a broken grid rather than a late one - drift is measured on the side that would chase the entry, Ask for a Buy and Bid for a Sell;
- the manual position it would hedge is closed.

Refusals that retrying cannot help - no position id, a broker that rewrites order comments, or basket capacity - abandon immediately, withdrawing any orders already placed. The queue lives in memory only: a restart discards it, exactly as a restart today leaves an ungridded manual entry alone.

### Pre-trade margin guard

Nothing downstream ever declines to add a position, so affordability is decided once, before the first pending exists. Grid creation is rejected unless the account could still carry the grid with **every** level filled:

1. Sum `OrderCalcMargin` over the levels each side would open - the same side's levels 2..N, the opposite side's levels 1..N - at their own entry prices and lots. Levels whose lot the broker would reject cost nothing and are skipped; a failed calculation rejects the grid.
2. Take the larger of the two sides when `SYMBOL_MARGIN_HEDGED` is 0, since hedged volume then costs nothing and the sides never both charge margin at once. Otherwise add both sides.
3. Reject when `equity / (current used margin + grid margin) * 100` falls below the configured floor.

The manual position is already funded and is therefore not counted again. A refusal here is transient, so the grid joins the retry queue rather than dying. Setting the floor to 0 disables the guard and restores the previous behaviour of ignoring account margin entirely.

### Manual entry filter

The EA cannot tell a deliberate one-click entry from any other manual trade on the symbol, so the user draws that line with three filters, all shipped disabled:

- **Minimum manual lot** and **maximum manual lot** - a manual entry outside the range is left entirely to the user.
- **Concurrent basket cap** - a manual entry arriving while that many baskets already run is left to the user.

A filtered entry is rejected before any order is placed, so it never enters basket state and is never queued for retry.

### Basket tag verification

Ownership, restart discovery, and attributing a broker SL/TP exit all run through the `G#<root ticket>` order comment, so a broker that rewrites or truncates comments blinds the EA rather than degrading it. After placing a grid the EA reads the tag back off the orders the broker accepted. If any tag differs:

1. Withdraw every order just placed, by the tickets returned at placement time.
2. Alert, and refuse to create any further grid until the EA is restarted.

Orders that cannot be selected yet are not treated as proof of a stripped tag.

## Mode 1: clean winning streak

A clean basket has no opposite-side positions and has not undergone winner cut. The ordinary ladder line first arms as soon as a second position exists on the profitable side (the usual "two positions before trailing" rule - see Shared exits below), but clean mode itself - cancelling every remaining pending order - waits for `InpCleanTrailMinPositions` (default 3): once the profitable side reaches that many positions with the opposite side still empty:

1. Persist the clean-trend decision and protection direction.
2. Delete **all pending orders belonging to this basket**, on both sides - including any of the profitable side's own levels beyond `InpCleanTrailMinPositions` that never got the chance to fill.
3. Retry failed deletions on later ticks without suspending protection.
4. Keep the selected direction authoritative even if its profit later turns negative.
5. Continue price-following trailing without needing more grid fills.

The initial line (armed at two positions, before clean mode itself) uses the previous position's entry plus 0.050 for Buy, or minus 0.050 for Sell. Thereafter the clean candidate follows Bid minus 3.000 for Buy, or Ask plus 3.000 for Sell, retaining whichever line is tighter. An existing tighter stop is never loosened. The legacy armed-ladder candidate may also tighten the line when applicable. No fixed budget target exists in this clean mode.

| Clean Buy example (`InpCleanTrailMinPositions` = 3) | Behavior |
| --- | --- |
| Only Buy at 4000 | No trailing yet |
| Second Buy fills at 4003; Buy side is profitable | Ordinary ladder line arms at 4000.050; pendings (including the 3rd level and beyond) stay live |
| Third Buy fills at 4006 | Latch clean mode now - delete every remaining basket pending, both sides; the 4th/5th Buy levels never get the chance to fill |
| Bid advances to 4009 | Price-following candidate 4006.000; raise SL if it improves the existing line |
| Bid advances to 4010 | Candidate 4007.000; continue trailing |
| Bid returns to the active line | Latch a full-basket market exit and retry until empty |

The previous 2.500 loser-cut rule is skipped for the clean direction once this mode is active, allowing the requested trailing SL to control its pullback exit. Other safety checks remain. A failed cancellation can still fill an order; the latch continues pending retirement and the basket retains protection. It does not silently resume grid expansion.

## Mode 2: winner cut, approach trailing, and recovery SL milestone

Before winner cut, the winning direction is selected by positive aggregate **price advance** - each position's favourable price distance from its own entry, weighted by its lot - and if both sides are positive, the larger one wins. A position counts as losing when its own price advance is negative. Neither figure includes swap or commission: financing cost would otherwise turn a flat position into a loser after a few nights and both mis-select the winning side and trip the safety breaker on carry rather than on price. Logged net figures still report real money (profit plus swap). The count on the winning side is its open-position count, not the number of individually profitable positions.

Winner cut starts when that side has at least three positions and the opposite side has at least one losing position, unless a higher-priority exit has already triggered. It records:

- k: the opposite-side losing-position count at cut time;
- anchor: the newest winning-side position's entry at cut time;
- direction: the surviving side.

It persists the decision before attempting to close every position and pending order on the opposite side, **and deletes the surviving side's own remaining pending orders in the same tick** (as of v1.43 - before, they stayed live until some later exit deleted them, which meant a fill landing on the exact tick that later exit fired raced its own pending cleanup: the broker's fill and the EA's delete could arrive in either order, so that level either opened a position closed again within moments, or was simply cancelled outright without ever opening - "reaches the stop and just cancels" is that race lost). WINNER CUT BUDGET's exit target is fixed relative to the cut anchor the moment the cut fires, so a level filling afterward was never going to matter for long anyway. A failed winning-side pending delete is retried alongside the cut-side retry below. Failed side closes are retried; budget and protection continue in the same tick.

Management of the survivor - trailing, the recovery SL milestone, the post-cut grace floor below - stays dormant until the cut side is confirmed fully clear (no open position, no pending order), so nothing treats a hedge that has not really been removed yet as gone.

### Exact recovery levels

| Quantity | Buy survivor | Sell survivor |
| --- | --- | --- |
| Full-basket budget target | anchor + k * grid step | anchor - k * grid step |
| Intended fixed SL | anchor + (k-1) * grid step | anchor - (k-1) * grid step |
| SL arming quote | Bid >= fixed SL + 2.000 | Ask <= fixed SL - 2.000 |

The arming comparison is inclusive. No 0.050 cushion is added to the recovery SL milestone. Before price actually reaches the intended fixed SL level (anchor for k=1, anchor + (k-1) grid steps for higher k), a post-cut basket trails exactly like an ordinary mixed basket - the same previous-entry/newest-entry ladder, no price-following - so K-mode is never tighter than the no-cut case during that approach (the post-cut grace floor below is the one deliberate exception: it can loosen that starting line once, never tighten it). Only once price reaches that level does price-following take over: Buy follows Bid minus 3.000; Sell follows Ask plus 3.000. The existing ladder candidate and any tighter protection are retained throughout, so the switch can only improve the line, never loosen it. Trailing remains active even with just one surviving position, and it continues after the milestone without moving the SL backward. The milestone is therefore a minimum protection level in the profitable direction, not an instruction to replace a tighter line.

### Post-cut grace floor

The ordinary approach-phase ladder above sits about one grid step behind the survivor's newest entry - identical to an ordinary mixed basket, by design. That is frequently tight enough that normal intra-swing noise, not a real reversal, closes the basket moments after a cut that was otherwise the right call. `InpPostCutGraceCents` (0 = disabled) widens that **starting** line only: the first time the cut side is confirmed clear, if the ladder line in place at that moment is tighter than (grid step + grace) behind the cut anchor, it is loosened out to that floor. It fires at most once per cut - tracked by its own persisted flag, restored across a restart - and every tick after that runs the ordinary approach-phase ladder, arm trigger, and recovery-SL milestone exactly as described above, tightening only, never loosening again. A grace floor that would already be looser than the current line is a no-op; a broker-side stop still installed from before the cut is retained as a fallback exactly as any other line change retains one.

With Buy anchor 4006, grid step 3.000, and `InpPostCutGraceCents` = 200 (2.000): the ordinary ladder would start at roughly 4003.050 (one step back plus the spread buffer); the grace floor instead starts it at 4006 - (3.000 + 2.000) + 0.050 = 4001.050. Price still has to run the same distance to reach the recovery SL milestone (4006 for k=1) and the budget target (4009) - grace only changes how much room the survivor has on the way there, not where those two levels sit.

For example, with Buy anchor 4006 and unchanged Buy entries 4000/4003/4006: for k=1 (intended SL = anchor = 4006), Bid 4005 still trails on the ladder alone (candidate 4003.050, identical to a no-cut basket at that quote); once Bid reaches 4006 price-following joins in, and Bid 4008 arms the milestone at 4006, with the budget still at 4009. For k=2 (intended SL = anchor + 3.000 = 4009), the ladder alone governs all the way through Bid 4008; Bid 4009 brings price-following into the comparison, Bid 4011 arms the milestone at 4009, and the budget still exits at 4012. New fills can produce a tighter ladder candidate on their own, independent of this switch. Only clean mode retires all pending orders; K-mode trailing does not delete surviving-side pending orders.

With anchor 4006 and grid step 3.000:

| Survivor | k | Budget target | Intended SL | First quote that arms SL |
| --- | --- | --- | --- | --- |
| Buy | 1 | Bid 4009 | 4006 | Bid 4008 |
| Buy | 2 | Bid 4012 | 4009 | Bid 4011 |
| Sell | 1 | Ask 4003 | 4006 | Ask 4004 |
| Sell | 2 | Ask 4000 | 4003 | Ask 4001 |

Later fills do not move the saved cut anchor, milestone, or budget target, though they may tighten the actual trailing line. Budget is checked before trailing and the milestone, so a quote that jumps directly past the target starts a full exit immediately.

The loser cut is skipped for the surviving direction from the moment of the cut, not from the later recovery-SL arming. The cut distance is below one grid step by configuration, while the survivor's ladder line sits a full step back, so a live loser cut on that side always fired first - and closing the survivor closes the recovery the cut was paid for. The cut side is still checked, so a failed close that left positions behind is not ignored. Other existing stops and safety exits can still close earlier; the target is not a guaranteed fill or a promise of net profit after banked losses and costs.

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

A settled full exit can keep failing - broker FROZEN, disconnect, requote rejection - while price keeps moving, and by then the recorded protection line is already behind current price (that is what triggered the exit) so the broker would reject re-installing it at that same level. Whenever the market close leaves positions open, a failsafe stop refreshes each one to the tightest level the broker's stop/freeze distance currently allows, moving only tighter than any existing stop and never back. It is not trailing and does not replace the retry itself; it exists purely to bound further loss while the exit keeps being retried. The same failsafe guards a WINNER CUT side-close that fails: the cut side normally carries no SL of its own at all, so a stuck close there would otherwise leave it completely unprotected until the retry eventually succeeds. It is scoped to just that side - the surviving side keeps its own protection line untouched.

A broker SL/TP exit at the formula line is handled in OnTradeTransaction even if price has bounced before the next tick. Ownership uses the manual position identifier or the tagged original opening order. The exit reason, original position direction, and historical DEAL_SL/DEAL_TP must match the current formula line or the retained pre-recovery line with its original direction. The first post-cut trailing change retains that older line before replacing it, and the later milestone does not overwrite it. It can be restored even before the milestone has armed. The retained line covers a delayed modification or a direction change that leaves the older broker SL/TP installed. Unrelated optional stops at other levels do not trigger this callback path.

## Failure handling, restart, and limits

| Case | Behavior |
| --- | --- |
| Failed close or pending deletion during full exit | Retry while the basket still has state; price rebound does not cancel the decision; a failsafe stop refreshes any positions still open toward current price on every retry |
| Failed losing-side close | Retry the saved cut side while continuing budget/protection; a failsafe stop guards that side alone until the retry succeeds |
| Failed winning-side pending delete at cut time | Retried on the same tick as the cut-side retry, until it succeeds |
| Failed SL modification | Keep the intended line and retry; an armed state does not prove the broker accepted every modification |
| No positions left | Delete leftover pending orders; prune the basket when fully empty |
| Restart with complete saved state | Restore the basket, line, market-exit latch, cut data, clean-retirement flag, and recovery-SL flag |
| Older saved state (versions 1-5) | Read supported legacy ownership/protection/cut fields; new flags default to false |
| Incomplete cut state | Cannot restore that budget; terminal discovery does not reconstruct the historical cut decision |
| Formula master false | EA-side decisions/retries stop; already-installed broker SL/TP remain; grid entry handling is separate |
| Terminal offline | EA-side trailing, cancellation and market exits do not run; accepted broker stops remain |
| Tick feed stalled | A one-second timer retries settled basket exits and stuck winner-cut side closes, and refreshes their failsafe stops; no trailing, cut, or breaker decision is taken off the timer, since those need a fresh quote |
| Broker rewrites order comments | Withdraw the orders just placed, alert, and create no further grid until restart |
| Transient grid refusal | Queue the request and retry on later ticks until the window closes, price leaves one grid step of the entry, or the manual position is closed |
| Manual partial close | Remaining positions are still managed; no automatic full exit solely for a manual partial close |

State version 6 stores clean retirement as field C, recovery SL arming as field J, and the retained pre-recovery line/direction as fields Y/Z. State version 7 adds the post-cut grace flag as field F, restored only while a winner cut is still recorded, so a restart cannot re-loosen an already-tightened line. Every actual line change and mode decision is written. Flushing those writes to disk is throttled: latched decisions - market exit, both cuts, clean retirement, recovery SL arming, the post-cut grace floor, and the first arming of a protection line - flush immediately, while a routine trailing step flushes at most once a second, because it repeats on nearly every tick of a trend. An unclean shutdown can therefore lose up to one second of line movement, which would leave a broker SL/TP exit at the newer line unattributed. Persistence uses terminal Global Variables and does not transfer to another terminal automatically.

The basket exit line is also installed as a take profit on the hedge side, and that take profit is only ever moved nearer the market, so an optional per-pending TP is never pushed further away by the basket line.

No equity-percentage or daily-loss limit exists. Stops and targets are price thresholds, not guaranteed fill prices or monetary profit guarantees. Multiple baskets add exposure. Use demo validation for actual execution behavior.

## Verification

Run the deterministic mocked-broker regression checks in MQ5/Tests/stopgrid_exit_tests.cjs and compile the EA with MetaEditor. The harness executes adapted production function bodies but is not a broker integration test, restart durability test, or performance backtest.
