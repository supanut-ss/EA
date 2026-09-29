//+------------------------------------------------------------------+
//| XAUUSD_StopGrid_9x9_Manual_EA.mq5                                |
//| Manual-trigger variant: places NO entry order itself. Waits for  |
//| the user's own first manual market order on this symbol, treats |
//| it as Level 1 (any lot), opens the matching opposite-side Level  |
//| 1 at the same lot, then arms Levels 2-9 both sides and manages   |
//| exits exactly like XAUUSD_StopGrid_9x9_EA.mq5.                   |
//+------------------------------------------------------------------+
#property copyright "Custom EA - XAUUSD 9x9 Stop Grid (Manual Trigger)"
#property version   "1.21"
#property strict

#include <Trade/Trade.mqh>

CTrade trade;

#define MAX_GRID_LEVELS 32
#define MAX_TRADE_SESSIONS_PER_DAY 64
#define MAX_TRADE_SESSIONS_PER_WEEK (7 * MAX_TRADE_SESSIONS_PER_DAY)
#define TRAIL_ACTIVATION_LEVEL 3
#define TRAIL_STEP_PRICE 1.0

enum ENUM_GRID_LOT_MODE
  {
   GRID_LOT_EQUAL = 0,       // Every level uses the first-level lot.
   GRID_LOT_ODD_MULTIPLIER,  // Levels use 1, 3, 5, ..., (2N-1) times the base lot.
   GRID_LOT_CUSTOM            // Read the mirrored level lots from InpCustomLotSequence.
  };

enum ENUM_OPPOSITE_MODE
  {
   OPPOSITE_KEEP = 0,        // Keep the other side's pending orders active.
   OPPOSITE_DELETE           // Delete the other side's pending orders after the first fill.
  };

input group "=== Entry Signal Filters ==="
input int                 InpRSIPeriod           = 7;
input double              InpRSIBuyBelow         = 20.0;
input double              InpRSISellAbove        = 80.0;
input int                 InpADXPeriod           = 18;
input double              InpADXStrongTrendThreshold = 25.0;
input bool                InpUseM5EMAFilter      = true;
input int                 InpTrendEMAPeriod      = 50;

input group "=== Grid Setup ==="
input int                 InpLevelsPerSide       = 9;          // Buy Stop and Sell Stop levels on each side.
input double              InpGridStepPrice       = 2.0;        // Price distance per level; 2.0 means $2.00, independent of _Point.
input double              InpFirstLevelDistance  = 2.0;        // Distance from anchor to level 1; levels 2+ still add InpGridStepPrice each.
input double              InpFirstLevelLot       = 0.01;       // Level 1 lot; the opposite side's level 1 always matches it.
input ENUM_GRID_LOT_MODE  InpLotMode             = GRID_LOT_ODD_MULTIPLIER;
input string              InpCustomLotSequence  = "0.01,0.01,0.01,0.01,0.01,0.01,0.01,0.01,0.01"; // One lot per level; level 1 must match InpFirstLevelLot.
input ENUM_OPPOSITE_MODE  InpOppositeMode        = OPPOSITE_KEEP;
input bool                InpAutoRearmAfterCycle = true;
input int                 InpRearmDelaySeconds   = 5;

input group "=== Exits and Execution ==="
input double              InpStopLossBeyondAnchor = 0.0;       // 0 places Buy SL / Sell SL at the anchor.
input double              InpTakeProfitBeyondLast = 2.0;        // Extra distance past the 9th level; default target is anchor +/- $20.
input double              InpMaxSpreadPrice      = 0.20;       // 0 disables the spread filter.
input int                 InpSlippagePoints      = 100;
input int                 InpExpirationHours     = 0;          // 0 means GTC.
input int                 InpMinutesBeforeSessionClose = 15;   // Liquidate this many minutes before each symbol trade-session close.
input double              InpMaxAdverseEntrySlippagePrice = 2.0; // 0 disables the gap-fill guard; otherwise flatten if a stop fill slips this far beyond its trigger.
input ulong               InpMagicNumber         = 20260925;

input group "=== Risk Guards ==="
input double              InpMaxRiskPercent      = 0.0;        // Reject the grid when modeled conservative anchor-stop risk exceeds this % of equity; 0 disables.
input double              InpRiskSlipBufferPrice = 0.05;       // Extra adverse close-price buffer used only by the risk estimate.
input double              InpMinMarginLevelPct   = 0.0;        // Projected margin level after all pending orders fill; 0 disables.
input int                 InpRetrySeconds        = 30;

struct STradeSession
  {
   int dayOfWeek;
   int startSeconds;
   int endSeconds;
  };

double   g_tickSize = 0.0;
double   g_volumeMin = 0.0;
double   g_volumeMax = 0.0;
double   g_volumeStep = 0.0;
double   g_customLots[];
int      g_rsiHandle = INVALID_HANDLE;
int      g_adxHandle = INVALID_HANDLE;
int      g_m5EmaHandle = INVALID_HANDLE;
datetime g_lastM1SignalBarTime = 0;
double   g_anchorPrice = 0.0;
datetime g_retryAfter = 0;
bool     g_cycleHadActivity = false;
bool     g_startedOnce = false;
int      g_trailingDirection = 0;
bool     g_level3Evaluated = false;
int      g_fixedCaseId = 0;
int      g_fixedCaseDirection = 0;
datetime g_fixedCaseCloseRetryAfter = 0;
datetime g_pendingCancelRetryAfter = 0;
ulong    g_manualTicket = 0;
datetime g_manualArmRetryAfter = 0;
ulong    g_manualOppositeTicket = 0;
double   g_manualLevel1Lot = 0.0;
string   g_stateKey = "";

STradeSession g_tradeSessions[MAX_TRADE_SESSIONS_PER_WEEK];
int      g_tradeSessionDayStart[7];
int      g_tradeSessionDayCount[7];
int      g_tradeSessionCount = 0;
datetime g_tradeSessionCacheDay = 0;
datetime g_tradeSessionRetryAfter = 0;
bool     g_tradeSessionScheduleLoaded = false;
bool     g_tradeSessionWarningLogged = false;
bool     g_sessionClosePending = false;
bool     g_gapGuardPending = false;

//+------------------------------------------------------------------+
bool ShouldLiquidateForSession(const bool isOpen,
                               const int secondsUntilClose,
                               const int minutesBeforeClose)
  {
   return(!isOpen || secondsUntilClose <= minutesBeforeClose * 60);
  }

//+------------------------------------------------------------------+
datetime ServerDayStart(const datetime serverTime)
  {
   MqlDateTime parts;
   if(!TimeToStruct(serverTime, parts))
      return(0);
   parts.hour = 0;
   parts.min = 0;
   parts.sec = 0;
   return(StructToTime(parts));
  }

//+------------------------------------------------------------------+
int SessionTimeSeconds(const datetime sessionTime)
  {
   MqlDateTime parts;
   if(!TimeToStruct(sessionTime, parts))
      return(0);
   return(parts.hour * 3600 + parts.min * 60 + parts.sec);
  }

//+------------------------------------------------------------------+
double AdverseEntrySlippagePrice(const int direction,
                                 const double requestedPrice,
                                 const double fillPrice)
  {
   if(direction > 0)
      return(MathMax(0.0, fillPrice - requestedPrice));
   if(direction < 0)
      return(MathMax(0.0, requestedPrice - fillPrice));
   return(0.0);
  }

//+------------------------------------------------------------------+
bool ShouldTriggerEntryGapGuard(const int direction,
                                const double requestedPrice,
                                const double fillPrice,
                                const double maxAdverseSlippagePrice)
  {
   if(maxAdverseSlippagePrice <= 0.0)
      return(false);
   return(AdverseEntrySlippagePrice(direction, requestedPrice, fillPrice) >=
          maxAdverseSlippagePrice);
  }

//+------------------------------------------------------------------+
bool RefreshSymbolTradeSessions(const datetime serverTime)
  {
   datetime dayStart = ServerDayStart(serverTime);
   if(dayStart <= 0)
      return(false);
   if(g_tradeSessionScheduleLoaded && g_tradeSessionCacheDay == dayStart)
      return(true);
   if(!g_tradeSessionScheduleLoaded && g_tradeSessionCacheDay == dayStart &&
      serverTime < g_tradeSessionRetryAfter)
      return(false);

   g_tradeSessionCount = 0;
   ArrayInitialize(g_tradeSessionDayStart, 0);
   ArrayInitialize(g_tradeSessionDayCount, 0);
   for(int day = 0; day < 7; day++)
     {
      g_tradeSessionDayStart[day] = g_tradeSessionCount;
      for(uint sessionIndex = 0; sessionIndex < MAX_TRADE_SESSIONS_PER_DAY; sessionIndex++)
        {
         datetime sessionFrom = 0;
         datetime sessionTo = 0;
         if(!SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)day, sessionIndex,
                                    sessionFrom, sessionTo))
            break;
         if(g_tradeSessionCount >= MAX_TRADE_SESSIONS_PER_WEEK)
            break;
         g_tradeSessions[g_tradeSessionCount].dayOfWeek = day;
         g_tradeSessions[g_tradeSessionCount].startSeconds = SessionTimeSeconds(sessionFrom);
         g_tradeSessions[g_tradeSessionCount].endSeconds = SessionTimeSeconds(sessionTo);
         g_tradeSessionCount++;
         g_tradeSessionDayCount[day]++;
        }
     }

   g_tradeSessionCacheDay = dayStart;
   g_tradeSessionScheduleLoaded = (g_tradeSessionCount > 0);
   g_tradeSessionRetryAfter = serverTime + 60;
   return(g_tradeSessionScheduleLoaded);
  }

//+------------------------------------------------------------------+
bool GetSymbolTradeSessionState(const datetime serverTime,
                                bool &isOpen,
                                int &secondsUntilClose)
  {
   isOpen = false;
   secondsUntilClose = 0;
   if(!RefreshSymbolTradeSessions(serverTime))
      return(false);

   datetime todayStart = ServerDayStart(serverTime);
   datetime sessionClose = 0;
   for(int dayOffset = -1; dayOffset <= 0; dayOffset++)
     {
      datetime sessionDay = todayStart + (datetime)(dayOffset * 86400);
      MqlDateTime dayParts;
      if(!TimeToStruct(sessionDay, dayParts))
         continue;
      int day = dayParts.day_of_week;
      for(int i = 0; i < g_tradeSessionDayCount[day]; i++)
        {
         int index = g_tradeSessionDayStart[day] + i;
         datetime sessionFrom = sessionDay + (datetime)g_tradeSessions[index].startSeconds;
         datetime sessionTo = sessionDay + (datetime)g_tradeSessions[index].endSeconds;
         if(sessionTo <= sessionFrom)
            sessionTo += 86400;
         if(serverTime >= sessionFrom && serverTime < sessionTo)
           {
            isOpen = true;
            if(sessionTo > sessionClose)
               sessionClose = sessionTo;
           }
        }
     }

   if(!isOpen)
      return(true);

   // Merge sessions that touch or overlap so an internal schedule boundary is not treated as a break.
   for(int pass = 0; pass < MAX_GRID_LEVELS; pass++)
     {
      bool extended = false;
      for(int dayOffset = -1; dayOffset <= 8; dayOffset++)
        {
         datetime sessionDay = todayStart + (datetime)(dayOffset * 86400);
         MqlDateTime dayParts;
         if(!TimeToStruct(sessionDay, dayParts))
            continue;
         int day = dayParts.day_of_week;
         for(int i = 0; i < g_tradeSessionDayCount[day]; i++)
           {
            int index = g_tradeSessionDayStart[day] + i;
            datetime sessionFrom = sessionDay + (datetime)g_tradeSessions[index].startSeconds;
            datetime sessionTo = sessionDay + (datetime)g_tradeSessions[index].endSeconds;
            if(sessionTo <= sessionFrom)
               sessionTo += 86400;
            if(sessionFrom <= sessionClose + 1 && sessionTo > sessionClose)
              {
               sessionClose = sessionTo;
               extended = true;
              }
           }
        }
      if(!extended)
         break;
     }

   secondsUntilClose = (int)MathMax(0, (long)(sessionClose - serverTime));
   return(true);
  }

//+------------------------------------------------------------------+
void SetSessionClosePending(const bool pending)
  {
   if(g_sessionClosePending == pending)
      return;
   g_sessionClosePending = pending;
   if(pending)
     {
      GlobalVariableSet(SessionClosePendingKey(), 1.0);
      Print("StopGrid9: session close guard activated; EA positions and pending orders will be retired.");
     }
   else
     {
      if(GlobalVariableCheck(SessionClosePendingKey()))
         GlobalVariableDel(SessionClosePendingKey());
      Print("StopGrid9: session reopened and EA activity is clear; waiting for a fresh M1 signal.");
     }
  }

//+------------------------------------------------------------------+
bool ManageSessionCloseState(const bool closeWindowActive,
                             const bool tradeAllowed)
  {
   if(closeWindowActive)
     {
      SkipClosedM1EntryBars();
      SetSessionClosePending(true);
      if(tradeAllowed && HasOwnActivity())
        {
         if(PendingCancelRetryDue())
            DeleteAllOwnPending();
         CloseAllOwnPositions();
        }
      return(true);
     }

   if(!g_sessionClosePending)
      return(false);

   SkipClosedM1EntryBars();
   if(HasOwnActivity())
     {
      if(tradeAllowed)
        {
         if(PendingCancelRetryDue())
            DeleteAllOwnPending();
         CloseAllOwnPositions();
        }
      return(true);
     }

   SetSessionClosePending(false);
   return(true);
  }

//+------------------------------------------------------------------+
int AdxTrendDirectionFromValues(const double adxValue,
                                const double plusDiValue,
                                const double minusDiValue,
                                const double strongTrendThreshold)
  {
   if(adxValue <= strongTrendThreshold)
      return(0);
   if(plusDiValue > minusDiValue)
      return(1);
   if(minusDiValue > plusDiValue)
      return(-1);
   return(2);
  }

//+------------------------------------------------------------------+
int GridDirectionForEntrySignal(const int signal,
                                const double adxValue,
                                const double plusDiValue,
                                const double minusDiValue,
                                const double strongTrendThreshold)
  {
   if(signal != 1 && signal != -1)
      return(2);
   int trendDirection = AdxTrendDirectionFromValues(adxValue, plusDiValue,
                                                    minusDiValue, strongTrendThreshold);
   if(trendDirection == 2 || (trendDirection != 0 && trendDirection != signal))
      return(2);
   return(trendDirection);
  }

//+------------------------------------------------------------------+
int M5EMATrendDirectionFromValues(const double closedM5Price,
                                  const double closedM5EMA)
  {
   if(closedM5Price > closedM5EMA)
      return(1);
   if(closedM5Price < closedM5EMA)
      return(-1);
   return(0);
  }

//+------------------------------------------------------------------+
int ApplyM5EMAEntryFilter(const int signal,
                          const int emaTrendDirection,
                          const bool filterEnabled)
  {
   if(signal != 1 && signal != -1)
      return(0);
   if(!filterEnabled || signal == emaTrendDirection)
      return(signal);
   return(0);
  }

int EntrySignalFromValues(const double rsiValue,
                          const double adxValue,
                          const double plusDiValue,
                          const double minusDiValue,
                          const double buyBelow,
                          const double sellAbove,
                          const double strongTrendThreshold,
                          int &gridDirection)
  {
   gridDirection = 0;
   int signal = 0;
   if(rsiValue < buyBelow)
      signal = 1;
   else if(rsiValue > sellAbove)
      signal = -1;
   if(signal == 0)
      return(0);

   gridDirection = GridDirectionForEntrySignal(signal, adxValue, plusDiValue,
                                               minusDiValue, strongTrendThreshold);
   if(gridDirection == 2)
     {
      gridDirection = 0;
      return(0);
     }
   return(signal);
  }

//+------------------------------------------------------------------+
bool ReadM1ADXValues(const int shift,
                     double &adxValue,
                     double &plusDiValue,
                     double &minusDiValue)
  {
   adxValue = 0.0;
   plusDiValue = 0.0;
   minusDiValue = 0.0;
   if(g_adxHandle == INVALID_HANDLE)
      return(false);

   double adxCurrent[1];
   double plusDiCurrent[1];
   double minusDiCurrent[1];
   if(CopyBuffer(g_adxHandle, 0, shift, 1, adxCurrent) != 1 ||
      CopyBuffer(g_adxHandle, 1, shift, 1, plusDiCurrent) != 1 ||
      CopyBuffer(g_adxHandle, 2, shift, 1, minusDiCurrent) != 1)
      return(false);

   adxValue = adxCurrent[0];
   plusDiValue = plusDiCurrent[0];
   minusDiValue = minusDiCurrent[0];
   return(true);
  }

//+------------------------------------------------------------------+
bool ReadLatestClosedM5EMATrend(int &trendDirection,
                                double &closedM5Price,
                                double &closedM5EMA)
  {
   trendDirection = 0;
   closedM5Price = 0.0;
   closedM5EMA = 0.0;
   if(g_m5EmaHandle == INVALID_HANDLE ||
      BarsCalculated(g_m5EmaHandle) < InpTrendEMAPeriod + 1 ||
      iTime(_Symbol, PERIOD_M5, 1) <= 0)
      return(false);

   double emaCurrent[1];
   if(CopyBuffer(g_m5EmaHandle, 0, 1, 1, emaCurrent) != 1)
      return(false);

   closedM5Price = iClose(_Symbol, PERIOD_M5, 1);
   closedM5EMA = emaCurrent[0];
   if(!MathIsValidNumber(closedM5Price) || !MathIsValidNumber(closedM5EMA) ||
      closedM5Price <= 0.0 || closedM5EMA <= 0.0 || closedM5EMA == EMPTY_VALUE)
      return(false);

   trendDirection = M5EMATrendDirectionFromValues(closedM5Price, closedM5EMA);
   return(true);
  }

void SkipClosedM1EntryBars()
  {
   datetime closedBarTime = iTime(_Symbol, PERIOD_M1, 1);
   if(closedBarTime > 0 && closedBarTime > g_lastM1SignalBarTime)
      g_lastM1SignalBarTime = closedBarTime;
  }

//+------------------------------------------------------------------+
bool ReadNewClosedM1EntrySignal(int &signal,
                                double &rsiValue,
                                double &adxValue,
                                double &plusDiValue,
                                double &minusDiValue,
                                int &emaTrendDirection,
                                double &closedM5Price,
                                double &closedM5EMA,
                                int &gridDirection,
                                datetime &signalBarTime)
  {
   signal = 0;
   rsiValue = 0.0;
   adxValue = 0.0;
   plusDiValue = 0.0;
   minusDiValue = 0.0;
   emaTrendDirection = 0;
   closedM5Price = 0.0;
   closedM5EMA = 0.0;
   gridDirection = 0;
   signalBarTime = 0;

   datetime closedBarTime = iTime(_Symbol, PERIOD_M1, 1);
   if(closedBarTime <= 0)
      return(false);
   if(g_lastM1SignalBarTime <= 0)
     {
      g_lastM1SignalBarTime = closedBarTime;
      return(false);
     }
   if(closedBarTime <= g_lastM1SignalBarTime)
      return(false);
   if(g_rsiHandle == INVALID_HANDLE || g_adxHandle == INVALID_HANDLE ||
      (InpUseM5EMAFilter && g_m5EmaHandle == INVALID_HANDLE))
      return(false);

   double rsiCurrent[1];
   if(CopyBuffer(g_rsiHandle, 0, 1, 1, rsiCurrent) != 1 ||
       !ReadM1ADXValues(1, adxValue, plusDiValue, minusDiValue))
      return(false);
   if(InpUseM5EMAFilter &&
      !ReadLatestClosedM5EMATrend(emaTrendDirection, closedM5Price, closedM5EMA))
      return(false);

   g_lastM1SignalBarTime = closedBarTime;
   signalBarTime = closedBarTime;
   rsiValue = rsiCurrent[0];
   signal = EntrySignalFromValues(rsiValue,
                                   adxValue, plusDiValue, minusDiValue,
                                  InpRSIBuyBelow, InpRSISellAbove,
                                  InpADXStrongTrendThreshold, gridDirection);
   signal = ApplyM5EMAEntryFilter(signal, emaTrendDirection, InpUseM5EMAFilter);
   if(signal == 0)
      gridDirection = 0;
   return(true);
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpRSIPeriod < 1 || InpADXPeriod < 1 ||
       (InpUseM5EMAFilter && InpTrendEMAPeriod < 1) ||
       InpADXStrongTrendThreshold <= 0.0 || InpADXStrongTrendThreshold >= 100.0 ||
       InpRSIBuyBelow <= 0.0 || InpRSISellAbove >= 100.0 ||
       InpRSIBuyBelow >= InpRSISellAbove ||
       InpLevelsPerSide < TRAIL_ACTIVATION_LEVEL || InpLevelsPerSide > MAX_GRID_LEVELS ||
       InpGridStepPrice <= 0.0 || InpFirstLevelDistance <= 0.0 || InpFirstLevelLot <= 0.0 ||
       InpStopLossBeyondAnchor < 0.0 || InpTakeProfitBeyondLast <= 0.0 ||
       InpMaxSpreadPrice < 0.0 || InpExpirationHours < 0 ||
       InpSlippagePoints < 0 || InpMinutesBeforeSessionClose < 1 ||
       InpMaxAdverseEntrySlippagePrice < 0.0 ||
      InpMaxRiskPercent < 0.0 || InpRiskSlipBufferPrice < 0.0 ||
      InpMinMarginLevelPct < 0.0 || InpRetrySeconds < 1 ||
      InpRearmDelaySeconds < 0 ||
      (InpLotMode != GRID_LOT_EQUAL && InpLotMode != GRID_LOT_ODD_MULTIPLIER && InpLotMode != GRID_LOT_CUSTOM) ||
      (InpOppositeMode != OPPOSITE_KEEP && InpOppositeMode != OPPOSITE_DELETE))
     {
      Print("StopGrid9: invalid input values.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   string symbolUpper = _Symbol;
   StringToUpper(symbolUpper);
   if(StringFind(symbolUpper, "XAUUSD") < 0)
     {
      Print("StopGrid9: attach this EA to an XAUUSD symbol (broker suffixes are supported). Current symbol: ", _Symbol);
      return(INIT_FAILED);
     }

   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Print("StopGrid9: a hedging account is required so each grid order remains a separate position.");
      return(INIT_FAILED);
     }

   g_tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   g_volumeMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_volumeMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   g_volumeStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(g_tickSize <= 0.0 || g_volumeMin <= 0.0 || g_volumeMax < g_volumeMin || g_volumeStep <= 0.0)
     {
      Print("StopGrid9: unable to read valid symbol tick/volume properties.");
      return(INIT_FAILED);
     }

   if(InpLotMode == GRID_LOT_CUSTOM && !LoadCustomLotSequence())
      return(INIT_PARAMETERS_INCORRECT);

   g_stateKey = StateKey();
   if(GlobalVariableCheck(ManualTicketKey()))
      g_manualTicket = (ulong)GlobalVariableGet(ManualTicketKey());
   if(GlobalVariableCheck(ManualOppositeTicketKey()))
      g_manualOppositeTicket = (ulong)GlobalVariableGet(ManualOppositeTicketKey());
   if(GlobalVariableCheck(SessionClosePendingKey()))
      g_sessionClosePending = (GlobalVariableGet(SessionClosePendingKey()) > 0.5);
   if(GlobalVariableCheck(GapGuardPendingKey()))
      g_gapGuardPending = (GlobalVariableGet(GapGuardPendingKey()) > 0.5);
   if(GlobalVariableCheck(TrailingDirectionKey()))
     {
      double savedDirection = GlobalVariableGet(TrailingDirectionKey());
      if(savedDirection == 1.0 || savedDirection == -1.0)
         g_trailingDirection = (int)savedDirection;
     }
   if(GlobalVariableCheck(ThirdLevelResolvedKey()))
      g_level3Evaluated = (GlobalVariableGet(ThirdLevelResolvedKey()) > 0.5);
   if(GlobalVariableCheck(FixedCaseKey()))
     {
      int savedCaseId = (int)GlobalVariableGet(FixedCaseKey());
      int savedCaseDirection = (int)GlobalVariableGet(FixedCaseDirectionKey());
      if(savedCaseId >= 1 && savedCaseId <= 4 &&
         (savedCaseDirection == 1 || savedCaseDirection == -1))
        {
         g_fixedCaseId = savedCaseId;
         g_fixedCaseDirection = savedCaseDirection;
        }
     }
   if(g_trailingDirection != 0)
      g_level3Evaluated = true;
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints((ulong)InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   g_rsiHandle = iRSI(_Symbol, PERIOD_M1, InpRSIPeriod, PRICE_CLOSE);
   g_adxHandle = iADX(_Symbol, PERIOD_M1, InpADXPeriod);
   if(InpUseM5EMAFilter)
      g_m5EmaHandle = iMA(_Symbol, PERIOD_M5, InpTrendEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_rsiHandle == INVALID_HANDLE || g_adxHandle == INVALID_HANDLE ||
      (InpUseM5EMAFilter && g_m5EmaHandle == INVALID_HANDLE))
     {
      Print("StopGrid9: unable to create M1 RSI/ADX or M5 EMA trend-filter handles. Error=", GetLastError());
      return(INIT_FAILED);
     }
   g_lastM1SignalBarTime = iTime(_Symbol, PERIOD_M1, 1);

   bool sessionOpen = false;
   int secondsUntilSessionClose = 0;
   if(!GetSymbolTradeSessionState(TimeCurrent(), sessionOpen, secondsUntilSessionClose))
     {
      g_tradeSessionWarningLogged = true;
      Print("StopGrid9: symbol trade sessions are unavailable; new grids are blocked until the schedule can be read.");
     }
   else if(ShouldLiquidateForSession(sessionOpen, secondsUntilSessionClose,
                                     InpMinutesBeforeSessionClose))
      SetSessionClosePending(true);

   if(HasOwnActivity())
     {
      g_anchorPrice = RecoverAnchorPrice();
      if(g_anchorPrice <= 0.0)
        {
         Print("StopGrid9: existing positions/orders were found but their grid anchor could not be recovered. No new grid was placed.");
         return(INIT_FAILED);
        }
      g_cycleHadActivity = true;
       g_startedOnce = true;
       Print("StopGrid9: resumed existing grid at anchor ", DoubleToString(g_anchorPrice, _Digits));
       if(g_sessionClosePending || g_gapGuardPending)
          SkipClosedM1EntryBars();
       else
         {
          ManageGridExitRules();
         }
      return(INIT_SUCCEEDED);
     }

   ClearSavedAnchor();
     Print("StopGrid9: waiting for a fresh closed M1 signal: RSI < ", DoubleToString(InpRSIBuyBelow, 1),
           " or RSI > ", DoubleToString(InpRSISellAbove, 1), " | ADX(", InpADXPeriod,
         ") > ", DoubleToString(InpADXStrongTrendThreshold, 1),
         " allows entries and pending orders only with the +DI/-DI trend | M5 EMA filter=",
         (InpUseM5EMAFilter ? IntegerToString(InpTrendEMAPeriod) : "OFF"));

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_rsiHandle != INVALID_HANDLE)
      IndicatorRelease(g_rsiHandle);
   if(g_adxHandle != INVALID_HANDLE)
      IndicatorRelease(g_adxHandle);
   if(g_m5EmaHandle != INVALID_HANDLE)
      IndicatorRelease(g_m5EmaHandle);
   Comment("");
   // Open positions and pending orders retain their server-side SL/TP on EA removal.
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   bool tradeAllowed = (TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) &&
                        MQLInfoInteger(MQL_TRADE_ALLOWED));
   if(g_gapGuardPending)
     {
      ProcessAdverseGapProtection(tradeAllowed);
      return;
     }

   bool sessionOpen = false;
   int secondsUntilSessionClose = 0;
   if(!GetSymbolTradeSessionState(TimeCurrent(), sessionOpen, secondsUntilSessionClose))
     {
      SkipClosedM1EntryBars();
      if(!g_tradeSessionWarningLogged)
        {
         Print("StopGrid9: symbol trade sessions are unavailable; new grids are blocked until the schedule can be read.");
         g_tradeSessionWarningLogged = true;
        }
      if(tradeAllowed && HasOwnActivity())
        {
         g_cycleHadActivity = true;
         g_startedOnce = true;
         if(g_anchorPrice <= 0.0)
            g_anchorPrice = RecoverAnchorPrice();
         if(PendingCancelRetryDue())
            DeleteAllOwnPending();
         ManageGridExitRules();
        }
      return;
     }
   g_tradeSessionWarningLogged = false;

   if(ManageSessionCloseState(ShouldLiquidateForSession(sessionOpen, secondsUntilSessionClose,
                                                        InpMinutesBeforeSessionClose),
                              tradeAllowed))
      return;

   if(!tradeAllowed)
     {
      SkipClosedM1EntryBars();
      return;
     }

   if(HasOwnActivity())
     {
      SkipClosedM1EntryBars();
       g_cycleHadActivity = true;
       g_startedOnce = true;
       if(g_anchorPrice <= 0.0)
          g_anchorPrice = RecoverAnchorPrice();
       ManageGridExitRules();
      return;
     }

   if(g_cycleHadActivity)
     {
      g_cycleHadActivity = false;
      g_anchorPrice = 0.0;
      g_manualTicket = 0;
      if(g_stateKey != "" && GlobalVariableCheck(ManualTicketKey()))
         GlobalVariableDel(ManualTicketKey());
      ClearSavedAnchor();
      g_retryAfter = TimeCurrent() + InpRearmDelaySeconds;
      Print("StopGrid9-Manual: previous grid has no open positions or pending orders; waiting for the next manual entry.");
     }

   if(g_startedOnce && !InpAutoRearmAfterCycle)
     {
      SkipClosedM1EntryBars();
      return;
     }
   if(TimeCurrent() < g_retryAfter)
     {
      SkipClosedM1EntryBars();
      return;
     }

   if(TimeCurrent() < g_manualArmRetryAfter)
      return;

   ulong manualTicket = 0;
   int manualDirection = 0;
   double manualLot = 0.0;
   double manualPrice = 0.0;
   if(!DetectManualTriggerPosition(manualTicket, manualDirection, manualLot, manualPrice))
      return;

   Print("StopGrid9-Manual: detected manual ", (manualDirection > 0 ? "BUY" : "SELL"),
         " #", manualTicket, " lot=", DoubleToString(manualLot, VolumeDigits()),
         " @", DoubleToString(manualPrice, _Digits),
         "; treating it as Level 1 and arming the rest of the grid.");

   if(ArmGridFromManual(manualTicket, manualDirection, manualLot, manualPrice))
      g_startedOnce = true;
   else
     {
      int retryDelay = InpRetrySeconds;
      if(retryDelay < 5)
         retryDelay = 5;
      g_manualArmRetryAfter = TimeCurrent() + retryDelay;
      Print("StopGrid9-Manual: could not arm the grid around this manual order; leaving it untouched and will retry in ",
            retryDelay, "s.");
     }
  }

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.symbol != _Symbol || trans.deal == 0)
      return;
   if(!HistoryDealSelect(trans.deal) ||
      (ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagicNumber ||
      (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_IN)
      return;

   ulong sourceOrder = (ulong)HistoryDealGetInteger(trans.deal, DEAL_ORDER);
   if(sourceOrder == 0 || !HistoryOrderSelect(sourceOrder))
      return;
   string orderComment = HistoryOrderGetString(sourceOrder, ORDER_COMMENT);

   ENUM_ORDER_TYPE sourceOrderType = (ENUM_ORDER_TYPE)HistoryOrderGetInteger(sourceOrder, ORDER_TYPE);
   bool fillWasFromStopOrder = (sourceOrderType == ORDER_TYPE_BUY_STOP || sourceOrderType == ORDER_TYPE_SELL_STOP);

   if(InpMaxAdverseEntrySlippagePrice > 0.0 && fillWasFromStopOrder &&
      (trans.deal_type == DEAL_TYPE_BUY || trans.deal_type == DEAL_TYPE_SELL))
     {
      int fillDirection = (trans.deal_type == DEAL_TYPE_BUY ? 1 : -1);
      double requestedPrice = HistoryOrderGetDouble(sourceOrder, ORDER_PRICE_OPEN);
      double fillPrice = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
      double adverseSlippage = AdverseEntrySlippagePrice(fillDirection, requestedPrice, fillPrice);
      if(ShouldTriggerEntryGapGuard(fillDirection, requestedPrice, fillPrice,
                                    InpMaxAdverseEntrySlippagePrice))
        {
         SetGapGuardPending(true);
         Print("StopGrid9: adverse stop-entry slippage ", DoubleToString(adverseSlippage, _Digits),
               " exceeds gap guard ", DoubleToString(InpMaxAdverseEntrySlippagePrice, _Digits),
               " | trigger=", DoubleToString(requestedPrice, _Digits),
               " | fill=", DoubleToString(fillPrice, _Digits),
               "; canceling EA pending orders and closing the basket.");
        }
     }

   if(StringFind(orderComment, "|L03") < 0)
      return;

   if(trans.deal_type == DEAL_TYPE_BUY || trans.deal_type == DEAL_TYPE_SELL)
      Print("StopGrid9: L03 fill transaction received; deferring the 3-0 check until OnTick reads settled positions.");
  }

//+------------------------------------------------------------------+
void ProcessAdverseGapProtection(const bool tradeAllowed)
  {
   SkipClosedM1EntryBars();
   if(!tradeAllowed)
      return;

   int pendingBefore = CountOwnPendingOrders();
   if(pendingBefore > 0 && PendingCancelRetryDue())
      DeleteAllOwnPending();
   CloseAllOwnPositions();
   if(!HasOwnActivity())
      SetGapGuardPending(false);
  }

//+------------------------------------------------------------------+
void SetGapGuardPending(const bool pending)
  {
   g_gapGuardPending = pending;
   if(g_stateKey == "")
      return;

   string key = GapGuardPendingKey();
   if(pending)
      GlobalVariableSet(key, 1.0);
   else if(GlobalVariableCheck(key))
      GlobalVariableDel(key);
  }

//+------------------------------------------------------------------+
// True when the currently-selected position (from a PositionGetTicket(i) loop) belongs
// to this EA: either it carries our magic number, or it is the one manual position we
// adopted as Level 1 (tracked by ticket, since a position's magic can't be changed after
// it opens). Must be called right after selecting `ticket` via PositionGetTicket(i).
bool IsOwnPosition(const ulong ticket)
  {
   if((ulong)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      return(true);
   return(g_manualTicket != 0 && ticket == g_manualTicket);
  }

//+------------------------------------------------------------------+
// Finds the user's own manually-placed position on this symbol (any magic, not ours) to
// treat as the grid's Level 1. Only meaningful while HasOwnActivity() is false, i.e. no
// grid is currently armed.
bool DetectManualTriggerPosition(ulong &ticket, int &direction, double &volume, double &price)
  {
   ticket = 0;
   direction = 0;
   volume = 0.0;
   price = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong candidate = PositionGetTicket(i);
      if(candidate == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol || IsOwnPosition(candidate))
         continue;

      ENUM_POSITION_TYPE positionType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(positionType != POSITION_TYPE_BUY && positionType != POSITION_TYPE_SELL)
         continue;

      ticket = candidate;
      direction = (positionType == POSITION_TYPE_BUY ? 1 : -1);
      volume = PositionGetDouble(POSITION_VOLUME);
      price = PositionGetDouble(POSITION_PRICE_OPEN);
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
// By design NO leg (Level 1..N, either side) carries an anchor-based SL - only a TP is
// set at placement. SL is decided later by the case logic once Level 3 resolves which
// pattern applies (3-0 trailing, or one of the fixed 3-x cases), not up front.
void ApplyTakeProfitOnly(const ulong ticket, const int direction, const double anchor)
  {
   if(ticket == 0 || (direction != 1 && direction != -1) || !PositionSelectByTicket(ticket))
      return;

   double tpPrice = NormalizePrice(anchor + direction * (LevelDistance(InpLevelsPerSide) + InpTakeProfitBeyondLast));
   bool requestSent = trade.PositionModify(ticket, 0.0, tpPrice);
   if(!TradeResultAccepted(requestSent, false))
      Print("StopGrid9-Manual: failed to set TP for the manual Level 1 position #", ticket,
            " | retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
// Arms the rest of the grid around a manually-opened Level 1: the manual fill anchors the
// grid, then places the opposite side's Level 1 (same lot) plus Levels 2..N on both sides
// as ordinary pending stop orders, sized as a multiple of the manual lot (see
// LotForLevel()).
bool ArmGridFromManual(const ulong manualTicket, const int manualDirection,
                       const double manualLot, const double manualPrice)
  {
   if((manualDirection != 1 && manualDirection != -1) || manualLot <= 0.0)
      return(false);
   if(HasOwnActivity())
      return(true);
   if(InpFirstLevelLot <= 0.0)
     {
      Print("StopGrid9-Manual: InpFirstLevelLot must stay > 0 (it only sets the lot-progression shape); grid not armed.");
      return(false);
     }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.ask <= 0.0 || tick.bid <= 0.0)
     {
      Print("StopGrid9-Manual: no valid quote; grid placement will be retried.");
      return(false);
     }

   // The manual fill itself has no SL (per design - see ArmGridFromManual below), so it
   // doesn't need LevelDistance(1) of room behind the anchor the way a normal anchor-SL
   // leg would. The anchor is simply the manual price, so the opposite side's Level 1
   // (placed as an ordinary pending stop order, same lot as the manual fill) sits exactly
   // LevelDistance(1) away from the manual entry, not 2x that.
   double anchor = NormalizePrice(manualPrice);
   // Level 1 (both sides) uses the manual lot exactly; Levels 2..N stay fixed to
   // InpFirstLevelLot's own progression (odd-multiplier/equal/custom), unrelated to
   // whatever lot the user happened to click.
   g_manualLevel1Lot = manualLot;

   double modeledRisk = 0.0;
   double projectedMargin = 0.0;
   double projectedMarginLevel = 0.0;
   if(!PreflightGrid(anchor, 0, modeledRisk, projectedMargin, projectedMarginLevel, true))
     {
      g_manualLevel1Lot = 0.0;
      return(false);
     }

   int oppositeDirection = -manualDirection;

   g_manualTicket = manualTicket;
   g_manualOppositeTicket = 0;
   g_anchorPrice = anchor;
   g_trailingDirection = 0;
   g_level3Evaluated = false;
   g_fixedCaseId = 0;
   g_fixedCaseDirection = 0;
   g_fixedCaseCloseRetryAfter = 0;
   g_pendingCancelRetryAfter = 0;
   if(GlobalVariableCheck(TrailingDirectionKey()))
      GlobalVariableDel(TrailingDirectionKey());
   if(GlobalVariableCheck(ThirdLevelResolvedKey()))
      GlobalVariableDel(ThirdLevelResolvedKey());
   if(GlobalVariableCheck(FixedCaseKey()))
      GlobalVariableDel(FixedCaseKey());
   if(GlobalVariableCheck(FixedCaseDirectionKey()))
      GlobalVariableDel(FixedCaseDirectionKey());
   GlobalVariableSet(g_stateKey, g_anchorPrice);
   GlobalVariableSet(ManualTicketKey(), (double)g_manualTicket);
   GlobalVariableSet(ManualOppositeTicketKey(), (double)g_manualOppositeTicket);

   ApplyTakeProfitOnly(manualTicket, manualDirection, anchor);

   ulong placedTickets[];
   ArrayResize(placedTickets, 2 * InpLevelsPerSide);
   int placedCount = 0;

   for(int sideIndex = 0; sideIndex < 2; sideIndex++)
     {
      int direction = (sideIndex == 0 ? manualDirection : oppositeDirection);
      int startLevel = (sideIndex == 0 ? 2 : 1); // the manual side's Level 1 already filled.
      for(int level = startLevel; level <= InpLevelsPerSide; level++)
        {
         double requestedLot = LotForLevel(level);
         double lot = NormalizeVolumeDown(requestedLot);
         // The manual side's own Level 1 sits AT the anchor (distance 0), not
         // LevelDistance(1) away like a normal pending Level 1 would - so its Levels 2..N
         // are shifted back by LevelDistance(1) too, keeping the same step-sized gap
         // between consecutive levels (200pts by default) that the opposite side gets.
         double levelDistance = (sideIndex == 0 ? LevelDistance(level) - LevelDistance(1) : LevelDistance(level));
         double entryPrice = NormalizePrice(anchor + direction * levelDistance);
         double slPrice = 0.0; // no SL up front anywhere - the case logic assigns one once Level 3 resolves.
         double tpPrice = NormalizePrice(anchor + direction * (LevelDistance(InpLevelsPerSide) + InpTakeProfitBeyondLast));
         datetime expiration = 0;
         ENUM_ORDER_TYPE_TIME timeType = ORDER_TIME_GTC;
         if(InpExpirationHours > 0)
           {
            expiration = TimeCurrent() + InpExpirationHours * 3600;
            timeType = ORDER_TIME_SPECIFIED;
           }

         string sideName = (direction > 0 ? "B" : "S");
         string orderComment = StringFormat("SG9|%s|L%02d", sideName, level);
         ResetLastError();
         bool sent = false;
         if(direction > 0)
            sent = trade.BuyStop(lot, entryPrice, _Symbol, slPrice, tpPrice, timeType, expiration, orderComment);
         else
            sent = trade.SellStop(lot, entryPrice, _Symbol, slPrice, tpPrice, timeType, expiration, orderComment);

         uint retcode = trade.ResultRetcode();
         ulong orderTicket = trade.ResultOrder();
         bool accepted = sent &&
            (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED || retcode == TRADE_RETCODE_DONE_PARTIAL);
         if(!accepted || orderTicket == 0)
           {
            Print("StopGrid9-Manual: failed to place ", (direction > 0 ? "Buy Stop" : "Sell Stop"),
                  " level ", level, " | retcode=", retcode, " ", trade.ResultRetcodeDescription(),
                  " | lastError=", GetLastError());
            RollbackGrid(placedTickets, placedCount);
            Print("StopGrid9-Manual: pending orders placed so far were rolled back; the manual Level 1 ",
                  "position is a real fill and was left open for the exit-management logic ",
                  "(anchor SL / gap-safety) to handle.");
            return(false);
           }

         placedTickets[placedCount++] = orderTicket;
        }
     }

   g_cycleHadActivity = true;
   g_startedOnce = true;
   Print("StopGrid9-Manual: grid armed around manual Level 1 | anchor=", DoubleToString(anchor, _Digits),
         " | Level 1 lot (both sides)=", DoubleToString(manualLot, VolumeDigits()),
         " | Levels 2-", InpLevelsPerSide, " use InpFirstLevelLot's own progression",
         " | placed ", placedCount, " pending orders (opposite side Level 1, plus levels 2-",
         InpLevelsPerSide, " both sides).");
   return(true);
  }

//+------------------------------------------------------------------+
bool StartGrid(const int gridDirection)
  {
   if(gridDirection < -1 || gridDirection > 1)
      return(false);
   if(HasOwnActivity())
      return(true);

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.ask <= 0.0 || tick.bid <= 0.0)
     {
      Print("StopGrid9: no valid quote; grid placement will be retried.");
      return(false);
     }

   double spread = tick.ask - tick.bid;
   if(InpMaxSpreadPrice > 0.0 && spread > InpMaxSpreadPrice)
     {
      Print("StopGrid9: spread ", DoubleToString(spread, _Digits),
            " exceeds limit ", DoubleToString(InpMaxSpreadPrice, _Digits), "; grid placement will be retried.");
      return(false);
     }

   double anchor = NormalizePrice((tick.ask + tick.bid) / 2.0);
   double modeledRisk = 0.0;
   double projectedMargin = 0.0;
   double projectedMarginLevel = 0.0;
   if(!PreflightGrid(anchor, gridDirection, modeledRisk, projectedMargin, projectedMarginLevel))
      return(false);

   int sideCount = (gridDirection == 0 ? 2 : 1);
   Print("StopGrid9: placing ", sideCount * InpLevelsPerSide, " stop orders | anchor=", DoubleToString(anchor, _Digits),
         " | grid=", (gridDirection > 0 ? "BUY-only" : (gridDirection < 0 ? "SELL-only" : "both sides")),
         " | step=", DoubleToString(InpGridStepPrice, 2), " | base lot=", DoubleToString(InpFirstLevelLot, VolumeDigits()),
         " | lot mode=", LotModeName(),
         " | modeled conservative anchor-stop risk=", DoubleToString(modeledRisk, 2), " ", AccountInfoString(ACCOUNT_CURRENCY),
         " | projected margin=", DoubleToString(projectedMargin, 2), " ", AccountInfoString(ACCOUNT_CURRENCY),
         " | projected margin level=", DoubleToString(projectedMarginLevel, 1), "%");

   g_anchorPrice = anchor;
   g_trailingDirection = 0;
   g_level3Evaluated = false;
   g_fixedCaseId = 0;
   g_fixedCaseDirection = 0;
   g_fixedCaseCloseRetryAfter = 0;
   g_pendingCancelRetryAfter = 0;
   if(GlobalVariableCheck(TrailingDirectionKey()))
      GlobalVariableDel(TrailingDirectionKey());
   if(GlobalVariableCheck(ThirdLevelResolvedKey()))
      GlobalVariableDel(ThirdLevelResolvedKey());
   if(GlobalVariableCheck(FixedCaseKey()))
      GlobalVariableDel(FixedCaseKey());
   if(GlobalVariableCheck(FixedCaseDirectionKey()))
      GlobalVariableDel(FixedCaseDirectionKey());
   GlobalVariableSet(g_stateKey, g_anchorPrice);

   ulong placedTickets[];
   ArrayResize(placedTickets, sideCount * InpLevelsPerSide);
   int placedCount = 0;

   for(int sideIndex = 0; sideIndex < sideCount; sideIndex++)
     {
      int direction = (gridDirection == 0 ? (sideIndex == 0 ? 1 : -1) : gridDirection);
      for(int level = 1; level <= InpLevelsPerSide; level++)
        {
         double requestedLot = LotForLevel(level);
         double lot = NormalizeVolumeDown(requestedLot);
         double entryPrice = NormalizePrice(anchor + direction * LevelDistance(level));
         double slPrice = NormalizePrice(anchor - direction * InpStopLossBeyondAnchor);
         double tpPrice = NormalizePrice(anchor + direction * (LevelDistance(InpLevelsPerSide) + InpTakeProfitBeyondLast));
         datetime expiration = 0;
         ENUM_ORDER_TYPE_TIME timeType = ORDER_TIME_GTC;
         if(InpExpirationHours > 0)
           {
            expiration = TimeCurrent() + InpExpirationHours * 3600;
            timeType = ORDER_TIME_SPECIFIED;
           }

         string sideName = (direction > 0 ? "B" : "S");
         string orderComment = StringFormat("SG9|%s|L%02d", sideName, level);
         ResetLastError();
         bool sent = false;
         if(direction > 0)
            sent = trade.BuyStop(lot, entryPrice, _Symbol, slPrice, tpPrice, timeType, expiration, orderComment);
         else
            sent = trade.SellStop(lot, entryPrice, _Symbol, slPrice, tpPrice, timeType, expiration, orderComment);

         uint retcode = trade.ResultRetcode();
         ulong orderTicket = trade.ResultOrder();
         bool accepted = sent &&
            (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED || retcode == TRADE_RETCODE_DONE_PARTIAL);
         if(!accepted || orderTicket == 0)
           {
            Print("StopGrid9: failed to place ", (direction > 0 ? "Buy Stop" : "Sell Stop"),
                  " level ", level, " | retcode=", retcode, " ", trade.ResultRetcodeDescription(),
                  " | lastError=", GetLastError());
            RollbackGrid(placedTickets, placedCount);
            g_anchorPrice = 0.0;
            ClearSavedAnchor();
            return(false);
           }

         placedTickets[placedCount++] = orderTicket;
        }
     }

   g_cycleHadActivity = true;
   g_startedOnce = true;
   Print("StopGrid9: grid armed successfully with ", sideCount * InpLevelsPerSide,
         " pending orders across ", sideCount, " side(s).");
   return(true);
  }

//+------------------------------------------------------------------+
bool PreflightGrid(const double anchor,
                   const int gridDirection,
                   double &modeledRisk,
                   double &projectedMargin,
                   double &projectedMarginLevel,
                   const bool skipLevel1StopDistance = false)
  {
   if(gridDirection < -1 || gridDirection > 1)
      return(false);

   bool includeBuy = (gridDirection >= 0);
   bool includeSell = (gridDirection <= 0);
   modeledRisk = 0.0;
   projectedMargin = 0.0;
   projectedMarginLevel = 0.0;
   double buyRisk = 0.0;
   double sellRisk = 0.0;
   double buyMargin = 0.0;
   double sellMargin = 0.0;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
     {
      Print("StopGrid9: cannot read a quote during preflight.");
      return(false);
     }

   long stopsLevelPoints = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDistance = stopsLevelPoints * _Point;

   for(int level = 1; level <= InpLevelsPerSide; level++)
     {
      double requestedLot = LotForLevel(level);
      double lot = NormalizeVolumeDown(requestedLot);
      if(lot < g_volumeMin || lot > g_volumeMax || MathAbs(lot - requestedLot) > g_volumeStep * 0.000001)
        {
         Print("StopGrid9: lot ", DoubleToString(requestedLot, 8), " at level ", level,
               " is not exactly representable by this broker's volume min/max/step; refusing a partial grid.");
         return(false);
        }

      double buyEntry = NormalizePrice(anchor + LevelDistance(level));
      double sellEntry = NormalizePrice(anchor - LevelDistance(level));
      bool checkStopDistance = (level > 1 || !skipLevel1StopDistance);
      if(checkStopDistance &&
         ((includeBuy && buyEntry <= tick.ask + minStopDistance) ||
          (includeSell && sellEntry >= tick.bid - minStopDistance)))
        {
         Print("StopGrid9: a pending entry is inside the broker's minimum stop distance; grid placement will be retried.");
         return(false);
        }

      double buySl = NormalizePrice(anchor - InpStopLossBeyondAnchor);
      double sellSl = NormalizePrice(anchor + InpStopLossBeyondAnchor);
      double buyTp = NormalizePrice(anchor + LevelDistance(InpLevelsPerSide) + InpTakeProfitBeyondLast);
      double sellTp = NormalizePrice(anchor - LevelDistance(InpLevelsPerSide) - InpTakeProfitBeyondLast);
      if(checkStopDistance &&
         ((includeBuy && ((buyEntry - buySl) < minStopDistance || (buyTp - buyEntry) < minStopDistance)) ||
          (includeSell && ((sellSl - sellEntry) < minStopDistance || (sellEntry - sellTp) < minStopDistance))))
        {
         Print("StopGrid9: one or more SL/TP levels violate the broker's minimum stop distance.");
         return(false);
        }

      double buyProfitAtStop = 0.0;
      double sellProfitAtStop = 0.0;
      double buyRequiredMargin = 0.0;
      double sellRequiredMargin = 0.0;
      double buyRiskExit = buySl - InpRiskSlipBufferPrice;
      double sellRiskExit = sellSl + InpRiskSlipBufferPrice;

      if((includeBuy && !OrderCalcProfit(ORDER_TYPE_BUY, _Symbol, lot, buyEntry, buyRiskExit, buyProfitAtStop)) ||
         (includeSell && !OrderCalcProfit(ORDER_TYPE_SELL, _Symbol, lot, sellEntry, sellRiskExit, sellProfitAtStop)))
        {
         Print("StopGrid9: OrderCalcProfit failed; risk cannot be estimated, so no grid was placed. Error=", GetLastError());
         return(false);
        }

      if((includeBuy && !OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lot, buyEntry, buyRequiredMargin)) ||
         (includeSell && !OrderCalcMargin(ORDER_TYPE_SELL, _Symbol, lot, sellEntry, sellRequiredMargin)))
        {
         Print("StopGrid9: OrderCalcMargin failed; grid affordability cannot be verified. Error=", GetLastError());
         return(false);
        }

      buyRisk += MathMax(0.0, -buyProfitAtStop);
      sellRisk += MathMax(0.0, -sellProfitAtStop);
      buyMargin += MathMax(0.0, buyRequiredMargin);
      sellMargin += MathMax(0.0, sellRequiredMargin);
     }

   // The broker may allow both directions to stop out in separate legs of one KEEP cycle.
   modeledRisk = buyRisk + sellRisk;
   if(InpMaxRiskPercent > 0.0)
     {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity <= 0.0)
        {
         Print("StopGrid9: account equity is unavailable; risk guard rejects the grid.");
         return(false);
        }
      double riskPercent = 100.0 * modeledRisk / equity;
      if(riskPercent > InpMaxRiskPercent)
        {
         Print("StopGrid9: modeled conservative anchor-stop risk is ", DoubleToString(riskPercent, 2),
               "% of equity, above the ", DoubleToString(InpMaxRiskPercent, 2), "% limit. Reduce the base lot or raise the risk limit deliberately.");
         return(false);
        }
     }

   double hedgedMargin = SymbolInfoDouble(_Symbol, SYMBOL_MARGIN_HEDGED);
   projectedMargin = (gridDirection == 0 && hedgedMargin > 0.0 ?
                      buyMargin + sellMargin : MathMax(buyMargin, sellMargin));
   double usedMargin = AccountInfoDouble(ACCOUNT_MARGIN);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double totalMargin = usedMargin + projectedMargin;
   if(totalMargin > 0.0)
      projectedMarginLevel = 100.0 * equity / totalMargin;
   else
      projectedMarginLevel = 1000000.0;

   if(InpMinMarginLevelPct > 0.0 && projectedMarginLevel < InpMinMarginLevelPct)
     {
      Print("StopGrid9: projected margin level ", DoubleToString(projectedMarginLevel, 1),
            "% is below the ", DoubleToString(InpMinMarginLevelPct, 1), "% minimum.");
      return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
double LotForLevel(const int level)
  {
   // Level 1 (both sides) always uses whatever lot the user manually clicked, regardless
   // of InpFirstLevelLot. Levels 2..N stay fixed to InpFirstLevelLot's own progression
   // (equal / odd-multiplier / custom) - same absolute lots the auto EA would use -
   // unrelated to the manual lot.
   if(level <= 1)
      return(g_manualLevel1Lot > 0.0 ? g_manualLevel1Lot : InpFirstLevelLot);
   if(InpLotMode == GRID_LOT_EQUAL)
      return(InpFirstLevelLot);
   if(InpLotMode == GRID_LOT_CUSTOM)
      return(g_customLots[level - 1]);
   return(InpFirstLevelLot * (2 * level - 1));
  }

//+------------------------------------------------------------------+
bool LoadCustomLotSequence()
  {
   string tokens[];
   ushort separator = (ushort)StringGetCharacter(",", 0);
   int count = StringSplit(InpCustomLotSequence, separator, tokens);
   if(count != InpLevelsPerSide)
     {
      Print("StopGrid9: custom lot sequence must contain exactly ", InpLevelsPerSide, " comma-separated values.");
      return(false);
     }

   ArrayResize(g_customLots, count);
   for(int i = 0; i < count; i++)
     {
      StringTrimLeft(tokens[i]);
      StringTrimRight(tokens[i]);
      double lot = StringToDouble(tokens[i]);
      if(lot <= 0.0)
        {
         Print("StopGrid9: custom lot value at level ", i + 1, " is invalid.");
         return(false);
        }
      g_customLots[i] = lot;
     }

   if(MathAbs(g_customLots[0] - InpFirstLevelLot) > 0.000000001)
     {
      Print("StopGrid9: custom sequence level 1 must equal InpFirstLevelLot so both first opposing levels match.");
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
string LotModeName()
  {
   if(InpLotMode == GRID_LOT_EQUAL)
      return("equal");
   if(InpLotMode == GRID_LOT_ODD_MULTIPLIER)
      return("odd-multiple");
   return("custom");
  }

//+------------------------------------------------------------------+
double LevelDistance(const int level)
  {
   if(level <= 1)
      return(InpFirstLevelDistance);
   return(InpFirstLevelDistance + (level - 1) * InpGridStepPrice);
  }

//+------------------------------------------------------------------+
double NormalizePrice(const double price)
  {
   if(g_tickSize <= 0.0)
      return(NormalizeDouble(price, _Digits));
   return(NormalizeDouble(MathRound(price / g_tickSize) * g_tickSize, _Digits));
  }

//+------------------------------------------------------------------+
double NormalizeVolumeDown(const double requestedVolume)
  {
   if(g_volumeStep <= 0.0)
      return(0.0);
   double steps = MathFloor(requestedVolume / g_volumeStep + 0.000000001);
   double volume = NormalizeDouble(steps * g_volumeStep, VolumeDigits());
   if(volume < g_volumeMin - g_volumeStep * 0.000001 || volume > g_volumeMax + g_volumeStep * 0.000001)
      return(0.0);
   return(volume);
  }

//+------------------------------------------------------------------+
int VolumeDigits()
  {
   int digits = 0;
   while(digits < 8 && MathAbs(g_volumeStep - NormalizeDouble(g_volumeStep, digits)) > 0.000000001)
      digits++;
   return(digits);
  }

//+------------------------------------------------------------------+
bool HasOwnActivity()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         IsOwnPosition(ticket))
         return(true);
     }

   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
         (ulong)OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
double RecoverAnchorPrice()
  {
   if(g_stateKey != "" && GlobalVariableCheck(g_stateKey))
     {
      double saved = GlobalVariableGet(g_stateKey);
      if(saved > 0.0)
         return(NormalizePrice(saved));
     }

   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol ||
         (ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
         continue;
      double sl = OrderGetDouble(ORDER_SL);
      if(sl > 0.0)
         return(NormalizePrice(sl));
     }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         !IsOwnPosition(ticket))
         continue;
      double sl = PositionGetDouble(POSITION_SL);
      if(sl > 0.0)
         return(NormalizePrice(sl));
     }

   return(0.0);
  }

//+------------------------------------------------------------------+
void ApplyOppositeMode()
  {
   if(InpOppositeMode != OPPOSITE_DELETE)
      return;

   int firstDirection = FirstFilledDirection();
   if(firstDirection == 0)
      return;

   ENUM_ORDER_TYPE typeToDelete = (firstDirection > 0 ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_BUY_STOP);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol ||
         (ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber ||
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != typeToDelete)
         continue;
      bool requestSent = trade.OrderDelete(ticket);
      if(!TradeResultAccepted(requestSent, true))
         Print("StopGrid9: failed to cancel opposite pending order #", ticket,
               " | retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
int FirstFilledDirection()
  {
   bool found = false;
   datetime oldestTime = 0;
   int direction = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         !IsOwnPosition(ticket))
         continue;
      datetime positionTime = (datetime)PositionGetInteger(POSITION_TIME);
      if(!found || positionTime < oldestTime)
        {
         found = true;
         oldestTime = positionTime;
         ENUM_POSITION_TYPE positionType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         direction = (positionType == POSITION_TYPE_BUY ? 1 : -1);
        }
     }
   return(direction);
  }

//+------------------------------------------------------------------+
int DetectThirdLevelDirection()
  {
   bool found = false;
   datetime oldestTime = 0;
   int direction = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         !IsOwnPosition(ticket))
         continue;

      ENUM_POSITION_TYPE positionType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      int positionDirection = (positionType == POSITION_TYPE_BUY ? 1 : -1);
      bool isLevelThree = (StringFind(PositionGetString(POSITION_COMMENT), "|L03") >= 0);
      if(!isLevelThree)
         continue;

      datetime positionTime = (datetime)PositionGetInteger(POSITION_TIME);
      if(!found || positionTime < oldestTime)
        {
         found = true;
         oldestTime = positionTime;
         direction = positionDirection;
        }
     }
   return(direction);
  }

//+------------------------------------------------------------------+
int CountOwnPositionsByDirection(const int direction)
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         !IsOwnPosition(ticket))
         continue;

      ENUM_POSITION_TYPE positionType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if((direction > 0 && positionType == POSITION_TYPE_BUY) ||
         (direction < 0 && positionType == POSITION_TYPE_SELL))
         count++;
     }
   return(count);
  }

//+------------------------------------------------------------------+
void EvaluateThirdLevelCase(const int direction)
  {
   if(g_level3Evaluated || (direction != 1 && direction != -1))
      return;

   int sameSidePositions = CountOwnPositionsByDirection(direction);
   int oppositeSidePositions = CountOwnPositionsByDirection(-direction);
   Print("StopGrid9: L03 fill detected; open-position counts=", sameSidePositions, "-", oppositeSidePositions);
   if(sameSidePositions == 3 && oppositeSidePositions >= 1 && oppositeSidePositions <= 3)
     {
      g_level3Evaluated = true;
      ActivateConfiguredCase(oppositeSidePositions, direction);
      GlobalVariableSet(ThirdLevelResolvedKey(), 1.0);
      return;
     }

   if(sameSidePositions < 3 && oppositeSidePositions == 0)
     {
      Print("StopGrid9: L03 fill seen but only ", sameSidePositions,
            " same-side position(s) settled so far; will re-check on the next tick.");
      return;
     }

   if(sameSidePositions != 3 || oppositeSidePositions != 0)
     {
      g_level3Evaluated = true;
      GlobalVariableSet(ThirdLevelResolvedKey(), 1.0);
      Print("StopGrid9: level 3 filled but the open-position counts do not match a configured 3-x case.");
      return;
     }

   g_level3Evaluated = true;
   ActivateTrailing(direction);
   GlobalVariableSet(ThirdLevelResolvedKey(), 1.0);
  }

//+------------------------------------------------------------------+
void ManageGridExitRules()
  {
   ForceCloseGappedStops();

   if(g_trailingDirection != 0)
     {
      ActivateTrailing(g_trailingDirection);
      return;
     }
   if(g_fixedCaseId != 0)
     {
      ManageConfiguredCase();
      return;
     }

   if(!g_level3Evaluated)
     {
      int detectedDirection = DetectThirdLevelDirection();
      if(detectedDirection != 0)
         EvaluateThirdLevelCase(detectedDirection);
     }
   if(g_trailingDirection != 0)
     {
      ActivateTrailing(g_trailingDirection);
      return;
     }
   if(g_fixedCaseId != 0)
     {
      ManageConfiguredCase();
      return;
     }

   int fifthLevelDirection = DetectFifthLevelDirection();
   if(fifthLevelDirection != 0)
     {
      ActivateConfiguredCase(4, fifthLevelDirection);
      ManageConfiguredCase();
      return;
     }

   ApplyOppositeMode();
  }

//+------------------------------------------------------------------+
int DetectFifthLevelDirection()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         !IsOwnPosition(ticket) ||
         StringFind(PositionGetString(POSITION_COMMENT), "|L05") < 0)
         continue;

      ENUM_POSITION_TYPE positionType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      int direction = (positionType == POSITION_TYPE_BUY ? 1 : -1);
      if(CountOwnPositionsByDirection(direction) == 5 &&
         CountOwnPositionsByDirection(-direction) == 4)
         return(direction);
     }
   return(0);
  }

//+------------------------------------------------------------------+
void ActivateConfiguredCase(const int caseId, const int direction)
  {
   if(caseId < 1 || caseId > 4 || (direction != 1 && direction != -1))
      return;
   if(g_trailingDirection != 0 || g_fixedCaseId != 0)
      return;

   g_fixedCaseId = caseId;
   g_fixedCaseDirection = direction;
   GlobalVariableSet(FixedCaseKey(), (double)g_fixedCaseId);
   GlobalVariableSet(FixedCaseDirectionKey(), (double)g_fixedCaseDirection);
   GlobalVariableSet(ThirdLevelResolvedKey(), 1.0);
   g_level3Evaluated = true;
   Print("StopGrid9: case ", FixedCaseName(caseId), " activated on ",
         (direction > 0 ? "Buy" : "Sell"), "; setting the main-side TP.");
  }

//+------------------------------------------------------------------+
int ConfiguredCaseTargetLevel(const int caseId)
  {
   if(caseId == 1)
      return(4);
   if(caseId == 2)
      return(5);
   if(caseId == 3)
      return(7);
   if(caseId == 4)
      return(9);
   return(0);
  }

//+------------------------------------------------------------------+
int ConfiguredCaseStopLevel(const int caseId)
  {
   if(caseId == 1)
      return(3);
   if(caseId == 2)
      return(4);
   if(caseId == 3)
      return(6);
   if(caseId == 4)
      return(8);
   return(0);
  }

//+------------------------------------------------------------------+
string FixedCaseName(const int caseId)
  {
   if(caseId == 1)
      return("3-1");
   if(caseId == 2)
      return("3-2");
   if(caseId == 3)
      return("3-3");
   if(caseId == 4)
      return("5-4");
   return("unknown");
  }

//+------------------------------------------------------------------+
bool HasOwnPositionAtLevel(const int direction, const int level)
  {
   if(direction != 1 && direction != -1)
      return(false);
   string levelMarker = StringFormat("|L%02d", level);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         !IsOwnPosition(ticket) ||
         StringFind(PositionGetString(POSITION_COMMENT), levelMarker) < 0)
         continue;
      ENUM_POSITION_TYPE positionType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if((direction > 0 && positionType == POSITION_TYPE_BUY) ||
         (direction < 0 && positionType == POSITION_TYPE_SELL))
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
void ManageConfiguredCase()
  {
   if(g_anchorPrice <= 0.0 || g_fixedCaseId < 1 || g_fixedCaseId > 4 ||
      (g_fixedCaseDirection != 1 && g_fixedCaseDirection != -1))
      return;

   int targetLevel = ConfiguredCaseTargetLevel(g_fixedCaseId);
   int stopLevel = ConfiguredCaseStopLevel(g_fixedCaseId);
   double targetPrice = NormalizePrice(g_anchorPrice + g_fixedCaseDirection *
                                       (LevelDistance(targetLevel) + TRAIL_STEP_PRICE));
   double stopPrice = NormalizePrice(g_anchorPrice + g_fixedCaseDirection *
                                     (LevelDistance(stopLevel) + TRAIL_STEP_PRICE));

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.ask <= 0.0 || tick.bid <= 0.0)
      return;
   double currentPrice = (g_fixedCaseDirection > 0 ? tick.bid : tick.ask);
   bool targetReached = (g_fixedCaseDirection > 0 ? currentPrice >= targetPrice :
                                                     currentPrice <= targetPrice);
   if(targetReached)
     {
      int pendingBeforeTarget = CountOwnPendingOrders();
      if(pendingBeforeTarget > 0 && PendingCancelRetryDue())
         DeleteAllOwnPending();
      if(!AllMainPositionsHaveCaseTakeProfit(g_fixedCaseDirection, targetPrice))
         RetryCloseCaseBasket("TP target was reached before every main-side position had that TP");
      return;
     }

   SetConfiguredCaseTakeProfit(g_fixedCaseDirection, targetPrice);

   if(!HasOwnPositionAtLevel(g_fixedCaseDirection, targetLevel))
      return;

   int pendingBefore = CountOwnPendingOrders();
   if(pendingBefore > 0 && PendingCancelRetryDue())
     {
      DeleteAllOwnPending();
      Print("StopGrid9: case ", FixedCaseName(g_fixedCaseId), " target L",
            targetLevel, " filled; deleting pending orders ", pendingBefore,
            " -> ", CountOwnPendingOrders());
     }
   SetConfiguredCaseStopLoss(g_fixedCaseDirection, stopPrice);
  }

//+------------------------------------------------------------------+
bool AllMainPositionsHaveCaseTakeProfit(const int direction, const double targetPrice)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         !IsOwnPosition(ticket))
         continue;
      ENUM_POSITION_TYPE positionType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if((direction > 0 && positionType != POSITION_TYPE_BUY) ||
         (direction < 0 && positionType != POSITION_TYPE_SELL))
         continue;

      double takeProfit = PositionGetDouble(POSITION_TP);
      bool protectedByTarget = (direction > 0 ?
                                (takeProfit > 0.0 && takeProfit <= targetPrice + g_tickSize * 0.5) :
                                (takeProfit > 0.0 && takeProfit >= targetPrice - g_tickSize * 0.5));
      if(!protectedByTarget)
         return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
void SetConfiguredCaseTakeProfit(const int direction, const double targetPrice)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         !IsOwnPosition(ticket))
         continue;
      ENUM_POSITION_TYPE positionType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if((direction > 0 && positionType != POSITION_TYPE_BUY) ||
         (direction < 0 && positionType != POSITION_TYPE_SELL))
         continue;

      double stopLoss = PositionGetDouble(POSITION_SL);
      double takeProfit = PositionGetDouble(POSITION_TP);
      if(takeProfit > 0.0 && MathAbs(takeProfit - targetPrice) <= g_tickSize * 0.5)
         continue;
      bool requestSent = trade.PositionModify(ticket, stopLoss, targetPrice);
      if(TradeResultAccepted(requestSent, false))
         Print("StopGrid9: case TP set for position #", ticket, " to ",
               DoubleToString(targetPrice, _Digits));
      else
         Print("StopGrid9: failed to set case TP for position #", ticket,
               " | retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
void SetConfiguredCaseStopLoss(const int direction, const double stopPrice)
  {
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.ask <= 0.0 || tick.bid <= 0.0)
      return;
   double currentPrice = (direction > 0 ? tick.bid : tick.ask);
   bool hasPosition = false;
   bool allPositionsProtected = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         !IsOwnPosition(ticket))
         continue;
      ENUM_POSITION_TYPE positionType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if((direction > 0 && positionType != POSITION_TYPE_BUY) ||
         (direction < 0 && positionType != POSITION_TYPE_SELL))
         continue;

      hasPosition = true;
      double oldStop = PositionGetDouble(POSITION_SL);
      bool protectedByStop = (direction > 0 ? oldStop >= stopPrice - g_tickSize * 0.5 :
                                               (oldStop > 0.0 && oldStop <= stopPrice + g_tickSize * 0.5));
      if(!protectedByStop)
         allPositionsProtected = false;
     }
   if(!hasPosition)
      return;

   if((direction > 0 && currentPrice <= stopPrice) ||
      (direction < 0 && currentPrice >= stopPrice))
     {
      if(allPositionsProtected)
         return; // The server-side fixed SL will close these positions when the market can execute it.
      RetryCloseCaseBasket("fixed SL was crossed before every position was protected");
      return;
     }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         !IsOwnPosition(ticket))
         continue;
      ENUM_POSITION_TYPE positionType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if((direction > 0 && positionType != POSITION_TYPE_BUY) ||
         (direction < 0 && positionType != POSITION_TYPE_SELL))
         continue;

      double oldStop = PositionGetDouble(POSITION_SL);
      bool tighten = (oldStop <= 0.0 ||
                      (direction > 0 && stopPrice > oldStop + g_tickSize * 0.5) ||
                      (direction < 0 && stopPrice < oldStop - g_tickSize * 0.5));
      if(!tighten)
         continue;

      double takeProfit = PositionGetDouble(POSITION_TP);
      bool requestSent = trade.PositionModify(ticket, stopPrice, takeProfit);
      if(TradeResultAccepted(requestSent, false))
         Print("StopGrid9: case fixed SL set for position #", ticket, " to ",
               DoubleToString(stopPrice, _Digits));
      else
         Print("StopGrid9: failed to set case fixed SL for position #", ticket,
               " | retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
void RetryCloseCaseBasket(const string reason)
  {
   if(TimeCurrent() < g_fixedCaseCloseRetryAfter)
      return;
   int retryDelay = InpRetrySeconds;
   if(retryDelay < 30)
      retryDelay = 30;
   g_fixedCaseCloseRetryAfter = TimeCurrent() + retryDelay;
   Print("StopGrid9: case ", FixedCaseName(g_fixedCaseId), "; ", reason,
         "; retrying a main-side basket close.");
   ClosePositionsByDirection(g_fixedCaseDirection);
  }

//+------------------------------------------------------------------+
void ActivateTrailing(const int detectedDirection)
  {
   if(g_trailingDirection == 0)
     {
      g_trailingDirection = detectedDirection;
      if(g_trailingDirection != 0 && g_stateKey != "")
        {
         GlobalVariableSet(TrailingDirectionKey(), (double)g_trailingDirection);
         Print("StopGrid9: level 3 filled; canceling all pending orders and starting the $1.00 trailing stop.");
        }
     }

   if(g_trailingDirection == 0)
      return;

   int pendingBefore = CountOwnPendingOrders();
   if(pendingBefore > 0 && PendingCancelRetryDue())
     {
      DeleteAllOwnPending();
      Print("StopGrid9: 3-0 pending cancellation requested; own pending orders ",
            pendingBefore, " -> ", CountOwnPendingOrders());
     }
   ManageTrailingStops(g_trailingDirection);
  }

//+------------------------------------------------------------------+
void ManageTrailingStops(const int direction)
  {
   if(g_anchorPrice <= 0.0 || (direction != 1 && direction != -1))
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.ask <= 0.0 || tick.bid <= 0.0)
      return;

   double currentPrice = (direction > 0 ? tick.bid : tick.ask);
   double activationPrice = g_anchorPrice + direction * LevelDistance(TRAIL_ACTIVATION_LEVEL);
   double favorableMove = direction * (currentPrice - activationPrice);
   int trailSteps = 0;
   if(favorableMove > 0.0)
      trailSteps = (int)MathFloor(favorableMove / TRAIL_STEP_PRICE + 0.000000001);

   // The initial stop is level 1 plus $1.00; each $1.00 beyond level 3 advances it by $1.00.
   double targetStop = NormalizePrice(g_anchorPrice + direction *
                                      (LevelDistance(1) + TRAIL_STEP_PRICE + trailSteps * TRAIL_STEP_PRICE));
   bool hasPosition = false;
   bool hasExistingStop = false;
   double strongestStop = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         !IsOwnPosition(ticket))
         continue;

      ENUM_POSITION_TYPE positionType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if((direction > 0 && positionType != POSITION_TYPE_BUY) ||
         (direction < 0 && positionType != POSITION_TYPE_SELL))
         continue;

      hasPosition = true;
      double oldStop = PositionGetDouble(POSITION_SL);
      if(oldStop <= 0.0)
         continue;
      if(!hasExistingStop || (direction > 0 && oldStop > strongestStop) ||
         (direction < 0 && oldStop < strongestStop))
        {
         strongestStop = oldStop;
         hasExistingStop = true;
        }
     }

   if(!hasPosition)
      return;

   if(hasExistingStop)
     {
      if(direction > 0)
         targetStop = MathMax(targetStop, strongestStop);
      else
         targetStop = MathMin(targetStop, strongestStop);
     }

   // Exit is left entirely to the broker-side SL set below (PositionModify), not a
   // manual price-cross close here: racing our own market-close against the broker's
   // own stop trigger caused duplicate-request failures and could delay the exit.
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         !IsOwnPosition(ticket))
         continue;

      ENUM_POSITION_TYPE positionType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if((direction > 0 && positionType != POSITION_TYPE_BUY) ||
         (direction < 0 && positionType != POSITION_TYPE_SELL))
         continue;

      double oldStop = PositionGetDouble(POSITION_SL);
      bool tighten = (oldStop <= 0.0 ||
                      (direction > 0 && targetStop > oldStop + g_tickSize * 0.5) ||
                      (direction < 0 && targetStop < oldStop - g_tickSize * 0.5));
      if(!tighten)
         continue;

      double takeProfit = PositionGetDouble(POSITION_TP);
      bool requestSent = trade.PositionModify(ticket, targetStop, takeProfit);
      if(TradeResultAccepted(requestSent, false))
         Print("StopGrid9: trailing SL moved for position #", ticket, " from ",
               DoubleToString(oldStop, _Digits), " to ", DoubleToString(targetStop, _Digits));
      else
         Print("StopGrid9: failed to update trailing SL for position #", ticket,
               " to ", DoubleToString(targetStop, _Digits), " | retcode=", trade.ResultRetcode(),
               " ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
// Safety net: force-close any own position whose SL price has already been gapped
// past (price on the wrong side of it right now) instead of relying only on the
// broker to trigger its own stop order for it.
void ForceCloseGappedStops()
  {
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.ask <= 0.0 || tick.bid <= 0.0)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         !IsOwnPosition(ticket))
         continue;

      double stopPrice = PositionGetDouble(POSITION_SL);
      if(stopPrice <= 0.0)
         continue;

      ENUM_POSITION_TYPE positionType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      bool gapped = (positionType == POSITION_TYPE_BUY && tick.bid <= stopPrice) ||
                    (positionType == POSITION_TYPE_SELL && tick.ask >= stopPrice);
      if(!gapped)
         continue;

      bool requestSent = trade.PositionClose(ticket);
      if(TradeResultAccepted(requestSent, false))
         Print("StopGrid9: gap-safety closed position #", ticket,
               " (price already past its SL ", DoubleToString(stopPrice, _Digits), ").");
      else
         Print("StopGrid9: gap-safety close failed for position #", ticket,
               " | retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
void ClosePositionsByDirection(const int direction)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         !IsOwnPosition(ticket))
         continue;

      ENUM_POSITION_TYPE positionType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if((direction > 0 && positionType != POSITION_TYPE_BUY) ||
         (direction < 0 && positionType != POSITION_TYPE_SELL))
         continue;

      bool requestSent = trade.PositionClose(ticket);
      if(!TradeResultAccepted(requestSent, false))
         Print("StopGrid9: failed to close position #", ticket,
               " | retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
void RollbackGrid(ulong &placedTickets[], const int placedCount)
  {
   for(int i = placedCount - 1; i >= 0; i--)
     {
      ulong ticket = placedTickets[i];
      if(ticket > 0 && OrderSelect(ticket))
        {
         bool requestSent = trade.OrderDelete(ticket);
         if(!TradeResultAccepted(requestSent, true))
            Print("StopGrid9: rollback could not delete pending order #", ticket,
                  " | retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
        }
     }

   DeleteAllOwnPending();
   CloseAllOwnPositions();
   Print("StopGrid9: partial grid was rolled back after a placement failure.");
  }

//+------------------------------------------------------------------+
// Gate for repeated per-tick pending-cancel attempts: once a cancel attempt
// fails (e.g. broker retcode 10013 near a session boundary), back off for
// InpRetrySeconds instead of hammering OrderSend every tick until it works.
bool PendingCancelRetryDue()
  {
   if(TimeCurrent() < g_pendingCancelRetryAfter)
      return(false);
   int retryDelay = InpRetrySeconds;
   if(retryDelay < 5)
      retryDelay = 5;
   g_pendingCancelRetryAfter = TimeCurrent() + retryDelay;
   return(true);
  }

//+------------------------------------------------------------------+
void DeleteAllOwnPending()
  {
   bool anyFailed = false;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol ||
         (ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
         continue;
      bool requestSent = trade.OrderDelete(ticket);
      if(!TradeResultAccepted(requestSent, true))
        {
         anyFailed = true;
         Print("StopGrid9: failed to delete pending order #", ticket,
               " | retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
        }
     }
   if(anyFailed)
      g_pendingCancelRetryAfter = TimeCurrent() + (InpRetrySeconds < 5 ? 5 : InpRetrySeconds);
  }

//+------------------------------------------------------------------+
int CountOwnPendingOrders()
  {
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol ||
         (ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
         continue;
      count++;
     }
   return(count);
  }

//+------------------------------------------------------------------+
void CloseAllOwnPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         !IsOwnPosition(ticket))
         continue;
      bool requestSent = trade.PositionClose(ticket);
      if(!TradeResultAccepted(requestSent, false))
         Print("StopGrid9: failed to close position #", ticket,
               " | retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
bool TradeResultAccepted(const bool methodResult, const bool allowPlaced)
  {
   if(!methodResult)
      return(false);
   uint retcode = trade.ResultRetcode();
   if(retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_DONE_PARTIAL)
      return(true);
   return(allowPlaced && retcode == TRADE_RETCODE_PLACED);
  }

//+------------------------------------------------------------------+
string StateKey()
  {
   uint symbolHash = 0;
   for(int i = 0; i < StringLen(_Symbol); i++)
      symbolHash = symbolHash * 31 + (uint)StringGetCharacter(_Symbol, i);
   return(StringFormat("SG9.%I64d.%I64u.%u",
                       AccountInfoInteger(ACCOUNT_LOGIN), InpMagicNumber, symbolHash));
  }

//+------------------------------------------------------------------+
string SessionClosePendingKey()
  {
   return(g_stateKey + ".SC");
  }

//+------------------------------------------------------------------+
string GapGuardPendingKey()
  {
   return(g_stateKey + ".GG");
  }

//+------------------------------------------------------------------+
string TrailingDirectionKey()
  {
   return(g_stateKey + ".T");
  }

//+------------------------------------------------------------------+
string ThirdLevelResolvedKey()
  {
   return(g_stateKey + ".R");
  }

//+------------------------------------------------------------------+
string FixedCaseKey()
  {
   return(g_stateKey + ".C");
  }

//+------------------------------------------------------------------+
string FixedCaseDirectionKey()
  {
   return(g_stateKey + ".D");
  }

//+------------------------------------------------------------------+
string ManualTicketKey()
  {
   return(g_stateKey + ".MT");
  }

//+------------------------------------------------------------------+
string ManualOppositeTicketKey()
  {
   return(g_stateKey + ".MO");
  }

//+------------------------------------------------------------------+
void ClearSavedAnchor()
  {
   if(g_stateKey != "" && GlobalVariableCheck(g_stateKey))
      GlobalVariableDel(g_stateKey);
   if(g_stateKey != "" && GlobalVariableCheck(TrailingDirectionKey()))
      GlobalVariableDel(TrailingDirectionKey());
   if(g_stateKey != "" && GlobalVariableCheck(ThirdLevelResolvedKey()))
      GlobalVariableDel(ThirdLevelResolvedKey());
   if(g_stateKey != "" && GlobalVariableCheck(FixedCaseKey()))
      GlobalVariableDel(FixedCaseKey());
   if(g_stateKey != "" && GlobalVariableCheck(FixedCaseDirectionKey()))
      GlobalVariableDel(FixedCaseDirectionKey());
   if(g_stateKey != "" && GlobalVariableCheck(GapGuardPendingKey()))
      GlobalVariableDel(GapGuardPendingKey());
   if(g_stateKey != "" && GlobalVariableCheck(ManualTicketKey()))
      GlobalVariableDel(ManualTicketKey());
   if(g_stateKey != "" && GlobalVariableCheck(ManualOppositeTicketKey()))
      GlobalVariableDel(ManualOppositeTicketKey());
   g_trailingDirection = 0;
   g_level3Evaluated = false;
   g_fixedCaseId = 0;
   g_fixedCaseDirection = 0;
   g_fixedCaseCloseRetryAfter = 0;
   g_pendingCancelRetryAfter = 0;
   g_gapGuardPending = false;
   g_manualTicket = 0;
   g_manualOppositeTicket = 0;
   g_manualLevel1Lot = 0.0;
  }
//+------------------------------------------------------------------+
