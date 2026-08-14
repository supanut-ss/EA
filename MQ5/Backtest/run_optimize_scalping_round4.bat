@echo off
setlocal

REM ============================================================
REM  XAUUSD Scalping & Session EA - Round 4 (InpAtrSlMultRange only)
REM  Runs metaeditor64.exe /compile and terminal64.exe /config
REM ============================================================

set "DATAFOLDER=C:\Users\CZ\AppData\Roaming\MetaQuotes\Terminal\53785E099C927DB68A545C249CDBCE06"
set "MT5DIR=C:\Program Files\MetaTrader 5 EXNESS"
set "SRC_MQ5=%~dp0..\Experts\XAUUSD_Scalping_EA.mq5"
set "SRC_MQH=%~dp0..\Include\EaIngestClient.mqh"

if not exist "%DATAFOLDER%\MQL5\Experts" (
    echo [ERROR] Could not find MQL5\Experts under: %DATAFOLDER%
    pause
    exit /b 1
)

echo [1/3] Copying EA + shared include into MT5 folders...
copy /Y "%SRC_MQ5%" "%DATAFOLDER%\MQL5\Experts\XAUUSD_Scalping_EA.mq5" >nul
copy /Y "%SRC_MQH%" "%DATAFOLDER%\MQL5\Include\EaIngestClient.mqh" >nul

echo [2/3] Compiling in MetaEditor (headless)...
"%MT5DIR%\metaeditor64.exe" /compile:"%DATAFOLDER%\MQL5\Experts\XAUUSD_Scalping_EA.mq5" /log:"%~dp0compile_log_scalping.txt"
type "%~dp0compile_log_scalping.txt"

echo [3/3] Running Strategy Tester genetic optimization round 4 (headless)...
"%MT5DIR%\terminal64.exe" /config:"%~dp0tester_config_scalping_optimize_round4.ini"

echo.
echo Done. Report: %DATAFOLDER%\XAUUSD_Scalping_Optimize_Round4.xml
pause
