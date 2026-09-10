//+------------------------------------------------------------------+
//|                    XAUUSD_OneClick_StopGrid_PONG.mq5              |
//|  Builds a two-sided pending-stop grid from one manual market      |
//|  entry. CASE 1 / CASE 2 basket-close rules are unchanged from the |
//|  base script. Level >= 2 positions on either side additionally    |
//|  get a breakeven+X lock; a position that reverses back through    |
//|  its own entry before locking spawns a mirror order at the same   |
//|  price, and once price returns to the manual root, a new re-entry |
//|  order is opened there too - an uncapped ping-pong recovery loop. |
//+------------------------------------------------------------------+
#property copyright "Custom EA - One Click Stop Grid PONG"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

CTrade trade;

#define MAX_PROCESSED_MANUAL_ORDERS 256
#define MAX_GRID_LEVELS_PER_SIDE    32
#define MAX_TRACKED_BASKETS         64

input group "=== Opening Grid ==="
input int      InpOrdersPerSide       = 5;       // Total levels per side; the manual entry counts as level 1 on its side
input int      InpPriceStepCents       = 200;     // Grid distance in price cents; 200 = 2.000 (4000 -> 4002)
input double   InpLotFactorStep        = 2.0;     // Factor increment per level; 2.0 gives 1x, 3x, 5x, 7x, 9x

input group "=== Optional SL / TP (price distance) ==="
input double   InpStopLossDistance     = 0.0;     // 0 = no SL; otherwise distance from each pending entry price
input double   InpTakeProfitDistance   = 0.0;     // 0 = no TP; otherwise distance from each pending entry price

input group "=== Basket Exit Rules (CASE 1 / CASE 2, unchanged) ==="
input bool     InpUseFormulaClose       = true;    // Master switch for CASE 1/2 AND the PONG recovery loop below
input bool     InpUseRecoveryFormula    = true;    // MAIN GATE: winning side count >= 2 * losing count + 1
input int      InpConsecutiveWinners    = 3;       // CASE 1 (k = 0) minimum winning-side positions
input int      InpWinnerMoveCents       = 150;     // CASE 1 last-winner move in price cents; 150 = 1.500 (4000 -> 4001.5)
input int      InpProfitLockCents       = 100;     // CASE 1 locked SL distance in price cents; 100 = 1.000 (SL 4001)
input int      InpLossExitMoveCents     = 150;     // CASE 2 (k > 0) last-winner move that closes the basket at market
input double   InpCloseMinProfitMoney   = 0.0;     // CASE 1 only; basket floating profit must exceed this before arming

input group "=== PONG Recovery (level 2+ on either side) ==="
input int      InpPongBreakevenCents    = 50;      // Once a level>=2 position's profit reaches this, lock its own SL there (breakeven+X)
// NOTE: there is deliberately NO cap on how many PONG mirror/re-entry cycles
// can chain - price whipsawing across the same two prices repeatedly will
// keep opening new positions with nothing closing the old ones except
// CASE 1 / CASE 2 above. This is an accepted, uncapped risk - see the
// summary given alongside this file for the exact reasoning.

input group "=== Execution Safety ==="
input ulong    InpMagicNumber          = 20260904;
input int      InpSlippagePoints       = 100;
input double   InpMaxSpreadPrice       = 0.0;     // 0 = disabled; otherwise reject a grid when spread exceeds this price distance
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
   bool  protectionArmed;      // CASE 1 latch: locked SL/TP line is active
   int   protectionDirection;
   double protectionPrice;
   bool  marketExitRequested;  // CASE 2 latch: close every position at market
   datetime startTime;
  };
CloseBasket g_closeBaskets[];

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpOrdersPerSide < 1 || InpOrdersPerSide > MAX_GRID_LEVELS_PER_SIDE ||
      InpPriceStepCents <= 0 || InpLotFactorStep <= 0.0 ||
      InpMaxOwnPendingOrders < 1 ||
      InpStopLossDistance < 0.0 || InpTakeProfitDistance < 0.0 ||
      InpCloseMinProfitMoney < 0.0 ||
      InpWinnerMoveCents <= 0 || InpProfitLockCents <= 0 ||
      InpLossExitMoveCents <= 0 ||
      InpConsecutiveWinners < 1 ||
      InpPongBreakevenCents <= 0 ||
      InpExpirationHours < 0)
     {
      Print("OneClickGridPONG: invalid input parameters");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpProfitLockCents >= InpWinnerMoveCents)
     {
      Print("OneClickGridPONG: InpProfitLockCents must stay below InpWinnerMoveCents so the locked SL sits behind the qualifying price");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(!SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE, g_tickSize) || g_tickSize <= 0.0 ||
      !SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN, g_volumeMin) || g_volumeMin <= 0.0 ||
      !SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX, g_volumeMax) || g_volumeMax <= 0.0 ||
      !SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP, g_volumeStep) || g_volumeStep <= 0.0)
     {
      Print("OneClickGridPONG: cannot read symbol trading constraints for ", _Symbol);
      return(INIT_FAILED);
     }

   if(InpStopLossDistance <= 0.0)
      Print("OneClickGridPONG: WARNING - per-position Stop Loss is disabled and there is no automatic maximum-loss protection.");

   Print("OneClickGridPONG: WARNING - the PONG recovery loop has NO cap on mirror/re-entry cycles. ",
         "A choppy, range-bound market can keep opening new positions indefinitely with nothing closing the old ones ",
         "except CASE 1 / CASE 2 above. This is by design, not a bug.");

   long marginMode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Print("OneClickGridPONG: a hedging account is required. Netting accounts merge positions and cannot preserve separate grid levels.");
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

   Print("OneClickGridPONG: ready on ", _Symbol,
         " | opening levels/side=", InpOrdersPerSide,
         " | step=", DoubleToString(GridStepPrice(), _Digits),
         " (", InpPriceStepCents, " cents)",
         " | lot factors=1x,+", DoubleToString(InpLotFactorStep, 2), "x per level");
   Print("OneClickGridPONG: main gate = ", InpUseRecoveryFormula
         ? "winning side must hold >= 2k+1 positions (k = losing positions)"
         : "disabled");
   Print("OneClickGridPONG: CASE 1 (k = 0) = ", InpConsecutiveWinners,
         " winners and the last winner past ", DoubleToString(WinnerMovePrice(), _Digits),
         " arm a locked SL at ", DoubleToString(ProfitLockPrice(), _Digits),
         " from that entry");
   Print("OneClickGridPONG: CASE 2 (k > 0) = close the whole basket at market once the last winner moves past ",
         DoubleToString(LossExitMovePrice(), _Digits));
   Print("OneClickGridPONG: PONG = level>=2 positions on either side lock their own SL at entry +",
         DoubleToString(PongLockPrice(), _Digits),
         " once price reaches it; if price reverses back through the entry first, a same-price mirror ",
         "opens on the opposite side, and once price returns to the manual root a new re-entry opens there too, uncapped");
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
      Print("OneClickGridPONG: invalid manual deal data for #", dealTicket);
      return;
     }

   if(manualPositionId == 0 ||
      !AddCloseBasket(manualOrderTicket, manualPositionId, manualTime))
     {
      Print("OneClickGridPONG: cannot adopt manual order #", manualOrderTicket,
            " safely; it remains user-owned and no grid will be created");
      return;
     }
   SavePersistentState();

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
     {
      Print("OneClickGridPONG: no valid market quote; grid was not created for manual order #", manualOrderTicket);
      return;
     }

   double spread = ask - bid;
   if(InpMaxSpreadPrice > 0.0 && spread > InpMaxSpreadPrice)
     {
      Print("OneClickGridPONG: spread ", DoubleToString(spread, _Digits),
            " exceeds limit ", DoubleToString(InpMaxSpreadPrice, _Digits),
            "; grid was not created for manual order #", manualOrderTicket);
      return;
     }

   int requiredPending = (InpOrdersPerSide - 1) + InpOrdersPerSide;
   int availableSlots  = InpMaxOwnPendingOrders - CountOwnPendingOrders();
   if(availableSlots < requiredPending)
     {
      Print("OneClickGridPONG: safety cap allows only ", availableSlots,
            " new pending orders but this grid requires ", requiredPending,
            "; no partial grid was created");
      return;
     }

   int placed = 0;

   // The manual position is level 1. With factor step 2, levels use the
   // odd-number sequence 1x, 3x, 5x, 7x, 9x on both sides. Level tags are
   // embedded in the comment (G#<root>.<level>) so the PONG logic below can
   // tell a level-1 position (exempt) from level 2+ (eligible).
   for(int level=2; level<=InpOrdersPerSide; level++)
     {
      double price = manualPrice + direction * (level - 1) * GridStepPrice();
      double lot   = manualLot * LotFactorForLevel(level);
      if(PlaceStopOrder(direction, level, manualOrderTicket, price, lot))
         placed++;
     }

   // The opposite side keeps the same fixed opening count and restarts the
   // odd-number lot sequence from 1x at its own first pending level. Its own
   // level 1 is exempt from PONG the same way the manual entry is.
   int oppositeDirection = -direction;
   for(int level=1; level<=InpOrdersPerSide; level++)
     {
      double price = manualPrice + oppositeDirection * level * GridStepPrice();
      double lot   = manualLot * LotFactorForLevel(level);
      if(PlaceStopOrder(oppositeDirection, level, manualOrderTicket, price, lot))
         placed++;
     }

   Print("OneClickGridPONG: manual order #", manualOrderTicket,
         " created ", placed, "/", requiredPending, " opening pending orders");
  }

//+------------------------------------------------------------------+
double LotFactorForLevel(const int level)
  {
   return(1.0 + (level - 1) * InpLotFactorStep);
  }

//+------------------------------------------------------------------+
double GridStepPrice()
  {
   // Grid units are price cents, deliberately independent of broker
   // _Point. Thus 200 always means a 2.000 XAUUSD price distance.
   return(InpPriceStepCents / 100.0);
  }

//+------------------------------------------------------------------+
double WinnerMovePrice()
  {
   // Exit distances share the grid's price-cent unit and deliberately ignore
   // broker _Point: 150 always means 4000 -> 4001.5.
   return(InpWinnerMoveCents / 100.0);
  }

//+------------------------------------------------------------------+
double ProfitLockPrice()
  {
   return(InpProfitLockCents / 100.0);
  }

//+------------------------------------------------------------------+
double LossExitMovePrice()
  {
   return(InpLossExitMoveCents / 100.0);
  }

//+------------------------------------------------------------------+
double PongLockPrice()
  {
   return(InpPongBreakevenCents / 100.0);
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
      Print("OneClickGridPONG: level ", level, " skipped; requested lot ",
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
      Print("OneClickGridPONG: level ", level, " at ", DoubleToString(entryPrice, _Digits),
            " skipped; pending-stop price is too close to or behind the current market");
      return(false);
     }

   double sl = BuildStopLoss(entryPrice, direction);
   double tp = BuildTakeProfit(entryPrice, direction);
   if(!StopsAreValid(entryPrice, sl, tp, minDistance, direction))
     {
      Print("OneClickGridPONG: level ", level, " skipped; SL/TP violates the broker minimum stop distance");
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
   string comment = GridCommentTag(manualOrderTicket, level);

   ResetLastError();
   bool sent = (direction == 1)
      ? trade.BuyStop(lot, entryPrice, _Symbol, sl, tp, timeType, expiration, comment)
      : trade.SellStop(lot, entryPrice, _Symbol, sl, tp, timeType, expiration, comment);

   uint retcode = trade.ResultRetcode();
   bool accepted = sent &&
      (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED || retcode == TRADE_RETCODE_DONE_PARTIAL);

   if(!accepted)
     {
      Print("OneClickGridPONG: ", side, " level ", level, " failed | lot=",
            DoubleToString(lot, VolumeDigits()), " price=", DoubleToString(entryPrice, _Digits),
            " | retcode=", retcode, " ", trade.ResultRetcodeDescription(),
            " | lastError=", GetLastError());
      return(false);
     }

   Print("OneClickGridPONG: placed ", side, " level ", level,
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
         type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_SELL_LIMIT ||
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
// Tagging scheme (all three share the same root-ticket prefix parsing):
//   G#<root>.<level>          - an original grid order/position (level 1..N)
//   M#<root>.<originTicket>   - a PONG mirror opened opposite an unarmed
//                               level>=2 position that reversed through its
//                               own entry (originTicket = that position)
//   R#<root>.<mirrorTicket>   - a PONG re-entry opened at the manual root's
//                               price once price returned there, chained
//                               from a specific filled mirror position
//+------------------------------------------------------------------+
string GridCommentTag(const ulong rootOrderTicket, const int level)
  {
   return(StringFormat("G#%I64u.%d", rootOrderTicket, level));
  }

//+------------------------------------------------------------------+
string PongMirrorTag(const ulong rootOrderTicket, const ulong originTicket)
  {
   return(StringFormat("M#%I64u.%I64u", rootOrderTicket, originTicket));
  }

//+------------------------------------------------------------------+
string PongReentryTag(const ulong rootOrderTicket, const ulong originTicket)
  {
   return(StringFormat("R#%I64u.%I64u", rootOrderTicket, originTicket));
  }

//+------------------------------------------------------------------+
bool CommentMatchesBasket(const string comment, const ulong rootOrderTicket)
  {
   ulong root = RootTicketFromComment(comment);
   return(root != 0 && root == rootOrderTicket);
  }

//+------------------------------------------------------------------+
// Accepts "G#", "M#" or "R#" prefixes and stops at the first non-digit
// character instead of requiring digits through the end of the string, so
// it works for both the plain legacy "G#<root>" format and the new
// "<prefix><root>.<suffix>" formats used here.
//+------------------------------------------------------------------+
ulong RootTicketFromComment(const string comment)
  {
   if(StringLen(comment) <= 2)
      return(0);

   string prefix = StringSubstr(comment, 0, 2);
   if(prefix != "G#" && prefix != "M#" && prefix != "R#")
      return(0);

   ulong parsed = 0;
   ulong maxValue = ~((ulong)0);
   int digitsConsumed = 0;
   for(int i=2; i<StringLen(comment); i++)
     {
      ushort ch = StringGetCharacter(comment, i);
      if(ch < '0' || ch > '9')
         break;
      ulong digit = (ulong)(ch - '0');
      if(parsed > (maxValue - digit) / 10)
         return(0);
      parsed = parsed * 10 + digit;
      digitsConsumed++;
     }
   if(digitsConsumed == 0)
      return(0);
   return(parsed);
  }

//+------------------------------------------------------------------+
int GridLevelFromComment(const string comment)
  {
   if(StringLen(comment) <= 2 || StringSubstr(comment, 0, 2) != "G#")
      return(0);

   int dot = StringFind(comment, ".", 2);
   if(dot < 0 || dot + 1 >= StringLen(comment))
      return(0);

   int level = (int)StringToInteger(StringSubstr(comment, dot + 1));
   return(level > 0 ? level : 0);
  }

//+------------------------------------------------------------------+
ulong PongOriginFromComment(const string comment)
  {
   if(StringLen(comment) <= 2)
      return(0);

   string prefix = StringSubstr(comment, 0, 2);
   if(prefix != "M#" && prefix != "R#")
      return(0);

   int dot = StringFind(comment, ".", 2);
   if(dot < 0 || dot + 1 >= StringLen(comment))
      return(0);

   return((ulong)StringToInteger(StringSubstr(comment, dot + 1)));
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
      Print("OneClickGridPONG: managed basket capacity reached; root #", rootOrderTicket,
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
            Print("OneClickGridPONG: discovered basket #", root,
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
            Print("OneClickGridPONG: discovered basket #", root,
                  " from tagged terminal state");
        }
     }

   for(int i=0; i<ArraySize(g_closeBaskets); i++)
      RememberManualOrder(g_closeBaskets[i].rootOrderTicket);

   if(ArraySize(g_closeBaskets) > 0)
      Print("OneClickGridPONG: restored ", ArraySize(g_closeBaskets), " managed basket(s)");
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
   return("OCSGP." + StringFormat("%08X", StateScopeHash()));
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
      Print("OneClickGridPONG: persistent state write failed for ", key,
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
      Print("OneClickGridPONG: saved basket state count is invalid; terminal state discovery will be used");
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
         Print("OneClickGridPONG: skipped incomplete saved basket slot ", i);
         continue;
        }

      if(!AddCloseBasket(root, manualId, (datetime)MathRound(timeValue)))
         break;

      int index = FindCloseBasket(root);

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
         Print("OneClickGridPONG: restored formula protection latch #", root,
               " | direction=", savedDirection,
               " | price=", DoubleToString(priceValue, _Digits));
        }
      else if(protectionComplete && armedValue > 0.5)
         Print("OneClickGridPONG: discarded incomplete formula protection state #", root);

      double marketExitValue = 0.0;
      if(index >= 0 && stateVersion >= 4 &&
         ReadStateValue(BasketStateKey(i, "X"), marketExitValue) && marketExitValue > 0.5)
        {
         g_closeBaskets[index].marketExitRequested = true;
         Print("OneClickGridPONG: restored CASE 2 market-exit latch #", root,
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
bool BasketHasOpenState(const CloseBasket &basket)
  {
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionBelongsToBasket(basket))
         return(true);
     }

   for(int i=OrdersTotal()-1; i>=0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderBelongsToBasket(basket))
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
bool GetLastWinnerOpenPrice(const CloseBasket &basket,
                            const int direction,
                            double &lastOpenPrice)
  {
   long latestTimeMsc = -1;
   ulong latestTicket = 0;
   lastOpenPrice = 0.0;

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
      if(timeMsc > latestTimeMsc || (timeMsc == latestTimeMsc && ticket > latestTicket))
        {
         latestTimeMsc = timeMsc;
         latestTicket = ticket;
         lastOpenPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        }
     }
   return(lastOpenPrice > 0.0);
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
         Print("OneClickGridPONG: pending delete failed #", ticket, " | ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
void CloseBasketAtMarket(const CloseBasket &basket)
  {
   // Pending orders go first so a fill cannot re-enter the basket between
   // the individual position closes. This also cancels any still-pending
   // PONG mirror/re-entry orders tagged to this same root.
   DeleteBasketPendingOrders(basket);

   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionBelongsToBasket(basket))
         continue;

      if(!trade.PositionClose(ticket, InpSlippagePoints))
         Print("OneClickGridPONG: market close failed #", ticket, " | ", trade.ResultRetcodeDescription(),
               " | it is retried on the following ticks");
     }
  }

//+------------------------------------------------------------------+
void ApplyBasketProtection(const CloseBasket &basket)
  {
   DeleteBasketPendingOrders(basket);

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
         Print("OneClickGridPONG: protection price too close for #", ticket,
               " | target=", DoubleToString(basket.protectionPrice, _Digits));
         continue;
        }

      if(MathAbs(newSL - curSL) < g_tickSize / 2.0 &&
         MathAbs(newTP - curTP) < g_tickSize / 2.0)
         continue;

      bool sent = trade.PositionModify(ticket, newSL, newTP);
      uint retcode = trade.ResultRetcode();
      if(!sent || (retcode != TRADE_RETCODE_DONE && retcode != TRADE_RETCODE_DONE_PARTIAL))
         Print("OneClickGridPONG: protection modify failed #", ticket, " | ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Generic pending-order placer used by the PONG loop. Chooses Stop vs   |
//| Limit automatically depending on which side of the current market the |
//| requested price falls on, since MT5 rejects a Stop order placed on    |
//| the wrong side (e.g. a Buy Stop below Ask) - a Limit is the correct   |
//| type once price has already moved past the target and needs to come  |
//| back to it, which is exactly the PONG "reopen at the same price"      |
//| situation.                                                            |
//+------------------------------------------------------------------+
bool PlacePendingAtPrice(const int direction,
                         const double rawPrice,
                         const double requestedLot,
                         const string comment)
  {
   double lot = NormalizeVolumeDown(requestedLot);
   if(lot <= 0.0)
     {
      Print("OneClickGridPONG PONG: lot ", DoubleToString(requestedLot, 8),
            " outside broker limits [", DoubleToString(g_volumeMin, 8), ", ",
            DoubleToString(g_volumeMax, 8), "]; order skipped | comment=", comment);
      return(false);
     }

   double price = NormalizePriceForDirection(rawPrice, direction);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minDistance = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   ENUM_ORDER_TYPE_TIME timeType = ORDER_TIME_GTC;
   datetime expiration = 0;
   if(InpExpirationHours > 0)
     {
      timeType = ORDER_TIME_SPECIFIED;
      expiration = TimeCurrent() + InpExpirationHours * 3600;
     }

   bool sent = false;
   string kind = "";

   if(direction == 1)
     {
      if(price - ask >= minDistance)
        {
         sent = trade.BuyStop(lot, price, _Symbol, 0.0, 0.0, timeType, expiration, comment);
         kind = "BuyStop";
        }
      else if(bid - price >= minDistance)
        {
         sent = trade.BuyLimit(lot, price, _Symbol, 0.0, 0.0, timeType, expiration, comment);
         kind = "BuyLimit";
        }
      else
        {
         Print("OneClickGridPONG PONG: price ", DoubleToString(price, _Digits),
               " too close to market; order skipped | comment=", comment);
         return(false);
        }
     }
   else
     {
      if(bid - price >= minDistance)
        {
         sent = trade.SellStop(lot, price, _Symbol, 0.0, 0.0, timeType, expiration, comment);
         kind = "SellStop";
        }
      else if(price - ask >= minDistance)
        {
         sent = trade.SellLimit(lot, price, _Symbol, 0.0, 0.0, timeType, expiration, comment);
         kind = "SellLimit";
        }
      else
        {
         Print("OneClickGridPONG PONG: price ", DoubleToString(price, _Digits),
               " too close to market; order skipped | comment=", comment);
         return(false);
        }
     }

   uint retcode = trade.ResultRetcode();
   bool accepted = sent &&
      (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED || retcode == TRADE_RETCODE_DONE_PARTIAL);
   if(!accepted)
     {
      Print("OneClickGridPONG PONG: ", kind, " failed | lot=", DoubleToString(lot, VolumeDigits()),
            " price=", DoubleToString(price, _Digits), " | retcode=", retcode, " ",
            trade.ResultRetcodeDescription(), " | comment=", comment);
      return(false);
     }

   Print("OneClickGridPONG PONG: placed ", kind, " | ticket=", trade.ResultOrder(),
         " lot=", DoubleToString(lot, VolumeDigits()), " price=", DoubleToString(price, _Digits),
         " comment=", comment);
   return(true);
  }

//+------------------------------------------------------------------+
//| True if a pending order or a position belonging to this basket already |
//| carries the given tag prefix ("M#" or "R#") chained from originTicket. |
//| Prevents re-triggering the same mirror/re-entry every tick.            |
//+------------------------------------------------------------------+
bool PongTagExistsForOrigin(const CloseBasket &basket, const string prefix, const ulong originTicket)
  {
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionBelongsToBasket(basket))
         continue;
      string comment = PositionGetString(POSITION_COMMENT);
      if(StringSubstr(comment, 0, 2) == prefix && PongOriginFromComment(comment) == originTicket)
         return(true);
     }

   for(int i=OrdersTotal()-1; i>=0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderBelongsToBasket(basket))
         continue;
      string comment = OrderGetString(ORDER_COMMENT);
      if(StringSubstr(comment, 0, 2) == prefix && PongOriginFromComment(comment) == originTicket)
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| PONG step 2 + step 3 for one open position. Applies only to level>=2  |
//| grid positions and to positions born from a PONG mirror/re-entry -    |
//| level 1 on either side (and the bare manual entry) are exempt.        |
//|                                                                        |
//|  - If the position's own SL already sits at its breakeven+X lock,     |
//|    nothing more to do; the position protects itself from here.        |
//|  - Else if price has reached breakeven+X in its favour, lock the SL   |
//|    there now (step 2).                                                |
//|  - Else if price has reversed back through the position's own entry   |
//|    before it could lock, open a same-price mirror on the opposite     |
//|    side, same lot, once only (step 3).                                |
//+------------------------------------------------------------------+
void ManagePongForPosition(const CloseBasket &basket, const ulong ticket)
  {
   if(!PositionSelectByTicket(ticket) || !PositionBelongsToBasket(basket))
      return;

   string comment = PositionGetString(POSITION_COMMENT);
   bool isGridLevel2Plus = (GridLevelFromComment(comment) >= 2);
   string prefix = (StringLen(comment) >= 2) ? StringSubstr(comment, 0, 2) : "";
   bool isPongChain = (prefix == "M#" || prefix == "R#");
   if(!isGridLevel2Plus && !isPongChain)
      return; // level-1 grid positions on both sides, and the manual entry, are exempt

   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   int direction = (type == POSITION_TYPE_BUY) ? 1 : -1;
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double lot = PositionGetDouble(POSITION_VOLUME);
   double curSL = PositionGetDouble(POSITION_SL);

   double lockPrice = entry + direction * PongLockPrice();
   double targetSL = NormalizePriceForDirection(lockPrice, -direction);

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return;

   bool alreadyArmed = (curSL > 0.0) &&
      ((direction == 1) ? (curSL >= targetSL - g_tickSize / 2.0) : (curSL <= targetSL + g_tickSize / 2.0));
   if(alreadyArmed)
      return;

   bool reachedLock = (direction == 1) ? (bid >= lockPrice) : (ask <= lockPrice);
   if(reachedLock)
     {
      double newSL = (curSL > 0.0)
         ? ((direction == 1) ? MathMax(curSL, targetSL) : MathMin(curSL, targetSL))
         : targetSL;
      double minDistance = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
      bool priceAllowed = (direction == 1) ? (bid - newSL > minDistance) : (newSL - ask > minDistance);
      if(!priceAllowed)
        {
         Print("OneClickGridPONG PONG: breakeven-lock price too close for #", ticket);
         return;
        }

      bool sent = trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
      uint retcode = trade.ResultRetcode();
      if(!sent || (retcode != TRADE_RETCODE_DONE && retcode != TRADE_RETCODE_DONE_PARTIAL))
         Print("OneClickGridPONG PONG: breakeven-lock modify failed #", ticket, " | ", trade.ResultRetcodeDescription());
      else
         Print("OneClickGridPONG PONG: locked #", ticket, " SL at ", DoubleToString(newSL, _Digits),
               " (entry ", DoubleToString(entry, _Digits), " +", DoubleToString(PongLockPrice(), _Digits), ")");
      return;
     }

   // Not armed yet - has price reversed back through this position's own
   // entry, meaning it missed the breakeven-lock window? A plain "bid <=
   // entry" is true the INSTANT a Buy Stop fills (bid = ask - spread at
   // that moment, and entry is approximately ask), which would fire this
   // on every single fill regardless of any real reversal. Requiring the
   // adverse move to clear the live spread by a tick screens that out.
   double spread = ask - bid;
   bool reversedThroughEntry = (direction == 1)
      ? (bid <= entry - spread - g_tickSize)
      : (ask >= entry + spread + g_tickSize);
   if(!reversedThroughEntry)
      return;

   if(PongTagExistsForOrigin(basket, "M#", ticket))
      return; // already mirrored this exact position once

   int mirrorDirection = -direction;
   string mirrorComment = PongMirrorTag(basket.rootOrderTicket, ticket);
   PlacePendingAtPrice(mirrorDirection, entry, lot, mirrorComment);
  }

//+------------------------------------------------------------------+
//| PONG step 4. Once a mirror (tagged M#) has itself filled into a       |
//| position, wait for price to return to the manual root's own entry     |
//| price - and for that root position to be profitable again - then open |
//| a new pending order there, in the root's own direction, same lot as   |
//| the mirror, chained via the R# tag. This new position is itself a     |
//| PONG-chain position, so it re-enters ManagePongForPosition's flow on  |
//| later ticks and can lock, or reverse and mirror again.                |
//+------------------------------------------------------------------+
void ManagePongReentry(const CloseBasket &basket, const ulong mirrorTicket)
  {
   if(!PositionSelectByTicket(mirrorTicket) || !PositionBelongsToBasket(basket))
      return;

   string mirrorComment = PositionGetString(POSITION_COMMENT);
   if(StringSubstr(mirrorComment, 0, 2) != "M#")
      return;

   double mirrorLot = PositionGetDouble(POSITION_VOLUME);

   if(PongTagExistsForOrigin(basket, "R#", mirrorTicket))
      return;

   if(basket.manualPositionId == 0 || !PositionSelectByTicket(basket.manualPositionId))
      return; // the manual root already closed; nothing left to return to

   double rootEntry = PositionGetDouble(POSITION_PRICE_OPEN);
   int rootDirection = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return;

   bool priceBackAtRoot = (rootDirection == 1) ? (bid >= rootEntry) : (ask <= rootEntry);
   if(!priceBackAtRoot)
      return;

   string reentryComment = PongReentryTag(basket.rootOrderTicket, mirrorTicket);
   PlacePendingAtPrice(rootDirection, rootEntry, mirrorLot, reentryComment);
  }

//+------------------------------------------------------------------+
//| Runs the PONG loop for every eligible position in one basket, once   |
//| per tick. Tickets are snapshotted first since PositionModify/OrderSend|
//| inside the loop can change PositionsTotal()/OrdersTotal() mid-scan.   |
//+------------------------------------------------------------------+
void ManagePongRecovery(const CloseBasket &basket)
  {
   ulong tickets[];
   ArrayResize(tickets, 0);
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionBelongsToBasket(basket))
         continue;
      int size = ArraySize(tickets);
      ArrayResize(tickets, size + 1);
      tickets[size] = ticket;
     }

   for(int i=0; i<ArraySize(tickets); i++)
      ManagePongForPosition(basket, tickets[i]);

   for(int i=0; i<ArraySize(tickets); i++)
     {
      if(!PositionSelectByTicket(tickets[i]))
         continue;
      if(StringSubstr(PositionGetString(POSITION_COMMENT), 0, 2) == "M#")
         ManagePongReentry(basket, tickets[i]);
     }
  }

//+------------------------------------------------------------------+
void ManageFormulaClose()
  {
   for(int b=ArraySize(g_closeBaskets)-1; b>=0; b--)
     {
      // Both latches are retried every tick until the basket is empty.
      if(g_closeBaskets[b].marketExitRequested || g_closeBaskets[b].protectionArmed)
        {
         if(g_closeBaskets[b].marketExitRequested)
            CloseBasketAtMarket(g_closeBaskets[b]);
         else
            ApplyBasketProtection(g_closeBaskets[b]);

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
         continue;

      // PONG recovery runs every tick regardless of the CASE 1/2 gate below,
      // since it manages individual positions rather than whole-basket exit
      // conditions.
      ManagePongRecovery(g_closeBaskets[b]);

      // The winning side is the profitable direction; k is the number of
      // losing positions currently held by the basket.
      int winningDirection = 0;
      if(buyProfit > 0.0 && sellProfit > 0.0)
         winningDirection = (buyProfit >= sellProfit) ? 1 : -1;
      else if(buyProfit > 0.0)
         winningDirection = 1;
      else if(sellProfit > 0.0)
         winningDirection = -1;
      if(winningDirection == 0)
         continue;

      int winnerCount = (winningDirection == 1) ? buyCount : sellCount;

      // MAIN GATE - the winning side must hold at least 2k+1 positions.
      if(InpUseRecoveryFormula && winnerCount < 2 * losingCount + 1)
         continue;

      // Both cases measure the move of the newest position on the winning
      // side, not of the basket as a whole.
      double lastWinnerOpenPrice;
      if(!GetLastWinnerOpenPrice(g_closeBaskets[b], winningDirection, lastWinnerOpenPrice))
         continue;

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double lastWinnerMove = (winningDirection == 1)
         ? (bid - lastWinnerOpenPrice)
         : (lastWinnerOpenPrice - ask);

      // CASE 2 - the basket still carries a losing position. Once the last
      // winner has moved past the exit distance the whole basket is closed
      // at market, regardless of net P/L.
      if(losingCount > 0)
        {
         if(lastWinnerMove <= LossExitMovePrice())
            continue;

         Print("OneClickGridPONG: CASE 2 market exit #", g_closeBaskets[b].rootOrderTicket,
               " | Buy=", buyCount, " Sell=", sellCount,
               " | winners=", winnerCount, " k=", losingCount,
               " | last winner=", DoubleToString(lastWinnerOpenPrice, _Digits),
               " moved ", DoubleToString(lastWinnerMove, _Digits),
               " | net=", DoubleToString(netProfit, 2));
         g_closeBaskets[b].marketExitRequested = true;
         SavePersistentState();
         CloseBasketAtMarket(g_closeBaskets[b]);
         continue;
        }

      // CASE 1 - no losing position (for example 3 winners and 0 losers).
      // The last winner's move arms a locked exit at the shorter
      // profit-lock distance from that position's entry price.
      if(winnerCount < InpConsecutiveWinners ||
         lastWinnerMove <= WinnerMovePrice() ||
         netProfit <= InpCloseMinProfitMoney)
         continue;

      double rawProtectionPrice = lastWinnerOpenPrice + winningDirection * ProfitLockPrice();
      double protectionPrice = NormalizePriceForDirection(rawProtectionPrice, -winningDirection);

      // The market must be strictly beyond the locked line before it can
      // become the basket's protected exit.
      bool marketBeyondProtection = (winningDirection == 1)
         ? (bid > protectionPrice)
         : (ask < protectionPrice);
      if(!marketBeyondProtection)
         continue;

      Print("OneClickGridPONG: CASE 1 profit lock armed #", g_closeBaskets[b].rootOrderTicket,
            " | Buy=", buyCount, " Sell=", sellCount,
            " | winners=", winnerCount, " k=0",
            " | last winner=", DoubleToString(lastWinnerOpenPrice, _Digits),
            " moved ", DoubleToString(lastWinnerMove, _Digits),
            " | locked exit=", DoubleToString(protectionPrice, _Digits),
            " | net=", DoubleToString(netProfit, 2));
      g_closeBaskets[b].protectionArmed = true;
      g_closeBaskets[b].protectionDirection = winningDirection;
      g_closeBaskets[b].protectionPrice = protectionPrice;
      SavePersistentState();
      ApplyBasketProtection(g_closeBaskets[b]);
     }
  }
//+------------------------------------------------------------------+
