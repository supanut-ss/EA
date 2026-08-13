# สรุป EA #2 — XAUUSD Scalping & Session-Based

ไฟล์โค้ด: [XAUUSD_Scalping_EA.mq5](Experts/XAUUSD_Scalping_EA.mq5) | ประวัติ design/backtest/optimize: [XAUUSD_Scalping_Spec.md](XAUUSD_Scalping_Spec.md)

สรุปนี้คือ**สถานะปัจจุบัน** (Logic + ค่าที่ตั้งอยู่จริงในโค้ด) เท่านั้น ไม่ใช่ log ประวัติการปรับ — ดู Spec ถ้าต้องการเหตุผล/ผลการทดลองแต่ละรอบ (โดยเฉพาะทำไม trend-mode entry ถึงผ่านมา 3 เวอร์ชัน)

## แนวคิดหลัก

ต่างจาก EA #1 ตรงที่ scalp ได้**ทุก regime** (ทั้งช่วงมีเทรนด์และช่วง sideway) โดยสลับตรรกะเข้าไม้ตาม ADX(H1) — มีไว้เพื่อดึงความถี่ไม้ของพอร์ตรวมขึ้น (EA #1 เทรดน้อยครั้งโดยธรรมชาติ) พร้อม hard safety ที่ไม่มีใน EA #1: **ห้ามมีไม้ค้างช่วงตลาดปิด/พักเบรกเด็ดขาด**

Magic Number (`InpMagicNumber=20260812`) แยกจาก EA #1 (`20260811`) — รันพร้อมกันบนบัญชี/สัญลักษณ์เดียวกันได้โดยไม่ปนกัน

## Logic

### 1) Regime Detector (H1) — เลือกโหมดเข้าไม้
- ADX(`InpAdxPeriod`) ≥ `InpAdxThreshold` → **โหมด Trend**, ต่ำกว่า → **โหมด Range/Choppy**
- โหมด Trend ยังต้องมี bias ชัด (EMA เร็ว/ช้า + DI สอดคล้องกัน แบบเดียวกับ EA #1) ถ้า ADX สูงแต่ทิศทางไม่ชัด → ไม่เข้าไม้รอบนั้น

### 2a) Entry โหมด Trend (M5) — pullback-scalp ตามเทรนด์
เข้าไม้เมื่อครบ 2 เงื่อนไข (ผ่านการแก้ 3 รอบจนกว่าจะไม่ noise เกินไป — ดู Spec):
- **Fresh cross:** แท่งก่อนหน้ายังอยู่ฝั่ง pullback ของ EMA (`InpEmaFastM5`) แท่งล่าสุดเพิ่งปิดกลับฝั่งเทรนด์ (กันยิงซ้ำทุกแท่งตอนราคาแกว่งใกล้ EMA)
- **RSI หลุบจริง:** ต้องเคยแตะระดับ `InpRsiPullbackDeepLow`/`InpRsiPullbackDeepHigh` ภายใน `InpPullbackLookbackBars` แท่งที่ผ่านมา แล้วฟื้นกลับผ่าน `InpRsiPullbackLow`/`InpRsiPullbackHigh`

### 2b) Entry โหมด Range/Choppy (M5) — mean-reversion แบบ 2 แท่งยืนยัน
- **Setup:** แท่งหนึ่งปิดหลุด Bollinger Band (`InpBbPeriod`/`InpBbDeviation`) พร้อม RSI แตะ `InpRsiOversold`/`InpRsiOverbought`
- **Confirm:** แท่งถัดมาต้องปิด**กลับเข้ามาใน**กรอบ Band แล้วแล้วค่อยเข้าไม้ (ไม่เข้าตั้งแต่แท่งแรกที่หลุดกรอบ — กันโดน fakeout/แนวโน้มที่วิ่งจริง)

### 3) Exit
- SL = ATR(M5) × `InpAtrSlMultTrend` (โหมด Trend) หรือ × `InpAtrSlMultRange` (โหมด Range, กว้างกว่า กัน wick สะบัด)
- TP โหมด Trend = ระยะ SL × `InpRiskReward`
- TP โหมด Range = ระยะ SL × `InpRiskReward` **แต่ถูก cap ไว้ที่ middle Bollinger Band** ถ้าจุดนั้นใกล้กว่า (เพราะ thesis คือราคาเด้งกลับเข้าเส้นกลาง ไม่ควรตั้งเป้าเกินนั้น)
- **Time-based exit:** ถ้าเปิดมาแล้ว ≥ `InpMaxBarsInTrade` แท่ง (M5) ยังไม่ถึง TP/SL → ปิดไม้ทิ้งที่ตลาด (thesis ของ pullback/reversion จางเร็ว)

### 4) Hard Safety — ห้ามมีไม้ค้างช่วงตลาดปิด/พักเบรก (แยกอิสระจาก logic ข้างบนทั้งหมด)
- อ่านตารางเทรดจริงของโบรกเกอร์ผ่าน `SymbolInfoSessionTrade()` (ถ้า `InpUseSymbolSessionTrade=true`) คำนวณเวลาที่เหลือก่อน session จะปิด
- เหลือน้อยกว่า `InpFlattenBufferMinutes` นาที → **บล็อกไม้ใหม่ทั้งหมด + ปิดไม้ที่เปิดอยู่ทุกไม้ของ EA นี้ทันที**
- ถ้า `InpUseSymbolSessionTrade=false` → fallback เป็นกฎ Friday cutoff (`InpFridayFallbackCutoffHour`) + ไม่เทรดเสาร์-อาทิตย์ แบบเดียวกับ EA #1 แต่ก็ยัง force-close ไม้ค้างด้วย (ไม่ใช่แค่บล็อกไม้ใหม่)
- ยืนยันด้วย backtest จริงหลายรอบ (สูงสุด 6 เดือน ข้าม weekend หลายสิบรอบ): **Maximal position holding time ไม่เคยเกิน 2:00:00** เลย

### 5) Filters อื่น
- สแปรดต้อง ≤ `InpMaxSpreadPoints`
- ไม้เปิดของ EA นี้ต้อง < `InpMaxOpenPositions`
- ไม้โหมด Trend วันนี้ต้อง < `InpMaxTradesPerDayTrend`, โหมด Range ต้อง < `InpMaxTradesPerDayChoppy` (นับแยกกัน คนละ cap)

## ค่าที่ตั้งอยู่จริงตอนนี้ (default ในโค้ด = ผลจาก genetic optimization รอบ 3, ดูรายละเอียดใน Spec)

| กลุ่ม | Input | ค่า |
|---|---|---|
| General | `InpLotSize` | 0.01 |
| General | `InpMagicNumber` | 20260812 |
| General | `InpSlippage` | 20 points |
| General | `InpMaxOpenPositions` | 2 |
| General | `InpMaxTradesPerDayTrend` | 15 |
| General | `InpMaxTradesPerDayChoppy` | 8 |
| Regime (H1) | `InpRegimeTF` | H1 |
| Regime (H1) | `InpAdxPeriod` | 14 |
| Regime (H1) | `InpAdxThreshold` | **30.0** |
| Regime (H1) | `InpEmaFastH1` / `InpEmaSlowH1` | 50 / 200 |
| Entry Trend (M5) | `InpEntryTF` | M5 |
| Entry Trend (M5) | `InpEmaFastM5` | 20 |
| Entry Trend (M5) | `InpRsiPeriod` | 14 (ใช้ร่วมกับโหมด Range) |
| Entry Trend (M5) | `InpRsiPullbackLow` / `InpRsiPullbackHigh` | 45.0 / 55.0 |
| Entry Trend (M5) | `InpRsiPullbackDeepLow` / `InpRsiPullbackDeepHigh` | **20.0** / **55.0** |
| Entry Trend (M5) | `InpPullbackLookbackBars` | 6 แท่ง |
| Entry Range (M5) | `InpBbPeriod` / `InpBbDeviation` | 20 / **2.5** |
| Entry Range (M5) | `InpRsiOversold` / `InpRsiOverbought` | **40.0** / **80.0** |
| Risk | `InpAtrPeriod` | 14 |
| Risk | `InpAtrSlMultTrend` / `InpAtrSlMultRange` | 1.0 / **0.6** |
| Risk | `InpRiskReward` | **1.6** |
| Risk | `InpMaxBarsInTrade` | 24 แท่ง (= 2 ชม.) |
| Spread | `InpMaxSpreadPoints` | 200 points |
| Safety | `InpUseSymbolSessionTrade` | true |
| Safety | `InpFlattenBufferMinutes` | 20 นาที |
| Safety | `InpFridayFallbackCutoffHour` | 20 (fallback เท่านั้น) |
| Backend Ingest | `InpIngestEnabled` | **false** (ปิดอยู่ ต้องเปิดเอง) |
| Backend Ingest | `InpIngestBaseUrl` | `http://localhost:5008` (ตรงกับ `Backend/EaConsole.Api/Properties/launchSettings.json`) |
| Backend Ingest | `InpIngestAccountId` / `InpIngestEaId` | 1 / **2** (ต่างจาก EA #1 — ดูหมายเหตุ) |
| Backend Ingest | `InpIngestHeartbeatSec` | 10 วินาที |
| Backend Ingest | `InpIngestTimeoutMs` | 5000 ms |
| Backend Ingest | `InpIngestApiKey` | "" (ว่าง — ใส่ตรงกับ `Ingest:ApiKey` ของ backend ตอน deploy จริง) |

## Backend Ingest (Webhook + Heartbeat)

ใช้ include ร่วมกับ EA #1: [EaIngestClient.mqh](Include/EaIngestClient.mqh) — logic เดียวกันทุกอย่าง (heartbeat ทุก `InpIngestHeartbeatSec` วิ, ส่ง trade OPEN/CLOSED พร้อม `slAmount`/`tpAmount` จาก `OrderCalcProfit()` ผ่าน `OnTradeTransaction()`, สถานะ EA, error log) ดูรายละเอียดเต็ม + ผลตรวจกับ backend จริงใน [XAUUSD_TrendBreakout_EA_Summary.md](XAUUSD_TrendBreakout_EA_Summary.md#backend-ingest-webhook--heartbeat)

**สำคัญ:** ต้องตั้ง `InpIngestEaId=2` (ต่างจาก EA #1 ที่ใช้ 1) เพราะ backend ใช้ `EaId` แยกข้อมูลของแต่ละ EA — คนละค่ากับ `InpMagicNumber` (20260812, แยกฝั่ง MT5 อยู่แล้ว) ตรงกับ ea_id=2 ("Scalping & Session") ใน `Backend/Database/seed_sample_data.sql`

**⚠️ พบความไม่ตรงกัน (ยังไม่ได้แก้):** seed data ตั้ง `magic_number` ของ EA ตัวนี้ไว้เป็น `100002` แต่ EA จริงใช้ `InpMagicNumber=20260812` — ไม่กระทบ ingest ปัจจุบัน (ดูรายละเอียดเหตุผลใน summary ของ EA #1)

**ปิดอยู่โดย default** — เป็น no-op จนกว่าจะเปิด (ยืนยันแล้วด้วย backtest 2 รอบ: ผลลัพธ์เหมือนเดิมทุกตัวเลขตอนปิด รวม max holding time 2:00:00 แม้เพิ่ม `OrderCalcProfit()` แล้วก็ตาม) **ห้ามเปิดตอน backtest/optimize** เหตุผลเดียวกับ EA #1

**เตรียม deploy จริงแล้ว (12 ส.ค. 2026):** backend เพิ่ม `Ingest:ApiKey` gate + forwarded headers + health endpoint — ดูรายละเอียดเต็มใน [Backend/DEPLOYMENT.md](../Backend/DEPLOYMENT.md) และหมายเหตุใน summary ของ EA #1

## Custom OnTester() Score

เหมือน EA #1 แต่เป้าความถี่สูงกว่า: เต็ม 1.0 ถ้าอยู่ในช่วง **3-8 ไม้/วัน** (เพราะ EA นี้มีไว้ดึงความถี่รวมของพอร์ต ไม่ใช่แค่ทำเท่า EA #1)

## ผล Backtest ล่าสุด (6 เดือน, 2026.02.11–08.11, M5 real ticks, deposit $1,000)

Net Profit **$452.54** | Profit Factor **1.35** | Max Equity DD **5.97% ($89.48)** | ไม้ **471 (~3.62/วัน)** | Max holding time **2:00:00** (ไม่มีไม้ค้างข้ามพักเลย)

## ข้อจำกัด/สิ่งที่ยังไม่ทำ

- ผลทั้งหมดยังเป็น **in-sample** เดียวกัน ไม่มี out-of-sample/walk-forward validation
- ยังไม่ forward-test บนบัญชีเดโมจริง — hard safety (flatten-before-close) ผ่านแค่ backtest ยังไม่เจอสถานการณ์จริง
- ยังไม่ได้ตรวจ margin level ตอนรันคู่กับ EA #1 จริงบน MT5 (มีแค่การรวม trade log แบบประมาณ — ดูผลรวมใน Spec)
- Webhook พร้อมใช้แล้ว แต่**ยังไม่เคยทดสอบยิงเข้า backend จริง** (แค่ยืนยันว่าปิดแล้วไม่กระทบผล backtest) — ต้องรัน backend, เปิด `InpIngestEnabled=true`, ตั้ง URL ที่ MT5 allow-list, ตั้ง `InpIngestEaId=2` แล้วทดสอบยิงจริงก่อนใช้งาน
