//+------------------------------------------------------------------+
//|                                        Phase0_StopGridStats.mq5  |
//|  เฟส 0: วัดสถิติระบบวาง Buy Stop / Sell Stop บน XAUUSD           |
//|  ใช้ข้อมูล M1 จำลองผังไม้หลายแบบในหลายสถานการณ์                  |
//|  ผลลัพธ์: MQL5\Files\Phase0_summary.txt และ Phase0_events.csv    |
//+------------------------------------------------------------------+
#property copyright "Stop Grid Phase 0"
#property version   "1.00"
#property script_show_inputs

enum ENUM_TZ_MODE
{
   TZ_AUTO_NY = 0, // GMT+2 ฤดูหนาว / GMT+3 ฤดูร้อน (ตาม DST อเมริกา)
   TZ_FIXED   = 1  // Offset คงที่
};

enum ENUM_CENTER_MODE
{
   CENTER_RANGE_MID = 0, // กึ่งกลางกรอบ
   CENTER_PRICE     = 1  // ราคาตอนวาง
};

//==================== INPUTS ====================
input group "=== ข้อมูล ==="
input ENUM_TZ_MODE     InpTZMode       = TZ_FIXED;      // โซนเวลา server (Exness ปัจจุบัน GMT+0)
input int              InpFixedOffset  = 0;             // Offset (ชม.) เมื่อเลือกคงที่

input group "=== ผังไม้ ==="
input string           InpLots         = "0.01,0.03,0.05"; // lot ไม้ 1,2,3
input string           InpLayouts      = "100,200,300:500;200,400,500:700;100,300,500:600"; // ระยะไม้:TP คั่นผังด้วย ;
input ENUM_CENTER_MODE InpCenterMode   = CENTER_RANGE_MID; // จุดกลาง P
input int              InpPendingExpiryMin = 120;       // Pending หมดอายุ (นาที)
input int              InpMaxHoldHours = 24;            // ถือสูงสุด (ชม.) แล้วปิดตามราคา
input double           InpSpreadPts    = 20;            // Spread เฉลี่ย (จุด, 100 = $1)
input double           InpCommissionPerLot = 0;         // ค่าคอมมิชชัน $ ต่อ lot ไป-กลับ

input group "=== S1: กรอบเอเชีย → ลอนดอนเปิด ==="
input bool             InpS1           = true;          // เปิดใช้ S1
input int              InpS1ArmBeforeMin = 15;          // วางก่อนลอนดอนเปิด (นาที)
input int              InpS1MaxRange   = 500;           // กรอบเอเชียกว้างสุด (จุด)

input group "=== S2: บีบตัวช่วงลอนดอน/นิวยอร์ก ==="
input bool             InpS2           = true;          // เปิดใช้ S2
input int              InpS2Minutes    = 120;           // ความยาวกรอบ (นาที) 120 = 8 แท่ง M15
input int              InpS2MaxRange   = 400;           // กรอบกว้างสุด (จุด)
input int              InpS2EndUTC     = 20;            // หยุดหาจังหวะ (ชม. UTC)

input group "=== S3: ก่อนนิวยอร์กเปิด ==="
input bool             InpS3           = true;          // เปิดใช้ S3
input int              InpS3RangeMin   = 40;            // ความยาวกรอบก่อนวาง (นาที)
input int              InpS3ArmBeforeMin = 5;           // วางก่อน NY เปิด (นาที)
input int              InpS3MaxRange   = 300;           // กรอบกว้างสุด (จุด)

input group "=== ตัวกรองเทรนด์ (บันทึกผลแยก) ==="
input int              InpEMAPeriod    = 200;           // EMA H1

//==================== TYPES & GLOBALS ====================
#define MAXL  5
#define NSCEN 3
#define PT    0.01   // 1 จุด = $0.01 ราคาทอง

#define OUT_NOTRIG 0
#define OUT_SL     10   // 10 + จำนวนไม้ที่ติด
#define OUT_TP     100
#define OUT_TIME   200

struct Layout
{
   int n;
   int lv[MAXL];
   int tp;
};

struct SimResult
{
   int      outcome;
   int      side;
   int      fills;
   double   gross;
   double   lots;
   double   net;
   datetime trig;
   int      exitIdx;
};

struct Stat
{
   int    armed;
   int    skipped;
   int    trig;
   int    tp;
   int    sl[MAXL];
   int    timeEx;
   double net;
   int    alTrig;
   int    alTp;
   double alNet;
};

MqlRates g_r[];
int      g_N = 0;
MqlRates g_h1[];
double   g_ema[];
datetime g_dataFrom = 0;
datetime g_dataTo   = 0;

Layout   g_lay[];
string   g_layName[];
int      g_nLay = 0;
double   g_lots[MAXL];
int      g_nLots = 0;
double   g_contract = 100;

Stat     g_stat[NSCEN * MAXL];
int      g_hTrig[NSCEN * MAXL * 24];
int      g_hTp[NSCEN * MAXL * 24];
double   g_hNet[NSCEN * MAXL * 24];
int      g_daysChecked[NSCEN];
int      g_daysObserved[NSCEN];
int      g_rangeTooWide[NSCEN];
int      g_csv = INVALID_HANDLE;

string   SCEN_NAME[NSCEN] = {"S1 Asia range -> London open", "S2 Squeeze in London/NY", "S3 Pre NY open"};

//==================== UTILITIES ====================
string Trim(string s) { StringTrimLeft(s); StringTrimRight(s); return s; }

double LotAt(int i) { return g_lots[MathMin(i, g_nLots - 1)]; }

datetime MakeDate(int y, int mon, int d, int h = 0, int mi = 0)
{
   MqlDateTime t;
   t.year = y; t.mon = mon; t.day = d; t.hour = h; t.min = mi; t.sec = 0;
   t.day_of_week = 0; t.day_of_year = 0;
   return StructToTime(t);
}

int DowOf(datetime t) { MqlDateTime s; TimeToStruct(t, s); return s.day_of_week; }

datetime NthSunday(int y, int mon, int nth)
{
   datetime d = MakeDate(y, mon, 1);
   int first = 1 + (7 - DowOf(d)) % 7;
   return MakeDate(y, mon, first + 7 * (nth - 1));
}

datetime LastSunday(int y, int mon)
{
   int ny = (mon == 12) ? y + 1 : y;
   int nm = (mon == 12) ? 1 : mon + 1;
   datetime d = MakeDate(ny, nm, 1) - 86400;
   return d - DowOf(d) * 86400;
}

bool IsUSDST(datetime utc)
{
   MqlDateTime s; TimeToStruct(utc, s);
   datetime st = NthSunday(s.year, 3, 2) + 7 * 3600;
   datetime en = NthSunday(s.year, 11, 1) + 6 * 3600;
   return utc >= st && utc < en;
}

bool IsUKDST(datetime utc)
{
   MqlDateTime s; TimeToStruct(utc, s);
   datetime st = LastSunday(s.year, 3) + 3600;
   datetime en = LastSunday(s.year, 10) + 3600;
   return utc >= st && utc < en;
}

int OffsetHoursUTC(datetime utc)
{
   if(InpTZMode == TZ_FIXED) return InpFixedOffset;
   return IsUSDST(utc) ? 3 : 2;
}

datetime ServerToUTC(datetime srv)
{
   if(InpTZMode == TZ_FIXED) return srv - InpFixedOffset * 3600;
   return srv - (IsUSDST(srv - 2 * 3600) ? 3 : 2) * 3600;
}

datetime UTCToServer(datetime utc) { return utc + OffsetHoursUTC(utc) * 3600; }

int FindIdx(datetime t) // index แรกที่ time >= t (อาจเท่ากับ g_N)
{
   int lo = 0, hi = g_N;
   while(lo < hi)
   {
      int m = (lo + hi) >> 1;
      if(g_r[m].time < t) lo = m + 1; else hi = m;
   }
   return lo;
}

void RangeHL(int i0, int i1, double &hi, double &lo)
{
   hi = -DBL_MAX; lo = DBL_MAX;
   for(int i = i0; i < i1; i++)
   {
      if(g_r[i].high > hi) hi = g_r[i].high;
      if(g_r[i].low  < lo) lo = g_r[i].low;
   }
}

void Out(int h, string line)
{
   Print(line);
   if(h != INVALID_HANDLE) FileWriteString(h, line + "\r\n");
}

//==================== INPUT PARSING ====================
bool ParseInputs()
{
   string lp[];
   int nl = StringSplit(InpLots, ',', lp);
   g_nLots = 0;
   for(int i = 0; i < nl && g_nLots < MAXL; i++)
   {
      double v = StringToDouble(Trim(lp[i]));
      if(v > 0) g_lots[g_nLots++] = v;
   }
   if(g_nLots == 0) { Print("InpLots invalid"); return false; }

   string lays[];
   int n = StringSplit(InpLayouts, ';', lays);
   ArrayResize(g_lay, 0);
   ArrayResize(g_layName, 0);
   g_nLay = 0;
   for(int i = 0; i < n && g_nLay < MAXL; i++)
   {
      string parts[];
      if(StringSplit(Trim(lays[i]), ':', parts) != 2) continue;
      string lvs[];
      int k = StringSplit(Trim(parts[0]), ',', lvs);
      if(k < 1 || k > MAXL) continue;

      Layout L;
      L.n = k;
      bool ok = true;
      for(int j = 0; j < k; j++)
      {
         L.lv[j] = (int)StringToInteger(Trim(lvs[j]));
         if(L.lv[j] <= 0 || (j > 0 && L.lv[j] <= L.lv[j - 1])) ok = false;
      }
      L.tp = (int)StringToInteger(Trim(parts[1]));
      if(L.tp <= L.lv[k - 1]) ok = false;
      if(!ok) { Print("Skip invalid layout: ", lays[i]); continue; }

      ArrayResize(g_lay, g_nLay + 1);
      ArrayResize(g_layName, g_nLay + 1);
      g_lay[g_nLay] = L;
      g_layName[g_nLay] = Trim(parts[0]) + " TP" + Trim(parts[1]);
      g_nLay++;
   }
   if(g_nLay == 0) { Print("InpLayouts invalid"); return false; }
   return true;
}

//==================== DATA ====================
bool LoadData()
{
   for(int wait = 0; wait < 40 && !IsStopped(); wait++)
   {
      if(SeriesInfoInteger(_Symbol, PERIOD_M1, SERIES_SYNCHRONIZED)) break;
      Sleep(250);
   }

   datetime currentBar = iTime(_Symbol, PERIOD_M1, 0);
   datetime serverNow = TimeTradeServer();
   bool currentBarOpen = currentBar > 0 && serverNow > 0 && currentBar + 60 > serverNow;
   datetime cutoff = currentBarOpen ? currentBar - 1 : D'2100.01.01';
   int n = -1, previous = -1;
   for(int attempt = 0; attempt < 10; attempt++)
   {
      ResetLastError();
      n = CopyRates(_Symbol, PERIOD_M1, (datetime)0, cutoff, g_r);
      if(n > 0)
      {
         if(n == previous) break; // จำนวนคงที่แล้ว ถือว่าโหลด history ที่เปิดให้ใช้ครบ
         previous = n;
         PrintFormat("Loading full M1 history... attempt %d bars %d", attempt + 1, n);
      }
      else
         PrintFormat("Loading full M1 history... attempt %d err %d", attempt + 1, GetLastError());
      Sleep(1000);
   }
   if(n <= 0) { Print("Cannot load M1 data. Download history first (View > Symbols > Bars)."); return false; }
   g_N = n;
   g_dataFrom = g_r[0].time;
   g_dataTo   = g_r[g_N - 1].time;
   PrintFormat("M1 bars loaded: %d | %s -> %s", g_N, TimeToString(g_r[0].time), TimeToString(g_r[g_N - 1].time));

   long serverFirst = 0;
   SeriesInfoInteger(_Symbol, PERIOD_M1, SERIES_SERVER_FIRSTDATE, serverFirst);
   long maxBars = TerminalInfoInteger(TERMINAL_MAXBARS);
   PrintFormat("M1 history boundary: server first %s | terminal max bars %d | last closed bar %s",
               serverFirst > 0 ? TimeToString((datetime)serverFirst) : "unknown", maxBars, TimeToString(g_dataTo));
   if(maxBars > 0 && g_N >= maxBars)
   {
      Print("ERROR: M1 history reached TERMINAL_MAXBARS. Increase Max bars in chart and rerun.");
      return false;
   }
   if(serverFirst > 0 && g_dataFrom - (datetime)serverFirst > 7 * 86400)
   {
      Print("ERROR: loaded M1 history starts later than the broker server history.");
      return false;
   }
   return true;
}

bool LoadTrend()
{
   datetime trendFrom = g_dataFrom > 60 * 86400 ? g_dataFrom - 60 * 86400 : 0;
   int n = -1, previous = -1;
   for(int attempt = 0; attempt < 5; attempt++)
   {
      n = CopyRates(_Symbol, PERIOD_H1, trendFrom, g_dataTo, g_h1);
      if(n > 0 && n == previous) break;
      previous = n;
      Sleep(250);
   }
   if(n <= InpEMAPeriod) { Print("H1 data not enough for EMA. Trend stats will be empty."); ArrayResize(g_ema, 0); return false; }
   ArrayResize(g_ema, n);
   double k = 2.0 / (InpEMAPeriod + 1);
   g_ema[0] = g_h1[0].close;
   for(int i = 1; i < n; i++) g_ema[i] = g_h1[i].close * k + g_ema[i - 1] * (1 - k);
   return true;
}

int TrendAt(datetime srv) // ใช้แท่ง H1 ที่ปิดแล้วเท่านั้น
{
   int sz = ArraySize(g_ema);
   if(sz == 0) return 0;
   int lo = 0, hi = sz - 1, ans = -1;
   while(lo <= hi)
   {
      int m = (lo + hi) >> 1;
      if(g_h1[m].time + 3600 <= srv) { ans = m; lo = m + 1; } else hi = m - 1;
   }
   if(ans < InpEMAPeriod) return 0;
   if(g_h1[ans].close > g_ema[ans]) return 1;
   if(g_h1[ans].close < g_ema[ans]) return -1;
   return 0;
}

//==================== SIMULATION ====================
// เดินราคาจาก a ไป b (ทางเดียว) คืนค่า true เมื่อรอบจบ
bool Segment(double a, double b, double P, const Layout &L,
             int &side, int &fills, double &exitPrice, int &outcome)
{
   if(a == b) return false;
   bool rising = (b > a);

   if(side == 0)
   {
      double up = P + L.lv[0] * PT;
      double dn = P - L.lv[0] * PT;
      if(rising && a < up && b >= up)       side = 1;
      else if(!rising && a > dn && b <= dn) side = -1;
      else return false;
   }

   if(side == 1)
   {
      if(rising)
      {
         while(fills < L.n && b >= P + L.lv[fills] * PT) fills++;
         if(b >= P + L.tp * PT) { exitPrice = P + L.tp * PT; outcome = OUT_TP; return true; }
      }
      else if(b <= P) { exitPrice = P; outcome = OUT_SL + fills; return true; }
   }
   else
   {
      if(!rising)
      {
         while(fills < L.n && b <= P - L.lv[fills] * PT) fills++;
         if(b <= P - L.tp * PT) { exitPrice = P - L.tp * PT; outcome = OUT_TP; return true; }
      }
      else if(b >= P) { exitPrice = P; outcome = OUT_SL + fills; return true; }
   }
   return false;
}

SimResult Simulate(int armIdx, double P, const Layout &L)
{
   SimResult r;
   r.outcome = OUT_NOTRIG; r.side = 0; r.fills = 0; r.gross = 0; r.lots = 0; r.net = 0; r.trig = 0; r.exitIdx = armIdx;

   datetime expiry = g_r[armIdx].time + InpPendingExpiryMin * 60;
   int side = 0, fills = 0, outcome = -1;
   double exitPrice = 0;
   double prev = g_r[armIdx].open;

   for(int j = armIdx; j < g_N; j++)
   {
      if(side == 0 && g_r[j].time >= expiry) { r.exitIdx = j; return r; }
      if(side != 0 && g_r[j].time >= r.trig + InpMaxHoldHours * 3600)
      {
         exitPrice = g_r[j].open; outcome = OUT_TIME; r.exitIdx = j; break;
      }

      // ลำดับราคาในแท่ง: แท่งเขียว O→L→H→C, แท่งแดง O→H→L→C
      double pts[5];
      pts[0] = prev;
      pts[1] = g_r[j].open;
      if(g_r[j].close >= g_r[j].open) { pts[2] = g_r[j].low;  pts[3] = g_r[j].high; }
      else                            { pts[2] = g_r[j].high; pts[3] = g_r[j].low;  }
      pts[4] = g_r[j].close;

      bool done = false;
      for(int s = 0; s < 4 && !done; s++)
      {
         int before = side;
         done = Segment(pts[s], pts[s + 1], P, L, side, fills, exitPrice, outcome);
         if(before == 0 && side != 0) r.trig = g_r[j].time;
      }
      prev = g_r[j].close;

      if(done) { r.exitIdx = j; break; }
      if(j == g_N - 1)
      {
         r.exitIdx = j;
         if(side == 0) return r;
         exitPrice = g_r[j].close; outcome = OUT_TIME;
      }
   }

   r.side = side; r.fills = fills; r.outcome = outcome;
   for(int i = 0; i < fills; i++)
   {
      double lot   = LotAt(i);
      double entry = P + side * L.lv[i] * PT;
      r.gross += side * (exitPrice - entry) * lot * g_contract;
      r.lots  += lot;
   }
   r.net = r.gross - r.lots * g_contract * InpSpreadPts * PT - r.lots * InpCommissionPerLot;
   return r;
}

//==================== RECORDING ====================
string OutcomeLabel(int o)
{
   if(o == OUT_NOTRIG) return "NOTRIG";
   if(o == OUT_TP)     return "TP";
   if(o == OUT_TIME)   return "TIME";
   return "SL" + IntegerToString(o - OUT_SL);
}

void Record(int scen, int l, const SimResult &r, int trend, int armIdx, double rangePts, double P)
{
   int k = scen * MAXL + l;
   g_stat[k].armed++;

   datetime armSrv = g_r[armIdx].time;
   datetime armTH  = ServerToUTC(armSrv) + 7 * 3600;
   string layoutCsv = g_layName[l];
   StringReplace(layoutCsv, ",", "/");

   if(g_csv != INVALID_HANDLE)
      FileWrite(g_csv, scen + 1, TimeToString(armSrv), TimeToString(armTH), DoubleToString(rangePts, 0),
                trend, layoutCsv, DoubleToString(P, 2), OutcomeLabel(r.outcome), r.side, r.fills,
                DoubleToString(r.lots, 2), DoubleToString(r.gross, 8), DoubleToString(r.net, 8),
                r.trig > 0 ? TimeToString(r.trig) : "",
                r.trig > 0 ? IntegerToString((int)((g_r[r.exitIdx].time - r.trig) / 60)) : "");

   if(r.outcome == OUT_NOTRIG) return;

   g_stat[k].trig++;
   g_stat[k].net += r.net;
   if(r.outcome == OUT_TP)        g_stat[k].tp++;
   else if(r.outcome == OUT_TIME) g_stat[k].timeEx++;
   else if(r.fills >= 1 && r.fills <= MAXL) g_stat[k].sl[r.fills - 1]++;

   if(trend != 0 && trend == r.side)
   {
      g_stat[k].alTrig++;
      g_stat[k].alNet += r.net;
      if(r.outcome == OUT_TP) g_stat[k].alTp++;
   }

   MqlDateTime t; TimeToStruct(ServerToUTC(r.trig) + 7 * 3600, t);
   int hk = k * 24 + t.hour;
   g_hTrig[hk]++;
   g_hNet[hk] += r.net;
   if(r.outcome == OUT_TP) g_hTp[hk]++;
}

int RunLayouts(int scen, int armIdx, double P, double rangePts)
{
   if(InpCenterMode == CENTER_PRICE) P = g_r[armIdx].open;
   int trend = TrendAt(g_r[armIdx].time);
   int maxExit = armIdx;
   double o = g_r[armIdx].open;

   for(int l = 0; l < g_nLay; l++)
   {
      if(o >= P + g_lay[l].lv[0] * PT || o <= P - g_lay[l].lv[0] * PT)
      {
         g_stat[scen * MAXL + l].skipped++; // ราคาเลยไม้แรกไปแล้วตอนวาง
         continue;
      }
      SimResult r = Simulate(armIdx, P, g_lay[l]);
      Record(scen, l, r, trend, armIdx, rangePts, P);
      if(r.exitIdx > maxExit) maxExit = r.exitIdx;
   }
   return maxExit;
}

//==================== SCENARIOS ====================
void RunDaily(int scen)
{
   datetime u0 = ServerToUTC(g_r[0].time);
   datetime u1 = ServerToUTC(g_r[g_N - 1].time);
   MqlDateTime s; TimeToStruct(u0, s);

   for(datetime day = MakeDate(s.year, s.mon, s.day); day < u1 && !IsStopped(); day += 86400)
   {
      int dow = DowOf(day);
      if(dow == 0 || dow == 6) continue;

      datetime rs, arm;
      int maxR;
      if(scen == 0)
      {
         int lonOpen = IsUKDST(day + 12 * 3600) ? 7 : 8;
         arm  = day + lonOpen * 3600 - InpS1ArmBeforeMin * 60;
         rs   = day;
         maxR = InpS1MaxRange;
      }
      else
      {
         datetime ny = day + (IsUSDST(day + 12 * 3600) ? 13 * 3600 + 1800 : 14 * 3600 + 1800);
         arm  = ny - InpS3ArmBeforeMin * 60;
         rs   = ny - InpS3RangeMin * 60;
         maxR = InpS3MaxRange;
      }

      datetime rsSrv = UTCToServer(rs), armSrv = UTCToServer(arm);
      int i0 = FindIdx(rsSrv), i1 = FindIdx(armSrv);
      if(i1 >= g_N || i1 <= i0) continue;
      if(g_r[i1].time - armSrv > 300) continue;                       // ไม่มีข้อมูลตอนวาง
      if((i1 - i0) < (int)((armSrv - rsSrv) / 60) * 0.5) continue;    // ข้อมูลขาด/วันหยุด

      g_daysChecked[scen]++;
      g_daysObserved[scen]++;
      double hi, lo;
      RangeHL(i0, i1, hi, lo);
      double rangePts = (hi - lo) / PT;
      if(rangePts > maxR) { g_rangeTooWide[scen]++; continue; }

      RunLayouts(scen, i1, (hi + lo) / 2.0, rangePts);
   }
}

void RunSqueeze()
{
   int scen = 1;
   int nextAllowed = 0;
   datetime lastObservedDay = 0;
   for(int j = InpS2Minutes; j < g_N && !IsStopped(); j++)
   {
      if(j < nextAllowed) continue;
      MqlDateTime st; TimeToStruct(g_r[j].time, st);
      if(st.min % 15 != 0) continue;

      datetime utc = ServerToUTC(g_r[j].time);
      MqlDateTime u; TimeToStruct(utc, u);
      if(u.day_of_week == 0 || u.day_of_week == 6) continue;
      datetime day = MakeDate(u.year, u.mon, u.day);
      datetime sessStart = day + (IsUKDST(utc) ? 7 : 8) * 3600;
      datetime sessEnd   = day + InpS2EndUTC * 3600;
      if(utc < sessStart || utc >= sessEnd) continue;

      int i0 = FindIdx(g_r[j].time - InpS2Minutes * 60);
      if(j - i0 < InpS2Minutes * 0.8) continue;

      if(day != lastObservedDay)
      {
         g_daysObserved[scen]++;
         lastObservedDay = day;
      }
      g_daysChecked[scen]++; // ใช้นับจำนวนจุดตรวจ
      double hi, lo;
      RangeHL(i0, j, hi, lo);
      double rangePts = (hi - lo) / PT;
      if(rangePts > InpS2MaxRange) { g_rangeTooWide[scen]++; continue; }

      int mx = RunLayouts(scen, j, (hi + lo) / 2.0, rangePts);
      nextAllowed = mx + 1;
   }
}

//==================== SUMMARY ====================
int CountWeekdays()
{
   int c = 0;
   datetime u0 = ServerToUTC(g_r[0].time), u1 = ServerToUTC(g_r[g_N - 1].time);
   MqlDateTime s; TimeToStruct(u0, s);
   for(datetime d = MakeDate(s.year, s.mon, s.day); d < u1; d += 86400)
   {
      int w = DowOf(d);
      if(w != 0 && w != 6) c++;
   }
   return MathMax(c, 1);
}

string Pct(int a, int b) { return b > 0 ? DoubleToString(100.0 * a / b, 1) + "%" : "-"; }

bool WriteSummary()
{
   int h = FileOpen("Phase0_summary.txt", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE)
   {
      PrintFormat("Cannot create Phase0_summary.txt. Error %d", GetLastError());
      return false;
   }
   int days = CountWeekdays();

   Out(h, "================ PHASE 0 SUMMARY ================");
   Out(h, StringFormat("Symbol %s | Data %s -> %s | Weekdays %d",
                       _Symbol, TimeToString(g_r[0].time, TIME_DATE), TimeToString(g_r[g_N - 1].time, TIME_DATE), days));
   Out(h, StringFormat("TZ mode %s | Spread %.0f pts | Commission $%.2f/lot | Lots %s | Center %s",
                       InpTZMode == TZ_AUTO_NY ? "AUTO NY (GMT+2/+3)" : "FIXED GMT+" + IntegerToString(InpFixedOffset),
                       InpSpreadPts, InpCommissionPerLot, InpLots,
                       InpCenterMode == CENTER_RANGE_MID ? "RANGE_MID" : "PRICE"));
   Out(h, "PASS rule: TP >= 25% of triggered AND avg net > 0 AND enough trades (S1/S3 >= 0.3/day, S2 >= 1/day)");
   Out(h, "Hours shown in Thai time (UTC+7). Intrabar path: bull O-L-H-C, bear O-H-L-C. Fills at exact level (no slippage).");

   bool enabled[NSCEN];
   enabled[0] = InpS1; enabled[1] = InpS2; enabled[2] = InpS3;

   for(int sc = 0; sc < NSCEN; sc++)
   {
      if(!enabled[sc]) continue;
      Out(h, "");
      Out(h, "---------------- " + SCEN_NAME[sc] + " ----------------");
      Out(h, StringFormat("Observed days %d | Checks %d | Range too wide %d (%s)",
                          g_daysObserved[sc], g_daysChecked[sc], g_rangeTooWide[sc],
                          Pct(g_rangeTooWide[sc], g_daysChecked[sc])));

      for(int l = 0; l < g_nLay; l++)
      {
         Stat st = g_stat[sc * MAXL + l];
         double perDay = (double)st.trig / MathMax(g_daysObserved[sc], 1);
         double avg    = st.trig > 0 ? st.net / st.trig : 0;
         double minPerDay = (sc == 1) ? 1.0 : 0.3;
         bool pass = st.trig > 0 && 100.0 * st.tp / st.trig >= 25.0 && avg > 0 && perDay >= minPerDay;

         Out(h, StringFormat("[%s] armed %d | skipped %d | triggered %d (%.2f/day) | %s",
                             g_layName[l], st.armed, st.skipped, st.trig, perDay, pass ? "PASS" : "FAIL"));

         string slTxt = "";
         for(int i = 0; i < g_lay[l].n; i++)
            slTxt += StringFormat("SL%d %s  ", i + 1, Pct(st.sl[i], st.trig));
         Out(h, StringFormat("   TP %s  %sTIME %s", Pct(st.tp, st.trig), slTxt, Pct(st.timeEx, st.trig)));
         Out(h, StringFormat("   Net total $%.2f | avg/trade $%.2f | trend-aligned: %d trades, TP %s, avg $%.2f",
                             st.net, avg, st.alTrig, Pct(st.alTp, st.alTrig),
                             st.alTrig > 0 ? st.alNet / st.alTrig : 0.0));

         string hrs = "   By TH hour (trades/TP%/avg$): ";
         for(int hr = 0; hr < 24; hr++)
         {
            int hk = (sc * MAXL + l) * 24 + hr;
            if(g_hTrig[hk] < 5) continue;
            hrs += StringFormat("%02d:[%d/%s/%.1f] ", hr, g_hTrig[hk], Pct(g_hTp[hk], g_hTrig[hk]), g_hNet[hk] / g_hTrig[hk]);
         }
         Out(h, hrs);
      }
   }
   Out(h, "=================================================");
   FileClose(h);
   return true;
}

//==================== MAIN ====================
void CheckServerOffset()
{
   for(int attempt = 0; attempt < 20 && !IsStopped(); attempt++)
   {
      if(TerminalInfoInteger(TERMINAL_CONNECTED) && TimeTradeServer() > 0) break;
      Sleep(250);
   }

   if(!TerminalInfoInteger(TERMINAL_CONNECTED) || TimeTradeServer() <= 0)
   {
      Print("WARNING: cannot verify server offset while terminal is disconnected.");
      return;
   }

   double detected = (double)(TimeTradeServer() - TimeGMT()) / 3600.0;
   int modeled = OffsetHoursUTC(TimeGMT());
   PrintFormat("Server offset now: GMT%+.1f | model uses GMT%+d", detected, modeled);
   if(MathAbs(detected - modeled) > 0.6)
      Print("WARNING: server offset differs from model. Check InpTZMode / InpFixedOffset.");
}

void OnStart()
{
   if(!ParseInputs()) return;

   string sym = _Symbol; StringToUpper(sym);
   if(StringFind(sym, "XAU") < 0 && StringFind(sym, "GOLD") < 0)
      Print("WARNING: script is designed for XAUUSD. Current symbol: ", _Symbol);

   g_contract = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   if(g_contract <= 0) g_contract = 100;

   CheckServerOffset();

   if(!LoadData()) return;
   LoadTrend();

   ZeroMemory(g_stat);
   ArrayInitialize(g_hTrig, 0);
   ArrayInitialize(g_hTp, 0);
   ArrayInitialize(g_hNet, 0);
   ArrayInitialize(g_daysChecked, 0);
   ArrayInitialize(g_daysObserved, 0);
   ArrayInitialize(g_rangeTooWide, 0);

   g_csv = FileOpen("Phase0_events.csv", FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(g_csv == INVALID_HANDLE)
   {
      PrintFormat("Cannot create Phase0_events.csv. Error %d", GetLastError());
      return;
   }
   FileWrite(g_csv, "scenario", "arm_server", "arm_thai", "range_pts", "trend", "layout", "center",
             "outcome", "side", "fills", "lots", "gross", "net", "trigger_server", "duration_min");

   Comment("Phase 0 running... S1");
   if(InpS1) RunDaily(0);
   Comment("Phase 0 running... S2");
   if(InpS2) RunSqueeze();
   Comment("Phase 0 running... S3");
   if(InpS3) RunDaily(2);

   if(g_csv != INVALID_HANDLE) FileClose(g_csv);
   bool summaryOk = WriteSummary();
   Comment("");
   if(summaryOk)
      Alert("Phase 0 done. Open File > Open Data Folder > MQL5 > Files > Phase0_summary.txt");
}
//+------------------------------------------------------------------+
