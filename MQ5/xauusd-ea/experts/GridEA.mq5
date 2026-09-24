\xEF\xBB\xBF//+------------------------------------------------------------------+
//|                                                     GridEA.mq5   |
//|  Grid EA v1.1 - XAUUSD เท่านั้น                                  |
//|  1 จุด = 0.01 ราคาทอง เสมอ (ปรับอัตโนมัติสำหรับโบรก 2 หรือ 3 ทศนิยม) |
//|  ต้องใช้บัญชี Hedging เท่านั้น                                       |
//+------------------------------------------------------------------+
#property copyright "Grid EA v1.0"
#property version   "1.10"
#property description "Trend-filtered ATR grid with basket TP and equity protection"

#include <Trade\Trade.mqh>

//==================== INPUTS ====================
input group "=== ทั่วไป ==="
input string InpSymbolKeys       = "XAUUSD,GOLD"; // ชื่อ symbol ที่อนุญาต (รองรับ suffix เช่น XAUUSDm)
input long   InpMagic            = 240901;   // Magic Number
input string InpComment          = "GridEA"; // คอมเมนต์ออเดอร์
input int    InpSlippage         = 30;       // Slippage สูงสุด (points)
input bool   InpShowPanel        = true;     // แสดงแผงข้อมูลบนกราฟ

input group "=== สัญญาณเข้าไม้แรก ==="
input bool            InpAllowBuy      = true;       // อนุญาตฝั่ง Buy
input bool            InpAllowSell     = true;       // อนุญาตฝั่ง Sell
input ENUM_TIMEFRAMES InpTrendTF       = PERIOD_H1;  // TF ตัวกรองเทรนด์
input int             InpEMAPeriod     = 200;        // EMA เทรนด์
input ENUM_TIMEFRAMES InpSignalTF      = PERIOD_M15; // TF สัญญาณ/ATR
input int             InpRSIPeriod     = 14;         // RSI Period
input double          InpRSIBuy        = 40;         // Buy เมื่อ RSI ต่ำกว่า
input double          InpRSISell       = 60;         // Sell เมื่อ RSI สูงกว่า
input bool            InpUseRangeMode  = false;      // Range mode (ADX ต่ำ = เปิดได้ 2 ฝั่ง)
input int             InpADXPeriod     = 14;         // ADX Period
input double          InpADXMax        = 20;         // ADX ต่ำกว่านี้ = ไซด์เวย์

input group "=== Grid ==="
input int    InpATRPeriod         = 14;    // ATR Period
input double InpGridATRMult       = 0.8;   // ระยะ grid = ATR x ค่านี้
input int    InpMinGridStep       = 300;   // ระยะ grid ต่ำสุด (points)
input int    InpMaxGridStep       = 1500;  // ระยะ grid สูงสุด (points)
input int    InpMaxOrdersSide     = 6;     // ไม้สูงสุดต่อฝั่ง
input int    InpMinMinutesBetween = 15;    // ห่างจากไม้ก่อนหน้าอย่างน้อย (นาที)

input group "=== Lot ==="
input bool   InpAutoLot       = false; // คำนวณ lot จากทุน
input double InpBaseLot       = 0.01;  // Lot เริ่มต้น
input double InpLotPerBalance = 2000;  // ทุนต่อ 0.01 lot (เมื่อใช้ Auto)
input double InpLotMultiplier = 1.2;   // ตัวคูณ lot (ล็อกสูงสุด 1.3)
input double InpMaxTotalLot   = 0.30;  // Lot รวมสูงสุด (สเกลตาม Auto lot)

input group "=== ปิดไม้ ==="
input int    InpTPPoints       = 300;  // TP ไม้เดียว (points)
input int    InpBasketTPPoints = 200;  // TP ร่วมจากราคาเฉลี่ย (points)
input double InpBasketTPMoney  = 0;    // ปิด basket เมื่อกำไรถึง ($) 0=ไม่ใช้
input bool   InpUseTrailing    = false;// Trailing ไม้เดียว
input int    InpTrailStart     = 250;  // เริ่ม trailing เมื่อกำไร (points)
input int    InpTrailStep      = 150;  // ระยะ SL ตามราคา (points)

input group "=== ความเสี่ยง ==="
input double InpEquityStopPct  = 20;    // Equity Stop (% DD) ปิดทั้งหมด
input double InpNoNewOrderDD   = 12;    // DD เกินนี้ ไม่เปิดไม้ใหม่ (%)
input double InpDailyLossPct   = 8;     // ขาดทุนต่อวันสูงสุด (%)
input int    InpCooldownHours  = 24;    // พักหลัง Equity Stop (ชม.)
input int    InpMaxBasketHours = 72;    // แจ้งเตือน basket อายุเกิน (ชม.)
input bool   InpCloseOldBasket = false; // ปิด basket ที่อายุเกินทิ้ง

input group "=== ตัวกรอง ==="
input int    InpMaxSpread       = 40;  // Spread สูงสุด (points)
input int    InpStartHour       = 9;   // เริ่มเปิด basket ใหม่ (ชม. server)
input int    InpEndHour         = 22;  // หยุดเปิด basket ใหม่ (ชม. server)
input int    InpSkipMondayMin   = 30;  // ข้ามช่วงเปิดวันจันทร์ (นาที)
input int    InpFridayNoNewHour = 18;  // ศุกร์ ไม่เปิด basket ใหม่หลัง (ชม.)
input bool   InpFridayCloseAll  = false;// ศุกร์ ปิดทั้งหมด
input int    InpFridayCloseHour = 22;  // ชม. ปิดทั้งหมดวันศุกร์
input string InpNewsTimes       = "";  // เวลาข่าว (server) คั่นด้วย ; เช่น 2026.10.02 15:30
input int    InpNewsBefore      = 30;  // ห้ามเทรดก่อนข่าว (นาที)
input int    InpNewsAfter       = 30;  // ห้ามเทรดหลังข่าว (นาที)

//==================== GLOBALS ====================
struct Basket
{
   int      count;
   double   lots;
   double   avgPrice;
   double   extremePrice;  // Buy = ราคาเปิดต่ำสุด, Sell = สูงสุด
   datetime lastTime;
   datetime firstTime;
   double   profit;
   void Reset() { count=0; lots=0; avgPrice=0; extremePrice=0; lastTime=0; firstTime=0; profit=0; }
};

CTrade   trade;
int      hEMA = INVALID_HANDLE, hRSI = INVALID_HANDLE, hATR = INVALID_HANDLE, hADX = INVALID_HANDLE;
Basket   g_buy, g_sell;
double   g_mult = 1.0;
double   g_pt = 0.01;    // 1 จุด = 0.01 ราคาทอง
double   g_scale = 1.0;  // จุดของ EA -> points จริงของโบรก
datetime g_news[];
datetime g_lastSignalBar = 0;
datetime g_oldAlertBuy = 0, g_oldAlertSell = 0;
string   g_gvPrefix = "";
string   g_status = "Ready";

//==================== HELPERS ====================
double Ask() { return SymbolInfoDouble(_Symbol, SYMBOL_ASK); }
double Bid() { return SymbolInfoDouble(_Symbol, SYMBOL_BID); }
int    CurrentSpread() { return (int)MathRound((Ask() - Bid()) / g_pt); } // หน่วย 0.01 ราคาทอง
int    StopsLevel()    { return (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL); }
bool   IsTester()      { return (bool)MQLInfoInteger(MQL_TESTER); }

double GVGet(string name, double def)
{
   string k = g_gvPrefix + name;
   return GlobalVariableCheck(k) ? GlobalVariableGet(k) : def;
}
void GVSet(string name, double v) { GlobalVariableSet(g_gvPrefix + name, v); }

void LogThrottled(string msg)
{
   static string   lastMsg  = "";
   static datetime lastTime = 0;
   datetime now = TimeCurrent();
   if(msg == lastMsg && now - lastTime < 300) return;
   lastMsg = msg; lastTime = now;
   Print(msg);
}

void Notify(string msg)
{
   Print(msg);
   if(!IsTester()) Alert(msg);
}

bool GetBuf(int handle, int buffer, int shift, double &val)
{
   double b[];
   if(CopyBuffer(handle, buffer, shift, 1, b) != 1) return false;
   val = b[0];
   return true;
}

double NormPrice(double p)
{
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0) ts = g_pt;
   return NormalizeDouble(MathRound(p / ts) * ts, _Digits);
}

double NormLot(double lot)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double mn   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0) step = 0.01;
   lot = MathFloor(lot / step + 1e-9) * step;
   lot = MathMax(mn, MathMin(mx, lot));
   int digits = (int)MathMax(0, MathCeil(-MathLog10(step)));
   return NormalizeDouble(lot, digits);
}

double CalcBaseLot()
{
   double base = InpBaseLot;
   if(InpAutoLot && InpLotPerBalance > 0)
      base = MathFloor(AccountInfoDouble(ACCOUNT_BALANCE) / InpLotPerBalance) * 0.01;
   if(base <= 0) base = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   return base;
}

double CalcLot(int orderIndex) // 1 = ไม้แรก
{
   return NormLot(CalcBaseLot() * MathPow(g_mult, orderIndex - 1));
}

double MaxTotalLotAllowed()
{
   if(!InpAutoLot || InpBaseLot <= 0) return InpMaxTotalLot;
   return InpMaxTotalLot * CalcBaseLot() / InpBaseLot;
}

double DrawdownPct()
{
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   if(bal <= 0) return 0;
   return MathMax(0.0, (bal - eq) / bal * 100.0);
}

double GridStepPoints()
{
   double atr;
   if(!GetBuf(hATR, 0, 1, atr)) return 0;
   double pts = atr / g_pt * InpGridATRMult;
   return MathMax((double)InpMinGridStep, MathMin((double)InpMaxGridStep, pts));
}

void ParseNews()
{
   ArrayResize(g_news, 0);
   if(StringLen(InpNewsTimes) == 0) return;
   string parts[];
   int n = StringSplit(InpNewsTimes, ';', parts);
   for(int i = 0; i < n; i++)
   {
      string s = parts[i];
      StringTrimLeft(s); StringTrimRight(s);
      if(StringLen(s) == 0) continue;
      datetime t = StringToTime(s);
      if(t > 0)
      {
         int sz = ArraySize(g_news);
         ArrayResize(g_news, sz + 1);
         g_news[sz] = t;
      }
      else Print("อ่านเวลาข่าวไม่ได้: ", s);
   }
   PrintFormat("โหลดเวลาข่าว %d รายการ", ArraySize(g_news));
}

//==================== BASKET STATE ====================
// อ่านสถานะจากออเดอร์จริงทุกครั้ง จึงทำงานต่อได้หลังรีสตาร์ท MT5
void CollectBasket(ENUM_POSITION_TYPE type, Basket &b)
{
   b.Reset();
   double sumPV = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;

      double   vol   = PositionGetDouble(POSITION_VOLUME);
      double   price = PositionGetDouble(POSITION_PRICE_OPEN);
      datetime t     = (datetime)PositionGetInteger(POSITION_TIME);

      b.count++;
      b.lots  += vol;
      sumPV   += vol * price;
      b.profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

      if(b.count == 1) b.extremePrice = price;
      else if(type == POSITION_TYPE_BUY)  b.extremePrice = MathMin(b.extremePrice, price);
      else                                b.extremePrice = MathMax(b.extremePrice, price);

      if(t > b.lastTime) b.lastTime = t;
      if(b.firstTime == 0 || t < b.firstTime) b.firstTime = t;
   }
   if(b.lots > 0) b.avgPrice = sumPV / b.lots;
}

void RefreshBaskets()
{
   CollectBasket(POSITION_TYPE_BUY,  g_buy);
   CollectBasket(POSITION_TYPE_SELL, g_sell);
}

//==================== ORDER EXECUTION ====================
bool OpenPosition(ENUM_ORDER_TYPE type, double lot, double tp, string tag)
{
   double price = (type == ORDER_TYPE_BUY) ? Ask() : Bid();
   double margin = 0;
   if(!OrderCalcMargin(type, _Symbol, lot, price, margin))
   {
      Print("OrderCalcMargin ล้มเหลว");
      return false;
   }
   if(margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
   {
      LogThrottled(StringFormat("Margin ไม่พอสำหรับ %s %.2f lot", tag, lot));
      return false;
   }

   for(int attempt = 1; attempt <= 3; attempt++)
   {
      price = (type == ORDER_TYPE_BUY) ? Ask() : Bid();
      double useTP = tp;
      if(useTP > 0 && MathAbs(useTP - price) < StopsLevel() * _Point) useTP = 0; // ให้ ManageBasketTP ตั้งทีหลัง

      string cmt = InpComment + " " + tag;
      bool ok = (type == ORDER_TYPE_BUY)
                ? trade.Buy(lot, _Symbol, price, 0, useTP, cmt)
                : trade.Sell(lot, _Symbol, price, 0, useTP, cmt);
      uint rc = trade.ResultRetcode();

      if(ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED))
      {
         PrintFormat("เปิด %s | %s %.2f lot @ %s | TP %s",
                     tag, (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), lot,
                     DoubleToString(trade.ResultPrice(), _Digits), DoubleToString(useTP, _Digits));
         return true;
      }
      PrintFormat("เปิดไม้ไม่สำเร็จ (ครั้งที่ %d): %u %s", attempt, rc, trade.ResultRetcodeDescription());
      if(rc != TRADE_RETCODE_REQUOTE && rc != TRADE_RETCODE_PRICE_CHANGED && rc != TRADE_RETCODE_PRICE_OFF)
         break;
      Sleep(300);
   }
   return false;
}

bool ClosePositions(bool all, ENUM_POSITION_TYPE type, string reason)
{
   bool allOk = true;
   int closed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(!all && (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;

      bool ok = false;
      for(int a = 0; a < 3 && !ok; a++)
      {
         ok = trade.PositionClose(ticket, (ulong)(InpSlippage * g_scale));
         if(!ok) Sleep(200);
      }
      if(ok) closed++;
      else
      {
         allOk = false;
         PrintFormat("ปิด #%I64u ไม่สำเร็จ: %s", ticket, trade.ResultRetcodeDescription());
      }
   }
   if(closed > 0) PrintFormat("ปิด %d ไม้ | เหตุผล: %s", closed, reason);
   return allOk;
}

//==================== EXIT MANAGEMENT ====================
void ManageBasketTP(ENUM_POSITION_TYPE type, Basket &b)
{
   if(b.count == 0) return;
   bool   isBuy = (type == POSITION_TYPE_BUY);
   double bid   = Bid(), ask = Ask();
   double stops = StopsLevel() * _Point;

   if(InpBasketTPMoney > 0 && b.profit >= InpBasketTPMoney)
   {
      ClosePositions(false, type, StringFormat("Basket money TP %.2f", b.profit));
      return;
   }

   double basketTarget = 0;
   if(b.count >= 2)
   {
      basketTarget = NormPrice(isBuy ? b.avgPrice + InpBasketTPPoints * g_pt
                                     : b.avgPrice - InpBasketTPPoints * g_pt);
      if((isBuy && bid >= basketTarget) || (!isBuy && ask <= basketTarget))
      {
         ClosePositions(false, type, "Basket TP reached");
         return;
      }
   }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;

      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);

      double wantTP = (b.count == 1)
                      ? NormPrice(isBuy ? open + InpTPPoints * g_pt : open - InpTPPoints * g_pt)
                      : basketTarget;

      // สำรอง: ราคาเลย TP แล้วแต่เซิร์ฟเวอร์ยังไม่ปิด
      if(b.count == 1 && ((isBuy && bid >= wantTP) || (!isBuy && ask <= wantTP)))
      {
         trade.PositionClose(ticket, (ulong)(InpSlippage * g_scale));
         continue;
      }

      double wantSL = sl;
      if(b.count == 1 && InpUseTrailing)
      {
         if(isBuy && bid - open >= InpTrailStart * g_pt)
         {
            double ns = NormPrice(bid - InpTrailStep * g_pt);
            if(ns > sl + g_pt && bid - ns >= stops) wantSL = ns;
         }
         if(!isBuy && open - ask >= InpTrailStart * g_pt)
         {
            double ns = NormPrice(ask + InpTrailStep * g_pt);
            if((sl == 0 || ns < sl - g_pt) && ns - ask >= stops) wantSL = ns;
         }
      }

      bool tpDiff = MathAbs(tp - wantTP) > g_pt * 0.5;
      bool slDiff = MathAbs(sl - wantSL) > g_pt * 0.5;
      if(!tpDiff && !slDiff) continue;

      double dist = isBuy ? wantTP - bid : ask - wantTP;
      if(dist < stops)
      {
         if(!slDiff) continue;
         wantTP = tp;
      }

      if(!trade.PositionModify(ticket, wantSL, wantTP))
         LogThrottled(StringFormat("แก้ TP/SL #%I64u ไม่สำเร็จ: %s", ticket, trade.ResultRetcodeDescription()));
   }
}

void CheckOldBasket(ENUM_POSITION_TYPE type, Basket &b, datetime now, datetime &alertedFirst)
{
   if(b.count == 0 || InpMaxBasketHours <= 0) return;
   if(now - b.firstTime < InpMaxBasketHours * 3600) return;

   string side = (type == POSITION_TYPE_BUY) ? "BUY" : "SELL";
   if(InpCloseOldBasket)
   {
      ClosePositions(false, type, side + " basket อายุเกินกำหนด");
      return;
   }
   if(alertedFirst != b.firstTime)
   {
      alertedFirst = b.firstTime;
      Notify(StringFormat("%s %s basket เปิดค้างเกิน %d ชม. (%d ไม้, P/L %.2f)",
                          _Symbol, side, InpMaxBasketHours, b.count, b.profit));
   }
}

//==================== RISK ====================
int DayKey(datetime t)
{
   MqlDateTime d;
   TimeToStruct(t, d);
   return d.year * 10000 + d.mon * 100 + d.day;
}

void CheckNewDay(datetime now)
{
   int key = DayKey(now);
   if((int)GVGet("dayKey", 0) != key)
   {
      GVSet("dayKey", key);
      GVSet("dayEquity", AccountInfoDouble(ACCOUNT_EQUITY));
      GVSet("halted", 0);
   }
}

// คืนค่า true เมื่อมีการปิดฉุกเฉินใน tick นี้
bool CheckRiskStops(datetime now)
{
   bool haveOrders = (g_buy.count + g_sell.count) > 0;
   if(!haveOrders) return false;

   double dd = DrawdownPct();
   if(dd >= InpEquityStopPct)
   {
      ClosePositions(true, POSITION_TYPE_BUY, StringFormat("EQUITY STOP (DD %.2f%%)", dd));
      GVSet("cooldown", (double)(now + InpCooldownHours * 3600));
      Notify(StringFormat("%s: Equity Stop ทำงาน DD %.2f%% พักเทรด %d ชม.", _Symbol, dd, InpCooldownHours));
      return true;
   }

   double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
   double dayEq = GVGet("dayEquity", eq);
   if(InpDailyLossPct > 0 && dayEq > 0 && GVGet("halted", 0) == 0)
   {
      double dl = (dayEq - eq) / dayEq * 100.0;
      if(dl >= InpDailyLossPct)
      {
         ClosePositions(true, POSITION_TYPE_BUY, StringFormat("DAILY LOSS %.2f%%", dl));
         GVSet("halted", 1);
         Notify(StringFormat("%s: ขาดทุนวันนี้ %.2f%% หยุดเทรดถึงวันถัดไป", _Symbol, dl));
         return true;
      }
   }

   if(InpFridayCloseAll)
   {
      MqlDateTime dt;
      TimeToStruct(now, dt);
      if(dt.day_of_week == 5 && dt.hour >= InpFridayCloseHour)
      {
         ClosePositions(true, POSITION_TYPE_BUY, "Friday close");
         return true;
      }
   }
   return false;
}

//==================== FILTERS ====================
bool IsNewsBlocked(datetime now)
{
   for(int i = 0; i < ArraySize(g_news); i++)
      if(now >= g_news[i] - InpNewsBefore * 60 && now <= g_news[i] + InpNewsAfter * 60)
         return true;
   return false;
}

bool InTradingHours(const MqlDateTime &dt)
{
   if(InpStartHour == InpEndHour) return true;
   if(InpStartHour < InpEndHour) return dt.hour >= InpStartHour && dt.hour < InpEndHour;
   return dt.hour >= InpStartHour || dt.hour < InpEndHour; // ข้ามเที่ยงคืน
}

bool CanOpenNewBasket(datetime now, string &reason)
{
   MqlDateTime dt;
   TimeToStruct(now, dt);
   if(now < (datetime)GVGet("cooldown", 0))                        { reason = "Cooldown after equity stop"; return false; }
   if(dt.day_of_week == 0 || dt.day_of_week == 6)                  { reason = "Weekend"; return false; }
   if(!InTradingHours(dt))                                         { reason = "Outside trading hours"; return false; }
   if(dt.day_of_week == 1 && dt.hour * 60 + dt.min < InpSkipMondayMin) { reason = "Monday open"; return false; }
   if(dt.day_of_week == 5 && dt.hour >= InpFridayNoNewHour)        { reason = "Friday cutoff"; return false; }
   if(CurrentSpread() > InpMaxSpread)                              { reason = "Spread too high"; return false; }
   if(IsNewsBlocked(now))                                          { reason = "News window"; return false; }
   if(DrawdownPct() >= InpNoNewOrderDD)                            { reason = "DD above no-new limit"; return false; }
   return true;
}

bool CanAddGridOrder(datetime now, string &reason)
{
   if(CurrentSpread() > InpMaxSpread)   { reason = "Spread too high"; return false; }
   if(IsNewsBlocked(now))               { reason = "News window"; return false; }
   if(DrawdownPct() >= InpNoNewOrderDD) { reason = "DD above no-new limit"; return false; }
   return true;
}

//==================== ENTRY LOGIC ====================
void TryGridAdd(ENUM_POSITION_TYPE type, Basket &b, datetime now)
{
   if(b.count == 0 || b.count >= InpMaxOrdersSide) return;
   if(now - b.lastTime < InpMinMinutesBetween * 60) return;

   double step = GridStepPoints();
   if(step <= 0) return;

   bool isBuy   = (type == POSITION_TYPE_BUY);
   bool trigger = isBuy ? (Ask() <= b.extremePrice - step * g_pt)
                        : (Bid() >= b.extremePrice + step * g_pt);
   if(!trigger) return;

   string reason;
   if(!CanAddGridOrder(now, reason))
   {
      g_status = "Grid add blocked: " + reason;
      LogThrottled(g_status);
      return;
   }

   double lot = CalcLot(b.count + 1);
   if(g_buy.lots + g_sell.lots + lot > MaxTotalLotAllowed() + 1e-9)
   {
      g_status = "Max total lot reached";
      LogThrottled(g_status);
      return;
   }

   string tag = StringFormat("%s grid #%d", isBuy ? "B" : "S", b.count + 1);
   if(OpenPosition(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, lot, 0, tag))
   {
      CollectBasket(type, b);
      ManageBasketTP(type, b);
   }
}

void TryFirstEntries(datetime now)
{
   datetime bar = iTime(_Symbol, InpSignalTF, 0);
   if(bar == 0 || bar == g_lastSignalBar) return;
   g_lastSignalBar = bar;

   if(g_buy.count > 0 && g_sell.count > 0) return;

   string reason;
   if(!CanOpenNewBasket(now, reason))
   {
      g_status = "New basket blocked: " + reason;
      return;
   }

   double ema, rsi, adx;
   double closeTrend = iClose(_Symbol, InpTrendTF, 1);
   if(closeTrend <= 0 || !GetBuf(hEMA, 0, 1, ema) || !GetBuf(hRSI, 0, 1, rsi))
   {
      g_status = "Indicator data not ready";
      return;
   }

   bool range = false;
   if(InpUseRangeMode && GetBuf(hADX, 0, 1, adx) && adx < InpADXMax) range = true;

   bool buyOK  = range || closeTrend > ema;
   bool sellOK = range || closeTrend < ema;
   g_status = StringFormat("Waiting | trend %s | RSI %.1f", range ? "RANGE" : (buyOK ? "UP" : "DOWN"), rsi);

   if(InpAllowBuy && g_buy.count == 0 && buyOK && rsi < InpRSIBuy)
   {
      double lot = CalcLot(1);
      if(g_buy.lots + g_sell.lots + lot <= MaxTotalLotAllowed() + 1e-9)
      {
         double tp = NormPrice(Ask() + InpTPPoints * g_pt);
         if(OpenPosition(ORDER_TYPE_BUY, lot, tp, "B first")) RefreshBaskets();
      }
   }

   if(InpAllowSell && g_sell.count == 0 && sellOK && rsi > InpRSISell)
   {
      double lot = CalcLot(1);
      if(g_buy.lots + g_sell.lots + lot <= MaxTotalLotAllowed() + 1e-9)
      {
         double tp = NormPrice(Bid() - InpTPPoints * g_pt);
         if(OpenPosition(ORDER_TYPE_SELL, lot, tp, "S first")) RefreshBaskets();
      }
   }
}

//==================== PANEL ====================
void DrawPanel(datetime now)
{
   if(!InpShowPanel) return;
   string s = StringFormat("GridEA v1.1 | %s | Magic %I64d\n", _Symbol, InpMagic);
   s += StringFormat("Spread %d / %d pts | Grid step %.0f pts\n", CurrentSpread(), InpMaxSpread, GridStepPoints());
   s += StringFormat("BUY : %d/%d orders | %.2f lot | avg %s | P/L %.2f\n",
                     g_buy.count, InpMaxOrdersSide, g_buy.lots,
                     g_buy.count > 0 ? DoubleToString(g_buy.avgPrice, _Digits) : "-", g_buy.profit);
   s += StringFormat("SELL: %d/%d orders | %.2f lot | avg %s | P/L %.2f\n",
                     g_sell.count, InpMaxOrdersSide, g_sell.lots,
                     g_sell.count > 0 ? DoubleToString(g_sell.avgPrice, _Digits) : "-", g_sell.profit);
   s += StringFormat("DD %.2f%% | no-new %.1f%% | stop %.1f%% | max lot %.2f\n",
                     DrawdownPct(), InpNoNewOrderDD, InpEquityStopPct, MaxTotalLotAllowed());

   datetime cd = (datetime)GVGet("cooldown", 0);
   if(GVGet("halted", 0) != 0) s += "STATUS: HALTED (daily loss)\n";
   else if(now < cd)           s += "STATUS: COOLDOWN until " + TimeToString(cd) + "\n";
   else                        s += "STATUS: " + g_status + "\n";
   Comment(s);
}

//==================== EVENT HANDLERS ====================
bool IsGoldSymbol()
{
   string sym = _Symbol;
   StringToUpper(sym);
   string keys[];
   int n = StringSplit(InpSymbolKeys, ',', keys);
   for(int i = 0; i < n; i++)
   {
      string k = keys[i];
      StringTrimLeft(k); StringTrimRight(k); StringToUpper(k);
      if(StringLen(k) > 0 && StringFind(sym, k) >= 0) return true;
   }
   return false;
}

int OnInit()
{
   if(!IsGoldSymbol())
   {
      PrintFormat("GridEA ใช้กับ XAUUSD เท่านั้น แต่กราฟนี้คือ %s", _Symbol);
      return INIT_FAILED;
   }
   // ทำให้ 1 จุดของ EA = 0.01 ราคาทองเสมอ ไม่ว่าโบรกจะมี 2 หรือ 3 ทศนิยม
   g_pt    = 0.01;
   g_scale = g_pt / _Point;
   if(_Digits != 2 && _Digits != 3)
      PrintFormat("คำเตือน: %s มี %d ทศนิยม ซึ่งไม่ปกติสำหรับทองคำ ตรวจสอบค่าจุดก่อนใช้งาน", _Symbol, _Digits);

   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("GridEA ต้องใช้บัญชี Hedging เท่านั้น");
      return INIT_FAILED;
   }
   if(InpMinGridStep <= 0 || InpMinGridStep > InpMaxGridStep || InpMaxOrdersSide < 1 ||
      InpTPPoints <= 0 || InpBasketTPPoints <= 0 || InpEquityStopPct <= 0)
   {
      Print("ค่า input ไม่ถูกต้อง: ตรวจ Grid step / Max orders / TP / Equity stop");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_mult = MathMax(1.0, MathMin(InpLotMultiplier, 1.3));
   if(InpLotMultiplier > 1.3) Print("LotMultiplier ถูกจำกัดไว้ที่ 1.3");

   hEMA = iMA(_Symbol, InpTrendTF, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hRSI = iRSI(_Symbol, InpSignalTF, InpRSIPeriod, PRICE_CLOSE);
   hATR = iATR(_Symbol, InpSignalTF, InpATRPeriod);
   hADX = iADX(_Symbol, InpTrendTF, InpADXPeriod);
   if(hEMA == INVALID_HANDLE || hRSI == INVALID_HANDLE || hATR == INVALID_HANDLE || hADX == INVALID_HANDLE)
   {
      Print("สร้าง indicator handle ไม่สำเร็จ");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints((ulong)(InpSlippage * g_scale));
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   g_gvPrefix = "GEA_" + IntegerToString(InpMagic) + "_" + _Symbol + "_";
   ParseNews();
   RefreshBaskets();

   PrintFormat("GridEA v1.1 เริ่มทำงาน | %s Digits=%d | 1 จุด EA = %.2f USD ราคา (x%.0f points โบรก) | TP %d จุด = $%.2f | พบ BUY %d, SELL %d ไม้",
               _Symbol, _Digits, g_pt, g_scale, InpTPPoints, InpTPPoints * g_pt, g_buy.count, g_sell.count);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hEMA != INVALID_HANDLE) IndicatorRelease(hEMA);
   if(hRSI != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hATR != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hADX != INVALID_HANDLE) IndicatorRelease(hADX);
   Comment("");
}

void OnTick()
{
   datetime now = TimeCurrent();
   CheckNewDay(now);
   RefreshBaskets();

   // 1) ป้องกันพอร์ตก่อนทุกอย่าง
   if(CheckRiskStops(now))
   {
      RefreshBaskets();
      DrawPanel(now);
      return;
   }

   // 2) จัดการการปิดไม้
   ManageBasketTP(POSITION_TYPE_BUY,  g_buy);
   ManageBasketTP(POSITION_TYPE_SELL, g_sell);
   RefreshBaskets();
   CheckOldBasket(POSITION_TYPE_BUY,  g_buy,  now, g_oldAlertBuy);
   CheckOldBasket(POSITION_TYPE_SELL, g_sell, now, g_oldAlertSell);
   RefreshBaskets();

   // 3) เพิ่มไม้ grid และเปิด basket ใหม่
   if(GVGet("halted", 0) == 0)
   {
      TryGridAdd(POSITION_TYPE_BUY,  g_buy,  now);
      TryGridAdd(POSITION_TYPE_SELL, g_sell, now);
      TryFirstEntries(now);
   }

   DrawPanel(now);
}
//+------------------------------------------------------------------+
