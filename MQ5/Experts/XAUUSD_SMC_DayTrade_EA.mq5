//+------------------------------------------------------------------+
//|                                XAUUSD_SMC_DayTrade_EA.mq5        |
//|  Strategy: Smart Money Concept (SMC) + Price Action day trading  |
//|            translated into deterministic, code-checkable rules  |
//|            from the "xauusd-daytrade" skill rule book.           |
//|                                                                    |
//|  Architecture: explicit state machine (IDLE/ARMED/ACTIVE/RUNNER/ |
//|  BLOCKED) - see the plan doc for the full rationale. A POI is    |
//|  identified on H4/H1/M15 (ARMED), then watched on M5 for a       |
//|  trigger candle before a position is opened (ACTIVE), managed to |
//|  TP1, and optionally left running as a trailed runner (RUNNER).  |
//|                                                                    |
//|  Deliberate scope decisions for v1 (see plan file, not hidden):  |
//|   - No EaIngestClient.mqh integration (explicitly excluded).     |
//|   - Timeframe roles are fixed (H4 bias / H1 structure / M15 POI /|
//|     M5 trigger / D1 for ATR+PDH/PDL), not input-configurable -   |
//|     simplifies indicator-handle management for v1.               |
//|   - TP1 is managed manually every tick (partial close), not via  |
//|     a broker-side TP field, because MT5 fully closes a position  |
//|     when its own TP is hit rather than partially closing it. The |
//|     broker-side TP field is instead set to the runner cap (2000  |
//|     pts) purely as a safety net if the terminal disconnects.     |
//|   - News filter is a manual CSV time list, no calendar API.      |
//|   - Setup B does not run the full 6-point OB/POI scoring rubric  |
//|     (its zone is a broken level/retest, not an OB) - it is       |
//|     graded as a flat "A" (0.75% risk), halved if counter-trend.  |
//|                                                                    |
//|  1 point = $0.01 of XAUUSD price always (100 points = $1 move).  |
//|  0.01 lot = $0.01 P&L per point (contract size 100 oz).           |
//|                                                                    |
//|  IMPORTANT: this file has not been compiled or backtested yet.   |
//|  Run metaeditor64.exe /compile before use, then verify in        |
//|  Strategy Tester visual mode before any demo/live deployment.    |
//|  This is not investment advice.                                  |
//+------------------------------------------------------------------+
#property copyright "Custom EA - SMC Day Trade"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

CTrade trade;

#define SETUP_A 0
#define SETUP_B 1
#define SETUP_C 2
#define SWING_CAP 40
#define OB_CAP 20
#define FVG_CAP 20

enum EaState
{
   STATE_IDLE,
   STATE_ARMED,
   STATE_ACTIVE,
   STATE_RUNNER,
   STATE_BLOCKED
};

//==================== INPUTS ====================
input group "=== General Settings ==="
input ulong  InpMagicNumber          = 20260917;  // Magic Number
input int    InpSlippage             = 30;        // Slippage (points, 0.01 USD units)
input int    InpMaxOpenPositions     = 1;         // Max concurrent positions (single-position-building; reserved)
input int    InpMaxTradesPerDay      = 6;         // Daily entry cap

input group "=== Structure / Swing Detection ==="
input int    InpSwingFractalN        = 2;         // Fractal bars each side (N)

input group "=== Displacement Test ==="
input int    InpDispAvgBodyLookback  = 10;        // Bars for avg body baseline
input double InpDispBodyMult         = 1.5;       // Body >= this x avg body
input int    InpAtrPeriodStructure   = 14;        // ATR period (all timeframes)
input double InpDispMaxWickPct       = 25.0;      // Max opposing wick % of range to count as displacement
input double InpDispCloseExtremePct  = 25.0;      // Close must be within this % of the extreme

input group "=== Order Block / FVG ==="
input double InpObBodyRefineUsd      = 4.00;      // OB range > this $ -> refine zone to candle body
input double InpObMitigationPct      = 50.0;      // % of OB body traded+closed through = mitigated
input double InpFvgMinGapPoints      = 50;        // Minimum FVG size on M15 (points)
input int    InpZoneMaxAgeHours      = 72;        // OB/FVG zones older than this stop counting as POI or obstacle (0 = never expire)

input group "=== POI Scoring / Grading ==="
input double InpMajorLevelTolUsd     = 1.00;      // Tolerance for "at a major level" tests
input double InpRoundLevelStepUsd    = 50.0;      // Round-level spacing
input double InpEqhEqlTolPoints      = 40;        // EQH/EQL clustering tolerance (points)
input int    InpPoiGradeAPlusMin     = 5;         // Score >= this = A+ (1.0% risk)
input int    InpPoiGradeAMin         = 4;         // Score >= this = A (0.75% risk)
input int    InpPoiGradeBMin         = 3;         // Score >= this = B (0.5% risk, trigger>=5)

input group "=== Trigger Candle Scoring ==="
input double InpPinBarMinWickPct     = 60.0;      // Min wick % of range for pin bar
input double InpEngulfMinBodyMult    = 1.0;       // Engulfing body >= prior body x this
input double InpTriggerCloseRangePct = 70.0;      // Close position threshold
input double InpTriggerAtrMult       = 0.5;       // Candle size >= this x ATR(14) M5
input int    InpTriggerScoreMinA     = 4;         // Min trigger score, grade A/A+
input int    InpTriggerScoreMinB     = 5;         // Min trigger score, grade B

input group "=== Setup A - Trend Pullback ==="
input bool   InpEnableSetupA         = true;      // Enable Setup A
input double InpSlBufferPoints       = 40;        // SL buffer beyond structure/OB extreme (+ spread)
input double InpTp1MinPoints         = 300;       // TP1 minimum distance
input double InpTp1MaxPoints         = 500;       // TP1 default/maximum distance
input double InpRunnerMinPoints      = 1000;      // Runner target minimum distance
input double InpRunnerMaxPoints      = 2000;      // Runner target / hard-exit distance
input double InpMaxSlToTp1Ratio      = 1.2;       // Hard risk gate at entry: reject if the actual SL distance would exceed TP1 x this
input int    InpSetupAExpiryHours    = 8;         // Give up watching an armed Setup A after this many hours with no trigger
input double InpMaxZoneWatchPoints   = 2000;      // Give up watching (not a risk gate) once price drifts this far from the zone while armed

input group "=== Setup B - Break and Retest ==="
input bool   InpEnableSetupB         = true;      // Enable Setup B
input double InpAsianRangeAtrPct     = 50.0;      // Asian range must be < this % of D1 ATR(14)
input int    InpRetestExpiryMinutes  = 120;       // Retest must occur within this window
input double InpSetupBCounterTrendRiskMult = 0.5; // Risk multiplier if counter to H1 bias
input int    InpAsianStartHour       = 0;         // Asian session start hour (broker time)
input int    InpAsianEndHour         = 6;         // Asian session end hour (broker time)

input group "=== Setup C - Liquidity Sweep + CHoCH ==="
input bool   InpEnableSetupC         = true;      // Enable Setup C
input double InpSetupCFixedRiskPct   = 0.5;       // Always 0.5% regardless of POI grade

input group "=== Runner Trail Milestones ==="
input bool   InpUseRunnerMilestones     = true;   // Apply milestone trailing
input double InpRunnerLockTriggerPts    = 700;    // Profit level that locks +InpRunnerLockPts
input double InpRunnerLockPts           = 300;
input bool   InpRunnerHalfCloseAt1000   = false;  // Optional/discretionary half-close
input double InpRunnerHalfCloseTriggerPts = 1000;
input double InpRunnerHardExitPts       = 2000;   // Hard exit profit cap
input int    InpMomentumExhaustionLookback = 3;   // Bars for shrinking-body / opposing-wick exhaustion proxy

input group "=== Risk Management / Daily Guardrails ==="
input double InpDailyLossStopPct     = 3.0;       // Stop new entries after this % realized loss
input int    InpMaxConsecutiveLosses = 3;         // Stop after N consecutive losing trades
input double InpDailyProfitTargetPct = 3.0;       // Halve risk (or stop) after this % realized profit
input bool   InpProfitTargetStopsTrading = false; // false = halve risk, true = stop entirely

input group "=== News Window Filter (manual list, no calendar API) ==="
input bool   InpUseNewsFilter        = false;
input string InpNewsWindowsCsv       = "";        // "YYYY.MM.DD HH:MM,YYYY.MM.DD HH:MM,..." parsed in OnInit
input int    InpNewsPreBufferMin     = 15;
input int    InpNewsPostBufferMin    = 30;

input group "=== Session Filter (broker/server time) ==="
input int    InpSessionStartHour     = 7;         // London open
input int    InpSessionEndHour       = 23;
input bool   InpAvoidSunday          = true;

input group "=== Safety - No Overnight/Weekend Positions ==="
input int    InpFlattenBufferMinutes     = 20;    // Flatten this many minutes before session close
input int    InpFridayFallbackCutoffHour = 20;    // Friday cutoff hour

input group "=== Spread Filter ==="
input double InpMaxSpreadPoints      = 300;

input group "=== Diagnostics ==="
input bool   InpShowComment          = true;      // Comment() dashboard
input bool   InpVerboseLogging       = true;      // Print() scoring/state decisions
input bool   InpDrawDebugObjects     = false;     // Draw swing/BOS/CHoCH/OB markers on chart (visual verification only)

//==================== TYPES ====================
struct SwingPoint
{
   datetime time;
   double   price;
   bool     isHigh;
   bool     taken;
};

struct StructureState
{
   int      trend;
   double   lastSwingHighPrice;
   datetime lastSwingHighTime;
   double   lastSwingLowPrice;
   datetime lastSwingLowTime;
   datetime lastBosTime;
   int      lastBosDir;
   datetime lastChochTime;
   int      lastChochDir;
};

struct ObCandidate
{
   datetime time;
   double   high;
   double   low;
   double   bodyHigh;
   double   bodyLow;
   bool     isBullish;
   bool     mitigated;
};

struct FvgCandidate
{
   datetime time;
   double   top;
   double   bottom;
   bool     isBullish;
   bool     filled;
};

struct EqualLevel
{
   double   price;
   bool     isHigh;
   bool     swept;
   datetime lastTime;
   int      touchCount;
};

struct SetupCandidate
{
   int      setupType;
   int      direction;
   int      poiGrade;
   double   riskPercent;
   double   zoneHigh;
   double   zoneLow;
   double   invalidationPrice;
   datetime armedTime;
   datetime expiryTime;
   int      requiredTriggerScore;
};

struct TradeContext
{
   ulong    positionTicket;
   int      setupType;
   int      direction;
   double   entryPrice;
   double   originalSl;
   double   originalVolume;
   double   tp1Price;
   bool     tp1Done;
   int      beautifulScore;
   double   runnerTarget;
   double   trailAnchor;
   datetime entryTime;
   datetime trailBosTime;
   bool     halfClosedAt1000;
};

//==================== GLOBALS ====================
double   g_pt    = 0.01;
double   g_scale = 1.0;
EaState  g_state = STATE_IDLE;
string   g_blockReason = "";
double   g_riskMultiplier = 1.0;

int      hAtrH4=INVALID_HANDLE, hAtrH1=INVALID_HANDLE, hAtrM15=INVALID_HANDLE, hAtrM5=INVALID_HANDLE, hAtrD1=INVALID_HANDLE;

datetime g_lastBarH4=0, g_lastBarH1=0, g_lastBarM15=0, g_lastBarM5=0;
bool     g_newBarM5=false;

SwingPoint g_swingsH4[];
SwingPoint g_swingsH1[];
SwingPoint g_swingsM15[];
SwingPoint g_swingsM5[];

StructureState g_structH4, g_structH1, g_structM15, g_structM5;

ObCandidate  g_obListM15[];
FvgCandidate g_fvgListM15[];
ObCandidate  g_obListM5[];
FvgCandidate g_fvgListM5[];

EqualLevel g_eqHighs[];
EqualLevel g_eqLows[];

SetupCandidate g_setup;
TradeContext   g_trade;

datetime g_newsWindows[];

//==================== POINT / LOT HELPERS ====================
double NormPrice(double p)
{
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0) ts = _Point;
   return NormalizeDouble(MathRound(p/ts)*ts, _Digits);
}

double NormLot(double lot)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double mn   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0) step = 0.01;
   lot = MathFloor(lot/step + 1e-9) * step;
   lot = MathMax(mn, MathMin(mx, lot));
   int digits = (int)MathMax(0, MathCeil(-MathLog10(step)));
   return NormalizeDouble(lot, digits);
}

void LogEvent(string msg)
{
   if(InpVerboseLogging) Print("[SMC] ", msg);
}

//==================== DEBUG CHART DRAWING (visual verification only) ====================
string DbgTfTag(ENUM_TIMEFRAMES tf)
{
   if(tf==PERIOD_H4)  return "H4";
   if(tf==PERIOD_H1)  return "H1";
   if(tf==PERIOD_M15) return "M15";
   if(tf==PERIOD_M5)  return "M5";
   return "TF";
}

void DrawSwingMarker(ENUM_TIMEFRAMES tf, datetime t, double price, bool isHigh)
{
   if(!InpDrawDebugObjects) return;
   string name = StringFormat("SMCDBG_%s_SW_%d_%s", DbgTfTag(tf), (long)t, isHigh?"H":"L");
   if(ObjectFind(0,name)>=0) return;
   ObjectCreate(0, name, OBJ_ARROW, 0, t, price);
   ObjectSetInteger(0, name, OBJPROP_ARROWCODE, isHigh?234:233);
   ObjectSetInteger(0, name, OBJPROP_COLOR, isHigh?clrRed:clrLime);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, StringFormat("%s swing %s @ %.2f", DbgTfTag(tf), isHigh?"HIGH":"LOW", price));
}

void DrawEventLabel(ENUM_TIMEFRAMES tf, datetime t, double price, string text, color clr)
{
   if(!InpDrawDebugObjects) return;
   string name = StringFormat("SMCDBG_%s_EV_%d_%s", DbgTfTag(tf), (long)t, text);
   if(ObjectFind(0,name)>=0) return;
   ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
   ObjectSetString(0, name, OBJPROP_TEXT, StringFormat("%s %s", DbgTfTag(tf), text));
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
}

void DrawObZoneDbg(ENUM_TIMEFRAMES tf, const ObCandidate &ob)
{
   if(!InpDrawDebugObjects) return;
   string name = StringFormat("SMCDBG_%s_OB_%d", DbgTfTag(tf), (long)ob.time);
   if(ObjectFind(0,name)>=0) return;
   datetime t2 = ob.time + PeriodSeconds(tf)*30;
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, ob.time, ob.high, t2, ob.low);
   ObjectSetInteger(0, name, OBJPROP_COLOR, ob.isBullish?clrDodgerBlue:clrOrange);
   ObjectSetInteger(0, name, OBJPROP_FILL, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
}

void ClearDebugObjects()
{
   ObjectsDeleteAll(0, "SMCDBG_");
}

//==================== NEW-BAR / ATR HELPERS ====================
bool IsNewBarTF(ENUM_TIMEFRAMES tf, datetime &lastTime)
{
   datetime t = iTime(_Symbol, tf, 0);
   if(t != lastTime)
   {
      lastTime = t;
      return true;
   }
   return false;
}

int AtrHandleFor(ENUM_TIMEFRAMES tf)
{
   if(tf==PERIOD_H4)  return hAtrH4;
   if(tf==PERIOD_H1)  return hAtrH1;
   if(tf==PERIOD_M15) return hAtrM15;
   if(tf==PERIOD_M5)  return hAtrM5;
   if(tf==PERIOD_D1)  return hAtrD1;
   return INVALID_HANDLE;
}

double GetAtr(ENUM_TIMEFRAMES tf, int shift)
{
   int h = AtrHandleFor(tf);
   if(h==INVALID_HANDLE) return 0;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(h, 0, shift, 1, buf) != 1) return 0;
   return buf[0];
}

//==================== RING BUFFER TRIM HELPERS ====================
void TrimSwings(SwingPoint &list[], int cap)
{
   int n = ArraySize(list);
   if(n <= cap) return;
   int remove = n - cap;
   for(int i=0; i<cap; i++) list[i] = list[i+remove];
   ArrayResize(list, cap);
}

void TrimOb(ObCandidate &list[], int cap)
{
   int n = ArraySize(list);
   if(n <= cap) return;
   int remove = n - cap;
   for(int i=0; i<cap; i++) list[i] = list[i+remove];
   ArrayResize(list, cap);
}

void TrimFvg(FvgCandidate &list[], int cap)
{
   int n = ArraySize(list);
   if(n <= cap) return;
   int remove = n - cap;
   for(int i=0; i<cap; i++) list[i] = list[i+remove];
   ArrayResize(list, cap);
}

void AppendSwing(SwingPoint &list[], datetime t, double price, bool isHigh, int cap)
{
   int n = ArraySize(list);
   if(n>0 && list[n-1].time==t && list[n-1].isHigh==isHigh) return;
   ArrayResize(list, n+1);
   list[n].time = t;
   list[n].price = price;
   list[n].isHigh = isHigh;
   list[n].taken = false;
   TrimSwings(list, cap);
}

void AppendOb(ObCandidate &list[], ObCandidate &item, int cap)
{
   int n = ArraySize(list);
   ArrayResize(list, n+1);
   list[n] = item;
   TrimOb(list, cap);
}

void AppendFvg(FvgCandidate &list[], FvgCandidate &item, int cap)
{
   int n = ArraySize(list);
   ArrayResize(list, n+1);
   list[n] = item;
   TrimFvg(list, cap);
}

//==================== STRUCTURE / SWING DETECTION ====================
bool IsSwingHigh(ENUM_TIMEFRAMES tf, int center, int n)
{
   double h = iHigh(_Symbol, tf, center);
   if(h<=0) return false;
   for(int i=1; i<=n; i++)
   {
      if(iHigh(_Symbol, tf, center-i) >= h) return false;
      if(iHigh(_Symbol, tf, center+i) >= h) return false;
   }
   return true;
}

bool IsSwingLow(ENUM_TIMEFRAMES tf, int center, int n)
{
   double l = iLow(_Symbol, tf, center);
   if(l<=0) return false;
   for(int i=1; i<=n; i++)
   {
      if(iLow(_Symbol, tf, center-i) <= l) return false;
      if(iLow(_Symbol, tf, center+i) <= l) return false;
   }
   return true;
}

void UpdateSwingList(ENUM_TIMEFRAMES tf, SwingPoint &list[], int cap)
{
   int center = InpSwingFractalN;
   if(IsSwingHigh(tf, center, InpSwingFractalN))
   {
      datetime t = iTime(_Symbol,tf,center);
      double   p = iHigh(_Symbol,tf,center);
      AppendSwing(list, t, p, true, cap);
      DrawSwingMarker(tf, t, p, true);
   }
   if(IsSwingLow(tf, center, InpSwingFractalN))
   {
      datetime t = iTime(_Symbol,tf,center);
      double   p = iLow(_Symbol,tf,center);
      AppendSwing(list, t, p, false, cap);
      DrawSwingMarker(tf, t, p, false);
   }
}

bool TestDisplacement(ENUM_TIMEFRAMES tf, int shift)
{
   double body  = MathAbs(iClose(_Symbol,tf,shift) - iOpen(_Symbol,tf,shift));
   double range = iHigh(_Symbol,tf,shift) - iLow(_Symbol,tf,shift);
   if(range<=0) return false;

   double avgBody = 0;
   int lookback = InpDispAvgBodyLookback;
   for(int i=shift+1; i<=shift+lookback; i++)
      avgBody += MathAbs(iClose(_Symbol,tf,i) - iOpen(_Symbol,tf,i));
   avgBody /= lookback;

   double atr = GetAtr(tf, shift);
   bool bodyOk = (body >= avgBody*InpDispBodyMult) || (atr>0 && body >= atr);

   bool   closeUp    = iClose(_Symbol,tf,shift) > iOpen(_Symbol,tf,shift);
   double upperWick  = iHigh(_Symbol,tf,shift) - MathMax(iOpen(_Symbol,tf,shift), iClose(_Symbol,tf,shift));
   double lowerWick  = MathMin(iOpen(_Symbol,tf,shift), iClose(_Symbol,tf,shift)) - iLow(_Symbol,tf,shift);
   double opposingWick = closeUp ? lowerWick : upperWick;
   bool wickOk = (opposingWick/range*100.0) <= InpDispMaxWickPct;

   double distFromExtreme = closeUp ? (iHigh(_Symbol,tf,shift) - iClose(_Symbol,tf,shift))
                                     : (iClose(_Symbol,tf,shift) - iLow(_Symbol,tf,shift));
   bool closeExtremeOk = (distFromExtreme/range*100.0) <= InpDispCloseExtremePct;

   return bodyOk && wickOk && closeExtremeOk;
}

void UpdateStructure(ENUM_TIMEFRAMES tf, StructureState &st, bool &bosNow, bool &chochNow, int &eventDir)
{
   bosNow = false; chochNow = false; eventDir = 0;
   double   closePrice = iClose(_Symbol, tf, 1);
   datetime closeTime   = iTime(_Symbol, tf, 1);

   if(st.lastSwingHighPrice > 0 && closePrice > st.lastSwingHighPrice)
   {
      eventDir = 1;
      if(st.trend==1) { st.lastBosTime=closeTime; st.lastBosDir=1; bosNow=true; DrawEventLabel(tf, closeTime, closePrice, "BOS up", clrLime); }
      else             { st.lastChochTime=closeTime; st.lastChochDir=1; chochNow=true; DrawEventLabel(tf, closeTime, closePrice, "CHoCH up", clrAqua); }
      st.trend = 1;
      st.lastSwingHighPrice = 0;
   }
   if(st.lastSwingLowPrice > 0 && closePrice < st.lastSwingLowPrice)
   {
      eventDir = -1;
      if(st.trend==-1) { st.lastBosTime=closeTime; st.lastBosDir=-1; bosNow=true; DrawEventLabel(tf, closeTime, closePrice, "BOS dn", clrRed); }
      else              { st.lastChochTime=closeTime; st.lastChochDir=-1; chochNow=true; DrawEventLabel(tf, closeTime, closePrice, "CHoCH dn", clrMagenta); }
      st.trend = -1;
      st.lastSwingLowPrice = 0;
   }
}

void UpdateSwingReference(StructureState &st, SwingPoint &swings[])
{
   int n = ArraySize(swings);
   for(int i=n-1; i>=0; i--)
   {
      if(swings[i].isHigh && swings[i].time > st.lastSwingHighTime)
      {
         st.lastSwingHighPrice = swings[i].price;
         st.lastSwingHighTime  = swings[i].time;
         break;
      }
   }
   for(int i=n-1; i>=0; i--)
   {
      if(!swings[i].isHigh && swings[i].time > st.lastSwingLowTime)
      {
         st.lastSwingLowPrice = swings[i].price;
         st.lastSwingLowTime  = swings[i].time;
         break;
      }
   }
}

int GetH1Bias()
{
   return g_structH1.trend;
}

void GetH1ImpulseLeg(double &legHigh, double &legLow)
{
   legHigh = g_structH1.lastSwingHighPrice;
   legLow  = g_structH1.lastSwingLowPrice;
   if(legHigh<=0 || legLow<=0 || legHigh<=legLow)
   {
      legHigh = 0; legLow = DBL_MAX;
      for(int i=1; i<=20; i++)
      {
         legHigh = MathMax(legHigh, iHigh(_Symbol, PERIOD_H1, i));
         legLow  = MathMin(legLow,  iLow(_Symbol, PERIOD_H1, i));
      }
   }
}

//==================== ORDER BLOCK / FVG ====================
bool DetectOrderBlock(ENUM_TIMEFRAMES tf, int breakShift, int dir, ObCandidate &out)
{
   if(!TestDisplacement(tf, breakShift)) return false;
   int obShift = -1;
   for(int i=breakShift+1; i<=breakShift+10; i++)
   {
      bool candleBull = iClose(_Symbol,tf,i) > iOpen(_Symbol,tf,i);
      bool wantOpposite = (dir==1) ? !candleBull : candleBull;
      if(wantOpposite) { obShift = i; break; }
   }
   if(obShift < 0) return false;

   out.time     = iTime(_Symbol, tf, obShift);
   out.high     = iHigh(_Symbol, tf, obShift);
   out.low      = iLow(_Symbol, tf, obShift);
   out.bodyHigh = MathMax(iOpen(_Symbol,tf,obShift), iClose(_Symbol,tf,obShift));
   out.bodyLow  = MathMin(iOpen(_Symbol,tf,obShift), iClose(_Symbol,tf,obShift));

   double rangeUsd = out.high - out.low;
   if(rangeUsd > InpObBodyRefineUsd)
   {
      out.high = out.bodyHigh;
      out.low  = out.bodyLow;
   }
   out.isBullish = (dir==1);
   out.mitigated = false;
   return true;
}

void RefreshMitigationOb(ObCandidate &list[], ENUM_TIMEFRAMES tf)
{
   double closePrice = iClose(_Symbol, tf, 1);
   int n = ArraySize(list);
   for(int i=0; i<n; i++)
   {
      if(list[i].mitigated) continue;
      // Age-expire stale zones: an OB from days ago shouldn't still count as a live
      // POI or, especially, as a "TP1 obstacle" blocking unrelated fresh setups -
      // measured against real backtest data, unmitigated zones piling up over time
      // was the dominant reason trades were getting skipped (see session notes).
      if(InpZoneMaxAgeHours>0 && (TimeCurrent()-list[i].time) > InpZoneMaxAgeHours*3600)
      {
         list[i].mitigated = true;
         continue;
      }
      double mid = list[i].bodyLow + (list[i].bodyHigh - list[i].bodyLow) * (InpObMitigationPct/100.0);
      if(list[i].isBullish)
      {
         if(closePrice < mid) list[i].mitigated = true;
      }
      else
      {
         if(closePrice > mid) list[i].mitigated = true;
      }
   }
}

void RefreshMitigationFvg(FvgCandidate &list[], ENUM_TIMEFRAMES tf)
{
   double closePrice = iClose(_Symbol, tf, 1);
   int n = ArraySize(list);
   for(int i=0; i<n; i++)
   {
      if(list[i].filled) continue;
      if(InpZoneMaxAgeHours>0 && (TimeCurrent()-list[i].time) > InpZoneMaxAgeHours*3600)
      {
         list[i].filled = true;
         continue;
      }
      if(list[i].isBullish  && closePrice < list[i].bottom) list[i].filled = true;
      if(!list[i].isBullish && closePrice > list[i].top)    list[i].filled = true;
   }
}

bool DetectFvg(ENUM_TIMEFRAMES tf, int shiftNewest, FvgCandidate &out)
{
   int s1 = shiftNewest;
   int s3 = shiftNewest + 2;
   double lowNewest  = iLow(_Symbol, tf, s1);
   double highOldest = iHigh(_Symbol, tf, s3);
   double highNewest = iHigh(_Symbol, tf, s1);
   double lowOldest  = iLow(_Symbol, tf, s3);
   double minGap = InpFvgMinGapPoints * g_pt;

   if(lowNewest > highOldest && (lowNewest - highOldest) >= minGap)
   {
      out.time=iTime(_Symbol,tf,s1); out.top=lowNewest; out.bottom=highOldest; out.isBullish=true; out.filled=false;
      return true;
   }
   if(highNewest < lowOldest && (lowOldest - highNewest) >= minGap)
   {
      out.time=iTime(_Symbol,tf,s1); out.top=lowOldest; out.bottom=highNewest; out.isBullish=false; out.filled=false;
      return true;
   }
   return false;
}

bool FvgOverlapsZone(const FvgCandidate &fvg, double zoneHigh, double zoneLow)
{
   return !(fvg.top < zoneLow || fvg.bottom > zoneHigh);
}

//==================== MAJOR LEVELS / LIQUIDITY ====================
double GetPDH() { return iHigh(_Symbol, PERIOD_D1, 1); }
double GetPDL() { return iLow(_Symbol, PERIOD_D1, 1); }

void GetAsianSessionRange(double &high, double &low)
{
   high = 0; low = DBL_MAX;
   MqlDateTime nowStruct;
   TimeToStruct(TimeCurrent(), nowStruct);
   datetime dayStart = TimeCurrent() - (nowStruct.hour*3600 + nowStruct.min*60 + nowStruct.sec);
   datetime winStart = dayStart + InpAsianStartHour*3600;
   datetime winEnd   = dayStart + InpAsianEndHour*3600;
   for(int i=1; i<200; i++)
   {
      datetime t = iTime(_Symbol, PERIOD_M15, i);
      if(t < winStart) break;
      if(t <= winEnd)
      {
         high = MathMax(high, iHigh(_Symbol,PERIOD_M15,i));
         low  = MathMin(low,  iLow(_Symbol,PERIOD_M15,i));
      }
   }
   if(low==DBL_MAX) low = 0;
}

bool IsRoundLevel(double price, double tolUsd)
{
   double rem  = MathMod(price, InpRoundLevelStepUsd);
   double dist = MathMin(rem, InpRoundLevelStepUsd-rem);
   return dist <= tolUsd;
}

bool IsLevelSwept(double price, bool isHigh, datetime sinceTime)
{
   for(int i=1; i<200; i++)
   {
      datetime t = iTime(_Symbol, PERIOD_M15, i);
      if(t < sinceTime) break;
      if(isHigh)
      {
         if(iHigh(_Symbol,PERIOD_M15,i) > price && iClose(_Symbol,PERIOD_M15,i) < price) return true;
      }
      else
      {
         if(iLow(_Symbol,PERIOD_M15,i) < price && iClose(_Symbol,PERIOD_M15,i) > price) return true;
      }
   }
   return false;
}

void PoolEqualLevels(SwingPoint &swings[], bool wantHigh, double tolPoints, EqualLevel &levels[])
{
   ArrayResize(levels, 0);
   double tolUsd = tolPoints * g_pt;
   int n = ArraySize(swings);
   for(int i=0; i<n; i++)
   {
      if(swings[i].isHigh != wantHigh) continue;
      bool merged = false;
      for(int j=0; j<ArraySize(levels); j++)
      {
         if(MathAbs(levels[j].price - swings[i].price) <= tolUsd)
         {
            levels[j].price    = (levels[j].price + swings[i].price)/2.0;
            levels[j].lastTime = swings[i].time;
            levels[j].touchCount++;
            merged = true;
            break;
         }
      }
      if(!merged)
      {
         int m = ArraySize(levels);
         ArrayResize(levels, m+1);
         levels[m].price      = swings[i].price;
         levels[m].isHigh     = wantHigh;
         levels[m].swept      = false;
         levels[m].lastTime   = swings[i].time;
         levels[m].touchCount = 1;
      }
   }
   for(int j=0; j<ArraySize(levels); j++)
      levels[j].swept = IsLevelSwept(levels[j].price, levels[j].isHigh, levels[j].lastTime);

   // A genuine "equal high/low" liquidity pool requires at least two swings clustered
   // together - a single, never-repeated swing is just ordinary structure, not a real
   // liquidity target, and treating every lone swing as one was flooding the chart
   // with "obstacles"/"major levels" (see session notes: this was the actual dominant
   // cause of low trade frequency, not stale-zone accumulation). Drop singletons here
   // so every consumer (IsMajorLevelNear, HasUnsweptLiquidityBetween,
   // FindNearestObstacleDistance) automatically only sees real EQH/EQL pools.
   for(int j=ArraySize(levels)-1; j>=0; j--)
   {
      if(levels[j].touchCount < 2)
      {
         int last = ArraySize(levels)-1;
         levels[j] = levels[last];
         ArrayResize(levels, last);
      }
   }
}

bool IsMajorLevelNear(double price, double tolUsd, string &label)
{
   if(MathAbs(price - GetPDH()) <= tolUsd) { label="PDH"; return true; }
   if(MathAbs(price - GetPDL()) <= tolUsd) { label="PDL"; return true; }
   double asianHigh, asianLow;
   GetAsianSessionRange(asianHigh, asianLow);
   if(asianHigh>0 && MathAbs(price-asianHigh)<=tolUsd) { label="AsianHigh"; return true; }
   if(asianLow>0  && MathAbs(price-asianLow)<=tolUsd)  { label="AsianLow";  return true; }
   if(IsRoundLevel(price, tolUsd)) { label="Round"; return true; }
   if(g_structH1.lastSwingHighPrice>0 && MathAbs(price-g_structH1.lastSwingHighPrice)<=tolUsd) { label="H1SwingHigh"; return true; }
   if(g_structH1.lastSwingLowPrice>0  && MathAbs(price-g_structH1.lastSwingLowPrice)<=tolUsd)  { label="H1SwingLow";  return true; }
   for(int i=0; i<ArraySize(g_eqHighs); i++)
      if(!g_eqHighs[i].swept && MathAbs(price-g_eqHighs[i].price)<=tolUsd) { label="EQH"; return true; }
   for(int i=0; i<ArraySize(g_eqLows); i++)
      if(!g_eqLows[i].swept && MathAbs(price-g_eqLows[i].price)<=tolUsd) { label="EQL"; return true; }
   label = "";
   return false;
}

bool HasUnsweptLiquidityBetween(double priceFrom, double priceTo, int direction)
{
   double lo = MathMin(priceFrom, priceTo), hi = MathMax(priceFrom, priceTo);
   for(int i=0; i<ArraySize(g_eqHighs); i++)
      if(!g_eqHighs[i].swept && g_eqHighs[i].price>lo && g_eqHighs[i].price<hi) return true;
   for(int i=0; i<ArraySize(g_eqLows); i++)
      if(!g_eqLows[i].swept && g_eqLows[i].price>lo && g_eqLows[i].price<hi) return true;
   return false;
}

double FindNearestObstacleDistance(int direction, double fromPrice)
{
   double nearest = 0;
   for(int i=0; i<ArraySize(g_obListM15); i++)
   {
      if(g_obListM15[i].mitigated) continue;
      if(g_obListM15[i].isBullish == (direction==1)) continue;
      // Only a zone with real POI quality counts as an obstacle worth skipping a
      // trade over - otherwise every minor/incidental OB blocks entries forever,
      // which measured as the dominant cause of low trade frequency (see session
      // notes: "TP1 obstacle too close" was the single biggest rejection reason).
      if(ScorePoi(g_obListM15[i], g_obListM15[i].isBullish?1:-1) < InpPoiGradeBMin) continue;
      double zoneNear = direction==1 ? g_obListM15[i].low : g_obListM15[i].high;
      if((direction==1 && zoneNear>fromPrice) || (direction==-1 && zoneNear<fromPrice))
      {
         double d = MathAbs(zoneNear-fromPrice);
         if(nearest==0 || d<nearest) nearest=d;
      }
   }
   for(int i=0; i<ArraySize(g_eqHighs); i++)
   {
      if(g_eqHighs[i].swept) continue;
      if(direction==1 && g_eqHighs[i].price>fromPrice)
      { double d=g_eqHighs[i].price-fromPrice; if(nearest==0||d<nearest) nearest=d; }
   }
   for(int i=0; i<ArraySize(g_eqLows); i++)
   {
      if(g_eqLows[i].swept) continue;
      if(direction==-1 && g_eqLows[i].price<fromPrice)
      { double d=fromPrice-g_eqLows[i].price; if(nearest==0||d<nearest) nearest=d; }
   }
   return nearest;
}

int ScorePoi(const ObCandidate &ob, int direction)
{
   int score = 1; // mandatory OB criteria already satisfied by construction
   double zoneMid = (ob.high+ob.low)/2.0;

   for(int i=0; i<ArraySize(g_fvgListM15); i++)
   {
      if(g_fvgListM15[i].filled) continue;
      if(g_fvgListM15[i].isBullish != (direction==1)) continue;
      if(FvgOverlapsZone(g_fvgListM15[i], ob.high, ob.low)) { score++; break; }
   }

   string label;
   if(IsMajorLevelNear(zoneMid, InpMajorLevelTolUsd, label)) score++;

   double curPrice = (direction==1) ? SymbolInfoDouble(_Symbol,SYMBOL_ASK) : SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(HasUnsweptLiquidityBetween(curPrice, zoneMid, direction)) score++;

   if(GetH1Bias()==direction) score++;

   double legHigh, legLow;
   GetH1ImpulseLeg(legHigh, legLow);
   if(legHigh>legLow)
   {
      double pos = (zoneMid-legLow)/(legHigh-legLow);
      if(direction==1  && pos<0.5) score++;
      if(direction==-1 && pos>0.5) score++;
   }
   return score;
}

//==================== TRIGGER CANDLE SCORING (M5, closed bars only) ====================
bool IsEngulfing(ENUM_TIMEFRAMES tf, int shift, int direction)
{
   double bodyCur  = MathAbs(iClose(_Symbol,tf,shift)   - iOpen(_Symbol,tf,shift));
   double bodyPrev = MathAbs(iClose(_Symbol,tf,shift+1) - iOpen(_Symbol,tf,shift+1));
   bool curBull  = iClose(_Symbol,tf,shift)   > iOpen(_Symbol,tf,shift);
   bool prevBull = iClose(_Symbol,tf,shift+1) > iOpen(_Symbol,tf,shift+1);
   if(direction==1  && !(curBull && !prevBull)) return false;
   if(direction==-1 && !(!curBull && prevBull)) return false;

   double curHigh  = MathMax(iOpen(_Symbol,tf,shift),   iClose(_Symbol,tf,shift));
   double curLow   = MathMin(iOpen(_Symbol,tf,shift),   iClose(_Symbol,tf,shift));
   double prevHigh = MathMax(iOpen(_Symbol,tf,shift+1), iClose(_Symbol,tf,shift+1));
   double prevLow  = MathMin(iOpen(_Symbol,tf,shift+1), iClose(_Symbol,tf,shift+1));
   bool covers = curHigh>=prevHigh && curLow<=prevLow;
   return covers && bodyCur >= bodyPrev*InpEngulfMinBodyMult;
}

bool IsPinBar(ENUM_TIMEFRAMES tf, int shift, int direction)
{
   double range = iHigh(_Symbol,tf,shift) - iLow(_Symbol,tf,shift);
   if(range<=0) return false;
   double body = MathAbs(iClose(_Symbol,tf,shift) - iOpen(_Symbol,tf,shift));
   double upperWick = iHigh(_Symbol,tf,shift) - MathMax(iOpen(_Symbol,tf,shift), iClose(_Symbol,tf,shift));
   double lowerWick = MathMin(iOpen(_Symbol,tf,shift), iClose(_Symbol,tf,shift)) - iLow(_Symbol,tf,shift);
   if(direction==1)
      return (lowerWick/range*100.0) >= InpPinBarMinWickPct && upperWick < body;
   return (upperWick/range*100.0) >= InpPinBarMinWickPct && lowerWick < body;
}

bool ClosePositionInRange(ENUM_TIMEFRAMES tf, int shift, int direction, double thresholdPct)
{
   double range = iHigh(_Symbol,tf,shift) - iLow(_Symbol,tf,shift);
   if(range<=0) return false;
   double posPct = (iClose(_Symbol,tf,shift) - iLow(_Symbol,tf,shift))/range*100.0;
   if(direction==1) return posPct >= thresholdPct;
   return posPct <= (100.0-thresholdPct);
}

int ScoreTriggerCandle(ENUM_TIMEFRAMES tf, int shift, int direction, double zoneHigh, double zoneLow)
{
   double price = iClose(_Symbol, tf, shift);
   string label;
   bool atLevel = (price>=zoneLow && price<=zoneHigh) || IsMajorLevelNear(price, InpMajorLevelTolUsd, label);
   if(!atLevel) return 0; // mandatory gate - no trade without it

   int score = 1; // gate satisfied
   if(IsEngulfing(tf,shift,direction) || IsPinBar(tf,shift,direction)) score++;
   score++; // candle is closed by construction (shift>=1 always used)
   if(ClosePositionInRange(tf,shift,direction,InpTriggerCloseRangePct)) score++;

   double body = MathAbs(iClose(_Symbol,tf,shift) - iOpen(_Symbol,tf,shift));
   double atr  = GetAtr(tf, shift);
   if(atr>0 && body >= atr*InpTriggerAtrMult) score++;

   bool breaksPriorHL = (direction==1) ? (iHigh(_Symbol,tf,shift) > iHigh(_Symbol,tf,shift+1))
                                        : (iLow(_Symbol,tf,shift)  < iLow(_Symbol,tf,shift+1));
   bool chochNow = (g_structM5.lastChochTime == iTime(_Symbol,tf,shift) && g_structM5.lastChochDir==direction);
   if(breaksPriorHL || chochNow) score++;

   return score;
}

//==================== RISK GRADE HELPER ====================
double CalcRiskPercentFromGrade(int score, bool counterTrend=false)
{
   double pct;
   if(score>=InpPoiGradeAPlusMin)      pct = 1.00;
   else if(score>=InpPoiGradeAMin)     pct = 0.75;
   else                                 pct = 0.50;
   if(counterTrend) pct *= InpSetupBCounterTrendRiskMult;
   return pct;
}

string SetupLabel(int t)
{
   if(t==SETUP_A) return "A";
   if(t==SETUP_B) return "B";
   return "C";
}

//==================== SETUP EVALUATION ====================
bool TryFindSetupA(SetupCandidate &out)
{
   if(!InpEnableSetupA) return false;
   int dir = g_structH1.trend;
   if(dir==0) return false;
   if(g_structH1.lastBosDir != dir) return false;
   if(g_structH1.lastChochDir!=0 && g_structH1.lastChochDir!=dir && g_structH1.lastChochTime > g_structH1.lastBosTime) return false;

   double legHigh, legLow;
   GetH1ImpulseLeg(legHigh, legLow);

   // A zone farther from current price than this cannot pass CalcSlTp's own
   // SL-vs-TP1 sanity check anyway (see that function), so skip it up front
   // rather than arming on a stale/far-away OB that can never actually fire.
   double curPrice = dir==1 ? SymbolInfoDouble(_Symbol,SYMBOL_ASK) : SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double maxZoneDist = InpMaxZoneWatchPoints*g_pt;

   int bestScore=-1, bestIdx=-1;
   double bestDist=DBL_MAX;
   for(int i=ArraySize(g_obListM15)-1; i>=0; i--)
   {
      if(g_obListM15[i].mitigated) continue;
      if(g_obListM15[i].isBullish != (dir==1)) continue;
      double zoneEdge = dir==1 ? g_obListM15[i].low : g_obListM15[i].high;
      double distToEdge = MathAbs(curPrice - zoneEdge);
      if(distToEdge > maxZoneDist) continue; // too far - would fail CalcSlTp's cap anyway
      double zoneMid = (g_obListM15[i].high+g_obListM15[i].low)/2.0;
      if(legHigh>legLow)
      {
         double pos = (zoneMid-legLow)/(legHigh-legLow);
         if(dir==1  && pos>=0.5) continue;
         if(dir==-1 && pos<=0.5) continue;
      }
      int sc = ScorePoi(g_obListM15[i], dir);
      if(sc<InpPoiGradeBMin) continue;
      // Prefer the nearest qualifying zone over a farther, marginally higher-graded
      // one - a trend-pullback entry should be the pullback price is actually at now.
      if(sc>bestScore || (sc==bestScore && distToEdge<bestDist)) { bestScore=sc; bestIdx=i; bestDist=distToEdge; }
   }
   if(bestIdx<0) return false;

   out.setupType = SETUP_A;
   out.direction = dir;
   out.poiGrade  = bestScore;
   out.zoneHigh  = g_obListM15[bestIdx].high;
   out.zoneLow   = g_obListM15[bestIdx].low;
   out.invalidationPrice = dir==1 ? g_obListM15[bestIdx].low - InpSlBufferPoints*g_pt
                                    : g_obListM15[bestIdx].high + InpSlBufferPoints*g_pt;
   out.armedTime  = TimeCurrent();
   out.expiryTime = TimeCurrent() + InpSetupAExpiryHours*3600;
   out.requiredTriggerScore = bestScore>=InpPoiGradeAMin ? InpTriggerScoreMinA : InpTriggerScoreMinB;
   out.riskPercent = CalcRiskPercentFromGrade(bestScore, false);
   return true;
}

bool TryFindSetupB(SetupCandidate &out)
{
   if(!InpEnableSetupB) return false;
   if(!IsAsianRangeExpansion()) return false;

   double pdh = GetPDH(), pdl = GetPDL();
   double c1 = iClose(_Symbol, PERIOD_M15, 1);
   double o1 = iOpen(_Symbol, PERIOD_M15, 1);
   double body1  = MathAbs(c1-o1);
   double range1 = iHigh(_Symbol,PERIOD_M15,1) - iLow(_Symbol,PERIOD_M15,1);
   if(range1<=0) return false;
   bool strongBody = (body1/range1*100.0) > 70.0 && TestDisplacement(PERIOD_M15,1);
   if(!strongBody) return false;

   int dir=0; double level=0;
   if(c1 > pdh)      { dir=1;  level=pdh; }
   else if(c1 < pdl) { dir=-1; level=pdl; }
   else return false;

   // Setup B does not run the full 6-point OB scoring rubric (its zone is a broken
   // level/retest, not an OB) - it is graded as a flat "A" baseline, halved if the
   // break is counter to H1 bias.
   int sc = InpPoiGradeAMin;
   bool counterTrend = (GetH1Bias()!=0 && GetH1Bias()!=dir);

   out.setupType = SETUP_B;
   out.direction = dir;
   out.poiGrade  = sc;
   out.zoneHigh  = level + InpMajorLevelTolUsd;
   out.zoneLow   = level - InpMajorLevelTolUsd;
   out.invalidationPrice = dir==1 ? level - InpSlBufferPoints*g_pt : level + InpSlBufferPoints*g_pt;
   out.armedTime  = TimeCurrent();
   out.expiryTime = TimeCurrent() + InpRetestExpiryMinutes*60;
   out.requiredTriggerScore = InpTriggerScoreMinA;
   out.riskPercent = CalcRiskPercentFromGrade(sc, counterTrend);
   return true;
}

bool TryFindSetupC(SetupCandidate &out)
{
   if(!InpEnableSetupC) return false;

   double pdh = GetPDH(), pdl = GetPDL();
   double h1 = iHigh(_Symbol,PERIOD_M15,1), l1 = iLow(_Symbol,PERIOD_M15,1), c1 = iClose(_Symbol,PERIOD_M15,1);
   double range = h1-l1;
   if(range<=0) return false;

   int dir=0; double sweptLevel=0;
   if(h1>pdh && c1<pdh)      { dir=-1; sweptLevel=h1; }
   else if(l1<pdl && c1>pdl) { dir=1;  sweptLevel=l1; }
   else return false;

   double o1 = iOpen(_Symbol,PERIOD_M15,1);
   double wick = dir==-1 ? (h1-MathMax(o1,c1)) : (MathMin(o1,c1)-l1);
   if(wick/range*100.0 < 40.0) return false;

   if(g_structM5.lastChochDir != dir) return false;
   if(TimeCurrent() - g_structM5.lastChochTime > 3*3600) return false;

   out.setupType = SETUP_C;
   out.direction = dir;
   out.poiGrade  = 0; // grade irrelevant - risk is always fixed for Setup C
   out.zoneHigh  = sweptLevel;
   out.zoneLow   = sweptLevel;
   out.invalidationPrice = dir==1 ? l1 - InpSlBufferPoints*g_pt : h1 + InpSlBufferPoints*g_pt;
   out.armedTime  = TimeCurrent();
   out.expiryTime = TimeCurrent() + 2*3600;
   out.requiredTriggerScore = InpTriggerScoreMinA;
   out.riskPercent = InpSetupCFixedRiskPct;
   return true;
}

void ScanForNewPOI()
{
   SetupCandidate cand;
   if(TryFindSetupA(cand)) { g_setup=cand; g_state=STATE_ARMED; LogEvent(StringFormat("ARMED Setup A dir=%d grade=%d", cand.direction, cand.poiGrade)); return; }
   if(TryFindSetupB(cand)) { g_setup=cand; g_state=STATE_ARMED; LogEvent(StringFormat("ARMED Setup B dir=%d", cand.direction)); return; }
   if(TryFindSetupC(cand)) { g_setup=cand; g_state=STATE_ARMED; LogEvent(StringFormat("ARMED Setup C dir=%d", cand.direction)); return; }
}

void EvaluateArmedSetup()
{
   if(g_setup.expiryTime>0 && TimeCurrent()>g_setup.expiryTime)
   {
      LogEvent("Setup expired, back to IDLE");
      g_state=STATE_IDLE;
      return;
   }
   double price = g_setup.direction==1 ? SymbolInfoDouble(_Symbol,SYMBOL_ASK) : SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(g_setup.direction==1  && price < g_setup.invalidationPrice) { LogEvent("Setup invalidated (SL side breached)"); g_state=STATE_IDLE; return; }
   if(g_setup.direction==-1 && price > g_setup.invalidationPrice) { LogEvent("Setup invalidated (SL side breached)"); g_state=STATE_IDLE; return; }
   if(GetH1Bias()!=0 && GetH1Bias()!=g_setup.direction && g_setup.setupType!=SETUP_C)
   {
      LogEvent("Setup invalidated (H1 bias flipped)");
      g_state=STATE_IDLE;
      return;
   }
   // NOTE: an earlier version of this function also force-invalidated a setup once
   // price drifted more than InpMaxZoneWatchPoints from the zone while still ARMED.
   // Measured against real backtest data that fired far more often than intended
   // (near-immediate invalidation of freshly-armed setups, collapsing trade count),
   // and is redundant with the two guards this repo already relies on: per-setup
   // expiry (Setup A: InpSetupAExpiryHours; B: InpRetestExpiryMinutes; C: its own 2h
   // window) bounds how long a stale arm can block rescanning, and CalcSlTp's strict
   // SL-vs-TP1 cap is the actual risk gate at entry time - it alone is what prevents
   // the original catastrophic-loss bug (see EA changelog / session notes), so the
   // extra pre-emptive distance check here was removed rather than re-tuned blind.

   int sc = ScoreTriggerCandle(PERIOD_M5, 1, g_setup.direction, g_setup.zoneHigh, g_setup.zoneLow);
   if(sc >= g_setup.requiredTriggerScore)
      ExecuteEntry(g_setup);
}

//==================== ENTRY EXECUTION / RISK SIZING ====================
double CalcLotFromRisk(double riskPercent, double slDistanceUsd)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * riskPercent/100.0 * g_riskMultiplier;
   double slPoints = slDistanceUsd / g_pt;
   if(slPoints<=0) return 0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double valuePerPointPerLot;
   if(tickSize>0) valuePerPointPerLot = tickValue/tickSize*g_pt;
   else            valuePerPointPerLot = 1.0; // fallback: project convention $1/point/1.0 lot

   double expected = 1.0;
   if(MathAbs(valuePerPointPerLot-expected) > expected*0.5)
      PrintFormat("WARNING: broker tick value/point (%.4f) diverges from the project's $1/point/lot convention. Verify contract size before trading live.", valuePerPointPerLot);

   double lot = riskMoney / (slPoints*valuePerPointPerLot);
   return NormLot(lot);
}

double FindNearestObstacleDistanceFromTp1(int direction, double tp1Price)
{
   return FindNearestObstacleDistance(direction, tp1Price);
}

bool CalcSlTp(const SetupCandidate &setup, double &entryPrice, double &sl, double &tp1, double &runnerTarget)
{
   double spreadUsd = SymbolInfoDouble(_Symbol,SYMBOL_ASK) - SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double buffer = spreadUsd + InpSlBufferPoints*g_pt;

   if(setup.direction==1)
   {
      entryPrice = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      sl = MathMin(setup.zoneLow, setup.invalidationPrice) - buffer;
   }
   else
   {
      entryPrice = SymbolInfoDouble(_Symbol,SYMBOL_BID);
      sl = MathMax(setup.zoneHigh, setup.invalidationPrice) + buffer;
   }

   double tp1Dist = InpTp1MaxPoints * g_pt;
   double obstacleDist = FindNearestObstacleDistance(setup.direction, entryPrice);
   if(obstacleDist>0 && obstacleDist < InpTp1MinPoints*g_pt)
      return false; // nearest obstacle too close - skip this trade entirely

   if(obstacleDist>0 && obstacleDist < tp1Dist)
      tp1Dist = MathMax(obstacleDist, InpTp1MinPoints*g_pt);

   // Sanity caps on the SL distance itself (plan spec: SL must be >= 0.5xATR(M15) and
   // <= TP1 x 1.2). Without this, a setup armed against one price level can still fire
   // after the market has gapped far away from that level by the time the M5 trigger
   // appears - the SL computed from the (now stale) zone can end up enormous relative
   // to entry, and CalcLotFromRisk's minimum-lot floor then makes the realized risk a
   // large multiple of the intended per-trade %. Reject the trade instead of taking it
   // at a nonsensical SL distance.
   double slDistCheck = MathAbs(entryPrice - sl);
   double atrM15Check = GetAtr(PERIOD_M15, 1);
   if(atrM15Check>0 && slDistCheck < atrM15Check*0.5)
      return false; // SL too tight relative to M15 volatility - skip
   if(slDistCheck > tp1Dist*InpMaxSlToTp1Ratio)
      return false; // SL too far relative to TP1 (stale/gapped zone) - skip

   tp1 = setup.direction==1 ? entryPrice+tp1Dist : entryPrice-tp1Dist;

   double runnerDist = InpRunnerMaxPoints * g_pt;
   runnerTarget = setup.direction==1 ? entryPrice+runnerDist : entryPrice-runnerDist;
   return true;
}

bool ExecuteEntry(const SetupCandidate &setup)
{
   double entry, sl, tp1, runnerTarget;
   if(!CalcSlTp(setup, entry, sl, tp1, runnerTarget))
   {
      LogEvent("Setup skipped: TP1 obstacle too close");
      g_state = STATE_IDLE;
      return false;
   }

   double slDist = MathAbs(entry-sl);
   double lot = CalcLotFromRisk(setup.riskPercent, slDist);
   if(lot<=0)
   {
      LogEvent("Setup skipped: computed lot size is zero");
      g_state = STATE_IDLE;
      return false;
   }

   string comment = StringFormat("SMC-%s-%d-%d", SetupLabel(setup.setupType), setup.poiGrade, setup.requiredTriggerScore);
   bool ok;
   if(setup.direction==1)
      ok = trade.Buy(lot, _Symbol, 0, NormPrice(sl), NormPrice(runnerTarget), comment);
   else
      ok = trade.Sell(lot, _Symbol, 0, NormPrice(sl), NormPrice(runnerTarget), comment);

   if(!ok)
   {
      PrintFormat("ExecuteEntry failed: %s", trade.ResultRetcodeDescription());
      g_state = STATE_IDLE;
      return false;
   }

   g_trade.positionTicket   = trade.ResultOrder();
   g_trade.setupType        = setup.setupType;
   g_trade.direction        = setup.direction;
   g_trade.entryPrice       = entry;
   g_trade.originalSl       = sl;
   g_trade.originalVolume   = lot;
   g_trade.tp1Price         = tp1;
   g_trade.tp1Done          = false;
   g_trade.beautifulScore   = -1;
   g_trade.runnerTarget     = runnerTarget;
   g_trade.trailAnchor      = sl;
   g_trade.entryTime        = TimeCurrent();
   g_trade.trailBosTime     = 0;
   g_trade.halfClosedAt1000 = false;

   LogEvent(StringFormat("ENTRY %s %s lot=%.2f entry=%.2f sl=%.2f tp1=%.2f runner=%.2f",
            SetupLabel(setup.setupType), setup.direction==1?"BUY":"SELL", lot, entry, sl, tp1, runnerTarget));

   g_state = STATE_ACTIVE;
   return true;
}

//==================== POSITION MANAGEMENT ====================
void ModifyPositionSl(double newSl)
{
   if(!PositionSelect(_Symbol)) return;
   double curSl = PositionGetDouble(POSITION_SL);
   double curTp = PositionGetDouble(POSITION_TP);
   bool improve = g_trade.direction==1 ? (newSl>curSl) : (curSl==0 || newSl<curSl);
   if(!improve) return;
   trade.PositionModify(_Symbol, NormPrice(newSl), curTp);
}

int EvaluateBeautifulChartScore()
{
   int score = 0;
   int dir = g_trade.direction;

   bool h1Agrees = (g_structH1.trend==dir) && !(g_structH1.lastChochDir==-dir && g_structH1.lastChochTime>=g_trade.entryTime);
   bool h4Agrees = (g_structH4.trend==dir);
   if(h1Agrees && h4Agrees) score++;

   int barsToTp1 = (int)((TimeCurrent()-g_trade.entryTime)/900) + 1;
   bool cleanRun = TestDisplacement(PERIOD_M15, 1);
   if(barsToTp1<=3 && cleanRun) score++;

   if(g_structM15.lastBosDir==dir && g_structM15.lastBosTime>=g_trade.entryTime) score++;

   double curPrice = dir==1 ? SymbolInfoDouble(_Symbol,SYMBOL_BID) : SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double obstacle = FindNearestObstacleDistance(dir, curPrice);
   if(obstacle==0 || obstacle > InpRunnerMinPoints*g_pt) score++;

   if(IsInsideSession(TimeCurrent()) && !IsNewsBlackout(TimeCurrent()+3600)) score++;

   bool counterTrend = (g_trade.setupType==SETUP_C) ||
                        (g_trade.setupType==SETUP_B && GetH1Bias()!=0 && GetH1Bias()!=dir);
   if(!counterTrend) score++;

   return score;
}

void ManageActiveTrade()
{
   if(!PositionSelect(_Symbol)) { g_state = STATE_IDLE; return; }

   double curBid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double curAsk = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   bool reachedTp1 = g_trade.direction==1 ? (curBid>=g_trade.tp1Price) : (curAsk<=g_trade.tp1Price);
   if(!reachedTp1) return;

   int score = EvaluateBeautifulChartScore();
   g_trade.beautifulScore = score;

   double remainingVol = PositionGetDouble(POSITION_VOLUME);
   double closeFraction;
   if(score<=2)      closeFraction = 1.00;
   else if(score<=4) closeFraction = 0.75;
   else               closeFraction = 0.55;

   LogEvent(StringFormat("TP1 reached, beautiful-chart score=%d -> close %.0f%%", score, closeFraction*100.0));

   if(closeFraction>=1.0)
   {
      trade.PositionClose(_Symbol);
      g_state = STATE_IDLE;
      return;
   }

   double minVol   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double closeVol = NormLot(remainingVol*closeFraction);
   if(closeVol>=remainingVol-minVol)
   {
      trade.PositionClose(_Symbol);
      g_state = STATE_IDLE;
      return;
   }
   if(closeVol>0) trade.PositionClosePartial(_Symbol, closeVol);

   double spreadUsd = curAsk-curBid;
   double newSl = g_trade.direction==1 ? g_trade.entryPrice+spreadUsd : g_trade.entryPrice-spreadUsd;
   ModifyPositionSl(newSl);

   g_trade.trailAnchor = newSl;
   g_trade.tp1Done = true;
   g_state = STATE_RUNNER;
}

bool CheckRunnerHardExit(double profitPts, string &reason)
{
   int dir = g_trade.direction;
   if(g_structM15.lastChochDir==-dir && g_structM15.lastChochTime>=g_trade.entryTime)
   { reason="M15 counter-CHoCH"; return true; }
   if(profitPts>=InpRunnerHardExitPts)
   { reason="Runner hit hard-exit profit cap"; return true; }
   if(InpUseNewsFilter && IsNewsBlackout(TimeCurrent()+15*60))
   { reason="Approaching major news"; return true; }
   if(SecondsToSessionClose() <= InpFlattenBufferMinutes*60)
   { reason="Near session close"; return true; }

   bool exhaustion = true;
   double prevBody = -1;
   for(int i=1; i<=InpMomentumExhaustionLookback; i++)
   {
      double body = MathAbs(iClose(_Symbol,PERIOD_M5,i)-iOpen(_Symbol,PERIOD_M5,i));
      if(prevBody>=0 && body>=prevBody) { exhaustion=false; break; }
      prevBody = body;
   }

   bool opposingWickBig = false;
   double range = iHigh(_Symbol,PERIOD_M5,1) - iLow(_Symbol,PERIOD_M5,1);
   if(range>0)
   {
      double o1=iOpen(_Symbol,PERIOD_M5,1), c1=iClose(_Symbol,PERIOD_M5,1);
      double opWick = (dir==1) ? (iHigh(_Symbol,PERIOD_M5,1)-MathMax(o1,c1)) : (MathMin(o1,c1)-iLow(_Symbol,PERIOD_M5,1));
      if(opWick/range*100.0 >= InpDispMaxWickPct) opposingWickBig = true;
   }
   if(exhaustion || opposingWickBig)
   { reason="Momentum exhaustion near target"; return true; }

   reason = "";
   return false;
}

void CloseRunner(string reason)
{
   LogEvent("Closing runner: "+reason);
   trade.PositionClose(_Symbol);
   g_state = STATE_IDLE;
}

void ManageRunnerTrade()
{
   if(!PositionSelect(_Symbol)) { g_state = STATE_IDLE; return; }

   double curBid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double curAsk = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double profitPts = g_trade.direction==1 ? (curBid-g_trade.entryPrice)/g_pt : (g_trade.entryPrice-curAsk)/g_pt;

   if(InpUseRunnerMilestones)
   {
      if(profitPts>=InpRunnerLockTriggerPts)
      {
         double lockPrice = g_trade.direction==1 ? g_trade.entryPrice+InpRunnerLockPts*g_pt
                                                    : g_trade.entryPrice-InpRunnerLockPts*g_pt;
         ModifyPositionSl(lockPrice);
      }

      if(g_structM15.lastBosDir==g_trade.direction && g_structM15.lastBosTime>g_trade.trailBosTime)
      {
         double newAnchor = g_trade.direction==1 ? g_structM15.lastSwingLowPrice : g_structM15.lastSwingHighPrice;
         if(newAnchor>0)
         {
            ModifyPositionSl(newAnchor);
            g_trade.trailBosTime = g_structM15.lastBosTime;
         }
      }

      if(InpRunnerHalfCloseAt1000 && !g_trade.halfClosedAt1000 && profitPts>=InpRunnerHalfCloseTriggerPts)
      {
         double vol = PositionGetDouble(POSITION_VOLUME);
         double closeVol = NormLot(vol*0.5);
         if(closeVol>0) trade.PositionClosePartial(_Symbol, closeVol);
         g_trade.halfClosedAt1000 = true;
      }
   }

   string reason;
   if(CheckRunnerHardExit(profitPts, reason)) CloseRunner(reason);
}

//==================== DAILY GUARDRAILS / FILTERS ====================
bool IsSpreadOk()
{
   double spreadPts = (SymbolInfoDouble(_Symbol,SYMBOL_ASK)-SymbolInfoDouble(_Symbol,SYMBOL_BID))/g_pt;
   return spreadPts <= InpMaxSpreadPoints;
}

int CountOpenPositions()
{
   int cnt=0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==(long)InpMagicNumber)
            cnt++;
      }
   }
   return cnt;
}

void CloseAllMyPositions()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==(long)InpMagicNumber)
            trade.PositionClose(ticket);
      }
   }
}

void GetTodayLossStats(int &lossesToday, double &realizedLossPctToday, int &consecutiveLosses, double &realizedProfitPctToday)
{
   lossesToday=0; consecutiveLosses=0; realizedLossPctToday=0; realizedProfitPctToday=0;
   MqlDateTime nowStruct;
   TimeToStruct(TimeCurrent(), nowStruct);
   datetime dayStart = TimeCurrent() - (nowStruct.hour*3600+nowStruct.min*60+nowStruct.sec);
   if(!HistorySelect(dayStart, TimeCurrent())) return;

   int total = HistoryDealsTotal();
   double netToday = 0;
   int streak = 0;
   for(int i=0; i<total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket,DEAL_MAGIC) != (long)InpMagicNumber) continue;
      if(HistoryDealGetString(ticket,DEAL_SYMBOL) != _Symbol) continue;
      long entry = HistoryDealGetInteger(ticket,DEAL_ENTRY);
      if(entry!=DEAL_ENTRY_OUT && entry!=DEAL_ENTRY_OUT_BY) continue;

      double profit = HistoryDealGetDouble(ticket,DEAL_PROFIT) + HistoryDealGetDouble(ticket,DEAL_SWAP) + HistoryDealGetDouble(ticket,DEAL_COMMISSION);
      netToday += profit;
      if(profit<0) { lossesToday++; streak++; }
      else if(profit>0) streak=0;
      consecutiveLosses = MathMax(consecutiveLosses, streak);
   }

   double dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE) - netToday;
   if(dayStartBalance>0)
   {
      if(netToday<0) realizedLossPctToday   = -netToday/dayStartBalance*100.0;
      if(netToday>0) realizedProfitPctToday =  netToday/dayStartBalance*100.0;
   }
}

int GetTodayEntryCount()
{
   MqlDateTime nowStruct;
   TimeToStruct(TimeCurrent(), nowStruct);
   datetime dayStart = TimeCurrent() - (nowStruct.hour*3600+nowStruct.min*60+nowStruct.sec);
   if(!HistorySelect(dayStart, TimeCurrent())) return 0;

   int total = HistoryDealsTotal();
   int count = 0;
   for(int i=0; i<total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket,DEAL_MAGIC) != (long)InpMagicNumber) continue;
      if(HistoryDealGetString(ticket,DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(ticket,DEAL_ENTRY)==DEAL_ENTRY_IN) count++;
   }
   return count;
}

bool IsInsideSession(datetime t)
{
   MqlDateTime s;
   TimeToStruct(t, s);
   if(InpAvoidSunday && s.day_of_week==0) return false;
   int hour = s.hour;
   if(InpSessionStartHour<=InpSessionEndHour)
      return hour>=InpSessionStartHour && hour<InpSessionEndHour;
   return hour>=InpSessionStartHour || hour<InpSessionEndHour;
}

int SecondsToSessionClose()
{
   MqlDateTime s;
   TimeToStruct(TimeCurrent(), s);
   int nowSec   = s.hour*3600+s.min*60+s.sec;
   int closeSec = InpSessionEndHour*3600;
   int remain   = closeSec - nowSec;
   if(remain<0) remain += 86400;
   return remain;
}

void EnforceNoOvernightPositions()
{
   MqlDateTime s;
   TimeToStruct(TimeCurrent(), s);
   bool fridayCutoff = (s.day_of_week==5 && s.hour>=InpFridayFallbackCutoffHour);
   bool nearClose    = SecondsToSessionClose() <= InpFlattenBufferMinutes*60;
   bool weekend      = (s.day_of_week==0 || s.day_of_week==6);

   if(fridayCutoff || nearClose || weekend)
   {
      if(CountOpenPositions()>0)
      {
         LogEvent("Flattening - session close / Friday cutoff / weekend guard");
         CloseAllMyPositions();
      }
      if(g_state==STATE_ACTIVE || g_state==STATE_RUNNER)
      {
         if(CountOpenPositions()==0) g_state=STATE_IDLE;
      }
      else if(g_state==STATE_ARMED)
      {
         g_state = STATE_IDLE;
      }
   }
}

bool IsAsianRangeExpansion()
{
   double high, low;
   GetAsianSessionRange(high, low);
   if(high<=0 || low<=0) return false;
   double range = high-low;
   double atrD1 = GetAtr(PERIOD_D1, 1);
   if(atrD1<=0) return false;
   return range <= atrD1*(InpAsianRangeAtrPct/100.0);
}

void ParseNewsWindows()
{
   ArrayResize(g_newsWindows, 0);
   if(StringLen(InpNewsWindowsCsv)==0) return;
   string parts[];
   int n = StringSplit(InpNewsWindowsCsv, ',', parts);
   for(int i=0; i<n; i++)
   {
      string s = parts[i];
      StringTrimLeft(s);
      StringTrimRight(s);
      if(StringLen(s)==0) continue;
      datetime t = StringToTime(s);
      if(t>0)
      {
         int m = ArraySize(g_newsWindows);
         ArrayResize(g_newsWindows, m+1);
         g_newsWindows[m] = t;
      }
   }
}

bool IsNewsBlackout(datetime t)
{
   if(!InpUseNewsFilter) return false;
   for(int i=0; i<ArraySize(g_newsWindows); i++)
   {
      datetime winStart = g_newsWindows[i] - InpNewsPreBufferMin*60;
      datetime winEnd   = g_newsWindows[i] + InpNewsPostBufferMin*60;
      if(t>=winStart && t<=winEnd) return true;
   }
   return false;
}

bool EvaluateDailyGuardrails()
{
   int losses, streak;
   double lossPct, profitPct;
   GetTodayLossStats(losses, lossPct, streak, profitPct);
   g_riskMultiplier = 1.0;

   if(lossPct>=InpDailyLossStopPct)               { g_blockReason="Daily loss stop reached";     return true; }
   if(streak>=InpMaxConsecutiveLosses)             { g_blockReason="Max consecutive losses reached"; return true; }
   if(GetTodayEntryCount()>=InpMaxTradesPerDay)    { g_blockReason="Max trades/day reached";      return true; }
   if(profitPct>=InpDailyProfitTargetPct)
   {
      if(InpProfitTargetStopsTrading) { g_blockReason="Daily profit target reached"; return true; }
      g_riskMultiplier = 0.5;
   }
   if(InpUseNewsFilter && IsNewsBlackout(TimeCurrent())) { g_blockReason="News blackout window";  return true; }
   if(!IsInsideSession(TimeCurrent()))              { g_blockReason="Outside trading session";    return true; }
   if(!IsSpreadOk())                                { g_blockReason="Spread too wide";            return true; }

   g_blockReason = "";
   return false;
}

//==================== BAR-CACHE ORCHESTRATION ====================
void UpdateDailyBarCaches()
{
   g_newBarM5 = false;

   if(IsNewBarTF(PERIOD_H4, g_lastBarH4))
   {
      UpdateSwingList(PERIOD_H4, g_swingsH4, SWING_CAP);
      bool bos, choch; int dir;
      UpdateStructure(PERIOD_H4, g_structH4, bos, choch, dir);
      UpdateSwingReference(g_structH4, g_swingsH4);
   }

   if(IsNewBarTF(PERIOD_H1, g_lastBarH1))
   {
      UpdateSwingList(PERIOD_H1, g_swingsH1, SWING_CAP);
      bool bos, choch; int dir;
      UpdateStructure(PERIOD_H1, g_structH1, bos, choch, dir);
      UpdateSwingReference(g_structH1, g_swingsH1);
   }

   if(IsNewBarTF(PERIOD_M15, g_lastBarM15))
   {
      UpdateSwingList(PERIOD_M15, g_swingsM15, SWING_CAP);
      bool bos, choch; int dir;
      UpdateStructure(PERIOD_M15, g_structM15, bos, choch, dir);
      if((bos||choch) && dir!=0)
      {
         ObCandidate ob;
         if(DetectOrderBlock(PERIOD_M15, 1, dir, ob))
         {
            AppendOb(g_obListM15, ob, OB_CAP);
            DrawObZoneDbg(PERIOD_M15, ob);
         }
      }
      FvgCandidate fvg;
      if(DetectFvg(PERIOD_M15, 1, fvg))
         AppendFvg(g_fvgListM15, fvg, FVG_CAP);
      UpdateSwingReference(g_structM15, g_swingsM15);
      RefreshMitigationOb(g_obListM15, PERIOD_M15);
      RefreshMitigationFvg(g_fvgListM15, PERIOD_M15);
      PoolEqualLevels(g_swingsM15, true,  InpEqhEqlTolPoints, g_eqHighs);
      PoolEqualLevels(g_swingsM15, false, InpEqhEqlTolPoints, g_eqLows);
   }

   if(IsNewBarTF(PERIOD_M5, g_lastBarM5))
   {
      g_newBarM5 = true;
      UpdateSwingList(PERIOD_M5, g_swingsM5, SWING_CAP);
      bool bos, choch; int dir;
      UpdateStructure(PERIOD_M5, g_structM5, bos, choch, dir);
      if((bos||choch) && dir!=0)
      {
         ObCandidate ob;
         if(DetectOrderBlock(PERIOD_M5, 1, dir, ob))
            AppendOb(g_obListM5, ob, OB_CAP);
      }
      FvgCandidate fvg;
      if(DetectFvg(PERIOD_M5, 1, fvg))
         AppendFvg(g_fvgListM5, fvg, FVG_CAP);
      UpdateSwingReference(g_structM5, g_swingsM5);
      RefreshMitigationOb(g_obListM5, PERIOD_M5);
      RefreshMitigationFvg(g_fvgListM5, PERIOD_M5);
   }
}

//==================== DASHBOARD ====================
void UpdateDashboard()
{
   string stateStr;
   switch(g_state)
   {
      case STATE_IDLE:    stateStr="IDLE"; break;
      case STATE_ARMED:   stateStr="ARMED"; break;
      case STATE_ACTIVE:  stateStr="ACTIVE"; break;
      case STATE_RUNNER:  stateStr="RUNNER"; break;
      case STATE_BLOCKED: stateStr="BLOCKED ("+g_blockReason+")"; break;
      default:             stateStr="?"; break;
   }
   string txt = StringFormat(
      "XAUUSD SMC Day-Trade EA\nState: %s\nH4 trend=%d  H1 trend=%d  M15 trend=%d\nNEWS FILTER: %s (%d windows)\nRisk multiplier: %.2f\nSpread OK: %s",
      stateStr, g_structH4.trend, g_structH1.trend, g_structM15.trend,
      InpUseNewsFilter?"ON":"OFF", ArraySize(g_newsWindows), g_riskMultiplier,
      IsSpreadOk()?"yes":"NO");
   Comment(txt);
}

//==================== RESTART RECONCILIATION ====================
void ReconcileStateFromBroker()
{
   if(CountOpenPositions()==0) { g_state = STATE_IDLE; return; }

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol || PositionGetInteger(POSITION_MAGIC)!=(long)InpMagicNumber) continue;

      string comment = PositionGetString(POSITION_COMMENT);
      string parts[];
      int n = StringSplit(comment, '-', parts);

      g_trade.direction      = PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? 1 : -1;
      g_trade.entryPrice     = PositionGetDouble(POSITION_PRICE_OPEN);
      g_trade.originalSl     = PositionGetDouble(POSITION_SL);
      g_trade.originalVolume = PositionGetDouble(POSITION_VOLUME);
      g_trade.entryTime      = (datetime)PositionGetInteger(POSITION_TIME);
      g_trade.setupType      = SETUP_A;
      if(n>=2)
      {
         if(parts[1]=="B") g_trade.setupType=SETUP_B;
         else if(parts[1]=="C") g_trade.setupType=SETUP_C;
      }
      g_trade.tp1Price      = g_trade.direction==1 ? g_trade.entryPrice+InpTp1MaxPoints*g_pt : g_trade.entryPrice-InpTp1MaxPoints*g_pt;
      g_trade.runnerTarget  = g_trade.direction==1 ? g_trade.entryPrice+InpRunnerMaxPoints*g_pt : g_trade.entryPrice-InpRunnerMaxPoints*g_pt;
      g_trade.trailAnchor   = g_trade.originalSl;
      g_trade.trailBosTime  = 0;
      g_trade.halfClosedAt1000 = false;

      // Heuristic (documented v1 gap, see file header): if SL already sits at/beyond
      // breakeven in the trade's favor, assume TP1 already happened and resume as a
      // runner; beautifulScore is recomputed fresh rather than perfectly restored.
      bool slBeyondEntry = g_trade.originalSl!=0 &&
                            (g_trade.direction==1 ? (g_trade.originalSl>=g_trade.entryPrice)
                                                    : (g_trade.originalSl<=g_trade.entryPrice));
      if(slBeyondEntry)
      {
         g_trade.tp1Done = true;
         g_state = STATE_RUNNER;
      }
      else
      {
         g_trade.tp1Done = false;
         g_state = STATE_ACTIVE;
      }
      return;
   }
   g_state = STATE_IDLE;
}

//==================== ENTRY POINTS ====================
int OnInit()
{
   g_pt    = 0.01;
   g_scale = g_pt/_Point;
   if(_Digits!=2 && _Digits!=3)
      PrintFormat("WARNING: %s has %d decimal digits, unusual for gold - verify point conversion before trading.", _Symbol, _Digits);

   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("WARNING: account is not in Hedging mode; this EA is designed for a hedging account.");

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints((ulong)(InpSlippage*g_scale));
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   hAtrH4  = iATR(_Symbol, PERIOD_H4,  InpAtrPeriodStructure);
   hAtrH1  = iATR(_Symbol, PERIOD_H1,  InpAtrPeriodStructure);
   hAtrM15 = iATR(_Symbol, PERIOD_M15, InpAtrPeriodStructure);
   hAtrM5  = iATR(_Symbol, PERIOD_M5,  InpAtrPeriodStructure);
   hAtrD1  = iATR(_Symbol, PERIOD_D1,  InpAtrPeriodStructure);
   if(hAtrH4==INVALID_HANDLE || hAtrH1==INVALID_HANDLE || hAtrM15==INVALID_HANDLE || hAtrM5==INVALID_HANDLE || hAtrD1==INVALID_HANDLE)
   {
      Print("Failed to create ATR indicator handles");
      return INIT_FAILED;
   }

   ParseNewsWindows();
   g_state = STATE_IDLE;
   ReconcileStateFromBroker();
   if(InpDrawDebugObjects) ClearDebugObjects();

   PrintFormat("XAUUSD_SMC_DayTrade_EA started | %s Digits=%d | 1 point=$%.2f (x%.2f broker points) | state=%d",
               _Symbol, _Digits, g_pt, g_scale, (int)g_state);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hAtrH4!=INVALID_HANDLE)  IndicatorRelease(hAtrH4);
   if(hAtrH1!=INVALID_HANDLE)  IndicatorRelease(hAtrH1);
   if(hAtrM15!=INVALID_HANDLE) IndicatorRelease(hAtrM15);
   if(hAtrM5!=INVALID_HANDLE)  IndicatorRelease(hAtrM5);
   if(hAtrD1!=INVALID_HANDLE)  IndicatorRelease(hAtrD1);
   Comment("");
}

void OnTick()
{
   UpdateDailyBarCaches();

   EnforceNoOvernightPositions();

   bool blocked = EvaluateDailyGuardrails();
   if(blocked)
   {
      if(g_state!=STATE_ACTIVE && g_state!=STATE_RUNNER) g_state = STATE_BLOCKED;
   }
   else if(g_state==STATE_BLOCKED)
   {
      g_state = STATE_IDLE;
   }

   if(g_state==STATE_ACTIVE)      ManageActiveTrade();
   else if(g_state==STATE_RUNNER) ManageRunnerTrade();

   if(g_newBarM5)
   {
      if(g_state==STATE_IDLE)        ScanForNewPOI();
      else if(g_state==STATE_ARMED)  EvaluateArmedSetup();
   }

   if(InpShowComment) UpdateDashboard();
}
