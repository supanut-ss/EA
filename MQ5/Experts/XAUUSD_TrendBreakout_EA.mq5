//+------------------------------------------------------------------+
//|                                    XAUUSD_TrendBreakout_EA.mq5 |
//|  Strategy: Trend Following & Breakout (XAUUSD)                 |
//|                                                                  |
//|  Logic:                                                          |
//|   1) Trend filter on H1: EMA50 vs EMA200 + ADX(14) direction     |
//|      (only trade in the direction of the higher-timeframe trend) |
//|   2) Entry on M15: Donchian channel breakout (20-bar high/low)   |
//|      of the PRIOR channel (current forming + last closed bar     |
//|      excluded from the channel itself)                           |
//|   3) Fakeout filter: last closed bar must CLOSE beyond the       |
//|      channel by an ATR-scaled buffer, and the bar before it must |
//|      NOT have already closed beyond that buffer (only trade the  |
//|      breakout bar itself, not a move that already ran)           |
//|   4) Risk: fixed lot size, SL = ATR multiple from entry,          |
//|      TP = SL distance x Risk:Reward, optional ATR trailing stop   |
//|   5) Filters: trading session window (default London/NY overlap, |
//|      broker server time), Friday cutoff, no Sunday trading,       |
//|      max spread, max trades/day, max concurrent positions         |
//|                                                                    |
//|  IMPORTANT: This EA has NOT been backtested by the assistant that |
//|  wrote it (no MT5 terminal available in that environment). Run it |
//|  in MT5 Strategy Tester on a demo account before any live use.    |
//|  See XAUUSD_TrendBreakout_Spec.md for the backtest checklist and  |
//|  parameter rationale.                                             |
//+------------------------------------------------------------------+
#property copyright "Custom EA - Trend Following & Breakout"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

CTrade trade;

//--- Inputs: General
input group "=== General Settings ==="
input double   InpLotSize          = 0.01;      // Fixed Lot Size
input ulong    InpMagicNumber      = 20260811;  // Magic Number
input int      InpSlippage         = 20;        // Slippage (points)
input int      InpMaxOpenPositions = 3;         // Max Open Positions (this EA)
input int      InpMaxTradesPerDay  = 6;         // Max New Trades Per Day

input group "=== Trend Filter (Higher Timeframe) ==="
input ENUM_TIMEFRAMES InpTrendTF   = PERIOD_H1; // Trend Timeframe
input int      InpEmaFast          = 50;        // EMA Fast Period
input int      InpEmaSlow          = 200;       // EMA Slow Period
input int      InpAdxPeriod        = 14;        // ADX Period
input double   InpAdxThreshold     = 20.0;      // ADX Minimum Threshold (trend strength)

input group "=== Breakout Settings (Entry Timeframe) ==="
input ENUM_TIMEFRAMES InpEntryTF   = PERIOD_M15; // Entry Timeframe
input int      InpDonchianPeriod   = 10;         // Donchian Channel Period (bars)
input int      InpAtrPeriod        = 14;         // ATR Period
input double   InpAtrBufferMult    = 0.30;       // ATR Buffer Multiplier (fakeout filter)

input group "=== Risk Management ==="
input double   InpAtrSlMult        = 1.5;        // ATR Multiplier for Stop Loss
input double   InpRiskReward       = 1.8;        // Risk:Reward Ratio (TP distance)
input bool     InpUseTrailing      = true;       // Use ATR Trailing Stop
input double   InpTrailAtrMult     = 1.2;        // Trailing Stop ATR Multiplier

input group "=== Session Filter (Broker/Server Time) ==="
input int      InpSessionStartHour = 8;          // Session Start Hour (London open through NY close)
input int      InpSessionEndHour   = 23;         // Session End Hour
input bool     InpAvoidFriday      = true;       // Cut off trading late on Friday
input int      InpFridayCutoffHour = 20;         // Friday Cutoff Hour
input bool     InpAvoidSunday      = true;       // Do not trade on Sunday

input group "=== Spread Filter ==="
input double   InpMaxSpreadPoints  = 350;        // Max Allowed Spread (points)

//--- Global variables
int handleEmaFast, handleEmaSlow, handleAdx, handleAtrEntry;
datetime lastBarTime   = 0;
datetime lastTradeDay  = 0;
int      tradesToday   = 0;
string   symbolName;
datetime g_testStartTime = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   symbolName = _Symbol;
   g_testStartTime = TimeCurrent();

   handleEmaFast  = iMA(symbolName, InpTrendTF, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   handleEmaSlow  = iMA(symbolName, InpTrendTF, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   handleAdx      = iADX(symbolName, InpTrendTF, InpAdxPeriod);
   handleAtrEntry = iATR(symbolName, InpEntryTF, InpAtrPeriod);

   if(handleEmaFast==INVALID_HANDLE || handleEmaSlow==INVALID_HANDLE ||
      handleAdx==INVALID_HANDLE || handleAtrEntry==INVALID_HANDLE)
   {
      Print("Failed to create indicator handle(s)");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(symbolName);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handleEmaFast);
   IndicatorRelease(handleEmaSlow);
   IndicatorRelease(handleAdx);
   IndicatorRelease(handleAtrEntry);
}

//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime t = iTime(symbolName, InpEntryTF, 0);
   if(t != lastBarTime)
   {
      lastBarTime = t;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
void ResetDailyCounterIfNeeded()
{
   MqlDateTime now, lastDay;
   TimeToStruct(TimeCurrent(), now);
   TimeToStruct(lastTradeDay, lastDay);

   if(lastTradeDay == 0 || now.day != lastDay.day || now.mon != lastDay.mon || now.year != lastDay.year)
   {
      tradesToday  = 0;
      lastTradeDay = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
bool IsWithinSession()
{
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);

   if(InpAvoidSunday && now.day_of_week == 0) return false;
   if(now.day_of_week == 6) return false; // Saturday - market closed anyway
   if(InpAvoidFriday && now.day_of_week == 5 && now.hour >= InpFridayCutoffHour) return false;

   if(InpSessionStartHour <= InpSessionEndHour)
      return (now.hour >= InpSessionStartHour && now.hour < InpSessionEndHour);
   else
      return (now.hour >= InpSessionStartHour || now.hour < InpSessionEndHour);
}

//+------------------------------------------------------------------+
bool IsSpreadOk()
{
   double spread = (double)SymbolInfoInteger(symbolName, SYMBOL_SPREAD);
   return (spread <= InpMaxSpreadPoints);
}

//+------------------------------------------------------------------+
int CountOpenPositions()
{
   int count = 0;
   for(int i=0; i<PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL)==symbolName &&
            PositionGetInteger(POSITION_MAGIC)==(long)InpMagicNumber)
            count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
// Returns 1 = bullish trend, -1 = bearish trend, 0 = no clear trend
int GetTrendBias()
{
   double emaFast[], emaSlow[], adxMain[], adxPlus[], adxMinus[];
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);
   ArraySetAsSeries(adxMain, true);
   ArraySetAsSeries(adxPlus, true);
   ArraySetAsSeries(adxMinus, true);

   if(CopyBuffer(handleEmaFast, 0, 0, 3, emaFast) < 3) return 0;
   if(CopyBuffer(handleEmaSlow, 0, 0, 3, emaSlow) < 3) return 0;
   if(CopyBuffer(handleAdx, 0, 0, 3, adxMain) < 3) return 0;
   if(CopyBuffer(handleAdx, 1, 0, 3, adxPlus) < 3) return 0;
   if(CopyBuffer(handleAdx, 2, 0, 3, adxMinus) < 3) return 0;

   bool adxOk = adxMain[0] >= InpAdxThreshold;

   if(emaFast[0] > emaSlow[0] && adxOk && adxPlus[0] > adxMinus[0])
      return 1;
   if(emaFast[0] < emaSlow[0] && adxOk && adxMinus[0] > adxPlus[0])
      return -1;

   return 0;
}

//+------------------------------------------------------------------+
// Donchian channel high/low over InpDonchianPeriod bars, using bars
// starting at shift 2 (i.e. EXCLUDING the current forming bar [0] and
// the last closed bar [1], which is the candidate breakout bar).
//+------------------------------------------------------------------+
bool GetDonchianLevels(double &channelHigh, double &channelLow)
{
   int highestIdx = iHighest(symbolName, InpEntryTF, MODE_HIGH, InpDonchianPeriod, 2);
   int lowestIdx  = iLowest(symbolName, InpEntryTF, MODE_LOW, InpDonchianPeriod, 2);
   if(highestIdx < 0 || lowestIdx < 0) return false;

   channelHigh = iHigh(symbolName, InpEntryTF, highestIdx);
   channelLow  = iLow(symbolName, InpEntryTF, lowestIdx);
   return true;
}

//+------------------------------------------------------------------+
double GetAtr()
{
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(handleAtrEntry, 0, 1, 1, atr) < 1) return 0;
   return atr[0];
}

//+------------------------------------------------------------------+
void CheckForEntry()
{
   if(CountOpenPositions() >= InpMaxOpenPositions) return;
   if(tradesToday >= InpMaxTradesPerDay) return;
   if(!IsWithinSession()) return;
   if(!IsSpreadOk()) return;

   int trend = GetTrendBias();
   if(trend == 0) return;

   double channelHigh, channelLow;
   if(!GetDonchianLevels(channelHigh, channelLow)) return;

   double atr = GetAtr();
   if(atr <= 0) return;

   double buffer = atr * InpAtrBufferMult;

   // Use the last CLOSED bar (index 1) for confirmation, and the bar
   // before it (index 2) to make sure we catch the breakout bar itself.
   double closeLast = iClose(symbolName, InpEntryTF, 1);
   double closePrev = iClose(symbolName, InpEntryTF, 2);

   double ask = SymbolInfoDouble(symbolName, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbolName, SYMBOL_BID);

   if(trend == 1 && closeLast > channelHigh + buffer && closePrev <= channelHigh + buffer)
   {
      double sl = ask - atr * InpAtrSlMult;
      double slDist = ask - sl;
      double tp = ask + slDist * InpRiskReward;
      OpenTrade(ORDER_TYPE_BUY, sl, tp);
   }
   else if(trend == -1 && closeLast < channelLow - buffer && closePrev >= channelLow - buffer)
   {
      double sl = bid + atr * InpAtrSlMult;
      double slDist = sl - bid;
      double tp = bid - slDist * InpRiskReward;
      OpenTrade(ORDER_TYPE_SELL, sl, tp);
   }
}

//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE type, double sl, double tp)
{
   int digits = (int)SymbolInfoInteger(symbolName, SYMBOL_DIGITS);
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   bool result = false;
   if(type == ORDER_TYPE_BUY)
      result = trade.Buy(InpLotSize, symbolName, 0, sl, tp, "TrendBreakout Buy");
   else
      result = trade.Sell(InpLotSize, symbolName, 0, sl, tp, "TrendBreakout Sell");

   if(result)
   {
      tradesToday++;
      Print("Trade opened: ", EnumToString(type), " Lots=", InpLotSize, " SL=", sl, " TP=", tp);
   }
   else
   {
      Print("OrderSend failed. Error: ", GetLastError(),
            " Retcode: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   if(!InpUseTrailing) return;

   double atr = GetAtr();
   if(atr <= 0) return;

   int digits = (int)SymbolInfoInteger(symbolName, SYMBOL_DIGITS);

   for(int i=0; i<PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbolName) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber) continue;

      long   type  = PositionGetInteger(POSITION_TYPE);
      double posSl = PositionGetDouble(POSITION_SL);
      double posTp = PositionGetDouble(POSITION_TP);

      if(type == POSITION_TYPE_BUY)
      {
         double bid   = SymbolInfoDouble(symbolName, SYMBOL_BID);
         double newSl = NormalizeDouble(bid - atr * InpTrailAtrMult, digits);
         if(newSl > posSl && newSl < bid)
            trade.PositionModify(ticket, newSl, posTp);
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double ask   = SymbolInfoDouble(symbolName, SYMBOL_ASK);
         double newSl = NormalizeDouble(ask + atr * InpTrailAtrMult, digits);
         if((posSl == 0 || newSl < posSl) && newSl > ask)
            trade.PositionModify(ticket, newSl, posTp);
      }
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   ResetDailyCounterIfNeeded();
   ManageTrailingStop();

   if(!IsNewBar()) return;

   CheckForEntry();
}

//+------------------------------------------------------------------+
//| Custom optimization criterion (Optimization Criterion = Custom max)|
//| Rewards net profit, but scales it by how close trade frequency    |
//| lands to the 2-3 trades/trading-day target and by how contained   |
//| drawdown stayed - so the genetic optimizer searches for the same  |
//| balance a human would look for, not just raw balance.             |
//+------------------------------------------------------------------+
double OnTester()
{
   double profit = TesterStatistics(STAT_PROFIT);
   double trades = TesterStatistics(STAT_TRADES);
   double ddPct  = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);

   if(trades < 5)
      return(-1000.0 - (5 - trades)); // too few trades to judge - discard, prefer the closest

   double totalDays    = (double)(TimeCurrent() - g_testStartTime) / 86400.0;
   double tradingDays  = MathMax(totalDays * (5.0 / 7.0), 1.0);
   double tradesPerDay = trades / tradingDays;

   // Frequency factor: 1.0 inside the [2,3] target band, ramps down outside it
   double freqFactor;
   if(tradesPerDay < 2.0)
      freqFactor = tradesPerDay / 2.0;
   else if(tradesPerDay <= 3.0)
      freqFactor = 1.0;
   else
      freqFactor = MathMax(0.4, 1.0 - (tradesPerDay - 3.0) * 0.15);
   freqFactor = MathMax(freqFactor, 0.05);

   // Drawdown factor: penalize hard once relative DD passes ~20-25%
   double ddFactor = MathMax(0.05, 1.0 - ddPct / 25.0);

   double score;
   if(profit >= 0)
      score = profit * freqFactor * ddFactor;
   else
      score = profit / MathMax(freqFactor * ddFactor, 0.05); // losses get worse, not better, when freq/DD are also bad

   return(score);
}
//+------------------------------------------------------------------+
