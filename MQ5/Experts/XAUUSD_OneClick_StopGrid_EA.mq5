//+------------------------------------------------------------------+
//|                         XAUUSD_OneClick_StopGrid_EA.mq5           |
//|  Builds a two-sided pending-stop grid from one manual market     |
//|  entry. Portfolio-close rules are managed separately.            |
//+------------------------------------------------------------------+
#property copyright "Custom EA - One Click Stop Grid"
#property version   "1.31"
#property strict

#include <Trade/Trade.mqh>

CTrade trade;

#define MAX_PROCESSED_MANUAL_ORDERS 256
#define MAX_GRID_LEVELS_PER_SIDE    32
#define MAX_TRACKED_BASKETS         64

input group "=== Opening Grid ==="
input int      InpOrdersPerSide       = 7;       // Total levels per side; the manual entry counts as level 1 on its side
input int      InpPriceStepCents       = 300;     // Grid distance in price cents; 300 = 3.000 (4000 -> 4003)
input double   InpFixedLotUnit         = 0.01;    // Fixed lot unit for level >= 2; lot = (2*level-1) * this, e.g. 0.01 -> 0.03, 0.05, 0.07, 0.09, ...

input group "=== Optional SL / TP (price distance) ==="
input double   InpStopLossDistance     = 0.0;     // 0 = no SL; otherwise distance from each pending entry price
input double   InpTakeProfitDistance   = 0.0;     // 0 = no TP; otherwise distance from each pending entry price

input group "=== Basket Exit Rules ==="
input bool     InpUseFormulaClose       = true;    // Master switch for every basket exit rule
input bool     InpUseRecoveryFormula    = true;    // SAFETY BREAKER gate: winning side count >= 2 * losing count + 1
input int      InpTrailArmCents         = 150;     // TRAILING layer 2 distance past the newest entry in price cents; 150 = 1.500
input int      InpMaxLosersBeforeCut    = 3;       // LOSER CUT: 0 = disabled; otherwise close everything once this many losers exist and the newest one is passed
input int      InpLoserCutMoveCents     = 200;     // LOSER CUT adverse move past the newest losing entry in price cents; 200 = 2.000

input group "=== Execution Safety ==="
input ulong    InpMagicNumber          = 20260904;
input int      InpSlippagePoints       = 100;
input double   InpMaxSpreadPrice       = 0.50;    // 0 = disabled; otherwise reject a grid when spread exceeds this price distance
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
      InpMaxLosersBeforeCut < 0 ||
      (InpMaxLosersBeforeCut > 0 && InpLoserCutMoveCents <= 0) ||
      InpExpirationHours < 0)
     {
      Print("OneClickGrid: invalid input parameters");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpTrailArmCents >= InpPriceStepCents)
     {
      Print("OneClickGrid: InpTrailArmCents must stay below InpPriceStepCents so the layer 2 line sits inside one grid step");
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
   Print("OneClickGrid: TRAILING layer 1 = protect at the previous position's entry as soon as a second position exists");
   Print("OneClickGrid: TRAILING layer 2 = move the line to ",
         DoubleToString(TrailArmPrice(), _Digits),
         " past the newest entry once price has travelled that far;",
         " the line never moves back and pending orders stay alive");
   if(InpUseRecoveryFormula)
      Print("OneClickGrid: SAFETY BREAKER = market-close the basket once k > ",
            (int)((InpOrdersPerSide - 1) / 2),
            " losing positions, since 2k+1 can no longer be satisfied within ",
            InpOrdersPerSide, " levels/side");
   Print("OneClickGrid: LOSER CUT = ", InpMaxLosersBeforeCut > 0
         ? StringFormat("close everything once k >= %d and price runs %s past the newest losing entry",
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
   // broker _Point: 150 always means 4000 -> 4001.5.
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
   string fields[] = {"RH","RL","MH","ML","T","E","L","Q","A","D","P","X"};
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
     }
   for(int i=basketCount; i<oldBasketCount && i<MAX_TRACKED_BASKETS; i++)
      DeleteBasketStateSlot(i);

   WriteStateValue(g_statePrefix + ".BC", (double)basketCount);
   WriteStateValue(g_statePrefix + ".V", 4.0);
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
   if(stateVersion < 1 || stateVersion > 4)
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
                    int &losingCount)
  {
   buyCount = 0;
   sellCount = 0;
   buyProfit = 0.0;
   sellProfit = 0.0;
   netProfit = 0.0;
   losingCount = 0;

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
        }
      else if(type == POSITION_TYPE_SELL)
        {
         sellCount++;
         sellProfit += profit;
        }

      if(profit < 0.0)
         losingCount++;
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
bool GetNewestLoserAdverseMove(const CloseBasket &basket, double &adverseMove)
  {
   long latestTimeMsc = -1;
   ulong latestTicket = 0;
   double entryPrice = 0.0;
   int direction = 0;
   adverseMove = 0.0;

   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionBelongsToBasket(basket))
         continue;

      // Same loser definition GetBasketStats uses for k.
      if(PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP) >= 0.0)
         continue;

      long timeMsc = PositionGetInteger(POSITION_TIME_MSC);
      if(timeMsc > latestTimeMsc || (timeMsc == latestTimeMsc && ticket > latestTicket))
        {
         latestTimeMsc = timeMsc;
         latestTicket = ticket;
         entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         direction = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
        }
     }

   if(direction == 0 || entryPrice <= 0.0)
      return(false);

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return(false);

   adverseMove = (direction == 1) ? (entryPrice - bid) : (ask - entryPrice);
   return(true);
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
//| Two-layer trailing protection.                                    |
//|  Layer 1 - the previous position's entry, usable the moment a     |
//|            second position exists on the winning side. It costs   |
//|            the newest position one grid step, but needs no price  |
//|            movement at all, so the basket is never unprotected.   |
//|  Layer 2 - TrailArmPrice() beyond the newest entry, once price    |
//|            has actually travelled that far. This locks profit on  |
//|            every position, the newest one included.               |
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
   // TrailArmPrice() behind the manual entry and close the basket for a
   // token profit before the next level can even fill, so both layers wait
   // until this side actually holds two positions.
   if(previousEntry <= 0.0)
      return;

   double candidate = previousEntry;
   string layer = "layer 1 - previous entry";

   double armedLine = newestEntry + direction * TrailArmPrice();
   bool layer2Ready = (direction == 1) ? (bid > armedLine) : (ask < armedLine);
   if(layer2Ready && IsBetterLine(armedLine, candidate, direction))
     {
      candidate = armedLine;
      layer = "layer 2 - newest entry + trail";
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

      int buyCount, sellCount, losingCount;
      double buyProfit, sellProfit, netProfit;
      GetBasketStats(g_closeBaskets[b], buyCount, sellCount, buyProfit, sellProfit, netProfit,
                     losingCount);

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

      // LOSER CUT - hard loss stop, evaluated before every other rule. Once
      // the basket carries InpMaxLosersBeforeCut losing positions and price
      // has run LoserCutMovePrice() past the newest of them, the whole
      // basket is closed at market. With a 3.000 grid and a 2.000 cut the
      // exit fires before the next adverse level can fill, so the losing
      // side cannot keep growing.
      if(InpMaxLosersBeforeCut > 0 && losingCount >= InpMaxLosersBeforeCut)
        {
         double loserAdverseMove;
         if(GetNewestLoserAdverseMove(g_closeBaskets[b], loserAdverseMove) &&
            loserAdverseMove >= LoserCutMovePrice())
           {
            Print("OneClickGrid: LOSER CUT market exit #", g_closeBaskets[b].rootOrderTicket,
                  " | Buy=", buyCount, " Sell=", sellCount,
                  " | k=", losingCount, " >= ", InpMaxLosersBeforeCut,
                  " | newest loser ran ", DoubleToString(loserAdverseMove, _Digits),
                  " past its entry (limit ", DoubleToString(LoserCutMovePrice(), _Digits), ")",
                  " | net=", DoubleToString(netProfit, 2));
            g_closeBaskets[b].marketExitRequested = true;
            SavePersistentState();
            CloseBasketAtMarket(g_closeBaskets[b]);
            continue;
           }
        }

      // SAFETY BREAKER - a recovery needs winnerCount >= 2*losingCount+1,
      // but winnerCount can never exceed InpOrdersPerSide (the grid's own
      // level cap). Once losingCount grows past that ceiling the basket can
      // no longer trade its way out, so cut the loss here rather than hold
      // an unrecoverable basket while price whips back and forth.
      if(InpUseRecoveryFormula && losingCount > 0 &&
         2 * losingCount + 1 > InpOrdersPerSide)
        {
         Print("OneClickGrid: SAFETY BREAKER market exit #", g_closeBaskets[b].rootOrderTicket,
               " | Buy=", buyCount, " Sell=", sellCount,
               " | k=", losingCount, " needs winners>=", 2 * losingCount + 1,
               " but max winners=", InpOrdersPerSide, " (gate unreachable)",
               " | net=", DoubleToString(netProfit, 2));
         g_closeBaskets[b].marketExitRequested = true;
         SavePersistentState();
         CloseBasketAtMarket(g_closeBaskets[b]);
         continue;
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

      // With no profitable side there is nothing new to trail behind, but a
      // line already sitting on the broker keeps protecting the basket.
      if(winningDirection == 0)
         continue;

      UpdateTrailingProtection(g_closeBaskets[b], winningDirection);

      if(g_closeBaskets[b].protectionArmed)
         ApplyBasketProtection(g_closeBaskets[b]);
     }
  }
//+------------------------------------------------------------------+
