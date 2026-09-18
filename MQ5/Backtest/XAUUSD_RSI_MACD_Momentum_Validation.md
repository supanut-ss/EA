# XAUUSD RSI/MACD Momentum EA validation

Validation date: 2026-09-18

Environment: Exness-MT5Trial8, XAUUSD, M1 Strategy Tester chart, USD 1,000 deposit, 1:100 leverage, real ticks for final verification.

## Selected candidate

- RSI extreme: 10/90
- BB width threshold: 50% of trailing average
- RSI divergence minimum gap: 3
- Confirm timeframe: M1
- MACD cross lookback: 1 closed bar
- OBV lookback: 3
- ATR stop multiple: 1.0
- Take-profit multiple: 2.5R

| Segment | Dates | Trades | Net profit | Profit factor | Expected payoff | Max equity drawdown |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| In-sample | 2026-01-01 to 2026-06-30 | 30 | $44.94 | 1.27 | $1.50 | 8.59% |
| Out-of-sample | 2026-07-01 to 2026-09-16 | 9 | $20.84 | 1.57 | $2.32 | 3.49% |

The out-of-sample trade count is too small for a live-readiness conclusion. Treat the EA as a backtest candidate and run longer walk-forward and demo-forward tests before operational use.

The raw HTML reports remain in the local MT5 data folder and are not versioned in this repository:

- `XAUUSD_RSI_MACD_Momentum_Candidate_InSample_Report.htm` — SHA-256 `71DD51DBB757EC47A50C38B648D5324E944FD46CE1C4C98283F79112CCBAFC64`
- `XAUUSD_RSI_MACD_Momentum_Candidate_OutSample_Report.htm` — SHA-256 `54EBF90BE57868950ED2788991C65BEFCC75EFBE94E1A198F307F9E7A6D71593`

This limits independent auditability from Git alone; rerun the committed configs to regenerate complete reports for another broker or data build.

## Rejected variants

- RSI 15/85 and RSI 10/90 produced the same 49 divergence-only trades under the loose-filter test. Results were negative (`-$26.15`, PF `0.90` and `-$26.32`, PF `0.90`), so broadening RSI did not improve frequency or expectancy.
- The BB 10% / OBV 7 / MACD lookback 3 / TP 2.0R variant made `$49.70` with PF `2.39` on the out-of-sample segment, but lost `-$38.00` with PF `0.80` on the in-sample segment. It was rejected as regime-sensitive.
- The M1 OHLC optimization leader made `$75.24` with PF `1.47` in screening. Its real-tick out-of-sample result fell to `$20.84` with PF `1.57`, which is why final selection uses real-tick evidence rather than the screening score.

## Complete real-tick optimization rerun (2026-09-18)

MT5 completed all 243 configured passes on `Exness-MT5Real8` for the
2026-01-01 to 2026-06-30 in-sample window. The highest balance/drawdown result
used MACD cross lookback 2 or 3, ATR stop 1.25, and TP 2.5R:

| Segment | Parameters | Trades | Net profit | Profit factor | Expected payoff | Max equity drawdown |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| In-sample | MACD LB 2/3, ATR 1.25, TP 2.5R | 20 | $92.78 | 2.02 | $4.64 | 5.25% |
| Out-of-sample | MACD LB 2, ATR 1.25, TP 2.5R | 6 | $19.81 | 1.85 | $3.30 | 3.74% |

The out-of-sample check used a two-pass optimization-mode run because normal
single-test mode repeatedly failed local-agent authorization on this host. MACD
lookbacks 2 and 3 produced identical results. The sample remains too small to
promote these parameters, so the current EA defaults remain unchanged. Do not
compare these figures directly with the earlier `Exness-MT5Trial8` results: the
rerun used `Exness-MT5Real8`, and feed differences can change fills and signals.

This OOS window has now been consumed by the lookback 2-versus-3 check. It must
not be reused for further parameter selection; use a later untouched holdout or
a rolling walk-forward before considering promotion.

All nine RSI 10/15/20 and 80/85/90 combinations were identical for each core
parameter set. The RSI-threshold dimensions were behaviorally inactive in this
grid; optimizing them added no information. Trigger A and Trigger B can overlap,
so trigger-specific counts or decision traces are required before attributing
the trades to divergence alone.

The raw XML reports remain in the local MT5 data folder and are not versioned:

- `XAUUSD_RSI_MACD_Momentum_Optimize_InSample.xml` — SHA-256 `D356C91E5C4931C23B39EE0D74992BF4C4711B422A6220E00932423C6F0540B0`
- `XAUUSD_RSI_MACD_Momentum_OptWinner_OutSample_Optimization.xml` — SHA-256 `29B4D95C75CBF559E12CEB2026378755402DD2ED3DA4C122DFD44F5BCA6F1CC4`

## Reproduction

- In-sample: `tester_config_rsi_macd_momentum_insample.ini`
- Out-of-sample: `tester_config_rsi_macd_momentum_outsample.ini`
- Two-year follow-up: `tester_config_rsi_macd_momentum_2y.ini`
- Bounded optimization: `tester_config_rsi_macd_momentum_optimize.ini`
- Optimization-winner OOS check: `tester_config_rsi_macd_momentum_outsample_optwinner_optimization.ini`
