import type { ClosedTrade } from "../types/dashboard";

export function computeTradeStats(trades: ClosedTrade[]) {
  if (trades.length === 0) return { winRatePct: 0, profitFactor: 0 };

  const wins = trades.filter((t) => t.pnl > 0);
  const grossProfit = wins.reduce((sum, t) => sum + t.pnl, 0);
  const grossLoss = Math.abs(trades.filter((t) => t.pnl < 0).reduce((sum, t) => sum + t.pnl, 0));

  const winRatePct = Math.round((wins.length / trades.length) * 100);
  const profitFactor = grossLoss === 0 ? grossProfit : grossProfit / grossLoss;

  return { winRatePct, profitFactor: Math.round(profitFactor * 100) / 100 };
}
