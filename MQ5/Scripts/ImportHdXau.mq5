//+------------------------------------------------------------------+
//| ImportHdXau.mq5 - build custom symbol XAUUSD_HD from M1 CSV      |
//| CSV (MQL5/Files/hd_xau_m1_utc.csv): unix_utc,open,high,low,close |
//| Fixed 40-point spread to mimic the Exness XAUUSD condition.      |
//+------------------------------------------------------------------+
#property script_show_inputs
input string InpSymbol = "XAUUSD_HD";
input string InpFile   = "hd_xau_m1_utc.csv";
input int    InpSpreadPoints = 40;

void OnStart()
{
   if(!SymbolInfoInteger(InpSymbol, SYMBOL_EXIST))
   {
      if(!CustomSymbolCreate(InpSymbol, "Custom\Gold", "XAUUSD"))
      {
         PrintFormat("CustomSymbolCreate failed: %d", GetLastError());
         TerminalClose(1);
         return;
      }
   }
   else
      CustomRatesDelete(InpSymbol, 0, LONG_MAX);

   int h = FileOpen(InpFile, FILE_READ | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE) { PrintFormat("open %s failed: %d", InpFile, GetLastError()); TerminalClose(2); return; }

   MqlRates buf[];
   ArrayResize(buf, 0, 60000);
   long total = 0;
   string parts[];
   while(!FileIsEnding(h))
   {
      string line = FileReadString(h);
      if(StringSplit(line, ',', parts) < 5) continue;
      int n = ArraySize(buf);
      ArrayResize(buf, n + 1, 60000);
      buf[n].time = (datetime)StringToInteger(parts[0]);
      buf[n].open = StringToDouble(parts[1]);
      buf[n].high = StringToDouble(parts[2]);
      buf[n].low  = StringToDouble(parts[3]);
      buf[n].close = StringToDouble(parts[4]);
      buf[n].tick_volume = 10;
      buf[n].real_volume = 0;
      buf[n].spread = InpSpreadPoints;
      if(n + 1 >= 50000)
      {
         int r = CustomRatesUpdate(InpSymbol, buf);
         total += r;
         PrintFormat("imported chunk -> %d (total %I64d)", r, total);
         ArrayResize(buf, 0, 60000);
      }
   }
   if(ArraySize(buf) > 0) total += CustomRatesUpdate(InpSymbol, buf);
   FileClose(h);
   SymbolSelect(InpSymbol, true);
   int hr = FileOpen("import_hd_result.txt", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(hr != INVALID_HANDLE) { FileWrite(hr, StringFormat("imported=%I64d", total)); FileClose(hr); }
   PrintFormat("Done: %I64d bars imported into %s", total, InpSymbol);
   TerminalClose(0);
}
