param(
   [string]$Terminal = "C:\Program Files\MetaTrader 5 EXNESS\terminal64.exe",
   [string]$DataFolder = "C:\Users\CZ\AppData\Roaming\MetaQuotes\Terminal\53785E099C927DB68A545C249CDBCE06",
   [string]$WorkFolder = "C:\Users\CZ\AppData\Local\Temp\StopGrid9_NoEMA_RSIADX_SerialSweep"
)

$ErrorActionPreference = "Stop"
$reportName = "StopGrid9_NoEMA_RSIADX_SerialPass"
$reportPath = Join-Path $DataFolder ($reportName + ".htm")
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$outputFolder = Join-Path $PSScriptRoot "Results"
New-Item -ItemType Directory -Path $WorkFolder -Force | Out-Null
New-Item -ItemType Directory -Path $outputFolder -Force | Out-Null
$csvPath = Join-Path $outputFolder ("StopGrid9_NoEMA_RSIADX_Sweep_" + $stamp + ".csv")
$progressPath = Join-Path $WorkFolder ("progress_" + $stamp + ".log")

function Get-ReportValue([string]$Html, [string]$Label) {
   $pattern = [regex]::Escape($Label + ":") + "</td>\s*<td[^>]*>(.*?)</td>"
   $match = [regex]::Match($Html, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
   if($match.Success) {
      $value = [regex]::Replace($match.Groups[1].Value, "<[^>]+>", " ")
      return [System.Net.WebUtility]::HtmlDecode($value).Trim()
   }
   return ""
}

$rsiPeriods = @(5, 7, 9)
$rsiBuyLevels = @(10.0, 15.0, 20.0)
$rsiSellLevels = @(80.0, 85.0, 90.0)
$adxPeriods = @(10, 14, 18)
$adxThresholds = @(30.0, 40.0, 50.0)
$cases = @()
foreach($rsiPeriod in $rsiPeriods) {
   foreach($buyBelow in $rsiBuyLevels) {
      foreach($sellAbove in $rsiSellLevels) {
         foreach($adxPeriod in $adxPeriods) {
            foreach($adxThreshold in $adxThresholds) {
               $cases += [pscustomobject]@{
                  RSIPeriod = $rsiPeriod
                  RSIBuyBelow = $buyBelow
                  RSISellAbove = $sellAbove
                  ADXPeriod = $adxPeriod
                  ADXThreshold = $adxThreshold
               }
            }
         }
      }
   }
}

$results = @()
$total = $cases.Count
for($index = 0; $index -lt $total; $index++) {
   $case = $cases[$index]
   $iniPath = Join-Path $WorkFolder "current_pass.ini"
   $ini = @"
[Tester]
Expert=XAUUSD_StopGrid_9x9_EA
Symbol=XAUUSD
Period=M1
Model=4
FromDate=2026.01.06
ToDate=2026.06.30
ForwardMode=0
Deposit=100000
Currency=USD
Leverage=1:100
ExecutionMode=0
Optimization=0
Report=$reportName
ReplaceReport=1
ShutdownTerminal=1
Visual=0

[TesterInputs]
InpRSIPeriod=$($case.RSIPeriod)||$($case.RSIPeriod)||1||$($case.RSIPeriod)||N
InpRSIBuyBelow=$($case.RSIBuyBelow)||$($case.RSIBuyBelow)||1||$($case.RSIBuyBelow)||N
InpRSISellAbove=$($case.RSISellAbove)||$($case.RSISellAbove)||1||$($case.RSISellAbove)||N
InpUseM5EMAFilter=false||false||0||true||N
InpTrendEMAPeriod=200||200||1||2000||N
InpADXPeriod=$($case.ADXPeriod)||$($case.ADXPeriod)||1||$($case.ADXPeriod)||N
InpADXStrongTrendThreshold=$($case.ADXThreshold)||$($case.ADXThreshold)||1||$($case.ADXThreshold)||N
InpLevelsPerSide=9||9||1||9||N
InpGridStepPrice=2.0||2.0||0.1||2.0||N
InpFirstLevelLot=0.01||0.01||0.01||0.01||N
InpLotMode=1||1||1||2||N
InpCustomLotSequence=0.01,0.01,0.01,0.01,0.01,0.01,0.01,0.01,0.01||0.01,0.01,0.01,0.01,0.01,0.01,0.01,0.01,0.01||0.01||0.01,0.01,0.01,0.01,0.01,0.01,0.01,0.01,0.01||N
InpOppositeMode=0||0||1||1||N
InpAutoRearmAfterCycle=true||false||0||true||N
InpRearmDelaySeconds=5||5||1||5||N
InpStopLossBeyondAnchor=0.0||0.0||1.0||0.0||N
InpTakeProfitBeyondLast=2.0||2.0||0.1||2.0||N
InpMaxSpreadPrice=0.20||0.20||0.01||0.20||N
InpSlippagePoints=100||100||1||100||N
InpExpirationHours=0||0||1||0||N
InpMinutesBeforeSessionClose=15||15||1||15||N
InpMagicNumber=91250925||91250925||1||91250925||N
InpMaxRiskPercent=0.0||0.0||0.1||0.0||N
InpRiskSlipBufferPrice=0.05||0.05||0.01||0.05||N
InpMinMarginLevelPct=300.0||300.0||1.0||300.0||N
InpRetrySeconds=30||30||1||30||N
"@
   [System.IO.File]::WriteAllText($iniPath, $ini, [System.Text.Encoding]::ASCII)

   $startedAt = Get-Date
   $argument = "/config:$iniPath"
   $process = Start-Process -FilePath $Terminal -ArgumentList $argument -WindowStyle Hidden -PassThru -Wait
   if(-not (Test-Path -LiteralPath $reportPath) -or (Get-Item -LiteralPath $reportPath).LastWriteTime -lt $startedAt) {
      $results += [pscustomobject]@{Pass=$index+1; Status="MissingReport"; RSIPeriod=$case.RSIPeriod; RSIBuyBelow=$case.RSIBuyBelow; RSISellAbove=$case.RSISellAbove; ADXPeriod=$case.ADXPeriod; ADXThreshold=$case.ADXThreshold; NetProfit=""; ProfitFactor=""; RecoveryFactor=""; EquityDD=""; Trades=""; HistoryQuality=""}
      $progress = "[{0}/{1}] FAILED to produce report" -f ($index+1), $total
      Add-Content -LiteralPath $progressPath -Value $progress -Encoding UTF8
      Write-Output $progress
      continue
   }

   $html = [System.IO.File]::ReadAllText($reportPath)
   $row = [pscustomobject]@{
      Pass = $index + 1
      Status = "OK"
      RSIPeriod = $case.RSIPeriod
      RSIBuyBelow = $case.RSIBuyBelow
      RSISellAbove = $case.RSISellAbove
      ADXPeriod = $case.ADXPeriod
      ADXThreshold = $case.ADXThreshold
      NetProfit = Get-ReportValue $html "Total Net Profit"
      ProfitFactor = Get-ReportValue $html "Profit Factor"
      RecoveryFactor = Get-ReportValue $html "Recovery Factor"
      EquityDD = Get-ReportValue $html "Equity Drawdown Relative"
      Trades = Get-ReportValue $html "Total Trades"
      HistoryQuality = Get-ReportValue $html "History Quality"
   }
   $results += $row
   if(Test-Path -LiteralPath $csvPath) {
      $row | Export-Csv -LiteralPath $csvPath -Append -NoTypeInformation -Encoding UTF8
   } else {
      $row | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
   }
   $progress = "[{0}/{1}] RSI {2} {3}/{4}; ADX {5}/{6}; RF {7}; PF {8}; net {9}; trades {10}" -f $row.Pass, $total, $row.RSIPeriod, $row.RSIBuyBelow, $row.RSISellAbove, $row.ADXPeriod, $row.ADXThreshold, $row.RecoveryFactor, $row.ProfitFactor, $row.NetProfit, $row.Trades
   Add-Content -LiteralPath $progressPath -Value $progress -Encoding UTF8
   Write-Output $progress
}

Write-Output "Sweep complete. CSV: $csvPath. Progress: $progressPath"
