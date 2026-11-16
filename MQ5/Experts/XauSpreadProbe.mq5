//+------------------------------------------------------------------+
//|                                                XauSpreadProbe.mq5 |
//| Strategy Tester only: records the real-tick bid/ask spread by    |
//| server hour (mean and percentiles) so trading costs can be sized. |
//| Run with Model=4 (every tick based on real ticks). It never       |
//| trades and never touches a live chart.                            |
//| Output: Common\Files\xau_spread_by_hour.csv                       |
//+------------------------------------------------------------------+
#property strict

#define BINS 81            // 0.00 .. 0.79 in 0.01 steps, last bin = >= 0.80

double sumS[24];
long   cnt[24];
long   hist[24][BINS];

int OnInit()
{
   if(!MQLInfoInteger(MQL_TESTER))
   {
      Print("XauSpreadProbe is for the Strategy Tester only");
      return INIT_FAILED;
   }
   ArrayInitialize(sumS, 0);
   ArrayInitialize(cnt, 0);
   ArrayInitialize(hist, 0);
   return INIT_SUCCEEDED;
}

void OnTick()
{
   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t) || t.bid <= 0 || t.ask <= 0) return;
   MqlDateTime dt;
   TimeToStruct(t.time, dt);
   double s = t.ask - t.bid;
   sumS[dt.hour] += s;
   cnt[dt.hour]++;
   int b = (int)MathMin(BINS - 1, MathFloor(s / 0.01 + 1e-9));
   hist[dt.hour][b]++;
}

double Pct(int h, double p)
{
   long acc = 0;
   for(int b = 0; b < BINS; b++)
   {
      acc += hist[h][b];
      if(acc >= cnt[h] * p) return b * 0.01;
   }
   return (BINS - 1) * 0.01;
}

void OnDeinit(const int reason)
{
   int f = FileOpen("xau_spread_by_hour.csv", FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(f == INVALID_HANDLE) { Print("FileOpen failed: ", GetLastError()); return; }
   FileWrite(f, "hour", "ticks", "mean", "p50", "p90", "p99");
   for(int h = 0; h < 24; h++)
   {
      if(cnt[h] == 0) { FileWrite(f, h, 0, 0, 0, 0, 0); continue; }
      FileWrite(f, h, cnt[h], DoubleToString(sumS[h] / cnt[h], 4),
                DoubleToString(Pct(h, 0.5), 2), DoubleToString(Pct(h, 0.9), 2), DoubleToString(Pct(h, 0.99), 2));
   }
   FileClose(f);
}
