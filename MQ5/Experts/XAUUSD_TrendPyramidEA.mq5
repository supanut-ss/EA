//+------------------------------------------------------------------+
//|                                    XAUUSD_TrendPyramidEA.mq5      |
//|  Trend + momentum Expert Advisor template for XAUUSD (Gold), MT5  |
//|                                                                    |
//|  Strategy summary:                                                |
//|   - Trend filter : EMA(FastEMA) vs EMA(SlowEMA)                   |
//|   - Trigger      : RSI in a configurable "trend-continuation" band|
//|   - Stops        : ATR-based SL/TP (scales with current gold      |
//|                     volatility instead of a fixed point count)    |
//|   - Sizing       : risk-% of equity per trade (dynamic lot size)  |
//|   - Frequency    : optional pyramiding - adds further same-       |
//|                     direction entries spaced by ATR, bounded by   |
//|                     MaxPositions and MaxTotalRiskPercent so more   |
//|                     trades never means uncontrolled risk          |
//|   - Safety       : max spread filter, trading-session filter,     |
//|                     daily loss circuit breaker                    |
//|                                                                    |
//|  This is a STARTING TEMPLATE, not a finished profitable system.   |
//|  Backtest (Strategy Tester, "every tick based on real ticks"),    |
//|  then forward-test on a demo account, before any live use.        |
//|  Educational / technical content only - not financial advice.    |
//+------------------------------------------------------------------+
#property copyright "Generated for XAUUSD gold-trading skill"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

CTrade trade;

//================= INPUTS ====================================

input group "=== Trend & Signal ==="
input int    FastEMA               = 50;      // Fast EMA period (trend)
input int    SlowEMA               = 200;     // Slow EMA period (trend)
input int    RSI_Period             = 14;      // RSI period
input double RSI_BuyMin             = 45.0;    // Buy allowed only if RSI above this
input double RSI_BuyMax             = 70.0;    // Buy blocked if RSI above this (overbought)
input double RSI_SellMax            = 55.0;    // Sell allowed only if RSI below this
input double RSI_SellMin            = 30.0;    // Sell blocked if RSI below this (oversold)
input int    ATR_Period             = 14;      // ATR period

input group "=== Stops / Targets (ATR based) ==="
input double SL_ATR_Multiplier      = 1.5;     // Stop loss = ATR * this
input double TP_ATR_Multiplier      = 3.0;     // Take profit = ATR * this
input bool   UseTrailingStop        = true;    // Trail SL once in profit
input double Trail_Start_ATR        = 1.0;     // Start trailing after profit >= this * ATR
input double Trail_Distance_ATR     = 1.0;     // Trail distance behind price, in ATR

input group "=== Risk & Position Sizing ==="
input double RiskPercentPerTrade    = 1.0;     // % equity risked per NEW trade
input double MaxTotalRiskPercent    = 3.0;     // Cap on summed risk of all open positions (this EA)
input double MinLot                 = 0.01;    // Safety floor (broker min usually applies too)
input double MaxLot                 = 5.0;     // Safety ceiling on a single trade's lot size
input double DailyLossLimitPercent  = 3.0;     // Stop opening new trades after this much daily loss

input group "=== Trade Frequency / Pyramiding ==="
input int    MaxPositions           = 3;       // Max concurrent same-direction positions (this EA)
input double PyramidStep_ATR        = 1.0;     // Min distance (in ATR) from last entry before adding another
input bool   AllowPyramiding        = true;    // false = at most 1 position per direction at a time

input group "=== Filters ==="
input int    MaxSpreadPoints        = 350;     // Skip new entries if spread (points) exceeds this
input bool   UseSessionFilter       = true;    // Restrict entries to broker-server-time window below
input int    SessionStartHour       = 7;       // Server time hour, inclusive (default: London open-ish)
input int    SessionEndHour         = 21;      // Server time hour, exclusive (default: after NY session)

input group "=== Misc ==="
input ulong  MagicNumber            = 20260814;
input string TradeComment           = "XAUUSD_TrendPyramidEA";

//================= GLOBALS ====================================

int emaFastHandle = INVALID_HANDLE;
int emaSlowHandle = INVALID_HANDLE;
int rsiHandle     = INVALID_HANDLE;
int atrHandle     = INVALID_HANDLE;

datetime lastBarTime   = 0;
double   dayStartEquity = 0.0;
int      currentDay     = -1;
bool     dailyLimitHit  = false;

//+------------------------------------------------------------------+
int OnInit()
  {
   emaFastHandle = iMA(_Symbol, PERIOD_CURRENT, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   emaSlowHandle = iMA(_Symbol, PERIOD_CURRENT, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   rsiHandle     = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);
   atrHandle     = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);

   if(emaFastHandle==INVALID_HANDLE || emaSlowHandle==INVALID_HANDLE ||
      rsiHandle==INVALID_HANDLE || atrHandle==INVALID_HANDLE)
     {
      Print("XAUUSD_TrendPyramidEA: failed to create indicator handle(s)");
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(50);

   // Brokers differ in which order-filling modes they accept for a symbol;
   // hard-coding FOK is a common reason "Unsupported filling mode" errors
   // show up live even though the EA worked fine in the tester. Detect and
   // use whatever the symbol actually supports instead.
   long fillingModes = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fillingModes & SYMBOL_FILLING_FOK) != 0)
      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fillingModes & SYMBOL_FILLING_IOC) != 0)
      trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      trade.SetTypeFilling(ORDER_FILLING_RETURN);

   dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   currentDay = dt.day_of_year;

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(emaFastHandle!=INVALID_HANDLE) IndicatorRelease(emaFastHandle);
   if(emaSlowHandle!=INVALID_HANDLE) IndicatorRelease(emaSlowHandle);
   if(rsiHandle!=INVALID_HANDLE)     IndicatorRelease(rsiHandle);
   if(atrHandle!=INVALID_HANDLE)     IndicatorRelease(atrHandle);
  }

//+------------------------------------------------------------------+
//| Helper: true once per new bar                                     |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(t != lastBarTime)
     {
      lastBarTime = t;
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Helper: reset / check the daily loss circuit breaker              |
//+------------------------------------------------------------------+
void UpdateDailyLossState()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != currentDay)
     {
      currentDay      = dt.day_of_year;
      dayStartEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
      dailyLimitHit   = false;
     }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(dayStartEquity > 0 && equity <= dayStartEquity * (1.0 - DailyLossLimitPercent/100.0))
     {
      if(!dailyLimitHit)
         Print("XAUUSD_TrendPyramidEA: daily loss limit reached, pausing new entries until next day.");
      dailyLimitHit = true;
     }
  }

//+------------------------------------------------------------------+
//| Helper: current spread in points                                  |
//+------------------------------------------------------------------+
int SpreadPoints()
  {
   return (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
  }

//+------------------------------------------------------------------+
//| Helper: session filter (broker/server time)                       |
//+------------------------------------------------------------------+
bool WithinSession()
  {
   if(!UseSessionFilter) return(true);
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(SessionStartHour <= SessionEndHour)
      return(dt.hour >= SessionStartHour && dt.hour < SessionEndHour);
   // handles a window that wraps past midnight, e.g. 22 -> 5
   return(dt.hour >= SessionStartHour || dt.hour < SessionEndHour);
  }

//+------------------------------------------------------------------+
//| Position accounting helpers (this EA / this symbol only)          |
//+------------------------------------------------------------------+
int CountPositions(const int direction) // direction: 1=buy, -1=sell
  {
   int count = 0;
   for(int i=0; i<PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) continue;

      long type = PositionGetInteger(POSITION_TYPE);
      if(direction==1 && type==POSITION_TYPE_BUY) count++;
      if(direction==-1 && type==POSITION_TYPE_SELL) count++;
     }
   return(count);
  }

double LastEntryPrice(const int direction)
  {
   double result = 0.0;
   datetime latest = 0;
   for(int i=0; i<PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) continue;

      long type = PositionGetInteger(POSITION_TYPE);
      bool matches = (direction==1 && type==POSITION_TYPE_BUY) ||
                     (direction==-1 && type==POSITION_TYPE_SELL);
      if(!matches) continue;

      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      if(opened >= latest)
        {
         latest = opened;
         result = PositionGetDouble(POSITION_PRICE_OPEN);
        }
     }
   return(result);
  }

//+------------------------------------------------------------------+
//| Sum of $ risk currently open across this EA's positions           |
//| (uses each position's own SL; positions without an SL are treated |
//|  conservatively using the current ATR-based SL distance)          |
//+------------------------------------------------------------------+
double OpenRiskMoney(const double fallbackSLDistance)
  {
   double totalRisk = 0.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0) return(0.0);

   for(int i=0; i<PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl         = PositionGetDouble(POSITION_SL);
      double slDist      = (sl>0) ? MathAbs(openPrice - sl) : fallbackSLDistance;
      double volume      = PositionGetDouble(POSITION_VOLUME);

      double moneyPerLot = (slDist / tickSize) * tickValue;
      totalRisk += moneyPerLot * volume;
     }
   return(totalRisk);
  }

//+------------------------------------------------------------------+
//| Risk-% based lot size for a given stop-loss distance (in price)   |
//+------------------------------------------------------------------+
double CalculateLotSize(const double slDistance)
  {
   if(slDistance <= 0) return(0.0);

   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * (RiskPercentPerTrade/100.0);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0 || tickValue <= 0) return(0.0);

   double moneyPerLot = (slDistance / tickSize) * tickValue;
   if(moneyPerLot <= 0) return(0.0);

   double lot = riskMoney / moneyPerLot;

   double volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(volStep <= 0) volStep = 0.01;

   // round DOWN to the nearest step so realized risk never exceeds target
   lot = MathFloor(lot / volStep) * volStep;

   lot = MathMax(lot, MathMax(volMin, MinLot));
   lot = MathMin(lot, MathMin(volMax, MaxLot));

   return(NormalizeDouble(lot, 3));
  }

//+------------------------------------------------------------------+
//| Manage trailing stops on existing positions                       |
//+------------------------------------------------------------------+
void ManageTrailing(const double atr)
  {
   if(!UseTrailingStop || atr<=0) return;

   double stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   for(int i=0; i<PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) continue;

      long   type      = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL      = PositionGetDouble(POSITION_SL);
      double curTP      = PositionGetDouble(POSITION_TP);

      if(type==POSITION_TYPE_BUY)
        {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double profit = bid - openPrice;
         if(profit >= Trail_Start_ATR * atr)
           {
            double newSL = bid - Trail_Distance_ATR * atr;
            if(newSL > curSL + _Point && (bid - newSL) > stopsLevel)
               trade.PositionModify(ticket, NormalizeDouble(newSL,_Digits), curTP);
           }
        }
      else if(type==POSITION_TYPE_SELL)
        {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profit = openPrice - ask;
         if(profit >= Trail_Start_ATR * atr)
           {
            double newSL = ask + Trail_Distance_ATR * atr;
            if((curSL==0 || newSL < curSL - _Point) && (newSL - ask) > stopsLevel)
               trade.PositionModify(ticket, NormalizeDouble(newSL,_Digits), curTP);
           }
        }
     }
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   UpdateDailyLossState();

   // Trail existing positions every tick (not just on new bar)
   double atrNow[];
   ArraySetAsSeries(atrNow, true);
   if(CopyBuffer(atrHandle, 0, 0, 1, atrNow) > 0)
      ManageTrailing(atrNow[0]);

   if(!IsNewBar()) return;   // evaluate new entries only once per bar

   // ---- Pull last CLOSED bar's indicator values (index 1) ----
   double emaFast[], emaSlow[], rsi[], atr[];
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(atr, true);

   if(CopyBuffer(emaFastHandle, 0, 1, 1, emaFast) <= 0) return;
   if(CopyBuffer(emaSlowHandle, 0, 1, 1, emaSlow) <= 0) return;
   if(CopyBuffer(rsiHandle,     0, 1, 1, rsi)     <= 0) return;
   if(CopyBuffer(atrHandle,     0, 1, 1, atr)     <= 0) return;

   double fast = emaFast[0];
   double slow = emaSlow[0];
   double rsiVal = rsi[0];
   double atrVal = atr[0];
   if(atrVal <= 0) return;

   bool uptrend   = fast > slow;
   bool downtrend = fast < slow;

   bool buySignal  = uptrend   && rsiVal > RSI_BuyMin  && rsiVal < RSI_BuyMax;
   bool sellSignal = downtrend && rsiVal < RSI_SellMax && rsiVal > RSI_SellMin;

   if(!buySignal && !sellSignal) return;
   if(dailyLimitHit) return;
   if(SpreadPoints() > MaxSpreadPoints) return;
   if(!WithinSession()) return;

   double slDistance = SL_ATR_Multiplier * atrVal;
   double tpDistance = TP_ATR_Multiplier * atrVal;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(buySignal)
     {
      int existing = CountPositions(1);
      int maxAllowed = AllowPyramiding ? MaxPositions : 1;
      if(existing >= maxAllowed) return;

      if(existing > 0)
        {
         double lastPrice = LastEntryPrice(1);
         if(lastPrice > 0 && (ask - lastPrice) < PyramidStep_ATR * atrVal) return;
        }

      double lot = CalculateLotSize(slDistance);
      if(lot <= 0) return;

      double projectedRisk = OpenRiskMoney(slDistance) + (slDistance/SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE))*SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE)*lot;
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity>0 && projectedRisk > equity * (MaxTotalRiskPercent/100.0)) return;

      double sl = NormalizeDouble(ask - slDistance, _Digits);
      double tp = NormalizeDouble(ask + tpDistance, _Digits);
      trade.Buy(lot, _Symbol, ask, sl, tp, TradeComment);
     }
   else if(sellSignal)
     {
      int existing = CountPositions(-1);
      int maxAllowed = AllowPyramiding ? MaxPositions : 1;
      if(existing >= maxAllowed) return;

      if(existing > 0)
        {
         double lastPrice = LastEntryPrice(-1);
         if(lastPrice > 0 && (lastPrice - bid) < PyramidStep_ATR * atrVal) return;
        }

      double lot = CalculateLotSize(slDistance);
      if(lot <= 0) return;

      double projectedRisk = OpenRiskMoney(slDistance) + (slDistance/SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE))*SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE)*lot;
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity>0 && projectedRisk > equity * (MaxTotalRiskPercent/100.0)) return;

      double sl = NormalizeDouble(bid + slDistance, _Digits);
      double tp = NormalizeDouble(bid - tpDistance, _Digits);
      trade.Sell(lot, _Symbol, bid, sl, tp, TradeComment);
     }
  }
//+------------------------------------------------------------------+
