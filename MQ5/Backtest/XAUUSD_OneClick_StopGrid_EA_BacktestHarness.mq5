//+------------------------------------------------------------------+
//|                         XAUUSD_OneClick_StopGrid_EA.mq5           |
//|  Builds a two-sided pending-stop grid from one manual market     |
//|  entry. Portfolio-close rules are managed separately.            |
//+------------------------------------------------------------------+
#property copyright "Custom EA - One Click Stop Grid (BACKTEST HARNESS - not for live use)"
#property version   "1.43"
#property strict

#include <Trade/Trade.mqh>

CTrade trade;

#define MAX_PROCESSED_MANUAL_ORDERS 256
#define MAX_GRID_LEVELS_PER_SIDE    32
#define MAX_TRACKED_BASKETS         64

input group "=== DEBUG HARNESS (backtest only) ==="
input bool     InpDebugAutoEntry       = true;    // Simulate a manual market entry (Magic 0) whenever no basket is running
input double   InpDebugManualLot       = 0.02;    // Lot size of each simulated manual entry
input int      InpDebugCooldownBars    = 20;      // Bars to wait after a basket empties before the next simulated entry
input int      InpDebugDirectionMode   = 0;       // 0 = alternate Buy/Sell, 1 = always Buy, 2 = always Sell

input group "=== Opening Grid ==="
input int      InpOrdersPerSide       = 5;       // Total levels per side; the manual entry counts as level 1 on its side
input int      InpPriceStepCents       = 200;     // Grid distance in price cents; 200 = 2.000 (4000 -> 4002)
input double   InpFixedLotUnit         = 0.01;    // Fixed lot unit for level >= 2; lot = (2*level-1) * this, e.g. 0.01 -> 0.03, 0.05, 0.07, 0.09, ...

input group "=== Optional SL / TP (price distance) ==="
input double   InpStopLossDistance     = 0.0;     // 0 = no SL; otherwise distance from each pending entry price
input double   InpTakeProfitDistance   = 0.0;     // 0 = no TP; otherwise distance from each pending entry price

input group "=== Basket Exit Rules ==="
input bool     InpUseFormulaClose       = true;    // Master switch for every basket exit rule
input bool     InpUseRecoveryFormula    = true;    // SAFETY BREAKER gate: winning side count >= 2 * losing count + 1
input int      InpTrailArmCents         = 200;     // Clean trailing distance and pre-cut ladder arm distance in price cents; 200 = 2.000
input int      InpRecoverySLArmCents    = 130;     // Arm the fixed recovery SL after price passes that SL by 1.300
input int      InpPostCutGraceCents     = 0;       // 0 = disabled; otherwise widen the survivor's protection floor to (grid step + this) behind the cut anchor, set once right after WINNER CUT clears its losing side
input double   InpProtectSpreadBuffer   = 0.050;   // Fixed cushion added to every trailing SL step, in price units
input int      InpWinnerCutCount        = 3;       // WINNER CUT: 0 = disabled; otherwise close the losing side (positions + pendings) once the winning side reaches this many positions
input int      InpCleanTrailMinPositions = 3;      // Mode 1 (clean trail): winning-side position count needed, with the opposite side still empty, before all remaining pendings are cancelled and the basket switches to pure trailing
input int      InpMaxLosersBeforeCut    = 2;       // LOSER CUT: 0 = disabled; otherwise close everything once one side holds this many POSITIONS (P/L ignored) and the newest is passed by the distance below
input int      InpLoserCutMoveCents     = 165;     // LOSER CUT adverse move against the newest entry on that side, in price cents; 165 = 1.650

input group "=== Execution Safety ==="
input ulong    InpMagicNumber          = 20260904;
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
// Flushing global variables is a disk write, and the trailing line moves on
// almost every tick of a trend. Routine line updates are therefore written
// but not forced out; every latched decision still flushes immediately.
#define STATE_FLUSH_INTERVAL_MSC 1000
ulong  g_lastStateFlushMsc = 0;
bool   g_basketTaggingBroken = false;

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
   bool   cleanTrailActive;    // clean trend: retire all pending orders and trail price
   bool   recoverySLArmed;     // fixed post-cut SL has reached its arming threshold
   bool   postCutGraceArmed;   // the post-cut grace baseline has been captured for this cut
   double postCutGraceBaselineEntry; // previousEntry at the moment grace was captured; unchanged = grace floor still applies
   double retainedProtectionPrice; // pre-recovery broker line may still execute
   int    retainedProtectionDirection;
  };
CloseBasket g_closeBaskets[];

// --- DEBUG HARNESS state ---
datetime g_debugCooldownUntilBar = 0;
int      g_debugNextDirection = 1;

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
      InpTrailArmCents <= 0 || InpRecoverySLArmCents <= 0 ||
      InpRecoverySLArmCents >= InpPriceStepCents ||
      InpPostCutGraceCents < 0 ||
      InpProtectSpreadBuffer < 0.0 ||
      InpWinnerCutCount < 0 ||
      InpCleanTrailMinPositions < 2 || InpCleanTrailMinPositions > InpOrdersPerSide ||
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
         "; clean baskets retire all pending orders and then trail price by this distance");
   Print("OneClickGrid: CLEAN TRAIL = once the winning side reaches ", InpCleanTrailMinPositions,
         " positions with the opposite side still empty, cancel every remaining pending order ",
         "on both sides and switch to pure trailing - any levels beyond that count never get the chance to fill");
   Print("OneClickGrid: recovery SL = cut anchor + direction * (k-1) grid steps; ",
         "the survivor trails on the ordinary ladder alone until price reaches that level, ",
         "then price-following joins in; arm after price passes SL by ",
         DoubleToString(InpRecoverySLArmCents / 100.0, _Digits), "; trailing stays active and never loosens this floor");
   Print("OneClickGrid: WINNER CUT = ", InpWinnerCutCount > 0
         ? StringFormat("once the winning side reaches %d positions, close the losing side (positions + pendings) at market and trail the survivor with a delayed recovery SL floor",
                        InpWinnerCutCount)
         : "disabled");
   Print("OneClickGrid: WINNER CUT BUDGET = after the cut, the surviving side may extend ",
         "k grid steps past its entry at cut time (k = losers banked at cut) before ",
         "the whole basket is closed at market as a backstop");
   Print("OneClickGrid: POST-CUT GRACE = ", InpPostCutGraceCents > 0
         ? StringFormat("once the cut side clears, widen the survivor's starting protection floor to grid step + %s behind the cut anchor (once per cut; ordinary trailing only tightens it from there)",
                        DoubleToString(InpPostCutGraceCents / 100.0, _Digits))
         : "disabled - the survivor's post-cut floor is the ordinary one-grid-step ladder");
   if(InpUseRecoveryFormula)
      Print("OneClickGrid: SAFETY BREAKER = market-close the basket once k > ",
            (int)((InpOrdersPerSide - 1) / 2),
            " losing positions, since 2k+1 can no longer be satisfied within ",
            InpOrdersPerSide, " levels/side");
   Print("OneClickGrid: MARGIN GUARD = ", InpMinMarginLevelPercent > 0.0
         ? StringFormat("reject a new grid whose fully filled levels would leave margin level below %s%%",
                        DoubleToString(InpMinMarginLevelPercent, 2))
         : "disabled - grid creation ignores account margin entirely");
   Print("OneClickGrid: LOSER CUT = ", InpMaxLosersBeforeCut > 0
         ? StringFormat("close everything once one side holds %d positions and price runs %s against the newest of them",
                        InpMaxLosersBeforeCut, DoubleToString(LoserCutMovePrice(), _Digits))
         : "disabled");
   Print("OneClickGrid: MANUAL ENTRY FILTER = lot ",
         InpMinManualLot > 0.0 ? DoubleToString(InpMinManualLot, 8) : "any",
         " .. ", InpMaxManualLot > 0.0 ? DoubleToString(InpMaxManualLot, 8) : "any",
         " | concurrent baskets ",
         InpMaxConcurrentBaskets > 0 ? IntegerToString(InpMaxConcurrentBaskets) : "unlimited");

   // Retries for decisions already taken must not depend on the next tick.
   EventSetTimer(1);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0)
      return;

   ProcessProtectionExitDeal(trans.deal);
   ProcessManualEntryDeal(trans.deal);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   ProcessPendingGrids();
   PruneClosedBaskets();
   if(InpUseFormulaClose)
      ManageFormulaClose();
   DebugHarnessMaybeOpenManualEntry();
  }

//+------------------------------------------------------------------+
// DEBUG HARNESS ONLY. Places one market order with Magic 0 - exactly what
// the production EA treats as a manual one-click entry - whenever nothing
// is currently running and the cooldown has elapsed, so the Strategy
// Tester exercises the real ProcessManualEntryDeal -> grid -> exit path
// repeatedly across the test range instead of doing nothing at all.
void DebugHarnessMaybeOpenManualEntry()
  {
   if(!InpDebugAutoEntry)
      return;
   if(ArraySize(g_closeBaskets) > 0 || ArraySize(g_pendingGrids) > 0)
      return;

   // A simulated entry the production EA never adopted (its grid attempt
   // was abandoned - spread, margin, or a market-closed reject that outran
   // the retry window) leaves a stray Magic-0 position with nothing
   // managing it, exactly as an unhedged manual position would in reality.
   // Left alone it would pin the rest of the test at one static position,
   // so the harness plays the role of the human noticing and closing it.
   DebugHarnessCloseStrayPositions();

   if(TimeCurrent() < g_debugCooldownUntilBar)
      return;
   if(PositionsTotal() > 0 || OrdersTotal() > 0)
      return;   // a basket-managed position/order; wait for it to clear

   int direction;
   if(InpDebugDirectionMode == 1)
      direction = 1;
   else if(InpDebugDirectionMode == 2)
      direction = -1;
   else
     {
      direction = g_debugNextDirection;
      g_debugNextDirection = -g_debugNextDirection;
     }

   // Deliberately a plain, unmanaged CTrade call at Magic 0 - the same
   // footprint a human clicking Buy/Sell in the terminal leaves.
   CTrade debugTrade;
   debugTrade.SetExpertMagicNumber(0);
   debugTrade.SetDeviationInPoints(InpSlippagePoints);
   debugTrade.SetTypeFillingBySymbol(_Symbol);
   bool sent = (direction == 1) ? debugTrade.Buy(InpDebugManualLot) : debugTrade.Sell(InpDebugManualLot);
   if(!sent)
     {
      Print("DEBUG HARNESS: simulated manual entry failed | ", debugTrade.ResultRetcodeDescription());
      return;
     }

   Print("DEBUG HARNESS: simulated manual ", (direction == 1) ? "Buy" : "Sell",
         " ", DoubleToString(InpDebugManualLot, 2), " lot to seed the next basket");
   g_debugCooldownUntilBar = (datetime)((long)TimeCurrent() + (long)InpDebugCooldownBars * PeriodSeconds());
  }

//+------------------------------------------------------------------+
// DEBUG HARNESS ONLY. Closes any Magic-0 position no basket is tracking -
// an abandoned grid attempt, or one left over from a symbol whose trading
// mode closed mid-retry - so a single unmanaged entry cannot stall every
// later cycle of the test.
void DebugHarnessCloseStrayPositions()
  {
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != 0)
         continue;

      ulong positionId = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      bool tracked = false;
      for(int b=0; b<ArraySize(g_closeBaskets); b++)
         if(g_closeBaskets[b].manualPositionId == positionId)
           {
            tracked = true;
            break;
           }
      if(tracked)
         continue;

      CTrade debugTrade;
      debugTrade.SetExpertMagicNumber(0);
      debugTrade.SetDeviationInPoints(InpSlippagePoints);
      debugTrade.SetTypeFillingBySymbol(_Symbol);
      if(!debugTrade.PositionClose(ticket, InpSlippagePoints))
         Print("DEBUG HARNESS: could not close stray position #", ticket,
               " | ", debugTrade.ResultRetcodeDescription());
      else
         Print("DEBUG HARNESS: closed stray unmanaged position #", ticket);
     }
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_statePrefix != "")
      SavePersistentState();
  }

//+------------------------------------------------------------------+
// Retries only. Everything that has to READ the market - trailing, both
// cuts, the safety breaker - stays on the tick path, where the quote that
// drives the decision is fresh; a timer firing into a dead feed would
// otherwise re-decide on the last quote before the gap and close into a
// market nobody can see. What belongs here is a decision already taken: a
// settled basket exit, or a WINNER CUT whose side-close never completed.
// Both only need another attempt, and both may wait a long time for the
// next tick to hand them one.
void OnTimer()
  {
   if(!InpUseFormulaClose)
      return;

   for(int b=ArraySize(g_closeBaskets)-1; b>=0; b--)
     {
      if(g_closeBaskets[b].marketExitRequested)
        {
         CloseBasketAtMarket(g_closeBaskets[b]);
         if(!BasketHasOpenState(g_closeBaskets[b]))
           {
            ArrayRemove(g_closeBaskets, b, 1);
            SavePersistentState();
           }
         else
            ApplyFailsafeStop(g_closeBaskets[b]);
         continue;
        }

      int cutDirection = g_closeBaskets[b].winnerCutDirection;
      if(cutDirection != 0 && SideHasOpenState(g_closeBaskets[b], -cutDirection))
        {
         CloseSideAtMarket(g_closeBaskets[b], -cutDirection);
         if(SideHasOpenState(g_closeBaskets[b], -cutDirection))
            ApplyFailsafeStop(g_closeBaskets[b], -cutDirection);
        }
     }
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

   if(!AddCloseBasket(manualOrderTicket, manualPositionId, manualTime))
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
// Every basket lookup in this EA - ownership, discovery after a restart,
// attributing a broker SL/TP exit - runs through the order comment, so a
// broker that rewrites or truncates it does not degrade the EA, it blinds
// it. Read the tag back off the orders the broker actually accepted, while
// the tickets are still known and the whole grid can still be withdrawn.
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
   g_closeBaskets[size].cleanTrailActive = false;
   g_closeBaskets[size].recoverySLArmed = false;
   g_closeBaskets[size].postCutGraceArmed = false;
   g_closeBaskets[size].postCutGraceBaselineEntry = 0.0;
   g_closeBaskets[size].retainedProtectionPrice = 0.0;
   g_closeBaskets[size].retainedProtectionDirection = 0;
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
   string fields[] = {"RH","RL","MH","ML","T","E","L","Q","A","D","P","X","K","W","G","C","J","Y","Z","F","I"};
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
      WriteStateValue(BasketStateKey(i, "A"), g_closeBaskets[i].protectionArmed ? 1.0 : 0.0);
      WriteStateValue(BasketStateKey(i, "D"), (double)g_closeBaskets[i].protectionDirection);
      WriteStateValue(BasketStateKey(i, "P"), g_closeBaskets[i].protectionPrice);
      WriteStateValue(BasketStateKey(i, "X"), g_closeBaskets[i].marketExitRequested ? 1.0 : 0.0);
      WriteStateValue(BasketStateKey(i, "K"), (double)g_closeBaskets[i].bankedLoserCount);
      WriteStateValue(BasketStateKey(i, "W"), g_closeBaskets[i].winnerCutAnchorPrice);
      WriteStateValue(BasketStateKey(i, "G"), (double)g_closeBaskets[i].winnerCutDirection);
      WriteStateValue(BasketStateKey(i, "C"), g_closeBaskets[i].cleanTrailActive ? 1.0 : 0.0);
      WriteStateValue(BasketStateKey(i, "J"), g_closeBaskets[i].recoverySLArmed ? 1.0 : 0.0);
      WriteStateValue(BasketStateKey(i, "F"), g_closeBaskets[i].postCutGraceArmed ? 1.0 : 0.0);
      WriteStateValue(BasketStateKey(i, "I"), g_closeBaskets[i].postCutGraceBaselineEntry);
      WriteStateValue(BasketStateKey(i, "Y"), g_closeBaskets[i].retainedProtectionPrice);
      WriteStateValue(BasketStateKey(i, "Z"), (double)g_closeBaskets[i].retainedProtectionDirection);
     }
   for(int i=basketCount; i<oldBasketCount && i<MAX_TRACKED_BASKETS; i++)
      DeleteBasketStateSlot(i);

   WriteStateValue(g_statePrefix + ".BC", (double)basketCount);
   WriteStateValue(g_statePrefix + ".V", 7.0);

   // Every value above is already stored; the flush only forces it to disk.
   // Latched decisions ask for that immediately. A routine trailing step
   // does not, because it repeats on nearly every tick of a trend - it
   // accepts losing up to STATE_FLUSH_INTERVAL_MSC of line movement to an
   // unclean shutdown instead.
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
   if(stateVersion < 1 || stateVersion > 7)
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

      double cleanValue = 0.0, recoveryValue = 0.0;
      if(index >= 0 && stateVersion >= 6 && g_closeBaskets[index].protectionArmed)
        {
         if(ReadStateValue(BasketStateKey(i, "C"), cleanValue) && cleanValue > 0.5 &&
            g_closeBaskets[index].winnerCutDirection == 0)
            g_closeBaskets[index].cleanTrailActive = true;
         if(ReadStateValue(BasketStateKey(i, "J"), recoveryValue) && recoveryValue > 0.5 &&
            g_closeBaskets[index].winnerCutDirection != 0)
            g_closeBaskets[index].recoverySLArmed = true;
         double graceValue = 0.0, graceBaselineValue = 0.0;
         if(stateVersion >= 7 && ReadStateValue(BasketStateKey(i, "F"), graceValue) && graceValue > 0.5 &&
            ReadStateValue(BasketStateKey(i, "I"), graceBaselineValue) &&
            g_closeBaskets[index].winnerCutDirection != 0)
           {
            g_closeBaskets[index].postCutGraceArmed = true;
            g_closeBaskets[index].postCutGraceBaselineEntry = graceBaselineValue;
           }
         double retainedPrice = 0.0, retainedDirection = 0.0;
         if(g_closeBaskets[index].winnerCutDirection != 0 &&
            ReadStateValue(BasketStateKey(i, "Y"), retainedPrice) && retainedPrice > 0.0 &&
            ReadStateValue(BasketStateKey(i, "Z"), retainedDirection) &&
            (retainedDirection == 1.0 || retainedDirection == -1.0))
           {
            g_closeBaskets[index].retainedProtectionPrice = retainedPrice;
            g_closeBaskets[index].retainedProtectionDirection = (int)retainedDirection;
           }
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
// Side selection and loser counting are deliberately price-based rather
// than money-based. POSITION_PROFIT excludes commission, and adding
// POSITION_SWAP on top made a flat position read as "losing" after a few
// nights of negative gold swap - which mis-selected the winning side and
// tripped the SAFETY BREAKER on financing cost rather than on price.
// buyAdvance/sellAdvance are therefore each side's volume-weighted price
// displacement (price distance x lots): the same unit on both sides, so
// the larger-winner comparison is unchanged, but free of financing noise.
// netProfit stays real money (profit + swap) because no decision reads it -
// it is log output only, and still understates the true cost by commission.
void GetBasketStats(const CloseBasket &basket,
                    int &buyCount,
                    int &sellCount,
                    double &buyAdvance,
                    double &sellAdvance,
                    double &netProfit,
                    int &buyLosingCount,
                    int &sellLosingCount)
  {
   buyCount = 0;
   sellCount = 0;
   buyAdvance = 0.0;
   sellAdvance = 0.0;
   netProfit = 0.0;
   buyLosingCount = 0;
   sellLosingCount = 0;

   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionBelongsToBasket(basket))
         continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double entry   = PositionGetDouble(POSITION_PRICE_OPEN);
      double current = PositionGetDouble(POSITION_PRICE_CURRENT);
      double volume  = PositionGetDouble(POSITION_VOLUME);
      // POSITION_PRICE_CURRENT is already the side's own closing quote (Bid
      // for Buy, Ask for Sell), so a fresh fill still reads as adverse by the
      // spread exactly as it did when POSITION_PROFIT drove this decision.
      bool quoteUsable = (entry > 0.0 && current > 0.0 && volume > 0.0);
      double advance = quoteUsable
         ? ((type == POSITION_TYPE_BUY) ? (current - entry) : (entry - current))
         : 0.0;

      if(type == POSITION_TYPE_BUY)
        {
         buyCount++;
         buyAdvance += advance * volume;
         if(quoteUsable && advance < 0.0)
            buyLosingCount++;
        }
      else if(type == POSITION_TYPE_SELL)
        {
         sellCount++;
         sellAdvance += advance * volume;
         if(quoteUsable && advance < 0.0)
            sellLosingCount++;
        }

      netProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
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
bool ProtectionLineTouched(const CloseBasket &basket, const double bid, const double ask)
  {
   if(!basket.protectionArmed || basket.protectionPrice <= 0.0 || bid <= 0.0 || ask <= 0.0)
      return(false);
   if(basket.protectionDirection == 1)
      return(bid <= basket.protectionPrice);
   if(basket.protectionDirection == -1)
      return(ask >= basket.protectionPrice);
   return(false);
  }

//+------------------------------------------------------------------+
void RequestProtectionExit(CloseBasket &basket)
  {
   if(!basket.marketExitRequested)
     {
      basket.marketExitRequested = true;
      SavePersistentState();
      Print("OneClickGrid: protection triggered; closing entire basket #", basket.rootOrderTicket);
     }
   CloseBasketAtMarket(basket);
  }

//+------------------------------------------------------------------+
void ProcessProtectionExitDeal(const ulong dealTicket)
  {
   if(!InpUseFormulaClose || !HistoryDealSelect(dealTicket))
      return;
   if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol ||
      (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
      return;

   ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(dealTicket, DEAL_REASON);
   if(reason != DEAL_REASON_SL && reason != DEAL_REASON_TP)
      return;
   ENUM_DEAL_TYPE type = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
   if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
      return;
   int positionDirection = (type == DEAL_TYPE_SELL) ? 1 : -1;
   ulong positionId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   double exitLevel = HistoryDealGetDouble(dealTicket, reason == DEAL_REASON_SL ? DEAL_SL : DEAL_TP);
   if(positionId == 0 || exitLevel <= 0.0)
      return;

   // Closing comments may be replaced by [sl ...]/[tp ...]. Recover ownership
   // from the original opening order identified by POSITION_IDENTIFIER.
   ulong root = 0;
   if(HistoryOrderSelect(positionId) &&
      HistoryOrderGetString(positionId, ORDER_SYMBOL) == _Symbol &&
      (ulong)HistoryOrderGetInteger(positionId, ORDER_MAGIC) == InpMagicNumber)
      root = RootTicketFromComment(HistoryOrderGetString(positionId, ORDER_COMMENT));

   for(int b=ArraySize(g_closeBaskets)-1; b>=0; b--)
     {
      if(positionId != g_closeBaskets[b].manualPositionId &&
         (root == 0 || root != g_closeBaskets[b].rootOrderTicket))
         continue;
      if(!g_closeBaskets[b].protectionArmed)
         return;
      // Match the formula line, not a slipped execution price or an
      // unrelated optional stop that was already tighter than the line.
      bool currentMatch = ProtectionExitMatches(g_closeBaskets[b].protectionDirection,
         g_closeBaskets[b].protectionPrice, positionDirection, reason, exitLevel);
      bool retainedMatch = ProtectionExitMatches(g_closeBaskets[b].retainedProtectionDirection,
         g_closeBaskets[b].retainedProtectionPrice, positionDirection, reason, exitLevel);
      if(!currentMatch && !retainedMatch)
         return;
      RequestProtectionExit(g_closeBaskets[b]);
      return;
     }
  }

//+------------------------------------------------------------------+
bool ProtectionExitMatches(const int lineDirection, const double linePrice,
                           const int positionDirection, const ENUM_DEAL_REASON reason,
                           const double exitLevel)
  {
   if((lineDirection != 1 && lineDirection != -1) || linePrice <= 0.0)
      return(false);
   bool winningSide = (positionDirection == lineDirection);
   if((winningSide && reason != DEAL_REASON_SL) || (!winningSide && reason != DEAL_REASON_TP))
      return(false);
   return(MathAbs(exitLevel - linePrice) <= g_tickSize / 2.0);
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

      bool sent = trade.PositionClose(ticket, InpSlippagePoints);
      if(!sent || trade.ResultRetcode() != TRADE_RETCODE_DONE)
         Print("OneClickGrid: market close failed #", ticket, " | ", trade.ResultRetcodeDescription(),
               " | it is retried on the following ticks");
     }
  }

//+------------------------------------------------------------------+
// Deletes only one side's pending orders, leaving its open positions (and
// the other side entirely) untouched. Used both by CloseSideAtMarket (the
// losing side, immediately before closing its positions) and, on its own,
// to retire the WINNING side's own remaining pendings the moment WINNER
// CUT fires - otherwise those pendings stay live until the eventual
// WINNER CUT BUDGET/LOSER CUT exit, and a fill landing on the very tick
// that exit fires races DeleteBasketPendingOrders there: whichever the
// broker processes first decides whether that level opens a real position
// (closed moments later for little benefit) or the pending is simply
// cancelled - "reaches the stop and just cancels, never opens" is exactly
// that race lost. Retiring the winner's own pendings at cut time removes
// the race instead of resolving it differently.
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
// Closes only one side of a basket - its pending orders and its open
// positions - leaving the other side (and its own pendings) untouched.
// Used by WINNER CUT to bank the losing side while the winner keeps running.
void CloseSideAtMarket(const CloseBasket &basket, const int direction)
  {
   bool wantBuy = (direction == 1);

   // Pending orders go first so a fill cannot re-enter this side between
   // the individual position closes.
   DeleteSidePendingOrders(basket, direction);

   ENUM_POSITION_TYPE posType = wantBuy ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionBelongsToBasket(basket))
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != posType)
         continue;

      bool sent = trade.PositionClose(ticket, InpSlippagePoints);
      if(!sent || trade.ResultRetcode() != TRADE_RETCODE_DONE)
         Print("OneClickGrid: market close failed #", ticket, " | ", trade.ResultRetcodeDescription(),
               " | it is retried on the following ticks");
     }
  }

//+------------------------------------------------------------------+
// A settled market exit (marketExitRequested) or a WINNER CUT side-close
// can keep failing - broker FROZEN, no connection, requote rejection -
// while price keeps moving. The basket's own protection line (or, for a
// cut side, its usual lack of any SL at all) does not help there, so this
// is not a repeat of ApplyBasketProtection: it hugs current price as
// tightly as the broker's stop/freeze distance allows, purely to cap
// further loss while the market-close keeps retrying. It only ever
// tightens an existing stop, never loosens one, and is not trailing -
// once the exit finally goes through there is nothing left to protect.
// direction selects which side to touch: 0 (default) means every position
// in the basket, for a full-basket exit; 1 or -1 restricts it to just that
// side, for a WINNER CUT close that is only meant to remove the loser.
void ApplyFailsafeStop(const CloseBasket &basket, const int direction = 0)
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return;
   double stopsDistance = MathMax(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                                  SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL)) * _Point;

   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionBelongsToBasket(basket))
         continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if((direction == 1 && type != POSITION_TYPE_BUY) ||
         (direction == -1 && type != POSITION_TYPE_SELL))
         continue;
      double curSL = PositionGetDouble(POSITION_SL);
      double candidate;
      bool tighter;

      if(type == POSITION_TYPE_BUY)
        {
         candidate = NormalizePriceForDirection(bid - stopsDistance - g_tickSize, -1);
         tighter = (curSL <= 0.0) || (candidate > curSL);
         if(!tighter || bid - candidate <= stopsDistance)
            continue;
        }
      else
        {
         candidate = NormalizePriceForDirection(ask + stopsDistance + g_tickSize, 1);
         tighter = (curSL <= 0.0) || (candidate < curSL);
         if(!tighter || candidate - ask <= stopsDistance)
            continue;
        }

      bool sent = trade.PositionModify(ticket, candidate, PositionGetDouble(POSITION_TP));
      uint retcode = trade.ResultRetcode();
      if(!sent || (retcode != TRADE_RETCODE_DONE && retcode != TRADE_RETCODE_DONE_PARTIAL))
         Print("OneClickGrid: failsafe stop refresh failed #", ticket, " | ", trade.ResultRetcodeDescription());
      else
         Print("OneClickGrid: failsafe stop refreshed #", ticket, " -> ", DoubleToString(candidate, _Digits),
               " while the market exit keeps retrying");
     }
  }

//+------------------------------------------------------------------+
void ApplyBasketProtection(const CloseBasket &basket)
  {
   // Pending retirement is handled by the clean-trend or market-exit path.
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
            // Keep whichever TP is nearer the market, so an optional TP the
            // user configured is not pushed further away by the basket line.
            newTP = (curTP > 0.0) ? MathMax(curTP, basket.protectionPrice) : basket.protectionPrice;
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
            // Keep whichever TP is nearer the market, so an optional TP the
            // user configured is not pushed further away by the basket line.
            newTP = (curTP > 0.0) ? MathMin(curTP, basket.protectionPrice) : basket.protectionPrice;
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
//| Mixed baskets retain ladder protection until winner cut. Clean   |
//| and post-cut baskets also trail executable price toward the exit.|
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
   if(previousEntry <= 0.0 && !basket.cleanTrailActive && basket.winnerCutDirection == 0)
      return;

   double candidate = previousEntry > 0.0
      ? previousEntry + direction * InpProtectSpreadBuffer
      : ((direction == 1) ? bid : ask) - direction * TrailArmPrice();
   string layer = "base - previous entry + spread buffer";

   // Post-cut grace. The base candidate above sits about one grid step
   // behind the survivor's newest entry - tight enough that ordinary
   // intra-swing noise, not a real reversal, often closes the basket
   // moments after a cut that was otherwise the right call. The first time
   // this runs for a given cut, previousEntry is banked as the grace
   // baseline; for as long as nothing has actually changed since then (no
   // new fill has moved previousEntry), the base candidate is floored at
   // (grid step + InpPostCutGraceCents) behind the cut anchor instead. The
   // moment a new fill, the arm trigger below, or price-following earns a
   // genuinely tighter line, this stops applying on its own - it is a
   // comparison against a fixed floor re-evaluated every tick, not a
   // one-time override, so nothing here can undo progress made later.
   bool graceJustBaselined = false;
   bool graceFloorApplied  = false;
   if(basket.winnerCutDirection != 0 && InpPostCutGraceCents > 0)
     {
      if(!basket.postCutGraceArmed)
        {
         basket.postCutGraceArmed = true;
         basket.postCutGraceBaselineEntry = previousEntry;
         graceJustBaselined = true;
        }
      if(basket.winnerCutAnchorPrice > 0.0 &&
         MathAbs(previousEntry - basket.postCutGraceBaselineEntry) < g_tickSize / 2.0)
        {
         double graceFloor = basket.winnerCutAnchorPrice -
            direction * (GridStepPrice() + InpPostCutGraceCents / 100.0) + direction * InpProtectSpreadBuffer;
         if(IsBetterLine(candidate, graceFloor, direction))
           {
            candidate = graceFloor;
            layer = "post-cut grace floor";
            graceFloorApplied = true;
           }
        }
     }

   double armTrigger = newestEntry + direction * TrailArmPrice();
   bool armed = (direction == 1) ? (bid > armTrigger) : (ask < armTrigger);
   double armedCandidate = newestEntry + direction * InpProtectSpreadBuffer;
   if(armed && IsBetterLine(armedCandidate, candidate, direction))
     {
      candidate = armedCandidate;
      layer = "armed - newest entry + spread buffer";
     }

   // Clean baskets follow price from the moment they go clean. A post-cut
   // (K) basket instead trails exactly like an ordinary mixed basket -
   // ladder only, no price-following - until price actually reaches the
   // fixed recovery SL level itself (RecoveryStopPrice: anchor for k=1,
   // anchor + step for k=2, ...). Only from that point does price-following
   // take over, carrying the line the rest of the way to the arm distance
   // and beyond; before it, the K case must not trail any tighter than the
   // no-cut case would.
   bool priceFollowingActive = basket.cleanTrailActive;
   if(basket.winnerCutDirection != 0)
     {
      double recoveryStop = RecoveryStopPrice(basket);
      priceFollowingActive = (direction == 1) ? (bid >= recoveryStop) : (ask <= recoveryStop);
     }

   if(priceFollowingActive)
     {
      double priceCandidate = ((direction == 1) ? bid : ask) - direction * TrailArmPrice();
      if(IsBetterLine(priceCandidate, candidate, direction))
         candidate = priceCandidate;
      layer = "price-following trailing";
     }

   double line = NormalizePriceForDirection(candidate, -direction);

   // The tick that just banked the grace baseline, and on which the floor
   // actually had to replace the ordinary candidate, is the one deliberate
   // exception to the ratchet below: it is allowed to loosen a line
   // inherited from the mixed-basket phase (which protected a hedge this
   // cut just removed) out to the grace floor. Every other tick - including
   // every later one that still recomputes the same floor because nothing
   // has changed, and this same tick when grace made no difference to the
   // candidate - only ever improves on basket.protectionPrice, exactly as
   // before grace existed.
   bool graceBypassRatchet = graceJustBaselined && graceFloorApplied;
   if(!graceBypassRatchet && basket.protectionArmed && basket.protectionDirection == direction &&
      !IsBetterLine(line, basket.protectionPrice, direction))
      return;

   bool firstArming = !basket.protectionArmed;

   if(basket.winnerCutDirection != 0 && basket.protectionArmed &&
      basket.retainedProtectionDirection == 0)
     {
      basket.retainedProtectionPrice = basket.protectionPrice;
      basket.retainedProtectionDirection = basket.protectionDirection;
     }
   basket.protectionArmed = true;
   basket.protectionDirection = direction;
   basket.protectionPrice = line;

   // Persist only an actual line change (unchanged candidates returned above).
   // Exact recovery is needed to attribute broker SL/TP exits after restart,
   // so the first arming is forced to disk at once; later steps ride the
   // flush interval, since each one supersedes the last anyway.
   SavePersistentState(firstArming || graceBypassRatchet);

   Print("OneClickGrid: trailing line #", basket.rootOrderTicket,
         " -> ", DoubleToString(line, _Digits),
         " | ", layer,
         " | direction=", direction,
         " | newest entry=", DoubleToString(newestEntry, _Digits));
  }

//+------------------------------------------------------------------+
double RecoveryStopPrice(const CloseBasket &basket)
  {
   return(NormalizePriceForDirection(basket.winnerCutAnchorPrice +
      basket.winnerCutDirection * (basket.bankedLoserCount - 1) * GridStepPrice(),
      -basket.winnerCutDirection));
  }

//+------------------------------------------------------------------+
void UpdateRecoveryProtection(CloseBasket &basket)
  {
   if(basket.winnerCutDirection == 0 || basket.bankedLoserCount < 1 || basket.winnerCutAnchorPrice <= 0.0)
      return;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return;
   int direction = basket.winnerCutDirection;
   double stopPrice = RecoveryStopPrice(basket);
   double armPrice = stopPrice + direction * (InpRecoverySLArmCents / 100.0);
   bool reached = (direction == 1) ? (bid >= armPrice) : (ask <= armPrice);
   if(!basket.recoverySLArmed && !reached)
      return;
   if(basket.recoverySLArmed)
      return; // Milestone already applied; the caller keeps trailing independently.

   // Preserve any existing tighter protection rather than loosening stops.
   // The old line can still fill before a modification succeeds, or remain
   // installed as the other stop type after a direction change.
   if(basket.protectionArmed && basket.retainedProtectionDirection == 0)
     {
      basket.retainedProtectionPrice = basket.protectionPrice;
      basket.retainedProtectionDirection = basket.protectionDirection;
     }
   if(!basket.protectionArmed || basket.protectionDirection != direction ||
      IsBetterLine(stopPrice, basket.protectionPrice, direction))
      basket.protectionPrice = stopPrice;
   basket.protectionDirection = direction;
   basket.protectionArmed = true;
   basket.recoverySLArmed = true;
   SavePersistentState();
   Print("OneClickGrid: recovery SL armed #", basket.rootOrderTicket,
         " | SL=", DoubleToString(basket.protectionPrice, _Digits),
         " | trigger=", DoubleToString(armPrice, _Digits));
  }

//+------------------------------------------------------------------+
void ManageFormulaClose()
  {
   for(int b=ArraySize(g_closeBaskets)-1; b>=0; b--)
     {
      // A touched line becomes a persistent full-basket exit before any
      // direction change, side retry, or new trailing candidate is evaluated.
      if(ProtectionLineTouched(g_closeBaskets[b], SymbolInfoDouble(_Symbol, SYMBOL_BID),
                               SymbolInfoDouble(_Symbol, SYMBOL_ASK)))
        {
         RequestProtectionExit(g_closeBaskets[b]);
         continue;
        }
      // Retry a settled exit even if price has bounced away from the line.
      if(g_closeBaskets[b].marketExitRequested)
        {
         CloseBasketAtMarket(g_closeBaskets[b]);

         if(!BasketHasOpenState(g_closeBaskets[b]))
           {
            ArrayRemove(g_closeBaskets, b, 1);
            SavePersistentState();
           }
         else
            ApplyFailsafeStop(g_closeBaskets[b]);
         continue;
        }

      int buyCount, sellCount, buyLosingCount, sellLosingCount;
      double buyAdvance, sellAdvance, netProfit;
      GetBasketStats(g_closeBaskets[b], buyCount, sellCount, buyAdvance, sellAdvance, netProfit,
                     buyLosingCount, sellLosingCount);

      if(g_closeBaskets[b].cleanTrailActive)
         DeleteBasketPendingOrders(g_closeBaskets[b]);

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

      // LOSER CUT - pre-SL loss stop, evaluated independently per side.
      // An active clean trail or armed recovery SL supersedes this stop
      // for its managed direction. The opposite side is still checked.
      // Evaluated before winner-cut selection and
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
             // Once a side is under its requested SL mode, the legacy
             // distance stop must not pre-empt that side's own line. For a
             // winner-cut survivor that starts at the cut, not at the later
             // recovery-SL arming: the cut distance (below one grid step) is
             // by construction tighter than the ladder line one step back, so
             // leaving it live through the approach meant the survivor was
             // always market-closed before its own line could work - and
             // closing the survivor is closing the recovery the cut paid for.
             if((g_closeBaskets[b].cleanTrailActive &&
                 cutDirection == g_closeBaskets[b].protectionDirection) ||
                (g_closeBaskets[b].winnerCutDirection != 0 &&
                 cutDirection == g_closeBaskets[b].winnerCutDirection))
                continue;
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
      if(buyAdvance > 0.0 && sellAdvance > 0.0)
         winningDirection = (buyAdvance >= sellAdvance) ? 1 : -1;
      else if(buyAdvance > 0.0)
         winningDirection = 1;
      else if(sellAdvance > 0.0)
         winningDirection = -1;

      // Once WINNER CUT has fired, the direction it left running is settled
      // and stored, so it stays authoritative from then on. The profit-sign
      // heuristic above would read "no side is winning" during exactly the
      // pullback the budget and trailing exist to catch, and counting live
      // positions instead would flip to the wrong side whenever one of the
      // cut side's closes failed and left a position behind.
      if(g_closeBaskets[b].winnerCutDirection != 0)
         winningDirection = g_closeBaskets[b].winnerCutDirection;
      else if(g_closeBaskets[b].cleanTrailActive)
         winningDirection = g_closeBaskets[b].protectionDirection;

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
         // A failed pending delete on the winning side at cut time (broker
         // rejection, disconnect) is retried here too, alongside the cut
         // side, rather than left to fill and race the eventual budget exit.
         DeleteSidePendingOrders(g_closeBaskets[b], winningDirection);
         CloseSideAtMarket(g_closeBaskets[b], -winningDirection);
         GetBasketStats(g_closeBaskets[b], buyCount, sellCount, buyAdvance, sellAdvance, netProfit,
                        buyLosingCount, sellLosingCount);
         if(SideHasOpenState(g_closeBaskets[b], -winningDirection))
            ApplyFailsafeStop(g_closeBaskets[b], -winningDirection);
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
      if(InpWinnerCutCount > 0 && !g_closeBaskets[b].cleanTrailActive &&
         g_closeBaskets[b].winnerCutDirection == 0 &&
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
         // The winning side's own unfilled levels stop mattering the moment
         // the cut is decided: WINNER CUT BUDGET's exit target is already
         // fixed relative to the anchor above, so a new fill from here on
         // only adds a position that budget will very likely close again
         // within moments - or, if that exit and the fill land on the same
         // tick, races DeleteBasketPendingOrders there and can be cancelled
         // instead of filled. Retiring them now removes both outcomes.
         DeleteSidePendingOrders(g_closeBaskets[b], winningDirection);
         CloseSideAtMarket(g_closeBaskets[b], -winningDirection);
         GetBasketStats(g_closeBaskets[b], buyCount, sellCount, buyAdvance, sellAdvance, netProfit,
                        buyLosingCount, sellLosingCount);
         if(SideHasOpenState(g_closeBaskets[b], -winningDirection))
            ApplyFailsafeStop(g_closeBaskets[b], -winningDirection);
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

      // A winner cut whose side-close has not yet fully succeeded (retried
      // above but still holding a position or a pending) leaves real
      // exposure on what is supposed to be the dead side. Managing the
      // survivor as one-sided - trailing it, arming the recovery SL - before
      // that side is actually empty would protect it on the assumption of a
      // hedge that has not really been removed yet, so both stay dormant
      // until the side is confirmed clear (by the retry above, or by the
      // broker).
      bool winnerCutSideClear = (g_closeBaskets[b].winnerCutDirection == 0) ||
         !SideHasOpenState(g_closeBaskets[b], -winningDirection);

      if(g_closeBaskets[b].winnerCutDirection != 0)
        {
         if(winnerCutSideClear)
           {
            UpdateTrailingProtection(g_closeBaskets[b], winningDirection);
            UpdateRecoveryProtection(g_closeBaskets[b]);
           }
        }
      else
        {
         UpdateTrailingProtection(g_closeBaskets[b], winningDirection);
         int oppositeCount = (winningDirection == 1) ? sellCount : buyCount;
         if(!g_closeBaskets[b].cleanTrailActive && oppositeCount == 0 && winnerCount >= InpCleanTrailMinPositions &&
            g_closeBaskets[b].protectionArmed)
           {
            g_closeBaskets[b].cleanTrailActive = true;
            SavePersistentState();
            DeleteBasketPendingOrders(g_closeBaskets[b]);
            UpdateTrailingProtection(g_closeBaskets[b], winningDirection);
           }
        }

      if(ProtectionLineTouched(g_closeBaskets[b], SymbolInfoDouble(_Symbol, SYMBOL_BID),
                               SymbolInfoDouble(_Symbol, SYMBOL_ASK)))
        {
         RequestProtectionExit(g_closeBaskets[b]);
         continue;
        }
      if(g_closeBaskets[b].protectionArmed && winnerCutSideClear)
         ApplyBasketProtection(g_closeBaskets[b]);
     }
  }
//+------------------------------------------------------------------+
