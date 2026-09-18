//+------------------------------------------------------------------+
//|                            XAUUSD_RSI_MACD_Momentum_EA.mq5       |
//|  Strategy: RSI + MACD + Bollinger Bands + OBV momentum system.   |
//|            Entry + real SL + real TP (ATR-based, fixed R:R). No  |
//|            trailing/partial-close/runner management yet.         |
//|                                                                    |
//|  Bias   (H1):  MACD(7,26,9) line/signal/histogram all agree.     |
//|  Trigger(M15): RSI(7) extreme (<=10 / >=90) OR RSI divergence    |
//|                vs the last two M15 swing points (same direction  |
//|                as Bias only - no countertrend divergence trades),|
//|                both gated by a Bollinger Bands width filter that |
//|                refuses to trade a squeezed/sideways market.      |
//|  Confirm(M1 default): a recent MACD(7,26,9) cross in Bias's      |
//|                AND OBV agreeing with price's recent direction.   |
//|                                                                    |
//|  DELIBERATE v1 SCOPE - NOT AN OVERSIGHT:                          |
//|   - A REAL broker-side SL order IS sent on every entry, at        |
//|     ATR(14) M15 distance from the entry price. This was added    |
//|     after an initial no-SL backtest (2026.01.01-09.16) measured   |
//|     -52% max drawdown and a single -$165 loss on a $1000 account |
//|     - empirical proof that "no SL" was too dangerous even for a  |
//|     demo account, so this version always protects every position.|
//|   - A REAL TP order is also sent (InpUseTp, default on) at        |
//|     InpTpRrMultiple x the SL distance, added so a winning trade   |
//|     actually locks in profit instead of only ever exiting via SL |
//|     or the flatten guard (floating profit was evaporating before |
//|     any real exit happened). No trailing/partial-close/runner    |
//|     management beyond this fixed TP yet.                          |
//|   The session/Friday/weekend flatten guard below is an ADDITIONAL|
//|     safety net (bounds overnight/weekend exposure), not the sole |
//|     protection - the real SL/TP pair is the primary one.          |
//|   - Concurrent positions are capped by InpMaxOpenPositions       |
//|     (default 1) to bound aggregate exposure.                      |
//|                                                                    |
//|  Point convention matches the sibling XAUUSD_SMC_DayTrade_EA.mq5: |
//|  1 point = $0.01 of XAUUSD price always (100 points = $1 move).  |
//|                                                                    |
//|  IMPORTANT: not compiled/backtested until this session's own      |
//|  verification pass. Run metaeditor64.exe /compile, then verify   |
//|  in Strategy Tester before any demo/live use. This is not         |
//|  investment advice.                                               |
//+------------------------------------------------------------------+
#property copyright "Custom EA - RSI/MACD Momentum"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

CTrade trade;

#define SWING_CAP 40

//==================== INPUTS ====================
input group "=== General Settings ==="
input ulong  InpMagicNumber          = 20260918;  // Magic Number
input int    InpSlippage             = 30;        // Slippage (points, 0.01 USD units)
input int    InpMaxOpenPositions     = 1;         // Max concurrent EA positions (hedging accounts)
input int    InpMaxTradesPerDay      = 10;        // Daily entry cap

input group "=== Bias (H1 MACD) ==="
input int    InpMacdFastEma          = 7;         // MACD fast EMA period
input int    InpMacdSlowEma          = 26;        // MACD slow EMA period
input int    InpMacdSignal           = 9;         // MACD signal period

input group "=== BB Width Filter (M15) ==="
input int    InpBbPeriod             = 20;        // Bollinger Bands period
input double InpBbDeviation          = 2.0;       // Bollinger Bands deviation
input int    InpBbWidthAvgLookback   = 50;        // Trailing bars for BB-width average
input double InpBbWidthSqueezePct    = 50.0;      // Min % of trailing avg BB width to allow a trigger

input group "=== Trigger A - RSI Extreme (M15) ==="
input int    InpRsiPeriod            = 7;         // RSI period (shared: trigger + divergence)
input double InpRsiExtremeLow        = 10.0;      // RSI <= this qualifies a Buy
input double InpRsiExtremeHigh       = 90.0;      // RSI >= this qualifies a Sell

input group "=== Trigger B - RSI Divergence (M15) ==="
input int    InpSwingFractalN        = 2;         // Fractal bars each side (N)
input double InpRsiDivergenceMinGap  = 3.0;       // Min RSI-point gap between the two swing points
input int    InpDivergenceMaxAgeBars = 12;        // Newest swing expires after this many M15 bars

input group "=== Confirm ==="
input ENUM_TIMEFRAMES InpConfirmTF   = PERIOD_M1; // Confirm/entry-scan timeframe (MACD cross + OBV) - lower = more frequent scans
input int    InpMacdCrossLookback    = 1;         // Accept a MACD cross within this many closed confirm bars
input int    InpObvLookback          = 3;         // Bars for OBV-vs-price direction check

input group "=== Risk / Position Sizing ==="
input double InpRiskPctTriggerA      = 0.5;       // Risk % - Trigger A only (RSI extreme)
input double InpRiskPctTriggerB      = 1.0;       // Risk % - Trigger B only, or A+B together
input int    InpAtrPeriod            = 14;        // ATR period (M15) - SL distance
input double InpAtrSlMultiple        = 1.0;       // SL distance = M15 ATR x this multiple
input bool   InpUseTp                = true;      // Send a real TP order (lets profit actually get measured/locked in instead of only SL/flatten)
input double InpTpRrMultiple         = 2.5;       // TP distance = SL distance (ATR) x this multiple

input group "=== Risk Management / Daily Guardrails ==="
input double InpDailyLossStopPct     = 3.0;       // Stop new entries after this % realized loss
input int    InpMaxConsecutiveLosses = 3;         // Stop after N consecutive losing trades
input double InpDailyProfitTargetPct = 3.0;       // Halve risk (or stop) after this % realized profit
input bool   InpProfitTargetStopsTrading = false; // false = halve risk, true = stop entirely
input bool   InpUseEquityCircuitBreaker  = true;  // Block new entries once equity drawdown from its all-time peak (since EA attach) exceeds the % below - does NOT reset daily, unlike the guards above
input double InpMaxEquityDrawdownPct     = 15.0;  // Max % equity may fall from its peak before new entries are blocked

input group "=== Session Filter (broker/server time) ==="
input int    InpSessionStartHour     = 7;         // London open
input int    InpSessionEndHour       = 23;
input bool   InpAvoidSunday          = true;

input group "=== Safety - Unconditional Close Before Market Close/Break ==="
input int    InpFlattenBufferMinutes     = 20;    // Flatten this many minutes before session close
input int    InpFridayFallbackCutoffHour = 20;    // Friday cutoff hour
input bool   InpUseBrokerSessionGuard    = true;  // Also force-close whenever the broker's own quote/trade session says the market is not open right now (intraday break, weekend) - unconditional, no other checks

input group "=== Spread Filter ==="
input double InpMaxSpreadPoints      = 300;

input group "=== Diagnostics ==="
input bool   InpShowComment          = true;      // Comment() dashboard
input bool   InpVerboseLogging       = true;      // Print() scoring/state decisions

//==================== TYPES ====================
struct SwingPoint
{
   datetime time;
   double   price;
   bool     isHigh;
   bool     taken;
};

//==================== GLOBALS ====================
double   g_pt    = 0.01;
double   g_scale = 1.0;
string   g_blockReason = "";
double   g_riskMultiplier = 1.0;

int      hMacdH1=INVALID_HANDLE, hRsiM15=INVALID_HANDLE, hBandsM15=INVALID_HANDLE;
int      hAtrM15=INVALID_HANDLE, hMacdM5=INVALID_HANDLE, hObvM5=INVALID_HANDLE;

datetime g_lastBarM15=0, g_lastBarM5=0;
bool     g_newBarM5=false;
datetime g_lastEntryConfirmTime=0;
string   g_gvPeakEquityKey="";
string   g_gvLastConfirmKey="";
string   g_gvLastDivLowKey="", g_gvLastDivHighKey="";
datetime g_lastUsedDivLowTime=0, g_lastUsedDivHighTime=0;

SwingPoint g_swingsM15[];

//==================== POINT / LOT HELPERS ====================
double NormPrice(double p)
{
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0) ts = _Point;
   return NormalizeDouble(MathRound(p/ts)*ts, _Digits);
}

double NormLotDown(double lot)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double mn   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step<=0 || mn<=0 || mx<=0 || lot<mn) return 0;
   lot = MathFloor(MathMin(mx,lot)/step + 1e-9) * step;
   if(lot<mn) return 0;
   int digits = (int)MathMax(0, MathCeil(-MathLog10(step)));
   return NormalizeDouble(lot, digits);
}

void LogEvent(string msg)
{
   if(InpVerboseLogging) Print("[RMB] ", msg);
}

//==================== NEW-BAR HELPERS ====================
bool IsNewBarTF(ENUM_TIMEFRAMES tf, datetime &lastTime)
{
   datetime t = iTime(_Symbol, tf, 0);
   if(t != lastTime)
   {
      lastTime = t;
      return true;
   }
   return false;
}

//==================== SWING DETECTION (reused pattern) ====================
void TrimSwings(SwingPoint &list[], int cap)
{
   int n = ArraySize(list);
   if(n <= cap) return;
   int remove = n - cap;
   for(int i=0; i<cap; i++) list[i] = list[i+remove];
   ArrayResize(list, cap);
}

void AppendSwing(SwingPoint &list[], datetime t, double price, bool isHigh, int cap)
{
   int n = ArraySize(list);
   if(n>0 && list[n-1].time==t && list[n-1].isHigh==isHigh) return;
   ArrayResize(list, n+1);
   list[n].time = t;
   list[n].price = price;
   list[n].isHigh = isHigh;
   list[n].taken = false;
   TrimSwings(list, cap);
}

bool IsSwingHigh(ENUM_TIMEFRAMES tf, int center, int n)
{
   double h = iHigh(_Symbol, tf, center);
   if(h<=0) return false;
   for(int i=1; i<=n; i++)
   {
      if(iHigh(_Symbol, tf, center-i) >= h) return false;
      if(iHigh(_Symbol, tf, center+i) >= h) return false;
   }
   return true;
}

bool IsSwingLow(ENUM_TIMEFRAMES tf, int center, int n)
{
   double l = iLow(_Symbol, tf, center);
   if(l<=0) return false;
   for(int i=1; i<=n; i++)
   {
      if(iLow(_Symbol, tf, center-i) <= l) return false;
      if(iLow(_Symbol, tf, center+i) <= l) return false;
   }
   return true;
}

void UpdateSwingList(ENUM_TIMEFRAMES tf, SwingPoint &list[], int cap)
{
   // Shift 0 is still forming. N+1 keeps the candidate and all N bars on
   // its right-hand side closed before the swing is accepted.
   int center = InpSwingFractalN + 1;
   if(IsSwingHigh(tf, center, InpSwingFractalN))
      AppendSwing(list, iTime(_Symbol,tf,center), iHigh(_Symbol,tf,center), true, cap);
   if(IsSwingLow(tf, center, InpSwingFractalN))
      AppendSwing(list, iTime(_Symbol,tf,center), iLow(_Symbol,tf,center), false, cap);
}

//==================== BIAS (H1 MACD) ====================
int GetH1Bias()
{
   double main[], sig[];
   ArraySetAsSeries(main, true);
   ArraySetAsSeries(sig, true);
   if(CopyBuffer(hMacdH1, 0, 1, 1, main) != 1) return 0;
   if(CopyBuffer(hMacdH1, 1, 1, 1, sig)  != 1) return 0;
   double hist = main[0] - sig[0];
   if(main[0]>sig[0] && hist>0) return 1;
   if(main[0]<sig[0] && hist<0) return -1;
   return 0;
}

//==================== BB WIDTH FILTER (M15) ====================
double GetBbWidthPct(int shift)
{
   double upper[], lower[], mid[];
   ArraySetAsSeries(upper, true);
   ArraySetAsSeries(lower, true);
   ArraySetAsSeries(mid, true);
   if(CopyBuffer(hBandsM15, 1, shift, 1, upper) != 1) return 0;
   if(CopyBuffer(hBandsM15, 2, shift, 1, lower) != 1) return 0;
   if(CopyBuffer(hBandsM15, 0, shift, 1, mid)   != 1) return 0;
   if(mid[0]==0) return 0;
   return (upper[0]-lower[0])/mid[0]*100.0;
}

bool IsBbWidthOk()
{
   double cur = GetBbWidthPct(1);
   double sum = 0; int cnt = 0;
   for(int i=2; i<=InpBbWidthAvgLookback+1; i++)
   {
      double w = GetBbWidthPct(i);
      if(w>0) { sum+=w; cnt++; }
   }
   if(cnt==0 || cur<=0) return false;
   double avg = sum/cnt;
   if(avg<=0) return false;
   return cur >= avg*(InpBbWidthSqueezePct/100.0);
}

//==================== TRIGGER A - RSI EXTREME (M15) ====================
bool CheckRsiExtremeTrigger(int dir)
{
   double rsi[];
   ArraySetAsSeries(rsi, true);
   if(CopyBuffer(hRsiM15, 0, 1, 1, rsi) != 1) return false;
   if(dir==1)  return rsi[0] <= InpRsiExtremeLow;
   return rsi[0] >= InpRsiExtremeHigh;
}

//==================== TRIGGER B - RSI DIVERGENCE (M15) ====================
double GetRsiAtTime(datetime t)
{
   int shift = iBarShift(_Symbol, PERIOD_M15, t, false);
   if(shift<0) return -1;
   double rsi[];
   ArraySetAsSeries(rsi, true);
   if(CopyBuffer(hRsiM15, 0, shift, 1, rsi) != 1) return -1;
   return rsi[0];
}

bool CheckRsiDivergenceTrigger(int dir, double &gapOut, int &newerIdxOut)
{
   gapOut = 0;
   newerIdxOut = -1;
   bool wantHigh = (dir==-1);
   int idxNewer=-1, idxOlder=-1;
   for(int i=ArraySize(g_swingsM15)-1; i>=0; i--)
   {
      if(g_swingsM15[i].isHigh != wantHigh) continue;
      if(idxNewer<0) { idxNewer=i; continue; }
      idxOlder=i;
      break;
   }
   if(idxNewer<0 || idxOlder<0) return false;
   datetime newerTime = g_swingsM15[idxNewer].time;
   datetime lastUsedTime = wantHigh ? g_lastUsedDivHighTime : g_lastUsedDivLowTime;
   if(g_swingsM15[idxNewer].taken || newerTime==lastUsedTime) return false;
   int newerShift = iBarShift(_Symbol, PERIOD_M15, newerTime, false);
   if(newerShift<0 || newerShift>InpDivergenceMaxAgeBars) return false;

   double pOlder=g_swingsM15[idxOlder].price, pNewer=g_swingsM15[idxNewer].price;
   double rOlder=GetRsiAtTime(g_swingsM15[idxOlder].time), rNewer=GetRsiAtTime(g_swingsM15[idxNewer].time);
   if(rOlder<0 || rNewer<0) return false;

   if(dir==1)
   {
      if(!(pNewer < pOlder)) return false; // lower low in price
      double gap = rNewer - rOlder;        // higher low in RSI
      if(gap < InpRsiDivergenceMinGap) return false;
      gapOut = gap;
      newerIdxOut = idxNewer;
      return true;
   }
   else
   {
      if(!(pNewer > pOlder)) return false; // higher high in price
      double gap = rOlder - rNewer;        // lower high in RSI
      if(gap < InpRsiDivergenceMinGap) return false;
      gapOut = gap;
      newerIdxOut = idxNewer;
      return true;
   }
}

//==================== CONFIRM (CONFIGURABLE TF) ====================
bool CheckMacdCrossConfirm(int dir, datetime &crossTimeOut)
{
   crossTimeOut = 0;
   int lookback = MathMax(1, InpMacdCrossLookback);
   double main[], sig[];
   ArraySetAsSeries(main, true);
   ArraySetAsSeries(sig, true);
   int needed = lookback+1;
   if(CopyBuffer(hMacdM5, 0, 1, needed, main) != needed) return false;
   if(CopyBuffer(hMacdM5, 1, 1, needed, sig)  != needed) return false;

   // The newest closed bar must still agree with the cross direction.
   if(dir==1 && main[0]<=sig[0]) return false;
   if(dir==-1 && main[0]>=sig[0]) return false;

   for(int i=0; i<lookback; i++)
   {
      bool crossed = dir==1
         ? (main[i+1]<=sig[i+1] && main[i]>sig[i])
         : (main[i+1]>=sig[i+1] && main[i]<sig[i]);
      if(crossed)
      {
         crossTimeOut = iTime(_Symbol, InpConfirmTF, i+1);
         return crossTimeOut>0;
      }
   }
   return false;
}

bool CheckObvConfirm(int dir)
{
   double obv[];
   ArraySetAsSeries(obv, true);
   if(CopyBuffer(hObvM5, 0, 1, InpObvLookback, obv) != InpObvLookback) return false;
   double obvNow = obv[0];
   double obvOld = obv[InpObvLookback-1];
   double priceNow = iClose(_Symbol, InpConfirmTF, 1);
   double priceOld = iClose(_Symbol, InpConfirmTF, InpObvLookback);
   if(dir==1)  return (priceNow>priceOld) && (obvNow>=obvOld);
   return (priceNow<priceOld) && (obvNow<=obvOld);
}

//==================== RISK / LOT SIZING ====================
double GetAtrVirtualDistance()
{
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(hAtrM15, 0, 1, 1, atr) != 1) return 0;
   return atr[0];
}

double CalcRiskPercent(bool triggerA, bool triggerB)
{
   if(triggerB) return InpRiskPctTriggerB; // covers B-only and A+B together
   return InpRiskPctTriggerA;
}

double CalcLotFromRisk(double riskPct, int dir, double entryPrice, double stopPrice)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * riskPct/100.0 * g_riskMultiplier;
   if(riskMoney<=0 || entryPrice<=0 || stopPrice<=0 || entryPrice==stopPrice) return 0;

   double projectedProfit = 0;
   ENUM_ORDER_TYPE orderType = dir==1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcProfit(orderType, _Symbol, 1.0, entryPrice, stopPrice, projectedProfit))
   {
      LogEvent(StringFormat("Entry skipped: OrderCalcProfit failed (%d)", GetLastError()));
      return 0;
   }
   double lossPerLot = MathAbs(projectedProfit);
   if(lossPerLot<=0) return 0;

   double rawLot = riskMoney/lossPerLot;
   double lot = NormLotDown(rawLot);
   if(lot<=0)
      LogEvent(StringFormat("Entry skipped: required lot %.4f is below broker minimum", rawLot));
   return lot;
}

//==================== ENTRY EXECUTION ====================
bool IsExecutedTradeRetcode(uint retcode)
{
   return retcode==TRADE_RETCODE_DONE || retcode==TRADE_RETCODE_DONE_PARTIAL;
}

bool ExecuteEntry(int dir, double riskPct, string comment)
{
   double atrDist = GetAtrVirtualDistance() * InpAtrSlMultiple;
   if(atrDist<=0)
   {
      LogEvent("Entry skipped: ATR unavailable/zero");
      return false;
   }
   // Real SL at ATR(14) M15 distance from entry (see file header - added after an
   // initial no-SL backtest measured -52% drawdown). TP is a real order too when
   // InpUseTp is on, at InpTpRrMultiple x the SL distance - added so winning trades
   // actually lock in profit instead of only ever exiting via SL or the flatten
   // guard (floating profit was evaporating before a real exit ever happened).
   double entryPrice = dir==1 ? SymbolInfoDouble(_Symbol,SYMBOL_ASK) : SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double sl = dir==1 ? entryPrice - atrDist : entryPrice + atrDist;
   double lot = CalcLotFromRisk(riskPct, dir, entryPrice, sl);
   if(lot<=0) return false;
   double tp = 0;
   if(InpUseTp)
   {
      double tpDist = atrDist * InpTpRrMultiple;
      tp = dir==1 ? entryPrice + tpDist : entryPrice - tpDist;
   }

   bool ok;
   if(dir==1)
      ok = trade.Buy(lot, _Symbol, 0, NormPrice(sl), tp>0?NormPrice(tp):0, comment);
   else
      ok = trade.Sell(lot, _Symbol, 0, NormPrice(sl), tp>0?NormPrice(tp):0, comment);

   uint retcode = trade.ResultRetcode();
   bool executed = ok && IsExecutedTradeRetcode(retcode);
   if(!executed)
   {
      PrintFormat("ExecuteEntry failed: retcode=%u %s", retcode, trade.ResultRetcodeDescription());
      return false;
   }

   LogEvent(StringFormat("ENTRY %s %s lot=%.2f risk=%.2f%% entry=%.2f sl=%.2f tp=%.2f atrDist=%.2f", comment, dir==1?"BUY":"SELL", lot, riskPct, entryPrice, sl, tp, atrDist));
   return true;
}

void TryFindAndExecuteEntry()
{
   if(CountOpenPositions()>=MathMax(1,InpMaxOpenPositions)) return;

   int bias = GetH1Bias();
   if(bias==0) { LogEvent("Skip: H1 bias mixed"); return; }

   if(!IsBbWidthOk()) { LogEvent("Skip: BB width squeezed"); return; }

   bool triggerA = CheckRsiExtremeTrigger(bias);
   double gap=0;
   int divergenceIdx=-1;
   bool triggerB = CheckRsiDivergenceTrigger(bias, gap, divergenceIdx);
   if(!triggerA && !triggerB) { LogEvent("Skip: no trigger"); return; }

   datetime confirmTime=0;
   if(!CheckMacdCrossConfirm(bias, confirmTime)) { LogEvent("Skip: MACD cross confirm failed"); return; }
   if(confirmTime==g_lastEntryConfirmTime) { LogEvent("Skip: MACD cross setup already traded"); return; }
   if(!CheckObvConfirm(bias))       { LogEvent("Skip: OBV confirm failed"); return; }

   double riskPct = CalcRiskPercent(triggerA, triggerB);
   string comment = (triggerA && triggerB) ? "RMB-AB" : (triggerB ? "RMB-B" : "RMB-A");
   if(ExecuteEntry(bias, riskPct, comment))
   {
      g_lastEntryConfirmTime = confirmTime;
      GlobalVariableSet(g_gvLastConfirmKey, (double)confirmTime);
      if(triggerB && divergenceIdx>=0)
      {
         g_swingsM15[divergenceIdx].taken = true;
         datetime usedTime = g_swingsM15[divergenceIdx].time;
         if(bias==1)
         {
            g_lastUsedDivLowTime = usedTime;
            GlobalVariableSet(g_gvLastDivLowKey, (double)usedTime);
         }
         else
         {
            g_lastUsedDivHighTime = usedTime;
            GlobalVariableSet(g_gvLastDivHighKey, (double)usedTime);
         }
      }
   }
}

//==================== DAILY GUARDRAILS / FILTERS ====================
bool IsSpreadOk()
{
   double spreadPts = (SymbolInfoDouble(_Symbol,SYMBOL_ASK)-SymbolInfoDouble(_Symbol,SYMBOL_BID))/g_pt;
   return spreadPts <= InpMaxSpreadPoints;
}

int CountOpenPositions()
{
   int cnt=0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==(long)InpMagicNumber)
            cnt++;
      }
   }
   return cnt;
}

bool CloseAllMyPositions()
{
   bool allClosed = true;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==(long)InpMagicNumber)
         {
            bool ok = trade.PositionClose(ticket);
            uint retcode = trade.ResultRetcode();
            if(!ok || retcode!=TRADE_RETCODE_DONE)
            {
               allClosed = false;
               PrintFormat("PositionClose failed or incomplete: ticket=%I64u retcode=%u %s",
                           ticket, retcode, trade.ResultRetcodeDescription());
            }
         }
      }
   }
   return allClosed;
}

void GetTodayLossStats(int &lossesToday, double &realizedLossPctToday, int &consecutiveLosses, double &realizedProfitPctToday)
{
   lossesToday=0; consecutiveLosses=0; realizedLossPctToday=0; realizedProfitPctToday=0;
   MqlDateTime nowStruct;
   TimeToStruct(TimeCurrent(), nowStruct);
   datetime dayStart = TimeCurrent() - (nowStruct.hour*3600+nowStruct.min*60+nowStruct.sec);
   if(!HistorySelect(dayStart, TimeCurrent())) return;

   int total = HistoryDealsTotal();
   double netToday = 0;
   int streak = 0;
   for(int i=0; i<total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket,DEAL_MAGIC) != (long)InpMagicNumber) continue;
      if(HistoryDealGetString(ticket,DEAL_SYMBOL) != _Symbol) continue;
      long entry = HistoryDealGetInteger(ticket,DEAL_ENTRY);
      if(entry!=DEAL_ENTRY_OUT && entry!=DEAL_ENTRY_OUT_BY) continue;

      double profit = HistoryDealGetDouble(ticket,DEAL_PROFIT) + HistoryDealGetDouble(ticket,DEAL_SWAP) + HistoryDealGetDouble(ticket,DEAL_COMMISSION);
      netToday += profit;
      if(profit<0) { lossesToday++; streak++; }
      else if(profit>0) streak=0;
      consecutiveLosses = MathMax(consecutiveLosses, streak);
   }

   double dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE) - netToday;
   if(dayStartBalance>0)
   {
      if(netToday<0) realizedLossPctToday   = -netToday/dayStartBalance*100.0;
      if(netToday>0) realizedProfitPctToday =  netToday/dayStartBalance*100.0;
   }
}

int GetTodayEntryCount()
{
   MqlDateTime nowStruct;
   TimeToStruct(TimeCurrent(), nowStruct);
   datetime dayStart = TimeCurrent() - (nowStruct.hour*3600+nowStruct.min*60+nowStruct.sec);
   if(!HistorySelect(dayStart, TimeCurrent())) return 0;

   int total = HistoryDealsTotal();
   int count = 0;
   for(int i=0; i<total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket,DEAL_MAGIC) != (long)InpMagicNumber) continue;
      if(HistoryDealGetString(ticket,DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(ticket,DEAL_ENTRY)==DEAL_ENTRY_IN) count++;
   }
   return count;
}

bool IsInsideSession(datetime t)
{
   MqlDateTime s;
   TimeToStruct(t, s);
   if(InpAvoidSunday && s.day_of_week==0) return false;
   int hour = s.hour;
   if(InpSessionStartHour<=InpSessionEndHour)
      return hour>=InpSessionStartHour && hour<InpSessionEndHour;
   return hour>=InpSessionStartHour || hour<InpSessionEndHour;
}

int SecondsToSessionClose()
{
   MqlDateTime s;
   TimeToStruct(TimeCurrent(), s);
   int nowSec   = s.hour*3600+s.min*60+s.sec;
   int closeSec = InpSessionEndHour*3600;
   int remain   = closeSec - nowSec;
   if(remain<0) remain += 86400;
   return remain;
}

// Queries the broker's own quote/trade session schedule for _Symbol (covers both the
// Friday weekend close and any intraday maintenance/liquidity break the broker
// defines - e.g. the short daily gap around rollover) rather than guessing a fixed
// hour. Returns true only if "now" falls inside a session the broker itself reports
// as open for trading today.
bool IsInsideBrokerTradeSession(datetime t)
{
   MqlDateTime s;
   TimeToStruct(t, s);
   int nowSec = s.hour*3600 + s.min*60 + s.sec;
   for(int i=0; i<10; i++)
   {
      datetime from, to;
      if(!SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)s.day_of_week, i, from, to)) break;
      int fromSec = (int)(from % 86400);
      int toSec   = (int)(to % 86400);
      // Equal endpoints represent a full-day session; a lower end time
      // represents a broker session that crosses midnight.
      if(fromSec==toSec) return true;
      if(fromSec<toSec && nowSec>=fromSec && nowSec<toSec) return true;
      if(fromSec>toSec && (nowSec>=fromSec || nowSec<toSec)) return true;
   }
   return false;
}

bool EnforceNoOvernightPositions()
{
   MqlDateTime s;
   TimeToStruct(TimeCurrent(), s);
   bool fridayCutoff = (s.day_of_week==5 && s.hour>=InpFridayFallbackCutoffHour);
   bool nearClose    = SecondsToSessionClose() <= InpFlattenBufferMinutes*60;
   bool weekend      = (s.day_of_week==0 || s.day_of_week==6);

   // Unconditional: whenever the broker itself reports the market as not currently
   // open for this symbol (weekend, or any intraday break), force-close regardless
   // of any other input/condition - this is the authoritative check the user asked
   // for, on top of the pre-emptive hour-based guards above.
   bool brokerSessionClosed = InpUseBrokerSessionGuard && !IsInsideBrokerTradeSession(TimeCurrent());

   if(fridayCutoff || nearClose || weekend || brokerSessionClosed)
   {
      if(CountOpenPositions()>0)
      {
         string reason = brokerSessionClosed ? "broker session closed/break (unconditional)" : "session close / Friday cutoff / weekend guard";
         LogEvent("Flattening - " + reason + " (additional safety net alongside the real SL)");
         if(!CloseAllMyPositions())
            LogEvent("Flatten incomplete; retrying on the next tick");
      }
      return true;
   }
   return false;
}

// Peak-equity circuit breaker: unlike every other guardrail above (which rebuilds
// its counters from TODAY's deal history and so resets every day), this tracks the
// account's all-time-high equity since this EA was first attached (persisted via a
// GlobalVariable, restart-safe) and blocks new entries once equity has fallen too
// far below that peak - catching a slow bleed across many separate days that no
// single day's own loss-stop would ever trip on its own.
double GetPeakEquity()
{
   double curEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double peak = GlobalVariableCheck(g_gvPeakEquityKey) ? GlobalVariableGet(g_gvPeakEquityKey) : curEquity;
   if(curEquity > peak)
   {
      peak = curEquity;
      GlobalVariableSet(g_gvPeakEquityKey, peak);
   }
   return peak;
}

bool IsEquityCircuitBreakerTripped(double &ddPctOut)
{
   ddPctOut = 0;
   if(!InpUseEquityCircuitBreaker) return false;
   double peak = GetPeakEquity();
   if(peak<=0) return false;
   double curEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   ddPctOut = (peak-curEquity)/peak*100.0;
   return ddPctOut >= InpMaxEquityDrawdownPct;
}

bool EvaluateDailyGuardrails()
{
   int losses, streak;
   double lossPct, profitPct;
   GetTodayLossStats(losses, lossPct, streak, profitPct);
   g_riskMultiplier = 1.0;

   double eqDdPct = 0;
   if(IsEquityCircuitBreakerTripped(eqDdPct))
   {
      g_blockReason = StringFormat("Equity circuit breaker tripped (%.2f%% below peak)", eqDdPct);
      return true;
   }
   if(lossPct>=InpDailyLossStopPct)               { g_blockReason="Daily loss stop reached";     return true; }
   if(streak>=InpMaxConsecutiveLosses)             { g_blockReason="Max consecutive losses reached"; return true; }
   if(GetTodayEntryCount()>=InpMaxTradesPerDay)    { g_blockReason="Max trades/day reached";      return true; }
   if(profitPct>=InpDailyProfitTargetPct)
   {
      if(InpProfitTargetStopsTrading) { g_blockReason="Daily profit target reached"; return true; }
      g_riskMultiplier = 0.5;
   }
   if(!IsInsideSession(TimeCurrent()))              { g_blockReason="Outside trading session";    return true; }
   if(!IsSpreadOk())                                { g_blockReason="Spread too wide";            return true; }

   g_blockReason = "";
   return false;
}

//==================== BAR-CACHE ORCHESTRATION ====================
void UpdateBarCaches()
{
   g_newBarM5 = false;

   if(IsNewBarTF(PERIOD_M15, g_lastBarM15))
      UpdateSwingList(PERIOD_M15, g_swingsM15, SWING_CAP);

   if(IsNewBarTF(InpConfirmTF, g_lastBarM5))
      g_newBarM5 = true;
}

//==================== DASHBOARD ====================
void UpdateDashboard()
{
   int bias = GetH1Bias();
   string biasStr = bias==1 ? "BUY" : (bias==-1 ? "SELL" : "MIXED/none");
   double eqDd=0; IsEquityCircuitBreakerTripped(eqDd);
   string txt = StringFormat(
      "XAUUSD RSI/MACD Momentum EA (SL+TP fixed R:R, no trailing yet)\nBias(H1): %s\nOpen positions: %d\nBlock: %s\nRisk multiplier: %.2f\nSpread OK: %s\nEquity DD from peak: %.2f%% (limit %.1f%%)",
      biasStr, CountOpenPositions(), g_blockReason=="" ? "none" : g_blockReason, g_riskMultiplier,
      IsSpreadOk()?"yes":"NO", eqDd, InpMaxEquityDrawdownPct);
   Comment(txt);
}

//==================== ENTRY POINTS ====================
int OnInit()
{
   if(InpMaxOpenPositions<1 || InpMaxTradesPerDay<1 || InpSwingFractalN<1 ||
      InpDivergenceMaxAgeBars<1 || InpMacdCrossLookback<1 || InpObvLookback<2 ||
      InpAtrPeriod<1 || InpAtrSlMultiple<=0 || InpTpRrMultiple<=0 ||
      InpRsiExtremeLow<=0 || InpRsiExtremeHigh>=100 || InpRsiExtremeLow>=InpRsiExtremeHigh ||
      InpRiskPctTriggerA<=0 || InpRiskPctTriggerB<=0)
   {
      Print("Invalid strategy input: check position limits, lookbacks, RSI levels, ATR/TP multiples, and risk percentages");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_pt    = 0.01;
   g_scale = g_pt/_Point;
   if(_Digits!=2 && _Digits!=3)
      PrintFormat("WARNING: %s has %d decimal digits, unusual for gold - verify point conversion before trading.", _Symbol, _Digits);

   ENUM_ACCOUNT_MARGIN_MODE marginMode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING && InpMaxOpenPositions>1)
   {
      Print("Invalid strategy input: netting accounts require InpMaxOpenPositions=1");
      return INIT_PARAMETERS_INCORRECT;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints((ulong)(InpSlippage*g_scale));
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   g_gvPeakEquityKey = "RMB_" + IntegerToString((long)InpMagicNumber) + "_" + _Symbol + "_PeakEquity";
   g_gvLastConfirmKey = "RMB_" + IntegerToString((long)InpMagicNumber) + "_" + _Symbol + "_LastConfirm";
   g_gvLastDivLowKey = "RMB_" + IntegerToString((long)InpMagicNumber) + "_" + _Symbol + "_LastDivLow";
   g_gvLastDivHighKey = "RMB_" + IntegerToString((long)InpMagicNumber) + "_" + _Symbol + "_LastDivHigh";
   if(GlobalVariableCheck(g_gvLastConfirmKey))
      g_lastEntryConfirmTime = (datetime)GlobalVariableGet(g_gvLastConfirmKey);
   if(GlobalVariableCheck(g_gvLastDivLowKey))
      g_lastUsedDivLowTime = (datetime)GlobalVariableGet(g_gvLastDivLowKey);
   if(GlobalVariableCheck(g_gvLastDivHighKey))
      g_lastUsedDivHighTime = (datetime)GlobalVariableGet(g_gvLastDivHighKey);

   hMacdH1   = iMACD(_Symbol, PERIOD_H1,  InpMacdFastEma, InpMacdSlowEma, InpMacdSignal, PRICE_CLOSE);
   hRsiM15   = iRSI(_Symbol, PERIOD_M15, InpRsiPeriod, PRICE_CLOSE);
   hBandsM15 = iBands(_Symbol, PERIOD_M15, InpBbPeriod, 0, InpBbDeviation, PRICE_CLOSE);
   hAtrM15   = iATR(_Symbol, PERIOD_M15, InpAtrPeriod);
   hMacdM5   = iMACD(_Symbol, InpConfirmTF, InpMacdFastEma, InpMacdSlowEma, InpMacdSignal, PRICE_CLOSE);
   hObvM5    = iOBV(_Symbol, InpConfirmTF, VOLUME_TICK);

   if(hMacdH1==INVALID_HANDLE || hRsiM15==INVALID_HANDLE || hBandsM15==INVALID_HANDLE ||
      hAtrM15==INVALID_HANDLE || hMacdM5==INVALID_HANDLE || hObvM5==INVALID_HANDLE)
   {
      Print("Failed to create one or more indicator handles");
      return INIT_FAILED;
   }

   PrintFormat("XAUUSD_RSI_MACD_Momentum_EA started | %s Digits=%d | 1 point=$%.2f (x%.2f broker points) | real ATR-based SL+TP, no trailing yet",
               _Symbol, _Digits, g_pt, g_scale);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hMacdH1!=INVALID_HANDLE)   IndicatorRelease(hMacdH1);
   if(hRsiM15!=INVALID_HANDLE)   IndicatorRelease(hRsiM15);
   if(hBandsM15!=INVALID_HANDLE) IndicatorRelease(hBandsM15);
   if(hAtrM15!=INVALID_HANDLE)   IndicatorRelease(hAtrM15);
   if(hMacdM5!=INVALID_HANDLE)   IndicatorRelease(hMacdM5);
   if(hObvM5!=INVALID_HANDLE)    IndicatorRelease(hObvM5);
   Comment("");
}

void OnTick()
{
   UpdateBarCaches();

   bool flattenBlocked = EnforceNoOvernightPositions();

   bool blocked = EvaluateDailyGuardrails();
   if(flattenBlocked)
   {
      g_blockReason = "Market-close flatten window";
      blocked = true;
   }
   if(!blocked && g_newBarM5)
      TryFindAndExecuteEntry();

   if(InpShowComment) UpdateDashboard();
}
