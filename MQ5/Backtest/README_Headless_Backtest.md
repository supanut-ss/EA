# รัน Backtest แบบ Headless (ไม่ต้องคลิกในโปรแกรม)

MT5 รองรับโหมด command-line จริง: `metaeditor64.exe /compile` (compile ไม่เปิด GUI) และ `terminal64.exe /config:ini` (รัน Strategy Tester ไม่เปิด GUI) ผมเตรียมสคริปต์ไว้ให้แล้ว คุณ **แก้ค่าเดียว แล้วดับเบิลคลิกครั้งเดียว** ที่เหลือรันเองหมด

## ทำไมผมรันเองให้ไม่ได้ 100%

Bash ของผมอยู่ใน sandbox Linux แยกจากเครื่อง Windows ของคุณ ไม่มีช่องทางสั่งรัน .exe บนเครื่องคุณได้ ส่วนการควบคุมหน้าจอก็ติดข้อจำกัดด้านความปลอดภัย (พิมพ์คำสั่งใน Command Prompt ไม่ได้) จึงเหลือแค่ให้คุณสั่งรันเอง 1 ครั้ง — แต่ตัวสคริปต์เองทำงานแบบ headless ทั้งหมด ไม่มี dialog ให้คลิกระหว่างทาง

## ขั้นตอน (ทำครั้งเดียว)

1. เปิด MT5 → **File → Open Data Folder** → copy path จาก address bar (เช่น `C:\Users\...\AppData\Roaming\MetaQuotes\Terminal\XXXXXXXX`)
2. เปิดไฟล์ `run_backtest.bat` ด้วย Notepad แก้บรรทัด:
   ```
   set "DATAFOLDER=PUT_YOUR_DATA_FOLDER_PATH_HERE"
   ```
   ให้เป็น path ที่ copy มา แล้ว save
3. เช็คบัญชีใน `tester_config.ini` ว่าเลข `Login=` ตรงกับบัญชีของคุณไหม (ที่ใส่ไว้ 279661518 เป็นค่าที่เห็นตอนคุยกันครั้งก่อน แก้ได้ถ้าไม่ตรง) **ห้ามใส่ Password ลงไฟล์นี้ถ้าโฟลเดอร์นี้จะถูก commit เข้า git**
4. ดับเบิลคลิก `run_backtest.bat` — มันจะ copy ไฟล์ EA เข้า Experts, compile, แล้วรัน Strategy Tester ให้เองทั้งหมด (terminal จะปิดตัวเองเมื่อเสร็จเพราะตั้ง `ShutdownTerminal=1`)
5. ผลลัพธ์จะถูกเซฟเป็นไฟล์รายงานในโฟลเดอร์ `Tester` ใต้ Data Folder ของคุณ ชื่อขึ้นต้นด้วย `XAUUSD_TrendBreakout_Report` — copy ไฟล์นั้นมาวางในโฟลเดอร์ EA ที่แชร์กับผม (หรือส่งมาให้ดูก็ได้) แล้วผมจะอ่านผลและช่วยปรับต่อ

## ถ้ารันแล้วไม่มี report ออกมา

สาเหตุที่พบบ่อยที่สุด: MT5 ยังไม่มีข้อมูลราคาย้อนหลังของ XAUUSD M15/H1 ช่วงที่ระบุใน `FromDate`/`ToDate` แคชอยู่ในเครื่อง แก้โดยเปิด MT5 ตามปกติ เปิดกราฟ XAUUSD ทั้ง M15 และ H1 แล้วกด Home ค้าง/scroll ย้อนหลังให้โหลดข้อมูลเก่าเข้ามาก่อนสักครั้ง จากนั้นค่อยรัน `run_backtest.bat` ใหม่

## รัน Genetic Optimization แบบ Headless (`run_optimize.bat`)

ใช้ `tester_config_optimize.ini` แทน `tester_config.ini` — ค้นหาค่า parameter ที่ดีที่สุดโดยอิงคะแนนจาก `OnTester()` ในโค้ด EA (กำไร × ปรับตามความถี่ไม้/วัน × ปรับตาม drawdown) แทนการดู balance อย่างเดียว

ขั้นตอนเหมือน `run_backtest.bat`:

1. เปิดไฟล์ `run_optimize.bat` ด้วย Notepad แก้ `DATAFOLDER=` ให้เป็น path เดียวกับที่ใช้ใน `run_backtest.bat`
2. เช็คช่วงพารามิเตอร์ที่จะ optimize ใน `tester_config_optimize.ini` (คอลัมน์ `Y` ใน `[TesterInputs]` คือตัวที่ค้นหา) ว่าตรงกับที่ต้องการไหม
3. ดับเบิลคลิก `run_optimize.bat` — มันจะ copy EA, compile, แล้วรัน genetic optimization ให้เองทั้งหมด
4. ผลลัพธ์เซฟเป็นไฟล์ในโฟลเดอร์ `Tester` ใต้ Data Folder ชื่อขึ้นต้นด้วย `XAUUSD_TrendBreakout_Optimize` — copy กลับมาให้ผมดู

**ข้อควรระวังเรื่อง RAM:** จากการทดลองรันจริงบนเครื่องนี้ (ดู `tester_config_optimize.ini` และ `XAUUSD_TrendBreakout_Spec.md`) progress เคยค้างที่ ~2% เพราะ RAM ว่างไม่พอ (agent แต่ละตัวกิน ~900MB+ สำหรับ tick data) ก่อนรันควรปิดโปรแกรมอื่นที่กิน RAM มาก หรือลดจำนวน local agent ใน MT5 (Tools > Options > Strategy Tester Agents) ถ้ายังค้าง
