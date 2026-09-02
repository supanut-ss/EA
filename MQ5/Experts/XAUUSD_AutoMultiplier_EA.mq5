//+------------------------------------------------------------------+
//|                                   XAUUSD_AutoMultiplier_EA.mq5    |
//|  Manual-entry auto-multiplier / grid manager - EA #4              |
//|                                                                    |
//|  This EA does NOT generate its own entry signal. It watches for a |
//|  position YOU open manually in the terminal (Magic = 0) on this   |
//|  chart's symbol and then:                                         |
//|                                                                    |
//|   1) Auto-multiply: immediately fires InpAutoAddCount further     |
//|      market orders in the SAME direction (default 4, so 1 manual  |
//|      + 4 auto = 5 total), each sized like the manual order unless |
//|      InpAutoOrderLot overrides it.                                |
//|   2) Fixed SL/TP, R:R 1:2: every order in the basket (manual +    |
//|      auto) gets its own SL = InpSL_Points and TP = InpTP_Points,  |
//|      measured from that order's own open price. Defaults are 5000 |
//|      / 10000 points = 5.00 / 10.00 on this 3-decimal gold feed -  |
//|      see the note above the inputs before changing broker.        |
//|   3) Two protection levels, each firing once per basket:          |
//|      LEVEL 1 - at InpBE_TriggerPoints (default 3000 = 3.00) every |
//|        still-open order has its SL moved to its own entry plus    |
//|        InpBE_LockPoints (default 120 = 0.12), which buys back the |
//|        commission/swap a stop parked exactly at entry would still |
//|        pay. Nothing is closed; the basket just stops being able   |
//|        to lose.                                                   |
//|      LEVEL 2 - at InpPartialCloseTrigger (default 5000 = 5.00) the |
//|        newest InpForceBECount orders (default 2, the ones that     |
//|        used to be closed here) are force-breakeven'd right now,    |
//|        regardless of whether LEVEL 1 has reached them yet. The     |
//|        rest of the basket is left alone here - LEVEL 1 still gets  |
//|        to them on its own trigger. Every order in the basket, both |
//|        groups, then hands its fixed TP over to the trailing stop   |
//|        below - nothing is closed here, the whole basket just       |
//|        starts running on the trail.                                |
//|   4) Peak trailing (InpUseTrailing, ON by default): from LEVEL 2   |
//|      onward every order's fixed TP is CLEARED                     |
//|      (InpTrailRemoveTP) so a winner can actually                  |
//|      run. From then on each order's SL is held                    |
//|      InpTrailDistancePoints (default 3000 = 3.00) behind the best |
//|      the basket has SEEN - a high-water mark, so the stop only    |
//|      ever ratchets forward - and is only rewritten when it gains  |
//|      at least InpTrailStepPoints. InpTrailWidenPerOrder gives     |
//|      each successive order a wider leash so one retrace does not  |
//|      flatten the whole basket at a single price.                  |
//|      InpMaxTP_Points, if set, becomes the one hard exit target.   |
//|      See TrailBasketByPeak for why SL is anchored to the peak     |
//|      instead of being stepped alongside TP. The LEVEL 2 group      |
//|      additionally gets a floor: their stop is never accepted below |
//|      the InpPartialCloseTrigger profit level they already earned,  |
//|      even on a peak too fresh for the plain formula to clear that   |
//|      on its own - the rest of the basket has no such floor.        |
//|   5) Optional extra profit lock: if InpUseProfitLock is on, once  |
//|      basket profit reaches InpProfitLockTriggerPoints (default    |
//|      12500 = 12.50), SL is pulled forward (once) to lock in       |
//|      InpProfitLockPoints (default 10000 = 10.00) on every         |
//|      order - regardless of whether step trailing above has        |
//|      actually kept pace. This is for a market that runs far       |
//|      enough to be worth protecting but too choppy/slow for the    |
//|      per-tick trailing to have triggered smoothly. Never moves SL |
//|      backward - only used if it improves on the current SL.       |
//|   6) Stepped profit-lock ladder (InpUseProfitLadder, ON by        |
//|      default): same mechanism as #5, but it keeps firing forever   |
//|      instead of once. The first trigger is InpLadderStart (default |
//|      6000 = 6.00); each level locks (trigger - InpLadderLockOffset,|
//|      default 3000 = 3.00) points of profit, then the NEXT trigger  |
//|      is this one plus InpLadderStepA/InpLadderStepB (default       |
//|      2000/1000), alternating every level - so with defaults the    |
//|      sequence runs 6000->lock 3000, 8000->5000, 9000->6000,        |
//|      11000->8000, 12000->9000, 14000->11000, 15000->12000,         |
//|      17000->14000, 18000->15000, 20000->17000, ... with no upper   |
//|      bound. Runs alongside #5, independently.                      |
//|                                                                    |
//|  Multiple manual entries (opposite directions, or spaced apart in |
//|  time) are tracked as independent baskets, each anchored to its   |
//|  own trigger position's open price.                               |
//|                                                                    |
//|  LIMITATION: basket membership (which auto orders belong to which |
//|  manual trigger) lives in memory only for this run and is not     |
//|  rebuilt from live terminal state after a recompile/restart. A    |
//|  basket that was already multiplied before a restart keeps its    |
//|  SL/TP but stops being managed for breakeven/trailing.            |
//|                                                                    |
//|  Standalone: no backend/dashboard reporting and no dependency on   |
//|  any account ID - this EA works purely off the local terminal's   |
//|  own positions, on whatever account/port it happens to be         |
//|  attached to.                                                     |
//|                                                                    |
//|  This is a STARTING TEMPLATE. Forward-test on a demo account      |
//|  before any live use. Educational / technical content only - not  |
//|  financial advice.                                                |
//+------------------------------------------------------------------+
#property copyright "Custom EA - Manual-Entry Auto Multiplier"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

CTrade trade;

#define MAX_BASKET_POSITIONS 32   // hard cap on positions tracked per basket (1 manual + auto adds)
#define LADDER_MAX_LEVELS_PER_TICK 1000  // safety cap - only reachable with a misconfigured (near-zero) ladder step

//================= INPUTS ====================================

input group "=== Auto Multiply (fires once per manual entry) ==="
input int      InpAutoAddCount       = 4;      // Additional same-direction orders to auto-open (0 = disable multiplying)
input double   InpAutoOrderLot       = 0.0;    // Lot size for auto orders; 0 = match the manual trigger order's lot
input int      InpMaxBaskets         = 10;     // Max concurrent manual-entry baskets tracked at once

// EVERY "points" input below is a raw broker point: distance = points *
// _Point. _Point comes from how many decimals the symbol is quoted to, so
// the same number is NOT the same distance everywhere. This broker prices
// XAUUSD to 3 decimals (4639.387), giving _Point = 0.001 - so a 5.00 move
// is 5000 points here, where a 2-decimal gold feed would call it 500. The
// defaults below are set for this 3-decimal feed; on a 2-decimal feed
// divide them all by 10. OnInit prints what each one resolved to in price
// terms, which is the fastest way to catch a mis-scaled setting.
input group "=== Stop Loss / Take Profit (fixed points, R:R 1:2) ==="
input int      InpSL_Points          = 5000;   // Stop Loss distance (points = 5.00 on 3-decimal gold), applied to every order in the basket
input int      InpTP_Points          = 10000;  // Take Profit distance (points = 10.00 on 3-decimal gold), applied to every order in the basket

input group "=== Breakeven & Trailing Handover (two separate levels, each fires once) ==="
input int      InpBE_TriggerPoints   = 3000;   // LEVEL 1 (3000 = 3.00): move every open order to its own breakeven - risk off, nothing closed yet
input int      InpBE_LockPoints      = 120;    // Points BEYOND each order's own entry to park the breakeven SL - covers commission/swap (110 = the $0.11 round-turn charge exactly, at any lot size; 0 = park it on the entry and eat the commission)
input int      InpPartialCloseTrigger = 5000;  // LEVEL 2 (5000 = 5.00): force-breakeven the newest InpForceBECount orders (they used to be closed here) and hand the WHOLE basket over to the trailing stop
input int      InpForceBECount        = 2;      // Newest N orders to force-breakeven at LEVEL 2, regardless of LEVEL 1's own trigger; the rest of the basket keeps waiting for LEVEL 1 to reach them normally

input group "=== Trailing (peak-based; takes over after breakeven) ==="
input bool     InpUseTrailing         = true;  // Let the remaining orders run on a trailing stop instead of a fixed TP
input int      InpTrailDistancePoints = 3000;  // SL is held this many points behind the BEST price the basket has seen (3000 = 3.00)
input int      InpTrailStepPoints     = 3000;  // Only move SL when it can improve by at least this much (0 = move on every tick it can)
input int      InpTrailWidenPerOrder  = 0;     // Add this many points to the trail distance per order, so they don't all stop out together (0 = all identical)
input bool     InpTrailRemoveTP       = true;  // Clear the fixed TP when trailing takes over, so a winner can actually run (final cap below still applies)
input int      InpMaxTP_Points        = 0;     // Hard final TP, in points from the basket's origin price (0 = none, exit purely on the trailing stop)

input group "=== Extra Profit Lock (independent safety net, works even without trailing) ==="
input bool     InpUseProfitLock           = false; // Enable: lock in a fixed profit once price runs far enough, even if trailing never triggered
input int      InpProfitLockTriggerPoints = 12500; // Once basket profit reaches this many points, lock SL as below (fires once per basket)
input int      InpProfitLockPoints        = 10000; // Points of profit (from each order's own open price) to lock into SL when the trigger fires

input group "=== Stepped Profit-Lock Ladder (fires repeatedly forever, locks forward as profit climbs) ==="
input bool     InpUseProfitLadder    = true;   // Enable the ladder below, independent of the single Extra Profit Lock above
input int      InpLadderStart        = 6000;   // First trigger (points of basket profit; 6000 = 6.00 on 3-decimal gold, same scale as the other inputs above)
input int      InpLadderLockOffset   = 3000;   // Every level locks (its trigger - this many points) into each order's SL
input int      InpLadderStepA        = 2000;   // Step added to get the next trigger, alternating with StepB starting from the first level
input int      InpLadderStepB        = 1000;   // The other alternating step (defaults give 6000,8000,9000,11000,12000,14000,15000,17000,18000,20000,... forever)

input group "=== Order Execution ==="
input ulong    InpMagicNumber        = 20260827; // Magic Number tagged on EA-opened (auto) orders only - the manual trigger keeps Magic=0
input int      InpSlippagePoints     = 500;      // Max price deviation allowed on auto market orders (500 = 0.50 on 3-decimal gold; the old 50 was 0.05, tighter than a normal gold spread)
input string   TradeComment          = "AutoMultiplier";

//================= BASKET STATE ====================================

struct Basket
  {
   int      direction;                     // 1 = buy, -1 = sell
   double   originPrice;                   // trigger (manual) position's open price - BE/profit-lock anchor
   bool     beApplied;
   bool     partialDone;                   // LEVEL 2 reached: breakeven ensured and TP handed over to the trailing stop
   bool     profitLockApplied;
   double   peakPrice;                     // best price this basket has seen (high-water mark) - the trailing stop is measured back from here
   ulong    tickets[MAX_BASKET_POSITIONS];
   int      ticketCount;

   // The LEVEL 2 force-breakeven group, snapshotted by TICKET (not array
   // index) the moment LEVEL 2 fires - PruneClosedTickets compacts
   // `tickets[]` as orders close, so an index range would drift out from
   // under a later order. These tickets proved the basket could reach
   // InpPartialCloseTrigger profit, so their trailing stop is never
   // allowed to settle for protecting less than that (see forceBeFloorPrice
   // in TrailBasketByPeak) - unlike the rest of the basket, which trails
   // on the plain peak-minus-distance formula with no such floor.
   ulong    forceBeTickets[MAX_BASKET_POSITIONS];
   int      forceBeTicketCount;
   double   forceBeFloorPrice;

   // Stepped profit-lock ladder cursor - the next un-fired trigger (points)
   // and which of InpLadderStepA/StepB gets added to it once it fires, to
   // produce the trigger after that. Starts at InpLadderStart/StepA and
   // walks forward with no upper bound (see ManageBaskets).
   double   ladderNextTrigger;
   bool     ladderNextIsStepA;
  };
Basket g_baskets[];

string symbolName;

//+------------------------------------------------------------------+
int OnInit()
  {
   symbolName = _Symbol;

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   // Brokers differ in which order-filling modes they accept for a symbol;
   // detect what this symbol actually supports instead of hard-coding one.
   long fillingModes = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fillingModes & SYMBOL_FILLING_FOK) != 0)
      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fillingModes & SYMBOL_FILLING_IOC) != 0)
      trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      trade.SetTypeFilling(ORDER_FILLING_RETURN);

   if(InpAutoAddCount + 1 > MAX_BASKET_POSITIONS)
      Print("AutoMultiplier: WARNING - InpAutoAddCount=", InpAutoAddCount, " would exceed the ",
            MAX_BASKET_POSITIONS, "-position basket capacity; extra auto orders beyond that will still ",
            "open but won't be breakeven/trailing-managed");

   if(InpMaxTP_Points > 0 && InpMaxTP_Points < InpTP_Points)
      Print("AutoMultiplier: WARNING - InpMaxTP_Points=", InpMaxTP_Points, " is smaller than the initial ",
            "InpTP_Points=", InpTP_Points, " - every order's starting TP will already be past the cap");

   if(InpBE_LockPoints >= InpBE_TriggerPoints)
      Print("AutoMultiplier: WARNING - InpBE_LockPoints=", InpBE_LockPoints,
            " is not below InpBE_TriggerPoints=", InpBE_TriggerPoints,
            " - the breakeven stop would land at or past the price that triggers it and be rejected");

   if(InpPartialCloseTrigger < InpBE_TriggerPoints)
      Print("AutoMultiplier: NOTE - trailing-handover level (", InpPartialCloseTrigger,
            ") is below the breakeven level (", InpBE_TriggerPoints,
            "), so the newest ", InpForceBECount, " order(s) will be force-breakeven'd at LEVEL 2 before ",
            "LEVEL 1 ever fires; the rest of the basket still waits for LEVEL 1 as normal");

   if(InpForceBECount > 0 && InpForceBECount >= InpAutoAddCount + 1)
      Print("AutoMultiplier: NOTE - InpForceBECount=", InpForceBECount, " covers the entire ",
            InpAutoAddCount + 1, "-order basket, so every order gets force-breakeven'd at LEVEL 2 ",
            "and LEVEL 1 will have nothing left to do");

   if(InpUseTrailing && InpTrailDistancePoints <= 0)
      Print("AutoMultiplier: WARNING - InpTrailDistancePoints=", InpTrailDistancePoints,
            " leaves no gap between the stop and the peak - the first tick against the basket will close it");

   if(InpUseTrailing && !InpTrailRemoveTP && InpMaxTP_Points == 0)
      Print("AutoMultiplier: NOTE - trailing is on but the original ", InpTP_Points,
            "-point TP is kept, so most orders will close there long before the trailing stop matters");

   if(InpUseProfitLock && InpProfitLockPoints > InpProfitLockTriggerPoints)
      Print("AutoMultiplier: WARNING - InpProfitLockPoints=", InpProfitLockPoints,
            " is larger than InpProfitLockTriggerPoints=", InpProfitLockTriggerPoints,
            " - the lock level won't be reachable yet when the trigger fires, so it will be skipped");

   if(InpUseProfitLadder)
     {
      if(InpLadderLockOffset <= 0 || InpLadderLockOffset >= InpLadderStart)
         Print("AutoMultiplier: WARNING - InpLadderLockOffset=", InpLadderLockOffset,
               " must be positive and below InpLadderStart=", InpLadderStart,
               " - the first level's SL would land at or past the price that triggers it and be rejected");

      if(InpLadderStepA <= 0 || InpLadderStepB <= 0)
         Print("AutoMultiplier: WARNING - InpLadderStepA/StepB must both be positive or the ladder cannot ",
               "advance - it will stall after the first level and re-fire nothing (capped at ",
               LADDER_MAX_LEVELS_PER_TICK, " levels/tick either way)");

      Print("AutoMultiplier: profit-lock ladder enabled - starts at ", InpLadderStart,
            ", locks (trigger - ", InpLadderLockOffset, "), steps alternate +", InpLadderStepA,
            "/+", InpLadderStepB, " forever (e.g. ", InpLadderStart, "->",
            InpLadderStart - InpLadderLockOffset, ", ", InpLadderStart + InpLadderStepA, "->",
            InpLadderStart + InpLadderStepA - InpLadderLockOffset, ", ...)");
     }

   // The single most confusing thing about this EA is that a "point" is not
   // the same size on every broker - spell out what each distance actually
   // resolves to in price, so a mis-scaled setting is obvious immediately
   // instead of being discovered from a stop that sat 10x too tight.
   Print("AutoMultiplier: ", symbolName, " quotes ", _Digits, " decimals, so 1 point = ",
         DoubleToString(_Point, _Digits), " price (defaults here assume the 3-decimal gold feed)");
   Print("AutoMultiplier: SL ", InpSL_Points, " = ", DoubleToString(InpSL_Points * _Point, _Digits),
         " | TP ", InpTP_Points, " = ", DoubleToString(InpTP_Points * _Point, _Digits),
         " | BE ", InpBE_TriggerPoints, " = ", DoubleToString(InpBE_TriggerPoints * _Point, _Digits),
         " (locks +", DoubleToString(InpBE_LockPoints * _Point, _Digits), ")",
         " | trailing handover ", InpPartialCloseTrigger, " = ", DoubleToString(InpPartialCloseTrigger * _Point, _Digits),
         " | trail distance ", InpTrailDistancePoints, " = ", DoubleToString(InpTrailDistancePoints * _Point, _Digits));

   Print("AutoMultiplier: ready - waiting for a manually-opened (Magic=0) position on ", symbolName);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
  }

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
      CheckManualTriggerDeal(trans.deal);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   ManageBaskets();
  }

//+------------------------------------------------------------------+
//| Retry wrapper around HistoryDealSelect() - MT5's local history     |
//| cache can lag the actual execution by a tick or two right after a  |
//| deal fires, so a single immediate lookup can miss it.              |
//+------------------------------------------------------------------+
bool HistoryDealSelectRetry(ulong dealTicket, int maxAttempts=5, int delayMs=100)
  {
   for(int attempt=1; attempt<=maxAttempts; attempt++)
     {
      HistorySelect(0, TimeCurrent());
      if(HistoryDealSelect(dealTicket)) return(true);
      if(attempt < maxAttempts) Sleep(delayMs);
     }
   Print("AutoMultiplier: WARNING - deal #", dealTicket, " not found in history after ", maxAttempts, " attempts");
   return(false);
  }

//+------------------------------------------------------------------+
//| A new deal was added to history - if it is a manual (Magic=0)     |
//| entry on our symbol, kick off a new basket for it.                 |
//+------------------------------------------------------------------+
void CheckManualTriggerDeal(ulong dealTicket)
  {
   if(!HistoryDealSelectRetry(dealTicket)) return;
   if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol) return;
   if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_IN) return;
   if((ulong)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != 0) return; // only pure manual entries trigger auto-multiply

   ulong positionId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   TryCreateBasketFromManualPosition(positionId);
  }

//+------------------------------------------------------------------+
int BasketIndexForTicket(ulong ticket)
  {
   for(int b=0; b<ArraySize(g_baskets); b++)
      for(int i=0; i<g_baskets[b].ticketCount; i++)
         if(g_baskets[b].tickets[i] == ticket)
            return(b);
   return(-1);
  }

//+------------------------------------------------------------------+
void AddTicketToBasket(Basket &bk, ulong ticket)
  {
   if(bk.ticketCount >= MAX_BASKET_POSITIONS)
     {
      Print("AutoMultiplier: basket full (", MAX_BASKET_POSITIONS, " positions) - position #", ticket,
            " will not be breakeven/trailing-managed");
      return;
     }
   bk.tickets[bk.ticketCount] = ticket;
   bk.ticketCount++;
  }

//+------------------------------------------------------------------+
//| Broker volume min/max/step normalization (same pattern used by    |
//| XAUUSD_TrendPyramidEA.mq5's CalculateLotSize).                     |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
  {
   double volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(volStep <= 0) volStep = 0.01;

   lot = MathRound(lot / volStep) * volStep;
   lot = MathMax(lot, volMin);
   lot = MathMin(lot, volMax);
   return(NormalizeDouble(lot, 3));
  }

//+------------------------------------------------------------------+
void ApplyFixedStops(ulong ticket, int direction, double openPrice)
  {
   double sl = (direction == 1) ? openPrice - InpSL_Points * _Point : openPrice + InpSL_Points * _Point;
   double tp = (direction == 1) ? openPrice + InpTP_Points * _Point : openPrice - InpTP_Points * _Point;
   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   if(!trade.PositionModify(ticket, sl, tp))
      Print("AutoMultiplier: failed to set fixed SL/TP on #", ticket, " - ", trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| Resolve the position ticket that resulted from the last trade.Buy/|
//| Sell() call. Same approach as ResolveManagedPositionIdentity() in  |
//| XAUUSD_COUNTER_TREND.mq5: match by POSITION_IDENTIFIER == the      |
//| opening order ticket first, falling back to the newest matching    |
//| position if that identifier isn't found yet.                       |
//+------------------------------------------------------------------+
ulong ResolveNewPositionTicket(int direction, ulong openingOrder)
  {
   long wantType = (direction == 1) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   ulong best = 0;
   long  bestTimeMsc = -1;

   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber) continue;
      if(PositionGetInteger(POSITION_TYPE) != wantType) continue;

      ulong identifier = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      if(openingOrder > 0 && identifier == openingOrder)
         return(identifier);

      long timeMsc = PositionGetInteger(POSITION_TIME_MSC);
      if(timeMsc >= bestTimeMsc)
        {
         bestTimeMsc = timeMsc;
         best = identifier;
        }
     }
   return(best);
  }

//+------------------------------------------------------------------+
ulong OpenAutoOrder(int direction, double lot)
  {
   lot = NormalizeLot(lot);
   if(lot <= 0)
     {
      Print("AutoMultiplier: auto order skipped - normalized lot size is 0");
      return(0);
     }

   double price = (direction == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl    = (direction == 1) ? price - InpSL_Points * _Point : price + InpSL_Points * _Point;
   double tp    = (direction == 1) ? price + InpTP_Points * _Point : price - InpTP_Points * _Point;
   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   bool ok = (direction == 1)
      ? trade.Buy(lot, _Symbol, price, sl, tp, TradeComment)
      : trade.Sell(lot, _Symbol, price, sl, tp, TradeComment);

   if(!ok)
     {
      Print("AutoMultiplier: auto ", (direction == 1 ? "BUY" : "SELL"), " ", DoubleToString(lot, 2),
            " lot failed - ", trade.ResultRetcodeDescription());
      return(0);
     }

   ulong ticket = ResolveNewPositionTicket(direction, trade.ResultOrder());
   if(ticket == 0)
      Print("AutoMultiplier: WARNING - auto order filled but its position ticket could not be resolved; ",
            "it will not be breakeven/trailing-managed");
   return(ticket);
  }

//+------------------------------------------------------------------+
//| A manual (Magic=0) position was detected - set its SL/TP, open the |
//| configured number of same-direction auto orders, and start a new   |
//| basket tracking all of them together.                              |
//+------------------------------------------------------------------+
void TryCreateBasketFromManualPosition(ulong positionId)
  {
   if(BasketIndexForTicket(positionId) >= 0) return; // already tracked

   if(!PositionSelectByTicket(positionId)) return;
   if(PositionGetString(POSITION_SYMBOL) != _Symbol) return;
   if((long)PositionGetInteger(POSITION_MAGIC) != 0) return;

   if(ArraySize(g_baskets) >= InpMaxBaskets)
     {
      Print("AutoMultiplier: max concurrent baskets (", InpMaxBaskets, ") reached - ignoring manual position #", positionId);
      return;
     }

   long   posType   = PositionGetInteger(POSITION_TYPE);
   int    direction = (posType == POSITION_TYPE_BUY) ? 1 : -1;
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double lot       = PositionGetDouble(POSITION_VOLUME);

   ApplyFixedStops(positionId, direction, openPrice);

   int bi = ArraySize(g_baskets);
   ArrayResize(g_baskets, bi + 1);
   g_baskets[bi].direction   = direction;
   g_baskets[bi].originPrice = openPrice;
   g_baskets[bi].beApplied         = false;
   g_baskets[bi].partialDone       = false;
   g_baskets[bi].profitLockApplied = false;
   g_baskets[bi].peakPrice         = openPrice;
   g_baskets[bi].ticketCount       = 0;
   g_baskets[bi].forceBeTicketCount = 0;
   g_baskets[bi].forceBeFloorPrice  = 0.0;
   g_baskets[bi].ladderNextTrigger  = InpLadderStart;
   g_baskets[bi].ladderNextIsStepA  = true;
   AddTicketToBasket(g_baskets[bi], positionId);

   Print("AutoMultiplier: manual ", (direction == 1 ? "BUY" : "SELL"), " #", positionId,
         " @", DoubleToString(openPrice, _Digits), " lot=", DoubleToString(lot, 2),
         " detected - opening ", InpAutoAddCount, " auto order(s)");

   double autoLot = (InpAutoOrderLot > 0.0) ? InpAutoOrderLot : lot;
   for(int i=0; i<InpAutoAddCount; i++)
     {
      ulong newTicket = OpenAutoOrder(direction, autoLot);
      if(newTicket > 0)
         AddTicketToBasket(g_baskets[bi], newTicket);
     }
  }

//+------------------------------------------------------------------+
void PruneClosedTickets(Basket &bk)
  {
   int keep = 0;
   for(int i=0; i<bk.ticketCount; i++)
      if(PositionSelectByTicket(bk.tickets[i]))
        {
         bk.tickets[keep] = bk.tickets[i];
         keep++;
        }
   bk.ticketCount = keep;
  }

//+------------------------------------------------------------------+
bool IsForceBeTicket(Basket &bk, ulong ticket)
  {
   for(int i=0; i<bk.forceBeTicketCount; i++)
      if(bk.forceBeTickets[i] == ticket)
         return(true);
   return(false);
  }

//+------------------------------------------------------------------+
//| The TP an order should carry once trailing has taken over. With    |
//| InpTrailRemoveTP the fixed TP is cleared (0 = no TP in MT5) so the |
//| trailing stop becomes the ONLY exit and a winner is free to run;   |
//| InpMaxTP_Points, when set, replaces it with a single hard ceiling. |
//|                                                                     |
//| Removing the TP is what makes this design controllable at all: the |
//| two earlier bugs here were both the same shape - a TP that had to  |
//| be shifted out of the way faster than price could reach it, racing |
//| a fill the broker performs server-side. A stop that only ever      |
//| ratchets forward has no such race.                                 |
//+------------------------------------------------------------------+
double TrailingModeTP(Basket &bk, double curTP)
  {
   if(!InpUseTrailing || !InpTrailRemoveTP) return curTP;
   if(InpMaxTP_Points > 0)
      return NormalizeDouble((bk.direction == 1) ? bk.originPrice + InpMaxTP_Points * _Point
                                                 : bk.originPrice - InpMaxTP_Points * _Point, _Digits);
   return 0.0; // no TP at all - exit purely on the trailing stop
  }

//+------------------------------------------------------------------+
//| Move a still-open order to its own breakeven (LEVEL 1 calls this  |
//| for the whole basket; LEVEL 2 calls it for just the newest        |
//| InpForceBECount orders via ApplyBreakevenToRange). TP is left     |
//| exactly as it is - the handover to trailing happens later, at     |
//| LEVEL 2 (see HandOverToTrailing).                                  |
//|                                                                     |
//| InpBE_LockPoints parks the stop that many points BEYOND the entry  |
//| rather than exactly on it. A stop sitting precisely at the open    |
//| price is break-even on PRICE but not on money: MT5's profit figure |
//| already nets out the spread (a buy enters at ask and exits at bid, |
//| so bid == entry really is zero gross), but commission and swap are |
//| charged separately on top and would still make the trade close     |
//| slightly negative. The offset buys back exactly those costs.       |
//|                                                                     |
//| Sizing it is lot-independent, because commission and profit-per-   |
//| point both scale with volume: on XAUUSD (100 oz/lot) a 0.01 lot is |
//| 1 oz, so 1 point = 0.001 = $0.001, and a $0.11 round-turn          |
//| commission is covered by 110 points no matter what lot is traded.  |
//| The offset is applied per order, off that order's own entry.       |
//+------------------------------------------------------------------+
void ApplyBreakevenToRange(Basket &bk, int startIdx, int count, double stopsLevel)
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double lock = InpBE_LockPoints * _Point;

   int endIdx = MathMin(startIdx + count, bk.ticketCount);
   for(int i=MathMax(startIdx, 0); i<endIdx; i++)
     {
      ulong ticket = bk.tickets[i];
      if(!PositionSelectByTicket(ticket)) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curTP     = PositionGetDouble(POSITION_TP);
      double newSL     = NormalizeDouble((bk.direction == 1) ? openPrice + lock : openPrice - lock, _Digits);

      bool okDistance = (bk.direction == 1) ? (bid - newSL) > stopsLevel : (newSL - ask) > stopsLevel;
      if(!okDistance)
        {
         Print("AutoMultiplier: breakeven skipped on #", ticket, " (too close to current price)");
         continue;
        }

      if(!trade.PositionModify(ticket, newSL, curTP))
         Print("AutoMultiplier: breakeven modify failed on #", ticket, " - ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
void ApplyBreakevenToBasket(Basket &bk, double stopsLevel)
  {
   ApplyBreakevenToRange(bk, 0, bk.ticketCount, stopsLevel);
  }

//+------------------------------------------------------------------+
//| Rewrite the TP of every still-open order in the basket according  |
//| to the trailing policy. Called once, at LEVEL 2, which is the      |
//| moment the trailing stop takes over as the exit mechanism.         |
//+------------------------------------------------------------------+
void HandOverToTrailing(Basket &bk, double stopsLevel)
  {
   if(!InpUseTrailing || !InpTrailRemoveTP) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i=0; i<bk.ticketCount; i++)
     {
      ulong ticket = bk.tickets[i];
      if(!PositionSelectByTicket(ticket)) continue;

      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);
      double newTP = TrailingModeTP(bk, curTP);
      if(MathAbs(newTP - curTP) < _Point/2) continue;

      // A hard ceiling that is already behind price would be rejected outright -
      // keep whatever TP the order has rather than losing the modify entirely.
      if(newTP > 0)
        {
         bool tpOk = (bk.direction == 1) ? (newTP - ask) > stopsLevel : (bid - newTP) > stopsLevel;
         if(!tpOk)
           {
            Print("AutoMultiplier: final-TP ceiling on #", ticket, " is already past current price - keeping existing TP");
            continue;
           }
        }

      if(!trade.PositionModify(ticket, curSL, newTP))
         Print("AutoMultiplier: trailing handover failed on #", ticket, " - ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| One-time safety net, independent of the step trailing above: once |
//| basket profit reaches a trigger, pull SL forward to lock in        |
//| lockPoints of profit on every order (measured from that order's    |
//| own open price) - for a market that runs far enough to be worth    |
//| protecting, but not smoothly enough for the per-tick trailing       |
//| above to have kept pace via the TP-proximity check. Never moves SL |
//| backward - only applied if it actually improves on whatever SL     |
//| that order already has (e.g. from breakeven or trailing already    |
//| having done better).                                                |
//|                                                                     |
//| Shared by the single Extra Profit Lock (InpProfitLockPoints) and    |
//| every level of the stepped ladder below - both are once-off        |
//| triggers that lock a fixed number of points, they just differ in    |
//| how many levels and at what trigger.                                |
//+------------------------------------------------------------------+
void ApplyProfitLockToBasket(Basket &bk, double lockPoints, double stopsLevel)
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i=0; i<bk.ticketCount; i++)
     {
      ulong ticket = bk.tickets[i];
      if(!PositionSelectByTicket(ticket)) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL     = PositionGetDouble(POSITION_SL);
      double curTP     = PositionGetDouble(POSITION_TP);
      double lockSL    = (bk.direction == 1) ? openPrice + lockPoints * _Point
                                              : openPrice - lockPoints * _Point;
      lockSL = NormalizeDouble(lockSL, _Digits);

      bool improves = (bk.direction == 1) ? (curSL <= 0 || lockSL > curSL) : (curSL <= 0 || lockSL < curSL);
      if(!improves) continue; // current SL already locks at least this much - leave it alone

      bool okDistance = (bk.direction == 1) ? (bid - lockSL) > stopsLevel : (lockSL - ask) > stopsLevel;
      if(!okDistance)
        {
         Print("AutoMultiplier: profit-lock skipped on #", ticket, " (too close to current price)");
         continue;
        }

      if(trade.PositionModify(ticket, lockSL, curTP))
         Print("AutoMultiplier: profit-lock applied on #", ticket, " - SL -> ", DoubleToString(lockSL, _Digits));
      else
         Print("AutoMultiplier: profit-lock modify failed on #", ticket, " - ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Hold every remaining order's SL a fixed distance behind the best   |
//| price the basket has SEEN (bk.peakPrice), not behind the price it  |
//| happens to be at when this runs. A high-water mark cannot move     |
//| backwards, so the stop can only ever ratchet forward: locked       |
//| profit is monotonic and a spike that retraces before the next tick |
//| still counts.                                                      |
//|                                                                     |
//| This replaces two earlier designs that both failed the same way -  |
//| they moved SL and TP together as a pair, which meant the stop's    |
//| position was derived from the target's position:                   |
//|   v1 shifted both once price came within one step of TP. The       |
//|      broker fills a TP server-side the instant price touches it,   |
//|      so the shift lost that race and every order closed at the     |
//|      original TP.                                                  |
//|   v2 shifted both on a percentage of forward progress. That fixed  |
//|      the race but still parked the new SL exactly on the market    |
//|      price each step (breakeven + one step = the very price that   |
//|      triggered it), so a ~500-point retrace on 2026-08-27 stopped  |
//|      out an entire 5-order basket seconds after it fired.          |
//| Here SL is anchored to the peak and TP is out of the picture       |
//| entirely (see TrailingModeTP) - there is no pair to keep in sync   |
//| and nothing to race.                                               |
//|                                                                     |
//| One exception to the plain peak-minus-distance formula: the LEVEL  |
//| 2 force-breakeven orders (bk.forceBeTickets) already proved the     |
//| basket reaches InpPartialCloseTrigger profit, so their target is    |
//| floored at bk.forceBeFloorPrice. Without this, a peak that has only |
//| just cleared the LEVEL 2 trigger (e.g. peak = 600 with a 300-point  |
//| trail distance, on a broker where LEVEL 2 = 500) would compute a    |
//| target of only 300 - LESS than what LEVEL 2 already earned, and     |
//| the ratchet-forward check would happily accept it since it's still |
//| better than the breakeven stop it's replacing. The floor is only a |
//| minimum: once the peak has run far enough that the plain formula    |
//| clears the floor on its own, this has no effect. It does not apply |
//| to the rest of the basket, which trails on the plain formula with   |
//| no such floor.                                                      |
//+------------------------------------------------------------------+
void TrailBasketByPeak(Basket &bk, double stopsLevel)
  {
   double step = InpTrailStepPoints * _Point;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i=0; i<bk.ticketCount; i++)
     {
      ulong ticket = bk.tickets[i];
      if(!PositionSelectByTicket(ticket)) continue;

      // Optionally give each successive order a wider leash, so a single
      // retrace takes out the tightest one and leaves the rest running
      // instead of flattening the whole basket at one price.
      double trailDistance = (InpTrailDistancePoints + i * InpTrailWidenPerOrder) * _Point;
      double target = (bk.direction == 1) ? bk.peakPrice - trailDistance
                                          : bk.peakPrice + trailDistance;

      if(IsForceBeTicket(bk, ticket))
         target = (bk.direction == 1) ? MathMax(target, bk.forceBeFloorPrice)
                                       : MathMin(target, bk.forceBeFloorPrice);

      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);

      // A stop only ever ratchets forward: ignore anything that would not
      // improve on the SL this order already has by at least one step.
      double improvement = (bk.direction == 1) ? (target - curSL) : (curSL - target);
      if(improvement < step || improvement <= 0) continue;

      double newSL = NormalizeDouble(target, _Digits);
      bool slOk = (bk.direction == 1) ? (bid - newSL) > stopsLevel : (newSL - ask) > stopsLevel;
      if(!slOk) continue; // peak is too close to price to place this stop yet - try again next tick

      if(!trade.PositionModify(ticket, newSL, curTP))
         Print("AutoMultiplier: trailing modify failed on #", ticket, " - ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Per-tick basket maintenance: drop closed tickets, apply the two    |
//| once-off breakeven levels and the LEVEL 2 trailing handover, then  |
//| (optionally) keep trailing SL forward in fixed steps.              |
//+------------------------------------------------------------------+
void ManageBaskets()
  {
   double stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int b=ArraySize(g_baskets)-1; b>=0; b--)
     {
      PruneClosedTickets(g_baskets[b]);
      if(g_baskets[b].ticketCount == 0)
        {
         ArrayRemove(g_baskets, b, 1);
         continue;
        }

      // High-water mark first, so everything below reacts to the best price
      // this basket has actually reached rather than the current tick.
      if(g_baskets[b].direction == 1)
        {
         if(bid > g_baskets[b].peakPrice) g_baskets[b].peakPrice = bid;
        }
      else
        {
         if(ask < g_baskets[b].peakPrice) g_baskets[b].peakPrice = ask;
        }

      double originPrice  = g_baskets[b].originPrice;
      double profitPrice  = (g_baskets[b].direction == 1) ? (bid - originPrice) : (originPrice - ask);
      double profitPoints = profitPrice / _Point;

      if(!g_baskets[b].beApplied && profitPoints >= InpBE_TriggerPoints)
        {
         // LEVEL 1 - risk off. Nothing is closed and TP is untouched here;
         // the basket simply stops being able to lose from this point.
         ApplyBreakevenToBasket(g_baskets[b], stopsLevel);
         g_baskets[b].beApplied = true;
        }

      if(!g_baskets[b].partialDone && profitPoints >= InpPartialCloseTrigger)
        {
         // LEVEL 2 - nothing is closed here anymore. The newest
         // InpForceBECount orders (the ones that used to get banked/closed)
         // are force-breakeven'd right now, regardless of whether LEVEL 1
         // has fired yet. The rest of the basket is left alone here - if
         // LEVEL 1 hasn't reached them yet, it still will, on its own
         // trigger, untouched by this level. Every order in the basket -
         // both groups - then hands its fixed TP over to the trailing stop.
         int splitStart = MathMax(0, g_baskets[b].ticketCount - InpForceBECount);

         // Snapshot which tickets are the force-BE group, by ID, before
         // trailing (and any later PruneClosedTickets) can shuffle indices.
         // These orders just proved the basket reaches InpPartialCloseTrigger
         // profit - TrailBasketByPeak uses forceBeFloorPrice to make sure
         // their stop is never accepted below that level, even on a peak
         // that hasn't run far enough past it yet for the plain
         // peak-minus-distance formula to clear it on its own.
         g_baskets[b].forceBeTicketCount = 0;
         for(int i=splitStart; i<g_baskets[b].ticketCount; i++)
           {
            g_baskets[b].forceBeTickets[g_baskets[b].forceBeTicketCount] = g_baskets[b].tickets[i];
            g_baskets[b].forceBeTicketCount++;
           }
         g_baskets[b].forceBeFloorPrice = (g_baskets[b].direction == 1)
            ? originPrice + InpPartialCloseTrigger * _Point
            : originPrice - InpPartialCloseTrigger * _Point;

         ApplyBreakevenToRange(g_baskets[b], splitStart, InpForceBECount, stopsLevel);
         g_baskets[b].partialDone = true;

         HandOverToTrailing(g_baskets[b], stopsLevel);
        }

      if(InpUseProfitLock && !g_baskets[b].profitLockApplied && profitPoints >= InpProfitLockTriggerPoints)
        {
         ApplyProfitLockToBasket(g_baskets[b], InpProfitLockPoints, stopsLevel);
         g_baskets[b].profitLockApplied = true;
        }

      // Stepped profit-lock ladder - independent of, and in addition to, the
      // single Extra Profit Lock above. Has no fixed end: each fired level
      // computes the next trigger by adding InpLadderStepA/StepB
      // (alternating) to the one that just fired, so the `while` below walks
      // forward through as many levels as this tick's profit has already
      // cleared (a fast tick jump can clear more than one at once) and keeps
      // going on every later tick for as long as profit keeps climbing.
      // LADDER_MAX_LEVELS_PER_TICK guards against an infinite loop if
      // InpLadderStepA/StepB are misconfigured to zero or negative.
      if(InpUseProfitLadder)
        {
         int guard = 0;
         while(profitPoints >= g_baskets[b].ladderNextTrigger && guard < LADDER_MAX_LEVELS_PER_TICK)
           {
            double lockPoints = g_baskets[b].ladderNextTrigger - InpLadderLockOffset;
            ApplyProfitLockToBasket(g_baskets[b], lockPoints, stopsLevel);

            double step = g_baskets[b].ladderNextIsStepA ? InpLadderStepA : InpLadderStepB;
            if(step <= 0) break; // misconfigured - stop advancing instead of looping forever
            g_baskets[b].ladderNextTrigger += step;
            g_baskets[b].ladderNextIsStepA  = !g_baskets[b].ladderNextIsStepA;
            guard++;
           }
        }

      // Trailing only starts once LEVEL 2 has handed the basket over and
      // taken the fixed TP away - from here the stop can only move forward,
      // so the basket's worst case never gets worse again.
      if(InpUseTrailing && g_baskets[b].partialDone)
         TrailBasketByPeak(g_baskets[b], stopsLevel);
     }
  }
//+------------------------------------------------------------------+
