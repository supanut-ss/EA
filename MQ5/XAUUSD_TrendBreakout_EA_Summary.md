# สรุป EA #1 — XAUUSD Trend Following & Breakout

ไฟล์โค้ด: [XAUUSD_TrendBreakout_EA.mq5](Experts/XAUUSD_TrendBreakout_EA.mq5) | ประวัติ backtest/ที่มาของค่าพารามิเตอร์: [XAUUSD_TrendBreakout_Spec.md](XAUUSD_TrendBreakout_Spec.md)

สรุปนี้คือ**สถานะปัจจุบัน** (Logic + ค่าที่ตั้งอยู่จริงในโค้ด) เท่านั้น ไม่ใช่ log ประวัติการปรับ — ดู Spec ถ้าต้องการเหตุผล/ผลการทดลองแต่ละรอบ

## แนวคิดหลัก

เทรดตามเทรนด์ใหญ่บน H1 แล้วรอจังหวะราคาหลุดกรอบ (breakout) บน M15 ในทิศทางเทรนด์นั้น — ยิ่งเทรนด์ชัดยิ่งมั่นใจ, ยิ่ง breakout จริง (ไม่ใช่ fakeout) ยิ่งเข้า

## Logic

### 1) Trend Filter (H1) — ตัดสินทิศทาง
- EMA เร็ว (`InpEmaFast`) vs EMA ช้า (`InpEmaSlow`) บอกทิศทางเทรนด์ โดยใช้แท่ง H1 ที่ปิดแล้ว (`shift 1`) เท่านั้น
- ADX(`InpAdxPeriod`) ต้อง ≥ `InpAdxThreshold` ถึงจะถือว่าเทรนด์แข็งพอ (ไม่ใช่ sideway)
- +DI/-DI ต้องสอดคล้องกับทิศทาง EMA ด้วย
- ถ้าเงื่อนไขไม่ผ่านทั้งหมด → **ไม่เทรดเลย** (ไม่มี fallback โหมดอื่น)

### 2) Entry (M15) — Donchian Breakout
- คำนวณกรอบ Donchian (`InpDonchianPeriod` แท่ง) จากแท่งย้อนหลัง **ไม่รวม**แท่งปัจจุบันที่กำลังก่อตัวและแท่งที่เพิ่งปิด (กันไม่ให้กรอบขยับตามราคาที่กำลังจะ breakout)
- **กันสัญญาณหลอก (fakeout filter):** แท่งที่เพิ่งปิดต้อง close เกินกรอบด้วยระยะบัฟเฟอร์ = ATR × `InpAtrBufferMult` และแท่งก่อนหน้าต้องไม่ breakout เมื่อเทียบกับ Donchian/ATR ของแท่งก่อนหน้าเอง จึงใช้สัญญาณแรกของ breakout event เท่านั้น
- ทิศทางไม้ต้องตรงกับ trend bias จาก H1 เท่านั้น (buy เมื่อเทรนด์ขึ้น, sell เมื่อเทรนด์ลง)

### 3) Exit
- SL = ราคาเข้า − ATR × `InpAtrSlMult`
- TP = ระยะ SL × `InpRiskReward`
- Trailing Stop (ถ้า `InpUseTrailing=true`): เริ่มทำงานเมื่อกำไรถึง ATR × `InpTrailStartAtrMult` แล้วจึงเลื่อน SL ตาม ATR × `InpTrailAtrMult`

### 4) Filters (ต้องผ่านทุกอันก่อนเข้าไม้)
- อยู่ในช่วงเวลาเทรด (`InpSessionStartHour`–`InpSessionEndHour`, เวลา broker/server)
- ไม่ใช่วันอาทิตย์ (ถ้า `InpAvoidSunday=true`), ไม่ใช่วันเสาร์ (ตลาดปิดอยู่แล้ว)
- ถ้าเป็นวันศุกร์และเลย `InpFridayCutoffHour` (เมื่อ `InpAvoidFriday=true`) → หยุดเทรด
- สแปรดต้อง ≤ `InpMaxSpreadPoints`
- ไม้เปิดของ EA นี้ต้อง < `InpMaxOpenPositions`
- ปริมาณรวมต้องไม่เกิน `InpLotSize × InpMaxOpenPositions` และ broker `SYMBOL_VOLUME_LIMIT`
- ไม้ที่เปิดวันนี้ต้อง < `InpMaxTradesPerDay`
- daily counter ถูกกู้จากประวัติ order หลัง restart; attach กลางแท่งจะไม่ประมวลผลสัญญาณเก่าซ้ำ
- ปฏิเสธบัญชี netting เพราะหลาย EA บน XAUUSD ไม่สามารถแยก ownership ด้วย magic number ได้อย่างปลอดภัย

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
| Risk | `InpTrailStartAtrMult` | 1.0 |
| Session | `InpSessionStartHour` / `InpSessionEndHour` | 6 / 23 |
| Session | `InpAvoidFriday` / `InpFridayCutoffHour` | true / 20 |
| Session | `InpAvoidSunday` | true |
| Spread | `InpMaxSpreadPoints` | 350 points |
| Backend Ingest | `InpIngestEnabled` | **true** (Strategy Tester บังคับปิดอัตโนมัติ) |
| Backend Ingest | `InpIngestBaseUrl` | `https://ea.thaipesleague.com` |
| Backend Ingest | `InpIngestAccountId` / `InpIngestEaId` | 1 / 1 |
| Backend Ingest | `InpIngestHeartbeatSec` | 29 วินาที |
| Backend Ingest | `InpIngestTimeoutMs` | 5000 ms |
| Backend Ingest | `InpIngestApiKey` | ตั้งค่า compiled default ให้ตรงกับ production backend (ไม่แสดงค่าในเอกสาร) |

## Backend Ingest (Webhook + Heartbeat)

ใช้ include ร่วมกับ EA #2: [EaIngestClient.mqh](Include/EaIngestClient.mqh) — ส่งข้อมูลเข้า backend (`Backend/EaConsole.Api`, route `api/ingest`) ผ่าน `WebRequest()` — ตรวจสอบ payload/enum/port ทุกอันกับโค้ด backend จริงแล้ว (Controllers/IngestController.cs, Dtos/IngestDtos.cs, Data/Entities/Enums.cs, Database/schema.sql):

- **Heartbeat ทุก `InpIngestHeartbeatSec` วินาที** (ผ่าน `OnTimer()`): ยิง `POST /api/ingest/snapshot` ส่ง balance/equity/margin/free margin/margin level/spread + `connectionState="connected"`
- **เปิดไม้:** ยิง `POST /api/ingest/trade` ทันทีหลัง `trade.Buy()/Sell()` สำเร็จ (status `OPEN`) — พร้อมคำนวณ `slAmount`/`tpAmount` (มูลค่า SL/TP เป็นเงิน) ด้วย `OrderCalcProfit()` ตามที่ schema.sql กำหนดไว้ตรงๆ ว่าต้องคำนวณฝั่ง MQL5 (SQL คำนวณ pip value เองไม่แม่นพอ)
- **ปิดไม้:** ตรวจจับผ่าน `OnTradeTransaction()` (จับได้ทั้งปิดเอง, โดน SL/TP, trailing stop) แล้วยิง `POST /api/ingest/trade` (status `CLOSED`, พร้อม `closeReason` = TP/SL/EA_LOGIC/MANUAL/OTHER — ตรงกับ `TradeCloseReason` enum ของ backend เป๊ะ)
- **สถานะ EA:** `PUT /api/ingest/ea/{eaId}/status` เป็น `active` ตอน `OnInit()`, `standby` ตอน `OnDeinit()`
- **Error log:** ถ้า `OrderSend` ล้มเหลว ยิง `POST /api/ingest/log` ระดับ `error`
- **Upsert key ฝั่ง backend คือ (`accountId`, `mt5Ticket`)** — ใช้ MT5 Position ID เดียวกันทั้งตอนเปิดและปิดไม้ (ไม่ใช่ order ticket) ตรงกับที่ `IngestService.cs` คาดหวังไว้พอดี ไม่ต้องรู้ trade_id ภายในของ backend

**เปิดอยู่โดย default บน live/demo แต่ถูกบังคับเป็น no-op เมื่อ `MQL_TESTER=true`** จึงไม่ยิง WebRequest ระหว่าง backtest/optimization แม้ input เปิดอยู่ ก่อนใช้งานจริงต้องเพิ่ม `InpIngestBaseUrl` ใน MT5: **Tools > Options > Expert Advisors > Allow WebRequest for listed URL** ไม่เช่นนั้นคำขอจะล้มเหลวด้วย error 4060

**⚠️ พบความไม่ตรงกัน (ยังไม่ได้แก้):** `Backend/Database/seed_sample_data.sql` ตั้ง `magic_number` ของ EA ตัวนี้ไว้เป็น `100001` แต่ EA จริงใช้ `InpMagicNumber=20260811` — ไม่กระทบการทำงานของ ingest ปัจจุบัน (`IngestService.cs` ไม่ได้เช็ค magic_number ตอนรับข้อมูล ใช้ `EaId` ที่ส่งมาตรงๆ) แต่ข้อมูลใน `eas` table จะไม่ตรงกับความจริง ถ้าจะให้ตรงต้องอัปเดต seed data หรือ column นี้ทีหลัง

**เตรียม deploy จริงแล้ว (12 ส.ค. 2026):** backend รองรับ reverse proxy, `GET /health` และการตรวจ `X-Api-Key` ผ่าน `Ingest__ApiKey`; compiled default ของ EA ต้องตรงกับ backend และควรหมุนค่า key พร้อมกันทั้งสองฝั่งเมื่อมีการเปลี่ยนแปลง

## Custom OnTester() Score

ให้คะแนน = กำไร × ปรับตามความถี่ไม้ (เต็ม 1.0 ถ้าอยู่ในช่วง **2-3 ไม้/วัน**, ลดถ้าน้อย/มากกว่านั้น) × ปรับตาม drawdown (ลดคะแนนหนักขึ้นเมื่อ Equity DD relative เกิน ~20-25%) — ใช้เป็น Optimization Criterion=5 (Custom) ตอนรัน genetic optimize เพื่อให้หาค่าที่สมดุลกำไร/ความถี่/DD ไม่ใช่กำไรดิบอย่างเดียว

## ผล Backtest ปัจจุบันหลัง correctness patch (2026.09.17)

Strategy Tester functional run ช่วง 2026.01.01–08.13, M15, deposit $1,000: Net Profit **$371.95** | Profit Factor **1.28** | Max Equity DD **15.20% ($212.68)** | ไม้ **195** | แพ้ติดสูงสุด **4 ไม้** อย่างไรก็ตาม report รอบนี้ระบุ History Quality **0% real ticks** จึงใช้ยืนยันเฉพาะว่า flow ทำงานครบ ไม่ใช้ยืนยัน performance หรือ edge

ทดลองเพิ่ม candle body/close-location/range filter บนข้อมูลชุดเดียวกันแล้วผลแย่ลง: Net Profit $91.45, PF 1.08, DD 22.02%, 159 ไม้ จึงไม่รวม filter นี้ในโค้ดปัจจุบัน; ผลนี้เป็น directional A/B เท่านั้นเพราะ History Quality ต่ำ

## ข้อจำกัด/สิ่งที่ยังไม่ทำ

- ผลทั้งหมดยังเป็น **in-sample** เดียวกัน ไม่มี out-of-sample/walk-forward validation
- functional run ปัจจุบันมี History Quality 0% real ticks จึงต้องดาวน์โหลด/ซ่อม real-tick history แล้วรันใหม่ก่อนเทียบ performance
- รอบ OOS 2026.08.14–09.17 มี real ticks เพียง 38% และ 39 ไม้ จึงยังใช้ยืนยัน edge ไม่ได้
- ยังไม่ forward-test บนบัญชีเดโมจริง
- Webhook เปิดอยู่โดย default แต่**ยังไม่เคยทดสอบยิงเข้า backend จริง** — ต้องยืนยัน backend key, เพิ่ม production URL ใน MT5 allow-list และทดสอบ heartbeat/open/close end-to-end ก่อนใช้งาน
