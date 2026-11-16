//+------------------------------------------------------------------+
//|                                XAUUSD_SessionBreakout_EA.mq5     |
//|  Strategy: Session Range Breakout (XAUUSD, daytrade)             |
//|                                                                  |
//|  Up to 4 independent "setups" per day. All times are broker      |
//|  SERVER time in minutes from 00:00 (Exness server = UTC+0,       |
//|  Thai time = server + 7h).                                       |
//|                                                                  |
//|  Each setup:                                                     |
//|   1) Range = High/Low of M15 bars in [setup - length, setup)     |
//|      (a start before 00:00 reads the previous day's bars)        |
//|   2) At the setup time place a Buy Stop above the range high and |
//|      a Sell Stop below the range low (OCO)                       |
//|   3) SL = min(range width, InpAtrSlMult x ATR(M15)) from entry   |
//|      TP = InpRiskReward x SL distance                            |
//|   4) At the setup's close time its pending orders are cancelled  |
//|      and its open positions are closed                           |
//|  Filters: range too wide/narrow vs ATR(H1), max spread,          |
//|  level-3 USD news (setup 1 only, live only), Friday cutoff.      |
//|  One position at a time; a new setup never stacks on an open one.|
//|                                                                  |
//|  Defaults: setup 1 (12:00, 4h range) and setup 2 (14:00, 2h      |
//|  range) and setup 4 (05:30) ON; setup 3 (00:00) OFF - no edge.   |
//|                                                                  |
//|  NOTE: the MT5 economic calendar API does not work in the        |
//|  Strategy Tester, so the news filter is skipped in backtests.    |
//|  Run in the Strategy Tester on a demo account before live use.   |
//+------------------------------------------------------------------+
#property copyright "Custom EA - Session Range Breakout"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>

CTrade trade;

#define NSETUP 4

//--- Inputs: General
input group "=== General Settings ==="
input double   InpLotSize          = 0.01;      // Fixed Lot Size
input ulong    InpMagicNumber      = 20261114;  // Magic Number
input int      InpSlippage         = 30;        // Slippage (points)
input double   InpMaxSpreadPrice   = 0.20;      // Max Allowed Spread (price units)
input int      InpMaxEntriesPerDay = 2;         // Max filled entries per day (all setups)
input double   InpRiskPercent      = 0.0;       // Risk per trade as % of equity (0 = use fixed lot)
input int      InpMaxLossesPerDay  = 0;         // Stop placing setups after this many losing trades today (0 = off)
input bool     InpAvoidFriday      = true;     // Skip setups placed late on Friday
input int      InpFridayLastMin    = 840;       // Friday: last setup time allowed (minutes, 840 = 14:00)

input group "=== Setup 1 (default: 12:00, range 08:00-12:00) ==="
input bool     InpS1Enable         = true;      // Enable
input int      InpS1SetupMin       = 720;       // Setup time (minutes from 00:00 server)
input int      InpS1RangeMin       = 240;       // Range length (minutes before setup)
input int      InpS1CloseMin       = 960;       // Close time (minutes)

input group "=== Setup 2 (default: 14:00, range 12:00-14:00) ==="
input bool     InpS2Enable         = false;     // Enable (off: S1+S4 tested best for 1-2 trades/day)
input int      InpS2SetupMin       = 840;       // Setup time (minutes)
input int      InpS2RangeMin       = 120;       // Range length (minutes)
input int      InpS2CloseMin       = 960;       // Close time (minutes)

input group "=== Setup 3 (default ON: 07:00 = 14:00 Thai, range 05:00-07:00) ==="
input bool     InpS3Enable         = true;      // Enable
input int      InpS3SetupMin       = 420;       // Setup time (minutes)
input int      InpS3RangeMin       = 120;       // Range length (minutes)
input int      InpS3CloseMin       = 600;       // Close time (minutes)

input group "=== Setup 4 (default ON: 05:30 = 12:30 Thai, range 03:30-05:30) ==="
input bool     InpS4Enable         = true;      // Enable
input int      InpS4SetupMin       = 330;       // Setup time (minutes)
input int      InpS4RangeMin       = 120;       // Range length (minutes)
input int      InpS4CloseMin       = 480;       // Close time (minutes)

input group "=== Entry ==="
input double   InpEntryBufferPrice = 0.10;      // Distance beyond range edge for the stop orders
input int      InpOrderExpiryMin   = 60;        // Cancel unfilled stop orders this many minutes after placement (0 = keep until setup close)

input group "=== Risk / Exit ==="
input ENUM_TIMEFRAMES InpAtrSlTF   = PERIOD_M15; // ATR timeframe for stop distance
input int      InpAtrSlPeriod      = 14;        // ATR period (stop distance)
input double   InpAtrSlMult        = 1.5;       // SL cap = this x ATR (SL = min(range width, cap))
input double   InpMinSlPrice       = 2.0;       // Minimum SL distance (price units)
input double   InpRiskReward       = 3.0;       // TP = this x SL distance
input int      InpDayEndMin        = 960;       // Close everything at/after this time (minutes, 960 = 16:00: before the 21:00 summer break / Friday close and US-holiday early closes seen 16:00-18:00; 0 = off)
input int      InpCloseBeforeSessionMin = 15;   // Close everything this many minutes before the trade session ends (daily break / weekend; 0 = off)
input double   InpBreakevenR       = 0.0;       // Move SL to entry once profit reaches this many R (0 = off)
input double   InpBreakevenLockR   = 0.1;       // ...and lock this many R beyond entry (covers spread)
input double   InpTrailStartR      = 0.0;       // Start trailing once profit reaches this many R (0 = off; real-tick tests favour the fixed 3R TP)
input double   InpTrailDistR       = 1.0;       // Trailing SL distance behind price, in R

input group "=== Filters ==="
input int      InpAtrFilterPeriod  = 14;        // ATR(H1) period for range filter
input double   InpMaxRangeAtrMult  = 2.5;       // Skip setup if range > this x ATR(H1) (0 = off)
input double   InpMinRangeAtrMult  = 0.5;       // Skip setup if range < this x ATR(H1) (0 = off)
input int      InpVolAtrPeriod     = 14;        // Volatility regime: ATR(D1) period
input double   InpMinDailyAtr      = 0.0;       // Skip all setups if ATR(D1) < this many price units (0 = off)
input double   InpMinDailyAtrPct   = 0.0;       // Skip all setups if ATR(D1)/close*100 < this (0 = off)
input bool     InpUseNewsFilter    = true;     // Setup 1: skip if level-3 USD news in window (live only)
input int      InpNewsStartHour    = 12;        // News window start hour (server)
input int      InpNewsEndHour      = 13;        // News window end hour (server, inclusive)

//--- State
int      hAtrSl = INVALID_HANDLE, hAtrH1 = INVALID_HANDLE, hAtrD1 = INVALID_HANDLE;
string   symbolName;
datetime g_dayStamp = 0;
bool     g_done[NSETUP];
bool     g_en[NSETUP];
int      g_setupMin[NSETUP], g_rangeMin[NSETUP], g_closeMin[NSETUP];
int      g_entriesToday = 0;
bool     g_posSeen = false;

//+------------------------------------------------------------------+
double NormalizePriceToTick(double price, int direction)
{
   double tickSize = SymbolInfoDouble(symbolName, SYMBOL_TRADE_TICK_SIZE);
   int digits = (int)SymbolInfoInteger(symbolName, SYMBOL_DIGITS);
   if(tickSize <= 0) tickSize = SymbolInfoDouble(symbolName, SYMBOL_POINT);
   if(tickSize <= 0) return NormalizeDouble(price, digits);
   double ticks = price / tickSize;
   if(direction < 0) ticks = MathFloor(ticks + 1e-9);
   else if(direction > 0) ticks = MathCeil(ticks - 1e-9);
   else ticks = MathRound(ticks);
   return NormalizeDouble(ticks * tickSize, digits);
}

//+------------------------------------------------------------------+
double NormalizeVolume(double volume)
{
   double minV = SymbolInfoDouble(symbolName, SYMBOL_VOLUME_MIN);
   double maxV = SymbolInfoDouble(symbolName, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(symbolName, SYMBOL_VOLUME_STEP);
   if(step <= 0 || minV <= 0 || maxV <= 0) return 0;
   if(volume < minV || volume > maxV) return 0;
   double v = NormalizeDouble(MathFloor((volume + 1e-12) / step) * step, 8);
   return (v < minV) ? 0 : v;
}

//+------------------------------------------------------------------+
// Number of losing closed trades of this EA since the start of the day
int LossesToday(datetime dayStart)
{
   if(!HistorySelect(dayStart, TimeCurrent())) return 0;
   int losses = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0) continue;
      if(HistoryDealGetInteger(tk, DEAL_MAGIC) != (long)InpMagicNumber) continue;
      if(HistoryDealGetString(tk, DEAL_SYMBOL) != symbolName) continue;
      if(HistoryDealGetInteger(tk, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      double p = HistoryDealGetDouble(tk, DEAL_PROFIT) + HistoryDealGetDouble(tk, DEAL_SWAP) +
                 HistoryDealGetDouble(tk, DEAL_COMMISSION);
      if(p < 0) losses++;
   }
   return losses;
}

//+------------------------------------------------------------------+
datetime DayStart(datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
}

//+------------------------------------------------------------------+
//| Minutes until the current trade session ends, -1 if the market   |
//| is closed now or the session runs on past midnight.              |
//+------------------------------------------------------------------+
int MinutesToSessionEnd(datetime now)
{
   MqlDateTime dt;
   TimeToStruct(now, dt);
   int secOfDay = dt.hour * 3600 + dt.min * 60 + dt.sec;
   datetime from, to;
   for(uint i = 0; SymbolInfoSessionTrade(symbolName, (ENUM_DAY_OF_WEEK)dt.day_of_week, i, from, to); i++)
   {
      int f = (int)from, t = (int)to;
      if(t <= f) t += 86400;                     // session listed as wrapping past midnight
      if(secOfDay < f || secOfDay >= t) continue;
      if(t < 86400) return (t - secOfDay) / 60;  // ends today (daily break or weekend close)
      // Runs to midnight: it only really ends if the next day has no session starting at 00:00
      int next = (dt.day_of_week + 1) % 7;
      datetime nf, nt;
      for(uint j = 0; SymbolInfoSessionTrade(symbolName, (ENUM_DAY_OF_WEEK)next, j, nf, nt); j++)
         if((int)nf == 0) return -1;
      return (86400 - secOfDay) / 60;
   }
   return -1;
}

//+------------------------------------------------------------------+
//| True when nothing may be held: past the day cutoff or about to   |
//| hit a session end (daily break, weekend).                        |
//+------------------------------------------------------------------+
bool MustBeFlat(datetime now, int nowMin)
{
   if(InpDayEndMin > 0 && nowMin >= InpDayEndMin) return true;
   if(InpCloseBeforeSessionMin > 0)
   {
      int left = MinutesToSessionEnd(now);
      if(left >= 0 && left <= InpCloseBeforeSessionMin) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
double ReadAtr(int handle)
{
   double buf[1];
   if(CopyBuffer(handle, 0, 1, 1, buf) != 1) return 0;   // last closed bar
   return buf[0];
}

//+------------------------------------------------------------------+
string Tag(int i) { return "SB" + IntegerToString(i + 1); }

//+------------------------------------------------------------------+
//| Pending orders of this EA (tag "" = all setups)                  |
//+------------------------------------------------------------------+
int CountPendingOrders(string tag = "")
{
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0 || !OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbolName) continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      if(tag != "" && StringFind(OrderGetString(ORDER_COMMENT), tag) < 0) continue;
      n++;
   }
   return n;
}

//+------------------------------------------------------------------+
void CancelPendingOrders(string tag = "")
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0 || !OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbolName) continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      if(tag != "" && StringFind(OrderGetString(ORDER_COMMENT), tag) < 0) continue;
      if(!trade.OrderDelete(t))
         PrintFormat("OrderDelete %I64u failed: %d", t, trade.ResultRetcode());
   }
}

//+------------------------------------------------------------------+
bool HasOpenPosition(string tag = "")
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbolName) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(tag != "" && StringFind(PositionGetString(POSITION_COMMENT), tag) < 0) continue;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Breakeven / trailing. R = initial SL distance, recovered from the |
//| fixed TP (TP = R x InpRiskReward), so no per-position state.      |
//+------------------------------------------------------------------+
void ManageExits()
{
   if(InpBreakevenR <= 0 && InpTrailStartR <= 0) return;
   double tick  = SymbolInfoDouble(symbolName, SYMBOL_TRADE_TICK_SIZE);
   double point = SymbolInfoDouble(symbolName, SYMBOL_POINT);
   double minGap = (double)SymbolInfoInteger(symbolName, SYMBOL_TRADE_STOPS_LEVEL) * point;
   double freeze = (double)SymbolInfoInteger(symbolName, SYMBOL_TRADE_FREEZE_LEVEL) * point;
   minGap = MathMax(minGap, freeze);
   if(tick <= 0) tick = point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbolName) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      bool   isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      if(tp <= 0 || InpRiskReward <= 0) continue;
      double R = MathAbs(tp - open) / InpRiskReward;
      if(R <= 0) continue;

      double px     = isBuy ? SymbolInfoDouble(symbolName, SYMBOL_BID) : SymbolInfoDouble(symbolName, SYMBOL_ASK);
      double profit = isBuy ? px - open : open - px;
      double newSL  = sl;

      if(InpBreakevenR > 0 && profit >= InpBreakevenR * R)
      {
         double be = isBuy ? open + InpBreakevenLockR * R : open - InpBreakevenLockR * R;
         if(isBuy ? (be > newSL) : (newSL <= 0 || be < newSL)) newSL = be;
      }
      if(InpTrailStartR > 0 && profit >= InpTrailStartR * R)
      {
         double tr = isBuy ? px - InpTrailDistR * R : px + InpTrailDistR * R;
         if(isBuy ? (tr > newSL) : (newSL <= 0 || tr < newSL)) newSL = tr;
      }

      newSL = NormalizePriceToTick(newSL, isBuy ? -1 : +1);
      if(MathAbs(newSL - sl) < tick * 0.5) continue;                 // nothing to change
      if(isBuy ? (px - newSL <= minGap) : (newSL - px <= minGap)) continue;  // too close to price
      if(!trade.PositionModify(tk, newSL, tp))
         PrintFormat("PositionModify %I64u failed: %d", tk, trade.ResultRetcode());
   }
}

//+------------------------------------------------------------------+
//| Late breakouts barely pay after costs: drop stop orders that have |
//| waited longer than InpOrderExpiryMin. Uses the order's own setup  |
//| time, so it also works after an EA restart.                       |
//+------------------------------------------------------------------+
void CancelExpiredOrders()
{
   if(InpOrderExpiryMin <= 0) return;
   datetime now = TimeCurrent();
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0 || !OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbolName) continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      if(now - (datetime)OrderGetInteger(ORDER_TIME_SETUP) < InpOrderExpiryMin * 60) continue;
      if(!trade.OrderDelete(t))
         PrintFormat("Expired order %I64u delete failed: %d", t, trade.ResultRetcode());
   }
}

//+------------------------------------------------------------------+
// A position left over from an earlier day (e.g. a failed close)
bool HasPositionOpenedBefore(datetime t)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbolName) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if((datetime)PositionGetInteger(POSITION_TIME) < t) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
void ClosePositions(string tag = "")
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbolName) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(tag != "" && StringFind(PositionGetString(POSITION_COMMENT), tag) < 0) continue;
      if(!trade.PositionClose(t))
         PrintFormat("PositionClose %I64u failed: %d", t, trade.ResultRetcode());
   }
}

//+------------------------------------------------------------------+
//| Range from M15 bars in [dayStart+startMin, dayStart+endMin).     |
//| startMin may be negative (previous day). Needs >= 80% of bars.   |
//+------------------------------------------------------------------+
bool BuildRange(datetime dayStart, int startMin, int endMin, double &hi, double &lo)
{
   datetime from = dayStart + startMin * 60;
   datetime to   = dayStart + endMin * 60 - 1;
   MqlRates rates[];
   int n = CopyRates(symbolName, PERIOD_M15, from, to, rates);
   int expected = (endMin - startMin) / 15;
   if(expected <= 0 || n < (int)(expected * 0.8)) return false;
   hi = rates[0].high;
   lo = rates[0].low;
   for(int i = 1; i < n; i++)
   {
      if(rates[i].high > hi) hi = rates[i].high;
      if(rates[i].low  < lo) lo = rates[i].low;
   }
   return (hi > lo);
}

//+------------------------------------------------------------------+
//| Level-3 USD event inside the news window today (live only)       |
//+------------------------------------------------------------------+
bool HasHighImpactNews(datetime dayStart)
{
   if(!InpUseNewsFilter || MQLInfoInteger(MQL_TESTER)) return false;
   MqlCalendarValue values[];
   datetime from = dayStart + InpNewsStartHour * 3600;
   datetime to   = dayStart + (InpNewsEndHour + 1) * 3600 - 1;
   int n = CalendarValueHistory(values, from, to, NULL, "USD");
   if(n <= 0) return false;
   for(int i = 0; i < n; i++)
   {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev)) continue;
      if(ev.importance == CALENDAR_IMPORTANCE_HIGH) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Place the OCO stop pair for setup index idx                      |
//+------------------------------------------------------------------+
void PlaceSetup(datetime dayStart, int idx)
{
   double hi, lo;
   if(!BuildRange(dayStart, g_setupMin[idx] - g_rangeMin[idx], g_setupMin[idx], hi, lo))
   {
      PrintFormat("%s skip: not enough bars to build the range", Tag(idx));
      return;
   }

   double atrH1 = ReadAtr(hAtrH1);
   double atrSl = ReadAtr(hAtrSl);
   if(atrH1 <= 0 || atrSl <= 0)
   {
      PrintFormat("%s skip: ATR not ready", Tag(idx));
      return;
   }

   // Volatility regime filter: last closed D1 ATR (absolute and/or % of price)
   if(InpMinDailyAtr > 0 || InpMinDailyAtrPct > 0)
   {
      double atrD1 = ReadAtr(hAtrD1);
      double ref   = iClose(symbolName, PERIOD_D1, 1);
      if(atrD1 <= 0 || ref <= 0)
      {
         PrintFormat("%s skip: daily ATR not ready", Tag(idx));
         return;
      }
      if((InpMinDailyAtr > 0 && atrD1 < InpMinDailyAtr) ||
         (InpMinDailyAtrPct > 0 && atrD1 / ref * 100.0 < InpMinDailyAtrPct))
      {
         PrintFormat("%s skip: low volatility regime, ATR(D1) %.2f (%.2f%%)", Tag(idx), atrD1, atrD1 / ref * 100.0);
         return;
      }
   }

   double width = hi - lo;
   if(InpMaxRangeAtrMult > 0 && width > InpMaxRangeAtrMult * atrH1)
   {
      PrintFormat("%s skip: range %.2f wider than %.1f x ATR(H1) %.2f", Tag(idx), width, InpMaxRangeAtrMult, atrH1);
      return;
   }
   if(InpMinRangeAtrMult > 0 && width < InpMinRangeAtrMult * atrH1)
   {
      PrintFormat("%s skip: range %.2f narrower than %.1f x ATR(H1) %.2f", Tag(idx), width, InpMinRangeAtrMult, atrH1);
      return;
   }
   if(idx == 0 && HasHighImpactNews(dayStart))
   {
      Print("SB1 skip: level-3 USD news inside the news window");
      return;
   }

   double ask = SymbolInfoDouble(symbolName, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbolName, SYMBOL_BID);
   if(ask <= 0 || bid <= 0 || ask - bid > InpMaxSpreadPrice)
   {
      PrintFormat("%s skip: spread %.3f above limit", Tag(idx), ask - bid);
      return;
   }

   double slDist = MathMin(width, InpAtrSlMult * atrSl);
   slDist = MathMax(slDist, InpMinSlPrice);
   double tpDist = slDist * InpRiskReward;

   // Fixed lot, or lot sized so that hitting SL loses InpRiskPercent of equity
   double lotWanted = InpLotSize;
   if(InpRiskPercent > 0)
   {
      double contract = SymbolInfoDouble(symbolName, SYMBOL_TRADE_CONTRACT_SIZE);
      if(contract > 0)
         lotWanted = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPercent / 100.0 / (slDist * contract);
      // Clamp to broker limits (the minimum lot may risk more than requested)
      lotWanted = MathMax(lotWanted, SymbolInfoDouble(symbolName, SYMBOL_VOLUME_MIN));
      lotWanted = MathMin(lotWanted, SymbolInfoDouble(symbolName, SYMBOL_VOLUME_MAX));
   }
   double vol = NormalizeVolume(lotWanted);
   if(vol <= 0)
   {
      Print("Skip: invalid lot size");
      return;
   }

   double buyPrice  = NormalizePriceToTick(hi + InpEntryBufferPrice, +1);
   double sellPrice = NormalizePriceToTick(lo - InpEntryBufferPrice, -1);

   // Stop orders must sit beyond the market; if price already ran past the edge, skip
   long stopsLevel = SymbolInfoInteger(symbolName, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist  = stopsLevel * SymbolInfoDouble(symbolName, SYMBOL_POINT);
   if(buyPrice <= ask + minDist || sellPrice >= bid - minDist)
   {
      PrintFormat("%s skip: price already outside the range at setup time", Tag(idx));
      return;
   }

   double buySL  = NormalizePriceToTick(buyPrice  - slDist, -1);
   double buyTP  = NormalizePriceToTick(buyPrice  + tpDist, +1);
   double sellSL = NormalizePriceToTick(sellPrice + slDist, +1);
   double sellTP = NormalizePriceToTick(sellPrice - tpDist, -1);

   string cmt = Tag(idx);
   bool okBuy = trade.BuyStop(vol, buyPrice, symbolName, buySL, buyTP, ORDER_TIME_GTC, 0, cmt);
   if(!okBuy) PrintFormat("BuyStop failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
   bool okSell = trade.SellStop(vol, sellPrice, symbolName, sellSL, sellTP, ORDER_TIME_GTC, 0, cmt);
   if(!okSell) PrintFormat("SellStop failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());

   // Never leave a lone half of the pair if the other side was rejected
   if(okBuy != okSell) CancelPendingOrders(cmt);

   PrintFormat("%s placed: range %.2f-%.2f width %.2f SL %.2f TP %.2f", cmt, lo, hi, width, slDist, tpDist);
}

//+------------------------------------------------------------------+
int OnInit()
{
   symbolName = _Symbol;

   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("Initialization failed: requires a hedging account so positions can be isolated by magic number.");
      return INIT_FAILED;
   }

   g_en[0] = InpS1Enable; g_setupMin[0] = InpS1SetupMin; g_rangeMin[0] = InpS1RangeMin; g_closeMin[0] = InpS1CloseMin;
   g_en[1] = InpS2Enable; g_setupMin[1] = InpS2SetupMin; g_rangeMin[1] = InpS2RangeMin; g_closeMin[1] = InpS2CloseMin;
   g_en[2] = InpS3Enable; g_setupMin[2] = InpS3SetupMin; g_rangeMin[2] = InpS3RangeMin; g_closeMin[2] = InpS3CloseMin;
   g_en[3] = InpS4Enable; g_setupMin[3] = InpS4SetupMin; g_rangeMin[3] = InpS4RangeMin; g_closeMin[3] = InpS4CloseMin;

   for(int i = 0; i < NSETUP; i++)
   {
      if(!g_en[i]) continue;
      if(g_setupMin[i] < 0 || g_setupMin[i] >= 1440 || g_rangeMin[i] < 15 ||
         g_closeMin[i] <= g_setupMin[i] || g_closeMin[i] > 1439)
      {
         PrintFormat("Initialization failed: invalid times for setup %d", i + 1);
         return INIT_PARAMETERS_INCORRECT;
      }
   }
   if(InpLotSize <= 0 || InpMaxEntriesPerDay < 1 || InpAtrSlPeriod < 2 || InpAtrFilterPeriod < 2 ||
      InpAtrSlMult <= 0 || InpRiskReward <= 0 || InpMinSlPrice < 0 || InpEntryBufferPrice < 0 ||
      InpDayEndMin < 0 || InpDayEndMin >= 1440 || InpCloseBeforeSessionMin < 0 ||
      InpBreakevenR < 0 || InpTrailStartR < 0 || (InpTrailStartR > 0 && InpTrailDistR <= 0) ||
      InpOrderExpiryMin < 0)
   {
      Print("Initialization failed: invalid input(s)");
      return INIT_PARAMETERS_INCORRECT;
   }

   hAtrSl = iATR(symbolName, InpAtrSlTF, InpAtrSlPeriod);
   hAtrH1 = iATR(symbolName, PERIOD_H1, InpAtrFilterPeriod);
   hAtrD1 = iATR(symbolName, PERIOD_D1, InpVolAtrPeriod);
   if(hAtrSl == INVALID_HANDLE || hAtrH1 == INVALID_HANDLE || hAtrD1 == INVALID_HANDLE)
   {
      Print("Failed to create ATR handle(s)");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(symbolName);

   // Restart safety: setups whose placement window already passed are not placed late
   datetime now = TimeCurrent();
   g_dayStamp = DayStart(now);
   MqlDateTime dt;
   TimeToStruct(now, dt);
   int nowMin = dt.hour * 60 + dt.min;
   for(int i = 0; i < NSETUP; i++)
      g_done[i] = (nowMin >= g_setupMin[i] + 30);
   g_posSeen = HasOpenPosition();
   g_entriesToday = g_posSeen ? 1 : 0;
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hAtrSl != INVALID_HANDLE) IndicatorRelease(hAtrSl);
   if(hAtrH1 != INVALID_HANDLE) IndicatorRelease(hAtrH1);
   if(hAtrD1 != INVALID_HANDLE) IndicatorRelease(hAtrD1);
}

//+------------------------------------------------------------------+
void OnTick()
{
   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   datetime today = DayStart(now);
   int nowMin = dt.hour * 60 + dt.min;

   if(today != g_dayStamp)
   {
      g_dayStamp = today;
      g_entriesToday = 0;
      g_posSeen = false;
      for(int i = 0; i < NSETUP; i++) g_done[i] = false;
   }

   // Never hold through a day change or a market close: flatten and stop for the day
   if(MustBeFlat(now, nowMin) || HasPositionOpenedBefore(today))
   {
      if(CountPendingOrders() > 0) CancelPendingOrders();
      if(HasOpenPosition())
      {
         PrintFormat("Force close: day end / session end (%02d:%02d)", dt.hour, dt.min);
         ClosePositions();
      }
      if(MustBeFlat(now, nowMin))
      {
         for(int i = 0; i < NSETUP; i++) g_done[i] = true;
         g_posSeen = HasOpenPosition();
         return;
      }
   }

   // Count fills and enforce OCO: once a position exists, remove pending orders
   CancelExpiredOrders();
   ManageExits();
   bool hasPos = HasOpenPosition();
   if(hasPos && !g_posSeen) g_entriesToday++;
   g_posSeen = hasPos;
   if(hasPos && CountPendingOrders() > 0) CancelPendingOrders();

   // Per-setup close time: cancel its pending orders and close its positions
   for(int i = 0; i < NSETUP; i++)
   {
      if(!g_en[i] || nowMin < g_closeMin[i] || nowMin < g_setupMin[i]) continue;
      string tg = Tag(i);
      if(CountPendingOrders(tg) > 0) CancelPendingOrders(tg);
      if(HasOpenPosition(tg)) ClosePositions(tg);
      g_done[i] = true;
   }

   if(dt.day_of_week == 0 || dt.day_of_week == 6) return;
   if(g_entriesToday >= InpMaxEntriesPerDay) return;

   // Setup placement: a 30 minute window starting at the setup time
   for(int i = 0; i < NSETUP; i++)
   {
      if(!g_en[i] || g_done[i]) continue;
      if(nowMin < g_setupMin[i]) continue;
      g_done[i] = true;                          // one attempt, success or skip
      if(nowMin >= g_setupMin[i] + 30) continue; // missed the window
      if(InpAvoidFriday && dt.day_of_week == 5 && g_setupMin[i] > InpFridayLastMin) continue;
      if(HasOpenPosition()) continue;            // never stack on an open position
      if(InpMaxLossesPerDay > 0 && LossesToday(today) >= InpMaxLossesPerDay)
      {
         PrintFormat("%s skip: daily loss limit reached", Tag(i));
         continue;
      }
      if(CountPendingOrders() > 0) CancelPendingOrders();   // replace an unfilled older pair
      PlaceSetup(today, i);
      break;                                     // at most one setup per tick
   }
}
//+------------------------------------------------------------------+
