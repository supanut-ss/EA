//+------------------------------------------------------------------+
//|                         XAUUSD_OneClick_StopGrid_EA.mq5           |
//|  Builds a two-sided pending-stop grid from one manual market     |
//|  entry. Portfolio-close rules are managed separately.            |
//+------------------------------------------------------------------+
#property copyright "Custom EA - One Click Stop Grid"
#property version   "1.33"
#property strict

#include <Trade/Trade.mqh>

CTrade trade;

#define MAX_PROCESSED_MANUAL_ORDERS 256
#define MAX_GRID_LEVELS_PER_SIDE    32
#define MAX_TRACKED_BASKETS         64

input group "=== Opening Grid ==="
input int      InpOrdersPerSide       = 5;       // Total levels per side; the manual entry counts as level 1 on its side
input int      InpPriceStepCents       = 300;     // Grid distance in price cents; 300 = 3.000 (4000 -> 4003)
input double   InpFixedLotUnit         = 0.01;    // Fixed lot unit for level >= 2; lot = (2*level-1) * this, e.g. 0.01 -> 0.03, 0.05, 0.07, 0.09, ...

input group "=== Optional SL / TP (price distance) ==="
input double   InpStopLossDistance     = 0.0;     // 0 = no SL; otherwise distance from each pending entry price
input double   InpTakeProfitDistance   = 0.0;     // 0 = no TP; otherwise distance from each pending entry price

input group "=== Basket Exit Rules ==="
input bool     InpUseFormulaClose       = true;    // Master switch for every basket exit rule
input bool     InpUseRecoveryFormula    = true;    // SAFETY BREAKER gate: winning side count >= 2 * losing count + 1
input int      InpTrailArmCents         = 300;     // TRAILING arm distance past the newest entry in price cents; 300 = 3.000. At one full grid step the armed stage cannot tighten mid-grid, since the next level fills first and moves the anchor
input double   InpProtectSpreadBuffer   = 0.050;   // Fixed cushion added to every trailing SL step, in price units
input int      InpWinnerCutCount        = 3;       // WINNER CUT: 0 = disabled; otherwise close the losing side (positions + pendings) once the winning side reaches this many positions
input int      InpMaxLosersBeforeCut    = 2;       // LOSER CUT: 0 = disabled; otherwise close everything once one side holds this many POSITIONS (P/L ignored) and the newest is passed by the distance below
input int      InpLoserCutMoveCents     = 250;     // LOSER CUT adverse move against the newest entry on that side, in price cents; 250 = 2.500

input group "=== Execution Safety ==="
input ulong    InpMagicNumber          = 20260904;
input int      InpSlippagePoints       = 100;
input double   InpMaxSpreadPrice       = 0.20;    // 0 = disabled; otherwise reject a grid when spread exceeds this price distance
input int      InpExpirationHours      = 0;       // 0 = good-till-cancelled
input int      InpMaxOwnPendingOrders  = 100;     // Safety cap for this EA, symbol, and magic number

ulong g_processedManualOrders[MAX_PROCESSED_MANUAL_ORDERS];
int   g_processedManualOrderCount = 0;
double g_tickSize = 0.0;
double g_volumeMin = 0.0;
double g_volumeMax = 0.0;
double g_volumeStep = 0.0;
string g_statePrefix = "";

struct CloseBasket
  {
   ulong rootOrderTicket;
   ulong manualPositionId;
   bool  protectionArmed;      // a trailing SL/TP line is live on this basket
   int   protectionDirection;
   double protectionPrice;
   bool  marketExitRequested;  // hard-exit latch: close every position at market
   datetime startTime;
   int    bankedLoserCount;     // k: losing-side positions WINNER CUT closed at cut time (0 = never cut)
   double winnerCutAnchorPrice; // the winning side's newest entry price at the moment WINNER CUT fired
   int    winnerCutDirection;   // the surviving side's direction once WINNER CUT fired (0 = never cut)
  };
CloseBasket g_closeBaskets[];

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpOrdersPerSide < 1 || InpOrdersPerSide > MAX_GRID_LEVELS_PER_SIDE ||
      InpPriceStepCents <= 0 || InpFixedLotUnit <= 0.0 ||
      InpMaxOwnPendingOrders < 1 ||
      InpStopLossDistance < 0.0 || InpTakeProfitDistance < 0.0 ||
      InpMaxSpreadPrice < 0.0 ||
      InpTrailArmCents <= 0 ||
      InpProtectSpreadBuffer < 0.0 ||
      InpWinnerCutCount < 0 ||
      InpMaxLosersBeforeCut < 0 ||
      (InpMaxLosersBeforeCut > 0 && InpLoserCutMoveCents <= 0) ||
      InpExpirationHours < 0)
     {
      Print("OneClickGrid: invalid input parameters");
      return(INIT_PARAMETERS_INCORRECT);
     }

   // The arm distance may equal one grid step but never exceed it. At
   // exactly one step the armed stage simply stops tightening mid-grid -
   // the next level fills first and moves the anchor - which leaves the
   // line a full step behind the market instead of jumping it up under the
   // newest entry. Past one step the arm could only ever fire on the last
   // level, which is not a distance anyone means to configure.
   if(InpTrailArmCents > InpPriceStepCents)
     {
      Print("OneClickGrid: InpTrailArmCents must not exceed InpPriceStepCents");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(!SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE, g_tickSize) || g_tickSize <= 0.0 ||
      !SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN, g_volumeMin) || g_volumeMin <= 0.0 ||
      !SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX, g_volumeMax) || g_volumeMax <= 0.0 ||
      !SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP, g_volumeStep) || g_volumeStep <= 0.0)
     {
      Print("OneClickGrid: cannot read symbol trading constraints for ", _Symbol);
      return(INIT_FAILED);
     }

   if(InpStopLossDistance <= 0.0)
      Print("OneClickGrid: WARNING - per-position Stop Loss is disabled and there is no automatic maximum-loss protection.");

   long marginMode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Print("OneClickGrid: a hedging account is required. Netting accounts merge positions and cannot preserve separate grid levels.");
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   g_statePrefix = BuildStatePrefix();
   LoadPersistentBaskets();
   RebuildCloseBaskets();
   CleanLegacyRiskState();
   SavePersistentState();

   Print("OneClickGrid: ready on ", _Symbol,
         " | opening levels/side=", InpOrdersPerSide,
         " | step=", DoubleToString(GridStepPrice(), _Digits),
         " (", InpPriceStepCents, " cents)",
         " | level 1 lot=manual entry lot on both sides, level>=2 lot=(2*level-1) x ",
         DoubleToString(InpFixedLotUnit, 8));
   Print("OneClickGrid: TRAILING base = protect at the previous position's entry + ",
         DoubleToString(InpProtectSpreadBuffer, _Digits),
         " as soon as a second position exists");
   Print("OneClickGrid: TRAILING arm = once price runs ",
         DoubleToString(TrailArmPrice(), _Digits),
         " past the newest entry, move the line to that entry + ",
         DoubleToString(InpProtectSpreadBuffer, _Digits),
         "; the line never moves back and pending orders stay alive");
   Print("OneClickGrid: WINNER CUT = ", InpWinnerCutCount > 0
         ? StringFormat("once the winning side reaches %d positions, close the losing side (positions + pendings) at market and leave the winner to the trailing line",
                        InpWinnerCutCount)
         : "disabled");
   Print("OneClickGrid: WINNER CUT BUDGET = after the cut, the surviving side may extend ",
         "k grid steps past its entry at cut time (k = losers banked at cut) before ",
         "the whole basket is closed at market as a backstop");
   if(InpUseRecoveryFormula)
      Print("OneClickGrid: SAFETY BREAKER = market-close the basket once k > ",
            (int)((InpOrdersPerSide - 1) / 2),
            " losing positions, since 2k+1 can no longer be satisfied within ",
            InpOrdersPerSide, " levels/side");
   Print("OneClickGrid: LOSER CUT = ", InpMaxLosersBeforeCut > 0
         ? StringFormat("close everything once one side holds %d positions and price runs %s against the newest of them",
                        InpMaxLosersBeforeCut, DoubleToString(LoserCutMovePrice(), _Digits))
         : "disabled");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0)
      return;

   ProcessManualEntryDeal(trans.deal);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   PruneClosedBaskets();
   if(InpUseFormulaClose)
      ManageFormulaClose();
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_statePrefix != "")
      SavePersistentState();
  }

//+------------------------------------------------------------------+
void ProcessManualEntryDeal(const ulong dealTicket)
  {
   if(!HistoryDealSelect(dealTicket))
      return;

   if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)
      return;
   if((ulong)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != 0)
      return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_IN && entry != DEAL_ENTRY_INOUT)
      return;

   ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
   if(dealType != DEAL_TYPE_BUY && dealType != DEAL_TYPE_SELL)
      return;

   ulong manualOrderTicket = (ulong)HistoryDealGetInteger(dealTicket, DEAL_ORDER);
   if(manualOrderTicket == 0 || WasManualOrderProcessed(manualOrderTicket))
      return;

   // Mark first so our own trade transactions cannot cause re-entry.
   RememberManualOrder(manualOrderTicket);

   double manualPrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
   double manualLot   = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
   ulong manualPositionId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   datetime manualTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
   int direction     = (dealType == DEAL_TYPE_BUY) ? 1 : -1;

   if(manualPrice <= 0.0 || manualLot <= 0.0)
     {
      Print("OneClickGrid: invalid manual deal data for #", dealTicket);
      return;
     }

   if(manualPositionId == 0 ||
      !AddCloseBasket(manualOrderTicket, manualPositionId, manualTime))
     {
      Print("OneClickGrid: cannot adopt manual order #", manualOrderTicket,
            " safely; it remains user-owned and no grid will be created");
      return;
     }
   SavePersistentState();

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
     {
      Print("OneClickGrid: no valid market quote; grid was not created for manual order #", manualOrderTicket);
      return;
     }

   double spread = ask - bid;
   if(InpMaxSpreadPrice > 0.0 && spread > InpMaxSpreadPrice)
     {
      Print("OneClickGrid: spread ", DoubleToString(spread, _Digits),
            " exceeds limit ", DoubleToString(InpMaxSpreadPrice, _Digits),
            "; grid was not created for manual order #", manualOrderTicket);
      return;
     }

   int requiredPending = (InpOrdersPerSide - 1) + InpOrdersPerSide;
   int availableSlots  = InpMaxOwnPendingOrders - CountOwnPendingOrders();
   if(availableSlots < requiredPending)
     {
      Print("OneClickGrid: safety cap allows only ", availableSlots,
            " new pending orders but this grid requires ", requiredPending,
            "; no partial grid was created");
      return;
     }

   int placed = 0;

   // The manual position is level 1: any lot the user opened with. Level 2
   // and beyond use a fixed lot progression independent of the manual lot
   // (odd multiples of InpFixedLotUnit: 3,5,7,9,... ).
   for(int level=2; level<=InpOrdersPerSide; level++)
     {
      double price = manualPrice + direction * (level - 1) * GridStepPrice();
      double lot   = LotForLevel(level, manualLot);
      if(PlaceStopOrder(direction, level, manualOrderTicket, price, lot))
         placed++;
     }

   // The opposite side's first pending order matches the manual entry's
   // lot exactly (level 1), then follows the same fixed lot progression.
   int oppositeDirection = -direction;
   for(int level=1; level<=InpOrdersPerSide; level++)
     {
      double price = manualPrice + oppositeDirection * level * GridStepPrice();
      double lot   = LotForLevel(level, manualLot);
      if(PlaceStopOrder(oppositeDirection, level, manualOrderTicket, price, lot))
         placed++;
     }

   Print("OneClickGrid: manual order #", manualOrderTicket,
         " created ", placed, "/", requiredPending, " opening pending orders");
  }

//+------------------------------------------------------------------+
double LotForLevel(const int level, const double manualLot)
  {
   // Level 1 (either side) always mirrors the manual entry's own lot.
   // Level 2+ is a fixed lot progression, independent of the manual lot:
   // odd multiples of InpFixedLotUnit -> 3,5,7,9,11,13,15,17,...
   if(level <= 1)
      return(manualLot);
   return((2 * level - 1) * InpFixedLotUnit);
  }

//+------------------------------------------------------------------+
double GridStepPrice()
  {
   // Grid units are price cents, deliberately independent of broker
   // _Point. Thus 200 always means a 2.000 XAUUSD price distance.
   return(InpPriceStepCents / 100.0);
  }

//+------------------------------------------------------------------+
double TrailArmPrice()
  {
   // Exit distances share the grid's price-cent unit and deliberately ignore
   // broker _Point: 300 always means 4000 -> 4003.
   return(InpTrailArmCents / 100.0);
  }

//+------------------------------------------------------------------+
double LoserCutMovePrice()
  {
   return(InpLoserCutMoveCents / 100.0);
  }

//+------------------------------------------------------------------+
bool PlaceStopOrder(const int direction,
                    const int level,
                    const ulong manualOrderTicket,
                    const double rawPrice,
                    const double requestedLot)
  {
   double lot = NormalizeVolumeDown(requestedLot);
   if(lot <= 0.0)
     {
      Print("OneClickGrid: level ", level, " skipped; requested lot ",
            DoubleToString(requestedLot, 8), " is outside broker limits [",
            DoubleToString(g_volumeMin, 8), ", ", DoubleToString(g_volumeMax, 8), "]");
      return(false);
     }

   double entryPrice = NormalizePriceForDirection(rawPrice, direction);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minDistance = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   bool entryAllowed = (direction == 1)
      ? (entryPrice - ask >= minDistance)
      : (bid - entryPrice >= minDistance);
   if(!entryAllowed)
     {
      Print("OneClickGrid: level ", level, " at ", DoubleToString(entryPrice, _Digits),
            " skipped; pending-stop price is too close to or behind the current market");
      return(false);
     }

   double sl = BuildStopLoss(entryPrice, direction);
   double tp = BuildTakeProfit(entryPrice, direction);
   if(!StopsAreValid(entryPrice, sl, tp, minDistance, direction))
     {
      Print("OneClickGrid: level ", level, " skipped; SL/TP violates the broker minimum stop distance");
      return(false);
     }

   ENUM_ORDER_TYPE_TIME timeType = ORDER_TIME_GTC;
   datetime expiration = 0;
   if(InpExpirationHours > 0)
     {
      timeType = ORDER_TIME_SPECIFIED;
      expiration = TimeCurrent() + InpExpirationHours * 3600;
     }

   string side = (direction == 1) ? "BS" : "SS";
   string comment = BasketTag(manualOrderTicket);

   ResetLastError();
   bool sent = (direction == 1)
      ? trade.BuyStop(lot, entryPrice, _Symbol, sl, tp, timeType, expiration, comment)
      : trade.SellStop(lot, entryPrice, _Symbol, sl, tp, timeType, expiration, comment);

   uint retcode = trade.ResultRetcode();
   bool accepted = sent &&
      (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED || retcode == TRADE_RETCODE_DONE_PARTIAL);

   if(!accepted)
     {
      Print("OneClickGrid: ", side, " level ", level, " failed | lot=",
            DoubleToString(lot, VolumeDigits()), " price=", DoubleToString(entryPrice, _Digits),
            " | retcode=", retcode, " ", trade.ResultRetcodeDescription(),
            " | lastError=", GetLastError());
      return(false);
     }

   Print("OneClickGrid: placed ", side, " level ", level,
         " | ticket=", trade.ResultOrder(),
         " lot=", DoubleToString(lot, VolumeDigits()),
         " price=", DoubleToString(entryPrice, _Digits));
   return(true);
  }

//+------------------------------------------------------------------+
double BuildStopLoss(const double entryPrice, const int direction)
  {
   if(InpStopLossDistance <= 0.0)
      return(0.0);

   double raw = entryPrice - direction * InpStopLossDistance;
   return(NormalizePriceForDirection(raw, -direction));
  }

//+------------------------------------------------------------------+
double BuildTakeProfit(const double entryPrice, const int direction)
  {
   if(InpTakeProfitDistance <= 0.0)
      return(0.0);

   double raw = entryPrice + direction * InpTakeProfitDistance;
   return(NormalizePriceForDirection(raw, direction));
  }

//+------------------------------------------------------------------+
bool StopsAreValid(const double entryPrice,
                   const double sl,
                   const double tp,
                   const double minDistance,
                   const int direction)
  {
   if(sl > 0.0)
     {
      double slDistance = (direction == 1) ? entryPrice - sl : sl - entryPrice;
      if(slDistance < minDistance || slDistance <= 0.0)
         return(false);
     }

   if(tp > 0.0)
     {
      double tpDistance = (direction == 1) ? tp - entryPrice : entryPrice - tp;
      if(tpDistance < minDistance || tpDistance <= 0.0)
         return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
double NormalizePriceForDirection(const double price, const int direction)
  {
   double ticks = price / g_tickSize;
   double normalized = (direction == 1)
      ? MathCeil(ticks - 1e-10) * g_tickSize
      : MathFloor(ticks + 1e-10) * g_tickSize;
   return(NormalizeDouble(normalized, _Digits));
  }

//+------------------------------------------------------------------+
double NormalizeVolumeDown(const double requestedLot)
  {
   if(!MathIsValidNumber(requestedLot) || requestedLot < g_volumeMin || requestedLot > g_volumeMax)
      return(0.0);

   double steps = MathFloor((requestedLot + 1e-12) / g_volumeStep);
   double lot = steps * g_volumeStep;
   if(lot < g_volumeMin || lot > g_volumeMax)
      return(0.0);
   return(NormalizeDouble(lot, VolumeDigits()));
  }

//+------------------------------------------------------------------+
int VolumeDigits()
  {
   int digits = 0;
   double step = g_volumeStep;
   while(digits < 8 && MathAbs(step - MathRound(step)) > 1e-9)
     {
      step *= 10.0;
      digits++;
     }
   return(digits);
  }

//+------------------------------------------------------------------+
int CountOwnPendingOrders()
  {
   int count = 0;
   for(int i=OrdersTotal()-1; i>=0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
         continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP ||
         type == ORDER_TYPE_BUY_STOP_LIMIT || type == ORDER_TYPE_SELL_STOP_LIMIT)
         count++;
     }
   return(count);
  }

//+------------------------------------------------------------------+
bool WasManualOrderProcessed(const ulong orderTicket)
  {
   for(int i=0; i<g_processedManualOrderCount; i++)
      if(g_processedManualOrders[i] == orderTicket)
         return(true);
   return(false);
  }

//+------------------------------------------------------------------+
void RememberManualOrder(const ulong orderTicket)
  {
   if(g_processedManualOrderCount < MAX_PROCESSED_MANUAL_ORDERS)
     {
      g_processedManualOrders[g_processedManualOrderCount] = orderTicket;
      g_processedManualOrderCount++;
      return;
     }

   for(int i=1; i<MAX_PROCESSED_MANUAL_ORDERS; i++)
      g_processedManualOrders[i-1] = g_processedManualOrders[i];
   g_processedManualOrders[MAX_PROCESSED_MANUAL_ORDERS-1] = orderTicket;
  }

//+------------------------------------------------------------------+
string BasketTag(const ulong rootOrderTicket)
  {
   return(StringFormat("G#%I64u", rootOrderTicket));
  }

//+------------------------------------------------------------------+
bool CommentMatchesBasket(const string comment, const ulong rootOrderTicket)
  {
   return(comment == BasketTag(rootOrderTicket));
  }

//+------------------------------------------------------------------+
ulong RootTicketFromComment(const string comment)
  {
   if(StringLen(comment) <= 2 || StringSubstr(comment, 0, 2) != "G#")
      return(0);

   ulong parsed = 0;
   ulong maxValue = ~((ulong)0);
   for(int i=2; i<StringLen(comment); i++)
     {
      ushort ch = StringGetCharacter(comment, i);
      if(ch < '0' || ch > '9')
         return(0);
      ulong digit = (ulong)(ch - '0');
      if(parsed > (maxValue - digit) / 10)
         return(0);
      parsed = parsed * 10 + digit;
     }
   return(parsed);
  }

//+------------------------------------------------------------------+
int FindCloseBasket(const ulong rootOrderTicket)
  {
   for(int i=0; i<ArraySize(g_closeBaskets); i++)
      if(g_closeBaskets[i].rootOrderTicket == rootOrderTicket)
         return(i);
   return(-1);
  }

//+------------------------------------------------------------------+
bool AddCloseBasket(const ulong rootOrderTicket,
                    const ulong manualPositionId,
                    const datetime startTime)
  {
   int index = FindCloseBasket(rootOrderTicket);
   if(index >= 0)
     {
      if(g_closeBaskets[index].manualPositionId == 0)
         g_closeBaskets[index].manualPositionId = manualPositionId;
      if(g_closeBaskets[index].startTime == 0)
         g_closeBaskets[index].startTime = startTime;
      return(true);
     }

   int size = ArraySize(g_closeBaskets);
   if(size >= MAX_TRACKED_BASKETS)
     {
      Print("OneClickGrid: managed basket capacity reached; root #", rootOrderTicket,
            " was not adopted");
      return(false);
     }
   ArrayResize(g_closeBaskets, size + 1);
   g_closeBaskets[size].rootOrderTicket = rootOrderTicket;
   g_closeBaskets[size].manualPositionId = manualPositionId;
   g_closeBaskets[size].protectionArmed = false;
   g_closeBaskets[size].protectionDirection = 0;
   g_closeBaskets[size].protectionPrice = 0.0;
   g_closeBaskets[size].marketExitRequested = false;
   g_closeBaskets[size].startTime = startTime;
   g_closeBaskets[size].bankedLoserCount = 0;
   g_closeBaskets[size].winnerCutAnchorPrice = 0.0;
   g_closeBaskets[size].winnerCutDirection = 0;
   return(true);
  }

//+------------------------------------------------------------------+
ulong ManualPositionIdFromHistory(const ulong rootOrderTicket)
  {
   if(!HistoryOrderSelect(rootOrderTicket))
      return(0);
   return((ulong)HistoryOrderGetInteger(rootOrderTicket, ORDER_POSITION_ID));
  }

//+------------------------------------------------------------------+
void RebuildCloseBaskets()
  {
   for(int i=OrdersTotal()-1; i>=0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol ||
         (ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
         continue;

      ulong root = RootTicketFromComment(OrderGetString(ORDER_COMMENT));
      if(root > 0)
        {
         ulong manualId = ManualPositionIdFromHistory(root);
         datetime startTime = (datetime)HistoryOrderGetInteger(root, ORDER_TIME_SETUP);
         bool discovered = (FindCloseBasket(root) < 0);
         AddCloseBasket(root, manualId, startTime);
         if(discovered)
            Print("OneClickGrid: discovered basket #", root,
                  " from tagged terminal state");
        }
     }

   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      ulong root = RootTicketFromComment(PositionGetString(POSITION_COMMENT));
      if(root > 0)
        {
         ulong manualId = ManualPositionIdFromHistory(root);
         datetime startTime = (datetime)HistoryOrderGetInteger(root, ORDER_TIME_SETUP);
         bool discovered = (FindCloseBasket(root) < 0);
         AddCloseBasket(root, manualId, startTime);
         if(discovered)
            Print("OneClickGrid: discovered basket #", root,
                  " from tagged terminal state");
        }
     }

   for(int i=0; i<ArraySize(g_closeBaskets); i++)
      RememberManualOrder(g_closeBaskets[i].rootOrderTicket);

   if(ArraySize(g_closeBaskets) > 0)
      Print("OneClickGrid: restored ", ArraySize(g_closeBaskets), " managed basket(s)");
  }

//+------------------------------------------------------------------+
bool PositionBelongsToBasket(const CloseBasket &basket)
  {
   if(PositionGetString(POSITION_SYMBOL) != _Symbol)
      return(false);

   ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);
   if(magic == InpMagicNumber)
      return(CommentMatchesBasket(PositionGetString(POSITION_COMMENT), basket.rootOrderTicket));

   if(magic == 0 && basket.manualPositionId > 0)
      return((ulong)PositionGetInteger(POSITION_IDENTIFIER) == basket.manualPositionId);

   return(false);
  }

//+------------------------------------------------------------------+
bool OrderBelongsToBasket(const CloseBasket &basket)
  {
   return(OrderGetString(ORDER_SYMBOL) == _Symbol &&
          (ulong)OrderGetInteger(ORDER_MAGIC) == InpMagicNumber &&
          CommentMatchesBasket(OrderGetString(ORDER_COMMENT), basket.rootOrderTicket));
  }

//+------------------------------------------------------------------+
uint StateScopeHash()
  {
   string scope = StringFormat("%I64u|%I64u|%s|%s",
                               (ulong)AccountInfoInteger(ACCOUNT_LOGIN),
                               InpMagicNumber, _Symbol,
                               AccountInfoString(ACCOUNT_SERVER));
   uint hash = 2166136261;
   for(int i=0; i<StringLen(scope); i++)
     {
      hash ^= (uint)StringGetCharacter(scope, i);
      hash *= 16777619;
     }
   return(hash);
  }

//+------------------------------------------------------------------+
string BuildStatePrefix()
  {
   return("OCSG." + StringFormat("%08X", StateScopeHash()));
  }

//+------------------------------------------------------------------+
string BasketStateKey(const int index, const string field)
  {
   return(g_statePrefix + ".B" + IntegerToString(index) + field);
  }

//+------------------------------------------------------------------+
bool ReadStateValue(const string key, double &value)
  {
   return(GlobalVariableGet(key, value));
  }

//+------------------------------------------------------------------+
void WriteStateValue(const string key, const double value)
  {
   if(GlobalVariableSet(key, value) == 0)
      Print("OneClickGrid: persistent state write failed for ", key,
            " | error=", GetLastError());
  }

//+------------------------------------------------------------------+
void WriteStateUlong(const string keyBase, const ulong value)
  {
   uint low = (uint)(value & 0xFFFFFFFF);
   uint high = (uint)(value >> 32);
   WriteStateValue(keyBase + "H", (double)high);
   WriteStateValue(keyBase + "L", (double)low);
  }

//+------------------------------------------------------------------+
bool ReadStateUlong(const string keyBase, ulong &value)
  {
   double highValue, lowValue;
   if(!ReadStateValue(keyBase + "H", highValue) ||
      !ReadStateValue(keyBase + "L", lowValue))
      return(false);

   uint high = (uint)MathRound(highValue);
   uint low = (uint)MathRound(lowValue);
   value = ((ulong)high << 32) | (ulong)low;
   return(true);
  }

//+------------------------------------------------------------------+
void DeleteBasketStateSlot(const int index)
  {
   string fields[] = {"RH","RL","MH","ML","T","E","L","Q","A","D","P","X","K","W","G"};
   for(int i=0; i<ArraySize(fields); i++)
      GlobalVariableDel(BasketStateKey(index, fields[i]));
  }

//+------------------------------------------------------------------+
void SavePersistentState()
  {
   if(g_statePrefix == "")
      return;

   double oldBasketCountValue = 0.0;
   int oldBasketCount = ReadStateValue(g_statePrefix + ".BC", oldBasketCountValue)
      ? (int)MathRound(oldBasketCountValue) : 0;
   int basketCount = (int)MathMin(ArraySize(g_closeBaskets), MAX_TRACKED_BASKETS);

   for(int i=0; i<basketCount; i++)
     {
      WriteStateUlong(BasketStateKey(i, "R"), g_closeBaskets[i].rootOrderTicket);
      WriteStateUlong(BasketStateKey(i, "M"), g_closeBaskets[i].manualPositionId);
      WriteStateValue(BasketStateKey(i, "T"), (double)g_closeBaskets[i].startTime);
      WriteStateValue(BasketStateKey(i, "A"), g_closeBaskets[i].protectionArmed ? 1.0 : 0.0);
      WriteStateValue(BasketStateKey(i, "D"), (double)g_closeBaskets[i].protectionDirection);
      WriteStateValue(BasketStateKey(i, "P"), g_closeBaskets[i].protectionPrice);
      WriteStateValue(BasketStateKey(i, "X"), g_closeBaskets[i].marketExitRequested ? 1.0 : 0.0);
      WriteStateValue(BasketStateKey(i, "K"), (double)g_closeBaskets[i].bankedLoserCount);
      WriteStateValue(BasketStateKey(i, "W"), g_closeBaskets[i].winnerCutAnchorPrice);
      WriteStateValue(BasketStateKey(i, "G"), (double)g_closeBaskets[i].winnerCutDirection);
     }
   for(int i=basketCount; i<oldBasketCount && i<MAX_TRACKED_BASKETS; i++)
      DeleteBasketStateSlot(i);

   WriteStateValue(g_statePrefix + ".BC", (double)basketCount);
   WriteStateValue(g_statePrefix + ".V", 5.0);
   GlobalVariablesFlush();
  }

//+------------------------------------------------------------------+
void LoadPersistentBaskets()
  {
   ArrayResize(g_closeBaskets, 0);
   double versionValue, countValue;
   if(!ReadStateValue(g_statePrefix + ".V", versionValue) ||
      !ReadStateValue(g_statePrefix + ".BC", countValue))
      return;

   int stateVersion = (int)MathRound(versionValue);
   if(stateVersion < 1 || stateVersion > 5)
      return;

   int count = (int)MathRound(countValue);
   if(count < 0 || count > MAX_TRACKED_BASKETS)
     {
      Print("OneClickGrid: saved basket state count is invalid; terminal state discovery will be used");
      return;
     }

   for(int i=0; i<count; i++)
     {
      ulong root, manualId;
      double timeValue;
      if(!ReadStateUlong(BasketStateKey(i, "R"), root) || root == 0 ||
         !ReadStateUlong(BasketStateKey(i, "M"), manualId) ||
         !ReadStateValue(BasketStateKey(i, "T"), timeValue))
        {
         Print("OneClickGrid: skipped incomplete saved basket slot ", i);
         continue;
        }

      if(!AddCloseBasket(root, manualId, (datetime)MathRound(timeValue)))
         break;

      int index = FindCloseBasket(root);
      if(stateVersion < 3)
        {
         double legacyLiquidation = 0.0;
         if(ReadStateValue(BasketStateKey(i, "Q"), legacyLiquidation) &&
            legacyLiquidation > 0.5)
            Print("OneClickGrid: ignored legacy loss-liquidation state #", root,
                  "; v1.21 has no automatic loss closure");
        }

      double armedValue, directionValue, priceValue;
      bool protectionComplete = (index >= 0 &&
         ReadStateValue(BasketStateKey(i, "A"), armedValue) &&
         ReadStateValue(BasketStateKey(i, "D"), directionValue) &&
         ReadStateValue(BasketStateKey(i, "P"), priceValue));
      int savedDirection = protectionComplete ? (int)MathRound(directionValue) : 0;
      if(protectionComplete && armedValue > 0.5 &&
         (savedDirection == 1 || savedDirection == -1) && priceValue > 0.0)
        {
         g_closeBaskets[index].protectionArmed = true;
         g_closeBaskets[index].protectionDirection = savedDirection;
         g_closeBaskets[index].protectionPrice = priceValue;
         Print("OneClickGrid: restored formula protection latch #", root,
               " | direction=", savedDirection,
               " | price=", DoubleToString(priceValue, _Digits));
        }
      else if(protectionComplete && armedValue > 0.5)
         Print("OneClickGrid: discarded incomplete formula protection state #", root);

      double marketExitValue = 0.0;
      if(index >= 0 && stateVersion >= 4 &&
         ReadStateValue(BasketStateKey(i, "X"), marketExitValue) && marketExitValue > 0.5)
        {
         g_closeBaskets[index].marketExitRequested = true;
         Print("OneClickGrid: restored market-exit latch #", root,
               "; the basket is closed on the next tick");
        }

      double bankedValue = 0.0, anchorValue = 0.0, cutDirectionValue = 0.0;
      bool cutStateComplete = (index >= 0 && stateVersion >= 5 &&
         ReadStateValue(BasketStateKey(i, "K"), bankedValue) &&
         ReadStateValue(BasketStateKey(i, "W"), anchorValue) &&
         ReadStateValue(BasketStateKey(i, "G"), cutDirectionValue));
      int savedCutDirection = cutStateComplete ? (int)MathRound(cutDirectionValue) : 0;
      if(cutStateComplete && bankedValue > 0.5 && anchorValue > 0.0 &&
         (savedCutDirection == 1 || savedCutDirection == -1))
        {
         g_closeBaskets[index].bankedLoserCount = (int)MathRound(bankedValue);
         g_closeBaskets[index].winnerCutAnchorPrice = anchorValue;
         g_closeBaskets[index].winnerCutDirection = savedCutDirection;
         Print("OneClickGrid: restored WINNER CUT budget #", root,
               " | k=", g_closeBaskets[index].bankedLoserCount,
               " | anchor=", DoubleToString(anchorValue, _Digits),
               " | direction=", savedCutDirection);
        }
      else if(cutStateComplete && bankedValue > 0.5)
         Print("OneClickGrid: discarded incomplete WINNER CUT budget state #", root,
               "; the surviving side runs without its budget ceiling");
     }
  }

//+------------------------------------------------------------------+
void CleanLegacyRiskState()
  {
   for(int i=0; i<MAX_TRACKED_BASKETS; i++)
     {
      GlobalVariableDel(BasketStateKey(i, "E"));
      GlobalVariableDel(BasketStateKey(i, "L"));
      GlobalVariableDel(BasketStateKey(i, "Q"));
     }

   double manualCountValue = 0.0;
   int manualCount = ReadStateValue(g_statePrefix + ".MC", manualCountValue)
      ? (int)MathMin(MathMax(MathRound(manualCountValue), 0.0), 256.0) : 0;
   for(int i=0; i<manualCount; i++)
     {
      GlobalVariableDel(g_statePrefix + ".M" + IntegerToString(i) + "H");
      GlobalVariableDel(g_statePrefix + ".M" + IntegerToString(i) + "L");
     }

   string dailyFields[] = {"DD","DT","DO","DW","DXH","DXL","DE","DF","DL","DQ","MC"};
   for(int i=0; i<ArraySize(dailyFields); i++)
      GlobalVariableDel(g_statePrefix + "." + dailyFields[i]);
  }

//+------------------------------------------------------------------+
void PruneClosedBaskets()
  {
   bool changed = false;
   for(int i=ArraySize(g_closeBaskets)-1; i>=0; i--)
      if(!BasketHasOpenState(g_closeBaskets[i]))
        {
         ArrayRemove(g_closeBaskets, i, 1);
         changed = true;
        }
   if(changed)
      SavePersistentState();
  }

//+------------------------------------------------------------------+
void GetBasketStats(const CloseBasket &basket,
                    int &buyCount,
                    int &sellCount,
                    double &buyProfit,
                    double &sellProfit,
                    double &netProfit,
                    int &buyLosingCount,
                    int &sellLosingCount)
  {
   buyCount = 0;
   sellCount = 0;
   buyProfit = 0.0;
   sellProfit = 0.0;
   netProfit = 0.0;
   buyLosingCount = 0;
   sellLosingCount = 0;

   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionBelongsToBasket(basket))
         continue;

      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(type == POSITION_TYPE_BUY)
        {
         buyCount++;
         buyProfit += profit;
         if(profit < 0.0)
            buyLosingCount++;
        }
      else if(type == POSITION_TYPE_SELL)
        {
         sellCount++;
         sellProfit += profit;
         if(profit < 0.0)
            sellLosingCount++;
        }

      netProfit += profit;
     }
  }

//+------------------------------------------------------------------+
bool BasketHasPendingOrders(const CloseBasket &basket)
  {
   for(int i=OrdersTotal()-1; i>=0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderBelongsToBasket(basket))
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
bool BasketHasOpenState(const CloseBasket &basket)
  {
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionBelongsToBasket(basket))
         return(true);
     }

   return(BasketHasPendingOrders(basket));
  }

//+------------------------------------------------------------------+
bool SideHasOpenState(const CloseBasket &basket, const int direction)
  {
   ENUM_POSITION_TYPE posType = (direction == 1) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionBelongsToBasket(basket))
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType)
         return(true);
     }

   for(int i=OrdersTotal()-1; i>=0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderBelongsToBasket(basket))
         continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      bool isBuySide = (type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY_STOP_LIMIT);
      bool isSellSide = (type == ORDER_TYPE_SELL_STOP || type == ORDER_TYPE_SELL_STOP_LIMIT);
      if((direction == 1) ? isBuySide : isSellSide)
         return(true);
     }

   return(false);
  }

//+------------------------------------------------------------------+
bool IsBetterLine(const double candidate, const double current, const int direction)
  {
   // "Better" means further from the market in the protective direction.
   return((direction == 1) ? (candidate > current) : (candidate < current));
  }

//+------------------------------------------------------------------+
bool GetTrailingAnchors(const CloseBasket &basket,
                        const int direction,
                        double &newestEntry,
                        double &previousEntry)
  {
   long  newestTimeMsc = -1, previousTimeMsc = -1;
   ulong newestTicket = 0, previousTicket = 0;
   newestEntry = 0.0;
   previousEntry = 0.0;

   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionBelongsToBasket(basket))
         continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if((direction == 1 && type != POSITION_TYPE_BUY) ||
         (direction == -1 && type != POSITION_TYPE_SELL))
         continue;

      long timeMsc = PositionGetInteger(POSITION_TIME_MSC);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);

      if(timeMsc > newestTimeMsc || (timeMsc == newestTimeMsc && ticket > newestTicket))
        {
         previousTimeMsc = newestTimeMsc;
         previousTicket = newestTicket;
         previousEntry = newestEntry;
         newestTimeMsc = timeMsc;
         newestTicket = ticket;
         newestEntry = openPrice;
        }
      else if(timeMsc > previousTimeMsc || (timeMsc == previousTimeMsc && ticket > previousTicket))
        {
         previousTimeMsc = timeMsc;
         previousTicket = ticket;
         previousEntry = openPrice;
        }
     }

   return(newestEntry > 0.0);
  }

//+------------------------------------------------------------------+
void DeleteBasketPendingOrders(const CloseBasket &basket)
  {
   for(int i=OrdersTotal()-1; i>=0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderBelongsToBasket(basket))
         continue;

      if(!trade.OrderDelete(ticket) || trade.ResultRetcode() != TRADE_RETCODE_DONE)
         Print("OneClickGrid: pending delete failed #", ticket, " | ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
void CloseBasketAtMarket(const CloseBasket &basket)
  {
   // Pending orders go first so a fill cannot re-enter the basket between
   // the individual position closes.
   DeleteBasketPendingOrders(basket);

   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionBelongsToBasket(basket))
         continue;

      if(!trade.PositionClose(ticket, InpSlippagePoints))
         Print("OneClickGrid: market close failed #", ticket, " | ", trade.ResultRetcodeDescription(),
               " | it is retried on the following ticks");
     }
  }

//+------------------------------------------------------------------+
// Closes only one side of a basket - its pending orders and its open
// positions - leaving the other side (and its own pendings) untouched.
// Used by WINNER CUT to bank the losing side while the winner keeps running.
void CloseSideAtMarket(const CloseBasket &basket, const int direction)
  {
   bool wantBuy = (direction == 1);

   // Pending orders go first so a fill cannot re-enter this side between
   // the individual position closes.
   for(int i=OrdersTotal()-1; i>=0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderBelongsToBasket(basket))
         continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      bool isBuySide = (type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY_STOP_LIMIT);
      bool isSellSide = (type == ORDER_TYPE_SELL_STOP || type == ORDER_TYPE_SELL_STOP_LIMIT);
      if(wantBuy && !isBuySide)
         continue;
      if(!wantBuy && !isSellSide)
         continue;

      if(!trade.OrderDelete(ticket) || trade.ResultRetcode() != TRADE_RETCODE_DONE)
         Print("OneClickGrid: pending delete failed #", ticket, " | ", trade.ResultRetcodeDescription());
     }

   ENUM_POSITION_TYPE posType = wantBuy ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionBelongsToBasket(basket))
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != posType)
         continue;

      if(!trade.PositionClose(ticket, InpSlippagePoints))
         Print("OneClickGrid: market close failed #", ticket, " | ", trade.ResultRetcodeDescription(),
               " | it is retried on the following ticks");
     }
  }

//+------------------------------------------------------------------+
void ApplyBasketProtection(const CloseBasket &basket)
  {
   // Pending orders are deliberately left alive: the protective line trails,
   // so the grid must stay able to extend while the basket is protected.
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double stopsDistance = MathMax(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                                  SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL)) * _Point;

   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionBelongsToBasket(basket))
         continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);
      double newSL = curSL;
      double newTP = curTP;
      bool priceAllowed = false;

      if(basket.protectionDirection == 1)
        {
         if(type == POSITION_TYPE_BUY)
           {
            newSL = (curSL > 0.0) ? MathMax(curSL, basket.protectionPrice) : basket.protectionPrice;
            priceAllowed = (bid - newSL > stopsDistance);
           }
         else
           {
            // A common exit below an up-trending market is a TP for Sell
            // positions; an SL cannot legally be placed below current Ask.
            newTP = basket.protectionPrice;
            priceAllowed = (ask - newTP > stopsDistance);
           }
        }
      else
        {
         if(type == POSITION_TYPE_SELL)
           {
            newSL = (curSL > 0.0) ? MathMin(curSL, basket.protectionPrice) : basket.protectionPrice;
            priceAllowed = (newSL - ask > stopsDistance);
           }
         else
           {
            // A common exit above a down-trending market is a TP for Buy
            // positions; an SL cannot legally be placed above current Bid.
            newTP = basket.protectionPrice;
            priceAllowed = (newTP - bid > stopsDistance);
           }
        }

      if(!priceAllowed)
        {
         Print("OneClickGrid: protection price too close for #", ticket,
               " | target=", DoubleToString(basket.protectionPrice, _Digits));
         continue;
        }

      if(MathAbs(newSL - curSL) < g_tickSize / 2.0 &&
         MathAbs(newTP - curTP) < g_tickSize / 2.0)
         continue;

      bool sent = trade.PositionModify(ticket, newSL, newTP);
      uint retcode = trade.ResultRetcode();
      if(!sent || (retcode != TRADE_RETCODE_DONE && retcode != TRADE_RETCODE_DONE_PARTIAL))
         Print("OneClickGrid: protection modify failed #", ticket, " | ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Ladder trailing protection, re-evaluated at every tick and every  |
//| new fill alike.                                                    |
//|  Base   - the previous position's entry + InpProtectSpreadBuffer, |
//|           usable the moment a second position exists on the       |
//|           winning side. It costs the newest position one grid     |
//|           step, but needs no price movement at all, so the basket |
//|           is never unprotected.                                   |
//|  Armed  - once price has actually travelled TrailArmPrice() past  |
//|           the newest entry, the line ratchets forward to that     |
//|           newest entry + InpProtectSpreadBuffer - a small cushion, |
//|           not the whole arm distance, so a real trend keeps room  |
//|           to run instead of being trailed tightly. At the default |
//|           arm of one full grid step this stage stays dormant      |
//|           mid-grid: the next level fills before price can travel  |
//|           that far, which moves the anchor out from under it. It  |
//|           therefore only bites on the last level, where no        |
//|           further pending order is left to fill.                  |
//| The better of the two wins, and the line only ever moves away     |
//| from the market so protection can never be given back.            |
//+------------------------------------------------------------------+
void UpdateTrailingProtection(CloseBasket &basket, const int direction)
  {
   double newestEntry, previousEntry;
   if(!GetTrailingAnchors(basket, direction, newestEntry, previousEntry))
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return;

   // A single position is not a grid yet. Trailing it would park the line
   // behind the manual entry and close the basket for a token profit before
   // the next level can even fill, so both stages wait until this side
   // actually holds two positions.
   if(previousEntry <= 0.0)
      return;

   double candidate = previousEntry + direction * InpProtectSpreadBuffer;
   string layer = "base - previous entry + spread buffer";

   double armTrigger = newestEntry + direction * TrailArmPrice();
   bool armed = (direction == 1) ? (bid > armTrigger) : (ask < armTrigger);
   double armedCandidate = newestEntry + direction * InpProtectSpreadBuffer;
   if(armed && IsBetterLine(armedCandidate, candidate, direction))
     {
      candidate = armedCandidate;
      layer = "armed - newest entry + spread buffer";
     }

   double line = NormalizePriceForDirection(candidate, -direction);

   if(basket.protectionArmed && basket.protectionDirection == direction &&
      !IsBetterLine(line, basket.protectionPrice, direction))
      return;

   bool firstArm = !basket.protectionArmed;
   basket.protectionArmed = true;
   basket.protectionDirection = direction;
   basket.protectionPrice = line;

   // Only the initial arm is flushed to disk. Trailing writes every tick
   // would flush constantly, and the exact line does not need to survive a
   // restart: it is re-derived from the open positions, while the
   // broker-side SL is ratcheted by MathMax/MathMin and cannot regress.
   if(firstArm)
      SavePersistentState();

   Print("OneClickGrid: trailing line #", basket.rootOrderTicket,
         " -> ", DoubleToString(line, _Digits),
         " | ", layer,
         " | direction=", direction,
         " | newest entry=", DoubleToString(newestEntry, _Digits));
  }

//+------------------------------------------------------------------+
void ManageFormulaClose()
  {
   for(int b=ArraySize(g_closeBaskets)-1; b>=0; b--)
     {
      // The market-exit latch is retried every tick until the basket is
      // empty. The protective line is deliberately NOT a latch: it has to
      // keep trailing, so it falls through to the rules below.
      if(g_closeBaskets[b].marketExitRequested)
        {
         CloseBasketAtMarket(g_closeBaskets[b]);

         if(!BasketHasOpenState(g_closeBaskets[b]))
           {
            ArrayRemove(g_closeBaskets, b, 1);
            SavePersistentState();
           }
         continue;
        }

      int buyCount, sellCount, buyLosingCount, sellLosingCount;
      double buyProfit, sellProfit, netProfit;
      GetBasketStats(g_closeBaskets[b], buyCount, sellCount, buyProfit, sellProfit, netProfit,
                     buyLosingCount, sellLosingCount);

      if(buyCount + sellCount == 0)
        {
         // No positions left - the protective line took them out, or the
         // user closed them by hand. Either way the grid has nothing left
         // to manage, so retire the leftover pendings rather than leave
         // live stop orders that would silently re-enter later.
         if(BasketHasPendingOrders(g_closeBaskets[b]))
           {
            Print("OneClickGrid: basket #", g_closeBaskets[b].rootOrderTicket,
                  " holds no positions; deleting its remaining pending orders");
            DeleteBasketPendingOrders(g_closeBaskets[b]);
           }
         continue;
        }

      // LOSER CUT - hard loss stop, evaluated before every other rule and
      // independently per side. The count is of POSITIONS open on a side,
      // regardless of their P/L, so the distance is what decides: once a
      // side holds InpMaxLosersBeforeCut positions and price has run
      // LoserCutMovePrice() against the newest of them, the whole basket is
      // closed at market. Counting only losing positions would push the
      // real trigger out to a full grid step, since a side's second
      // position cannot be underwater until price is already that far
      // against it, and the configured distance would never bind. The
      // distance stays below one grid step so the exit lands before the
      // basket's next level can fill. Both sides are checked separately:
      // in a developed basket both hold positions, so stopping at the
      // first side over the count would leave the other one unexamined.
      if(InpMaxLosersBeforeCut > 0)
        {
         double cutBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double cutAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

         for(int d=0; cutBid > 0.0 && cutAsk > 0.0 && d<2; d++)
           {
            int cutDirection = (d == 0) ? 1 : -1;
            int sideCount = (cutDirection == 1) ? buyCount : sellCount;
            if(sideCount < InpMaxLosersBeforeCut)
               continue;

            double cutNewestEntry, cutPreviousEntry;
            if(!GetTrailingAnchors(g_closeBaskets[b], cutDirection, cutNewestEntry, cutPreviousEntry))
               continue;

            double adverseMove = (cutDirection == 1)
               ? (cutNewestEntry - cutBid)
               : (cutAsk - cutNewestEntry);
            if(adverseMove < LoserCutMovePrice())
               continue;

            Print("OneClickGrid: LOSER CUT market exit #", g_closeBaskets[b].rootOrderTicket,
                  " | Buy=", buyCount, " Sell=", sellCount,
                  " | direction=", cutDirection,
                  " | side holds ", sideCount, " >= ", InpMaxLosersBeforeCut, " positions",
                  " | newest entry ", DoubleToString(cutNewestEntry, _Digits),
                  " ran ", DoubleToString(adverseMove, _Digits),
                  " against it (limit ", DoubleToString(LoserCutMovePrice(), _Digits), ")",
                  " | net=", DoubleToString(netProfit, 2));
            g_closeBaskets[b].marketExitRequested = true;
            SavePersistentState();
            CloseBasketAtMarket(g_closeBaskets[b]);
            break;
           }

         if(g_closeBaskets[b].marketExitRequested)
            continue;
        }

      // SAFETY BREAKER - independent per side for the same reason as the
      // loser cut above. A recovery on a given side needs winnerCount on
      // THAT side >= 2*k+1, but winnerCount can never exceed
      // InpOrdersPerSide (the grid's own level cap). Once a side's own
      // loser count k grows past that ceiling, that side can no longer
      // trade its way out, so cut the loss here rather than hold an
      // unrecoverable basket while price whips back and forth.
      if(InpUseRecoveryFormula)
        {
         int breakerDirection = 0;
         if(buyLosingCount > 0 && 2 * buyLosingCount + 1 > InpOrdersPerSide)
            breakerDirection = 1;
         else if(sellLosingCount > 0 && 2 * sellLosingCount + 1 > InpOrdersPerSide)
            breakerDirection = -1;

         if(breakerDirection != 0)
           {
            int k = (breakerDirection == 1) ? buyLosingCount : sellLosingCount;
            Print("OneClickGrid: SAFETY BREAKER market exit #", g_closeBaskets[b].rootOrderTicket,
                  " | Buy=", buyCount, " Sell=", sellCount,
                  " | direction=", breakerDirection,
                  " | k=", k, " needs winners>=", 2 * k + 1,
                  " but max winners=", InpOrdersPerSide, " (gate unreachable)",
                  " | net=", DoubleToString(netProfit, 2));
            g_closeBaskets[b].marketExitRequested = true;
            SavePersistentState();
            CloseBasketAtMarket(g_closeBaskets[b]);
            continue;
           }
        }

      // The winning side is the profitable direction; the protective line
      // trails behind whichever side that is.
      int winningDirection = 0;
      if(buyProfit > 0.0 && sellProfit > 0.0)
         winningDirection = (buyProfit >= sellProfit) ? 1 : -1;
      else if(buyProfit > 0.0)
         winningDirection = 1;
      else if(sellProfit > 0.0)
         winningDirection = -1;

      // Once WINNER CUT has fired, the direction it left running is settled
      // and stored, so it stays authoritative from then on. The profit-sign
      // heuristic above would read "no side is winning" during exactly the
      // pullback the budget and trailing exist to catch, and counting live
      // positions instead would flip to the wrong side whenever one of the
      // cut side's closes failed and left a position behind.
      if(g_closeBaskets[b].winnerCutDirection != 0)
         winningDirection = g_closeBaskets[b].winnerCutDirection;

      // With no side to manage there is nothing new to trail behind, but a
      // line already sitting on the broker keeps protecting the basket.
      if(winningDirection == 0)
         continue;

      // WINNER CUT RETRY - the cut is a settled decision, so the side it cut
      // has to end up empty even when an earlier delete or close failed.
      // Retrying on the stored direction (rather than on a fresh P/L read)
      // means a leftover position is cleared whether it is still losing or
      // has since drifted back to profit.
      if(g_closeBaskets[b].winnerCutDirection != 0 &&
         SideHasOpenState(g_closeBaskets[b], -winningDirection))
        {
         Print("OneClickGrid: WINNER CUT retry #", g_closeBaskets[b].rootOrderTicket,
               " | the cut side still holds orders or positions; closing it again",
               " | direction=", -winningDirection);
         CloseSideAtMarket(g_closeBaskets[b], -winningDirection);
         continue;
        }

      int winnerCount = (winningDirection == 1) ? buyCount : sellCount;
      int losingCount = (winningDirection == 1) ? sellLosingCount : buyLosingCount;

      // WINNER CUT - once the winning side reaches InpWinnerCutCount
      // positions, the recovery-formula ratio (2k+1, e.g. 3-1 or 5-2) and
      // its extra price-move requirement no longer matter: bank the edge
      // now by closing the losing side - its open positions and its
      // remaining pending orders - at market. The winning side is left
      // running with no hedge left on the other side; the trailing line
      // below takes over protecting it from here. A clean basket (k = 0)
      // has nothing to bank and is skipped.
      if(InpWinnerCutCount > 0 && g_closeBaskets[b].winnerCutDirection == 0 &&
         losingCount > 0 && winnerCount >= InpWinnerCutCount)
        {
         // The anchor, k and the direction are banked together or not at
         // all: a budget ceiling without a usable anchor would silently do
         // nothing, so a failed anchor read just retries on the next tick.
         double cutAnchorEntry, cutAnchorPrevious;
         if(!GetTrailingAnchors(g_closeBaskets[b], winningDirection, cutAnchorEntry, cutAnchorPrevious) ||
            cutAnchorEntry <= 0.0)
           {
            Print("OneClickGrid: WINNER CUT deferred #", g_closeBaskets[b].rootOrderTicket,
                  "; the winning side's newest entry could not be read this tick");
            continue;
           }

         Print("OneClickGrid: WINNER CUT closing losing side #", g_closeBaskets[b].rootOrderTicket,
               " | Buy=", buyCount, " Sell=", sellCount,
               " | winners=", winnerCount, " >= ", InpWinnerCutCount,
               " | losers=", losingCount,
               " | anchor=", DoubleToString(cutAnchorEntry, _Digits),
               " | net=", DoubleToString(netProfit, 2));
         g_closeBaskets[b].bankedLoserCount = losingCount;
         g_closeBaskets[b].winnerCutAnchorPrice = cutAnchorEntry;
         g_closeBaskets[b].winnerCutDirection = winningDirection;
         SavePersistentState();
         CloseSideAtMarket(g_closeBaskets[b], -winningDirection);
         continue;
        }

      // WINNER CUT BUDGET - once WINNER CUT has fired for this basket (k > 0
      // banked losers), the surviving side is allowed to extend k grid steps
      // past its entry at cut time. Beyond that the trend has run out of the
      // room its own banked loss earned it, so the whole remaining side is
      // closed at market as a backstop. A basket that never had a WINNER CUT
      // (k = 0) has no such ceiling and trails indefinitely.
      if(g_closeBaskets[b].bankedLoserCount > 0 && g_closeBaskets[b].winnerCutAnchorPrice > 0.0)
        {
         double budgetLimit = g_closeBaskets[b].winnerCutAnchorPrice +
            winningDirection * g_closeBaskets[b].bankedLoserCount * GridStepPrice();
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         bool budgetExceeded = (winningDirection == 1) ? (bid >= budgetLimit) : (ask <= budgetLimit);

         if(bid > 0.0 && ask > 0.0 && budgetExceeded)
           {
            Print("OneClickGrid: WINNER CUT BUDGET market exit #", g_closeBaskets[b].rootOrderTicket,
                  " | k=", g_closeBaskets[b].bankedLoserCount,
                  " | anchor=", DoubleToString(g_closeBaskets[b].winnerCutAnchorPrice, _Digits),
                  " | limit=", DoubleToString(budgetLimit, _Digits),
                  " | net=", DoubleToString(netProfit, 2));
            g_closeBaskets[b].marketExitRequested = true;
            SavePersistentState();
            CloseBasketAtMarket(g_closeBaskets[b]);
            continue;
           }
        }

      UpdateTrailingProtection(g_closeBaskets[b], winningDirection);

      if(g_closeBaskets[b].protectionArmed)
         ApplyBasketProtection(g_closeBaskets[b]);
     }
  }
//+------------------------------------------------------------------+
