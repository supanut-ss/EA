//+------------------------------------------------------------------+
//| XAUUSD_StopGrid_9x9_EA.mq5                                      |
//| Symmetric nine-level Buy Stop / Sell Stop grid for MetaTrader 5. |
//+------------------------------------------------------------------+
#property copyright "Custom EA - XAUUSD 9x9 Stop Grid"
#property version   "1.20"
#property strict

#include <Trade/Trade.mqh>

CTrade trade;

#define MAX_GRID_LEVELS 32
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

input group "=== Grid Setup ==="
input int                 InpLevelsPerSide       = 9;          // Buy Stop and Sell Stop levels on each side.
input double              InpGridStepPrice       = 2.0;        // Price distance per level; 2.0 means $2.00, independent of _Point.
input double              InpFirstLevelLot       = 0.01;       // Level 1 lot; the opposite side's level 1 always matches it.
input ENUM_GRID_LOT_MODE  InpLotMode             = GRID_LOT_EQUAL;
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
input ulong               InpMagicNumber         = 20260925;

input group "=== Risk Guards ==="
input double              InpMaxRiskPercent      = 2.0;        // Reject the grid when modeled conservative anchor-stop risk exceeds this % of equity; 0 disables.
input double              InpRiskSlipBufferPrice = 0.05;       // Extra adverse close-price buffer used only by the risk estimate.
input double              InpMinMarginLevelPct   = 300.0;      // Projected margin level after all pending orders fill; 0 disables.
input int                 InpRetrySeconds        = 30;

double   g_tickSize = 0.0;
double   g_volumeMin = 0.0;
double   g_volumeMax = 0.0;
double   g_volumeStep = 0.0;
double   g_customLots[];
double   g_anchorPrice = 0.0;
datetime g_retryAfter = 0;
bool     g_cycleHadActivity = false;
bool     g_startedOnce = false;
int      g_trailingDirection = 0;
bool     g_level3Evaluated = false;
int      g_fixedCaseId = 0;
int      g_fixedCaseDirection = 0;
datetime g_fixedCaseCloseRetryAfter = 0;
string   g_stateKey = "";

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpLevelsPerSide < TRAIL_ACTIVATION_LEVEL || InpLevelsPerSide > MAX_GRID_LEVELS ||
      InpGridStepPrice <= 0.0 || InpFirstLevelLot <= 0.0 ||
      InpStopLossBeyondAnchor < 0.0 || InpTakeProfitBeyondLast <= 0.0 ||
      InpMaxSpreadPrice < 0.0 || InpExpirationHours < 0 ||
      InpSlippagePoints < 0 ||
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
      ManageGridExitRules();
      return(INIT_SUCCEEDED);
     }

   ClearSavedAnchor();
   if(StartGrid())
      g_startedOnce = true;
   else
      g_retryAfter = TimeCurrent() + InpRetrySeconds;

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   Comment("");
   // Open positions and pending orders retain their server-side SL/TP on EA removal.
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
      return;

   if(HasOwnActivity())
     {
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
      ClearSavedAnchor();
      g_retryAfter = TimeCurrent() + InpRearmDelaySeconds;
      Print("StopGrid9: previous grid has no open positions or pending orders.");
     }

   if(g_startedOnce && !InpAutoRearmAfterCycle)
      return;
   if(TimeCurrent() < g_retryAfter)
      return;

   if(StartGrid())
      g_startedOnce = true;
   else
      g_retryAfter = TimeCurrent() + InpRetrySeconds;
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
   if(StringFind(orderComment, "|L03") < 0)
      return;

   if(trans.deal_type == DEAL_TYPE_BUY || trans.deal_type == DEAL_TYPE_SELL)
      Print("StopGrid9: L03 fill transaction received; deferring the 3-0 check until OnTick reads settled positions.");
  }

//+------------------------------------------------------------------+
bool StartGrid()
  {
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
   if(!PreflightGrid(anchor, modeledRisk, projectedMargin, projectedMarginLevel))
      return(false);

   Print("StopGrid9: placing ", 2 * InpLevelsPerSide, " stop orders | anchor=", DoubleToString(anchor, _Digits),
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
   ArrayResize(placedTickets, 2 * InpLevelsPerSide);
   int placedCount = 0;

   for(int sideIndex = 0; sideIndex < 2; sideIndex++)
     {
      int direction = (sideIndex == 0 ? 1 : -1);
      for(int level = 1; level <= InpLevelsPerSide; level++)
        {
         double requestedLot = LotForLevel(level);
         double lot = NormalizeVolumeDown(requestedLot);
         double entryPrice = NormalizePrice(anchor + direction * level * InpGridStepPrice);
         double slPrice = NormalizePrice(anchor - direction * InpStopLossBeyondAnchor);
         double tpPrice = NormalizePrice(anchor + direction * (InpLevelsPerSide * InpGridStepPrice + InpTakeProfitBeyondLast));
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
   Print("StopGrid9: grid armed successfully. Buy Stop and Sell Stop ladders each contain ", InpLevelsPerSide, " levels.");
   return(true);
  }

//+------------------------------------------------------------------+
bool PreflightGrid(const double anchor,
                   double &modeledRisk,
                   double &projectedMargin,
                   double &projectedMarginLevel)
  {
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

      double buyEntry = NormalizePrice(anchor + level * InpGridStepPrice);
      double sellEntry = NormalizePrice(anchor - level * InpGridStepPrice);
      if(buyEntry <= tick.ask + minStopDistance || sellEntry >= tick.bid - minStopDistance)
        {
         Print("StopGrid9: a pending entry is inside the broker's minimum stop distance; grid placement will be retried.");
         return(false);
        }

      double buySl = NormalizePrice(anchor - InpStopLossBeyondAnchor);
      double sellSl = NormalizePrice(anchor + InpStopLossBeyondAnchor);
      double buyTp = NormalizePrice(anchor + InpLevelsPerSide * InpGridStepPrice + InpTakeProfitBeyondLast);
      double sellTp = NormalizePrice(anchor - InpLevelsPerSide * InpGridStepPrice - InpTakeProfitBeyondLast);
      if((buyEntry - buySl) < minStopDistance || (buyTp - buyEntry) < minStopDistance ||
         (sellSl - sellEntry) < minStopDistance || (sellEntry - sellTp) < minStopDistance)
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

      if(!OrderCalcProfit(ORDER_TYPE_BUY, _Symbol, lot, buyEntry, buyRiskExit, buyProfitAtStop) ||
         !OrderCalcProfit(ORDER_TYPE_SELL, _Symbol, lot, sellEntry, sellRiskExit, sellProfitAtStop))
        {
         Print("StopGrid9: OrderCalcProfit failed; risk cannot be estimated, so no grid was placed. Error=", GetLastError());
         return(false);
        }

      if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lot, buyEntry, buyRequiredMargin) ||
         !OrderCalcMargin(ORDER_TYPE_SELL, _Symbol, lot, sellEntry, sellRequiredMargin))
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
   projectedMargin = (hedgedMargin <= 0.0 ? MathMax(buyMargin, sellMargin) : buyMargin + sellMargin);
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
   if(InpLotMode == GRID_LOT_EQUAL || level <= 1)
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
         (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
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
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
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
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
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
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
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
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
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
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber ||
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
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber ||
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
                                       (targetLevel * InpGridStepPrice + TRAIL_STEP_PRICE));
   double stopPrice = NormalizePrice(g_anchorPrice + g_fixedCaseDirection *
                                     (stopLevel * InpGridStepPrice + TRAIL_STEP_PRICE));

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.ask <= 0.0 || tick.bid <= 0.0)
      return;
   double currentPrice = (g_fixedCaseDirection > 0 ? tick.bid : tick.ask);
   bool targetReached = (g_fixedCaseDirection > 0 ? currentPrice >= targetPrice :
                                                     currentPrice <= targetPrice);
   if(targetReached)
     {
      int pendingBeforeTarget = CountOwnPendingOrders();
      if(pendingBeforeTarget > 0)
         DeleteAllOwnPending();
      if(!AllMainPositionsHaveCaseTakeProfit(g_fixedCaseDirection, targetPrice))
         RetryCloseCaseBasket("TP target was reached before every main-side position had that TP");
      return;
     }

   SetConfiguredCaseTakeProfit(g_fixedCaseDirection, targetPrice);

   if(!HasOwnPositionAtLevel(g_fixedCaseDirection, targetLevel))
      return;

   int pendingBefore = CountOwnPendingOrders();
   if(pendingBefore > 0)
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
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
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
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
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
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
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
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
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
   if(pendingBefore > 0)
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
   double activationPrice = g_anchorPrice + direction * TRAIL_ACTIVATION_LEVEL * InpGridStepPrice;
   double favorableMove = direction * (currentPrice - activationPrice);
   int trailSteps = 0;
   if(favorableMove > 0.0)
      trailSteps = (int)MathFloor(favorableMove / TRAIL_STEP_PRICE + 0.000000001);

   // The initial stop is level 1 plus $1.00; each $1.00 beyond level 3 advances it by $1.00.
   double targetStop = NormalizePrice(g_anchorPrice + direction *
                                      (InpGridStepPrice + TRAIL_STEP_PRICE + trailSteps * TRAIL_STEP_PRICE));
   bool hasPosition = false;
   bool hasExistingStop = false;
   double strongestStop = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
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

   if((direction > 0 && currentPrice <= targetStop) ||
      (direction < 0 && currentPrice >= targetStop))
     {
      Print("StopGrid9: price crossed the active trailing stop; closing the remaining positions on that side.");
      ClosePositionsByDirection(direction);
      return;
     }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
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
void ClosePositionsByDirection(const int direction)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
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
void DeleteAllOwnPending()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol ||
         (ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
         continue;
      bool requestSent = trade.OrderDelete(ticket);
      if(!TradeResultAccepted(requestSent, true))
         Print("StopGrid9: failed to delete pending order #", ticket,
               " | retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
     }
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
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
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
   g_trailingDirection = 0;
   g_level3Evaluated = false;
   g_fixedCaseId = 0;
   g_fixedCaseDirection = 0;
   g_fixedCaseCloseRetryAfter = 0;
  }
//+------------------------------------------------------------------+
