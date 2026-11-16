//+------------------------------------------------------------------+
//| SyncXauHistory.mq5 - force the terminal to download XAUUSD M1    |
//| history from the broker server (run once, then close terminal).  |
//+------------------------------------------------------------------+
#property script_show_inputs
input int InpFromYear = 2016;

void OnStart()
{
   string sym = "XAUUSD";
   SymbolSelect(sym, true);
   int h = FileOpen("sync_history_result.txt", FILE_WRITE | FILE_TXT | FILE_ANSI);
   // Walk month by month so each request stays small; newest first so older data chains downward
   MqlDateTime now; TimeToStruct(TimeCurrent(), now);
   for(int y = now.year; y >= InpFromYear; y--)
   {
      for(int m = (y == now.year ? now.mon : 12); m >= 1; m--)
      {
         datetime from = StringToTime(StringFormat("%d.%02d.01", y, m));
         datetime to   = (m == 12) ? StringToTime(StringFormat("%d.01.01", y + 1)) : StringToTime(StringFormat("%d.%02d.01", y, m + 1));
         int got = -1, err = 0;
         for(int attempt = 0; attempt < 12; attempt++)
         {
            MqlRates r[];
            ResetLastError();
            got = CopyRates(sym, PERIOD_M1, from, to - 60, r);
            err = GetLastError();
            if(got > 1000) break;
            Sleep(1000);
         }
         string line = StringFormat("%d.%02d bars=%d err=%d", y, m, got, err);
         Print(line);
         if(h != INVALID_HANDLE) { FileWrite(h, line); FileFlush(h); }
      }
   }
   if(h != INVALID_HANDLE) FileClose(h);
   TerminalClose(0);
}
