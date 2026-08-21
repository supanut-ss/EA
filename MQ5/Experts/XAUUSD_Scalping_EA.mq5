//+------------------------------------------------------------------+
//|                                       XAUUSD_Scalping_EA.mq5     |
//|  Strategy: Scalping & Session-Based (XAUUSD) - EA #2             |
//|  Complements XAUUSD_TrendBreakout_EA.mq5 (separate Magic Number, |
//|  can run on the same account/symbol at the same time)            |
//|                                                                    |
//|  Logic:                                                           |
//|   1) Regime detector on H1: ADX(14) vs threshold decides TREND    |
//|      vs RANGE/CHOPPY regime (same threshold style as EA #1) -     |
//|      this EA scalps in BOTH regimes, switching entry logic:       |
//|        - TREND regime: micro pullback-scalp on M5 IN THE          |
//|          DIRECTION of the H1 trend (EMA50/200 + ADX +DI/-DI). The |
//|          setup bar's wick must actually touch/cross the M5 fast   |
//|          EMA (a real price-action pullback) and the next bar must |
//|          close back on the trend side of it, with RSI in a        |
//|          moderate (non-extreme) band just confirming we are not   |
//|          already overextended. (v1 used a plain "RSI crosses the  |
//|          45/55 midline" trigger - too noisy, replaced after the   |
//|          first optimize round only reached PF ~1.08 best-case.)   |
//|        - RANGE/CHOPPY regime: mean-reversion on M5 (Bollinger     |
//|          Bands + RSI extreme), but requires a 2-BAR confirmation  |
//|          pattern (setup bar closes beyond the band with an        |
//|          extreme RSI, then the NEXT closed bar must already be    |
//|          back inside the band) before entering - this is the      |
//|          extra caution required for the choppiest, most fakeout-  |
//|          prone regime, instead of catching the first extreme bar. |
//|   2) Exit: fixed ATR-based SL (wider multiplier in RANGE regime   |
//|      to survive wick noise). TREND mode TP = SL distance x        |
//|      Risk:Reward. RANGE mode TP is capped at the middle Bollinger |
//|      Band (the actual mean this thesis bets on reverting to) if   |
//|      that is closer than the fixed R:R distance. Plus a time-based|
//|      exit if a trade sits open too many bars without hitting      |
//|      TP/SL (the pullback/reversion thesis decays fast).           |
//|   3) HARD SAFETY REQUIREMENT (independent of the above, applies   |
//|      to every open position regardless of regime): no position    |
//|      may be left open across a market break or market close.     |
//|      Reads the broker's real per-symbol trading schedule via      |
//|      SymbolInfoSessionTrade() and, inside a configurable buffer   |
//|      before the next session close, blocks new entries AND force- |
//|      closes every open position of this EA. Falls back to a      |
//|      simple Friday-cutoff/no-weekend rule if that API is disabled.|
//|                                                                    |
//|  IMPORTANT: See XAUUSD_Scalping_Spec.md for the design rationale, |
//|  parameter values, and backtest history before any live use.      |
//+------------------------------------------------------------------+
#property copyright "Custom EA - Scalping & Session-Based"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

// This EA's own ingest defaults - matches its real registration in the
// backend DB (ea_id=2, "Scalping & Session") and the live production
// host, so a fresh attach no longer needs manual reconfiguration (see
// EaIngestClient.mqh for how these override the shared fallback).
#define INGEST_DEFAULT_EA_ID 2
#define INGEST_DEFAULT_BASE_URL "https://ea.thaipesleague.com"
// Distinct from EA1's/EA3's heartbeat interval on purpose - see the
// incident note in EaIngestClient.mqh next to INGEST_DEFAULT_HEARTBEAT_SEC.
#define INGEST_DEFAULT_HEARTBEAT_SEC 31
// Not a sensitive secret (shared low-value gate in front of the ingest
// endpoints, not an account/broker credential) - defaulting it on plus
// InpIngestEnabled=true (2026-08-21+) means a fresh attach reports to the
// backend immediately with no manual setup. Must match backend's
// Ingest:ApiKey (see deploy-single-host.ps1's $IngestApiKey, local-only,
// git-ignored).
#define INGEST_DEFAULT_ENABLED true
#define INGEST_DEFAULT_API_KEY "33be34ac24f13a1131f00b8451c9be4a1e3dbc1a5bfee721fd45f2f8142ede86"
#include <EaIngestClient.mqh>

CTrade trade;

//--- Inputs: General
input group "=== General Settings ==="
input double   InpLotSize              = 0.01;      // Fixed Lot Size
input ulong    InpMagicNumber          = 20260812;   // Magic Number (must differ from EA #1)
input int      InpSlippage             = 20;         // Slippage (points)
input int      InpMaxOpenPositions     = 2;          // Max Open Positions (this EA)
input int      InpMaxTradesPerDayTrend = 15;         // Max Trades/Day - Trend Mode
input int      InpMaxTradesPerDayChoppy = 8;         // Max Trades/Day - Range/Choppy Mode (extra caution)

// Defaults below (InpAdxThreshold, InpRsiPullbackDeepLow/High, InpRsiOversold,
// InpAtrSlMultRange, InpRiskReward, InpMaxBarsInTrade) come from genetic
// optimization round 3 (Pass 2180, filtered to Trades>=200 to avoid the
// overfit top-ranked pass that traded only 39 times) + round 4 (confirmed
// InpAtrSlMultRange=0.4 is a real local optimum, not a search-range edge
// artifact). XAUUSD M5, 2026.02.11-2026.08.11: 218 trades, PF 1.62, Max DD
// 3.30%, Net Profit $148.68 on $1000/0.01 lot.
input group "=== Regime Filter (Higher Timeframe H1) ==="
input ENUM_TIMEFRAMES InpRegimeTF  = PERIOD_H1; // Regime Timeframe
input int      InpAdxPeriod        = 14;        // ADX Period
input double   InpAdxThreshold     = 25.0;      // ADX Threshold: >=Trend, <Range/Choppy
input int      InpEmaFastH1        = 50;        // EMA Fast Period (trend direction)
input int      InpEmaSlowH1        = 200;       // EMA Slow Period (trend direction)

input group "=== Entry - Trend Mode (M5, pullback WITH the H1 trend) ==="
input ENUM_TIMEFRAMES InpEntryTF   = PERIOD_M5; // Entry Timeframe
input int      InpEmaFastM5        = 20;        // M5 Fast EMA (pullback confirmation)
input int      InpRsiPeriod        = 14;        // RSI Period (shared by both modes)
input double   InpRsiPullbackLow   = 45.0;      // RSI level: uptrend recovery trigger
input double   InpRsiPullbackHigh  = 55.0;      // RSI level: downtrend recovery trigger
input double   InpRsiPullbackDeepLow  = 25.0;   // RSI must have dipped below this (uptrend) to count as a real pullback
input double   InpRsiPullbackDeepHigh = 65.0;   // RSI must have risen above this (downtrend) to count as a real pullback
input int      InpPullbackLookbackBars = 6;      // Bars to scan for the RSI dip/rise before the recovery bar

input group "=== Entry - Range/Choppy Mode (M5, mean-reversion, 2-bar confirm) ==="
input int      InpBbPeriod         = 20;        // Bollinger Bands Period
input double   InpBbDeviation      = 2.5;       // Bollinger Bands Deviation
input double   InpRsiOversold      = 45.0;      // RSI Oversold Level (setup bar)
input double   InpRsiOverbought    = 80.0;      // RSI Overbought Level (setup bar)

input group "=== Risk Management ==="
input int      InpAtrPeriod        = 14;        // ATR Period (M5)
input double   InpAtrSlMultTrend   = 1.0;        // ATR Multiplier for SL - Trend Mode
input double   InpAtrSlMultRange   = 0.4;        // ATR Multiplier for SL - Range Mode (wider, wick noise)
input double   InpRiskReward       = 1.0;        // Risk:Reward Ratio (TP distance)
input int      InpMaxBarsInTrade   = 36;         // Time-based exit: close after N entry-TF bars

input group "=== Breakeven & Trailing (profit lock) - TESTED, KEEP ON ==="
// This EA had NO stop management at all: every trade sat on its original fixed SL
// until TP, SL or the time stop. All 280 stop-outs were real losses averaging
// -5.59 against 218 TP hits averaging +8.08. Adding the profit lock roughly HALVED
// drawdown on the 2026.01.01-08.13 backtest (stops-only run vs baseline):
//   baseline     $180.65  DD 24.75%  PF 1.11  Recovery 0.71
//   stops on     $169.59  DD 15.45%  PF 1.14  Recovery 1.08
// Slightly less profit, far less risk. Note the same change made EA #1 worse - it
// is a 41%-win / big-payoff system that needs its winners to run, while this EA
// takes many small trades where banking the move is the better trade-off.
input bool     InpUseBreakeven     = true;       // Move SL to entry+buffer once far enough in profit
input double   InpBETriggerAtrMult = 0.8;        // Profit (in ATR) required before locking breakeven
input int      InpBELockPoints     = 20;         // Profit locked at breakeven (points, covers spread/commission)
input bool     InpUseTrailing      = true;       // Trail the stop behind price after breakeven
input double   InpTrailAtrMult     = 1.0;        // Trailing Stop ATR Multiplier

input group "=== Loss Streak Protection - TESTED, KEEP ON ==="
// Max consecutive losses here was 15 (EA #1 = 10, EA #3 = 4), and trades opened
// while already 3+ losses deep lost a net -64.52 over 86 trades: this EA keeps
// firing into losing runs, unlike EA #1 whose post-streak trades were net +152.98
// (which is why the same guards are disabled there). Guards-only run vs baseline:
//   baseline     $180.65  DD 24.75%  PF 1.11  Recovery 0.71
//   guards on    $239.77  DD 20.50%  PF 1.20  Recovery 1.14
// More profit AND less drawdown. Combined with the stops above the full set gives
// $198.69 / DD 13.20% / PF 1.22 / Recovery 1.49 - the best risk-adjusted result of
// the four combinations, which is what ships as the default here.
input bool     InpUseDailyLossGuard = true;      // Stop opening new trades after N losses in one day
input int      InpMaxDailyLosses    = 4;         // Maximum losing trades per day (higher than EA #1: this EA trades more)
input bool     InpUseLossCooldown   = true;      // Pause new entries for a while after a losing trade
input int      InpLossCooldownMins  = 45;        // Cooldown length after a loss (minutes)

input group "=== Spread Filter ==="
input double   InpMaxSpreadPoints  = 200;        // Max Allowed Spread (points)
// Sunday is a thin, gap-prone half session. EA #1 already skips it; this EA did
// not, and its 21 Sunday trades won only 28.6% for a net -19.01.
input bool     InpAvoidSunday       = true;      // Do not trade on Sunday

input group "=== Safety - No Overnight/Break Positions (hard requirement) ==="
input bool     InpUseSymbolSessionTrade   = true; // Use broker's real session schedule (SymbolInfoSessionTrade)
input int      InpFlattenBufferMinutes    = 20;   // Block new trades & flatten this many minutes before close
input int      InpFridayFallbackCutoffHour = 20;  // Fallback only (if session-trade API disabled): Friday cutoff hour

//--- Global variables
int handleAdxH1, handleEmaFastH1, handleEmaSlowH1;
int handleRsiM5, handleBbM5, handleEmaFastM5, handleAtrM5;
datetime lastBarTime        = 0;
datetime lastTradeDay       = 0;
int      tradesTodayTrend   = 0;
int      tradesTodayChoppy  = 0;
bool     g_blockNewEntries  = false;
string   symbolName;
datetime g_testStartTime    = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   symbolName = _Symbol;
   g_testStartTime = TimeCurrent();

   handleAdxH1     = iADX(symbolName, InpRegimeTF, InpAdxPeriod);
   handleEmaFastH1 = iMA(symbolName, InpRegimeTF, InpEmaFastH1, 0, MODE_EMA, PRICE_CLOSE);
   handleEmaSlowH1 = iMA(symbolName, InpRegimeTF, InpEmaSlowH1, 0, MODE_EMA, PRICE_CLOSE);
   handleRsiM5     = iRSI(symbolName, InpEntryTF, InpRsiPeriod, PRICE_CLOSE);
   handleBbM5      = iBands(symbolName, InpEntryTF, InpBbPeriod, 0, InpBbDeviation, PRICE_CLOSE);
   handleEmaFastM5 = iMA(symbolName, InpEntryTF, InpEmaFastM5, 0, MODE_EMA, PRICE_CLOSE);
   handleAtrM5     = iATR(symbolName, InpEntryTF, InpAtrPeriod);

   if(handleAdxH1==INVALID_HANDLE || handleEmaFastH1==INVALID_HANDLE || handleEmaSlowH1==INVALID_HANDLE ||
      handleRsiM5==INVALID_HANDLE || handleBbM5==INVALID_HANDLE || handleEmaFastM5==INVALID_HANDLE ||
      handleAtrM5==INVALID_HANDLE)
   {
      Print("Failed to create indicator handle(s)");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(symbolName);

   EventSetTimer(InpIngestHeartbeatSec);
   IngestPrintStartupInfo();
   IngestSetEaStatus("active");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   IngestSetEaStatus("standby");

   IndicatorRelease(handleAdxH1);
   IndicatorRelease(handleEmaFastH1);
   IndicatorRelease(handleEmaSlowH1);
   IndicatorRelease(handleRsiM5);
   IndicatorRelease(handleBbM5);
   IndicatorRelease(handleEmaFastM5);
   IndicatorRelease(handleAtrM5);
}

//+------------------------------------------------------------------+
void OnTimer()
{
   IngestSendHeartbeat(symbolName);
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   IngestHandleTradeTransaction(trans, InpMagicNumber, symbolName);
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
      tradesTodayTrend  = 0;
      tradesTodayChoppy = 0;
      lastTradeDay      = TimeCurrent();
   }
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
void CloseAllMyPositions()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbolName) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber) continue;
      trade.PositionClose(ticket);
   }
}

//+------------------------------------------------------------------+
// Seconds remaining until the currently active broker trading session
// for this symbol closes. Returns 0 if we are not inside any session
// right now (already in a break / already closed).
//+------------------------------------------------------------------+
long SecondsToSessionClose()
{
   datetime now = TimeTradeServer();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   long nowSec = dt.hour*3600 + dt.min*60 + dt.sec;
   ENUM_DAY_OF_WEEK dow = (ENUM_DAY_OF_WEEK)dt.day_of_week;

   for(int i=0; i<8; i++)
   {
      datetime from, to;
      if(!SymbolInfoSessionTrade(symbolName, dow, i, from, to)) break;
      long fromSec = (long)from;
      long toSec   = (long)to;
      if(nowSec >= fromSec && nowSec < toSec)
         return (toSec - nowSec);
   }
   return 0;
}

//+------------------------------------------------------------------+
// Hard safety requirement: block new entries and flatten every open
// position of this EA whenever we are within InpFlattenBufferMinutes
// of the next market break/close. Independent of regime/entry logic.
//+------------------------------------------------------------------+
void EnforceNoOvernightPositions()
{
   if(InpUseSymbolSessionTrade)
   {
      long secondsLeft = SecondsToSessionClose();
      g_blockNewEntries = (secondsLeft <= (long)InpFlattenBufferMinutes * 60);
   }
   else
   {
      MqlDateTime dt;
      TimeToStruct(TimeTradeServer(), dt);
      g_blockNewEntries = (dt.day_of_week == 0 || dt.day_of_week == 6 ||
                            (dt.day_of_week == 5 && dt.hour >= InpFridayFallbackCutoffHour));
   }

   if(g_blockNewEntries)
      CloseAllMyPositions();
}

//+------------------------------------------------------------------+
// Returns 1 = TREND regime, 0 = RANGE/CHOPPY regime.
// When TREND, also sets bias: 1 = bullish, -1 = bearish, 0 = unclear
// (ADX high but EMA/DI direction disagree - skip trend entries this bar).
//+------------------------------------------------------------------+
int GetRegime(int &bias)
{
   bias = 0;

   double adxMain[], adxPlus[], adxMinus[], emaFast[], emaSlow[];
   ArraySetAsSeries(adxMain, true);
   ArraySetAsSeries(adxPlus, true);
   ArraySetAsSeries(adxMinus, true);
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);

   if(CopyBuffer(handleAdxH1, 0, 0, 3, adxMain) < 3) return 0;
   if(CopyBuffer(handleAdxH1, 1, 0, 3, adxPlus) < 3) return 0;
   if(CopyBuffer(handleAdxH1, 2, 0, 3, adxMinus) < 3) return 0;
   if(CopyBuffer(handleEmaFastH1, 0, 0, 3, emaFast) < 3) return 0;
   if(CopyBuffer(handleEmaSlowH1, 0, 0, 3, emaSlow) < 3) return 0;

   if(adxMain[0] < InpAdxThreshold) return 0; // RANGE/CHOPPY regime

   if(emaFast[0] > emaSlow[0] && adxPlus[0] > adxMinus[0])
      bias = 1;
   else if(emaFast[0] < emaSlow[0] && adxMinus[0] > adxPlus[0])
      bias = -1;

   return 1; // TREND regime (bias may still be 0 if direction is unclear)
}

//+------------------------------------------------------------------+
double GetAtrM5()
{
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(handleAtrM5, 0, 1, 1, atr) < 1) return 0;
   return atr[0];
}

//+------------------------------------------------------------------+
bool OpenTrade(ENUM_ORDER_TYPE type, double sl, double tp, string comment)
{
   int digits = (int)SymbolInfoInteger(symbolName, SYMBOL_DIGITS);
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   bool result = false;
   if(type == ORDER_TYPE_BUY)
      result = trade.Buy(InpLotSize, symbolName, 0, sl, tp, comment);
   else
      result = trade.Sell(InpLotSize, symbolName, 0, sl, tp, comment);

   if(result)
   {
      Print("Trade opened: ", EnumToString(type), " Lots=", InpLotSize, " SL=", sl, " TP=", tp);

      ulong dealTicket = trade.ResultDeal();
      if(IngestHistoryDealSelectRetry(dealTicket))
      {
         ulong positionId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
         double openPrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
         datetime openTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
         double swap = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
         double commission = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
         string side = (type == ORDER_TYPE_BUY) ? "BUY" : "SELL";

         double slAmount = 0, tpAmount = 0;
         bool slCalcOk = OrderCalcProfit(type, symbolName, InpLotSize, openPrice, sl, slAmount);
         bool tpCalcOk = OrderCalcProfit(type, symbolName, InpLotSize, openPrice, tp, tpAmount);

         IngestTrackOpen(positionId, side, InpLotSize, openPrice, sl, tp, slAmount, tpAmount, openTime);
         IngestTradeOpened(positionId, symbolName, side, InpLotSize, openPrice, sl, tp,
                            slAmount, tpAmount, openTime, swap, commission);
      }
   }
   else
   {
      Print("OrderSend failed. Error: ", GetLastError(),
            " Retcode: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      IngestLog(InpIngestEaId, "error", StringFormat("OrderSend failed: retcode=%d %s",
                trade.ResultRetcode(), trade.ResultRetcodeDescription()));
   }

   return result;
}

//+------------------------------------------------------------------+
// TREND regime entry: micro pullback-scalp WITH the H1 trend on M5.
//
// v1 used "RSI crosses the 45/55 midline" - fired on noise (RSI wobbles
// across its own midline constantly). v2 replaced it with "wick touches
// the M5 EMA" - fired even MORE often (a real backtest showed ~7.5
// trades/day from this mode alone, blowing past the whole EA's 3-8/day
// target and pushing Max DD from ~20% to ~28%), because a candle wick
// grazing a nearby EMA is common noise too, and nothing stopped it from
// re-firing on every bar while price chopped near the EMA.
//
// v3 requires BOTH: (a) a FRESH cross - the prior bar's CLOSE must still
// be on the pullback side of the EMA and only the current bar closes
// back on the trend side, so this can only fire once per pullback, not
// every bar price hovers near the EMA; and (b) a GENUINE dip - RSI must
// have actually reached a deep pullback level (InpRsiPullbackDeepLow/
// High) within the last InpPullbackLookbackBars bars, not just brushed
// the neutral zone, before recovering past InpRsiPullbackLow/High.
//+------------------------------------------------------------------+
void TryTrendEntry(int bias)
{
   if(bias == 0) { Print("Entry skip: TREND regime but bias unclear (EMA/DI disagree)"); return; }
   if(tradesTodayTrend >= InpMaxTradesPerDayTrend) { Print("Entry skip: TREND daily cap reached (", InpMaxTradesPerDayTrend, ")"); return; }

   int lookback = InpPullbackLookbackBars + 2;
   double rsi[], emaFastM5buf[], closeBuf[];
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(emaFastM5buf, true);
   ArraySetAsSeries(closeBuf, true);
   if(CopyBuffer(handleRsiM5, 0, 0, lookback, rsi) < lookback) return;
   if(CopyBuffer(handleEmaFastM5, 0, 0, lookback, emaFastM5buf) < lookback) return;
   if(CopyClose(symbolName, InpEntryTF, 0, lookback, closeBuf) < lookback) return;

   double atr = GetAtrM5();
   if(atr <= 0) return;

   double ask = SymbolInfoDouble(symbolName, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbolName, SYMBOL_BID);

   bool freshCrossUp   = closeBuf[2] <= emaFastM5buf[2] && closeBuf[1] > emaFastM5buf[1];
   bool freshCrossDown = closeBuf[2] >= emaFastM5buf[2] && closeBuf[1] < emaFastM5buf[1];

   double minRsi = rsi[1];
   double maxRsi = rsi[1];
   for(int i=2; i<=InpPullbackLookbackBars+1; i++)
   {
      minRsi = MathMin(minRsi, rsi[i]);
      maxRsi = MathMax(maxRsi, rsi[i]);
   }

   if(bias == 1 && freshCrossUp && rsi[1] >= InpRsiPullbackLow && minRsi <= InpRsiPullbackDeepLow)
   {
      double sl = ask - atr * InpAtrSlMultTrend;
      double dist = ask - sl;
      double tp = ask + dist * InpRiskReward;
      IngestLog(InpIngestEaId, "info", StringFormat(
         "Trend pullback BUY signal: RSI recovered to %s (dipped to %s), fresh EMA cross up",
         DoubleToString(rsi[1], 1), DoubleToString(minRsi, 1)));
      if(OpenTrade(ORDER_TYPE_BUY, sl, tp, "Scalp Buy Trend")) tradesTodayTrend++;
   }
   else if(bias == -1 && freshCrossDown && rsi[1] <= InpRsiPullbackHigh && maxRsi >= InpRsiPullbackDeepHigh)
   {
      double sl = bid + atr * InpAtrSlMultTrend;
      double dist = sl - bid;
      double tp = bid - dist * InpRiskReward;
      IngestLog(InpIngestEaId, "info", StringFormat(
         "Trend pullback SELL signal: RSI recovered to %s (rose to %s), fresh EMA cross down",
         DoubleToString(rsi[1], 1), DoubleToString(maxRsi, 1)));
      if(OpenTrade(ORDER_TYPE_SELL, sl, tp, "Scalp Sell Trend")) tradesTodayTrend++;
   }
   else
   {
      Print("Entry skip: TREND bias=", bias, " no pullback setup (RSI=", DoubleToString(rsi[1], 1),
            " crossUp=", freshCrossUp, " crossDown=", freshCrossDown, ")");
   }
}

//+------------------------------------------------------------------+
// RANGE/CHOPPY regime entry: mean-reversion on M5 with a 2-bar
// confirmation pattern - setup bar closes beyond the Bollinger Band
// with an extreme RSI, then the NEXT closed bar must already be back
// inside the band before we enter. Extra caution for the choppiest,
// most fakeout-prone regime instead of catching the first extreme bar.
//
// TP is capped at the middle band (the actual "mean" this thesis bets
// on reverting to) instead of always using the fixed R:R distance -
// v1 used a plain fixed R:R here too, which can aim past how far a
// reversion inside a tight/choppy range actually travels.
//+------------------------------------------------------------------+
void TryRangeEntry()
{
   if(tradesTodayChoppy >= InpMaxTradesPerDayChoppy) { Print("Entry skip: RANGE daily cap reached (", InpMaxTradesPerDayChoppy, ")"); return; }

   double rsi[], bbUpper[], bbLower[], bbMiddle[];
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(bbUpper, true);
   ArraySetAsSeries(bbLower, true);
   ArraySetAsSeries(bbMiddle, true);
   if(CopyBuffer(handleRsiM5, 0, 0, 3, rsi) < 3) return;
   if(CopyBuffer(handleBbM5, 1, 0, 3, bbUpper) < 3) return;  // MODE_UPPER
   if(CopyBuffer(handleBbM5, 2, 0, 3, bbLower) < 3) return;  // MODE_LOWER
   if(CopyBuffer(handleBbM5, 0, 0, 3, bbMiddle) < 3) return; // MODE_MAIN

   double close1 = iClose(symbolName, InpEntryTF, 1); // confirmation bar
   double close2 = iClose(symbolName, InpEntryTF, 2); // setup bar

   double atr = GetAtrM5();
   if(atr <= 0) return;

   double ask = SymbolInfoDouble(symbolName, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbolName, SYMBOL_BID);

   bool buySetup    = close2 < bbLower[2] && rsi[2] <= InpRsiOversold;
   bool buyConfirm   = close1 >= bbLower[1];
   bool sellSetup   = close2 > bbUpper[2] && rsi[2] >= InpRsiOverbought;
   bool sellConfirm  = close1 <= bbUpper[1];

   if(buySetup && buyConfirm)
   {
      double sl = ask - atr * InpAtrSlMultRange;
      double rrTp = ask + (ask - sl) * InpRiskReward;
      double tp = (bbMiddle[1] > ask) ? MathMin(rrTp, bbMiddle[1]) : rrTp;
      IngestLog(InpIngestEaId, "info", StringFormat(
         "Range mean-reversion BUY signal: setup closed below BB lower %s (RSI %s), confirmed back inside",
         DoubleToString(bbLower[2], 2), DoubleToString(rsi[2], 1)));
      if(OpenTrade(ORDER_TYPE_BUY, sl, tp, "Scalp Buy Range")) tradesTodayChoppy++;
   }
   else if(sellSetup && sellConfirm)
   {
      double sl = bid + atr * InpAtrSlMultRange;
      double rrTp = bid - (sl - bid) * InpRiskReward;
      double tp = (bbMiddle[1] < bid) ? MathMax(rrTp, bbMiddle[1]) : rrTp;
      IngestLog(InpIngestEaId, "info", StringFormat(
         "Range mean-reversion SELL signal: setup closed above BB upper %s (RSI %s), confirmed back inside",
         DoubleToString(bbUpper[2], 2), DoubleToString(rsi[2], 1)));
      if(OpenTrade(ORDER_TYPE_SELL, sl, tp, "Scalp Sell Range")) tradesTodayChoppy++;
   }
   else
   {
      Print("Entry skip: RANGE no setup (RSI=", DoubleToString(rsi[2], 1),
            " buySetup=", buySetup, " sellSetup=", sellSetup, ")");
   }
}

//+------------------------------------------------------------------+
// Count this EA's losing closes for the current broker day and find the most
// recent one. Read from trade history rather than tracked in a counter so the
// guards keep working after a terminal restart or a mid-day reattach, and so a
// manual close is counted the same as an EA close.
//+------------------------------------------------------------------+
void GetTodayLossStats(int &lossesToday, datetime &lastLossTime)
{
   lossesToday  = 0;
   lastLossTime = 0;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime dayStart = StructToTime(dt);

   if(!HistorySelect(dayStart, TimeCurrent() + 1)) return;

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != symbolName) continue;
      if((ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagicNumber) continue;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) continue;

      // Net result, not gross: a trade closed a hair above the stop still counts
      // as a loss once commission and swap are paid.
      double net = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                 + HistoryDealGetDouble(ticket, DEAL_SWAP)
                 + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      if(net >= 0) continue;

      lossesToday++;
      datetime closeTime = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
      if(closeTime > lastLossTime) lastLossTime = closeTime;
   }
}

//+------------------------------------------------------------------+
bool IsLossGuardBlocking()
{
   if(!InpUseDailyLossGuard && !InpUseLossCooldown) return false;

   int lossesToday; datetime lastLossTime;
   GetTodayLossStats(lossesToday, lastLossTime);

   if(InpUseDailyLossGuard && lossesToday >= InpMaxDailyLosses)
      return true;

   if(InpUseLossCooldown && lastLossTime > 0 &&
      (TimeCurrent() - lastLossTime) < (long)InpLossCooldownMins * 60)
      return true;

   return false;
}

//+------------------------------------------------------------------+
// Two-stage stop management, applied in this order per position:
//   1) Breakeven - once the trade is InpBETriggerAtrMult ATR in profit, pull the
//      stop to entry plus InpBELockPoints so the trade can no longer close red.
//   2) ATR trail - keep the stop InpTrailAtrMult ATR behind price.
// The stop only ever moves in the favourable direction, so the trail can never
// undo the breakeven lock.
//+------------------------------------------------------------------+
void ManagePositionStops()
{
   if(!InpUseTrailing && !InpUseBreakeven) return;

   double atr = GetAtrM5();
   if(atr <= 0) return;

   int    digits = (int)SymbolInfoInteger(symbolName, SYMBOL_DIGITS);
   double point  = SymbolInfoDouble(symbolName, SYMBOL_POINT);
   double lock   = InpBELockPoints * point;

   for(int i=0; i<PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbolName) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber) continue;

      long   type      = PositionGetInteger(POSITION_TYPE);
      double posSl     = PositionGetDouble(POSITION_SL);
      double posTp     = PositionGetDouble(POSITION_TP);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);

      if(type == POSITION_TYPE_BUY)
      {
         double bid       = SymbolInfoDouble(symbolName, SYMBOL_BID);
         double desiredSl = posSl;

         if(InpUseBreakeven && (bid - openPrice) >= atr * InpBETriggerAtrMult)
         {
            double beSl = openPrice + lock;
            if(beSl > desiredSl) desiredSl = beSl;
         }
         if(InpUseTrailing)
         {
            double trailSl = bid - atr * InpTrailAtrMult;
            if(trailSl > desiredSl) desiredSl = trailSl;
         }

         desiredSl = NormalizeDouble(desiredSl, digits);
         if(desiredSl > posSl && desiredSl < bid)
            trade.PositionModify(ticket, desiredSl, posTp);
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double ask       = SymbolInfoDouble(symbolName, SYMBOL_ASK);
         double desiredSl = (posSl == 0) ? DBL_MAX : posSl;

         if(InpUseBreakeven && (openPrice - ask) >= atr * InpBETriggerAtrMult)
         {
            double beSl = openPrice - lock;
            if(beSl < desiredSl) desiredSl = beSl;
         }
         if(InpUseTrailing)
         {
            double trailSl = ask + atr * InpTrailAtrMult;
            if(trailSl < desiredSl) desiredSl = trailSl;
         }

         if(desiredSl == DBL_MAX) continue;
         desiredSl = NormalizeDouble(desiredSl, digits);
         if((posSl == 0 || desiredSl < posSl) && desiredSl > ask)
            trade.PositionModify(ticket, desiredSl, posTp);
      }
   }
}

//+------------------------------------------------------------------+
void CheckForEntry()
{
   if(g_blockNewEntries) { Print("Entry skip: flatten buffer (near session close/break)"); return; }
   if(CountOpenPositions() >= InpMaxOpenPositions) { Print("Entry skip: max open positions (", InpMaxOpenPositions, ")"); return; }
   if(!IsSpreadOk()) { Print("Entry skip: spread ", (int)SymbolInfoInteger(symbolName, SYMBOL_SPREAD), " > max ", (int)InpMaxSpreadPoints, " pts"); return; }

   if(InpAvoidSunday)
   {
      MqlDateTime now;
      TimeToStruct(TimeCurrent(), now);
      if(now.day_of_week == 0) { Print("Entry skip: Sunday"); return; }
   }

   if(IsLossGuardBlocking()) { Print("Entry skip: loss guard active"); return; }

   int bias;
   int regime = GetRegime(bias);

   if(regime == 1)
      TryTrendEntry(bias);
   else
      TryRangeEntry();
}

//+------------------------------------------------------------------+
// Time-based exit: the pullback/reversion thesis decays fast - close
// any position of this EA that has been open too many entry-TF bars
// without hitting TP or SL.
//+------------------------------------------------------------------+
void ManageTimeBasedExit()
{
   long maxSeconds = (long)InpMaxBarsInTrade * PeriodSeconds(InpEntryTF);

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbolName) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber) continue;

      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      if(TimeCurrent() - openTime >= maxSeconds)
         trade.PositionClose(ticket);
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   ResetDailyCounterIfNeeded();
   EnforceNoOvernightPositions();
   ManagePositionStops();
   ManageTimeBasedExit();

   if(!IsNewBar()) return;

   CheckForEntry();
}

//+------------------------------------------------------------------+
//| Custom optimization criterion (Optimization Criterion = Custom max)|
//| Same shape as EA #1's OnTester(), but targets a higher trade       |
//| frequency band (3-8 trades/day) since this EA exists to raise the  |
//| combined portfolio frequency, not just match EA #1's own target.   |
//+------------------------------------------------------------------+
double OnTester()
{
   double profit = TesterStatistics(STAT_PROFIT);
   double trades = TesterStatistics(STAT_TRADES);
   double ddPct  = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);

   if(trades < 10)
      return(-1000.0 - (10 - trades));

   double totalDays    = (double)(TimeCurrent() - g_testStartTime) / 86400.0;
   double tradingDays  = MathMax(totalDays * (5.0 / 7.0), 1.0);
   double tradesPerDay = trades / tradingDays;

   double freqFactor;
   if(tradesPerDay < 3.0)
      freqFactor = tradesPerDay / 3.0;
   else if(tradesPerDay <= 8.0)
      freqFactor = 1.0;
   else
      freqFactor = MathMax(0.4, 1.0 - (tradesPerDay - 8.0) * 0.08);
   freqFactor = MathMax(freqFactor, 0.05);

   double ddFactor = MathMax(0.05, 1.0 - ddPct / 25.0);

   double score;
   if(profit >= 0)
      score = profit * freqFactor * ddFactor;
   else
      score = profit / MathMax(freqFactor * ddFactor, 0.05);

   return(score);
}
//+------------------------------------------------------------------+
