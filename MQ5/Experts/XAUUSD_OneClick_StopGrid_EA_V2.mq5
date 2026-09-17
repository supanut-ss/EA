//+------------------------------------------------------------------+
//|                   XAUUSD_OneClick_StopGrid_EA_V2.mq5              |
//|  A ground-up, count-based exit design built on the OpenOnly       |
//|  opening path (XAUUSD_OneClick_StopGrid_EA_OpenOnly.mq5). Exit    |
//|  decisions read only how many positions have FILLED on each side  |
//|  (never money, never actual fill price) and compare against the   |
//|  grid's own THEORETICAL level prices (manualPrice +/- N*step) -   |
//|  deliberately simpler and more predictable than production's      |
//|  WINNER CUT / LOSER CUT / SAFETY BREAKER machinery, by design.    |
//|                                                                    |
//|  Rule A (independent, checked every tick, both directions checked  |
//|  separately): "losing" is decided by PRICE, not by which side      |
//|  happens to hold fewer fills - a side with MORE fills can still be |
//|  the one currently underwater if price pulled back hard enough.    |
//|  Once a side has InpLoserCutSideCount filled positions and its own |
//|  newest (highest-level) entry is underwater by InpLoserCutMoveCents|
//|  or more, the ENTIRE basket closes at market.                      |
//|                                                                    |
//|  Rule B (win/loss position-count lookup - win/loss decided by     |
//|  whichever side has strictly more filled positions; a tie does    |
//|  nothing): applies a fixed SL/TP to every open position on the    |
//|  WINNING side only. Prices are the grid's own level prices, never |
//|  the position's actual (slightly slipped) fill price.             |
//|    3-0: SL = level1 + buffer; TP = level5.                        |
//|         Once set, ALL remaining pending orders (both sides) are   |
//|         cancelled - this basket's final shape is exactly these 3  |
//|         positions, once.                                          |
//|    3-1: SL = level1 + buffer; TP = level4 + tpBuffer.             |
//|    3-2: SL = level1 + buffer; TP = level5 + tpBuffer. Once price  |
//|         reaches level4, SL moves to level2 and stays there.       |
//|    Everything else (1-0,1-1,1-2,2-0,2-1,2-2, and every            |
//|    combination not listed above, e.g. 4-x/5-x) does nothing -     |
//|    whatever SL/TP was last set (if any) is left exactly as is.    |
//|                                                                    |
//|  Forked from XAUUSD_OneClick_StopGrid_EA_OpenOnly.mq5; the three  |
//|  files (production, OpenOnly, this one) are fully independent     |
//|  from here - a fix in one is not automatically present elsewhere. |
//+------------------------------------------------------------------+
#property copyright "Custom EA - One Click Stop Grid (V2 - count-based exit design)"
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
input double   InpFixedLotUnit         = 0.01;    // Fixed lot unit for level >= 2; lot = (2*level-1) * this, e.g. 0.01 -> 0.03, 0.05, 0.07, 0.09, ...

input group "=== Optional SL / TP (price distance) ==="
input double   InpStopLossDistance     = 0.0;     // 0 = no SL; otherwise distance from each pending entry price
input double   InpTakeProfitDistance   = 0.0;     // 0 = no TP; otherwise distance from each pending entry price

input group "=== Basket Exit Rules (V2 - count based) ==="
input int      InpLoserCutSideCount    = 2;       // Rule A: close everything once one side holds this many filled positions...
input int      InpLoserCutMoveCents    = 150;     // ...and price runs this far past that side's newest (highest-level) entry
input int      InpSlBufferCents        = 20;      // Rule B: SL = winning side's level-1 price + this, in the protective direction
input int      InpTpBufferCents        = 100;     // Rule B: TP = a further winning-side level price + this, in the favorable direction
input int      InpRule31Level4CloseCents = 700;   // Rule B 3-1: level 4's own pending stays live, but once price runs this far past it, force it closed/cancelled together with the rest
input int      InpRule32Level5CloseCents = 900;   // Rule B 3-2: level 5's own pending stays live, but once price runs this far past it, force it closed/cancelled together with the rest

input group "=== Execution Safety ==="
input ulong    InpMagicNumber          = 20260906;  // Different again from OpenOnly (20260905) and production (20260904) - three independent state/ownership scopes  // Deliberately different from the production EA's default (20260904) so the two never share persisted state or basket ownership if both ever run on the same account/symbol
input ulong    InpFollowMagicNumber    = 0;         // Also treat this Magic Number's own market entries as a trigger, same as a manual (Magic 0) entry - 0 = follow manual entries only
input int      InpSlippagePoints       = 100;
input double   InpMaxSpreadPrice       = 0.20;    // 0 = disabled; otherwise reject a grid when spread exceeds this price distance
input int      InpExpirationHours      = 0;       // 0 = good-till-cancelled
input int      InpMaxOwnPendingOrders  = 100;     // Safety cap for this EA, symbol, and magic number
input double   InpMinMarginLevelPercent = 300.0;   // 0 = disabled; reject a grid whose full fill would leave margin level below this percent

input group "=== Manual Entry Filter ==="
input double   InpMinManualLot         = 0.0;     // 0 = disabled; ignore a manual entry smaller than this lot
input double   InpMaxManualLot         = 0.0;     // 0 = disabled; ignore a manual entry larger than this lot
input int      InpMaxConcurrentBaskets = 0;       // 0 = unlimited; ignore a new manual entry while this many baskets already run
input int      InpGridRetrySeconds     = 60;      // 0 = no retry; otherwise keep retrying a transiently rejected grid this long, while price stays within one grid step of the entry

ulong g_processedManualOrders[MAX_PROCESSED_MANUAL_ORDERS];
int   g_processedManualOrderCount = 0;
double g_tickSize = 0.0;
double g_volumeMin = 0.0;
double g_volumeMax = 0.0;
double g_volumeStep = 0.0;
string g_statePrefix = "";
// Flushing global variables is a disk write. Nothing here updates every
// tick the way the production EA's trailing line did, but the same
// throttle is kept for consistency and in case that changes later.
#define STATE_FLUSH_INTERVAL_MSC 1000
ulong  g_lastStateFlushMsc = 0;
bool   g_basketTaggingBroken = false;

// Every exit-only field (protection line, WINNER CUT budget, clean-trail
// latch, recovery SL, post-cut grace, market-exit latch) has been removed
// from this struct along with the code that used it. What remains is only
// what the OPENING path needs: identifying a basket, and knowing whether
// it still has anything open so the concurrent-basket cap and persisted
// state stay accurate.
struct CloseBasket
  {
   ulong rootOrderTicket;
   ulong manualPositionId;
   datetime startTime;
   double manualPrice;     // the manual entry's own fill price - the fixed origin every level price is computed from
   int    direction;       // the manual entry's own direction (1 = Buy, -1 = Sell)
   bool   rule30Applied;   // Rule B's 3-0 pending-cancellation has already run once for this basket
   bool   rule30SlArmed;   // Rule B's 3-0 SL-to-level3 move has already fired once for this basket
   bool   rule31Applied;   // Rule B's 3-1 losing-side pending-cancellation has already run once for this basket
   bool   rule32Armed;     // Rule B's 3-2 SL-to-level2 move has already fired once for this basket
   bool   rule32Applied;   // Rule B's 3-2 losing-side pending-cancellation has already run once for this basket
   bool   rule31Level4Failsafe;   // Rule B's 3-1 level-4 overflow failsafe has already fired once for this basket
   bool   rule32Level5Failsafe;   // Rule B's 3-2 level-5 overflow failsafe has already fired once for this basket
  };
CloseBasket g_closeBaskets[];

// A grid rejected for a passing reason - a spread spike, a momentary quote
// gap, margin briefly tied up - used to be dead for good, because the
// manual order was marked processed before any of those checks ran and
// nothing ever looked at it again. The request is queued here instead and
// retried on later ticks, bounded both in time and in how far price may
// walk away from the entry the grid is built around.
#define GRID_CREATED 0
#define GRID_RETRY   1
#define GRID_ABANDON 2

struct PendingGrid
  {
   ulong    manualOrderTicket;
   ulong    manualPositionId;
   double   manualPrice;
   double   manualLot;
   datetime manualTime;
   int      direction;
   ulong    expiryMsc;
  };
PendingGrid g_pendingGrids[];

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpOrdersPerSide < 1 || InpOrdersPerSide > MAX_GRID_LEVELS_PER_SIDE ||
      InpPriceStepCents <= 0 || InpFixedLotUnit <= 0.0 ||
      InpMaxOwnPendingOrders < 1 ||
      InpStopLossDistance < 0.0 || InpTakeProfitDistance < 0.0 ||
      InpMaxSpreadPrice < 0.0 ||
      InpMinMarginLevelPercent < 0.0 ||
      InpMinManualLot < 0.0 || InpMaxManualLot < 0.0 ||
      (InpMinManualLot > 0.0 && InpMaxManualLot > 0.0 && InpMinManualLot > InpMaxManualLot) ||
      InpMaxConcurrentBaskets < 0 ||
      InpGridRetrySeconds < 0 ||
      InpExpirationHours < 0)
     {
      Print("OneClickGrid: invalid input parameters");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpFollowMagicNumber != 0 && InpFollowMagicNumber == InpMagicNumber)
     {
      Print("OneClickGrid: InpFollowMagicNumber cannot equal InpMagicNumber - this EA's own grid ",
            "fills would then be mistaken for new manual entries, opening a runaway basket on top ",
            "of itself");
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

   Print("OneClickGrid: WARNING - this is the OPENING-ONLY build. No basket-close rule of any ",
         "kind runs: no trailing, no WINNER CUT, no LOSER CUT, no SAFETY BREAKER. A filled grid ",
         "has no automatic maximum-loss protection beyond InpStopLossDistance/InpTakeProfitDistance, ",
         "which are both 0 (disabled) by default. Do not run this unattended on a funded account.");
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
   SavePersistentState();

   Print("OneClickGrid: ready on ", _Symbol,
         " | opening levels/side=", InpOrdersPerSide,
         " | step=", DoubleToString(GridStepPrice(), _Digits),
         " (", InpPriceStepCents, " cents)",
         " | level 1 lot=manual entry lot on both sides, level>=2 lot=(2*level-1) x ",
         DoubleToString(InpFixedLotUnit, 8));
   Print("OneClickGrid: MARGIN GUARD = ", InpMinMarginLevelPercent > 0.0
         ? StringFormat("reject a new grid whose fully filled levels would leave margin level below %s%%",
                        DoubleToString(InpMinMarginLevelPercent, 2))
         : "disabled - grid creation ignores account margin entirely");
   Print("OneClickGrid: MANUAL ENTRY FILTER = lot ",
         InpMinManualLot > 0.0 ? DoubleToString(InpMinManualLot, 8) : "any",
         " .. ", InpMaxManualLot > 0.0 ? DoubleToString(InpMaxManualLot, 8) : "any",
         " | concurrent baskets ",
         InpMaxConcurrentBaskets > 0 ? IntegerToString(InpMaxConcurrentBaskets) : "unlimited");

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
   ProcessPendingGrids();
   PruneClosedBaskets();
   ManageExitRules();
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
   // Trigger on a true manual entry (Magic 0) or, if configured, on another
   // EA's own entries at InpFollowMagicNumber - either way this basket is
   // then built and owned exactly as if it were a manual click.
   ulong dealMagic = (ulong)HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
   if(dealMagic != 0 && dealMagic != InpFollowMagicNumber)
      return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_IN && entry != DEAL_ENTRY_INOUT)
      return;

   ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
   if(dealType != DEAL_TYPE_BUY && dealType != DEAL_TYPE_SELL)
      return;

   if(g_basketTaggingBroken)
      return;

   ulong manualOrderTicket = (ulong)HistoryDealGetInteger(dealTicket, DEAL_ORDER);
   if(manualOrderTicket == 0 || WasManualOrderProcessed(manualOrderTicket))
      return;

   // Mark first so our own trade transactions cannot cause re-entry. This
   // only records that the deal was seen; whether a grid was actually built
   // is the retry queue's business, not this flag's.
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

   if(!ManualEntryAccepted(manualLot))
      return;

   if(TryCreateGrid(manualOrderTicket, manualPositionId, manualPrice, manualLot,
                    manualTime, direction) == GRID_RETRY)
      QueuePendingGrid(manualOrderTicket, manualPositionId, manualPrice, manualLot,
                       manualTime, direction);
  }

//+------------------------------------------------------------------+
// One attempt at building the grid for a manual entry. The basket is only
// adopted once real orders exist to manage: a manual position the EA has
// claimed but placed nothing around is worse than an unclaimed one, since
// no exit rule acts on a lone position and the claim merely hides it from
// the user. Returns GRID_RETRY when the refusal was a passing market or
// account condition, GRID_ABANDON when retrying could not help.
int TryCreateGrid(const ulong manualOrderTicket,
                  const ulong manualPositionId,
                  const double manualPrice,
                  const double manualLot,
                  const datetime manualTime,
                  const int direction)
  {
   if(manualPositionId == 0)
     {
      Print("OneClickGrid: manual order #", manualOrderTicket,
            " has no position id; it remains user-owned and no grid will be created");
      return(GRID_ABANDON);
     }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
     {
      Print("OneClickGrid: no valid market quote; grid deferred for manual order #", manualOrderTicket);
      return(GRID_RETRY);
     }

   double spread = ask - bid;
   if(InpMaxSpreadPrice > 0.0 && spread > InpMaxSpreadPrice)
     {
      Print("OneClickGrid: spread ", DoubleToString(spread, _Digits),
            " exceeds limit ", DoubleToString(InpMaxSpreadPrice, _Digits),
            "; grid deferred for manual order #", manualOrderTicket);
      return(GRID_RETRY);
     }

   double projectedMarginLevel = 0.0, gridMargin = 0.0;
   if(!GridMarginIsAffordable(direction, manualPrice, manualLot, projectedMarginLevel, gridMargin))
     {
      Print("OneClickGrid: margin guard deferred the grid for manual order #", manualOrderTicket,
            " | fully filled it would need ", DoubleToString(gridMargin, 2), " ",
            AccountInfoString(ACCOUNT_CURRENCY), " more margin, leaving margin level ",
            DoubleToString(projectedMarginLevel, 2), "% against a ",
            DoubleToString(InpMinMarginLevelPercent, 2), "% floor");
      return(GRID_RETRY);
     }

   int requiredPending = (InpOrdersPerSide - 1) + InpOrdersPerSide;
   int availableSlots  = InpMaxOwnPendingOrders - CountOwnPendingOrders();
   if(availableSlots < requiredPending)
     {
      Print("OneClickGrid: safety cap allows only ", availableSlots,
            " new pending orders but this grid requires ", requiredPending,
            "; no partial grid was created");
      return(GRID_RETRY);
     }

   int placed = 0;
   ulong placedTickets[];
   ArrayResize(placedTickets, requiredPending);

   // The manual position is level 1: any lot the user opened with. Level 2
   // and beyond use a fixed lot progression independent of the manual lot
   // (odd multiples of InpFixedLotUnit: 3,5,7,9,... ).
   for(int level=2; level<=InpOrdersPerSide; level++)
     {
      double price = manualPrice + direction * (level - 1) * GridStepPrice();
      double lot   = LotForLevel(level, manualLot);
      ulong ticket = PlaceStopOrder(direction, level, manualOrderTicket, price, lot);
      if(ticket > 0)
        {
         placedTickets[placed] = ticket;
         placed++;
        }
     }

   // The opposite side's first pending order matches the manual entry's
   // lot exactly (level 1), then follows the same fixed lot progression.
   int oppositeDirection = -direction;
   for(int level=1; level<=InpOrdersPerSide; level++)
     {
      double price = manualPrice + oppositeDirection * level * GridStepPrice();
      double lot   = LotForLevel(level, manualLot);
      ulong ticket = PlaceStopOrder(oppositeDirection, level, manualOrderTicket, price, lot);
      if(ticket > 0)
        {
         placedTickets[placed] = ticket;
         placed++;
        }
     }

   if(placed == 0)
     {
      Print("OneClickGrid: the broker accepted no level of the grid for manual order #",
            manualOrderTicket, "; nothing was adopted and the attempt is deferred");
      return(GRID_RETRY);
     }

   if(!BasketTagsIntact(placedTickets, placed, BasketTag(manualOrderTicket)))
     {
      g_basketTaggingBroken = true;
      Print("OneClickGrid: this broker did not preserve the basket tag ",
            BasketTag(manualOrderTicket), " on the orders it accepted. Nothing can be ",
            "attributed to a basket without it, so the ", placed,
            " order(s) just placed are being withdrawn and no further grid will be created.");
      Alert("OneClickGrid: this broker rewrites order comments; grid creation is disabled.");
      WithdrawPlacedOrders(placedTickets, placed);
      return(GRID_ABANDON);
     }

   if(!AddCloseBasket(manualOrderTicket, manualPositionId, manualTime, manualPrice, direction))
     {
      Print("OneClickGrid: cannot adopt manual order #", manualOrderTicket,
            " safely; the ", placed, " order(s) just placed are being withdrawn and it remains user-owned");
      WithdrawPlacedOrders(placedTickets, placed);
      return(GRID_ABANDON);
     }
   SavePersistentState();

   Print("OneClickGrid: manual order #", manualOrderTicket,
         " created ", placed, "/", requiredPending, " opening pending orders");
   return(GRID_CREATED);
  }

//+------------------------------------------------------------------+
void WithdrawPlacedOrders(const ulong &tickets[], const int count)
  {
   for(int i=0; i<count; i++)
      if(!trade.OrderDelete(tickets[i]) || trade.ResultRetcode() != TRADE_RETCODE_DONE)
         Print("OneClickGrid: could not withdraw order #", tickets[i],
               " | ", trade.ResultRetcodeDescription(), " - remove it by hand");
  }

//+------------------------------------------------------------------+
void QueuePendingGrid(const ulong manualOrderTicket,
                      const ulong manualPositionId,
                      const double manualPrice,
                      const double manualLot,
                      const datetime manualTime,
                      const int direction)
  {
   if(InpGridRetrySeconds <= 0)
     {
      Print("OneClickGrid: grid retries are disabled; manual order #", manualOrderTicket,
            " stays open and unhedged");
      return;
     }

   int size = ArraySize(g_pendingGrids);
   if(size >= MAX_TRACKED_BASKETS)
     {
      Print("OneClickGrid: the grid retry queue is full; manual order #", manualOrderTicket,
            " stays open and unhedged");
      return;
     }

   ArrayResize(g_pendingGrids, size + 1);
   g_pendingGrids[size].manualOrderTicket = manualOrderTicket;
   g_pendingGrids[size].manualPositionId  = manualPositionId;
   g_pendingGrids[size].manualPrice       = manualPrice;
   g_pendingGrids[size].manualLot         = manualLot;
   g_pendingGrids[size].manualTime        = manualTime;
   g_pendingGrids[size].direction         = direction;
   g_pendingGrids[size].expiryMsc         = GetTickCount64() + (ulong)InpGridRetrySeconds * 1000;

   Print("OneClickGrid: grid creation for manual order #", manualOrderTicket,
         " is queued; it is retried for up to ", InpGridRetrySeconds,
         "s, or until price leaves ", DoubleToString(GridStepPrice(), _Digits),
         " of the entry");
  }

//+------------------------------------------------------------------+
// A queued grid stays worth retrying while the market has not walked away
// from the entry it is built around: past one grid step the levels would
// sit behind the market and be refused one by one, which produces a broken
// grid rather than a late one. The window bounds the wait on its own, so a
// quote the EA cannot read yet does not end the attempt.
bool PendingGridStillValid(const double manualPrice,
                           const int direction,
                           const ulong expiryMsc,
                           const double bid,
                           const double ask,
                           const ulong nowMsc)
  {
   if(nowMsc >= expiryMsc)
      return(false);
   if(bid <= 0.0 || ask <= 0.0)
      return(true);

   double reference = (direction == 1) ? ask : bid;
   return(MathAbs(reference - manualPrice) < GridStepPrice());
  }

//+------------------------------------------------------------------+
bool ManualPositionStillOpen(const ulong manualPositionId)
  {
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_IDENTIFIER) == manualPositionId)
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
void ProcessPendingGrids()
  {
   for(int i=ArraySize(g_pendingGrids)-1; i>=0; i--)
     {
      if(!ManualPositionStillOpen(g_pendingGrids[i].manualPositionId))
        {
         Print("OneClickGrid: queued grid for manual order #", g_pendingGrids[i].manualOrderTicket,
               " dropped; the manual position it would hedge is gone");
         ArrayRemove(g_pendingGrids, i, 1);
         continue;
        }

      if(!PendingGridStillValid(g_pendingGrids[i].manualPrice,
                                g_pendingGrids[i].direction,
                                g_pendingGrids[i].expiryMsc,
                                SymbolInfoDouble(_Symbol, SYMBOL_BID),
                                SymbolInfoDouble(_Symbol, SYMBOL_ASK),
                                GetTickCount64()))
        {
         Print("OneClickGrid: queued grid for manual order #", g_pendingGrids[i].manualOrderTicket,
               " abandoned; the retry window closed or price left the entry it was built around.",
               " The manual position stays open, unhedged and entirely user-owned.");
         ArrayRemove(g_pendingGrids, i, 1);
         continue;
        }

      if(TryCreateGrid(g_pendingGrids[i].manualOrderTicket,
                       g_pendingGrids[i].manualPositionId,
                       g_pendingGrids[i].manualPrice,
                       g_pendingGrids[i].manualLot,
                       g_pendingGrids[i].manualTime,
                       g_pendingGrids[i].direction) != GRID_RETRY)
         ArrayRemove(g_pendingGrids, i, 1);
     }
  }

//+------------------------------------------------------------------+
// Any market deal the user opens by hand on this symbol starts a grid, so
// the EA has no way of its own to tell a deliberate one-click entry from
// an unrelated manual trade. These filters are how the user draws that
// line; all three ship disabled, leaving the previous behaviour intact.
bool ManualEntryAccepted(const double manualLot)
  {
   if(InpMinManualLot > 0.0 && manualLot < InpMinManualLot - 1e-9)
     {
      Print("OneClickGrid: manual entry of ", DoubleToString(manualLot, 8),
            " lot is below the ", DoubleToString(InpMinManualLot, 8),
            " filter; it stays user-owned and no grid was created");
      return(false);
     }

   if(InpMaxManualLot > 0.0 && manualLot > InpMaxManualLot + 1e-9)
     {
      Print("OneClickGrid: manual entry of ", DoubleToString(manualLot, 8),
            " lot is above the ", DoubleToString(InpMaxManualLot, 8),
            " filter; it stays user-owned and no grid was created");
      return(false);
     }

   if(InpMaxConcurrentBaskets > 0 && ArraySize(g_closeBaskets) >= InpMaxConcurrentBaskets)
     {
      Print("OneClickGrid: ", ArraySize(g_closeBaskets), " basket(s) already run and the limit is ",
            InpMaxConcurrentBaskets, "; the manual entry stays user-owned and no grid was created");
      return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
// Every basket lookup in this EA - ownership, discovery after a restart -
// runs through the order comment, so a broker that rewrites or truncates
// it does not degrade the EA, it blinds it. Read the tag back off the
// orders the broker actually accepted, while the tickets are still known
// and the whole grid can still be withdrawn.
bool BasketTagsIntact(const ulong &tickets[], const int count, const string expectedTag)
  {
   for(int i=0; i<count; i++)
     {
      if(!OrderSelect(tickets[i]))
         continue;   // not readable yet is not proof of a stripped tag
      if(OrderGetString(ORDER_COMMENT) != expectedTag)
         return(false);
     }
   return(true);
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
ulong PlaceStopOrder(const int direction,
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
      return(0);
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
      return(0);
     }

   double sl = BuildStopLoss(entryPrice, direction);
   double tp = BuildTakeProfit(entryPrice, direction);
   if(!StopsAreValid(entryPrice, sl, tp, minDistance, direction))
     {
      Print("OneClickGrid: level ", level, " skipped; SL/TP violates the broker minimum stop distance");
      return(0);
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
      return(0);
     }

   ulong placedTicket = trade.ResultOrder();
   Print("OneClickGrid: placed ", side, " level ", level,
         " | ticket=", placedTicket,
         " lot=", DoubleToString(lot, VolumeDigits()),
         " price=", DoubleToString(entryPrice, _Digits));
   return(placedTicket);
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
// Margin one grid level would cost once it fills, or a negative value when
// the broker cannot price it. A level whose lot the broker would reject is
// skipped at placement time too, so it costs nothing and is not a failure
// here; an uncalculable one is, because a level that cannot be priced
// cannot be budgeted for either.
double LevelMargin(const int direction,
                   const double rawPrice,
                   const double requestedLot)
  {
   double lot = NormalizeVolumeDown(requestedLot);
   if(lot <= 0.0)
      return(0.0);

   double price = NormalizePriceForDirection(rawPrice, direction);
   ENUM_ORDER_TYPE type = (direction == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double margin = 0.0;
   ResetLastError();
   if(!OrderCalcMargin(type, _Symbol, lot, price, margin) || margin < 0.0)
     {
      Print("OneClickGrid: OrderCalcMargin failed at ", DoubleToString(price, _Digits),
            " for ", DoubleToString(lot, VolumeDigits()), " lot | error=", GetLastError());
      return(-1.0);
     }
   return(margin);
  }

//+------------------------------------------------------------------+
// Pre-trade margin guard. Every pending this grid is about to place can
// fill, and nothing downstream ever declines to add a position, so the
// only honest moment to ask whether the account can carry the whole grid
// is before any of it exists. The check is deliberately about capacity at
// full fill, not about the current balance: a grid that only fits while
// it is empty is the one that produces a stop-out mid-ladder.
bool GridMarginIsAffordable(const int direction,
                            const double manualPrice,
                            const double manualLot,
                            double &projectedLevel,
                            double &gridMargin)
  {
   projectedLevel = 0.0;
   gridMargin = 0.0;
   if(InpMinMarginLevelPercent <= 0.0)
      return(true);

   // Same side: levels 2..N. Level 1 is the manual position, already funded.
   double sameSide = 0.0;
   for(int level=2; level<=InpOrdersPerSide; level++)
     {
      double margin = LevelMargin(direction,
                                  manualPrice + direction * (level - 1) * GridStepPrice(),
                                  LotForLevel(level, manualLot));
      if(margin < 0.0)
         return(false);
      sameSide += margin;
     }

   // Opposite side: levels 1..N.
   int oppositeDirection = -direction;
   double oppositeSide = 0.0;
   for(int level=1; level<=InpOrdersPerSide; level++)
     {
      double margin = LevelMargin(oppositeDirection,
                                  manualPrice + oppositeDirection * level * GridStepPrice(),
                                  LotForLevel(level, manualLot));
      if(margin < 0.0)
         return(false);
      oppositeSide += margin;
     }

   // Where the symbol charges nothing for hedged volume, the two sides
   // never both cost margin at once, so the worst case is the dearer side
   // filling alone. Where hedged volume is charged, both sides genuinely
   // can be funded at the same time and have to be added up.
   double hedgedMargin = SymbolInfoDouble(_Symbol, SYMBOL_MARGIN_HEDGED);
   gridMargin = (hedgedMargin <= 0.0)
      ? MathMax(sameSide, oppositeSide)
      : sameSide + oppositeSide;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0.0)
     {
      Print("OneClickGrid: account equity is unavailable or not positive; the margin guard rejects the grid");
      return(false);
     }

   double projectedUsed = AccountInfoDouble(ACCOUNT_MARGIN) + gridMargin;
   if(projectedUsed <= 0.0)
      return(true);   // nothing would be committed

   projectedLevel = equity / projectedUsed * 100.0;
   return(projectedLevel >= InpMinMarginLevelPercent);
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
                    const datetime startTime,
                    const double manualPrice,
                    const int direction)
  {
   int index = FindCloseBasket(rootOrderTicket);
   if(index >= 0)
     {
      if(g_closeBaskets[index].manualPositionId == 0)
         g_closeBaskets[index].manualPositionId = manualPositionId;
      if(g_closeBaskets[index].startTime == 0)
         g_closeBaskets[index].startTime = startTime;
      if(g_closeBaskets[index].manualPrice == 0.0 && manualPrice > 0.0)
         g_closeBaskets[index].manualPrice = manualPrice;
      if(g_closeBaskets[index].direction == 0 && (direction == 1 || direction == -1))
         g_closeBaskets[index].direction = direction;
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
   g_closeBaskets[size].startTime = startTime;
   g_closeBaskets[size].manualPrice = manualPrice;
   g_closeBaskets[size].direction = direction;
   g_closeBaskets[size].rule30Applied = false;
   g_closeBaskets[size].rule30SlArmed = false;
   g_closeBaskets[size].rule31Applied = false;
   g_closeBaskets[size].rule32Armed = false;
   g_closeBaskets[size].rule32Applied = false;
   g_closeBaskets[size].rule31Level4Failsafe = false;
   g_closeBaskets[size].rule32Level5Failsafe = false;
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
// Recovers the two values every level-price computation in this file
// depends on, from the manual order's own history record - needed only
// when a restart rediscovers a basket from tagged terminal state rather
// than from ProcessManualEntryDeal, which already has both in hand.
bool ManualEntryInfoFromHistory(const ulong rootOrderTicket, double &manualPrice, int &direction)
  {
   manualPrice = 0.0;
   direction = 0;
   if(!HistoryOrderSelect(rootOrderTicket))
      return(false);

   manualPrice = HistoryOrderGetDouble(rootOrderTicket, ORDER_PRICE_OPEN);
   ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)HistoryOrderGetInteger(rootOrderTicket, ORDER_TYPE);
   if(orderType == ORDER_TYPE_BUY)
      direction = 1;
   else if(orderType == ORDER_TYPE_SELL)
      direction = -1;
   else
      return(false);

   return(manualPrice > 0.0);
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
         double manualPrice; int direction;
         ManualEntryInfoFromHistory(root, manualPrice, direction);
         bool discovered = (FindCloseBasket(root) < 0);
         AddCloseBasket(root, manualId, startTime, manualPrice, direction);
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
         double manualPrice; int direction;
         ManualEntryInfoFromHistory(root, manualPrice, direction);
         bool discovered = (FindCloseBasket(root) < 0);
         AddCloseBasket(root, manualId, startTime, manualPrice, direction);
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

   // The manual entry itself carries whichever Magic Number placed it - 0
   // for a true manual click, or InpFollowMagicNumber when this basket was
   // seeded by following another EA - never our own InpMagicNumber, so it
   // is identified by position, not by our comment tag.
   if((magic == 0 || (InpFollowMagicNumber != 0 && magic == InpFollowMagicNumber)) &&
      basket.manualPositionId > 0)
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
// ================== V2 EXIT RULES (count-based) =====================
// Every price used below is the grid's own THEORETICAL level price -
// basket.manualPrice offset by whole grid steps - never an actual fill
// price. Fills happen in strict level order (a pending stop cannot fill
// out of turn), so "the Nth filled position on a side" and "that side's
// level N" are the same thing; nothing here needs to read
// POSITION_PRICE_OPEN at all. This is what keeps the design simple and
// fully predictable: the whole rule table is pure arithmetic on
// (manualPrice, direction, step, filled count).
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
// The price of level N on the given side (direction), for this basket.
// N=1 is that side's own first fill: the manual entry itself when
// direction matches the basket's own direction, or the mirrored level-1
// stop one full grid step away on the opposite side - exactly how the
// opening path in this file already places them.
double LevelPrice(const CloseBasket &basket, const int direction, const int level)
  {
   double step = GridStepPrice();
   if(direction == basket.direction)
      return(basket.manualPrice + direction * (level - 1) * step);
   return(basket.manualPrice + direction * level * step);
  }

//+------------------------------------------------------------------+
int CountSidePositions(const CloseBasket &basket, const int direction)
  {
   ENUM_POSITION_TYPE posType = (direction == 1) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   int count = 0;
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionBelongsToBasket(basket))
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType)
         count++;
     }
   return(count);
  }

//+------------------------------------------------------------------+
void DeleteAllBasketPendings(const CloseBasket &basket)
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
// Deletes only one side's remaining pending orders, leaving the other
// side (and any of its own open positions) untouched.
void DeleteSidePendingOrders(const CloseBasket &basket, const int direction)
  {
   bool wantBuy = (direction == 1);
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
  }

//+------------------------------------------------------------------+
// Cancels one specific level's own pending order on one side, if it is
// still live - leaves every other pending, on either side, untouched.
// Returns true only once nothing matching is left live - a failed delete
// (requote, market closed) leaves a matching order behind and reports
// false, so the caller knows to retry rather than treat this as done.
bool DeleteBasketPendingAtLevel(const CloseBasket &basket, const int direction, const int level)
  {
   double levelPrice = LevelPrice(basket, direction, level);
   double tolerance = GridStepPrice() / 2.0;
   bool allClear = true;
   for(int i=OrdersTotal()-1; i>=0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderBelongsToBasket(basket))
         continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      bool isBuySide = (type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY_STOP_LIMIT);
      bool isSellSide = (type == ORDER_TYPE_SELL_STOP || type == ORDER_TYPE_SELL_STOP_LIMIT);
      if(direction == 1 && !isBuySide)
         continue;
      if(direction == -1 && !isSellSide)
         continue;
      if(MathAbs(OrderGetDouble(ORDER_PRICE_OPEN) - levelPrice) > tolerance)
         continue;

      if(!trade.OrderDelete(ticket) || trade.ResultRetcode() != TRADE_RETCODE_DONE)
        {
         Print("OneClickGrid: pending delete failed #", ticket, " | ", trade.ResultRetcodeDescription(),
               " | it is retried on the following ticks");
         allClear = false;
        }
     }
   return(allClear);
  }

//+------------------------------------------------------------------+
// Rule B's overflow failsafe for the one further level it still lets fill
// after the win/loss table locks in (level 4 for 3-1, level 5 for 3-2):
// once price has run extraCents past that level's own price, force it
// closed no matter its current state - cancels it if it is still an
// unfilled pending, or closes it at market if it has since filled into a
// live position. By that point the table's own SL/TP (set at a much
// tighter distance) should already have closed the official 3 winners, so
// in practice this only ever touches the extra, unprotected overflow
// fill(s). Returns true once the threshold is reached and acted on.
// Returns true only once the level is genuinely clear (no matching pending,
// no matching position) - a failed close/cancel returns false so the
// caller retries on the next tick instead of marking this permanently
// done while the position is still actually live.
bool EnforceLevelFailsafe(const CloseBasket &basket, const int direction, const int level, const double extraCents)
  {
   double levelPrice = LevelPrice(basket, direction, level);
   double reference = (direction == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                        : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   bool reached = (direction == 1) ? (reference >= levelPrice + extraCents)
                                    : (reference <= levelPrice - extraCents);
   if(!reached)
      return(false);

   bool pendingClear = DeleteBasketPendingAtLevel(basket, direction, level);

   bool positionsClear = true;
   ENUM_POSITION_TYPE posType = (direction == 1) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionBelongsToBasket(basket))
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != posType)
         continue;
      if(!trade.PositionClose(ticket, InpSlippagePoints) || trade.ResultRetcode() != TRADE_RETCODE_DONE)
        {
         Print("OneClickGrid: RULE B failsafe close failed #", ticket, " | ", trade.ResultRetcodeDescription(),
               " | it is retried on the following ticks");
         positionsClear = false;
        }
     }
   return(pendingClear && positionsClear);
  }

//+------------------------------------------------------------------+
// Rule A. Independent of Rule B and checked first, on EACH side separately
// (a side's own price-based loss has nothing to do with which side holds
// more fills): once a side has InpLoserCutSideCount filled positions AND
// its boundary entry - the level that is underwater exactly when that many
// of its positions are simultaneously underwater - has run InpLoserCutMoveCents
// against it, the whole basket - both sides, positions and pendings alike -
// closes at market. A failed close/delete is simply retried on the next
// tick, since the basket is not removed from tracking until
// PruneClosedBaskets finds it genuinely empty.
bool CheckAndApplyLoserCut(const CloseBasket &basket)
  {
   if(InpLoserCutSideCount <= 0)
      return(false);

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return(false);

   for(int d=0; d<2; d++)
     {
      int direction = (d == 0) ? 1 : -1;
      int count = CountSidePositions(basket, direction);
      if(count < InpLoserCutSideCount)
         continue;

      // Level prices on a side move monotonically with level number (each
      // further level is filled only after price crosses further in that
      // side's direction), so the boundary level below is the level that -
      // if IT is underwater - guarantees every level above it (the newer,
      // more extreme ones) is underwater too. That makes it the exact price
      // at which InpLoserCutSideCount positions are simultaneously losing,
      // unlike the side's newest entry alone, which can be underwater while
      // its own earlier (better-priced) fills are still in profit.
      int boundaryLevel = count - InpLoserCutSideCount + 1;
      double boundaryEntry = LevelPrice(basket, direction, boundaryLevel);
      double reference = (direction == 1) ? bid : ask;
      // Positive only when the boundary entry is actually underwater right
      // now (a buy is at a loss when bid < entry, a sell when ask > entry) -
      // so this one comparison both identifies the genuinely losing side and
      // measures how far, regardless of which side happens to hold more
      // total fills.
      double adverse = (direction == 1) ? (boundaryEntry - reference) : (reference - boundaryEntry);
      if(adverse < InpLoserCutMoveCents / 100.0)
         continue;

      Print("OneClickGrid: RULE A market exit #", basket.rootOrderTicket,
            " | side=", direction, " holds ", count, " >= ", InpLoserCutSideCount,
            " positions and is underwater | boundary entry (level ", boundaryLevel, ") ",
            DoubleToString(boundaryEntry, _Digits),
            " ran ", DoubleToString(adverse, _Digits),
            " against it (limit ", DoubleToString(InpLoserCutMoveCents / 100.0, _Digits), ")");

      DeleteAllBasketPendings(basket);
      for(int i=PositionsTotal()-1; i>=0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionBelongsToBasket(basket))
            continue;
         if(!trade.PositionClose(ticket, InpSlippagePoints) || trade.ResultRetcode() != TRADE_RETCODE_DONE)
            Print("OneClickGrid: market close failed #", ticket, " | ", trade.ResultRetcodeDescription(),
                  " | it is retried on the following ticks");
        }
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
void ApplySideSLTP(const CloseBasket &basket, const int direction, const double slPrice, const double tpPrice)
  {
   ENUM_POSITION_TYPE posType = (direction == 1) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   double normSl = NormalizePriceForDirection(slPrice, -direction);
   double normTp = NormalizePriceForDirection(tpPrice, direction);

   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionBelongsToBasket(basket))
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != posType)
         continue;

      double curSl = PositionGetDouble(POSITION_SL);
      double curTp = PositionGetDouble(POSITION_TP);
      if(MathAbs(curSl - normSl) < g_tickSize / 2.0 && MathAbs(curTp - normTp) < g_tickSize / 2.0)
         continue;

      bool sent = trade.PositionModify(ticket, normSl, normTp);
      uint retcode = trade.ResultRetcode();
      if(!sent || (retcode != TRADE_RETCODE_DONE && retcode != TRADE_RETCODE_DONE_PARTIAL))
         Print("OneClickGrid: RULE B SL/TP modify failed #", ticket, " | ", trade.ResultRetcodeDescription());
      else
         Print("OneClickGrid: RULE B set #", ticket, " -> SL=", DoubleToString(normSl, _Digits),
               " TP=", DoubleToString(normTp, _Digits));
     }
  }

//+------------------------------------------------------------------+
// Rule B. Decides win/loss by filled-position count alone: whichever side
// has strictly more is "winning" (a tie, including 0-0, does nothing).
// Only the four (winCount, loseCount) combinations in the table below
// have a defined action; everything else - including win counts of 4 or
// 5 and every loss count above 2 - deliberately does nothing and leaves
// whatever SL/TP a lower combination already set exactly as is.
void ApplyRuleB(CloseBasket &basket)
  {
   int buyCount = CountSidePositions(basket, 1);
   int sellCount = CountSidePositions(basket, -1);

   // These two failsafes run independently of the win/loss table below,
   // since the level they guard (4 for 3-1, 5 for 3-2) is deliberately left
   // free to keep filling after the table locks in - by the time either
   // threshold is reached, the winning side's count may already have moved
   // past what the table recognizes (e.g. 4, when the table only defines
   // exactly 3), which would otherwise leave that extra fill unprotected.
   if(buyCount > 0 || sellCount > 0)
     {
      int liveWinDirection = (buyCount >= sellCount) ? 1 : -1;
      if(basket.rule31Applied && !basket.rule31Level4Failsafe &&
         EnforceLevelFailsafe(basket, liveWinDirection, 4, InpRule31Level4CloseCents / 100.0))
        {
         Print("OneClickGrid: RULE B 3-1 level-4 failsafe #", basket.rootOrderTicket,
               " | price ran ", InpRule31Level4CloseCents, " cents past level 4 - forcing it closed with the rest");
         basket.rule31Level4Failsafe = true;
         SavePersistentState();
        }
      if(basket.rule32Applied && !basket.rule32Level5Failsafe &&
         EnforceLevelFailsafe(basket, liveWinDirection, 5, InpRule32Level5CloseCents / 100.0))
        {
         Print("OneClickGrid: RULE B 3-2 level-5 failsafe #", basket.rootOrderTicket,
               " | price ran ", InpRule32Level5CloseCents, " cents past level 5 - forcing it closed with the rest");
         basket.rule32Level5Failsafe = true;
         SavePersistentState();
        }
     }

   if(buyCount == sellCount)
      return;

   int winDirection = (buyCount > sellCount) ? 1 : -1;
   int winCount = MathMax(buyCount, sellCount);
   int loseCount = MathMin(buyCount, sellCount);

   double slBuffer = InpSlBufferCents / 100.0;
   double tpBuffer = InpTpBufferCents / 100.0;
   double sl, tp;
   bool matched = false;
   bool retirePendingsNow = false;
   bool retireLosingSideNow = false;
   bool retireLosingSideNow32 = false;

   if(winCount == 3 && loseCount == 0)
     {
      // 3-0: starting SL/TP bracket, set once - and at that same moment
      // the basket's shape is locked to exactly these 3 positions, since
      // no further level can ever fill once their pendings (both sides)
      // are gone. The SL still arms tighter afterward: once price runs
      // InpTpBufferCents past level3, it moves from level1+buffer to
      // level3 exactly, once, and holds there even if price retreats.
      sl = LevelPrice(basket, winDirection, 1) + winDirection * slBuffer;
      tp = LevelPrice(basket, winDirection, 5);
      matched = true;
      retirePendingsNow = !basket.rule30Applied;

      double level3 = LevelPrice(basket, winDirection, 3);
      double armTrigger = level3 + winDirection * tpBuffer;
      double armReference = (winDirection == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                                 : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      bool reachedArm = (winDirection == 1) ? (armReference >= armTrigger) : (armReference <= armTrigger);
      if(reachedArm && !basket.rule30SlArmed)
        {
         basket.rule30SlArmed = true;
         SavePersistentState();
        }
      if(basket.rule30SlArmed)
         sl = level3;
     }
   else if(winCount == 3 && loseCount == 1)
     {
      sl = LevelPrice(basket, winDirection, 1) + winDirection * slBuffer;
      tp = LevelPrice(basket, winDirection, 4) + winDirection * tpBuffer;
      matched = true;
      // The losing side's own remaining pendings are retired once SL/TP
      // is set, so it can never grow past its current 1 position.
      retireLosingSideNow = !basket.rule31Applied;
     }
   else if(winCount == 3 && loseCount == 2)
     {
      sl = LevelPrice(basket, winDirection, 1) + winDirection * slBuffer;
      tp = LevelPrice(basket, winDirection, 5) + winDirection * tpBuffer;
      matched = true;
      // Same as 3-1: the losing side's own remaining pendings are retired
      // once SL/TP is set, so it can never grow past its current 2
      // positions.
      retireLosingSideNow32 = !basket.rule32Applied;

      // Arm once price reaches level 4, then hold - never re-evaluated
      // back down if price retreats afterward.
      double level4 = LevelPrice(basket, winDirection, 4);
      double reference = (winDirection == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                              : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      bool reached4 = (winDirection == 1) ? (reference >= level4) : (reference <= level4);
      if(reached4 && !basket.rule32Armed)
        {
         basket.rule32Armed = true;
         SavePersistentState();
        }
      if(basket.rule32Armed)
         sl = LevelPrice(basket, winDirection, 2);
     }
   else
      return;   // unlisted combination: leave whatever was set before untouched

   if(!matched)
      return;

   ApplySideSLTP(basket, winDirection, sl, tp);

   // Cross-wire the losing side onto the SAME two price lines so the broker
   // closes both sides together the instant either one is touched: a price
   // move that fills the winning SL also fills the losing side's TP there,
   // and a move that fills the winning TP also fills the losing side's SL at
   // that level - no orphaned losing position survives the winning exit.
   if(loseCount > 0)
      ApplySideSLTP(basket, -winDirection, tp, sl);

   if(retirePendingsNow)
     {
      Print("OneClickGrid: RULE B 3-0 reached #", basket.rootOrderTicket,
            " | retiring every remaining pending order, both sides - this basket is now exactly ",
            winCount, " positions");
      DeleteAllBasketPendings(basket);
      basket.rule30Applied = true;
      SavePersistentState();
     }

   if(retireLosingSideNow)
     {
      Print("OneClickGrid: RULE B 3-1 reached #", basket.rootOrderTicket,
            " | retiring the losing side's remaining pending orders - that side is capped at ",
            loseCount, " position(s) - and cancelling the winning side's own level-5 pending, ",
            "leaving only level 4 free to still fill");
      DeleteSidePendingOrders(basket, -winDirection);
      DeleteBasketPendingAtLevel(basket, winDirection, 5);
      basket.rule31Applied = true;
      SavePersistentState();
     }

   if(retireLosingSideNow32)
     {
      Print("OneClickGrid: RULE B 3-2 reached #", basket.rootOrderTicket,
            " | retiring the losing side's remaining pending orders - that side is capped at ",
            loseCount, " position(s)");
      DeleteSidePendingOrders(basket, -winDirection);
      basket.rule32Applied = true;
      SavePersistentState();
     }
  }

//+------------------------------------------------------------------+
void ManageExitRules()
  {
   for(int b=ArraySize(g_closeBaskets)-1; b>=0; b--)
     {
      // Both sides can reach zero filled positions before their pendings
      // are cleared out - e.g. Rule B's cross-wired SL/TP closes the
      // winning and losing sides together, but a winning side that never
      // reached 3-0 keeps its own further-level pendings live throughout.
      // That is a 0-0 tie to Rule A/B (neither acts on it), so without this
      // it would sit there untouched, live, forever.
      if(CountSidePositions(g_closeBaskets[b], 1) == 0 && CountSidePositions(g_closeBaskets[b], -1) == 0)
        {
         if(BasketHasPendingOrders(g_closeBaskets[b]))
           {
            Print("OneClickGrid: basket #", g_closeBaskets[b].rootOrderTicket,
                  " has zero filled positions on both sides - retiring its remaining pending orders");
            DeleteAllBasketPendings(g_closeBaskets[b]);
           }
         continue;
        }
      if(CheckAndApplyLoserCut(g_closeBaskets[b]))
         continue;
      ApplyRuleB(g_closeBaskets[b]);
     }
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
   // "OCSGO" (not production's "OCSG") so this build's Global Variables
   // never collide with the production EA's, even by accident.
   return("OCSGO." + StringFormat("%08X", StateScopeHash()));
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
   string fields[] = {"RH","RL","MH","ML","T","P","N","R0","R1","R2","R3","R4","R5","R6"};
   for(int i=0; i<ArraySize(fields); i++)
      GlobalVariableDel(BasketStateKey(index, fields[i]));
  }

//+------------------------------------------------------------------+
void SavePersistentState(const bool forceFlush = true)
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
      WriteStateValue(BasketStateKey(i, "P"), g_closeBaskets[i].manualPrice);
      WriteStateValue(BasketStateKey(i, "N"), (double)g_closeBaskets[i].direction);
      WriteStateValue(BasketStateKey(i, "R0"), g_closeBaskets[i].rule30Applied ? 1.0 : 0.0);
      WriteStateValue(BasketStateKey(i, "R1"), g_closeBaskets[i].rule30SlArmed ? 1.0 : 0.0);
      WriteStateValue(BasketStateKey(i, "R2"), g_closeBaskets[i].rule32Armed ? 1.0 : 0.0);
      WriteStateValue(BasketStateKey(i, "R3"), g_closeBaskets[i].rule31Applied ? 1.0 : 0.0);
      WriteStateValue(BasketStateKey(i, "R4"), g_closeBaskets[i].rule32Applied ? 1.0 : 0.0);
      WriteStateValue(BasketStateKey(i, "R5"), g_closeBaskets[i].rule31Level4Failsafe ? 1.0 : 0.0);
      WriteStateValue(BasketStateKey(i, "R6"), g_closeBaskets[i].rule32Level5Failsafe ? 1.0 : 0.0);
     }
   for(int i=basketCount; i<oldBasketCount && i<MAX_TRACKED_BASKETS; i++)
      DeleteBasketStateSlot(i);

   WriteStateValue(g_statePrefix + ".BC", (double)basketCount);
   WriteStateValue(g_statePrefix + ".V", 1.0);

   ulong now = GetTickCount64();
   if(forceFlush || g_lastStateFlushMsc == 0 ||
      now - g_lastStateFlushMsc >= STATE_FLUSH_INTERVAL_MSC)
     {
      GlobalVariablesFlush();
      g_lastStateFlushMsc = now;
     }
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
   if(stateVersion != 1)
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
      double manualPriceValue = 0.0, directionValue = 0.0;
      if(!ReadStateUlong(BasketStateKey(i, "R"), root) || root == 0 ||
         !ReadStateUlong(BasketStateKey(i, "M"), manualId) ||
         !ReadStateValue(BasketStateKey(i, "T"), timeValue) ||
         !ReadStateValue(BasketStateKey(i, "P"), manualPriceValue) ||
         !ReadStateValue(BasketStateKey(i, "N"), directionValue))
        {
         Print("OneClickGrid: skipped incomplete saved basket slot ", i);
         continue;
        }

      int savedDirection = (int)MathRound(directionValue);
      if(!AddCloseBasket(root, manualId, (datetime)MathRound(timeValue), manualPriceValue, savedDirection))
         continue;

      int index = FindCloseBasket(root);
      if(index >= 0)
        {
         double r0Value = 0.0, r1Value = 0.0, r2Value = 0.0, r3Value = 0.0, r4Value = 0.0;
         double r5Value = 0.0, r6Value = 0.0;
         if(ReadStateValue(BasketStateKey(i, "R0"), r0Value) && r0Value > 0.5)
            g_closeBaskets[index].rule30Applied = true;
         if(ReadStateValue(BasketStateKey(i, "R1"), r1Value) && r1Value > 0.5)
            g_closeBaskets[index].rule30SlArmed = true;
         if(ReadStateValue(BasketStateKey(i, "R2"), r2Value) && r2Value > 0.5)
            g_closeBaskets[index].rule32Armed = true;
         if(ReadStateValue(BasketStateKey(i, "R3"), r3Value) && r3Value > 0.5)
            g_closeBaskets[index].rule31Applied = true;
         if(ReadStateValue(BasketStateKey(i, "R4"), r4Value) && r4Value > 0.5)
            g_closeBaskets[index].rule32Applied = true;
         if(ReadStateValue(BasketStateKey(i, "R5"), r5Value) && r5Value > 0.5)
            g_closeBaskets[index].rule31Level4Failsafe = true;
         if(ReadStateValue(BasketStateKey(i, "R6"), r6Value) && r6Value > 0.5)
            g_closeBaskets[index].rule32Level5Failsafe = true;
        }
     }
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
