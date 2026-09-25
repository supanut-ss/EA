# StopGrid behavior checks

Run the deterministic 9x9 EA behavior scenarios from the repository root:

```powershell
node MQ5/Tests/stopgrid_9x9_behavior_tests.cjs
```

This harness extracts production functions from `XAUUSD_StopGrid_9x9_EA.mq5` and checks M5 EMA trend classification and RSI-signal filtering, the 15-minute session-close guard, EA-only pending cancellation and position closure, retry behavior across trading-disabled periods, ADX/DI counter-trend blocking, the exact `3-0` gate and trailing behavior, fixed `3-1`/`3-2`/`3-3`/`5-4` exits in both directions, and unmatched cases. It uses a mocked broker and does not replace compiling the EA or running MT5 Strategy Tester.

## MT5 Strategy Tester behavior run

Use `MQ5/Backtest/tester_config_stopgrid_9x9_behavior.ini` with the matching `XAUUSD_StopGrid_9x9_Behavior.set` in the terminal data folder at `MQL5/Profiles/Tester`. The preset uses XAUUSD M1 real ticks, RSI 7 with strict thresholds below 15 and above 85, a closed M5 price-versus-EMA(200) signal filter, ADX 14 with a strong-trend threshold of 40, 9 levels per side, a $2 step, a 0.01 base lot, and a 15-minute session-close guard; risk and spread guards are disabled. The EMA filter blocks RSI signals against the M5 trend but does not change the grid's side count: when ADX is at or below 40, an accepted signal still places both directions; when ADX is strong, the orders must follow the DI direction. Its $50 anchor SL and $100 TP extension are only to let both directions' positions coexist long enough to exercise mixed-side cases; it is not a live-trading profile. Launch MT5 with `/config:<path-to-tester_config_stopgrid_9x9_behavior.ini>`; the report is written to the terminal data folder using the configured report name.

## OneClick StopGrid regression checks

Run from the repository root with Node.js:

```powershell
node MQ5/Tests/stopgrid_exit_tests.cjs
```

The harness extracts production MQL5 function bodies and adapts their syntax for execution with a mocked broker. It checks protection triggers, basket ownership, persistent-exit control flow, same-tick winner-cut continuation, clean-trend pending retirement, approach trailing for k=1/k=2, and recovery SL milestones in both directions. It does not place orders or connect to a trading account.

Compile the EA separately in MetaEditor. These checks are not an MT5 integration test or a profitability backtest; broker execution timing, slippage, and terminal restart behavior still need demo validation. Keep `InpUseFormulaClose` enabled to run the basket exit rules and their retries.
