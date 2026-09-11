# StopGrid exit regression checks

Run from the repository root with Node.js:

```powershell
node MQ5/Tests/stopgrid_exit_tests.cjs
```

The harness extracts production MQL5 function bodies and adapts their syntax for execution with a mocked broker. It checks protection triggers, basket ownership, persistent-exit control flow, same-tick winner-cut continuation, clean-trend pending retirement, approach trailing for k=1/k=2, and recovery SL milestones in both directions. It does not place orders or connect to a trading account.

Compile the EA separately in MetaEditor. These checks are not an MT5 integration test or a profitability backtest; broker execution timing, slippage, and terminal restart behavior still need demo validation. Keep `InpUseFormulaClose` enabled to run the basket exit rules and their retries.
