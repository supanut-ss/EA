//+------------------------------------------------------------------+
//|                                                   XAUUSD_COUNTER_TREND.mq5 |
//|                                  Copyright 2026, Antigravity AI  |
//|                                             https://ats.info.com |
//+------------------------------------------------------------------+
#property copyright   "Copyright 2026, Antigravity AI"
#property link        "https://ats.info.com"
#property version     "2.22"
#property description "XAUUSD COUNTER TREND v2.22 - Counter-trend baseline with confirmed trend breakout"
#property strict

#include <Trade\Trade.mqh>

//--- Input Parameters
input group "== Webhook Connection Settings =="
input bool     InpEnableWebhookPolling = true;                 // เปิดใช้งานการดึงสัญญาณการเทรดผ่าน Webhook
input string   InpBackendURL           = "https://ea.thaipesleague.com"; // ลิงก์ API หลังบ้าน C# (EA Console dashboard - เดิมชี้ ats.thaipesleague.com)
input string   InpAuthToken            = "33be34ac24f13a1131f00b8451c9be4a1e3dbc1a5bfee721fd45f2f8142ede86"; // ต้องตรงกับ Ingest:ApiKey ของ backend (ส่งเป็น header X-Api-Key ด้วย ดู WebRequest calls ด้านล่าง)
// Real incident (2026-08-13 to 08-20): this, EA1's, and EA2's heartbeat/poll
// all defaulted to 10s - MT5 timers start counting from whenever each EA
// gets attached, so the three drifted into firing together often enough to
// burst past the backend host's (low, shared-host) max_user_connections,
// silently dropping requests with no retry. 37000 here is deliberately a
// different, mutually-prime-ish value from EA1's/EA2's 29s/31s so the three
// can't resynchronize - OnTimer() here only does the webhook poll + this
// EA's heartbeat snapshot, not the trading strategy itself, so a slower
// interval doesn't affect entries/exits (see OnTimer() below).
input int      InpPollInterval         = 37000;                 // รอบเวลาการดึงข้อมูลจากหลังบ้าน (มิลลิวินาที)
input int      InpSignalDedupDays      = 30;                    // เก็บผล signal ID เพื่อป้องกันเปิดซ้ำข้าม restart
input double   InpTesterServerUtcOffsetHours = 0.0;             // Strategy Tester server offset from UTC (for example 2 or 3)

// account_id ในฝั่ง backend (ดู Backend/EaConsole.Api/Controllers/
// SignalsController.cs) 2026-08-14: ย้ายจาก account_id=1
// (เดิมใช้ร่วมกับ EA1/EA2) ไปเป็นบัญชี Live จริงของตัวเอง (Exness-MT5Real8)
//
// 2026-08-28: เดิมเป็น #define hardcode ตรงกันทั้งสองฝั่ง แก้จากหน้าจอ MT5
// ไม่ได้เลย - พอเอา EA ไปแนบบัญชี demo มันจะเขียนทับ snapshot ของบัญชี Live
// และยัดเทรด demo เข้าไปในประวัติของ Live ด้วย ตอนนี้ EA ส่ง account_id ไป
// กับ payload แล้ว (backend fallback เป็น 2 ถ้า build เก่าไม่ได้ส่งมา) จึง
// ตั้งแยกพอร์ตได้จากหน้าจอ แบบเดียวกับ InpIngestAccountId ของ EA1/EA2
input int      InpBackendAccountId     = 2;                     // account_id ฝั่ง backend ของพอร์ตนี้ (ต้องมีแถวใน accounts table - ใช้ id คนละตัวเมื่อรันบัญชี demo)
// 1 แถวใน eas ผูกกับบัญชีเดียว (schema.sql: fk_eas_account) และ dashboard
// list EA ตาม account แล้วกรองเทรดด้วย ea_id ของบัญชีนั้น - ย้ายพอร์ตจึงต้อง
// เปลี่ยน ea_id ตามด้วย ไม่งั้นเทรดกับ log จะถูกกรองหายไปทั้งหมด
input int      InpBackendEaId          = 3;                     // ea_id ฝั่ง backend ของ EA ตัวนี้ (ต้องเป็นแถวที่ account_id ตรงกับ InpBackendAccountId)

input group "== Trade Settings =="
input int      InpSlippage             = 20;                    // ระยะ Slippage สูงสุดที่ยอมรับได้ (Points)
input int      InpMagic                = 88188;                 // หมายเลข Magic Number ของ EA สำหรับแยกแยะออเดอร์

input group "== Algorithm Settings (Pure Structure + Liquidity/CHoCH/BOS/FVG/OB) =="
input int      InpPivotLength          = 4;                     // จำนวนแท่งย้อนหลังสำหรับหาจุดกลับตัว Pivot
input double   InpSLBuffer             = 1.0;                   // ระยะเผื่อของ Stop Loss จากจุดต่ำสุด/สูงสุด (Points)
input int      InpMaxSLPips            = 12000;                 // ระยะ Stop Loss สูงสุดในโหมดคำนวณอัตโนมัติ (Points)
input double   InpPDThreshold          = 0.700;                 // ระดับราคาเป้าหมาย Premium/Discount (ปกติ 0.618)

enum ENUM_ENTRY_MODE {
   ENTRY_MODE_DISCOUNT_ONLY = 0, // Discount/Premium Only (Original 54% WR)
   ENTRY_MODE_ANY_FVG = 1,       // Any FVG/OB (High Frequency)
   ENTRY_MODE_STRICT_ICT = 2     // FVG/OB Inside Discount/Premium (Strict ICT)
};
input group "== Entry Logic =="
input ENUM_ENTRY_MODE InpEntryMode = ENTRY_MODE_DISCOUNT_ONLY;  // Counter-only baseline performed best in matched tests
input bool     InpRequireCHoCH          = false;                 // CHoCH-only filtering was not profitable in matched tests
input int      InpCHoCHMaxAgeBars      = 12;                    // Expire directional CHoCH after this many closed bars
input int      InpBOSConfirmBars        = 2;                     // Consecutive closed bars beyond the broken pivot
input int      InpBOSMaxPendingBars     = 4;                     // Expire an unconfirmed BOS candidate after this many bars
input int      InpFVGMaxAgeBars         = 48;                    // Maximum active age for an FVG zone
input int      InpOBMaxAgeBars          = 48;                    // Maximum active age for an order-block zone

input group "== Confirmed Trend Breakout Entry ==="
input bool     InpUseTrendBreakout             = false;          // OFF by default; matched A/B test favored the Counter-only baseline
input int      InpBreakoutConfirmBars          = 2;              // Consecutive closed bars beyond the confirmed pivot
input double   InpBreakoutMinBodyATR           = 0.50;           // First breakout candle body must be at least this ATR multiple
input double   InpBreakoutMaxExtensionATR      = 0.75;           // Skip if confirmation close is already too far from the pivot
input double   InpBreakoutMaxCloseWickRatio    = 0.25;           // Breakout candle must close near its directional edge
input bool     InpBreakoutRequireHTFAlignment  = true;           // Enabled H1/H4 trends must agree with the breakout
input bool     InpBreakoutAllowVolumeSpike     = true;           // Allow momentum volume; configured news windows still block entry

input group "== Scalping Risk =="
input bool     InpUseFixedSL           = true;                  // เปิดใช้งานการตั้งค่า Stop Loss แบบคงที่
input int      InpFixedSLPips          = 10000;                 // ระยะ Stop Loss แบบคงที่ (Points)

input group "== Daily Loss Guard =="
input bool     InpUseDailyLossGuard    = true;                  // Stop opening new trades after the daily loss limit
input int      InpMaxDailyLossCount    = 3;                     // Maximum losing positions per symbol and magic number
input string   InpDailyLossTimezone    = "Asia/Bangkok";        // Daily reset timezone: UTC, Asia/Bangkok, America/New_York

input group "== M5 Anti Fake-PA =="
input double   InpPABodyMin            = 0.20;                  // อัตราส่วนเนื้อเทียนขั้นต่ำสำหรับยืนยัน Price Action
input double   InpPAWickMax            = 0.65;                  // อัตราส่วนไส้เทียนสูงสุดสำหรับยืนยัน Price Action
input double   InpPACloseMin           = 0.60;                  // สัดส่วนตําแหน่งราคาปิดเทียนขั้นต่ำสำหรับคอนเฟิร์ม
input bool     InpPAEngulf             = true;                  // บังคับให้เกิดแท่งกลืนกิน (Engulfing Close)

input group "== Position Sizing (Fixed 0.05 lot per trade) =="
input double   InpFixedLot             = 0.05;                  // ปริมาณล็อตในการเปิดออเดอร์แต่ละครั้ง

input group "== Webhook Risk Limits =="
input double   InpWebhookMaxLot        = 0.05;                  // ล็อตสูงสุดที่ backend ขอได้ต่อคำสั่ง
input double   InpWebhookMaxRiskPct    = 1.0;                   // ความเสี่ยงสูงสุดต่อคำสั่งคิดจาก equity และ SL
input double   InpWebhookMaxSpreadPrice = 1.0;                  // spread สูงสุดในหน่วยราคาของ symbol
input int      InpWebhookMaxPositions  = 1;                     // จำนวน position สูงสุดต่อ symbol และ magic
input bool     InpWebhookRequireSL     = true;                  // ปฏิเสธ webhook ที่ไม่มี Stop Loss

input group "== Trend Filters =="
input bool     InpUseEMA               = true;                  // เปิดใช้งานตัวกรองเทรนด์ด้วยเส้น EMA 200 (M5)
input int      InpEMALength            = 200;                   // ความยาวเส้น EMA ไทม์เฟรมหลัก
input bool     InpUseH1Trend           = true;                  // เปิดใช้งานตัวกรองเทรนด์ของไทม์เฟรม H1 (EMA 21)
input int      InpH1EMALen             = 21;                    // ความยาวเส้น EMA ในไทม์เฟรม H1
input bool     InpUseH4Trend           = true;                  // เปิดใช้งานตัวกรองเทรนด์ของไทม์เฟรม H4 (EMA 21)
input int      InpH4EMALen             = 21;                    // ความยาวเส้น EMA ในไทม์เฟรม H4
input bool     InpFilterCounterTrend   = true;                  // Counter-only baseline: reject entries against H1/H4 trend

input group "== News & Volume Filters =="
input bool     InpUseNewsFilter        = true;                  // เปิดใช้งานตัวกรองงดเทรดในช่วงเวลาข่าว
input string   InpNewsSession          = "0300-0500:23456;1930-2030:6"; // ช่วงเวลาบล็อกเทรด คั่นด้วย ;
input string   InpNewsTimezone         = "Asia/Bangkok";        // เขตเวลาสำหรับกรองข่าว (เช่น Asia/Bangkok)
input bool     InpUseVolFilter         = true;                  // เปิดใช้งานตัวกรองปริมาณซื้อขายผิดปกติ (Volume Spike)
input double   InpVolSpikeMult         = 2.2;                   // ตัวคูณเกณฑ์ความสูงของ Volume Spike
input int      InpVolSmaLen            = 20;                    // ความยาว SMA สำหรับคำนวณปริมาณซื้อขายปกติ
input int      InpVolSpikeLookback     = 1;                     // ระยะเวลาที่จะทำการบล็อกออเดอร์หลังจากเกิดสไปค์ (แท่ง)

input group "== Sideway & Range Filters =="
input bool     InpUseADXFilter         = true;                  // เปิดใช้งานตัวกรองความแรงของเทรนด์ด้วย ADX
input int      InpADXLen               = 14;                    // ความยาวอินดิเคเตอร์ ADX
input double   InpADXMinThreshold      = 14.0;                  // ค่าความแรงเทรนด์ ADX ขั้นต่ำที่อนุญาตให้เทรด
input bool     InpUseChopFilter        = true;                  // เปิดใช้งานตัวกรองตลาดไซด์เวย์ด้วย Choppiness Index
input int      InpChopLen              = 14;                    // ความยาวอินดิเคเตอร์ Choppiness Index
input double   InpChopMaxThreshold     = 70.0;                  // ค่าสูงสุดของ CHOP ที่อนุญาต (หลีกเลี่ยงไซด์เวย์จัด)
input bool     InpUseATRFilter         = true;                  // เปิดใช้งานตัวกรองภาวะตลาดบีบตัวแรงด้วย ATR Ratio
input double   InpATRMinRatio          = 0.95;                  // อัตราส่วนความผันผวน ATR เทียบกับเส้นเฉลี่ย 50 วัน

input group "== Loss Cooldown Filter =="
input bool     InpUseLossCooldown      = true;                  // พักเปิดไม้ใหม่หลังปิดสถานะขาดทุน
input int      InpLossCooldownMins     = 75;                    // ระยะเวลาพักหลังไม้แพ้ (นาที)

input group "== Early Exit Management =="
input bool     InpUseEarlyExit         = true;                  // ปิดสถานะก่อนถึง Hard SL เมื่อโครงสร้างเสีย
input bool     InpExitOnOppositeCHoCH  = true;                  // ปิดเมื่อเกิด CHoCH ฝั่งตรงข้าม
input bool     InpExitOnStructureBreak = true;                  // ปิดเมื่อแท่งปิดทะลุ Pivot ฝั่งป้องกัน
input int      InpExitConfirmBars      = 2;                     // จำนวนแท่งปิดยืนยันสถานการณ์เสีย
input bool     InpExitOnHTFReversal    = false;                 // ปิดเมื่อ H1/H4 ที่เปิดใช้กลับทิศพร้อมกัน
input bool     InpUseTimeStop          = true;                  // ปิดไม้ไม่เดินและยังขาดทุนเมื่อถือเกินกำหนด
input int      InpTimeStopBars         = 20;                    // จำนวนแท่งสูงสุดก่อน Time Stop
input double   InpEarlyExitRiskR       = 0.65;                  // ขาดทุนถึงสัดส่วน R นี้ให้ข้ามเวลายืนยันเมื่อมีสัญญาณเสีย

input group "== Breakeven & Scaled Trailing Stop =="
input int      InpBEPips               = 5000;                  // ระยะกำไรที่เริ่มเปิดใช้งานล็อคทุน Breakeven (Points)
input int      InpBELowVolPips         = 5000;                  // ระยะกำไรที่ล็อคทุนเมื่อ Volume ต่ำ (Points)
input int      InpBECostBufferPoints   = 200;                   // Profit locked at BE to cover commission/fees (symbol points)
input bool     InpUseAdaptiveBE        = true;                  // เปิดใช้งาน Adaptive BE
input int      InpTrailLevel1Pips      = 15000;                 // ระยะกำไรที่เริ่มรัน Trailing Stop เลื่อนตามราคา (Points)
input int      InpTrailLevel1LockPips  = 7000;                  // ระยะล็อกกำไรขั้นต่ำของ Trailing Stop (Points)
input bool     InpUseSteppedTrail      = true;                  // ใช้ Trailing Stop แบบขยับตามระยะห่าง (true) หรือแบบตายตัว (false)
input int      InpTPPips               = 37500;                 // ระยะเป้าหมายในการปิดทำกำไรสูงสุด Take Profit (Points)

input group "== Force Close Settings =="
input bool     InpUseForceClose        = true;                  // เปิดใช้งานระบบปิดออเดอร์ทั้งหมดโดยบังคับตามเวลา
input string   InpForceCloseSession    = "0400-0405:23456";     // ช่วงเวลาที่จะปิดออเดอร์ทั้งหมดบังคับ
input string   InpForceCloseTimezone   = "Asia/Bangkok";        // เขตเวลาสำหรับปิดออเดอร์บังคับ (เช่น Asia/Bangkok)

//--- Global Variables
CTrade   trade;
string   backend_url = "";
string   auth_token  = "";

bool IsExternalIntegrationAllowed()
{
   return !MQLInfoInteger(MQL_TESTER)
          && !MQLInfoInteger(MQL_OPTIMIZATION);
}

// Validate both the local CTrade call and the trade-server return code.
// A true CTrade return value only confirms that the request structure passed
// local validation; it does not by itself prove that the server executed it.
bool IsTradeResultSuccessful(const bool request_ok,
                             const string operation,
                             const ulong ticket = 0,
                             const bool allow_no_changes = false)
{
   uint retcode = trade.ResultRetcode();
   bool retcode_ok = (retcode == TRADE_RETCODE_DONE
                      || retcode == TRADE_RETCODE_DONE_PARTIAL
                      || (allow_no_changes && retcode == TRADE_RETCODE_NO_CHANGES));

   if(request_ok && retcode_ok)
   {
      if(retcode == TRADE_RETCODE_DONE_PARTIAL)
         Print("ATS EA TRADE WARNING: ", operation,
               " completed partially ticket=", ticket,
               " order=", trade.ResultOrder(),
               " deal=", trade.ResultDeal(),
               " volume=", DoubleToString(trade.ResultVolume(), 2));
      return true;
   }

   Print("ATS EA TRADE ERROR: ", operation,
         " ticket=", ticket,
         " request_ok=", request_ok ? "true" : "false",
         " retcode=", retcode,
         " description=", trade.ResultRetcodeDescription(),
         " order=", trade.ResultOrder(),
         " deal=", trade.ResultDeal(),
         " price=", DoubleToString(trade.ResultPrice(), 8),
         " volume=", DoubleToString(trade.ResultVolume(), 2),
         " last_error=", GetLastError());
   return false;
}

string GetAnalyticsPrefix()
{
   return "ATS_AM_" + IntegerToString(InpMagic) + "_" + Symbol() + "_";
}

string GetAnalyticsKey(const string metric, const ulong ticket)
{
   return GetAnalyticsPrefix() + metric + "_" + IntegerToString(ticket);
}

enum ENUM_SIGNAL_CLAIM_RESULT
{
   SIGNAL_CLAIM_ACQUIRED = 0,
   SIGNAL_CLAIM_IN_FLIGHT = 1,
   SIGNAL_CLAIM_COMPLETED_OPEN = 2,
   SIGNAL_CLAIM_COMPLETED_FAILED = 3
};

string GetSignalClaimPrefix()
{
   return "ATS_SIG_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))
          + "_" + IntegerToString(InpMagic) + "_";
}

string GetSignalClaimBase(const string signal_id)
{
   uint hash1 = 2166136261;
   uint hash2 = 5381;
   for(int i = 0; i < StringLen(signal_id); i++)
   {
      uint character = (uint)StringGetCharacter(signal_id, i);
      hash1 = (hash1 ^ character) * 16777619;
      hash2 = ((hash2 << 5) + hash2) ^ character;
   }
   return GetSignalClaimPrefix() + IntegerToString((long)hash1)
          + "_" + IntegerToString((long)hash2);
}

ENUM_SIGNAL_CLAIM_RESULT TryClaimSignal(const string signal_id,
                                        ulong &existing_ticket,
                                        double &existing_price)
{
   existing_ticket = 0;
   existing_price = 0.0;
   string base = GetSignalClaimBase(signal_id);
   string state_key = base + "_STATE";
   string outcome_key = base + "_OUTCOME";

   if(!GlobalVariableCheck(state_key))
      GlobalVariableSet(state_key, 0.0);

   datetime claimed_at = TimeCurrent();
   if(claimed_at <= 0) claimed_at = 1;
   if(GlobalVariableSetOnCondition(state_key, (double)claimed_at, 0.0))
   {
      Print("ATS EA: Claimed webhook signal id=", signal_id);
      return SIGNAL_CLAIM_ACQUIRED;
   }

   double state = GlobalVariableGet(state_key);
   if(state < 0.0)
   {
      uint ticket_high = GlobalVariableCheck(base + "_TICKET_HI")
                         ? (uint)GlobalVariableGet(base + "_TICKET_HI") : 0;
      uint ticket_low = GlobalVariableCheck(base + "_TICKET_LO")
                        ? (uint)GlobalVariableGet(base + "_TICKET_LO") : 0;
      existing_ticket = ((ulong)ticket_high << 32) | (ulong)ticket_low;
      if(GlobalVariableCheck(base + "_PRICE"))
         existing_price = GlobalVariableGet(base + "_PRICE");
      double outcome = GlobalVariableCheck(outcome_key) ? GlobalVariableGet(outcome_key) : -1.0;
      return outcome > 0.0 ? SIGNAL_CLAIM_COMPLETED_OPEN : SIGNAL_CLAIM_COMPLETED_FAILED;
   }

   Print("ATS EA: Duplicate webhook signal is already in flight id=", signal_id);
   return SIGNAL_CLAIM_IN_FLIGHT;
}

void CompleteSignalClaim(const string signal_id,
                         const bool opened,
                         const ulong ticket,
                         const double entry_price)
{
   string base = GetSignalClaimBase(signal_id);
   // Persist result fields before marking the claim completed. A crash between
   // these writes remains fail-closed as IN_FLIGHT and cannot open a duplicate.
   GlobalVariableSet(base + "_TICKET_HI", (double)(uint)(ticket >> 32));
   GlobalVariableSet(base + "_TICKET_LO", (double)(uint)ticket);
   GlobalVariableSet(base + "_PRICE", entry_price);
   GlobalVariableSet(base + "_OUTCOME", opened ? 1.0 : -1.0);
   datetime completed_at = TimeCurrent();
   if(completed_at <= 0) completed_at = 1;
   GlobalVariableSet(base + "_STATE", -(double)completed_at);
   GlobalVariablesFlush();
}

void CleanupExpiredSignalClaims()
{
   datetime now = TimeCurrent();
   if(now <= 0) return;
   int retention_seconds = InpSignalDedupDays * 86400;
   string prefix = GetSignalClaimPrefix();

   for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
   {
      string name = GlobalVariableName(i);
      if(StringFind(name, prefix) != 0) continue;
      int state_suffix = StringFind(name, "_STATE");
      if(state_suffix != StringLen(name) - 6) continue;

      double state = GlobalVariableGet(name);
      datetime state_time = (datetime)MathAbs(state);
      if(state_time > 0 && now - state_time <= retention_seconds) continue;

      string base = StringSubstr(name, 0, StringLen(name) - 6);
      GlobalVariableDel(base + "_TICKET_HI");
      GlobalVariableDel(base + "_TICKET_LO");
      GlobalVariableDel(base + "_PRICE");
      GlobalVariableDel(base + "_OUTCOME");
      GlobalVariableDel(name);
   }
}

double NormalizePriceToTick(const string symbol, const double price, const bool round_up)
{
   if(price <= 0.0)
      return 0.0;

   double tick_size = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_size <= 0.0)
      tick_size = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(tick_size <= 0.0)
      return 0.0;

   double tick_count = price / tick_size;
   double normalized = (round_up ? MathCeil(tick_count - 1e-9)
                                 : MathFloor(tick_count + 1e-9)) * tick_size;
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   return NormalizeDouble(normalized, digits);
}

bool PrepareMarketStops(const string symbol,
                        const bool is_buy,
                        const MqlTick &tick,
                        double &sl,
                        double &tp)
{
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double tick_size = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(point <= 0.0 || tick_size <= 0.0)
   {
      Print("ATS EA TRADE ERROR: Invalid point/tick size for ", symbol);
      return false;
   }

   if(sl > 0.0) sl = NormalizePriceToTick(symbol, sl, !is_buy);
   if(tp > 0.0) tp = NormalizePriceToTick(symbol, tp, is_buy);

   long stops_level = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minimum_distance = (double)stops_level * point;
   double reference_price = is_buy ? tick.bid : tick.ask;
   bool invalid_sl = is_buy
                     ? (sl > 0.0 && sl >= reference_price - minimum_distance)
                     : (sl > 0.0 && sl <= reference_price + minimum_distance);
   bool invalid_tp = is_buy
                     ? (tp > 0.0 && tp <= reference_price + minimum_distance)
                     : (tp > 0.0 && tp >= reference_price - minimum_distance);

   if(invalid_sl || invalid_tp)
   {
      Print("ATS EA TRADE ERROR: Invalid market stops symbol=", symbol,
            " side=", is_buy ? "BUY" : "SELL",
            " reference=", DoubleToString(reference_price, 8),
            " sl=", DoubleToString(sl, 8),
            " tp=", DoubleToString(tp, 8),
            " minimum_distance=", DoubleToString(minimum_distance, 8));
      return false;
   }
   return true;
}

bool PrepareModifiedStop(const string symbol,
                         const long position_type,
                         const double current_price,
                         double &sl)
{
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double tick_size = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(point <= 0.0 || tick_size <= 0.0 || sl <= 0.0)
      return false;

   bool is_buy = position_type == POSITION_TYPE_BUY;
   sl = NormalizePriceToTick(symbol, sl, !is_buy);

   long stops_level = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freeze_level = SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minimum_distance = (double)MathMax(stops_level, freeze_level) * point;
   bool invalid_sl = is_buy ? (sl >= current_price - minimum_distance)
                            : (sl <= current_price + minimum_distance);
   if(invalid_sl)
   {
      Print("ATS EA TRADE ERROR: Invalid modified SL symbol=", symbol,
            " side=", is_buy ? "BUY" : "SELL",
            " current=", DoubleToString(current_price, 8),
            " sl=", DoubleToString(sl, 8),
            " minimum_distance=", DoubleToString(minimum_distance, 8));
      return false;
   }
   return true;
}

int GetManagedPositionCountForSymbol(const string symbol)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == symbol
         && PositionGetInteger(POSITION_MAGIC) == InpMagic)
         count++;
   }
   return count;
}

bool PrepareWebhookVolume(const string symbol,
                          const bool is_buy,
                          const MqlTick &tick,
                          const double sl,
                          const double requested_volume,
                          double &normalized_volume)
{
   normalized_volume = 0.0;
   if(requested_volume <= 0.0)
   {
      Print("ATS EA TRADE ERROR: Webhook volume must be positive symbol=", symbol);
      return false;
   }

   double spread = tick.ask - tick.bid;
   if(spread < 0.0 || spread > InpWebhookMaxSpreadPrice)
   {
      Print("ATS EA TRADE ERROR: Webhook blocked by spread symbol=", symbol,
            " spread=", DoubleToString(spread, 8),
            " maximum=", DoubleToString(InpWebhookMaxSpreadPrice, 8));
      return false;
   }

   int position_count = GetManagedPositionCountForSymbol(symbol);
   if(position_count >= InpWebhookMaxPositions)
   {
      Print("ATS EA TRADE ERROR: Webhook position limit reached symbol=", symbol,
            " count=", position_count, " maximum=", InpWebhookMaxPositions);
      return false;
   }

   double volume_min = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double volume_max = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double volume_step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(volume_min <= 0.0 || volume_max < volume_min || volume_step <= 0.0)
   {
      Print("ATS EA TRADE ERROR: Invalid broker volume specification symbol=", symbol);
      return false;
   }

   double maximum_volume = MathMin(volume_max, InpWebhookMaxLot);
   if(InpWebhookRequireSL && sl <= 0.0)
   {
      Print("ATS EA TRADE ERROR: Webhook Stop Loss is required symbol=", symbol);
      return false;
   }

   if(sl > 0.0)
   {
      ENUM_ORDER_TYPE order_type = is_buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double entry_price = is_buy ? tick.ask : tick.bid;
      double projected_one_lot = 0.0;
      ResetLastError();
      if(!OrderCalcProfit(order_type, symbol, 1.0, entry_price, sl, projected_one_lot)
         || projected_one_lot >= 0.0)
      {
         Print("ATS EA TRADE ERROR: Cannot calculate webhook SL risk symbol=", symbol,
               " error=", GetLastError());
         return false;
      }

      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double risk_budget = equity * InpWebhookMaxRiskPct / 100.0;
      double risk_limited_volume = risk_budget / MathAbs(projected_one_lot);
      maximum_volume = MathMin(maximum_volume, risk_limited_volume);
   }

   if(maximum_volume < volume_min
      || requested_volume > maximum_volume + 1e-9)
   {
      Print("ATS EA TRADE ERROR: Webhook volume exceeds risk/broker cap symbol=", symbol,
            " requested=", DoubleToString(requested_volume, 8),
            " maximum=", DoubleToString(maximum_volume, 8));
      return false;
   }

   normalized_volume = MathFloor((requested_volume + 1e-12) / volume_step) * volume_step;
   normalized_volume = NormalizeDouble(normalized_volume, 8);
   if(normalized_volume < volume_min || normalized_volume > maximum_volume + 1e-9)
   {
      Print("ATS EA TRADE ERROR: Webhook normalized volume is invalid symbol=", symbol,
            " normalized=", DoubleToString(normalized_volume, 8));
      return false;
   }

   ENUM_ORDER_TYPE margin_order_type = is_buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double margin = 0.0;
   double entry_price = is_buy ? tick.ask : tick.bid;
   ResetLastError();
   if(!OrderCalcMargin(margin_order_type, symbol, normalized_volume, entry_price, margin))
   {
      Print("ATS EA TRADE ERROR: Cannot calculate webhook margin symbol=", symbol,
            " error=", GetLastError());
      return false;
   }
   double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(margin <= 0.0 || margin > free_margin)
   {
      Print("ATS EA TRADE ERROR: Insufficient free margin for webhook symbol=", symbol,
            " required=", DoubleToString(margin, 2),
            " available=", DoubleToString(free_margin, 2));
      return false;
   }
   return true;
}

//--- Indicator Handles
int adx_handle = INVALID_HANDLE;
int atr_handle = INVALID_HANDLE;
int ema_handle = INVALID_HANDLE;

//--- Algorithm State
double last_ph = 0.0, last_pl = 0.0;
double prev_ph = 0.0, prev_pl = 0.0;
int    trend   = 0,   prev_trend = 0;
double swing_high = 0.0, swing_low = 0.0;
bool   touched_discount = false, touched_premium = false;
bool   choch_bull = false, choch_bear = false;
int    choch_bull_age = -1, choch_bear_age = -1;
int    early_exit_buy_bad_bars = 0, early_exit_sell_bad_bars = 0;
int    pending_bos_direction = 0, pending_bos_confirmations = 0, pending_bos_age = 0;
double pending_bos_level = 0.0;

//--- FVG / OB zones
double fvg_bull_low = 0.0, fvg_bull_high = 0.0;
double fvg_bear_low = 0.0, fvg_bear_high = 0.0;
double ob_bull_low  = 0.0, ob_bull_high  = 0.0;
double ob_bear_low  = 0.0, ob_bear_high  = 0.0;
int fvg_bull_age = -1, fvg_bear_age = -1;
int ob_bull_age = -1, ob_bear_age = -1;

//--- Tracked positions
struct TrackedPosition { ulong ticket; ulong identifier; string symbol; string action; double volume; double open_price; double sl; double tp; string comment; string pending_close_reason; };
TrackedPosition tracked_positions[];
int tracked_count = 0;

//+------------------------------------------------------------------+
bool IsNewBar()
{
   static datetime last_time = 0;
   datetime ct[];
   if(CopyTime(Symbol(), Period(), 0, 1, ct) < 1) return false;
   if(ct[0] != last_time) { last_time = ct[0]; return true; }
   return false;
}

double GetPositionSize()
{
   double s = 0.0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(PositionGetSymbol(i) == Symbol() && PositionGetInteger(POSITION_MAGIC) == InpMagic)
      {
         double v = PositionGetDouble(POSITION_VOLUME);
         s += (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? v : -v;
      }
   return s;
}

int GetPositionCount()
{
   int c = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(PositionGetSymbol(i) == Symbol() && PositionGetInteger(POSITION_MAGIC) == InpMagic) c++;
   return c;
}

bool ResolveManagedPositionIdentity(const string symbol,
                                    const long position_type,
                                    const ulong opening_order,
                                    ulong &position_identifier)
{
   ulong position_ticket = 0;
   position_identifier = 0;
   long newest_time_msc = -1;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      string selected_symbol = PositionGetSymbol(i);
      if(selected_symbol != symbol || PositionGetInteger(POSITION_MAGIC) != InpMagic
         || PositionGetInteger(POSITION_TYPE) != position_type)
         continue;

      ulong candidate_ticket = (ulong)PositionGetInteger(POSITION_TICKET);
      ulong candidate_identifier = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      if(opening_order > 0 && candidate_identifier == opening_order)
      {
         position_ticket = candidate_ticket;
         position_identifier = candidate_identifier;
         return true;
      }

      long candidate_time_msc = PositionGetInteger(POSITION_TIME_MSC);
      if(candidate_time_msc >= newest_time_msc)
      {
         newest_time_msc = candidate_time_msc;
         position_ticket = candidate_ticket;
         position_identifier = candidate_identifier;
      }
   }
   return position_ticket > 0 && position_identifier > 0;
}

// Detect each managed direction independently. Net volume cannot be used for
// this purpose on hedging accounts because equal BUY and SELL volume is zero.
void GetManagedPositionSides(bool &has_buy, bool &has_sell)
{
   has_buy = false;
   has_sell = false;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      string position_symbol = PositionGetSymbol(i);
      if(position_symbol != Symbol()
         || PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      long position_type = PositionGetInteger(POSITION_TYPE);
      if(position_type == POSITION_TYPE_BUY)
         has_buy = true;
      else if(position_type == POSITION_TYPE_SELL)
         has_sell = true;

      if(has_buy && has_sell)
         return;
   }
}

void ForceCloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != Symbol()) continue;
      
      Print("ATS EA: Force Closing position #", ticket, " due to Force Close Time.");
      SetPendingCloseReason(ticket, "Force Close (Session End)");
      ResetLastError();
      bool close_request_ok = trade.PositionClose(ticket);
      if(IsTradeResultSuccessful(close_request_ok, "Force close", ticket))
      {
         Print("ATS EA: Position #", ticket, " closed successfully.");
      }
      else
      {
         Print("ATS EA ERROR: Failed to force close position #", ticket);
      }
   }
}

void AddTrackedPosition(ulong t, ulong identifier, string sym, string act, double vol, double op, double sl, double tp, string comment="")
{
   ArrayResize(tracked_positions, tracked_count+1);
   tracked_positions[tracked_count].ticket = t;
   tracked_positions[tracked_count].identifier = identifier;
   tracked_positions[tracked_count].symbol = sym;
   tracked_positions[tracked_count].action = act;
   tracked_positions[tracked_count].volume = vol;
   tracked_positions[tracked_count].open_price = op;
   tracked_positions[tracked_count].sl = sl;
   tracked_positions[tracked_count].tp = tp;
   tracked_positions[tracked_count].comment = comment;
   tracked_positions[tracked_count].pending_close_reason = "";
   tracked_count++;
}

void RemoveTrackedPosition(int idx)
{
   if(idx < 0 || idx >= tracked_count) return;
   for(int i = idx; i < tracked_count-1; i++) tracked_positions[i] = tracked_positions[i+1];
   tracked_count--;
   ArrayResize(tracked_positions, tracked_count);
}

// Called right before an EA-initiated trade.PositionClose() so the
// close-detection loop in SyncPositionsWithBackend can report WHY it
// closed - MT5's own DEAL_REASON only ever says "EXPERT" for these
// (i.e. "some EA closed it"), it can't know the EA's actual motive.
void SetPendingCloseReason(ulong ticket, string reason)
{
   for(int i = 0; i < tracked_count; i++)
   {
      if(tracked_positions[i].ticket == ticket)
      {
         tracked_positions[i].pending_close_reason = reason;
         return;
      }
   }
}

bool GetClosedPositionResult(const ulong position_identifier,
                             double &exit_price,
                             double &net_profit,
                             ENUM_DEAL_REASON &exit_deal_reason)
{
   exit_price = 0.0;
   net_profit = 0.0;
   exit_deal_reason = DEAL_REASON_CLIENT; // harmless default, only read when has_exit is true
   if(position_identifier == 0 || !HistorySelectByPosition(position_identifier))
      return false;

   bool has_exit = false;
   long latest_exit_time_msc = -1;
   int deal_count = HistoryDealsTotal();
   for(int i = 0; i < deal_count; i++)
   {
      ulong deal_ticket = HistoryDealGetTicket(i);
      if(deal_ticket == 0) continue;

      // Account for costs charged on both the opening and closing deals.
      net_profit += HistoryDealGetDouble(deal_ticket, DEAL_PROFIT)
                    + HistoryDealGetDouble(deal_ticket, DEAL_SWAP)
                    + HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION)
                    + HistoryDealGetDouble(deal_ticket, DEAL_FEE);

      long entry_type = HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
      if(entry_type == DEAL_ENTRY_OUT || entry_type == DEAL_ENTRY_INOUT || entry_type == DEAL_ENTRY_OUT_BY)
      {
         has_exit = true;
         long exit_time_msc = HistoryDealGetInteger(deal_ticket, DEAL_TIME_MSC);
         if(exit_time_msc >= latest_exit_time_msc)
         {
            latest_exit_time_msc = exit_time_msc;
            exit_price = HistoryDealGetDouble(deal_ticket, DEAL_PRICE);
            exit_deal_reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(deal_ticket, DEAL_REASON);
         }
      }
   }
   return has_exit;
}

void SendLocalTradeToBackend(string id, string action, string symbol, double volume,
                             double entry_price, double sl, double tp, string status,
                             ulong ticket, double exit_price, double profit,
                             double mfe = 0.0, double mae = 0.0, double adx = 0.0,
                             double chop = 0.0, double atr_ratio = 0.0, bool is_low_vol = false,
                             string entry_condition = "", string close_reason = "")
{
   if(!IsExternalIntegrationAllowed()) return;
   string url  = backend_url + "/api/signals/local";
   string hdr  = "Content-Type: application/json\r\nX-Api-Key: " + auth_token + "\r\n";
   string pay  = StringFormat("{\"token\":\"%s\",\"account_id\":%d,\"ea_id\":%d,\"id\":\"%s\",\"action\":\"%s\",\"symbol\":\"%s\","
                              "\"volume\":%s,\"entry_price\":%s,\"sl\":%s,\"tp\":%s,"
                              "\"status\":\"%s\",\"ticket\":\"%s\",\"exit_price\":%s,\"profit\":%s,"
                              "\"mfe\":%s,\"mae\":%s,\"adx\":%s,\"chop\":%s,\"atr_ratio\":%s,\"is_low_vol\":%s,"
                              "\"entry_condition\":\"%s\",\"close_reason\":\"%s\"}",
                              auth_token, InpBackendAccountId, InpBackendEaId, id, action, symbol,
                              DoubleToString(volume,2), DoubleToString(entry_price,2),
                              DoubleToString(sl,2), DoubleToString(tp,2),
                              status, IntegerToString(ticket),
                              DoubleToString(exit_price,2), DoubleToString(profit,2),
                              DoubleToString(mfe,5), DoubleToString(mae,5), DoubleToString(adx,2),
                              DoubleToString(chop,2), DoubleToString(atr_ratio,3), is_low_vol ? "true" : "false",
                              entry_condition, AtsJsonEscape(close_reason));
   char pd[], rd[]; string rh;
   StringToCharArray(pay, pd, 0, StringLen(pay), CP_UTF8);
   ResetLastError();
   int h = WebRequest("POST", url, hdr, 3000, pd, rd, rh);
   if(h != 200) Print("ATS EA ERROR: Local sync HTTP=", h, " err=", GetLastError());
}

//+------------------------------------------------------------------+
// Reports structure events (Pivot High/Low, CHoCH, ...) to the generic
// /api/ingest/log endpoint so they show up on the dashboard's Activity
// Log card, the same way EA1/EA2's IngestLog() does - EA3 doesn't share
// EaIngestClient.mqh (its whole protocol is separate/pre-existing), so
// this posts the equivalent payload shape directly. These events were
// already being Print()'d locally (see ExecuteStrategyLogic) with no
// backend visibility at all before this.
//+------------------------------------------------------------------+
string AtsJsonEscape(string s)
{
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   return s;
}

void SendActivityLog(string level, string message)
{
   if(!IsExternalIntegrationAllowed()) return;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string eventTime = StringFormat("%04d-%02d-%02dT%02d:%02d:%02d", dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec);

   string url = backend_url + "/api/ingest/log";
   string hdr = "Content-Type: application/json\r\nX-Api-Key: " + auth_token + "\r\n";
   string pay = StringFormat("{\"accountId\":%d,\"eaId\":%d,\"level\":\"%s\",\"message\":\"%s\",\"eventTimeBroker\":\"%s\"}",
                              InpBackendAccountId, InpBackendEaId, level, AtsJsonEscape(message), eventTime);
   char pd[], rd[]; string rh;
   StringToCharArray(pay, pd, 0, StringLen(pay), CP_UTF8);
   ResetLastError();
   int h = WebRequest("POST", url, hdr, 3000, pd, rd, rh);
   if(h != 200 && h != 202) Print("ATS EA ERROR: Activity log HTTP=", h, " err=", GetLastError());
}

void SyncPositionsWithBackend()
{
   if(!IsExternalIntegrationAllowed()) return;
   int cur = PositionsTotal();
   ulong cts[]; ArrayResize(cts, cur);
   ulong current_identifiers[]; ArrayResize(current_identifiers, cur);
   for(int i = 0; i < cur; i++)
   {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      cts[i] = tk;
      current_identifiers[i] = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != Symbol()) continue;
      bool found = false;
      for(int j = 0; j < tracked_count; j++)
      {
         bool same_position = current_identifiers[i] > 0
                              ? tracked_positions[j].identifier == current_identifiers[i]
                              : tracked_positions[j].ticket == tk;
         if(same_position)
         {
            tracked_positions[j].ticket = tk;
            found = true;
            break;
         }
      }
      if(!found)
      {
         string sym = PositionGetString(POSITION_SYMBOL);
         string act = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "BUY" : "SELL";
         double vol = PositionGetDouble(POSITION_VOLUME);
         double op  = PositionGetDouble(POSITION_PRICE_OPEN);
         double sl  = PositionGetDouble(POSITION_SL);
         double tp  = PositionGetDouble(POSITION_TP);
         ulong identifier = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
         string comment = PositionGetString(POSITION_COMMENT);
         AddTrackedPosition(tk, identifier, sym, act, vol, op, sl, tp, comment);
         SendLocalTradeToBackend(IntegerToString(tk), act, sym, vol, op, sl, tp, "OPEN", tk, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, false, comment);
      }
   }
   for(int j = tracked_count-1; j >= 0; j--)
   {
      ulong tk = tracked_positions[j].ticket;
      bool found = false;
      for(int i = 0; i < cur; i++)
      {
         bool same_position = tracked_positions[j].identifier > 0
                              ? current_identifiers[i] == tracked_positions[j].identifier
                              : cts[i] == tk;
         if(same_position) { found = true; break; }
      }
      if(!found)
      {
         double ep = 0.0, pf = 0.0;
         ENUM_DEAL_REASON deal_reason = DEAL_REASON_CLIENT;
         ulong identifier = tracked_positions[j].identifier;
         bool exit_history_found = GetClosedPositionResult(identifier, ep, pf, deal_reason);
         if(!exit_history_found)
         {
            // The terminal history can lag the position list briefly. Retain
            // tracking state and retry instead of publishing a false result.
            Print("ATS EA: Closed position history not ready; retry identifier=", identifier);
            continue;
         }
         string stat = (pf >= 0.0 ? "WIN" : "LOSS");
         string tk_str = IntegerToString(tk);

         // MT5's own DEAL_REASON is authoritative for TP/SL/Manual (the
         // broker/terminal decided those, not us) - only fall back to our
         // own tracked reason (Structure Break / CHoCH / Time Stop / Force
         // Close) when MT5 just says "an EA closed it", since that alone
         // doesn't say which of our own exit rules actually fired.
         string close_reason;
         if(deal_reason == DEAL_REASON_TP) close_reason = "TP";
         else if(deal_reason == DEAL_REASON_SL) close_reason = "SL";
         else if(deal_reason == DEAL_REASON_CLIENT || deal_reason == DEAL_REASON_MOBILE || deal_reason == DEAL_REASON_WEB) close_reason = "Manual";
         else if(tracked_positions[j].pending_close_reason != "") close_reason = tracked_positions[j].pending_close_reason;
         else close_reason = "EA Logic";
         double mfe = 0.0, mae = 0.0, adx = 0.0, chop = 0.0, atr_ratio = 0.0;
         bool low_vol = false;

         ulong analytics_identity = identifier > 0 ? identifier : tk;
         string max_price_key = GetAnalyticsKey("MAX_PRICE", analytics_identity);
         string min_price_key = GetAnalyticsKey("MIN_PRICE", analytics_identity);
         string adx_key = GetAnalyticsKey("ADX", analytics_identity);
         string chop_key = GetAnalyticsKey("CHOP", analytics_identity);
         string atr_key = GetAnalyticsKey("ATR", analytics_identity);
         string low_vol_key = GetAnalyticsKey("LOW_VOL", analytics_identity);
         double max_price = tracked_positions[j].open_price;
         double min_price = tracked_positions[j].open_price;
         if(GlobalVariableCheck(max_price_key)) max_price = GlobalVariableGet(max_price_key);
         if(GlobalVariableCheck(min_price_key)) min_price = GlobalVariableGet(min_price_key);
         if(ep > 0.0)
         {
            max_price = MathMax(max_price, ep);
            min_price = MathMin(min_price, ep);
         }
         if(tracked_positions[j].action == "BUY")
         {
            mfe = MathMax(0.0, max_price - tracked_positions[j].open_price);
            mae = MathMax(0.0, tracked_positions[j].open_price - min_price);
         }
         else
         {
            mfe = MathMax(0.0, tracked_positions[j].open_price - min_price);
            mae = MathMax(0.0, max_price - tracked_positions[j].open_price);
         }
         if(GlobalVariableCheck(adx_key)) adx = GlobalVariableGet(adx_key);
         if(GlobalVariableCheck(chop_key)) chop = GlobalVariableGet(chop_key);
         if(GlobalVariableCheck(atr_key)) atr_ratio = GlobalVariableGet(atr_key);
         if(GlobalVariableCheck(low_vol_key)) low_vol = true;

         SendLocalTradeToBackend(tk_str, tracked_positions[j].action,
                                 tracked_positions[j].symbol, tracked_positions[j].volume,
                                 tracked_positions[j].open_price, tracked_positions[j].sl,
                                 tracked_positions[j].tp, stat, tk, ep, pf,
                                 mfe, mae, adx, chop, atr_ratio, low_vol, tracked_positions[j].comment,
                                 close_reason);

         if(GlobalVariableCheck(max_price_key)) GlobalVariableDel(max_price_key);
         if(GlobalVariableCheck(min_price_key)) GlobalVariableDel(min_price_key);
         if(GlobalVariableCheck(adx_key)) GlobalVariableDel(adx_key);
         if(GlobalVariableCheck(chop_key)) GlobalVariableDel(chop_key);
         if(GlobalVariableCheck(atr_key)) GlobalVariableDel(atr_key);
         if(GlobalVariableCheck(low_vol_key)) GlobalVariableDel(low_vol_key);
         
         RemoveTrackedPosition(j);
      }
   }
}

void InitTrackedPositions()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != Symbol()) continue;
      AddTrackedPosition(tk, (ulong)PositionGetInteger(POSITION_IDENTIFIER),
         PositionGetString(POSITION_SYMBOL),
         (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)?"BUY":"SELL",
         PositionGetDouble(POSITION_VOLUME), PositionGetDouble(POSITION_PRICE_OPEN),
         PositionGetDouble(POSITION_SL), PositionGetDouble(POSITION_TP), PositionGetString(POSITION_COMMENT));
   }
   Print("ATS EA: Tracking ", tracked_count, " open positions.");
}

bool GetHTFTrend(ENUM_TIMEFRAMES tf, int ema_len, bool &bull, bool &bear)
{
   // Fail closed: an enabled HTF filter must not silently pass when its
   // indicator data is unavailable.
   bull = bear = false;
   int h = iMA(Symbol(), tf, ema_len, 0, MODE_EMA, PRICE_CLOSE);
   if(h == INVALID_HANDLE) return false;
   double eb[1], cb[1];
   if(CopyBuffer(h,0,1,1,eb)<1 || CopyClose(Symbol(),tf,1,1,cb)<1) { IndicatorRelease(h); return false; }
   bull = (cb[0] > eb[0]); bear = (cb[0] < eb[0]);
   IndicatorRelease(h);
   return true;
}

int GetNthSundayOfMonth(const int year, const int month, const int nth)
{
   MqlDateTime first_day;
   ZeroMemory(first_day);
   first_day.year = year;
   first_day.mon = month;
   first_day.day = 1;

   datetime first_time = StructToTime(first_day);
   MqlDateTime normalized_first_day;
   TimeToStruct(first_time, normalized_first_day);
   return 1 + ((7 - normalized_first_day.day_of_week) % 7) + 7 * (nth - 1);
}

int GetTimezoneOffsetSeconds(const string timezone, const datetime utc_time)
{
   if(timezone == "UTC")
      return 0;
   if(timezone == "Asia/Bangkok")
      return 7 * 3600;
   if(timezone == "America/New_York")
   {
      MqlDateTime utc_dt;
      TimeToStruct(utc_time, utc_dt);

      // US Eastern time: DST starts at 07:00 UTC on the second Sunday
      // in March and ends at 06:00 UTC on the first Sunday in November.
      MqlDateTime dst_start;
      ZeroMemory(dst_start);
      dst_start.year = utc_dt.year;
      dst_start.mon = 3;
      dst_start.day = GetNthSundayOfMonth(utc_dt.year, 3, 2);
      dst_start.hour = 7;

      MqlDateTime dst_end;
      ZeroMemory(dst_end);
      dst_end.year = utc_dt.year;
      dst_end.mon = 11;
      dst_end.day = GetNthSundayOfMonth(utc_dt.year, 11, 1);
      dst_end.hour = 6;

      datetime dst_start_utc = StructToTime(dst_start);
      datetime dst_end_utc = StructToTime(dst_end);
      return (utc_time >= dst_start_utc && utc_time < dst_end_utc) ? -4 * 3600 : -5 * 3600;
   }

   // Preserve the previous fallback for an unsupported timezone.
   return (int)(TimeCurrent() - TimeGMT());
}

//+------------------------------------------------------------------+
//| GetTimeInTimezone: Convert current UTC to selected timezone      |
//+------------------------------------------------------------------+
datetime GetTimeInTimezone(string timezone)
{
   datetime utc_time = TimeGMT();
   if(MQLInfoInteger(MQL_TESTER))
      utc_time = TimeCurrent() - (int)MathRound(InpTesterServerUtcOffsetHours * 3600.0);
   return utc_time + GetTimezoneOffsetSeconds(timezone, utc_time);
}

//+------------------------------------------------------------------+
//| Daily Loss Guard                                                  |
//+------------------------------------------------------------------+
struct DailyPositionResult
{
   ulong  position_id;
   double pnl;
   bool   has_exit;
};

datetime GetDailyStartTime(string timezone)
{
   datetime utc_now        = TimeGMT();
   if(MQLInfoInteger(MQL_TESTER))
      utc_now = TimeCurrent() - (int)MathRound(InpTesterServerUtcOffsetHours * 3600.0);
   datetime server_now     = TimeCurrent();
   int timezone_offset_now = GetTimezoneOffsetSeconds(timezone, utc_now);
   datetime local_now      = utc_now + timezone_offset_now;
   int trade_server_offset = (int)(server_now - utc_now);

   MqlDateTime local_dt;
   TimeToStruct(local_now, local_dt);
   local_dt.hour = 0;
   local_dt.min  = 0;
   local_dt.sec  = 0;

   // Re-evaluate the offset at local midnight. On DST transition days the
   // offset at midnight can differ from the current offset after 02:00.
   datetime local_midnight_wall = StructToTime(local_dt);
   datetime candidate_utc = local_midnight_wall - timezone_offset_now;
   int midnight_timezone_offset = GetTimezoneOffsetSeconds(timezone, candidate_utc);
   datetime midnight_utc = local_midnight_wall - midnight_timezone_offset;

   // HistorySelect expects trade-server time.
   return midnight_utc + trade_server_offset;
}

int GetTodayLossCount(string symbol)
{
   datetime day_start = GetDailyStartTime(InpDailyLossTimezone);
   datetime now        = TimeCurrent();
   if(day_start > now || !HistorySelect(day_start, now))
      return 0;

   DailyPositionResult results[];
   int result_count = 0;
   int deal_count = HistoryDealsTotal();

   for(int i = 0; i < deal_count; i++)
   {
      ulong deal_ticket = HistoryDealGetTicket(i);
      if(deal_ticket == 0) continue;
      if(HistoryDealGetInteger(deal_ticket, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetString(deal_ticket, DEAL_SYMBOL) != symbol) continue;

      ulong position_id = (ulong)HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID);
      if(position_id == 0) continue;

      int idx = -1;
      for(int j = 0; j < result_count; j++)
      {
         if(results[j].position_id == position_id) { idx = j; break; }
      }
      if(idx < 0)
      {
         idx = result_count++;
         ArrayResize(results, result_count);
         results[idx].position_id = position_id;
         results[idx].pnl         = 0.0;
         results[idx].has_exit    = false;
      }

      results[idx].pnl += HistoryDealGetDouble(deal_ticket, DEAL_PROFIT)
                         + HistoryDealGetDouble(deal_ticket, DEAL_SWAP)
                         + HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION)
                         + HistoryDealGetDouble(deal_ticket, DEAL_FEE);

      long entry_type = HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
      if(entry_type == DEAL_ENTRY_OUT || entry_type == DEAL_ENTRY_OUT_BY || entry_type == DEAL_ENTRY_INOUT)
         results[idx].has_exit = true;
   }

   int loss_count = 0;
   for(int i = 0; i < result_count; i++)
      if(results[i].has_exit && results[i].pnl < 0.0) loss_count++;

   return loss_count;
}

bool IsDailyLossBlocked(string symbol, int &loss_count)
{
   loss_count = 0;
   if(!InpUseDailyLossGuard) return false;

   loss_count = GetTodayLossCount(symbol);
   return (loss_count >= InpMaxDailyLossCount);
}

//+------------------------------------------------------------------+
//| IsInSessionString: Check if time falls inside Pine session string|
//+------------------------------------------------------------------+
bool IsInSessionString(datetime time_val, string session_str)
{
   if(session_str == "") return false;
   
   string session_blocks[];
   int num_blocks = StringSplit(session_str, ';', session_blocks);
   
   for(int b = 0; b < num_blocks; b++)
   {
       string block_str = session_blocks[b];
       StringTrimLeft(block_str);
       StringTrimRight(block_str);
       if(block_str == "") continue;
       
       string time_part = block_str;
       string days_part = "";
       int colon_idx = StringFind(block_str, ":");
       if(colon_idx != -1)
       {
          time_part = StringSubstr(block_str, 0, colon_idx);
          days_part = StringSubstr(block_str, colon_idx + 1);
       }
       
       MqlDateTime dt;
       TimeToStruct(time_val, dt);
       
       bool day_match = true;
       if(days_part != "")
       {
          int pine_day = (dt.day_of_week == 0) ? 1 : (dt.day_of_week + 1);
          string day_char = IntegerToString(pine_day);
          if(StringFind(days_part, day_char) == -1)
             day_match = false;
       }
       
       if(!day_match) continue; // Skip if this block's days don't match
       
       int current_time_mins = dt.hour * 60 + dt.min;
       string ranges[];
       int num_ranges = StringSplit(time_part, ',', ranges);
       if(num_ranges <= 0) continue;
       
       for(int i = 0; i < num_ranges; i++)
       {
          string range = ranges[i];
          StringTrimLeft(range);
          StringTrimRight(range);
          int dash_idx = StringFind(range, "-");
          if(dash_idx == -1) continue;
          
          string start_str = StringSubstr(range, 0, dash_idx);
          string end_str = StringSubstr(range, dash_idx + 1);
          
          int start_h = (int)StringToInteger(StringSubstr(start_str, 0, 2));
          int start_m = (int)StringToInteger(StringSubstr(start_str, 2, 2));
          int end_h = (int)StringToInteger(StringSubstr(end_str, 0, 2));
          int end_m = (int)StringToInteger(StringSubstr(end_str, 2, 2));
          
          int start_mins = start_h * 60 + start_m;
          int end_mins = end_h * 60 + end_m;
          
          if(start_mins <= end_mins)
          {
             if(current_time_mins >= start_mins && current_time_mins < end_mins)
                return true;
          }
          else
          {
             if(current_time_mins >= start_mins || current_time_mins < end_mins)
                return true;
          }
       }
   }
   return false;
}

//+------------------------------------------------------------------+
//| GetATRRatioValue: Calculate volatility ratio                     |
//+------------------------------------------------------------------+
bool GetATRRatioValue(double &ratio)
{
   ratio = 0.0;
   if(atr_handle == INVALID_HANDLE || BarsCalculated(atr_handle) < 50) return false;
   double atr_buf[];
   ArrayResize(atr_buf, 50);
   ArraySetAsSeries(atr_buf, true);
   if(CopyBuffer(atr_handle, 0, 1, 50, atr_buf) < 50) return false;
   
   double atr_14 = atr_buf[0];
   double sum = 0.0;
   for(int i=0; i<50; i++) sum += atr_buf[i];
   double atr_sma_50 = sum / 50.0;
   
   if(atr_sma_50 > 0)
   {
      ratio = atr_14 / atr_sma_50;
      return MathIsValidNumber(ratio) && ratio > 0.0;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Read the ATR value of a specific closed bar.                     |
//+------------------------------------------------------------------+
bool GetATRValueAtShift(const int shift, double &atr_value)
{
   atr_value = 0.0;
   if(shift < 1 || atr_handle == INVALID_HANDLE || BarsCalculated(atr_handle) <= shift)
      return false;

   double atr_buf[1];
   if(CopyBuffer(atr_handle, 0, shift, 1, atr_buf) != 1)
      return false;

   atr_value = atr_buf[0];
   return MathIsValidNumber(atr_value) && atr_value > 0.0;
}

//+------------------------------------------------------------------+
//| Confirm a fresh continuation breakout once per crossed pivot.    |
//| The oldest confirmation bar must cross the level; every newer    |
//| closed bar must remain beyond it. This prevents repeated entries. |
//+------------------------------------------------------------------+
bool IsConfirmedTrendBreakout(const int direction,
                              const double level,
                              double &closes[],
                              double &opens[],
                              double &highs[],
                              double &lows[],
                              double &extension_atr)
{
   extension_atr = 0.0;
   if(!InpUseTrendBreakout || (direction != 1 && direction != -1) || level <= 0.0)
      return false;

   int first_break_shift = InpBreakoutConfirmBars;
   if(ArraySize(closes) <= first_break_shift + 1
      || ArraySize(opens) <= first_break_shift
      || ArraySize(highs) <= first_break_shift
      || ArraySize(lows) <= first_break_shift)
      return false;

   // Require a fresh cross, followed by consecutive closes that hold beyond
   // the same confirmed pivot. Equality does not count as a breakout.
   if(direction > 0)
   {
      if(closes[first_break_shift + 1] > level)
         return false;
      for(int i = first_break_shift; i >= 1; i--)
         if(closes[i] <= level) return false;
   }
   else
   {
      if(closes[first_break_shift + 1] < level)
         return false;
      for(int i = first_break_shift; i >= 1; i--)
         if(closes[i] >= level) return false;
   }

   double atr_value = 0.0;
   if(!GetATRValueAtShift(first_break_shift, atr_value))
      return false;

   double candle_range = highs[first_break_shift] - lows[first_break_shift];
   if(candle_range <= 0.0)
      return false;

   double directional_body = direction > 0
                             ? closes[first_break_shift] - opens[first_break_shift]
                             : opens[first_break_shift] - closes[first_break_shift];
   if(directional_body <= 0.0 || directional_body / atr_value < InpBreakoutMinBodyATR)
      return false;

   double close_wick_ratio = direction > 0
                             ? (highs[first_break_shift] - closes[first_break_shift]) / candle_range
                             : (closes[first_break_shift] - lows[first_break_shift]) / candle_range;
   if(close_wick_ratio > InpBreakoutMaxCloseWickRatio)
      return false;

   extension_atr = direction > 0
                   ? (closes[1] - level) / atr_value
                   : (level - closes[1]) / atr_value;
   return extension_atr >= 0.0 && extension_atr <= InpBreakoutMaxExtensionATR;
}

//+------------------------------------------------------------------+
//| CalculateChoppiness: Calculate Choppiness Index (0-100)          |
//+------------------------------------------------------------------+
double CalculateChoppiness(int len)
{
   double hi_arr[], lo_arr[], cl_arr[];
   ArraySetAsSeries(hi_arr, true);
   ArraySetAsSeries(lo_arr, true);
   ArraySetAsSeries(cl_arr, true);
   
   if(CopyHigh(Symbol(), Period(), 1, len, hi_arr) < len ||
      CopyLow(Symbol(), Period(), 1, len, lo_arr) < len ||
      CopyClose(Symbol(), Period(), 1, len + 1, cl_arr) < len + 1)
      return 100.0;
      
   double atr_sum = 0.0;
   double hh = hi_arr[0];
   double ll = lo_arr[0];
   
   for(int i=0; i<len; i++)
   {
      double tr = hi_arr[i] - lo_arr[i];
      double diff1 = MathAbs(hi_arr[i] - cl_arr[i+1]);
      double diff2 = MathAbs(lo_arr[i] - cl_arr[i+1]);
      if(diff1 > tr) tr = diff1;
      if(diff2 > tr) tr = diff2;
      atr_sum += tr;
      
      if(hi_arr[i] > hh) hh = hi_arr[i];
      if(lo_arr[i] < ll) ll = lo_arr[i];
   }
   
   double range = hh - ll;
   if(range > 0)
   {
      double chop = 100.0 * MathLog10(atr_sum / range) / MathLog10(len);
      return chop;
   }
   return 100.0;
}

//+------------------------------------------------------------------+
//| GetADXValue: Retrieve ADX indicator value                        |
//+------------------------------------------------------------------+
double GetADXValue()
{
   if(!InpUseADXFilter) return 100.0;
   if(adx_handle == INVALID_HANDLE) return 0.0;
   double val[1];
   if(CopyBuffer(adx_handle, 0, 1, 1, val) < 1) return 0.0;
   return val[0];
}

//+------------------------------------------------------------------+
//| IsVolumeSpikeActive: Check if there was a volume spike recently  |
//+------------------------------------------------------------------+
bool IsVolumeSpikeActive(int sma_len, double multiplier, int lookback_bars)
{
   long vol_arr[];
   ArraySetAsSeries(vol_arr, true);
   // Load closed bars only. Each candidate is compared with an SMA made from
   // strictly older bars, so the spike cannot inflate its own baseline.
   int required = sma_len + lookback_bars;
   int copied = CopyTickVolume(Symbol(), Period(), 1, required, vol_arr);
   if(copied < required)
      return false;

   for(int i = 0; i < lookback_bars; i++)
   {
      double sum = 0;
      for(int j = 0; j < sma_len; j++)
      {
         sum += (double)vol_arr[i + j + 1];
      }
      double sma = sum / sma_len;
      if(sma > 0 && (double)vol_arr[i] > sma * multiplier)
      {
         Print("ATS EA: Volume spike detected on bar ", i, " Volume=", vol_arr[i], " SMA=", sma, " Multiplier=", multiplier);
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Return true while the most recent closed position is a loss and  |
//| its configured cooldown window has not expired.                  |
//+------------------------------------------------------------------+
bool IsLossCooldownActive(string symbol, int &remaining_minutes)
{
   remaining_minutes = 0;
   if(!InpUseLossCooldown)
      return false;

   datetime now = TimeCurrent();
   if(!HistorySelect(now - 7 * 86400, now))
      return false;

   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong deal_ticket = HistoryDealGetTicket(i);
      if(deal_ticket == 0)
         continue;

      long entry_type = HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
      if(entry_type != DEAL_ENTRY_OUT && entry_type != DEAL_ENTRY_INOUT && entry_type != DEAL_ENTRY_OUT_BY)
         continue;
      if(HistoryDealGetInteger(deal_ticket, DEAL_MAGIC) != InpMagic)
         continue;
      if(HistoryDealGetString(deal_ticket, DEAL_SYMBOL) != symbol)
         continue;

      double net_result = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT)
                          + HistoryDealGetDouble(deal_ticket, DEAL_SWAP)
                          + HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION);
      if(net_result >= 0.0)
         return false;

      datetime closed_at = (datetime)HistoryDealGetInteger(deal_ticket, DEAL_TIME);
      int remaining_seconds = InpLossCooldownMins * 60 - (int)(now - closed_at);
      if(remaining_seconds <= 0)
         return false;

      remaining_minutes = (remaining_seconds + 59) / 60;
      return true;
   }
   return false;
}

void ResetPendingBOS()
{
   pending_bos_direction = 0;
   pending_bos_confirmations = 0;
   pending_bos_age = 0;
   pending_bos_level = 0.0;
}

void SetBullishCHoCH()
{
   choch_bull = true;
   choch_bull_age = 0;
}

void SetBearishCHoCH()
{
   choch_bear = true;
   choch_bear_age = 0;
}

void ClearBullishCHoCH()
{
   choch_bull = false;
   choch_bull_age = -1;
}

void ClearBearishCHoCH()
{
   choch_bear = false;
   choch_bear_age = -1;
}

void AgeCHoCHState()
{
   if(choch_bull)
   {
      choch_bull_age++;
      if(choch_bull_age > InpCHoCHMaxAgeBars)
         ClearBullishCHoCH();
   }
   if(choch_bear)
   {
      choch_bear_age++;
      if(choch_bear_age > InpCHoCHMaxAgeBars)
         ClearBearishCHoCH();
   }
}

bool UpdateBOSTrend(const double closed_price, const bool log_event)
{
   if(pending_bos_direction != 0)
   {
      pending_bos_age++;
      bool still_beyond_level = pending_bos_direction > 0
                                ? closed_price > pending_bos_level
                                : closed_price < pending_bos_level;
      if(!still_beyond_level || pending_bos_age > InpBOSMaxPendingBars)
         ResetPendingBOS();
      else
      {
         pending_bos_confirmations++;
         if(pending_bos_confirmations >= InpBOSConfirmBars)
         {
            int confirmed_direction = pending_bos_direction;
            trend = confirmed_direction;
            if(trend > 0) ClearBearishCHoCH();
            else ClearBullishCHoCH();
            if(log_event)
               Print("ATS EA: BOS ", trend > 0 ? "Bullish" : "Bearish",
                     " confirmed bars=", pending_bos_confirmations,
                     " level=", pending_bos_level);
            ResetPendingBOS();
            return true;
         }
      }
   }

   if(pending_bos_direction == 0)
   {
      int candidate_direction = 0;
      double candidate_level = 0.0;
      if(trend <= 0 && last_ph > 0.0 && closed_price > last_ph)
      {
         candidate_direction = 1;
         candidate_level = last_ph;
      }
      else if(trend >= 0 && last_pl > 0.0 && closed_price < last_pl)
      {
         candidate_direction = -1;
         candidate_level = last_pl;
      }

      if(candidate_direction != 0)
      {
         pending_bos_direction = candidate_direction;
         pending_bos_level = candidate_level;
         pending_bos_confirmations = 1;
         pending_bos_age = 1;
         if(InpBOSConfirmBars <= 1)
         {
            trend = candidate_direction;
            if(trend > 0) ClearBearishCHoCH();
            else ClearBullishCHoCH();
            if(log_event)
               Print("ATS EA: BOS ", trend > 0 ? "Bullish" : "Bearish",
                     " confirmed level=", pending_bos_level);
            ResetPendingBOS();
            return true;
         }
         if(log_event)
            Print("ATS EA: BOS candidate direction=", candidate_direction,
                  " confirmation=1/", InpBOSConfirmBars,
                  " level=", candidate_level);
      }
   }
   return false;
}

void ClearAllZones()
{
   fvg_bull_low = fvg_bull_high = 0.0;
   fvg_bear_low = fvg_bear_high = 0.0;
   ob_bull_low = ob_bull_high = 0.0;
   ob_bear_low = ob_bear_high = 0.0;
   fvg_bull_age = fvg_bear_age = -1;
   ob_bull_age = ob_bear_age = -1;
}

void UpdateZoneLifecycle(const double closed_price, const bool trend_changed)
{
   if(trend_changed)
   {
      ClearAllZones();
      return;
   }

   if(fvg_bull_age >= 0 && (++fvg_bull_age > InpFVGMaxAgeBars || closed_price < fvg_bull_low))
      { fvg_bull_low = fvg_bull_high = 0.0; fvg_bull_age = -1; }
   if(fvg_bear_age >= 0 && (++fvg_bear_age > InpFVGMaxAgeBars || closed_price > fvg_bear_high))
      { fvg_bear_low = fvg_bear_high = 0.0; fvg_bear_age = -1; }
   if(ob_bull_age >= 0 && (++ob_bull_age > InpOBMaxAgeBars || closed_price < ob_bull_low))
      { ob_bull_low = ob_bull_high = 0.0; ob_bull_age = -1; }
   if(ob_bear_age >= 0 && (++ob_bear_age > InpOBMaxAgeBars || closed_price > ob_bear_high))
      { ob_bear_low = ob_bear_high = 0.0; ob_bear_age = -1; }
}

// Detect FVG for a specified closed-bar shift. The older impulse candle is
// two bars behind the evaluated candle.
void DetectFVGAtShift(double &highs[], double &lows[], const int current_shift)
{
   int older_shift = current_shift + 2;
   if(current_shift < 1 || older_shift >= ArraySize(highs) || older_shift >= ArraySize(lows)) return;
   if(highs[older_shift] < lows[current_shift])
      { fvg_bull_low = highs[older_shift]; fvg_bull_high = lows[current_shift]; fvg_bull_age = 0; }
   if(lows[older_shift] > highs[current_shift])
      { fvg_bear_low = highs[current_shift]; fvg_bear_high = lows[older_shift]; fvg_bear_age = 0; }
}

// Detect Order Block: last opposing candle before impulse move
void DetectOBAtShift(double &opens[], double &closes[], double &highs[], double &lows[], const int current_shift)
{
   int older_shift = current_shift + 2;
   if(current_shift < 1 || older_shift >= ArraySize(opens) || older_shift >= ArraySize(closes)
      || older_shift >= ArraySize(highs) || older_shift >= ArraySize(lows)) return;
   // Bullish OB: older bearish candle before a bullish close above its high.
   if(closes[older_shift]<opens[older_shift] && closes[current_shift]>opens[current_shift]
      && closes[current_shift]>highs[older_shift])
      { ob_bull_low=lows[older_shift]; ob_bull_high=highs[older_shift]; ob_bull_age=0; }
   // Bearish OB: older bullish candle before a bearish close below its low.
   if(closes[older_shift]>opens[older_shift] && closes[current_shift]<opens[current_shift]
      && closes[current_shift]<lows[older_shift])
      { ob_bear_low=lows[older_shift]; ob_bear_high=highs[older_shift]; ob_bear_age=0; }
}

void DetectFVG(double &highs[], double &lows[])
{
   DetectFVGAtShift(highs, lows, 1);
}

void DetectOB(double &opens[], double &closes[], double &highs[], double &lows[])
{
   DetectOBAtShift(opens, closes, highs, lows, 1);
}

void InitStateFromHistory()
{
   ResetPendingBOS();
   ClearAllZones();
   int hb = 500;
   double cl[], op[], hi[], lo[];
   ArraySetAsSeries(cl,true); ArraySetAsSeries(op,true);
   ArraySetAsSeries(hi,true); ArraySetAsSeries(lo,true);
   if(CopyClose(Symbol(),Period(),0,hb,cl)<hb || CopyOpen(Symbol(),Period(),0,hb,op)<hb ||
      CopyHigh(Symbol(),Period(),0,hb,hi)<hb  || CopyLow(Symbol(),Period(),0,hb,lo)<hb)
      { Print("ATS EA: History load error."); return; }
   int plt = 0;
   // Rebuild through bar 2 only. IsNewBar() intentionally processes bar 1 on
   // the first tick after initialization, so no closed bar is counted twice.
   for(int i = hb-2*InpPivotLength-1; i >= 2; i--)
   {
      AgeCHoCHState();
      int ti = i + InpPivotLength;
      bool iph = true, ipl = true;
      for(int j = 1; j <= 2*InpPivotLength+1; j++)
      {
         int ci = i+j-1; if(ci==ti) continue;
         if(hi[ci]>hi[ti]) iph=false;
         if(lo[ci]<lo[ti]) ipl=false;
      }
      if(iph) { prev_ph=last_ph; last_ph=hi[ti];
         if(trend==1&&prev_ph>0&&last_ph<prev_ph) SetBearishCHoCH(); }
      if(ipl) { prev_pl=last_pl; last_pl=lo[ti];
          if(trend==-1&&prev_pl>0&&last_pl>prev_pl) SetBullishCHoCH(); }
      double cv = cl[i];
      int trend_before_bos = trend;
      UpdateBOSTrend(cv, false);
      if(trend==1)  { swing_low=(!swing_low)?last_pl:swing_low; swing_high=MathMax(!swing_high?hi[i]:swing_high,hi[i]); }
      else if(trend==-1) { swing_high=(!swing_high)?last_ph:swing_high; swing_low=MathMin(!swing_low?lo[i]:swing_low,lo[i]); }
      if(trend!=plt)
      {
         if(trend==1)  { swing_low=last_pl; swing_high=hi[i]; ClearBearishCHoCH(); }
         if(trend==-1) { swing_high=last_ph; swing_low=lo[i]; ClearBullishCHoCH(); }
         plt=trend;
      }
      UpdateZoneLifecycle(cv, trend != trend_before_bos);
      DetectFVGAtShift(hi, lo, i);
      DetectOBAtShift(op, cl, hi, lo, i);
      double sr=swing_high-swing_low;
      double dl=swing_low+(sr*InpPDThreshold), pl2=swing_high-(sr*InpPDThreshold);
      if(trend==1&&lo[i]<=dl) touched_discount=true; if(trend!=1) touched_discount=false;
      if(trend==-1&&hi[i]>=pl2) touched_premium=true; if(trend!=-1) touched_premium=false;
   }
   Print("ATS EA: History init done. Trend=",trend," SH=",swing_high," SL=",swing_low,
         " CHoCH Bull=",choch_bull," Bear=",choch_bear);
}

//+------------------------------------------------------------------+
//| Confirmed soft exit. Hard SL remains active at the broker.       |
//+------------------------------------------------------------------+
bool ManageEarlyExit(double closed_price,
                     bool buy_bad_signal,
                     bool sell_bad_signal,
                     string buy_reason,
                     string sell_reason)
{
   bool has_buy = false;
   bool has_sell = false;
   GetManagedPositionSides(has_buy, has_sell);
   bool has_managed_positions = has_buy || has_sell;
   string risk_prefix = "ATS_ER_" + IntegerToString(InpMagic) + "_" + Symbol() + "_";
   if(!InpUseEarlyExit || !has_managed_positions)
   {
      early_exit_buy_bad_bars = 0;
      early_exit_sell_bad_bars = 0;
      if(!has_managed_positions)
      {
         for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
         {
            string variable_name = GlobalVariableName(i);
            if(StringFind(variable_name, risk_prefix) == 0)
               GlobalVariableDel(variable_name);
         }
      }
      return false;
   }

   // Maintain confirmation independently for both sides. This allows BUY and
   // SELL positions to coexist without one side suppressing the other.
   early_exit_buy_bad_bars = (has_buy && buy_bad_signal)
                             ? early_exit_buy_bad_bars + 1 : 0;
   early_exit_sell_bad_bars = (has_sell && sell_bad_signal)
                              ? early_exit_sell_bad_bars + 1 : 0;

   bool closed_any = false;
   int period_seconds = PeriodSeconds(Period());
   if(period_seconds <= 0) period_seconds = 300;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      string symbol = PositionGetSymbol(i);
      if(symbol != Symbol() || PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
      long position_type = PositionGetInteger(POSITION_TYPE);
      double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      double stop_price = PositionGetDouble(POSITION_SL);
      double position_profit = PositionGetDouble(POSITION_PROFIT);
      datetime opened_at = (datetime)PositionGetInteger(POSITION_TIME);

      string risk_key = risk_prefix + IntegerToString(ticket);
      double initial_risk = 0.0;
      if(GlobalVariableCheck(risk_key))
         initial_risk = GlobalVariableGet(risk_key);
      else
      {
         initial_risk = MathAbs(open_price - stop_price);
         if(initial_risk <= 0.0)
            initial_risk = (InpUseFixedSL ? InpFixedSLPips : InpMaxSLPips)
                           * SymbolInfoDouble(symbol, SYMBOL_POINT);
         GlobalVariableSet(risk_key, initial_risk);
      }

      bool is_buy = position_type == POSITION_TYPE_BUY;
      bool bad_signal = is_buy ? buy_bad_signal : sell_bad_signal;
      int confirmed_bars = is_buy ? early_exit_buy_bad_bars : early_exit_sell_bad_bars;
      double adverse_distance = is_buy ? open_price - closed_price : closed_price - open_price;
      double adverse_r = initial_risk > 0.0 ? MathMax(0.0, adverse_distance) / initial_risk : 0.0;
      int held_bars = (int)((TimeCurrent() - opened_at) / period_seconds);

      bool confirmed_exit = bad_signal && confirmed_bars >= InpExitConfirmBars;
      bool risk_emergency = bad_signal && adverse_r >= InpEarlyExitRiskR;
      bool time_exit = InpUseTimeStop && held_bars >= InpTimeStopBars && position_profit <= 0.0;
      if(!confirmed_exit && !risk_emergency && !time_exit)
         continue;

      string reason = time_exit ? "Time Stop" : (is_buy ? buy_reason : sell_reason);
      Print("ATS EA: EARLY EXIT #", ticket, " ", is_buy ? "BUY" : "SELL",
            " reason=", reason, " confirm=", confirmed_bars,
            " adverseR=", DoubleToString(adverse_r, 2), " heldBars=", held_bars);
      SetPendingCloseReason(ticket, reason);

      ResetLastError();
      bool close_request_ok = trade.PositionClose(ticket);
      if(IsTradeResultSuccessful(close_request_ok, "Early exit", ticket))
      {
         GlobalVariableDel(risk_key);
         closed_any = true;
      }
      else
         Print("ATS EA: Early exit failed #", ticket);
   }

   if(closed_any)
   {
      // Keep confirmation state for any side whose close request failed, so it
      // can retry on the next closed bar instead of losing its confirmation.
      GetManagedPositionSides(has_buy, has_sell);
      if(!has_buy) early_exit_buy_bad_bars = 0;
      if(!has_sell) early_exit_sell_bad_bars = 0;
   }
   return closed_any;
}

//+------------------------------------------------------------------+
//| MAIN STRATEGY: Liquidity + CHoCH + BOS + FVG/OB + PA            |
//+------------------------------------------------------------------+
void ExecuteStrategyLogic()
{
   int hn = MathMax(MathMax(2*InpPivotLength+4, 8), InpBreakoutConfirmBars+3);
   double cl[], op[], hi[], lo[];
   ArraySetAsSeries(cl,true); ArraySetAsSeries(op,true);
   ArraySetAsSeries(hi,true); ArraySetAsSeries(lo,true);
   if(CopyClose(Symbol(),Period(),0,hn,cl)<hn || CopyOpen(Symbol(),Period(),0,hn,op)<hn ||
      CopyHigh(Symbol(),Period(),0,hn,hi)<hn   || CopyLow(Symbol(),Period(),0,hn,lo)<hn) return;

   AgeCHoCHState();

   // 1. Pivot detection
   int ti = InpPivotLength+1;
   bool iph=true, ipl=true;
   for(int j=1; j<=2*InpPivotLength+1; j++)
   {
      if(j==ti) continue;
      if(hi[j]>hi[ti]) iph=false;
      if(lo[j]<lo[ti]) ipl=false;
   }
   if(iph) {
      prev_ph=last_ph; last_ph=hi[ti];
      if(trend==1&&prev_ph>0&&last_ph<prev_ph) {
         SetBearishCHoCH();
         Print("ATS EA: Bearish CHoCH PH ",last_ph," < ",prev_ph);
         SendActivityLog("info", StringFormat("Bearish CHoCH — Pivot High %s < previous %s", DoubleToString(last_ph,2), DoubleToString(prev_ph,2)));
      }
      Print("ATS EA: Pivot High ",last_ph);
      SendActivityLog("info", StringFormat("Pivot High %s", DoubleToString(last_ph,2)));
   }
   if(ipl) {
      prev_pl=last_pl; last_pl=lo[ti];
      if(trend==-1&&prev_pl>0&&last_pl>prev_pl) {
         SetBullishCHoCH();
         Print("ATS EA: Bullish CHoCH PL ",last_pl," > ",prev_pl);
         SendActivityLog("info", StringFormat("Bullish CHoCH — Pivot Low %s > previous %s", DoubleToString(last_pl,2), DoubleToString(prev_pl,2)));
      }
      Print("ATS EA: Pivot Low ",last_pl);
      SendActivityLog("info", StringFormat("Pivot Low %s", DoubleToString(last_pl,2)));
   }

   // 2. BOS: require consecutive closed-bar confirmation and expire stale candidates.
   double cc = cl[1]; prev_trend=trend;
   UpdateBOSTrend(cc, true);

   // 3. Swing update
   if(trend==1)  { swing_low=(!swing_low)?last_pl:swing_low; swing_high=MathMax(!swing_high?hi[1]:swing_high,hi[1]); }
   if(trend==-1) { swing_high=(!swing_high)?last_ph:swing_high; swing_low=MathMin(!swing_low?lo[1]:swing_low,lo[1]); }
   if(trend!=prev_trend)
   {
      if(trend==1)  { swing_low=last_pl; swing_high=hi[1]; }
      if(trend==-1) { swing_high=last_ph; swing_low=lo[1]; }
   }

   // 4. FVG & OB detection
   UpdateZoneLifecycle(cc, trend != prev_trend);
   DetectFVG(hi, lo);
   DetectOB(op, cl, hi, lo);

   // 5. Premium / Discount
   double sr=swing_high-swing_low;
   double dl=swing_low+(sr*InpPDThreshold), pl2=swing_high-(sr*InpPDThreshold);
   double ps=GetPositionSize();
   if(trend!=1||ps>0) touched_discount=false;
   if(trend!=-1||ps<0) touched_premium=false;
   if(trend==1) {
      if(hi[1]>=pl2) touched_discount=false;
      if(lo[1]<=dl) touched_discount=true;
   }
   if(trend==-1) {
      if(lo[1]<=dl) touched_premium=false;
      if(hi[1]>=pl2) touched_premium=true;
   }

   // 6. FVG/OB re-entry check
   bool in_bull_fvg = fvg_bull_low>0&&fvg_bull_high>0 && lo[1]<=fvg_bull_high && hi[1]>=fvg_bull_low;
   bool in_bull_ob  = ob_bull_low>0&&ob_bull_high>0   && lo[1]<=ob_bull_high  && hi[1]>=ob_bull_low;
   bool in_bear_fvg = fvg_bear_low>0&&fvg_bear_high>0 && lo[1]<=fvg_bear_high && hi[1]>=fvg_bear_low;
   bool in_bear_ob  = ob_bear_low>0&&ob_bear_high>0   && lo[1]<=ob_bear_high  && hi[1]>=ob_bear_low;

    // 7. PA confirmation (4-layer filter)
    bool bullish_pa_raw = cl[2] < op[2] && cl[1] > op[1];
    bool bearish_pa_raw = cl[2] > op[2] && cl[1] < op[1];

    double bull_body   = cl[1] - op[1];
    double bull_range  = hi[1] - lo[1];
    double bear_body   = op[1] - cl[1];
    double bear_range  = hi[1] - lo[1];

    double bull_body_ratio = bull_range > 0 ? bull_body / bull_range : 0.0;
    double bear_body_ratio = bear_range > 0 ? bear_body / bear_range : 0.0;

    double bull_upper_wick = hi[1] - cl[1];
    double bear_lower_wick = cl[1] - lo[1];
    double bull_wick_ratio = bull_range > 0 ? bull_upper_wick / bull_range : 1.0;
    double bear_wick_ratio = bear_range > 0 ? bear_lower_wick / bear_range : 1.0;

    double bull_close_pos  = bull_range > 0 ? (cl[1] - lo[1]) / bull_range : 0.0;
    double bear_close_pos  = bear_range > 0 ? (hi[1] - cl[1]) / bear_range : 0.0;

    bool bull_engulf = !InpPAEngulf || (cl[1] > hi[2]);
    bool bear_engulf = !InpPAEngulf || (cl[1] < lo[2]);

    bool bull_pa = bullish_pa_raw
                && bull_body_ratio >= InpPABodyMin
                && bull_wick_ratio  <= InpPAWickMax
                && bull_close_pos   >= InpPACloseMin
                && bull_engulf;

    bool bear_pa = bearish_pa_raw
                && bear_body_ratio >= InpPABodyMin
                && bear_wick_ratio  <= InpPAWickMax
                && bear_close_pos   >= InpPACloseMin
                && bear_engulf;

    // 8. EMA filter
   bool ema_lc=!InpUseEMA, ema_sc=!InpUseEMA;
   if(InpUseEMA)
   {
      double eb[1];
      bool ema_ready = ema_handle != INVALID_HANDLE
                       && BarsCalculated(ema_handle) > InpEMALength
                       && CopyBuffer(ema_handle,0,1,1,eb)==1;
      if(!ema_ready)
      {
         // A handle created once in OnInit() can stay permanently stuck at
         // BarsCalculated()<=length in the Strategy Tester (reproduced across
         // a full multi-year run: 0 valid reads out of 368k bars), even
         // though the same iMA()+CopyBuffer() pattern used fresh per-call in
         // GetHTFTrend() works every time. Recreate the handle instead of
         // leaving entries permanently blocked for the rest of the run.
         if(ema_handle != INVALID_HANDLE) IndicatorRelease(ema_handle);
         ema_handle = iMA(Symbol(), Period(), InpEMALength, 0, MODE_EMA, PRICE_CLOSE);
         ema_ready = ema_handle != INVALID_HANDLE
                     && BarsCalculated(ema_handle) > InpEMALength
                     && CopyBuffer(ema_handle,0,1,1,eb)==1;
      }
      if(ema_ready)
      {
         ema_lc=(cc>eb[0]);
         ema_sc=(cc<eb[0]);
      }
      else
         Print("ATS EA: Entry blocked because EMA data is unavailable.");
   }

   // 9. HTF filters: enabled timeframes must have valid data. Directional
   // agreement is enforced only when InpFilterCounterTrend is enabled.
   bool h1b=false,h1r=false,h4b=false,h4r=false;
   bool h1_ready = !InpUseH1Trend || GetHTFTrend(PERIOD_H1,InpH1EMALen,h1b,h1r);
   bool h4_ready = !InpUseH4Trend || GetHTFTrend(PERIOD_H4,InpH4EMALen,h4b,h4r);
   bool htf_data_ok = h1_ready && h4_ready;

   bool long_is_countertrend  = (InpUseH1Trend && h1r) || (InpUseH4Trend && h4r);
   bool short_is_countertrend = (InpUseH1Trend && h1b) || (InpUseH4Trend && h4b);
   bool lok = htf_data_ok && (!InpFilterCounterTrend || !long_is_countertrend);
   bool sok = htf_data_ok && (!InpFilterCounterTrend || !short_is_countertrend);
   bool long_htf_aligned = htf_data_ok
                           && (!InpUseH1Trend || h1b)
                           && (!InpUseH4Trend || h4b);
   bool short_htf_aligned = htf_data_ok
                            && (!InpUseH1Trend || h1r)
                            && (!InpUseH4Trend || h4r);

   if(!htf_data_ok)
      Print("ATS EA: Entry blocked because enabled HTF trend data is unavailable.");

   bool buy_structure_break = last_pl > 0.0 && cc < last_pl;
   bool sell_structure_break = last_ph > 0.0 && cc > last_ph;
   bool htf_exit_enabled = InpExitOnHTFReversal && (InpUseH1Trend || InpUseH4Trend) && htf_data_ok;
   bool buy_htf_reversal = htf_exit_enabled
                           && (!InpUseH1Trend || h1r)
                           && (!InpUseH4Trend || h4r);
   bool sell_htf_reversal = htf_exit_enabled
                            && (!InpUseH1Trend || h1b)
                            && (!InpUseH4Trend || h4b);

   bool buy_bad_signal = (InpExitOnOppositeCHoCH && choch_bear)
                         || (InpExitOnStructureBreak && buy_structure_break)
                         || buy_htf_reversal;
   bool sell_bad_signal = (InpExitOnOppositeCHoCH && choch_bull)
                          || (InpExitOnStructureBreak && sell_structure_break)
                          || sell_htf_reversal;
   string buy_exit_reason = (InpExitOnStructureBreak && buy_structure_break) ? "Structure Break"
                            : (InpExitOnOppositeCHoCH && choch_bear) ? "Bearish CHoCH" : "H1/H4 Reversal";
   string sell_exit_reason = (InpExitOnStructureBreak && sell_structure_break) ? "Structure Break"
                             : (InpExitOnOppositeCHoCH && choch_bull) ? "Bullish CHoCH" : "H1/H4 Reversal";
   bool early_exit_closed = ManageEarlyExit(cc, buy_bad_signal, sell_bad_signal,
                                            buy_exit_reason, sell_exit_reason);

   // 10. Entry conditions (one trade at a time, frequent entries)
   bool no_pos = (GetPositionCount()==0);
   bool fvg_ob_bull = false;
   bool fvg_ob_bear = false;
   
   if(InpEntryMode == ENTRY_MODE_DISCOUNT_ONLY) {
       fvg_ob_bull = touched_discount;
       fvg_ob_bear = touched_premium;
   } else if(InpEntryMode == ENTRY_MODE_ANY_FVG) {
       fvg_ob_bull = in_bull_fvg || in_bull_ob || touched_discount;
       fvg_ob_bear = in_bear_fvg || in_bear_ob || touched_premium;
   } else if(InpEntryMode == ENTRY_MODE_STRICT_ICT) {
       fvg_ob_bull = (in_bull_fvg || in_bull_ob) && touched_discount;
       fvg_ob_bear = (in_bear_fvg || in_bear_ob) && touched_premium;
   }
   
   // News & Volume filter
    bool news_blocked = false;
    bool volume_spike_blocked = false;
    if(InpUseNewsFilter)
    {
       datetime time_in_tz = GetTimeInTimezone(InpNewsTimezone);
       if(IsInSessionString(time_in_tz, InpNewsSession))
       {
           news_blocked = true;
           Print("ATS EA: Trade blocked by News Filter (Current Time in Timezone: ", TimeToString(time_in_tz), ")");
       }
    }
    if(InpUseVolFilter)
    {
       if(IsVolumeSpikeActive(InpVolSmaLen, InpVolSpikeMult, InpVolSpikeLookback))
       {
           volume_spike_blocked = true;
           if(!InpUseTrendBreakout || !InpBreakoutAllowVolumeSpike)
              Print("ATS EA: Trade blocked by Volume Spike Filter.");
       }
    }
    bool normal_filter_blocked = news_blocked || volume_spike_blocked;
    bool breakout_filter_blocked = news_blocked
                                   || (volume_spike_blocked && !InpBreakoutAllowVolumeSpike);
    
    // Sideway & Range Filters
    bool sideway_blocked = false;
    double adx = 0.0;
    if(InpUseADXFilter)
    {
       adx = GetADXValue();
       if(adx < InpADXMinThreshold)
       {
          sideway_blocked = true;
       }
    }
    double chop = 0.0;
    if(!sideway_blocked && InpUseChopFilter)
    {
       chop = CalculateChoppiness(InpChopLen);
       if(chop > InpChopMaxThreshold)
       {
          sideway_blocked = true;
       }
    }
    double atr_ratio = 0.0;
    if(!sideway_blocked && InpUseATRFilter)
    {
       bool atr_ready = GetATRRatioValue(atr_ratio);
       if(!atr_ready || atr_ratio < InpATRMinRatio)
       {
          sideway_blocked = true;
          if(!atr_ready)
             Print("ATS EA: Entry blocked because ATR ratio data is unavailable.");
       }
    }

    bool in_force_close = false;
     if(InpUseForceClose)
    {
       datetime time_in_tz = GetTimeInTimezone(InpForceCloseTimezone);
       if(IsInSessionString(time_in_tz, InpForceCloseSession))
           in_force_close = true;
     }

     int today_loss_count = 0;
     bool daily_loss_blocked = IsDailyLossBlocked(Symbol(), today_loss_count);
     if(daily_loss_blocked)
        Print("ATS EA: Entry blocked by Daily Loss Guard (", today_loss_count,
              "/", InpMaxDailyLossCount, " losing positions, timezone=", InpDailyLossTimezone, ")");

     bool choch_long_ok  = !InpRequireCHoCH || choch_bull;
     bool choch_short_ok = !InpRequireCHoCH || choch_bear;

     int cooldown_remaining = 0;
     bool loss_cooldown_blocked = IsLossCooldownActive(Symbol(), cooldown_remaining);
     if(loss_cooldown_blocked)
        Print("ATS EA: Entry blocked by Loss Cooldown (", cooldown_remaining, " minutes remaining)");

     double bull_breakout_extension_atr = 0.0;
     double bear_breakout_extension_atr = 0.0;
     bool bull_breakout_confirmed = (trend == 1)
                                     && IsConfirmedTrendBreakout(1, last_ph, cl, op, hi, lo,
                                                                  bull_breakout_extension_atr);
     bool bear_breakout_confirmed = (trend == -1)
                                     && IsConfirmedTrendBreakout(-1, last_pl, cl, op, hi, lo,
                                                                  bear_breakout_extension_atr);

     bool breakout_long_htf_ok = InpBreakoutRequireHTFAlignment ? long_htf_aligned : lok;
     bool breakout_short_htf_ok = InpBreakoutRequireHTFAlignment ? short_htf_aligned : sok;
     bool common_entry_ok = no_pos && !early_exit_closed && !sideway_blocked
                            && !in_force_close && !daily_loss_blocked && !loss_cooldown_blocked;

     bool normalLongCond = (trend==1) && choch_long_ok && fvg_ob_bull && bull_pa
                           && ema_lc && lok && common_entry_ok && !normal_filter_blocked;
     bool normalShortCond = (trend==-1) && choch_short_ok && fvg_ob_bear && bear_pa
                            && ema_sc && sok && common_entry_ok && !normal_filter_blocked;
     bool breakoutLongCond = bull_breakout_confirmed && ema_lc && breakout_long_htf_ok
                             && common_entry_ok && !breakout_filter_blocked;
     bool breakoutShortCond = bear_breakout_confirmed && ema_sc && breakout_short_htf_ok
                              && common_entry_ok && !breakout_filter_blocked;

     // Breakout classification takes precedence when both paths become true on
     // the same bar; common_entry_ok still guarantees a single position.
     bool longCond = normalLongCond || breakoutLongCond;
     bool shortCond = normalShortCond || breakoutShortCond;
     bool long_entry_is_breakout = breakoutLongCond;
     bool short_entry_is_breakout = breakoutShortCond;

   double pt        = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   double tp_v      = InpTPPips * pt;
   double sl_buffer = InpSLBuffer * pt;

   bool is_low_vol = false;
   if(InpUseAdaptiveBE)
   {
       long vol_arr[]; ArraySetAsSeries(vol_arr, true);
       // Compare the just-closed entry bar with N strictly older closed bars.
       int required_volume_bars = InpVolSmaLen + 1;
       if(CopyTickVolume(Symbol(), Period(), 1, required_volume_bars, vol_arr) >= required_volume_bars)
       {
           double sum = 0;
           for(int j = 1; j <= InpVolSmaLen; j++) sum += (double)vol_arr[j];
           double sma = sum / InpVolSmaLen;
           if((double)vol_arr[0] < sma) is_low_vol = true;
       }
   }

   // 11. Execute BUY
   if(longCond)
   {
      MqlTick tk;
      if(!SymbolInfoTick(Symbol(),tk))
      {
         Print("ATS EA TRADE ERROR: Cannot read BUY tick. Error=", GetLastError());
         return;
      }
      double a = tk.ask;
      double slp = 0.0;
       if(InpUseFixedSL) {
           slp = a - (InpFixedSLPips * pt);
       } else {
           if(long_entry_is_breakout)
              slp = last_ph - sl_buffer;
           else
           {
              slp = swing_low - sl_buffer;
              if(ob_bull_low>0 && ob_bull_low<slp) slp=ob_bull_low-sl_buffer;
           }
       }
      double risk = a - slp;
      if(!InpUseFixedSL && (risk>InpMaxSLPips*pt||risk<=0))
         { risk=InpMaxSLPips*pt; slp=a-risk; }
      double atp=a+tp_v;
      if(!PrepareMarketStops(Symbol(), true, tk, slp, atp))
         return;
      string buy_entry_tag = long_entry_is_breakout ? "BREAKOUT" : (in_bull_fvg?"FVG":in_bull_ob?"OB":"PD");
      Print("ATS EA: BUY | Ask=",a," SL=",slp," TP=",atp," Lot=",InpFixedLot,
            " Entry=",buy_entry_tag,
            long_entry_is_breakout ? StringFormat(" ExtensionATR=%.2f", bull_breakout_extension_atr) : "");
      ResetLastError();
      string buy_comment = long_entry_is_breakout ? "ATS BUY[BREAKOUT]" : "ATS BUY[BOS+FVG/OB]";
      bool buy_request_ok = trade.Buy(InpFixedLot, Symbol(), a, slp, atp, buy_comment);
      if(IsTradeResultSuccessful(buy_request_ok, "Strategy BUY"))
      {
          ulong position_identifier = 0;
          if(ResolveManagedPositionIdentity(Symbol(), POSITION_TYPE_BUY, trade.ResultOrder(),
                                            position_identifier))
          {
             if(InpUseAdaptiveBE && is_low_vol) GlobalVariableSet(GetAnalyticsKey("LOW_VOL", position_identifier), 1.0);
             GlobalVariableSet(GetAnalyticsKey("MAX_PRICE", position_identifier), a);
             GlobalVariableSet(GetAnalyticsKey("MIN_PRICE", position_identifier), a);
             GlobalVariableSet(GetAnalyticsKey("ADX", position_identifier), adx);
             GlobalVariableSet(GetAnalyticsKey("CHOP", position_identifier), chop);
             GlobalVariableSet(GetAnalyticsKey("ATR", position_identifier), atr_ratio);
          }
          else
             Print("ATS EA WARNING: Cannot resolve BUY position identifier for analytics.");
          ClearBullishCHoCH();
      }
   }
   else if(shortCond)
   {
      MqlTick tk;
      if(!SymbolInfoTick(Symbol(),tk))
      {
         Print("ATS EA TRADE ERROR: Cannot read SELL tick. Error=", GetLastError());
         return;
      }
      double b = tk.bid;
      double slp = 0.0;
       if(InpUseFixedSL) {
           slp = b + (InpFixedSLPips * pt);
       } else {
           if(short_entry_is_breakout)
              slp = last_pl + sl_buffer;
           else
           {
              slp = swing_high + sl_buffer;
              if(ob_bear_high>0 && ob_bear_high>slp) slp=ob_bear_high+sl_buffer;
           }
       }
      double risk = slp - b;
      if(!InpUseFixedSL && (risk>InpMaxSLPips*pt||risk<=0))
         { risk=InpMaxSLPips*pt; slp=b+risk; }
      double btp=b-tp_v;
      if(!PrepareMarketStops(Symbol(), false, tk, slp, btp))
         return;
      string sell_entry_tag = short_entry_is_breakout ? "BREAKOUT" : (in_bear_fvg?"FVG":in_bear_ob?"OB":"PD");
      Print("ATS EA: SELL | Bid=",b," SL=",slp," TP=",btp," Lot=",InpFixedLot,
            " Entry=",sell_entry_tag,
            short_entry_is_breakout ? StringFormat(" ExtensionATR=%.2f", bear_breakout_extension_atr) : "");
      ResetLastError();
      string sell_comment = short_entry_is_breakout ? "ATS SELL[BREAKOUT]" : "ATS SELL[BOS+FVG/OB]";
      bool sell_request_ok = trade.Sell(InpFixedLot, Symbol(), b, slp, btp, sell_comment);
      if(IsTradeResultSuccessful(sell_request_ok, "Strategy SELL"))
      {
          ulong position_identifier = 0;
          if(ResolveManagedPositionIdentity(Symbol(), POSITION_TYPE_SELL, trade.ResultOrder(),
                                            position_identifier))
          {
             if(InpUseAdaptiveBE && is_low_vol) GlobalVariableSet(GetAnalyticsKey("LOW_VOL", position_identifier), 1.0);
             GlobalVariableSet(GetAnalyticsKey("MAX_PRICE", position_identifier), b);
             GlobalVariableSet(GetAnalyticsKey("MIN_PRICE", position_identifier), b);
             GlobalVariableSet(GetAnalyticsKey("ADX", position_identifier), adx);
             GlobalVariableSet(GetAnalyticsKey("CHOP", position_identifier), chop);
             GlobalVariableSet(GetAnalyticsKey("ATR", position_identifier), atr_ratio);
          }
          else
             Print("ATS EA WARNING: Cannot resolve SELL position identifier for analytics.");
          ClearBearishCHoCH();
      }
   }
}

//+------------------------------------------------------------------+
//| Breakeven & Scaled Trailing (every tick)                         |
//| Level 1 : profit >= 500 pip  -> SL = entry (breakeven)          |
//| Level 2 : profit >= 1000 pip -> SL = entry + 500 pip            |
//| TP : hard-coded at 1500 pip from entry                           |
//+------------------------------------------------------------------+
void CheckBEAndTrailing()
{
   if(GetPositionCount()==0)
   {
      int n=GlobalVariablesTotal();
      string analytics_prefix = GetAnalyticsPrefix();
      for(int k=n-1; k>=0; k--)
      {
         string gn=GlobalVariableName(k);
         if(StringFind(gn, analytics_prefix) == 0)
            GlobalVariableDel(gn);
      }
      return;
   }
   double pt    = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   double be_d  = InpBEPips * pt;
   double be_d_low = InpBELowVolPips * pt;
   double be_cost_lock_d = InpBECostBufferPoints * pt;
   double t1_d  = InpTrailLevel1Pips * pt;
   double lk_d  = InpTrailLevel1LockPips * pt;

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      if(PositionGetSymbol(i)!=Symbol()||PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      ulong  tk   = PositionGetInteger(POSITION_TICKET);
      ulong  analytics_identity = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      if(analytics_identity == 0) analytics_identity = tk;
      double ep   = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      long   typ  = PositionGetInteger(POSITION_TYPE);
      double cur  = SymbolInfoDouble(Symbol(),(typ==POSITION_TYPE_BUY)?SYMBOL_BID:SYMBOL_ASK);
      double nsl  = sl;
      bool   mod  = false;

      string max_price_key = GetAnalyticsKey("MAX_PRICE", analytics_identity);
      string min_price_key = GetAnalyticsKey("MIN_PRICE", analytics_identity);
      double max_price = GlobalVariableCheck(max_price_key) ? GlobalVariableGet(max_price_key) : ep;
      double min_price = GlobalVariableCheck(min_price_key) ? GlobalVariableGet(min_price_key) : ep;
      if(cur > max_price) max_price = cur;
      if(cur < min_price) min_price = cur;
      GlobalVariableSet(max_price_key, max_price);
      GlobalVariableSet(min_price_key, min_price);

      if(typ==POSITION_TYPE_BUY)
      {
         double pd = max_price-ep;
         double active_be_d = be_d;
         if(InpUseAdaptiveBE && GlobalVariableCheck(GetAnalyticsKey("LOW_VOL", analytics_identity))) active_be_d = be_d_low;
         
         if(pd>=t1_d)         // Level 2 Trailing Stop
         {
            double ls = ep + lk_d;
            if(InpUseSteppedTrail)
            {
               double step_multiplier = MathFloor(pd / lk_d);
               double locked_profit = (step_multiplier - 1.0) * lk_d;
               ls = ep + locked_profit;
            }
            if(nsl<ls) { nsl=ls; mod=true; Print("ATS BUY #",tk," Trail SL=",nsl); }
         }
         else if(pd>=active_be_d)    // Level 1: breakeven
         {
            double be_locked = ep + be_cost_lock_d;
            if(nsl<be_locked) { nsl=be_locked; mod=true; Print("ATS BUY #",tk," BE SL=",nsl); }
         }
          if(mod&&nsl>sl)
          {
             if(!PrepareModifiedStop(Symbol(), typ, cur, nsl))
                continue;
             // A rejected modify (e.g. broker "invalid stops") leaves the position's
             // real SL unchanged, so next tick recomputes the SAME target and retries
             // - without this guard that repeats every tick forever (seen in backtest:
             // hundreds of identical "invalid stops" retries within one bar). Skip a
             // target once it has already failed, until price moves it to something new.
             string failed_sl_key = GetAnalyticsKey("LAST_FAILED_SL", analytics_identity);
             if(GlobalVariableCheck(failed_sl_key) && MathAbs(GlobalVariableGet(failed_sl_key) - nsl) < pt/2)
                continue;
             ResetLastError();
             bool modify_request_ok = trade.PositionModify(tk,nsl,tp);
             if(IsTradeResultSuccessful(modify_request_ok, "BUY SL modify", tk, true))
                GlobalVariableDel(failed_sl_key);
             else
                GlobalVariableSet(failed_sl_key, nsl);
          }
      }
      else
      {
         double pd = ep-min_price;
         double active_be_d = be_d;
         if(InpUseAdaptiveBE && GlobalVariableCheck(GetAnalyticsKey("LOW_VOL", analytics_identity))) active_be_d = be_d_low;
         
         if(pd>=t1_d)         // Level 2 Trailing Stop
         {
            double ls = ep - lk_d;
            if(InpUseSteppedTrail)
            {
               double step_multiplier = MathFloor(pd / lk_d);
               double locked_profit = (step_multiplier - 1.0) * lk_d;
               ls = ep - locked_profit;
            }
            if(sl==0.0||nsl>ls) { nsl=ls; mod=true; Print("ATS SELL #",tk," Trail SL=",nsl); }
         }
         else if(pd>=active_be_d)    // Level 1: breakeven
         {
            double be_locked = ep - be_cost_lock_d;
            if(sl==0.0||nsl>be_locked) { nsl=be_locked; mod=true; Print("ATS SELL #",tk," BE SL=",nsl); }
         }
          if(mod&&(sl==0.0||nsl<sl))
          {
             if(!PrepareModifiedStop(Symbol(), typ, cur, nsl))
                continue;
             // See matching comment in the BUY branch above - same guard against
             // retrying an already-rejected target every tick forever.
             string failed_sl_key = GetAnalyticsKey("LAST_FAILED_SL", analytics_identity);
             if(GlobalVariableCheck(failed_sl_key) && MathAbs(GlobalVariableGet(failed_sl_key) - nsl) < pt/2)
                continue;
             ResetLastError();
             bool modify_request_ok = trade.PositionModify(tk,nsl,tp);
             if(IsTradeResultSuccessful(modify_request_ok, "SELL SL modify", tk, true))
                GlobalVariableDel(failed_sl_key);
             else
                GlobalVariableSet(failed_sl_key, nsl);
          }
      }
   }
}

bool ValidateInputParameters()
{
   if(InpMagic <= 0 || InpSlippage < 0)
   {
      Print("ATS EA ERROR: InpMagic must be positive and InpSlippage cannot be negative.");
      return false;
   }
   if(InpPivotLength < 1 || InpPDThreshold <= 0.0 || InpPDThreshold > 1.0)
   {
      Print("ATS EA ERROR: InpPivotLength must be >= 1 and InpPDThreshold must be in (0,1].");
      return false;
   }
   if(InpBOSConfirmBars < 1 || InpBOSMaxPendingBars < InpBOSConfirmBars
      || InpCHoCHMaxAgeBars < 1 || InpFVGMaxAgeBars < 1 || InpOBMaxAgeBars < 1)
   {
      Print("ATS EA ERROR: BOS/CHoCH confirmation/expiry and FVG/OB maximum ages are invalid.");
      return false;
   }
   if(InpUseTrendBreakout
      && (InpBreakoutConfirmBars < 1 || InpBreakoutConfirmBars > 10
          || InpBreakoutMinBodyATR <= 0.0
          || InpBreakoutMaxExtensionATR <= 0.0
          || InpBreakoutMaxCloseWickRatio < 0.0
          || InpBreakoutMaxCloseWickRatio > 1.0))
   {
      Print("ATS EA ERROR: Breakout requires ConfirmBars 1..10, positive ATR thresholds, and CloseWickRatio in [0,1].");
      return false;
   }
   if(InpSLBuffer < 0.0 || InpMaxSLPips <= 0 || (InpUseFixedSL && InpFixedSLPips <= 0))
   {
      Print("ATS EA ERROR: Stop parameters require non-negative buffer and positive SL distances.");
      return false;
   }
   if(InpFixedLot <= 0.0 || InpTPPips <= 0)
   {
      Print("ATS EA ERROR: InpFixedLot and InpTPPips must be positive.");
      return false;
   }
   if(InpWebhookMaxLot <= 0.0
      || InpWebhookMaxRiskPct <= 0.0 || InpWebhookMaxRiskPct > 10.0
      || InpWebhookMaxSpreadPrice <= 0.0
      || InpWebhookMaxPositions < 1)
   {
      Print("ATS EA ERROR: Webhook risk limits require positive lot/spread/positions and risk in (0,10].");
      return false;
   }
   if((InpUseEMA && InpEMALength < 1)
      || (InpUseH1Trend && InpH1EMALen < 1)
      || (InpUseH4Trend && InpH4EMALen < 1))
   {
      Print("ATS EA ERROR: Every enabled EMA length must be >= 1.");
      return false;
   }
   if(InpPABodyMin < 0.0 || InpPABodyMin > 1.0
      || InpPAWickMax < 0.0 || InpPAWickMax > 1.0
      || InpPACloseMin < 0.0 || InpPACloseMin > 1.0)
   {
      Print("ATS EA ERROR: Price-action ratios must be between 0 and 1.");
      return false;
   }
   if((InpUseVolFilter || InpUseAdaptiveBE) && InpVolSmaLen < 1)
   {
      Print("ATS EA ERROR: InpVolSmaLen must be >= 1 when volume logic is enabled.");
      return false;
   }
   if(InpUseVolFilter && (InpVolSpikeMult <= 0.0 || InpVolSpikeLookback < 1))
   {
      Print("ATS EA ERROR: Volume spike multiplier/lookback must be positive.");
      return false;
   }
   if(InpUseADXFilter && (InpADXLen < 1 || InpADXMinThreshold < 0.0))
   {
      Print("ATS EA ERROR: ADX length must be >= 1 and threshold cannot be negative.");
      return false;
   }
   if(InpUseChopFilter && (InpChopLen <= 1 || InpChopMaxThreshold < 0.0))
   {
      Print("ATS EA ERROR: Choppiness length must be > 1 and threshold cannot be negative.");
      return false;
   }
   if(InpUseATRFilter && InpATRMinRatio <= 0.0)
   {
      Print("ATS EA ERROR: InpATRMinRatio must be positive.");
      return false;
   }
   if(InpBEPips <= 0 || InpBECostBufferPoints < 0 || InpTrailLevel1Pips <= 0
      || (InpUseAdaptiveBE && InpBELowVolPips <= 0)
      || (InpUseSteppedTrail && InpTrailLevel1LockPips <= 0))
   {
      Print("ATS EA ERROR: Breakeven/trailing distances must be positive when enabled.");
      return false;
   }
   if(InpUseDailyLossGuard && InpMaxDailyLossCount < 1)
   {
      Print("ATS EA ERROR: InpMaxDailyLossCount must be at least 1.");
      return false;
   }
   if(InpUseLossCooldown && InpLossCooldownMins < 1)
   {
      Print("ATS EA ERROR: InpLossCooldownMins must be at least 1.");
      return false;
   }
   if(InpUseEarlyExit && (InpExitConfirmBars < 1
      || InpEarlyExitRiskR <= 0.0 || InpEarlyExitRiskR > 1.0))
   {
      Print("ATS EA ERROR: Early Exit requires ConfirmBars >= 1 and RiskR in (0,1].");
      return false;
   }
   if(InpUseTimeStop && InpTimeStopBars < 1)
   {
      Print("ATS EA ERROR: InpTimeStopBars must be >= 1 when Time Stop is enabled.");
      return false;
   }
   if(InpPollInterval < 16)
   {
      Print("ATS EA ERROR: InpPollInterval must be at least 16 milliseconds.");
      return false;
   }
   if(InpSignalDedupDays < 1 || InpSignalDedupDays > 3650)
   {
      Print("ATS EA ERROR: InpSignalDedupDays must be between 1 and 3650.");
      return false;
   }
   if(InpTesterServerUtcOffsetHours < -14.0 || InpTesterServerUtcOffsetHours > 14.0)
   {
      Print("ATS EA ERROR: InpTesterServerUtcOffsetHours must be between -14 and 14.");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(!ValidateInputParameters())
      return(INIT_PARAMETERS_INCORRECT);

   backend_url = InpBackendURL;
   if(StringSubstr(backend_url,StringLen(backend_url)-1,1)=="/")
      backend_url=StringSubstr(backend_url,0,StringLen(backend_url)-1);
   auth_token=InpAuthToken;
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   CleanupExpiredSignalClaims();
   
   // Initialize Indicators
   if(InpUseADXFilter)
   {
      adx_handle = iADX(Symbol(), Period(), InpADXLen);
      if(adx_handle == INVALID_HANDLE) { Print("ATS EA ERROR: Failed to create ADX handle"); return(INIT_FAILED); }
   }
   if(InpUseATRFilter || InpUseTrendBreakout)
   {
      atr_handle = iATR(Symbol(), Period(), 14);
      if(atr_handle == INVALID_HANDLE) { Print("ATS EA ERROR: Failed to create ATR handle"); return(INIT_FAILED); }
   }
   if(InpUseEMA)
   {
      ema_handle = iMA(Symbol(), Period(), InpEMALength, 0, MODE_EMA, PRICE_CLOSE);
      if(ema_handle == INVALID_HANDLE) { Print("ATS EA ERROR: Failed to create EMA handle"); return(INIT_FAILED); }
   }
   
   InitStateFromHistory();
   InitTrackedPositions();
   if(InpEnableWebhookPolling && IsExternalIntegrationAllowed())
   {
      if(!EventSetMillisecondTimer(InpPollInterval))
         Print("ATS EA ERROR: Failed to start webhook polling timer. Error=", GetLastError());
   }
   else if(!IsExternalIntegrationAllowed())
      Print("ATS EA: Strategy Tester/optimization detected; timer and WebRequest calls are skipped.");
   else
      Print("ATS EA: Webhook polling timer disabled; local position synchronization remains enabled.");
   Print("ATS EA v2.22 | Lot=",InpFixedLot," BE=",InpBEPips,"p Trail@",InpTrailLevel1Pips,"p->",InpTrailLevel1LockPips,"p TP=",InpTPPips,"p");
   Print("ATS EA: Strategy = Counter-trend filter + pullback entry + confirmed trend breakout");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if(adx_handle != INVALID_HANDLE) IndicatorRelease(adx_handle);
   if(atr_handle != INVALID_HANDLE) IndicatorRelease(atr_handle);
   if(ema_handle != INVALID_HANDLE) IndicatorRelease(ema_handle);
   Print("ATS EA: Deinitialized.");
}

void OnTick()
{
   // Publish a just-closed position before no-position cleanup can remove its
   // analytics state. Open-position management then updates extrema per tick.
   if(IsExternalIntegrationAllowed()) SyncPositionsWithBackend();
   CheckBEAndTrailing();
   
   // Force Close Check
   if(InpUseForceClose)
   {
      datetime time_in_tz = GetTimeInTimezone(InpForceCloseTimezone);
      if(IsInSessionString(time_in_tz, InpForceCloseSession))
      {
         ForceCloseAllPositions();
      }
   }
   
   if(IsNewBar()) ExecuteStrategyLogic();
}

string GetMT5StateJson()
{
   double bal=AccountInfoDouble(ACCOUNT_BALANCE), eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double fm=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double bid=SymbolInfoDouble(Symbol(),SYMBOL_BID), ask=SymbolInfoDouble(Symbol(),SYMBOL_ASK);
   string pj="["; int total=PositionsTotal(), cnt=0;
   for(int i=0;i<total;i++)
   {
      string selected_symbol=PositionGetSymbol(i);
      if(selected_symbol=="") continue;
      if(selected_symbol!=Symbol() || PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      ulong tk=PositionGetInteger(POSITION_TICKET);
      string sym=selected_symbol;
      string ptyp=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)?"BUY":"SELL";
      if(cnt>0) pj+=",";
      pj+=StringFormat("{\"ticket\":\"%s\",\"symbol\":\"%s\",\"type\":\"%s\",\"volume\":%s,"
                       "\"open_price\":%s,\"current_price\":%s,\"sl\":%s,\"tp\":%s,\"profit\":%s}",
         IntegerToString(tk),sym,ptyp,
         DoubleToString(PositionGetDouble(POSITION_VOLUME),2),
         DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN),5),
         DoubleToString(PositionGetDouble(POSITION_PRICE_CURRENT),5),
         DoubleToString(PositionGetDouble(POSITION_SL),5),
         DoubleToString(PositionGetDouble(POSITION_TP),5),
         DoubleToString(PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP),2));
      cnt++;
   }
   pj+="]";
   return StringFormat("{\"token\":\"%s\",\"account_id\":%d,\"balance\":%s,\"equity\":%s,\"free_margin\":%s,\"bid\":%s,\"ask\":%s,\"positions\":%s}",
      auth_token,InpBackendAccountId,DoubleToString(bal,2),DoubleToString(eq,2),DoubleToString(fm,2),
      DoubleToString(bid,5),DoubleToString(ask,5),pj);
}

void OnTimer()
{
   if(!InpEnableWebhookPolling || !IsExternalIntegrationAllowed()) return;
   string url=backend_url+"/api/signals/pending", hdr="Content-Type: application/json\r\nX-Api-Key: " + auth_token + "\r\n";
   string pay=GetMT5StateJson();
   char pd[],rd[]; string rh;
   StringToCharArray(pay,pd,0,StringLen(pay),CP_UTF8);
   ResetLastError();
   int h=WebRequest("POST",url,hdr,3000,pd,rd,rh);
   if(h==-1) { int e=GetLastError(); if(e==4014) Print("ATS EA: Add '",backend_url,"' to Allowed URLs."); return; }
   if(h!=200) return;
   string jr=CharArrayToString(rd,0,WHOLE_ARRAY,CP_UTF8);
   if(jr!=""&&jr!="[]") ProcessSignals(jr);
}

bool IsJsonWhitespace(const ushort character)
{
   return character == 32 || character == 9 || character == 10 || character == 13;
}

void SkipJsonWhitespace(const string json, int &index)
{
   int length = StringLen(json);
   while(index < length && IsJsonWhitespace(StringGetCharacter(json, index))) index++;
}

bool ParseJsonStringAt(const string json, const int quote_index, string &value, int &next_index)
{
   value = "";
   next_index = quote_index;
   int length = StringLen(json);
   if(quote_index < 0 || quote_index >= length || StringGetCharacter(json, quote_index) != 34)
      return false;

   for(int i = quote_index + 1; i < length; i++)
   {
      ushort character = StringGetCharacter(json, i);
      if(character == 34)
      {
         next_index = i + 1;
         return true;
      }
      if(character == 92)
      {
         i++;
         if(i >= length) return false;
         ushort escaped = StringGetCharacter(json, i);
         if(escaped == 34) value += "\"";
         else if(escaped == 92) value += "\\";
         else if(escaped == 47) value += "/";
         else if(escaped == 98) value += ShortToString(8);
         else if(escaped == 102) value += ShortToString(12);
         else if(escaped == 110) value += "\n";
         else if(escaped == 114) value += "\r";
         else if(escaped == 116) value += "\t";
         else if(escaped == 117)
         {
            if(i + 4 >= length) return false;
            uint unicode_value = 0;
            for(int hex_index = 1; hex_index <= 4; hex_index++)
            {
               ushort hex_character = StringGetCharacter(json, i + hex_index);
               int hex_value = -1;
               if(hex_character >= 48 && hex_character <= 57) hex_value = (int)hex_character - 48;
               else if(hex_character >= 65 && hex_character <= 70) hex_value = (int)hex_character - 65 + 10;
               else if(hex_character >= 97 && hex_character <= 102) hex_value = (int)hex_character - 97 + 10;
               if(hex_value < 0) return false;
               unicode_value = unicode_value * 16 + (uint)hex_value;
            }
            value += ShortToString((ushort)unicode_value);
            i += 4;
         }
         else return false;
      }
      else
         value += StringSubstr(json, i, 1);
   }
   return false;
}

bool TryGetJsonValue(const string json, const string wanted_key, string &value, bool &is_string)
{
   value = "";
   is_string = false;
   int length = StringLen(json), index = 0;
   SkipJsonWhitespace(json, index);
   if(index >= length || StringGetCharacter(json, index) != 123) return false;
   index++;

   while(index < length)
   {
      SkipJsonWhitespace(json, index);
      if(index < length && StringGetCharacter(json, index) == 44) { index++; continue; }
      if(index >= length || StringGetCharacter(json, index) == 125) break;

      string parsed_key = "";
      int after_key = index;
      if(!ParseJsonStringAt(json, index, parsed_key, after_key)) return false;
      index = after_key;
      SkipJsonWhitespace(json, index);
      if(index >= length || StringGetCharacter(json, index) != 58) return false;
      index++;
      SkipJsonWhitespace(json, index);
      if(index >= length) return false;

      string parsed_value = "";
      bool parsed_is_string = false;
      if(StringGetCharacter(json, index) == 34)
      {
         int after_value = index;
         if(!ParseJsonStringAt(json, index, parsed_value, after_value)) return false;
         index = after_value;
         parsed_is_string = true;
      }
      else
      {
         int value_start = index;
         int nested_depth = 0;
         bool inside_string = false, escaped_character = false;
         while(index < length)
         {
            ushort character = StringGetCharacter(json, index);
            if(inside_string)
            {
               if(escaped_character) escaped_character = false;
               else if(character == 92) escaped_character = true;
               else if(character == 34) inside_string = false;
               index++;
               continue;
            }
            if(character == 34) { inside_string = true; index++; continue; }
            if(character == 123 || character == 91) { nested_depth++; index++; continue; }
            if(character == 125)
            {
               if(nested_depth == 0) break;
               nested_depth--; index++; continue;
            }
            if(character == 93) { if(nested_depth > 0) nested_depth--; index++; continue; }
            if(character == 44 && nested_depth == 0) break;
            index++;
         }
         parsed_value = StringSubstr(json, value_start, index - value_start);
         StringTrimLeft(parsed_value);
         StringTrimRight(parsed_value);
      }

      if(parsed_key == wanted_key)
      {
         value = parsed_value;
         is_string = parsed_is_string;
         return true;
      }
   }
   return false;
}

bool IsValidJsonNumber(string token)
{
   StringTrimLeft(token); StringTrimRight(token);
   int length = StringLen(token), index = 0;
   if(length == 0) return false;
   ushort character = StringGetCharacter(token, index);
   if(character == 45) index++;
   if(index >= length) return false;

   character = StringGetCharacter(token, index);
   if(character == 48)
   {
      index++;
      if(index < length)
      {
         character = StringGetCharacter(token, index);
         if(character >= 48 && character <= 57) return false;
      }
   }
   else if(character >= 49 && character <= 57)
   {
      while(index < length)
      {
         character = StringGetCharacter(token, index);
         if(character < 48 || character > 57) break;
         index++;
      }
   }
   else return false;

   if(index < length && StringGetCharacter(token, index) == 46)
   {
      index++;
      int fraction_digits = 0;
      while(index < length)
      {
         character = StringGetCharacter(token, index);
         if(character < 48 || character > 57) break;
         fraction_digits++; index++;
      }
      if(fraction_digits == 0) return false;
   }

   if(index < length && (StringGetCharacter(token, index) == 101 || StringGetCharacter(token, index) == 69))
   {
      index++;
      if(index < length && (StringGetCharacter(token, index) == 43 || StringGetCharacter(token, index) == 45)) index++;
      int exponent_digits = 0;
      while(index < length)
      {
         character = StringGetCharacter(token, index);
         if(character < 48 || character > 57) break;
         exponent_digits++; index++;
      }
      if(exponent_digits == 0) return false;
   }
   return index == length;
}

bool TryGetJsonDouble(const string json, const string key, double &number)
{
   number = 0.0;
   string token = ""; bool is_string = false;
   if(!TryGetJsonValue(json, key, token, is_string) || is_string || !IsValidJsonNumber(token)) return false;
   number = StringToDouble(token);
   return MathIsValidNumber(number);
}

bool TryGetJsonULong(const string json, const string key, ulong &number)
{
   number = 0;
   string token = ""; bool is_string = false;
   if(!TryGetJsonValue(json, key, token, is_string)) return false;
   StringTrimLeft(token); StringTrimRight(token);
   int length = StringLen(token);
   if(length == 0) return false;
   for(int i = 0; i < length; i++)
   {
      ushort character = StringGetCharacter(token, i);
      if(character < 48 || character > 57) return false;
      ulong digit = (ulong)(character - 48);
      ulong next_number = number * 10 + digit;
      if(next_number < number) return false;
      number = next_number;
   }
   return true;
}

bool FindNextJsonObject(const string json, const int search_start, int &object_start, int &object_end)
{
   object_start = -1; object_end = -1;
   int length = StringLen(json), depth = 0;
   bool inside_string = false, escaped_character = false;
   for(int i = search_start; i < length; i++)
   {
      ushort character = StringGetCharacter(json, i);
      if(inside_string)
      {
         if(escaped_character) escaped_character = false;
         else if(character == 92) escaped_character = true;
         else if(character == 34) inside_string = false;
         continue;
      }
      if(character == 34) { inside_string = true; continue; }
      if(character == 123)
      {
         if(depth == 0) object_start = i;
         depth++;
      }
      else if(character == 125 && depth > 0)
      {
         depth--;
         if(depth == 0) { object_end = i; return true; }
      }
   }
   return false;
}

bool NormalizeWebhookSymbol(const string requested_symbol, string &execution_symbol)
{
   execution_symbol = "";
   if(requested_symbol == Symbol()) { execution_symbol = Symbol(); return true; }
   bool local_is_gold = StringFind(Symbol(), "XAUUSD") == 0 || StringFind(Symbol(), "GOLD") == 0;
   if(requested_symbol == "XAUUSD" && local_is_gold)
   {
      execution_symbol = Symbol();
      return true;
   }
   return false;
}

bool IsWebhookActionConsistent(const string status, const string action)
{
   if(status == "PENDING_BUY") return action == "BUY" || action == "PENDING_BUY";
   if(status == "PENDING_SELL") return action == "SELL" || action == "PENDING_SELL";
   if(status == "PENDING_CLOSE") return action == "CLOSE" || action == "PENDING_CLOSE";
   return false;
}

void ProcessSignals(string ja)
{
   int position = 0, object_start = -1, object_end = -1;
   while(FindNextJsonObject(ja, position, object_start, object_end))
   {
      string object_json = StringSubstr(ja, object_start, object_end - object_start + 1);
      position = object_end + 1;

      string id = "", action = "", status = "", requested_symbol = "";
      bool string_value = false;
      bool schema_ok = TryGetJsonValue(object_json, "id", id, string_value) && string_value
                       && TryGetJsonValue(object_json, "action", action, string_value) && string_value
                       && TryGetJsonValue(object_json, "status", status, string_value) && string_value
                       && TryGetJsonValue(object_json, "symbol", requested_symbol, string_value) && string_value;
      StringTrimLeft(id); StringTrimRight(id);
      StringTrimLeft(action); StringTrimRight(action); StringToUpper(action);
      StringTrimLeft(status); StringTrimRight(status); StringToUpper(status);
      StringTrimLeft(requested_symbol); StringTrimRight(requested_symbol);

      string execution_symbol = "";
      if(!schema_ok || id == "" || !IsWebhookActionConsistent(status, action)
         || !NormalizeWebhookSymbol(requested_symbol, execution_symbol))
      {
         Print("ATS EA WEBHOOK REJECT: Invalid signal schema/action/symbol id=", id);
         continue;
      }

      if(status == "PENDING_BUY" || status == "PENDING_SELL")
      {
         double lot = 0.0, sl = 0.0, tp = 0.0;
         bool lot_ok = TryGetJsonDouble(object_json, "volume", lot) && lot > 0.0;
         bool sl_present = TryGetJsonDouble(object_json, "sl", sl);
         bool tp_present = TryGetJsonDouble(object_json, "tp", tp);
         if(!lot_ok || (sl_present && sl < 0.0) || (tp_present && tp < 0.0))
         {
            Print("ATS EA WEBHOOK REJECT: Invalid numeric fields id=", id);
            continue;
         }
         if(status == "PENDING_BUY") ExecuteBuy(id, execution_symbol, lot, sl_present ? sl : 0.0, tp_present ? tp : 0.0);
         else ExecuteSell(id, execution_symbol, lot, sl_present ? sl : 0.0, tp_present ? tp : 0.0);
      }
      else
      {
         ulong ticket = 0;
         string unused_ticket = ""; bool unused_is_string = false;
         if(TryGetJsonValue(object_json, "ticket", unused_ticket, unused_is_string)
            && !TryGetJsonULong(object_json, "ticket", ticket))
         {
            Print("ATS EA WEBHOOK REJECT: Invalid close ticket id=", id);
            continue;
         }
         ExecuteClose(id, execution_symbol, ticket);
      }
   }
}

void ExecuteBuy(string id,string sym,double lot,double sl,double tp)
{
   ulong existing_ticket = 0;
   double existing_price = 0.0;
   ENUM_SIGNAL_CLAIM_RESULT claim = TryClaimSignal(id, existing_ticket, existing_price);
   if(claim == SIGNAL_CLAIM_COMPLETED_OPEN)
   {
      Print("ATS EA: Replaying OPEN status for duplicate BUY signal id=", id);
      UpdateSignalStatus(id,"OPEN",existing_ticket,existing_price,0.0,0.0);
      return;
   }
   if(claim == SIGNAL_CLAIM_COMPLETED_FAILED)
   {
      UpdateSignalStatus(id,"FAILED",0,0.0,0.0,0.0);
      return;
   }
   if(claim != SIGNAL_CLAIM_ACQUIRED)
      return;

   int today_loss_count = 0;
   if(IsDailyLossBlocked(sym, today_loss_count))
   {
      Print("ATS EA: Webhook BUY blocked by Daily Loss Guard (", today_loss_count,
            "/", InpMaxDailyLossCount, " losing positions)");
      CompleteSignalClaim(id,false,0,0.0);
      UpdateSignalStatus(id,"FAILED",0,0.0,0.0,0.0);
      return;
   }

   int cooldown_remaining = 0;
   if(IsLossCooldownActive(sym, cooldown_remaining))
   {
      Print("ATS EA: Webhook BUY blocked by Loss Cooldown (", cooldown_remaining, " minutes remaining)");
      CompleteSignalClaim(id,false,0,0.0);
      UpdateSignalStatus(id,"FAILED",0,0.0,0.0,0.0);
      return;
   }

   MqlTick tk;
   if(!SymbolInfoTick(sym,tk))
   {
      CompleteSignalClaim(id,false,0,0.0);
      UpdateSignalStatus(id,"FAILED",0,0.0,0.0,0.0);
      return;
   }
   if(!PrepareMarketStops(sym, true, tk, sl, tp))
   {
      CompleteSignalClaim(id,false,0,0.0);
      UpdateSignalStatus(id,"FAILED",0,0.0,0.0,0.0);
      return;
   }
   double normalized_lot = 0.0;
   if(!PrepareWebhookVolume(sym, true, tk, sl, lot, normalized_lot))
   {
      CompleteSignalClaim(id,false,0,0.0);
      UpdateSignalStatus(id,"FAILED",0,0.0,0.0,0.0);
      return;
   }

   ResetLastError();
   bool buy_request_ok = trade.Buy(normalized_lot,sym,tk.ask,sl,tp,"ATS BUY "+id);
   if(IsTradeResultSuccessful(buy_request_ok, "Webhook BUY"))
   {
      ulong t=trade.ResultOrder(); if(!t) t=trade.ResultDeal();
      double fp=trade.ResultPrice(); if(fp<=0) fp=tk.ask;
      CompleteSignalClaim(id,true,t,fp);
      UpdateSignalStatus(id,"OPEN",t,fp,0.0,0.0);
   }
   else
   {
      CompleteSignalClaim(id,false,0,0.0);
      UpdateSignalStatus(id,"FAILED",0,0.0,0.0,0.0);
   }
}

void ExecuteSell(string id,string sym,double lot,double sl,double tp)
{
   ulong existing_ticket = 0;
   double existing_price = 0.0;
   ENUM_SIGNAL_CLAIM_RESULT claim = TryClaimSignal(id, existing_ticket, existing_price);
   if(claim == SIGNAL_CLAIM_COMPLETED_OPEN)
   {
      Print("ATS EA: Replaying OPEN status for duplicate SELL signal id=", id);
      UpdateSignalStatus(id,"OPEN",existing_ticket,existing_price,0.0,0.0);
      return;
   }
   if(claim == SIGNAL_CLAIM_COMPLETED_FAILED)
   {
      UpdateSignalStatus(id,"FAILED",0,0.0,0.0,0.0);
      return;
   }
   if(claim != SIGNAL_CLAIM_ACQUIRED)
      return;

   int today_loss_count = 0;
   if(IsDailyLossBlocked(sym, today_loss_count))
   {
      Print("ATS EA: Webhook SELL blocked by Daily Loss Guard (", today_loss_count,
            "/", InpMaxDailyLossCount, " losing positions)");
      CompleteSignalClaim(id,false,0,0.0);
      UpdateSignalStatus(id,"FAILED",0,0.0,0.0,0.0);
      return;
   }

   int cooldown_remaining = 0;
   if(IsLossCooldownActive(sym, cooldown_remaining))
   {
      Print("ATS EA: Webhook SELL blocked by Loss Cooldown (", cooldown_remaining, " minutes remaining)");
      CompleteSignalClaim(id,false,0,0.0);
      UpdateSignalStatus(id,"FAILED",0,0.0,0.0,0.0);
      return;
   }

   MqlTick tk;
   if(!SymbolInfoTick(sym,tk))
   {
      CompleteSignalClaim(id,false,0,0.0);
      UpdateSignalStatus(id,"FAILED",0,0.0,0.0,0.0);
      return;
   }
   if(!PrepareMarketStops(sym, false, tk, sl, tp))
   {
      CompleteSignalClaim(id,false,0,0.0);
      UpdateSignalStatus(id,"FAILED",0,0.0,0.0,0.0);
      return;
   }
   double normalized_lot = 0.0;
   if(!PrepareWebhookVolume(sym, false, tk, sl, lot, normalized_lot))
   {
      CompleteSignalClaim(id,false,0,0.0);
      UpdateSignalStatus(id,"FAILED",0,0.0,0.0,0.0);
      return;
   }

   ResetLastError();
   bool sell_request_ok = trade.Sell(normalized_lot,sym,tk.bid,sl,tp,"ATS SELL "+id);
   if(IsTradeResultSuccessful(sell_request_ok, "Webhook SELL"))
   {
      ulong t=trade.ResultOrder(); if(!t) t=trade.ResultDeal();
      double fp=trade.ResultPrice(); if(fp<=0) fp=tk.bid;
      CompleteSignalClaim(id,true,t,fp);
      UpdateSignalStatus(id,"OPEN",t,fp,0.0,0.0);
   }
   else
   {
      CompleteSignalClaim(id,false,0,0.0);
      UpdateSignalStatus(id,"FAILED",0,0.0,0.0,0.0);
   }
}

bool TryResolveOwnedClosePosition(const string sym,const ulong requested_ticket,
                                  ulong &resolved_ticket,ulong &position_identifier,
                                  string &reject_reason)
{
   resolved_ticket=0;
   position_identifier=0;
   reject_reason="";

   if(requested_ticket>0)
   {
      if(!PositionSelectByTicket(requested_ticket))
      {
         reject_reason="POSITION_NOT_FOUND";
         return false;
      }
      if(PositionGetString(POSITION_SYMBOL)!=sym)
      {
         reject_reason="SYMBOL_MISMATCH";
         return false;
      }
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic)
      {
         reject_reason="MAGIC_MISMATCH";
         return false;
      }

      resolved_ticket=requested_ticket;
      position_identifier=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
      return true;
   }

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong candidate_ticket=PositionGetTicket(i);
      if(candidate_ticket==0 || !PositionSelectByTicket(candidate_ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=sym
         || PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;

      if(resolved_ticket>0)
      {
         resolved_ticket=0;
         position_identifier=0;
         reject_reason="AMBIGUOUS_OWNED_POSITIONS";
         return false;
      }

      resolved_ticket=candidate_ticket;
      position_identifier=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
   }

   if(resolved_ticket==0)
   {
      reject_reason="POSITION_NOT_FOUND";
      return false;
   }
   return true;
}

void ExecuteClose(string id,string sym,ulong ticket)
{
   ulong owned_ticket=0;
   ulong position_identifier=0;
   string reject_reason="";
   if(!TryResolveOwnedClosePosition(sym,ticket,owned_ticket,position_identifier,reject_reason))
   {
      Print("ATS EA WEBHOOK REJECT: CLOSE ownership check failed id=",id,
            " symbol=",sym," requested_ticket=",ticket," reason=",reject_reason);
      string rejected_status=(reject_reason=="POSITION_NOT_FOUND" ? "CLOSED_NOT_FOUND" : "CLOSE_FAILED");
      UpdateSignalStatus(id,rejected_status,ticket,0.0,0.0,0.0);
      return;
   }

   ulong revalidated_ticket=0;
   ulong revalidated_identifier=0;
   string revalidation_reason="";
   if(!TryResolveOwnedClosePosition(sym,owned_ticket,revalidated_ticket,
                                    revalidated_identifier,revalidation_reason))
   {
      Print("ATS EA WEBHOOK REJECT: CLOSE ownership changed before submission id=",id,
            " symbol=",sym," ticket=",owned_ticket," reason=",revalidation_reason);
      UpdateSignalStatus(id,"CLOSE_FAILED",owned_ticket,0.0,0.0,0.0);
      return;
   }
   owned_ticket=revalidated_ticket;
   position_identifier=revalidated_identifier;

   ResetLastError();
   bool close_request_ok = trade.PositionClose(owned_ticket);
   if(IsTradeResultSuccessful(close_request_ok, "Webhook CLOSE", owned_ticket))
   {
      double pf=0.0, history_exit_price=0.0;
      ENUM_DEAL_REASON unused_deal_reason = DEAL_REASON_CLIENT;
      bool exit_history_found = GetClosedPositionResult(position_identifier, history_exit_price, pf, unused_deal_reason);
      string close_status = !exit_history_found ? "CLOSED_UNRESOLVED" : (pf>=0?"WIN":"LOSS");
      double reported_exit_price = history_exit_price > 0.0 ? history_exit_price : trade.ResultPrice();
      UpdateSignalStatus(id,close_status,owned_ticket,0.0,reported_exit_price,pf);
   } else UpdateSignalStatus(id,"CLOSE_FAILED",0,0.0,0.0,0.0);
}

void UpdateSignalStatus(string id,string status,ulong ticket,double ep,double xp,double pf)
{
   string url=backend_url+"/api/signals/update", hdr="Content-Type: application/json\r\nX-Api-Key: " + auth_token + "\r\n";
   string pay=StringFormat("{\"token\":\"%s\",\"account_id\":%d,\"ea_id\":%d,\"id\":\"%s\",\"status\":\"%s\",\"ticket\":\"%s\","
                           "\"entry_price\":%s,\"exit_price\":%s,\"profit\":%s}",
      auth_token,InpBackendAccountId,InpBackendEaId,id,status,IntegerToString(ticket),
      DoubleToString(ep,2),DoubleToString(xp,2),DoubleToString(pf,2));
   char pd[],rd[]; string rh;
   StringToCharArray(pay,pd,0,StringLen(pay),CP_UTF8);
   ResetLastError();
   int h=WebRequest("POST",url,hdr,3000,pd,rd,rh);
   if(h==200) Print("ATS EA: Status updated -> ",status);
   else Print("ATS EA ERROR: Status update HTTP=",h," err=",GetLastError());
}
//+------------------------------------------------------------------+
