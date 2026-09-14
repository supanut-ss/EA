//+------------------------------------------------------------------+
//|                                        SwingATR_Analysis.mq5      |
//|  TEST TOOLING - not a trading EA. Measures how far XAUUSD moves  |
//|  before reversing (a simple zigzag leg-length distribution) and  |
//|  the average ATR, over whatever range/period the Strategy Tester |
//|  is configured to run. Never opens a trade.                      |
//+------------------------------------------------------------------+
#property copyright "Test tooling - market character analysis"
#property version   "1.00"
#property strict

input int    InpAtrPeriod            = 14;    // ATR smoothing period (Wilder)
input double InpSwingDeviationPrice  = 1.00;   // Minimum retrace from the running extreme to confirm a swing pivot (noise filter)
input int    InpReportEveryNBars     = 2000;   // Print an interim snapshot every N closed bars, in case OnDeinit output is lost

datetime g_lastBarTime = 0;
double   g_prevClose   = 0.0;
double   g_atr         = 0.0;
int      g_atrBars     = 0;
double   g_atrSum      = 0.0;
bool     g_atrSeeded   = false;
int      g_barsProcessed = 0;

int    g_direction = 0;    // 0 = not yet seeded, 1 = up-leg building, -1 = down-leg building
double g_extreme   = 0.0;
double g_pivot      = 0.0;
double g_legs[];

int OnInit()
  {
   ArrayResize(g_legs, 0);
   Print("SwingATR: starting on ", _Symbol, " ", EnumToString((ENUM_TIMEFRAMES)_Period),
         " | ATR period=", InpAtrPeriod, " | swing deviation=", DoubleToString(InpSwingDeviationPrice, 2));
   return(INIT_SUCCEEDED);
  }

void OnTick()
  {
   datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(barTime == 0 || barTime == g_lastBarTime)
      return;

   if(g_lastBarTime != 0)
     {
      double high  = iHigh(_Symbol, PERIOD_CURRENT, 1);
      double low   = iLow(_Symbol, PERIOD_CURRENT, 1);
      double close = iClose(_Symbol, PERIOD_CURRENT, 1);
      if(high > 0.0 && low > 0.0 && close > 0.0)
         ProcessClosedBar(high, low, close);
     }
   g_lastBarTime = barTime;

   if(InpReportEveryNBars > 0 && g_barsProcessed > 0 && g_barsProcessed % InpReportEveryNBars == 0)
      PrintReport("interim @ " + IntegerToString(g_barsProcessed) + " bars");
  }

void ProcessClosedBar(const double high, const double low, const double close)
  {
   g_barsProcessed++;

   if(g_prevClose > 0.0)
     {
      double tr = MathMax(high - low, MathMax(MathAbs(high - g_prevClose), MathAbs(low - g_prevClose)));
      if(!g_atrSeeded)
        {
         g_atrSum += tr;
         g_atrBars++;
         if(g_atrBars >= InpAtrPeriod)
           {
            g_atr = g_atrSum / InpAtrPeriod;
            g_atrSeeded = true;
           }
        }
      else
         g_atr = (g_atr * (InpAtrPeriod - 1) + tr) / InpAtrPeriod;
     }
   g_prevClose = close;

   if(g_direction == 0)
     {
      g_extreme = high;
      g_pivot   = low;
      g_direction = 1;
      return;
     }

   if(g_direction == 1)
     {
      if(high > g_extreme)
         g_extreme = high;
      if(g_extreme - low >= InpSwingDeviationPrice)
        {
         RecordLeg(g_extreme - g_pivot);
         g_pivot   = g_extreme;
         g_extreme = low;
         g_direction = -1;
        }
     }
   else
     {
      if(low < g_extreme)
         g_extreme = low;
      if(high - g_extreme >= InpSwingDeviationPrice)
        {
         RecordLeg(g_pivot - g_extreme);
         g_pivot   = g_extreme;
         g_extreme = high;
         g_direction = 1;
        }
     }
  }

void RecordLeg(const double length)
  {
   int size = ArraySize(g_legs);
   ArrayResize(g_legs, size + 1);
   g_legs[size] = length;
  }

void OnDeinit(const int reason)
  {
   PrintReport("FINAL (deinit reason=" + IntegerToString(reason) + ")");
  }

void PrintReport(const string label)
  {
   Print("=== SwingATR ", label, " | ", _Symbol, " ", EnumToString((ENUM_TIMEFRAMES)_Period), " ===");
   Print("Bars processed: ", g_barsProcessed);
   Print("ATR(", InpAtrPeriod, ") current smoothed value: ", DoubleToString(g_atr, 3),
         " (", DoubleToString(g_atr * 100, 0), " cents)");

   int n = ArraySize(g_legs);
   Print("Swing legs (deviation filter ", DoubleToString(InpSwingDeviationPrice, 2), "): ", n);
   if(n == 0)
      return;

   double sorted[];
   ArrayCopy(sorted, g_legs);
   ArraySort(sorted);

   double sum = 0.0;
   for(int i = 0; i < n; i++)
      sum += sorted[i];

   int i25 = (int)MathMin(n - 1, n * 0.25);
   int i50 = (int)MathMin(n - 1, n * 0.50);
   int i75 = (int)MathMin(n - 1, n * 0.75);
   int i90 = (int)MathMin(n - 1, n * 0.90);

   Print("  min    = ", DoubleToString(sorted[0], 3), " (", DoubleToString(sorted[0] * 100, 0), "c)");
   Print("  p25    = ", DoubleToString(sorted[i25], 3), " (", DoubleToString(sorted[i25] * 100, 0), "c)");
   Print("  median = ", DoubleToString(sorted[i50], 3), " (", DoubleToString(sorted[i50] * 100, 0), "c)");
   Print("  mean   = ", DoubleToString(sum / n, 3), " (", DoubleToString(sum / n * 100, 0), "c)");
   Print("  p75    = ", DoubleToString(sorted[i75], 3), " (", DoubleToString(sorted[i75] * 100, 0), "c)");
   Print("  p90    = ", DoubleToString(sorted[i90], 3), " (", DoubleToString(sorted[i90] * 100, 0), "c)");
   Print("  max    = ", DoubleToString(sorted[n - 1], 3), " (", DoubleToString(sorted[n - 1] * 100, 0), "c)");
  }
