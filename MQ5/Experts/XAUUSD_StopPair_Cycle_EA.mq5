//+------------------------------------------------------------------+
//|                                  XAUUSD_StopPair_Cycle_EA.mq5     |
//|  One cycle = one Buy Stop above and one Sell Stop below an anchor |
//|  (the mid price when the cycle starts).                           |
//|                                                                    |
//|    Buy  Stop  anchor + gap   SL anchor   TP entry + tp distance   |
//|    Sell Stop  anchor - gap   SL anchor   TP entry - tp distance   |
//|                                                                    |
//|  The moment any position closes (TP or SL) the cycle ends: every  |
//|  pending order is deleted first, every remaining position is      |
//|  closed, and a new cycle starts around the current price.         |
//+------------------------------------------------------------------+
#property copyright "Custom EA - Stop Pair Cycle"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

CTrade trade;

input group "=== Cycle ==="
input double   InpGapPrice          = 50.0;       // Distance from the anchor to each stop entry (price units, 50 = 4000 -> 4050)
input double   InpTakeProfitPrice   = 200.0;      // TP distance from each entry (price units)
input double   InpLots              = 0.01;       // Fixed lot per order

input group "=== Execution Safety ==="
input ulong    InpMagicNumber       = 20261006;
input int      InpSlippagePoints    = 100;
input double   InpMaxSpreadPrice    = 1.0;        // 0 = disabled; otherwise skip starting a cycle while spread exceeds this price distance
input int      InpRetrySeconds      = 5;          // Wait this long before retrying a rejected cycle start

double   g_tickSize     = 0.0;
int      g_digits       = 0;
int      g_peakPositions = 0;       // Most positions seen open in the current cycle
bool     g_closing      = false;    // A cycle end is in progress and must finish before a new one starts
datetime g_nextAttempt  = 0;

//+------------------------------------------------------------------+
double NormalizePrice(const double price)
  {
   return NormalizeDouble(MathRound(price / g_tickSize) * g_tickSize, g_digits);
  }

int CountOwnPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber)
         count++;
     }
   return count;
  }

int CountOwnPendings()
  {
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == (long)InpMagicNumber)
         count++;
     }
   return count;
  }

void DeleteOwnPendings()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != (long)InpMagicNumber)
         continue;
      if(!trade.OrderDelete(ticket))
         PrintFormat("OrderDelete %I64u failed: %d %s", ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }
  }

void CloseOwnPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) != _Symbol || PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber)
         continue;
      const ulong ticket = PositionGetInteger(POSITION_TICKET);
      if(!trade.PositionClose(ticket))
         PrintFormat("PositionClose %I64u failed: %d %s", ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }
  }

// Pendings go first so a stop cannot fill while the positions are being closed.
bool EndCycle()
  {
   DeleteOwnPendings();
   CloseOwnPositions();
   DeleteOwnPendings();
   return CountOwnPositions() == 0 && CountOwnPendings() == 0;
  }

bool StartCycle()
  {
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.ask <= 0.0 || tick.bid <= 0.0)
      return false;

   if(InpMaxSpreadPrice > 0.0 && tick.ask - tick.bid > InpMaxSpreadPrice)
      return false;

   const double anchor     = NormalizePrice((tick.ask + tick.bid) * 0.5);
   const double buyEntry   = NormalizePrice(anchor + InpGapPrice);
   const double sellEntry  = NormalizePrice(anchor - InpGapPrice);
   const double buyTp      = NormalizePrice(buyEntry + InpTakeProfitPrice);
   const double sellTp     = NormalizePrice(sellEntry - InpTakeProfitPrice);

   const double minDistance = MathMax(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                                      SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL)) * _Point;
   if(buyEntry - tick.ask < minDistance || tick.bid - sellEntry < minDistance || InpGapPrice < minDistance)
     {
      Print("Gap is inside the broker's minimum stop distance; cycle not started");
      return false;
     }

   if(!trade.BuyStop(InpLots, buyEntry, _Symbol, anchor, buyTp, ORDER_TIME_GTC, 0, "StopPair buy"))
     {
      PrintFormat("BuyStop failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return false;
     }

   if(!trade.SellStop(InpLots, sellEntry, _Symbol, anchor, sellTp, ORDER_TIME_GTC, 0, "StopPair sell"))
     {
      PrintFormat("SellStop failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
      DeleteOwnPendings();   // never leave a one-sided cycle behind
      return false;
     }

   PrintFormat("Cycle started: anchor %.2f buy %.2f sell %.2f", anchor, buyEntry, sellEntry);
   return true;
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   g_tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   g_digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(g_tickSize <= 0.0)
      return INIT_FAILED;

   const double volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double volMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   const double steps   = InpLots / volStep;
   if(InpLots < volMin || InpLots > volMax || MathAbs(steps - MathRound(steps)) > 1e-6)
     {
      PrintFormat("InpLots %.2f is not a valid volume (min %.2f max %.2f step %.2f)", InpLots, volMin, volMax, volStep);
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpGapPrice <= 0.0 || InpTakeProfitPrice <= 0.0)
      return INIT_PARAMETERS_INCORRECT;

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   // Resume after a restart: whatever is already open belongs to the running cycle.
   g_peakPositions = CountOwnPositions();
   return INIT_SUCCEEDED;
  }

void OnTick()
  {
   const int positions = CountOwnPositions();
   if(positions > g_peakPositions)
      g_peakPositions = positions;

   // A position vanished (TP or SL hit) or an earlier cycle end is still unfinished.
   if(g_closing || (g_peakPositions > 0 && positions < g_peakPositions))
     {
      g_closing = true;
      if(!EndCycle())
         return;
      g_closing = false;
      g_peakPositions = 0;
     }

   if(CountOwnPositions() > 0)
      return;   // cycle running

   const int pendings = CountOwnPendings();
   if(pendings == 2)
      return;   // cycle armed, waiting for a fill

   if(pendings != 0)
     {
      g_closing = true;   // broken cycle (one side missing); clear it and restart
      return;
     }

   if(TimeCurrent() < g_nextAttempt)
      return;
   if(!StartCycle())
      g_nextAttempt = TimeCurrent() + InpRetrySeconds;
  }
