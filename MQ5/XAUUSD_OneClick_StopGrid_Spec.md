# XAUUSD One-Click Stop Grid EA

## Deterministic behavior

- Attach `XAUUSD_OneClick_StopGrid_EA.mq5` to the intended gold-symbol chart on an MT5 hedging account.
- A newly filled manual market order (`Magic = 0`) on that chart symbol is the trigger and level 1 of its direction.
- With `InpOrdersPerSide = 5`, a manual buy creates four Buy Stops above the manual fill and five Sell Stops below it. A manual sell creates four Sell Stops below and five Buy Stops above.
- `InpPriceStepCents` uses price cents rather than broker points. Its default `200` is a direct `2.000` price distance and creates levels such as 4000, 4002, and 4004 regardless of quote digits.
- Opening lots use an independent odd-number sequence on each side. With `InpLotFactorStep = 2.0`, the manual side is `1x, 3x, 5x, 7x, 9x`; the opposite pending side restarts at `1x, 3x, 5x, 7x, 9x`.
- The supplied `N = 2k+1` formula now arms basket protection rather than closing at market. If the Sell side has `k` losing positions, the profitable Buy side has at least `2k+1` positions, and basket P/L is above `InpCloseMinProfitMoney`, the EA can arm the protection line. The rule is mirrored when Buy is losing.
- `InpBEPriceDistance = 1.0` is a direct price distance. If the last Buy winner opened at 4000, Bid must move above 4001 and the protected basket-exit line is 4001. For Sell, the mirrored line is 3999 after Ask moves below it.
- `InpConsecutiveWinners = 3` allows the same protection after three qualifying consecutive positions without waiting for a larger `2k+1` count.
- When protection arms, the EA deletes every remaining tagged pending order. Winning-direction positions receive an SL at the common protection price; opposite-direction positions receive a TP at the same price because MT5 cannot place their SL on the other side of the current market. Modification failures are retried on following ticks.

## Safety and limitations

### Exit safety and persistence

- The EA has no automatic maximum-loss ceiling, basket liquidation, or daily-loss protection. It never closes a position at market because of loss; `InpStopLossDistance` is the only optional loss exit created for each EA pending order, and its default `0.0` disables that SL.
- Formula BE protection is the only portfolio-management path. After its documented winner-count, winner-distance, minimum-net-profit, and market-beyond-protection conditions arm, it deletes only that basket's tagged pending orders and modifies owned positions with the common SL/TP line; it does not submit a market close.
- Basket ownership and valid formula-protection state persist through restart. Version 1.21 ignores and removes legacy percentage, fixed-loss, daily-loss, and liquidation fields, so attaching it cannot resume an old risk-triggered closure.
- Use one EA instance per account/server/symbol/magic scope. Persistence uses terminal Global Variables; copying the EA to another terminal or deleting these variables does not transfer or preserve saved basket state.
- With formula management disabled and no per-order SL, open positions have no EA-managed automatic loss exit. Increasing grid lots can therefore create unbounded losses; evaluate only in an isolated demo/test environment until independently validated.

- The EA refuses to initialize on a netting account because independent grid positions require hedging mode.
- Prices and volumes are normalized to the symbol tick size and broker volume step. A level is skipped rather than moved if its intended stop price is already behind the market or violates the broker stop distance.
- `InpStopLossDistance` and `InpTakeProfitDistance` default to zero, meaning no SL or TP. Configure both before live evaluation if bounded per-order risk is required.
- Pending orders are not automatically cancelled merely because the opposite side triggers. They remain until filled, deleted by formula basket protection or manually, or expired by `InpExpirationHours`.
- The in-memory duplicate guard prevents repeated processing during one EA run. Existing manual positions are deliberately not multiplied after restart or reattachment.
- Basket tags and persisted adopted-root records allow management to be reconstructed after restart, including a tracked basket whose only remaining position is its manual root.
- Increasing opening lots are high risk. Verify the maximum generated lot and margin requirement before enabling AutoTrading, then forward-test on a demo account.

## Example

For a manual Buy at 4000 with 0.01 lot, five levels per side, `InpPriceStepCents = 200`, and `InpLotFactorStep = 2.0`:

| Side | Prices | Lots |
| --- | --- | --- |
| Buy | 4000 manual, then Buy Stops at 4002, 4004, 4006, 4008 | 0.01, 0.03, 0.05, 0.07, 0.09 |
| Sell | Sell Stops at 3998, 3996, 3994, 3992, 3990 | 0.01, 0.03, 0.05, 0.07, 0.09 |

With a standard 100-ounce XAUUSD contract, three straight Buy winners at 4000/4002/4004 and a close just above 4005 produce approximately `$5 + $9 + $5 = $19` gross before spread, commission, swap, slippage, and any opposite-side loss.
