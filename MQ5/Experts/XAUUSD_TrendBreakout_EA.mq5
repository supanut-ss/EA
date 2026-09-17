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
#property version   "1.10"
#property strict

#include <Trade\Trade.mqh>

// This EA's own ingest defaults - matches its real registration in the
// backend DB (ea_id=1, "Trend Breakout") and the live production host.
// Previously left unset ("untouched" per the EA2 commit that introduced
// these overrides), which meant a fresh attach silently defaulted to
// localhost:5008 unless someone remembered to retype the production URL by
// hand - made explicit here so that footgun can't recur. Heartbeat interval
// is deliberately different from EA2's/EA3's - see the incident note next
// to INGEST_DEFAULT_HEARTBEAT_SEC in EaIngestClient.mqh.
#define INGEST_DEFAULT_EA_ID 1
#define INGEST_DEFAULT_BASE_URL "https://ea.thaipesleague.com"
#define INGEST_DEFAULT_HEARTBEAT_SEC 29
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
input double   InpLotSize          = 0.01;      // Fixed Lot Size
input ulong    InpMagicNumber      = 20260811;  // Magic Number
input int      InpSlippage         = 20;        // Slippage (points)
input int      InpMaxOpenPositions = 4;         // Max Open Positions (this EA)
input int      InpMaxTradesPerDay  = 6;         // Max New Trades Per Day

input group "=== Trend Filter (Higher Timeframe) ==="
input ENUM_TIMEFRAMES InpTrendTF   = PERIOD_H1; // Trend Timeframe
input int      InpEmaFast          = 50;        // EMA Fast Period
input int      InpEmaSlow          = 200;       // EMA Slow Period
input int      InpAdxPeriod        = 14;        // ADX Period
input double   InpAdxThreshold     = 20.0;      // ADX Minimum Threshold (trend strength)

input group "=== Breakout Settings (Entry Timeframe) ==="
input ENUM_TIMEFRAMES InpEntryTF   = PERIOD_M15; // Entry Timeframe
input int      InpDonchianPeriod   = 8;          // Donchian Channel Period (bars)
input int      InpAtrPeriod        = 14;         // ATR Period
input double   InpAtrBufferMult    = 0.30;       // ATR Buffer Multiplier (fakeout filter)

input group "=== Risk Management ==="
input double   InpAtrSlMult        = 1.5;        // ATR Multiplier for Stop Loss
input double   InpRiskReward       = 1.8;        // Risk:Reward Ratio (TP distance)
input bool     InpUseTrailing      = true;       // Use ATR Trailing Stop
input double   InpTrailAtrMult     = 1.2;        // Trailing Stop ATR Multiplier
input double   InpTrailStartAtrMult= 1.0;        // Activate trailing only after this ATR profit

input group "=== Breakeven (profit lock) - TESTED AND REJECTED, default OFF ==="
// Ported from EA #3 (which exits its stops at an average of +1.02 instead of this
// EA's -3.34) on the theory that a profit lock was the missing piece. Backtested
// 2026.01.01-08.13 and it made this EA WORSE, so it ships OFF:
//   baseline      $223.07  DD 15.18%  PF 1.18
//   breakeven on  $139.33  DD 14.85%  PF 1.11   <- costs 84 dollars of profit
// Reason: this is a LOW win rate / HIGH payoff system (41% wins; the 28 TP hits
// average +34.16 and carry the whole account against 143 losers). TP sits at
// 1.8 x 1.5*ATR = 2.7*ATR, so locking breakeven at 1*ATR gets tagged by ordinary
// retracement and converts would-be big winners into scratches. A profit lock
// suits EA #3's 67%-win mean-reversion profile, not this one. Do not enable
// without re-testing - "best practice from the better EA" did not transfer.
input bool     InpUseBreakeven     = false;      // Move SL to entry+buffer once far enough in profit
input double   InpBETriggerAtrMult = 1.0;        // Profit (in ATR) required before locking breakeven
input int      InpBELockPoints     = 20;         // Profit locked at breakeven (points, covers spread/commission)

input group "=== Loss Streak Protection - TESTED AND REJECTED, default OFF ==="
// Same story: EA #3 caps losses per day and cools off after a loss, and holds
// drawdown near 11% while this EA ran a 10-loss streak. Enabling it here made
// drawdown WORSE, not better:
//   baseline    $223.07  DD 15.18%
//   guards on   $187.39  DD 19.63%
// Reason: the per-trade diagnostic showed trades this EA opens while already 3+
// losses deep are net POSITIVE (+152.98). Its losing streaks are followed by the
// recovery trades, so sitting them out skips the drawdown repair. The same
// measurement for EA #2 was -64.52, and the guards do help there.
input bool     InpUseDailyLossGuard = false;     // Stop opening new trades after N losses in one day
input int      InpMaxDailyLosses    = 3;         // Maximum losing trades per day
input bool     InpUseLossCooldown   = false;     // Pause new entries for a while after a losing trade
input int      InpLossCooldownMins  = 75;        // Cooldown length after a loss (minutes)

input group "=== Session Filter (Broker/Server Time) ==="
input int      InpSessionStartHour = 6;          // Session Start Hour (London open through NY close)
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
bool     dailyCounterReady = false;
string   symbolName;
datetime g_testStartTime = 0;

//+------------------------------------------------------------------+
bool IsTradeRetcodeSuccessful()
{
   uint retcode = trade.ResultRetcode();
   return (retcode == TRADE_RETCODE_DONE ||
           retcode == TRADE_RETCODE_DONE_PARTIAL);
}

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
   double minVolume = SymbolInfoDouble(symbolName, SYMBOL_VOLUME_MIN);
   double maxVolume = SymbolInfoDouble(symbolName, SYMBOL_VOLUME_MAX);
   double step      = SymbolInfoDouble(symbolName, SYMBOL_VOLUME_STEP);
   if(step <= 0 || minVolume <= 0 || maxVolume <= 0) return 0;
   if(volume < minVolume || volume > maxVolume) return 0;

   double steps = MathFloor((volume + 1e-12) / step);
   double normalized = NormalizeDouble(steps * step, 8);
   if(normalized < minVolume) return 0;
   return normalized;
}

//+------------------------------------------------------------------+
double GetOpenVolume()
{
   double volume = 0;
   for(int i=0; i<PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbolName) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber) continue;
      volume += PositionGetDouble(POSITION_VOLUME);
   }
   return volume;
}

//+------------------------------------------------------------------+
datetime BrokerDayStart()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   return StructToTime(dt);
}

//+------------------------------------------------------------------+
bool LoadTodayEntryOrderCount(int &count)
{
   count = 0;
   datetime dayStart = BrokerDayStart();
   if(!HistorySelect(dayStart, TimeCurrent() + 1)) return false;

   ulong countedOrders[];
   for(int i=0; i<HistoryDealsTotal(); i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != symbolName) continue;
      if((ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagicNumber) continue;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_IN && entry != DEAL_ENTRY_INOUT) continue;

      ulong orderTicket = (ulong)HistoryDealGetInteger(ticket, DEAL_ORDER);
      if(orderTicket == 0) continue;
      bool alreadyCounted = false;
      for(int j=0; j<ArraySize(countedOrders); j++)
      {
         if(countedOrders[j] == orderTicket)
         {
            alreadyCounted = true;
            break;
         }
      }
      if(alreadyCounted) continue;

      int size = ArraySize(countedOrders);
      if(ArrayResize(countedOrders, size + 1) != size + 1) return false;
      countedOrders[size] = orderTicket;
      count++;
   }
   return true;
}

//+------------------------------------------------------------------+
int OnInit()
{
   symbolName = _Symbol;
   g_testStartTime = TimeCurrent();

   ENUM_ACCOUNT_MARGIN_MODE marginMode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("Initialization failed: this EA requires a hedging account so positions can be isolated by magic number.");
      return(INIT_FAILED);
   }

   if(InpLotSize <= 0 || InpMaxOpenPositions < 1 || InpMaxTradesPerDay < 1 ||
      InpDonchianPeriod < 2 || InpAtrPeriod < 2 ||
      InpAtrBufferMult < 0 || InpAtrSlMult <= 0 || InpRiskReward <= 0 ||
      InpTrailAtrMult <= 0 || InpTrailStartAtrMult < 0)
   {
      Print("Initialization failed: invalid strategy input(s)");
      return(INIT_PARAMETERS_INCORRECT);
   }

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

   lastBarTime  = iTime(symbolName, InpEntryTF, 0);
   lastTradeDay = TimeCurrent();
   dailyCounterReady = LoadTodayEntryOrderCount(tradesToday);
   if(!dailyCounterReady)
      Print("Trade history is not ready; entries remain blocked until the daily counter can be rebuilt.");

   EventSetTimer(InpIngestHeartbeatSec);
   IngestPrintStartupInfo();
   IngestSetEaStatus("active");
   IngestSyncOpenPositions(InpMagicNumber, symbolName);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   IngestSetEaStatus("standby");

   IndicatorRelease(handleEmaFast);
   IndicatorRelease(handleEmaSlow);
   IndicatorRelease(handleAdx);
   IndicatorRelease(handleAtrEntry);
}

//+------------------------------------------------------------------+
void OnTimer()
{
   IngestSendHeartbeat(symbolName);
   IngestSyncOpenPositions(InpMagicNumber, symbolName);
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
   if(t <= 0) return false;
   if(lastBarTime == 0)
   {
      lastBarTime = t;
      return false;
   }
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

   bool dayChanged = (lastTradeDay == 0 || now.day != lastDay.day ||
                      now.mon != lastDay.mon || now.year != lastDay.year);
   if(dayChanged || !dailyCounterReady)
   {
      int restoredCount = 0;
      dailyCounterReady = LoadTodayEntryOrderCount(restoredCount);
      if(dailyCounterReady)
      {
         tradesToday  = restoredCount;
         lastTradeDay = TimeCurrent();
      }
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
bool IsSymbolTradeSessionOpen()
{
   ENUM_SYMBOL_TRADE_MODE tradeMode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(symbolName, SYMBOL_TRADE_MODE);
   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED) return false;

   MqlDateTime now;
   TimeToStruct(TimeTradeServer(), now);
   int nowSeconds = now.hour * 3600 + now.min * 60 + now.sec;

   for(uint sessionIndex=0; ; sessionIndex++)
   {
      datetime sessionFrom, sessionTo;
      if(!SymbolInfoSessionTrade(symbolName, (ENUM_DAY_OF_WEEK)now.day_of_week,
                                 sessionIndex, sessionFrom, sessionTo))
         break;

      long fromSeconds = (long)sessionFrom % 86400;
      long toSeconds   = (long)sessionTo % 86400;
      // Equal endpoints represent a full 24-hour session. For overnight
      // sessions, move the close and pre-open clock into the following day.
      if(toSeconds <= fromSeconds) toSeconds += 86400;
      long comparableNow = nowSeconds;
      if(comparableNow < fromSeconds) comparableNow += 86400;
      if(comparableNow >= fromSeconds && comparableNow < toSeconds) return true;
   }
   return false;
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
   if(BarsCalculated(handleEmaFast) < InpEmaSlow + 2 ||
      BarsCalculated(handleEmaSlow) < InpEmaSlow + 2 ||
      BarsCalculated(handleAdx) < InpAdxPeriod + 2)
      return 0;

   double emaFast[1], emaSlow[1], adxMain[1], adxPlus[1], adxMinus[1];
   // Shift 1: use only the completed H1 candle. The bias must not change intrabar.
   if(CopyBuffer(handleEmaFast, 0, 1, 1, emaFast) != 1) return 0;
   if(CopyBuffer(handleEmaSlow, 0, 1, 1, emaSlow) != 1) return 0;
   if(CopyBuffer(handleAdx, 0, 1, 1, adxMain) != 1) return 0;
   if(CopyBuffer(handleAdx, 1, 1, 1, adxPlus) != 1) return 0;
   if(CopyBuffer(handleAdx, 2, 1, 1, adxMinus) != 1) return 0;

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
bool GetDonchianLevels(int startShift, double &channelHigh, double &channelLow)
{
   int highestIdx = iHighest(symbolName, InpEntryTF, MODE_HIGH, InpDonchianPeriod, startShift);
   int lowestIdx  = iLowest(symbolName, InpEntryTF, MODE_LOW, InpDonchianPeriod, startShift);
   if(highestIdx < 0 || lowestIdx < 0) return false;

   channelHigh = iHigh(symbolName, InpEntryTF, highestIdx);
   channelLow  = iLow(symbolName, InpEntryTF, lowestIdx);
   return true;
}

//+------------------------------------------------------------------+
double GetAtr(int shift=1)
{
   double atr[];
   ArraySetAsSeries(atr, true);
   if(BarsCalculated(handleAtrEntry) < InpAtrPeriod + shift + 1) return 0;
   if(CopyBuffer(handleAtrEntry, 0, shift, 1, atr) != 1) return 0;
   return atr[0];
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
void CheckForEntry()
{
   if(!dailyCounterReady) { Print("Entry skip: daily trade counter unavailable"); return; }
   if(CountOpenPositions() >= InpMaxOpenPositions) { Print("Entry skip: max open positions (", InpMaxOpenPositions, ")"); return; }
   if(tradesToday >= InpMaxTradesPerDay) { Print("Entry skip: daily trade cap reached (", InpMaxTradesPerDay, ")"); return; }

   double orderVolume = NormalizeVolume(InpLotSize);
   if(orderVolume <= 0) { Print("Entry skip: lot size is below broker minimum or symbol volume data is unavailable"); return; }
   double maxAggregateVolume = orderVolume * InpMaxOpenPositions;
   double symbolVolumeLimit = SymbolInfoDouble(symbolName, SYMBOL_VOLUME_LIMIT);
   if(symbolVolumeLimit > 0)
      maxAggregateVolume = MathMin(maxAggregateVolume, symbolVolumeLimit);
   double volumeStep = SymbolInfoDouble(symbolName, SYMBOL_VOLUME_STEP);
   if(GetOpenVolume() + orderVolume > maxAggregateVolume + volumeStep * 0.5)
   {
      Print("Entry skip: aggregate volume cap reached (", DoubleToString(maxAggregateVolume, 2), ")");
      return;
   }
   if(!IsWithinSession())
   {
      MqlDateTime nowDt;
      TimeToStruct(TimeCurrent(), nowDt);
      Print("Entry skip: outside session (hour=", nowDt.hour, " dow=", nowDt.day_of_week, ")");
      return;
   }
   if(!IsSymbolTradeSessionOpen()) { Print("Entry skip: broker trade session is closed"); return; }
   if(!IsSpreadOk()) { Print("Entry skip: spread ", (int)SymbolInfoInteger(symbolName, SYMBOL_SPREAD), " > max ", (int)InpMaxSpreadPoints, " pts"); return; }
   if(IsLossGuardBlocking()) { Print("Entry skip: loss guard active"); return; }

   int trend = GetTrendBias();
   if(trend == 0) { Print("Entry skip: H1 trend unclear"); return; }

   if(Bars(symbolName, InpEntryTF) < InpDonchianPeriod + 3) return;

   double channelHigh, channelLow, previousChannelHigh, previousChannelLow;
   if(!GetDonchianLevels(2, channelHigh, channelLow)) return;
   if(!GetDonchianLevels(3, previousChannelHigh, previousChannelLow)) return;

   double atr = GetAtr(1);
   double previousAtr = GetAtr(2);
   if(atr <= 0 || previousAtr <= 0) return;

   double buffer = atr * InpAtrBufferMult;
   double previousBuffer = previousAtr * InpAtrBufferMult;

   // Use the last CLOSED bar (index 1) for confirmation, and the bar
   // before it (index 2) to make sure we catch the breakout bar itself.
   double closeLast = iClose(symbolName, InpEntryTF, 1);
   double closePrev = iClose(symbolName, InpEntryTF, 2);

   double ask = SymbolInfoDouble(symbolName, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbolName, SYMBOL_BID);

   if(trend == 1 &&
      closeLast > channelHigh + buffer &&
      closePrev <= previousChannelHigh + previousBuffer)
   {
      double sl = ask - atr * InpAtrSlMult;
      double slDist = ask - sl;
      double tp = ask + slDist * InpRiskReward;
      IngestLog(InpIngestEaId, "info", StringFormat(
         "Breakout BUY signal: close %s > Donchian high %s (+buffer %s), H1 trend bullish",
         DoubleToString(closeLast, 2), DoubleToString(channelHigh, 2), DoubleToString(buffer, 2)));
      OpenTrade(ORDER_TYPE_BUY, sl, tp);
   }
   else if(trend == -1 &&
           closeLast < channelLow - buffer &&
           closePrev >= previousChannelLow - previousBuffer)
   {
      double sl = bid + atr * InpAtrSlMult;
      double slDist = sl - bid;
      double tp = bid - slDist * InpRiskReward;
      IngestLog(InpIngestEaId, "info", StringFormat(
         "Breakout SELL signal: close %s < Donchian low %s (-buffer %s), H1 trend bearish",
         DoubleToString(closeLast, 2), DoubleToString(channelLow, 2), DoubleToString(buffer, 2)));
      OpenTrade(ORDER_TYPE_SELL, sl, tp);
   }
   else
   {
      Print("Entry skip: trend=", trend, " no Donchian breakout (close=", DoubleToString(closeLast, 2),
            " high=", DoubleToString(channelHigh, 2), " low=", DoubleToString(channelLow, 2), ")");
   }
}

//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE type, double sl, double tp)
{
   MqlTick tick;
   if(!SymbolInfoTick(symbolName, tick))
   {
      Print("OrderSend skipped: current tick unavailable");
      return;
   }

   double volume = NormalizeVolume(InpLotSize);
   if(volume <= 0)
   {
      Print("OrderSend skipped: invalid normalized volume for input lot ", InpLotSize);
      return;
   }

   double point = SymbolInfoDouble(symbolName, SYMBOL_POINT);
   double minStopDistance = (double)SymbolInfoInteger(symbolName, SYMBOL_TRADE_STOPS_LEVEL) * point;
   if(type == ORDER_TYPE_BUY)
   {
      sl = NormalizePriceToTick(sl, -1);
      tp = NormalizePriceToTick(tp, 1);
      if(sl <= 0 || sl >= tick.bid - minStopDistance || tp <= tick.ask + minStopDistance)
      {
         Print("OrderSend skipped: BUY stops violate broker stop distance");
         return;
      }
   }
   else
   {
      sl = NormalizePriceToTick(sl, 1);
      tp = NormalizePriceToTick(tp, -1);
      if(sl <= tick.ask + minStopDistance || tp <= 0 || tp >= tick.bid - minStopDistance)
      {
         Print("OrderSend skipped: SELL stops violate broker stop distance");
         return;
      }
   }

   bool result = false;
   if(type == ORDER_TYPE_BUY)
      result = trade.Buy(volume, symbolName, 0, sl, tp, "TrendBreakout Buy");
   else
      result = trade.Sell(volume, symbolName, 0, sl, tp, "TrendBreakout Sell");

   if(result && IsTradeRetcodeSuccessful())
   {
      tradesToday++;
      Print("Trade opened: ", EnumToString(type), " Lots=", volume, " SL=", sl, " TP=", tp,
            " Retcode=", trade.ResultRetcode());
   }
   else
   {
      Print("OrderSend failed. Error: ", GetLastError(),
            " Retcode: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      IngestLog(InpIngestEaId, "error", StringFormat("OrderSend failed: retcode=%d %s",
                trade.ResultRetcode(), trade.ResultRetcodeDescription()));
   }
}

//+------------------------------------------------------------------+
// Two-stage stop management, applied in this order per position:
//   1) Breakeven - once the trade is InpBETriggerAtrMult ATR in profit, pull the
//      stop to entry plus InpBELockPoints so the trade can no longer close red.
//   2) ATR trail - keep the stop InpTrailAtrMult ATR behind price.
// The stop only ever moves in the favourable direction (max/min against the
// current stop), so the trail can never undo the breakeven lock - which was the
// flaw in the trail-only version: it could drag the stop back to roughly
// -0.3*ATR after a trade had already been more than 1*ATR in profit.
//+------------------------------------------------------------------+
void ManagePositionStops()
{
   if(!InpUseTrailing && !InpUseBreakeven) return;
   if(!IsSymbolTradeSessionOpen()) return;

   double atr = GetAtr();
   if(atr <= 0) return;

   double point  = SymbolInfoDouble(symbolName, SYMBOL_POINT);
   double tickSize = SymbolInfoDouble(symbolName, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0) tickSize = point;
   double stopDistance = (double)SymbolInfoInteger(symbolName, SYMBOL_TRADE_STOPS_LEVEL) * point;
   double freezeDistance = (double)SymbolInfoInteger(symbolName, SYMBOL_TRADE_FREEZE_LEVEL) * point;
   double minDistance = MathMax(stopDistance, freezeDistance);
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
            if((bid - openPrice) >= atr * InpTrailStartAtrMult)
            {
               double trailSl = bid - atr * InpTrailAtrMult;
               if(trailSl > desiredSl) desiredSl = trailSl;
            }
         }

         desiredSl = MathMin(desiredSl, bid - minDistance);
         desiredSl = NormalizePriceToTick(desiredSl, -1);
         if(desiredSl > posSl + tickSize * 0.5 && desiredSl < bid - minDistance + tickSize * 0.5)
         {
            bool modified = trade.PositionModify(ticket, desiredSl, posTp);
            if(!modified || (!IsTradeRetcodeSuccessful() && trade.ResultRetcode() != TRADE_RETCODE_NO_CHANGES))
               Print("Stop modify failed: ticket=", ticket, " BUY SL->", desiredSl,
                     " retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double ask       = SymbolInfoDouble(symbolName, SYMBOL_ASK);
         // A fresh sell can legitimately carry SL==0 only if stops were rejected;
         // treat that as "no protection yet" so any candidate stop is an upgrade.
         double desiredSl = (posSl == 0) ? DBL_MAX : posSl;

         if(InpUseBreakeven && (openPrice - ask) >= atr * InpBETriggerAtrMult)
         {
            double beSl = openPrice - lock;
            if(beSl < desiredSl) desiredSl = beSl;
         }
         if(InpUseTrailing)
         {
            if((openPrice - ask) >= atr * InpTrailStartAtrMult)
            {
               double trailSl = ask + atr * InpTrailAtrMult;
               if(trailSl < desiredSl) desiredSl = trailSl;
            }
         }

         if(desiredSl == DBL_MAX) continue;
         desiredSl = MathMax(desiredSl, ask + minDistance);
         desiredSl = NormalizePriceToTick(desiredSl, 1);
         if((posSl == 0 || desiredSl < posSl - tickSize * 0.5) &&
            desiredSl > ask + minDistance - tickSize * 0.5)
         {
            bool modified = trade.PositionModify(ticket, desiredSl, posTp);
            if(!modified || (!IsTradeRetcodeSuccessful() && trade.ResultRetcode() != TRADE_RETCODE_NO_CHANGES))
               Print("Stop modify failed: ticket=", ticket, " SELL SL->", desiredSl,
                     " retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
         }
      }
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   ResetDailyCounterIfNeeded();
   ManagePositionStops();

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
