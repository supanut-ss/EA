@echo off
setlocal

REM ============================================================
REM  XAUUSD Trend/Breakout EA - Headless Compile + Backtest
REM  Runs metaeditor64.exe /compile and terminal64.exe /config
REM  No clicking inside MT5 or MetaEditor is required to run this.
REM ============================================================

REM --- EDIT THIS: paste your MT5 Data Folder path here ---
REM     Get it from MT5: File -> Open Data Folder (copy the address bar path)
set "DATAFOLDER=PUT_YOUR_DATA_FOLDER_PATH_HERE"

REM --- MT5 install folder (already confirmed on this machine) ---
set "MT5DIR=C:\Program Files\MetaTrader 5"

REM --- Source EA file in the shared project folder (do not move this) ---
set "SRC_MQ5=%~dp0..\Experts\XAUUSD_TrendBreakout_EA.mq5"

if "%DATAFOLDER%"=="PUT_YOUR_DATA_FOLDER_PATH_HERE" (
    echo [ERROR] Please edit this .bat file first and set DATAFOLDER.
    echo         In MT5: File -^> Open Data Folder, copy the path from
    echo         the File Explorer address bar and paste it above.
    pause
    exit /b 1
)

if not exist "%DATAFOLDER%\MQL5\Experts" (
    echo [ERROR] Could not find MQL5\Experts under: %DATAFOLDER%
    echo         Double check the DATAFOLDER path you set above.
    pause
    exit /b 1
)

echo [1/3] Copying EA into MT5 Experts folder...
copy /Y "%SRC_MQ5%" "%DATAFOLDER%\MQL5\Experts\XAUUSD_TrendBreakout_EA.mq5" >nul
if errorlevel 1 (
    echo [ERROR] Copy failed. Check SRC_MQ5 path: %SRC_MQ5%
    pause
    exit /b 1
)

echo [2/3] Compiling in MetaEditor (headless)...
"%MT5DIR%\metaeditor64.exe" /compile:"%DATAFOLDER%\MQL5\Experts\XAUUSD_TrendBreakout_EA.mq5" /log:"%~dp0compile_log.txt"
echo ----- compile_log.txt -----
type "%~dp0compile_log.txt"
echo ----------------------------
findstr /C:"0 error" "%~dp0compile_log.txt" >nul
if errorlevel 1 (
    echo [WARNING] Compile log does not show "0 error" - check the log above before trusting the test results.
    pause
)

echo [3/3] Running Strategy Tester (headless, terminal will close itself when done)...
"%MT5DIR%\terminal64.exe" /config:"%~dp0tester_config.ini"

echo.
echo Done. Look for the report in your Data Folder, usually under:
echo   %DATAFOLDER%\Tester\
echo (file name starts with "XAUUSD_TrendBreakout_Report")
echo Copy that .htm report back into the shared EA folder and share it back.
pause
