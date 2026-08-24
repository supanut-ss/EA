//+------------------------------------------------------------------+
//|                                          EaIngestClient.mqh      |
//|  Shared backend integration for EA Console (Backend/EaConsole.Api |
//|  Controllers/IngestController.cs, route api/ingest). Included by  |
//|  both XAUUSD_TrendBreakout_EA.mq5 and XAUUSD_Scalping_EA.mq5.      |
//|                                                                    |
//|  Wire-up required in the including .mq5 (see either EA for the   |
//|  exact calls):                                                    |
//|    OnInit()             -> EventSetTimer(InpIngestHeartbeatSec);  |
//|                             IngestSetEaStatus("active");          |
//|    OnDeinit()            -> EventKillTimer();                     |
//|                             IngestSetEaStatus("standby");         |
//|    OnTimer()             -> IngestSendHeartbeat(symbolName);      |
//|                             IngestSyncOpenPositions(...);         |
//|    OnTradeTransaction()  -> IngestHandleTradeTransaction(trans,   |
//|                             InpMagicNumber, symbolName);          |
//|                                                                    |
//|  IMPORTANT: `InpIngestEnabled` defaults to false for any EA that   |
//|  doesn't opt in (see INGEST_DEFAULT_ENABLED below) - everything    |
//|  in this file is a no-op until it's on. EA1/EA2 default it to      |
//|  true (2026-08-21+) since a fresh attach should just work, but     |
//|  WebRequest is never meant for Strategy Tester/optimization (it    |
//|  would hit the real server from every parallel tester agent on    |
//|  every heartbeat/trade - slow, non-deterministic, and pointless    |
//|  for historical data) - so IngestEnabled() below forces this off   |
//|  whenever MQLInfoInteger(MQL_TESTER) is true, regardless of what   |
//|  the input says. No manual untick-before-backtest step needed.    |
//|                                                                    |
//|  MT5 blocks all WebRequest calls by default. Before enabling this |
//|  in live/demo trading, add the backend host in MT5:               |
//|    Tools > Options > Expert Advisors > "Allow WebRequest for      |
//|    listed URL" -> add InpIngestBaseUrl exactly. Without this,     |
//|    every call below fails with WebRequest error 4060 (logged via  |
//|    Print(), never a silent failure).                              |
//+------------------------------------------------------------------+
#ifndef EA_INGEST_CLIENT_MQH
#define EA_INGEST_CLIENT_MQH

// Per-EA defaults: #include is textual, so a single default here applies
// to every EA that includes this file - wrong for InpIngestBaseUrl/EaId,
// which genuinely differ per EA/deployment. Each including .mq5 can
// #define these BEFORE #include <EaIngestClient.mqh> to override just its
// own default; anything not overridden falls back to the values below
// (which stay dev-safe: localhost + EaId 1, matching the original
// behavior for any EA that doesn't opt in).
#ifndef INGEST_DEFAULT_BASE_URL
   #define INGEST_DEFAULT_BASE_URL "http://localhost:5008"
#endif
#ifndef INGEST_DEFAULT_EA_ID
   #define INGEST_DEFAULT_EA_ID 1
#endif
// Real incident (2026-08-13 to 08-20): EA1/EA2/EA3 all defaulted to a 10s
// heartbeat/poll, and since MT5's EventSetTimer() starts counting from
// whenever each EA happens to be attached/recompiled, the three drifted
// into firing on the same tick often enough to burst the backend host's
// MariaDB past its (low, shared-host) max_user_connections - some of those
// requests got silently dropped with no retry. Two independent changes: (1)
// slower default (was 10s) since heartbeat freshness doesn't need to be
// that tight, and (2) a distinct, mutually-prime-ish default per EA so a
// repeat of the day-one coincidence can't recur - three synchronized clocks
// only re-align at their LCM, which for prime-ish seconds like these is
// effectively "never" in practice (see the per-EA #define overrides).
#ifndef INGEST_DEFAULT_HEARTBEAT_SEC
   #define INGEST_DEFAULT_HEARTBEAT_SEC 29
#endif
// Same override pattern for the enabled flag and API key - EA1/EA2 opt into
// non-secret production defaults via #define (2026-08-21+); anything that
// doesn't override stays OFF/blank, same dev-safe fallback as before (keep
// it that way for any future EA that includes this file without opting in -
// see the big warning above about WebRequest during Strategy Tester runs).
#ifndef INGEST_DEFAULT_ENABLED
   #define INGEST_DEFAULT_ENABLED false
#endif
#ifndef INGEST_DEFAULT_API_KEY
   #define INGEST_DEFAULT_API_KEY ""
#endif

input group "=== Backend Ingest (EA Console) ==="
input bool     InpIngestEnabled      = INGEST_DEFAULT_ENABLED;     // Enable sending data to backend (OFF by default - see notes above)
input string   InpIngestBaseUrl      = INGEST_DEFAULT_BASE_URL;    // Backend base URL, no trailing slash (see Backend/EaConsole.Api/Properties/launchSettings.json)
input int      InpIngestAccountId    = 1;                          // AccountId in the backend DB
input int      InpIngestEaId         = INGEST_DEFAULT_EA_ID;       // EaId in the backend DB (must differ per EA)
input int      InpIngestHeartbeatSec = INGEST_DEFAULT_HEARTBEAT_SEC; // Heartbeat interval, seconds (kept distinct per EA on purpose - see comment above)
input int      InpIngestTimeoutMs    = 5000;                       // WebRequest timeout, ms
input string   InpIngestApiKey       = INGEST_DEFAULT_API_KEY;     // X-Api-Key header (leave blank if backend's Ingest:ApiKey is unset)

//--- one open-trade record we remember between "opened" and "closed" events
struct IngestOpenTradeInfo
{
   ulong    ticket;
   string   side;
   double   lot;
   double   openPrice;
   double   sl;
   double   tp;
   double   slAmount;
   double   tpAmount;
   datetime openTime;
   bool     reportedOpen;
   // Cached from the real opening deal the first time it's known (MT5 has no
   // "commission so far" position property - only deals carry it, and this
   // account's model charges it once on entry) - reused on every later
   // refresh instead of re-querying history, and instead of sending 0 and
   // clobbering the real value back to zero (see IngestReportOpenPosition).
   double   commission;
};
IngestOpenTradeInfo g_ingestOpenTrades[];

//+------------------------------------------------------------------+
// Single source of truth for "should we actually send anything" - checks
// InpIngestEnabled AND forces off inside Strategy Tester/optimization
// regardless of that input's value. Needed now that EA1/EA2 default
// InpIngestEnabled=true (2026-08-21+): the old plain-input check relied on
// remembering to untick it by hand before every backtest/optimization run,
// and optimization spins up many parallel tester agents that would each
// hit the real production backend on every heartbeat/trade if that were
// ever forgotten (see the WebRequest-in-tester warning at the top of this
// file). MQL_TESTER is true for both a plain backtest and every
// optimization pass, so one check covers both.
bool IngestEnabled()
{
   return InpIngestEnabled && !(bool)MQLInfoInteger(MQL_TESTER);
}

//--- IngestSend() only ever Print()s on FAILURE - a fully-working EA and a
//    silently-misconfigured one (wrong AccountId/EaId, backend down, etc.)
//    look IDENTICAL in the Experts tab: total silence. This counter drives
//    a periodic "still alive" confirmation so success is visible too,
//    without spamming a line every single heartbeat (default 10s).
int g_ingestHeartbeatCount = 0;

//+------------------------------------------------------------------+
string IngestIsoTime(datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return StringFormat("%04d-%02d-%02dT%02d:%02d:%02d", dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec);
}

//+------------------------------------------------------------------+
string IngestJsonEscape(string s)
{
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   return s;
}

//+------------------------------------------------------------------+
// Real incident (2026-08-14): trades were executing fine (visible in
// History) but NEVER showed up as either "reported" or "returned HTTP"
// in the Experts log - meaning the ingest call was never even attempted.
// Root cause: HistoryDealSelect() was called immediately after
// trade.Buy()/Sell()/OnTradeTransaction() fired, but MT5's local history
// cache can lag the actual execution by a tick or two. A failed lookup
// silently skipped the whole reporting block with no error printed at
// all. Retry with a short pause instead of a single immediate attempt,
// and warn (loudly, once) if it still isn't there after that - a report
// that never fires needs to be visible, not silent.
//+------------------------------------------------------------------+
bool IngestHistoryDealSelectRetry(ulong dealTicket, int maxAttempts = 5, int delayMs = 100)
{
   for(int attempt = 1; attempt <= maxAttempts; attempt++)
   {
      HistorySelect(0, TimeCurrent()); // refresh the local history cache before each retry
      if(HistoryDealSelect(dealTicket)) return true;
      if(attempt < maxAttempts) Sleep(delayMs);
   }
   Print("Ingest: WARNING - deal #", dealTicket, " not found in history after ", maxAttempts,
         " attempts (", (maxAttempts * delayMs), "ms) - trade report SKIPPED for this event");
   return false;
}

//+------------------------------------------------------------------+
bool IngestSend(string method, string path, string jsonBody)
{
   if(!IngestEnabled()) return false;

   // Real incident (2026-08-14): InpIngestBaseUrl was set with a trailing
   // slash, producing a literal "//api/..." that this host's web server
   // rejects before the request even reaches the backend app - every
   // heartbeat/trade 404'd silently for as long as it went unnoticed.
   // XAUUSD_COUNTER_TREND.mq5 already strips this defensively at OnInit;
   // do the same here regardless of what the input actually contains.
   string baseUrl = InpIngestBaseUrl;
   while(StringLen(baseUrl) > 0 && StringSubstr(baseUrl, StringLen(baseUrl)-1, 1) == "/")
      baseUrl = StringSubstr(baseUrl, 0, StringLen(baseUrl)-1);
   string url = baseUrl + path;
   string headers = "Content-Type: application/json\r\n";
   if(InpIngestApiKey != "")
      headers += "X-Api-Key: " + InpIngestApiKey + "\r\n";
   char data[];
   StringToCharArray(jsonBody, data, 0, StringLen(jsonBody));
   char result[];
   string resultHeaders;

   ResetLastError();
   int status = WebRequest(method, url, headers, InpIngestTimeoutMs, data, result, resultHeaders);
   if(status == -1)
   {
      Print("Ingest ", method, " failed (", path, "): WebRequest error ", GetLastError(),
            " - check Tools>Options>Expert Advisors>Allow WebRequest for: ", InpIngestBaseUrl);
      return false;
   }
   if(status < 200 || status >= 300)
   {
      Print("Ingest ", method, " ", path, " returned HTTP ", status);
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
// Call once from the including EA's OnInit(), after InpIngestEnabled is
// known - this ONE line at startup would have caught the exact bug found
// in production (InpIngestAccountId pointing at a nonexistent account):
// the value actually being used is right there in the log immediately,
// instead of inferring it from silence.
//+------------------------------------------------------------------+
void IngestPrintStartupInfo()
{
   if(!InpIngestEnabled)
   {
      Print("Ingest: disabled (InpIngestEnabled=false) - nothing will be sent to backend");
      return;
   }
   if((bool)MQLInfoInteger(MQL_TESTER))
   {
      Print("Ingest: InpIngestEnabled=true but running in Strategy Tester/optimization - ",
            "forcing OFF regardless (never send test/optimization runs to the real backend)");
      return;
   }
   Print("Ingest: enabled -> ", InpIngestBaseUrl,
         " (AccountId=", InpIngestAccountId, ", EaId=", InpIngestEaId,
         ", heartbeat every ", InpIngestHeartbeatSec, "s)");
}

//+------------------------------------------------------------------+
void IngestSendHeartbeat(string symbol)
{
   if(!IngestEnabled()) return;

   double balance     = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity       = AccountInfoDouble(ACCOUNT_EQUITY);
   double margin       = AccountInfoDouble(ACCOUNT_MARGIN);
   double freeMargin   = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double marginLevel  = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   int    spread       = (int)SymbolInfoInteger(symbol, SYMBOL_SPREAD);

   string json = StringFormat(
      "{\"accountId\":%d,\"capturedAtBroker\":\"%s\",\"balance\":%.2f,\"equity\":%.2f,"
      "\"margin\":%.2f,\"freeMargin\":%.2f,\"marginLevelPct\":%.2f,\"spreadPoints\":%d,"
      "\"connectionState\":\"connected\"}",
      InpIngestAccountId, IngestIsoTime(TimeCurrent()), balance, equity,
      margin, freeMargin, marginLevel, spread);

   bool ok = IngestSend("POST", "/api/ingest/snapshot", json);
   if(ok)
   {
      g_ingestHeartbeatCount++;
      // First success right away, then roughly once every 10 minutes -
      // frequent enough to notice quickly if it silently stops, not so
      // frequent it buries real trade activity in the log.
      int printEvery = (InpIngestHeartbeatSec > 0) ? MathMax(1, 600 / InpIngestHeartbeatSec) : 60;
      if(g_ingestHeartbeatCount == 1 || g_ingestHeartbeatCount % printEvery == 0)
         Print("Ingest: heartbeat OK #", g_ingestHeartbeatCount,
               " (Balance=", DoubleToString(balance,2), " Equity=", DoubleToString(equity,2), ")");
   }
}

//+------------------------------------------------------------------+
void IngestTrackOpen(ulong ticket, string side, double lot, double openPrice,
                      double sl, double tp, double slAmount, double tpAmount, datetime openTime)
{
   int index = -1;
   bool reportedOpen = false;
   double commission = 0;
   for(int i = 0; i < ArraySize(g_ingestOpenTrades); i++)
   {
      if(g_ingestOpenTrades[i].ticket != ticket) continue;
      index = i;
      reportedOpen = g_ingestOpenTrades[i].reportedOpen;
      commission   = g_ingestOpenTrades[i].commission;
      break;
   }

   if(index < 0)
   {
      index = ArraySize(g_ingestOpenTrades);
      ArrayResize(g_ingestOpenTrades, index + 1);
   }

   g_ingestOpenTrades[index].ticket       = ticket;
   g_ingestOpenTrades[index].side         = side;
   g_ingestOpenTrades[index].lot          = lot;
   g_ingestOpenTrades[index].openPrice    = openPrice;
   g_ingestOpenTrades[index].sl           = sl;
   g_ingestOpenTrades[index].tp           = tp;
   g_ingestOpenTrades[index].slAmount     = slAmount;
   g_ingestOpenTrades[index].tpAmount     = tpAmount;
   g_ingestOpenTrades[index].openTime     = openTime;
   g_ingestOpenTrades[index].reportedOpen = reportedOpen;
   g_ingestOpenTrades[index].commission   = commission;
}

//+------------------------------------------------------------------+
bool IngestOpenWasReported(ulong ticket)
{
   for(int i = 0; i < ArraySize(g_ingestOpenTrades); i++)
      if(g_ingestOpenTrades[i].ticket == ticket)
         return g_ingestOpenTrades[i].reportedOpen;
   return false;
}

//+------------------------------------------------------------------+
void IngestMarkOpenReported(ulong ticket, double commission)
{
   for(int i = 0; i < ArraySize(g_ingestOpenTrades); i++)
   {
      if(g_ingestOpenTrades[i].ticket != ticket) continue;
      g_ingestOpenTrades[i].reportedOpen = true;
      g_ingestOpenTrades[i].commission   = commission;
      return;
   }
}

//+------------------------------------------------------------------+
double IngestGetCachedCommission(ulong ticket)
{
   for(int i = 0; i < ArraySize(g_ingestOpenTrades); i++)
      if(g_ingestOpenTrades[i].ticket == ticket)
         return g_ingestOpenTrades[i].commission;
   return 0;
}

//+------------------------------------------------------------------+
bool IngestPopOpen(ulong ticket, IngestOpenTradeInfo &outInfo)
{
   for(int i = 0; i < ArraySize(g_ingestOpenTrades); i++)
   {
      if(g_ingestOpenTrades[i].ticket == ticket)
      {
         outInfo = g_ingestOpenTrades[i];
         ArrayRemove(g_ingestOpenTrades, i, 1);
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
bool IngestTradeOpened(ulong ticket, string symbol, string side, double lot,
                        double openPrice, double sl, double tp,
                        double slAmount, double tpAmount, datetime openTime,
                        double currentPrice, double unrealizedPnl,
                        double swap, double commission)
{
   if(!IngestEnabled()) return false;

   // Real incident (2026-08-21): %d expects a 32-bit signed int, but ticket
   // is ulong (64-bit) and MT5 ticket numbers on this account have grown
   // past 2^31 (2.1B+) - %d silently wrapped every ticket into a negative
   // number, which the backend then rejected outright: MySqlException "Out
   // of range value for column 'mt5_ticket'" (an UNSIGNED column) on every
   // single OPEN/CLOSE report, both here and in IngestTradeClosed below.
   // %I64u is MQL5's unsigned-64-bit specifier (borrowed from Win32 printf).
   string json = StringFormat(
      "{\"accountId\":%d,\"eaId\":%d,\"mt5Ticket\":%I64u,\"symbol\":\"%s\",\"side\":\"%s\",\"lot\":%.2f,"
      "\"openPrice\":%.3f,\"closePrice\":null,\"stopLoss\":%.3f,\"takeProfit\":%.3f,"
      "\"currentPrice\":%.3f,\"unrealizedPnl\":%.2f,\"slAmount\":%.2f,\"tpAmount\":%.2f,"
      "\"openTimeBroker\":\"%s\",\"closeTimeBroker\":null,"
      "\"status\":\"OPEN\",\"pnl\":null,\"swap\":%.2f,\"commission\":%.2f,\"closeReason\":null}",
      InpIngestAccountId, InpIngestEaId, ticket, symbol, side, lot,
      openPrice, sl, tp, currentPrice, unrealizedPnl, slAmount, tpAmount,
      IngestIsoTime(openTime), swap, commission);

   if(IngestSend("POST", "/api/ingest/trade", json))
      return true;
   return false;
}

//+------------------------------------------------------------------+
void IngestTradeClosed(ulong ticket, string symbol, string side, double lot,
                        double openPrice, double closePrice, double sl, double tp,
                        double slAmount, double tpAmount,
                        datetime openTime, datetime closeTime,
                        double pnl, double swap, double commission, string closeReason)
{
   if(!IngestEnabled()) return;

   // See IngestTradeOpened's comment - same %d-on-ulong overflow bug fixed
   // here with %I64u.
   string json = StringFormat(
      "{\"accountId\":%d,\"eaId\":%d,\"mt5Ticket\":%I64u,\"symbol\":\"%s\",\"side\":\"%s\",\"lot\":%.2f,"
      "\"openPrice\":%.3f,\"closePrice\":%.3f,\"stopLoss\":%.3f,\"takeProfit\":%.3f,"
      "\"currentPrice\":%.3f,\"unrealizedPnl\":null,\"slAmount\":%.2f,\"tpAmount\":%.2f,"
      "\"openTimeBroker\":\"%s\",\"closeTimeBroker\":\"%s\","
      "\"status\":\"CLOSED\",\"pnl\":%.2f,\"swap\":%.2f,\"commission\":%.2f,\"closeReason\":\"%s\"}",
      InpIngestAccountId, InpIngestEaId, ticket, symbol, side, lot,
      openPrice, closePrice, sl, tp, closePrice, slAmount, tpAmount,
      IngestIsoTime(openTime), IngestIsoTime(closeTime),
      pnl, swap, commission, closeReason);

   if(IngestSend("POST", "/api/ingest/trade", json))
      Print("Ingest: trade #", ticket, " reported as CLOSED (pnl=", DoubleToString(pnl,2), ")");
}

//+------------------------------------------------------------------+
void IngestLog(int eaId, string level, string message)
{
   if(!IngestEnabled()) return;

   string json = StringFormat(
      "{\"accountId\":%d,\"eaId\":%d,\"level\":\"%s\",\"message\":\"%s\",\"eventTimeBroker\":\"%s\"}",
      InpIngestAccountId, eaId, level, IngestJsonEscape(message), IngestIsoTime(TimeCurrent()));

   IngestSend("POST", "/api/ingest/log", json);
}

//+------------------------------------------------------------------+
void IngestSetEaStatus(string state)
{
   if(!IngestEnabled()) return;

   string json = StringFormat("{\"state\":\"%s\"}", state);
   string path = StringFormat("/api/ingest/ea/%d/status", InpIngestEaId);
   IngestSend("PUT", path, json);
}

//+------------------------------------------------------------------+
// Fallback for when IngestPopOpen() finds nothing - e.g. the EA was
// recompiled/restarted while this position was still open, so
// g_ingestOpenTrades[] (in-memory only, never rebuilt from live state)
// lost the record; or the open-side ingest call simply never ran. Without
// this fallback IngestHandleTradeTransaction() used to silently `return`
// on a miss, which meant the close report - and the trade itself, as far
// as the backend/dashboard ever knew - was dropped forever with no log
// line anywhere. Real incident (2026-08-18): several XAUUSD_Scalping_EA
// trades confirmed closed in the MT5 terminal history never appeared in
// the dashboard's Trade History at all.
//
// Rebuilds enough of the open side from MT5's own deal history (which the
// terminal always retains, unlike our in-memory array) to still report
// the close. SL/TP/slAmount/tpAmount are NOT stored on deals in MT5, so
// they come back as 0 ("unset") only in this fallback path - still far
// better than dropping the closed trade entirely.
//+------------------------------------------------------------------+
bool IngestReconstructOpenInfo(ulong positionId, IngestOpenTradeInfo &outInfo, ulong &outOpenMagic)
{
   if(!HistorySelectByPosition(positionId)) return false;

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;

      ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
      outInfo.ticket    = positionId;
      outInfo.side      = (dealType == DEAL_TYPE_BUY) ? "BUY" : "SELL";
      outInfo.lot       = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
      outInfo.openPrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
      outInfo.sl        = 0;
      outInfo.tp        = 0;
      outInfo.slAmount  = 0;
      outInfo.tpAmount  = 0;
      outInfo.openTime  = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
      outInfo.reportedOpen = false;
      outOpenMagic      = (ulong)HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool IngestSelectPositionByIdentifier(ulong positionId, ulong magicNumber, string symbol)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong positionTicket = PositionGetTicket(i); // also selects the position
      if(positionTicket == 0) continue;
      if((ulong)PositionGetInteger(POSITION_IDENTIFIER) != positionId) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool IngestBuildOpenInfoFromPosition(ulong positionId, ulong magicNumber, string symbol,
                                     IngestOpenTradeInfo &outInfo, double &currentPrice, double &unrealizedPnl, double &swap)
{
   if(!IngestSelectPositionByIdentifier(positionId, magicNumber, symbol)) return false;

   ENUM_POSITION_TYPE positionType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   ENUM_ORDER_TYPE orderType = (positionType == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   outInfo.ticket       = positionId;
   outInfo.side         = (positionType == POSITION_TYPE_BUY) ? "BUY" : "SELL";
   outInfo.lot          = PositionGetDouble(POSITION_VOLUME);
   outInfo.openPrice    = PositionGetDouble(POSITION_PRICE_OPEN);
   outInfo.sl           = PositionGetDouble(POSITION_SL);
   outInfo.tp           = PositionGetDouble(POSITION_TP);
   outInfo.slAmount     = 0;
   outInfo.tpAmount     = 0;
   outInfo.openTime     = (datetime)PositionGetInteger(POSITION_TIME);
   outInfo.reportedOpen = IngestOpenWasReported(positionId);
   currentPrice         = PositionGetDouble(POSITION_PRICE_CURRENT);
   unrealizedPnl        = PositionGetDouble(POSITION_PROFIT);
   swap                 = PositionGetDouble(POSITION_SWAP);

   if(outInfo.sl > 0 &&
      !OrderCalcProfit(orderType, symbol, outInfo.lot, outInfo.openPrice, outInfo.sl, outInfo.slAmount))
      outInfo.slAmount = 0;
   if(outInfo.tp > 0 &&
      !OrderCalcProfit(orderType, symbol, outInfo.lot, outInfo.openPrice, outInfo.tp, outInfo.tpAmount))
      outInfo.tpAmount = 0;
   return true;
}

//+------------------------------------------------------------------+
// Report (first time) or refresh (every call after) an MT5-confirmed live
// position. Driven by TRADE_TRANSACTION_DEAL_ADD for the fast/accurate path
// AND by the timer reconciliation every heartbeat - deliberately does NOT
// skip once already reported (2026-08-21+: the earlier version did, which
// meant a position's currentPrice/unrealizedPnl on the dashboard froze at
// whatever they were at the very first report and never moved again for the
// rest of the trade's life, even though the report itself was cheap and the
// backend upserts by ticket anyway). commission is the one field MT5 can't
// re-derive live from an open position (only deals carry it, not positions) -
// cache it from the real opening deal the first time it's known and reuse it
// on every later refresh instead of re-sending 0 and clobbering the real
// value back to zero.
bool IngestReportOpenPosition(ulong positionId, ulong magicNumber, string symbol, ulong openingDealTicket = 0)
{
   bool firstReport = !IngestOpenWasReported(positionId);

   IngestOpenTradeInfo info;
   double currentPrice = 0, unrealizedPnl = 0, swap = 0;
   if(!IngestBuildOpenInfoFromPosition(positionId, magicNumber, symbol, info, currentPrice, unrealizedPnl, swap))
   {
      if(firstReport)
      {
         // Position already closed by the time we got here, or history/live
         // state briefly unavailable - only worth the reconstruction fallback
         // (0/unset SL/TP) for a first report; a refresh with nothing new to
         // say can just wait for the next heartbeat. The reconstructed magic
         // isn't needed here - ownership was already established by the
         // magicNumber/symbol filter in IngestSelectPositionByIdentifier
         // before this fallback is ever reached.
         ulong unusedMagic = 0;
         if(!IngestReconstructOpenInfo(positionId, info, unusedMagic))
         {
            Print("Ingest: WARNING - position #", positionId,
                  " opened but live position/history details are unavailable - OPEN report deferred to timer");
            return false;
         }
         currentPrice = info.openPrice;
         unrealizedPnl = 0;
         swap = 0;
      }
      else return false;
   }

   IngestTrackOpen(info.ticket, info.side, info.lot, info.openPrice, info.sl, info.tp,
                   info.slAmount, info.tpAmount, info.openTime);

   double commission = IngestGetCachedCommission(positionId);
   if(openingDealTicket != 0 && HistoryDealSelect(openingDealTicket))
      commission = HistoryDealGetDouble(openingDealTicket, DEAL_COMMISSION);

   if(!IngestTradeOpened(info.ticket, symbol, info.side, info.lot, info.openPrice,
                         info.sl, info.tp, info.slAmount, info.tpAmount, info.openTime,
                         currentPrice, unrealizedPnl, swap, commission))
      return false;

   if(firstReport) Print("Ingest: trade #", positionId, " reported as OPEN");
   IngestMarkOpenReported(positionId, commission);
   return true;
}

//+------------------------------------------------------------------+
// Refreshes currentPrice/unrealizedPnl/SL/TP for every currently-open
// position of this EA on every heartbeat tick (see IngestReportOpenPosition's
// comment), and self-heals a missed OPEN report or a republish after an
// EA/terminal restart in the same pass.
void IngestSyncOpenPositions(ulong magicNumber, string symbol)
{
   if(!IngestEnabled()) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong positionTicket = PositionGetTicket(i); // also selects the position
      if(positionTicket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;

      ulong positionId = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      IngestReportOpenPosition(positionId, magicNumber, symbol);
   }
}

//+------------------------------------------------------------------+
// Call from the including EA's OnTradeTransaction(). OPEN is reported from
// MT5's confirmed entry deal (via IngestReportOpenPosition); CLOSE is
// matched back to the tracked position by position id, so it only needs
// one history lookup (the closing deal itself), not a second scan for the
// original opening deal. Falls back to IngestReconstructOpenInfo() when
// there's no in-memory record (see that function's comment). The timer
// reconciliation (IngestSyncOpenPositions) above is the retry path for an
// OPEN request that failed or for a transaction event missed during
// restart.
//
// Real incident (2026-08-24): positions closed manually from the MT5
// terminal (or mobile/web) stayed "OPEN" forever on the dashboard even
// though they were flat in the terminal. Root cause: this used to reject
// the transaction up front if the CLOSING deal's magic number didn't
// match InpMagicNumber - but MT5 stamps a manually-closed position's
// closing deal with magic 0 (it's placed by the client/terminal, not the
// EA), regardless of what magic the position was opened with. So every
// manual close was silently dropped before it ever reached IngestPopOpen()
// below, which is the check that actually proves the position is ours.
// Fix: don't gate on the closing deal's magic at all - a position found
// in our own in-memory open-trade list is provably ours no matter who
// closed it. The magic check now only runs as a fallback, against the
// OPENING deal (which is reliably stamped by whoever opened the
// position), to avoid misattributing another same-symbol EA's position
// when reconstructing from history for an untracked ticket.
//+------------------------------------------------------------------+
void IngestHandleTradeTransaction(const MqlTradeTransaction &trans, ulong magicNumber, string symbol)
{
   if(!IngestEnabled()) return;
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   ulong dealTicket = trans.deal;
   if(!IngestHistoryDealSelectRetry(dealTicket)) return;
   if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != symbol) return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   ulong positionId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);

   if(entry == DEAL_ENTRY_IN)
   {
      IngestReportOpenPosition(positionId, magicNumber, symbol, dealTicket);
      return;
   }

   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) return;

   IngestOpenTradeInfo info;
   if(!IngestPopOpen(positionId, info))
   {
      ulong openMagic = 0;
      if(!IngestReconstructOpenInfo(positionId, info, openMagic))
      {
         Print("Ingest: WARNING - position #", positionId, " closed but no open record found (not tracked, and not in deal history either) - close NOT reported");
         return;
      }
      if(openMagic != magicNumber) return; // opened by a different EA/magic on this symbol - not ours, nothing to report
      Print("Ingest: position #", positionId, " had no in-memory open record (EA restarted mid-trade, or closed manually) - reconstructed from deal history to report the close (SL/TP will show as 0/unset)");
   }

   double closePrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
   double profit      = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
   double swap         = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
   double commission   = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
   datetime closeTime  = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
   ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(dealTicket, DEAL_REASON);

   string closeReason = "OTHER";
   if(reason == DEAL_REASON_SL) closeReason = "SL";
   else if(reason == DEAL_REASON_TP) closeReason = "TP";
   else if(reason == DEAL_REASON_EXPERT) closeReason = "EA_LOGIC";
   else if(reason == DEAL_REASON_CLIENT || reason == DEAL_REASON_MOBILE || reason == DEAL_REASON_WEB) closeReason = "MANUAL";

   IngestTradeClosed(positionId, symbol, info.side, info.lot,
                      info.openPrice, closePrice, info.sl, info.tp,
                      info.slAmount, info.tpAmount, info.openTime, closeTime,
                      profit, swap, commission, closeReason);
}

#endif
