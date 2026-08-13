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
//|    OnTradeTransaction()  -> IngestHandleTradeTransaction(trans,   |
//|                             InpMagicNumber, symbolName);          |
//|    OpenTrade(), right after a successful trade.Buy()/Sell()  ->   |
//|                             IngestTrackOpen(...) + IngestTradeOpened(...) |
//|                                                                    |
//|  IMPORTANT: `InpIngestEnabled` defaults to false - everything in  |
//|  this file is a no-op until the user turns it on. Keep it OFF     |
//|  during Strategy Tester backtests/optimization (WebRequest is not |
//|  meant for that - it would hit a real server from every one of    |
//|  the parallel tester agents on every heartbeat/trade, which is    |
//|  slow, non-deterministic, and pointless for historical data).     |
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

input group "=== Backend Ingest (EA Console) ==="
input bool     InpIngestEnabled      = false;                      // Enable sending data to backend (OFF by default - see notes above)
input string   InpIngestBaseUrl      = "http://localhost:5008";    // Backend base URL, no trailing slash (see Backend/EaConsole.Api/Properties/launchSettings.json)
input int      InpIngestAccountId    = 1;                          // AccountId in the backend DB
input int      InpIngestEaId         = 1;                          // EaId in the backend DB (must differ per EA)
input int      InpIngestHeartbeatSec = 10;                         // Heartbeat interval, seconds
input int      InpIngestTimeoutMs    = 5000;                       // WebRequest timeout, ms
input string   InpIngestApiKey       = "";                         // X-Api-Key header (leave blank if backend's Ingest:ApiKey is unset)

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
};
IngestOpenTradeInfo g_ingestOpenTrades[];

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
bool IngestSend(string method, string path, string jsonBody)
{
   if(!InpIngestEnabled) return false;

   string url = InpIngestBaseUrl + path;
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
   Print("Ingest: enabled -> ", InpIngestBaseUrl,
         " (AccountId=", InpIngestAccountId, ", EaId=", InpIngestEaId,
         ", heartbeat every ", InpIngestHeartbeatSec, "s)");
}

//+------------------------------------------------------------------+
void IngestSendHeartbeat(string symbol)
{
   if(!InpIngestEnabled) return;

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
   int n = ArraySize(g_ingestOpenTrades);
   ArrayResize(g_ingestOpenTrades, n + 1);
   g_ingestOpenTrades[n].ticket    = ticket;
   g_ingestOpenTrades[n].side      = side;
   g_ingestOpenTrades[n].lot       = lot;
   g_ingestOpenTrades[n].openPrice = openPrice;
   g_ingestOpenTrades[n].sl        = sl;
   g_ingestOpenTrades[n].tp        = tp;
   g_ingestOpenTrades[n].slAmount  = slAmount;
   g_ingestOpenTrades[n].tpAmount  = tpAmount;
   g_ingestOpenTrades[n].openTime  = openTime;
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
void IngestTradeOpened(ulong ticket, string symbol, string side, double lot,
                        double openPrice, double sl, double tp,
                        double slAmount, double tpAmount, datetime openTime,
                        double swap, double commission)
{
   if(!InpIngestEnabled) return;

   string json = StringFormat(
      "{\"accountId\":%d,\"eaId\":%d,\"mt5Ticket\":%d,\"symbol\":\"%s\",\"side\":\"%s\",\"lot\":%.2f,"
      "\"openPrice\":%.3f,\"closePrice\":null,\"stopLoss\":%.3f,\"takeProfit\":%.3f,"
      "\"currentPrice\":%.3f,\"unrealizedPnl\":0,\"slAmount\":%.2f,\"tpAmount\":%.2f,"
      "\"openTimeBroker\":\"%s\",\"closeTimeBroker\":null,"
      "\"status\":\"OPEN\",\"pnl\":null,\"swap\":%.2f,\"commission\":%.2f,\"closeReason\":null}",
      InpIngestAccountId, InpIngestEaId, ticket, symbol, side, lot,
      openPrice, sl, tp, openPrice, slAmount, tpAmount, IngestIsoTime(openTime), swap, commission);

   if(IngestSend("POST", "/api/ingest/trade", json))
      Print("Ingest: trade #", ticket, " reported as OPEN");
}

//+------------------------------------------------------------------+
void IngestTradeClosed(ulong ticket, string symbol, string side, double lot,
                        double openPrice, double closePrice, double sl, double tp,
                        double slAmount, double tpAmount,
                        datetime openTime, datetime closeTime,
                        double pnl, double swap, double commission, string closeReason)
{
   if(!InpIngestEnabled) return;

   string json = StringFormat(
      "{\"accountId\":%d,\"eaId\":%d,\"mt5Ticket\":%d,\"symbol\":\"%s\",\"side\":\"%s\",\"lot\":%.2f,"
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
   if(!InpIngestEnabled) return;

   string json = StringFormat(
      "{\"accountId\":%d,\"eaId\":%d,\"level\":\"%s\",\"message\":\"%s\",\"eventTimeBroker\":\"%s\"}",
      InpIngestAccountId, eaId, level, IngestJsonEscape(message), IngestIsoTime(TimeCurrent()));

   IngestSend("POST", "/api/ingest/log", json);
}

//+------------------------------------------------------------------+
void IngestSetEaStatus(string state)
{
   if(!InpIngestEnabled) return;

   string json = StringFormat("{\"state\":\"%s\"}", state);
   string path = StringFormat("/api/ingest/ea/%d/status", InpIngestEaId);
   IngestSend("PUT", path, json);
}

//+------------------------------------------------------------------+
// Call from the including EA's OnTradeTransaction(). Detects the CLOSE
// side only (opens are sent directly from OpenTrade(), which already
// has all the fields on hand) - matches the closed deal back to the
// IngestTrackOpen() record by position id, so this only needs one
// history lookup (the closing deal itself), not a second scan for the
// original opening deal.
//+------------------------------------------------------------------+
void IngestHandleTradeTransaction(const MqlTradeTransaction &trans, ulong magicNumber, string symbol)
{
   if(!InpIngestEnabled) return;
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   ulong dealTicket = trans.deal;
   if(!HistoryDealSelect(dealTicket)) return;
   if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != symbol) return;
   if((ulong)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != magicNumber) return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) return;

   ulong positionId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);

   IngestOpenTradeInfo info;
   if(!IngestPopOpen(positionId, info)) return; // not one of our tracked trades

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
