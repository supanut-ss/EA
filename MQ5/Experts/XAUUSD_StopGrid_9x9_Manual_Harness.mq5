//+------------------------------------------------------------------+
//| XAUUSD_StopGrid_9x9_Manual_Harness.mq5                           |
//| Strategy Tester wrapper: includes the real Manual EA unchanged   |
//| and opens the "manual" Level 1 market order itself whenever the  |
//| account is flat, so the grid/case/exit logic can be backtested.  |
//+------------------------------------------------------------------+
#property copyright "Test harness for XAUUSD_StopGrid_9x9_Manual_EA"
#property version   "1.00"
#property strict

#define OnInit ManualEaOnInit
#define OnDeinit ManualEaOnDeinit
#define OnTick ManualEaOnTick
#define OnTradeTransaction ManualEaOnTradeTransaction
#include "XAUUSD_StopGrid_9x9_Manual_EA.mq5"
#undef OnInit
#undef OnDeinit
#undef OnTick
#undef OnTradeTransaction

input group "=== Harness ==="
input int    HarnessDirection      = 0;      // 1 = always Buy, -1 = always Sell, 0 = alternate
input double HarnessManualLot      = 0.01;
input int    HarnessDelaySeconds   = 60;     // Wait after flat before the next manual entry.
input int    HarnessStartHour      = 8;      // Server-hour window for manual entries.
input int    HarnessEndHour        = 20;

CTrade   g_harnessTrade;
datetime g_harnessNextEntry = 0;
int      g_harnessNextDirection = 1;
int      g_harnessEntries = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   g_harnessTrade.SetExpertMagicNumber(0);   // a "manual" order carries no EA magic
   g_harnessNextDirection = (HarnessDirection == 0 ? 1 : HarnessDirection);
   return(ManualEaOnInit());
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   Print("HARNESS: manual entries opened=", g_harnessEntries);
   ManualEaOnDeinit(reason);
  }

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   ManualEaOnTradeTransaction(trans, request, result);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   bool flat = (PositionsTotal() == 0 && OrdersTotal() == 0);
   if(!flat)
      g_harnessNextEntry = TimeCurrent() + HarnessDelaySeconds;
   else if(TimeCurrent() >= g_harnessNextEntry &&
           now.hour >= HarnessStartHour && now.hour < HarnessEndHour)
     {
      bool ok = (g_harnessNextDirection > 0 ?
                 g_harnessTrade.Buy(HarnessManualLot, _Symbol, 0.0, 0.0, 0.0, "manual") :
                 g_harnessTrade.Sell(HarnessManualLot, _Symbol, 0.0, 0.0, 0.0, "manual"));
      if(ok)
        {
         g_harnessEntries++;
         if(HarnessDirection == 0)
            g_harnessNextDirection = -g_harnessNextDirection;
        }
      g_harnessNextEntry = TimeCurrent() + HarnessDelaySeconds;
     }
   ManualEaOnTick();
  }
