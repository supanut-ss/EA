# XAUUSD One-Click Stop Grid EA

## Deterministic behavior

- Attach `XAUUSD_OneClick_StopGrid_EA.mq5` to the intended gold-symbol chart on an MT5 hedging account.
- A newly filled manual market order (`Magic = 0`) on that chart symbol is the trigger and level 1 of its direction.
- With `InpOrdersPerSide = 5`, a manual buy creates four Buy Stops above the manual fill and five Sell Stops below it. A manual sell creates four Sell Stops below and five Buy Stops above.
- `InpPriceStep` is a direct price distance, not broker points. A value of `1.0` creates levels such as 4000, 4001, and 4002 regardless of quote digits.
- Opening lots use an independent odd-number sequence on each side. With `InpLotFactorStep = 2.0`, the manual side is `1x, 3x, 5x, 7x, 9x`; the opposite pending side restarts at `1x, 3x, 5x, 7x, 9x`.
- The supplied `N = 2k+1` formula applies only to closing. If the Sell side has `k` open positions and its combined floating P/L is negative, the basket closes when the profitable Buy side has at least `2k+1` open positions, every Buy position is strictly above `InpMinWinnerProfitEach` (default `$1.00`), and basket P/L is above `InpCloseMinProfitMoney`. The rule is mirrored when Buy is the losing side.
- When the close rule triggers, the EA deletes the basket's remaining pending orders first and then closes every open position in that basket. Failed deletions or closes are retried on following ticks.

## Safety and limitations

- The EA refuses to initialize on a netting account because independent grid positions require hedging mode.
- Prices and volumes are normalized to the symbol tick size and broker volume step. A level is skipped rather than moved if its intended stop price is already behind the market or violates the broker stop distance.
- `InpStopLossDistance` and `InpTakeProfitDistance` default to zero, meaning no SL or TP. Configure both before live evaluation if bounded per-order risk is required.
- Pending orders are not automatically cancelled when the opposite side triggers. They remain until filled, manually deleted, or expired by `InpExpirationHours`.
- The in-memory duplicate guard prevents repeated processing during one EA run. Existing manual positions are deliberately not multiplied after restart or reattachment.
- Basket tags on EA orders allow formula-close management to be reconstructed after restart while tagged pending orders or positions remain.
- Increasing opening lots are high risk. Verify the maximum generated lot and margin requirement before enabling AutoTrading, then forward-test on a demo account.

## Example

For a manual Buy at 4000 with 0.01 lot, five levels per side, a 1.0 price step, and `InpLotFactorStep = 2.0`:

| Side | Prices | Lots |
| --- | --- | --- |
| Buy | 4000 manual, then Buy Stops at 4001, 4002, 4003, 4004 | 0.01, 0.03, 0.05, 0.07, 0.09 |
| Sell | Sell Stops at 3999, 3998, 3997, 3996, 3995 | 0.01, 0.03, 0.05, 0.07, 0.09 |
