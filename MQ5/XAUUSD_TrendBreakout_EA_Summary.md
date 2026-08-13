# สรุป EA #1 — XAUUSD Trend Following & Breakout

ไฟล์โค้ด: [XAUUSD_TrendBreakout_EA.mq5](Experts/XAUUSD_TrendBreakout_EA.mq5) | ประวัติ backtest/ที่มาของค่าพารามิเตอร์: [XAUUSD_TrendBreakout_Spec.md](XAUUSD_TrendBreakout_Spec.md)

สรุปนี้คือ**สถานะปัจจุบัน** (Logic + ค่าที่ตั้งอยู่จริงในโค้ด) เท่านั้น ไม่ใช่ log ประวัติการปรับ — ดู Spec ถ้าต้องการเหตุผล/ผลการทดลองแต่ละรอบ

## แนวคิดหลัก

เทรดตามเทรนด์ใหญ่บน H1 แล้วรอจังหวะราคาหลุดกรอบ (breakout) บน M15 ในทิศทางเทรนด์นั้น — ยิ่งเทรนด์ชัดยิ่งมั่นใจ, ยิ่ง breakout จริง (ไม่ใช่ fakeout) ยิ่งเข้า

## Logic

### 1) Trend Filter (H1) — ตัดสินทิศทาง
- EMA เร็ว (`InpEmaFast`) vs EMA ช้า (`InpEmaSlow`) บอกทิศทางเทรนด์
- ADX(`InpAdxPeriod`) ต้อง ≥ `InpAdxThreshold` ถึงจะถือว่าเทรนด์แข็งพอ (ไม่ใช่ sideway)
- +DI/-DI ต้องสอดคล้องกับทิศทาง EMA ด้วย
- ถ้าเงื่อนไขไม่ผ่านทั้งหมด → **ไม่เทรดเลย** (ไม่มี fallback โหมดอื่น)

### 2) Entry (M15) — Donchian Breakout
- คำนวณกรอบ Donchian (`InpDonchianPeriod` แท่ง) จากแท่งย้อนหลัง **ไม่รวม**แท่งปัจจุบันที่กำลังก่อตัวและแท่งที่เพิ่งปิด (กันไม่ให้กรอบขยับตามราคาที่กำลังจะ breakout)
- **กันสัญญาณหลอก (fakeout filter):** แท่งที่เพิ่งปิดต้อง close เกินกรอบด้วยระยะบัฟเฟอร์ = ATR × `InpAtrBufferMult` และแท่งก่อนหน้ามันต้อง**ยังไม่**เกินบัฟเฟอร์นี้ — เข้าเฉพาะแท่งที่เพิ่ง breakout จริง ไม่ไล่ราคาที่วิ่งไปแล้ว
- ทิศทางไม้ต้องตรงกับ trend bias จาก H1 เท่านั้น (buy เมื่อเทรนด์ขึ้น, sell เมื่อเทรนด์ลง)

### 3) Exit
- SL = ราคาเข้า − ATR × `InpAtrSlMult`
- TP = ระยะ SL × `InpRiskReward`
- Trailing Stop (ถ้า `InpUseTrailing=true`): เลื่อน SL ตาม ATR × `InpTrailAtrMult` เมื่อราคาไปในทางที่ได้กำไร

### 4) Filters (ต้องผ่านทุกอันก่อนเข้าไม้)
- อยู่ในช่วงเวลาเทรด (`InpSessionStartHour`–`InpSessionEndHour`, เวลา broker/server)
- ไม่ใช่วันอาทิตย์ (ถ้า `InpAvoidSunday=true`), ไม่ใช่วันเสาร์ (ตลาดปิดอยู่แล้ว)
- ถ้าเป็นวันศุกร์และเลย `InpFridayCutoffHour` (เมื่อ `InpAvoidFriday=true`) → หยุดเทรด
- สแปรดต้อง ≤ `InpMaxSpreadPoints`
- ไม้เปิดของ EA นี้ต้อง < `InpMaxOpenPositions`
- ไม้ที่เปิดวันนี้ต้อง < `InpMaxTradesPerDay`

**หมายเหตุ:** EA นี้ไม่มี hard safety แบบ "ปิดไม้ก่อนตลาดปิด" เหมือน EA #2 — ใช้แค่ session/Friday/Sunday filter (บล็อกไม้ใหม่เท่านั้น ไม่ force-close ไม้ที่เปิดอยู่)

## ค่าที่ตั้งอยู่จริงตอนนี้ (default ในโค้ด = ผลจาก genetic optimization, ดูรายละเอียดใน Spec)

| กลุ่ม | Input | ค่า |
|---|---|---|
| General | `InpLotSize` | 0.01 |
| General | `InpMagicNumber` | 20260811 |
| General | `InpSlippage` | 20 points |
| General | `InpMaxOpenPositions` | 4 |
| General | `InpMaxTradesPerDay` | 6 |
| Trend Filter (H1) | `InpTrendTF` | H1 |
| Trend Filter (H1) | `InpEmaFast` / `InpEmaSlow` | 50 / 200 |
| Trend Filter (H1) | `InpAdxPeriod` | 14 |
| Trend Filter (H1) | `InpAdxThreshold` | 20.0 |
| Breakout (M15) | `InpEntryTF` | M15 |
| Breakout (M15) | `InpDonchianPeriod` | 8 แท่ง |
| Breakout (M15) | `InpAtrPeriod` | 14 |
| Breakout (M15) | `InpAtrBufferMult` | 0.30 |
| Risk | `InpAtrSlMult` | 1.5 |
| Risk | `InpRiskReward` | 1.8 |
| Risk | `InpUseTrailing` | true |
| Risk | `InpTrailAtrMult` | 1.2 |
| Session | `InpSessionStartHour` / `InpSessionEndHour` | 6 / 23 |
| Session | `InpAvoidFriday` / `InpFridayCutoffHour` | true / 20 |
| Session | `InpAvoidSunday` | true |
| Spread | `InpMaxSpreadPoints` | 350 points |
| Backend Ingest | `InpIngestEnabled` | **false** (ปิดอยู่ ต้องเปิดเอง) |
| Backend Ingest | `InpIngestBaseUrl` | `http://localhost:5008` (ตรงกับ `Backend/EaConsole.Api/Properties/launchSettings.json`) |
| Backend Ingest | `InpIngestAccountId` / `InpIngestEaId` | 1 / 1 |
| Backend Ingest | `InpIngestHeartbeatSec` | 10 วินาที |
| Backend Ingest | `InpIngestTimeoutMs` | 5000 ms |
| Backend Ingest | `InpIngestApiKey` | "" (ว่าง — ใส่ตรงกับ `Ingest:ApiKey` ของ backend ตอน deploy จริง) |

## Backend Ingest (Webhook + Heartbeat)

ใช้ include ร่วมกับ EA #2: [EaIngestClient.mqh](Include/EaIngestClient.mqh) — ส่งข้อมูลเข้า backend (`Backend/EaConsole.Api`, route `api/ingest`) ผ่าน `WebRequest()` — ตรวจสอบ payload/enum/port ทุกอันกับโค้ด backend จริงแล้ว (Controllers/IngestController.cs, Dtos/IngestDtos.cs, Data/Entities/Enums.cs, Database/schema.sql):

- **Heartbeat ทุก `InpIngestHeartbeatSec` วินาที** (ผ่าน `OnTimer()`): ยิง `POST /api/ingest/snapshot` ส่ง balance/equity/margin/free margin/margin level/spread + `connectionState="connected"`
- **เปิดไม้:** ยิง `POST /api/ingest/trade` ทันทีหลัง `trade.Buy()/Sell()` สำเร็จ (status `OPEN`) — พร้อมคำนวณ `slAmount`/`tpAmount` (มูลค่า SL/TP เป็นเงิน) ด้วย `OrderCalcProfit()` ตามที่ schema.sql กำหนดไว้ตรงๆ ว่าต้องคำนวณฝั่ง MQL5 (SQL คำนวณ pip value เองไม่แม่นพอ)
- **ปิดไม้:** ตรวจจับผ่าน `OnTradeTransaction()` (จับได้ทั้งปิดเอง, โดน SL/TP, trailing stop) แล้วยิง `POST /api/ingest/trade` (status `CLOSED`, พร้อม `closeReason` = TP/SL/EA_LOGIC/MANUAL/OTHER — ตรงกับ `TradeCloseReason` enum ของ backend เป๊ะ)
- **สถานะ EA:** `PUT /api/ingest/ea/{eaId}/status` เป็น `active` ตอน `OnInit()`, `standby` ตอน `OnDeinit()`
- **Error log:** ถ้า `OrderSend` ล้มเหลว ยิง `POST /api/ingest/log` ระดับ `error`
- **Upsert key ฝั่ง backend คือ (`accountId`, `mt5Ticket`)** — ใช้ MT5 Position ID เดียวกันทั้งตอนเปิดและปิดไม้ (ไม่ใช่ order ticket) ตรงกับที่ `IngestService.cs` คาดหวังไว้พอดี ไม่ต้องรู้ trade_id ภายในของ backend

**ปิดอยู่โดย default (`InpIngestEnabled=false`)** — เป็น no-op ทั้งหมดจนกว่าจะเปิดเอง (ยืนยันแล้วด้วย backtest 2 รอบ: ผลลัพธ์เหมือนเดิมทุกตัวเลขตอนปิด แม้เพิ่ม `OrderCalcProfit()` เข้าไปแล้วก็ตาม) **ห้ามเปิดตอน backtest/optimize** เพราะ WebRequest จะยิงจริงจากทุก tester agent ที่รันพร้อมกัน ช้าและไม่มีประโยชน์กับข้อมูลย้อนหลัง ก่อนใช้งานจริง (live/demo) ต้องเพิ่ม `InpIngestBaseUrl` ใน MT5: **Tools > Options > Expert Advisors > Allow WebRequest for listed URL** ก่อน ไม่งั้นทุกคำขอจะพังด้วย error 4060 (มี log ผ่าน `Print()` ให้เห็นเสมอ ไม่ fail แบบเงียบ)

**⚠️ พบความไม่ตรงกัน (ยังไม่ได้แก้):** `Backend/Database/seed_sample_data.sql` ตั้ง `magic_number` ของ EA ตัวนี้ไว้เป็น `100001` แต่ EA จริงใช้ `InpMagicNumber=20260811` — ไม่กระทบการทำงานของ ingest ปัจจุบัน (`IngestService.cs` ไม่ได้เช็ค magic_number ตอนรับข้อมูล ใช้ `EaId` ที่ส่งมาตรงๆ) แต่ข้อมูลใน `eas` table จะไม่ตรงกับความจริง ถ้าจะให้ตรงต้องอัปเดต seed data หรือ column นี้ทีหลัง

**เตรียม deploy จริงแล้ว (12 ส.ค. 2026):** backend ปรับให้พร้อมขึ้น host จริงแล้ว — ดู [Backend/DEPLOYMENT.md](../Backend/DEPLOYMENT.md) เต็มๆ สรุปสั้น: เพิ่ม `UseForwardedHeaders()` (รองรับ reverse proxy), `GET /health` (สำหรับ uptime monitor), และ **`Ingest:ApiKey`** — ถ้า backend ตั้งค่านี้ไว้ (ผ่าน env var `Ingest__ApiKey`) endpoint `/api/ingest/*` จะเช็ค header `X-Api-Key` ทุกครั้ง ต้องตั้ง `InpIngestApiKey` ที่ EA ให้ตรงกัน (ปิดอยู่โดย default ทั้งสองฝั่ง — ถ้าไม่ตั้งอะไรเลยพฤติกรรมเหมือนเดิม)

## Custom OnTester() Score

ให้คะแนน = กำไร × ปรับตามความถี่ไม้ (เต็ม 1.0 ถ้าอยู่ในช่วง **2-3 ไม้/วัน**, ลดถ้าน้อย/มากกว่านั้น) × ปรับตาม drawdown (ลดคะแนนหนักขึ้นเมื่อ Equity DD relative เกิน ~20-25%) — ใช้เป็น Optimization Criterion=5 (Custom) ตอนรัน genetic optimize เพื่อให้หาค่าที่สมดุลกำไร/ความถี่/DD ไม่ใช่กำไรดิบอย่างเดียว

## ผล Backtest ล่าสุด (6 เดือน, 2026.02.11–08.11, M15 real ticks, deposit $1,000)

Net Profit **$427.58** | Profit Factor **1.37** | Max Equity DD **13.24% ($182.27)** | ไม้ **252 (~1.95/วัน)**

## ข้อจำกัด/สิ่งที่ยังไม่ทำ

- ผลทั้งหมดยังเป็น **in-sample** เดียวกัน ไม่มี out-of-sample/walk-forward validation
- ยังไม่ forward-test บนบัญชีเดโมจริง
- Webhook พร้อมใช้แล้ว แต่**ยังไม่เคยทดสอบยิงเข้า backend จริง** (แค่ยืนยันว่าปิดแล้วไม่กระทบผล backtest) — ต้องรัน backend, เปิด `InpIngestEnabled=true`, ตั้ง URL ที่ MT5 allow-list แล้วทดสอบยิงจริงก่อนใช้งาน
