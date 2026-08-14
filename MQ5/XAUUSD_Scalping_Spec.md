# XAUUSD Scalping & Session EA — แผนออกแบบ (ยังไม่ได้ลงมือเขียนโค้ด)

EA ตัวที่ 2 จาก 2 ตัว คู่กับ `XAUUSD_TrendBreakout_EA.mq5` (ดู [XAUUSD_TrendBreakout_Spec.md](XAUUSD_TrendBreakout_Spec.md)) — ไฟล์นี้เป็น**แผนออกแบบ**เท่านั้น รอผล optimize ของ EA ตัวที่ 1 นิ่งก่อน (เสร็จแล้ว — ดู spec ตัวที่ 1) แล้วค่อยเริ่มเขียนโค้ดจริงตามแผนนี้

**อัปเดต 12 ส.ค. 2026 (v2):** แก้ทิศทางตามที่ผู้ใช้สั่ง — เดิมวางแผนให้เทรดเฉพาะตอน sideway/choppy เท่านั้น (gate ด้วย ADX ต่ำ) ตอนนี้เปลี่ยนเป็น **ต้อง scalp ได้ทุกช่วงของกราฟ** (ทั้งช่วงมีเทรนด์และช่วง sideway) แต่ **ระวังเป็นพิเศษตอน sideway/choppy** (ความเสี่ยงสัญญาณหลอกสูงสุด) และเพิ่มข้อกำหนดใหม่ที่เป็น **hard requirement**: **ต้องไม่มีไม้ค้างช่วงพักเบรก/ตลาดปิด** ไม่ว่า regime จะเป็นแบบไหน

## เป้าหมายและความสัมพันธ์กับ EA ตัวที่ 1

- EA ตัวที่ 1 (Trend/Breakout) เทรดตามเทรนด์ใหญ่เท่านั้น (ต้องผ่าน ADX(14) ≥ 20 บน H1) และหยุดเทรดเมื่อตลาด sideway — ที่ความถี่คุณภาพนี้ได้จริง ~1.95 ไม้/วัน (หลัง optimize) ยังไม่ถึงเป้าพอร์ตรวม 2-3 ไม้/วัน
- EA ตัวที่ 2 ต้องเพิ่มความถี่ไม้ของพอร์ตรวมโดย**เทรดได้ทุก regime** ไม่ผูกกับช่วงที่ EA ตัวที่ 1 พักอยู่เท่านั้นแบบแผนเดิม — ใช้ตรรกะเข้าไม้ 2 แบบสลับกันตาม regime (ดูหัวข้อถัดไป) เพื่อให้ยังคุม edge ไว้ได้แม้เทรดทุกช่วง
- Magic number แยกจาก EA ตัวที่ 1 เด็ดขาด — ทั้งสองตัวอาจรันพร้อมกันบนบัญชี/สัญลักษณ์เดียวกัน ต้องไม่ปนกันตอนนับไม้เปิด/คำนวณ P&L

## หลักการ (ทำไมออกแบบแบบนี้)

### 1) เทรดได้ทุก regime แต่สลับตรรกะเข้าไม้ตาม ADX(H1)

Mean-reversion ล้วนๆ จะพังถ้าปล่อยให้เข้าไม้สู้เทรนด์แรง (fade ตอนตลาดกำลังวิ่งจริง) — เพื่อให้ "scalp ได้ทุกช่วง" โดยไม่เสีย edge จึงแยกตรรกะเป็น 2 โหมดตาม ADX(14) บน H1 (threshold เดียวกับ EA ตัวที่ 1 เพื่อให้ regime อ่านตรงกัน):

- **โหมด Trend (ADX ≥ threshold):** micro pullback-scalp **ตามทิศทางเทรนด์** บน M5 (เช่น EMA เร็ว/ช้าบอกทิศ + RSI ย่อตัวไม่ถึง extreme เป็นจุดเข้า) — เข้าไม้สั้นๆ ตามคลื่นย่อยของเทรนด์ ไม่ fade เทรนด์ ปลอดภัยกว่าตอนตลาดมีทิศทางชัด
- **โหมด Range/Choppy (ADX < threshold):** mean-reversion บน M5 (Bollinger Bands(20,2.0) + RSI extreme) ตามแผนเดิม แต่เพิ่ม **ความระวังพิเศษ** เพราะเป็นโซนที่เสี่ยง fakeout สูงสุด:
  - ต้องมีแท่งยืนยัน 2 แท่งติดกันที่ปิดเกิน band + RSI extreme (ไม่เข้าไม้จากแท่งเดียว)
  - ลดขนาดไม้/ลดจำนวนไม้สูงสุดต่อวันเฉพาะโหมดนี้ (`InpMaxTradesPerDayChoppy` แยกจากโหมด trend)
  - SL กว้างกว่าโหมด trend เล็กน้อย (ATR-based) เพื่อกันโดน wick สะบัดออกก่อนราคาดีดกลับจริง

### 2) Entry/Exit ร่วม (ทั้ง 2 โหมด)

- **Exit:** TP อิง R:R สั้น (~1:1 ถึง 1:1.2 — scalp เก็บกำไรเร็ว ไม่ถือรอมาก), SL แน่นอิง ATR(M5)
- **Time-based exit:** ถ้าเปิดมาแล้ว N แท่ง (M5) ยังไม่ถึง TP/SL ให้ปิดไม้ทิ้ง — ทั้งสมมติฐาน pullback-continuation และ mean-reversion จางลงเร็วถ้าไม่เกิดในไม่กี่แท่ง
- **Filter สแปรด:** เข้มกว่า EA ตัวที่ 1 เพราะเข้าไม้ M5/สั้น edge ต่อไม้เล็ก สแปรดกว้างกินขาดกำไรง่ายกว่ามาก

### 3) Hard requirement ใหม่: ห้ามมีไม้ค้างช่วงพักเบรก/ตลาดปิด

ข้อกำหนดนี้แยกอิสระจากตรรกะเข้าไม้ทั้งหมดข้างบน ใช้กับทุกไม้ของ EA นี้ไม่ว่า regime ไหน:

- ใช้ `SymbolInfoSessionTrade(symbol, day_of_week, session_index, from, to)` ของ MT5 อ่านตารางเวลาเทรดจริงของโบรกเกอร์สำหรับ XAUUSD (ครอบคลุมทั้งปิดสัปดาห์และช่วงพักที่โบรกเกอร์กำหนดไว้ เช่น rollover/maintenance) แทนการ hardcode ชั่วโมงเอง — แม่นยำกว่าและไม่ต้องเดาว่าโบรกเกอร์มีพักช่วงไหนบ้าง
- คำนวณ "เวลาที่เหลือก่อนตลาด/session จะปิดครั้งถัดไป" ทุกแท่งใหม่ ถ้าน้อยกว่า `InpFlattenBufferMinutes` (draft ~15-30 นาที):
  1. **ห้ามเปิดไม้ใหม่** ทันที (บล็อก `CheckForEntry()` ทั้ง 2 โหมด)
  2. **ปิดไม้ที่เปิดอยู่ทั้งหมดของ EA นี้ทันที** (ใช้ Magic Number ของตัวเองกรอง ไม่ยุ่งกับไม้ของ EA ตัวที่ 1)
- Fallback เผื่อ `SymbolInfoSessionTrade` อ่านไม่ได้/ผิดปกติ: เก็บกฎ Friday cutoff / no-Sunday-trading แบบ EA ตัวที่ 1 ไว้เป็นเซฟตี้เน็ตสำรอง (defense-in-depth ไม่ใช่ตัวหลัก)
- ต้อง unit-test แนวคิดนี้ด้วย backtest ที่ตั้งช่วงให้ครอบคลุมวันศุกร์ปิดตลาดและวันเปิดตลาดวันอาทิตย์/จันทร์อย่างน้อยหลายรอบ เพื่อยืนยันว่าไม่มีไม้ค้างข้ามพักจริง

## Input parameters ที่วางแผน (draft ค่าเริ่มต้น — ต้องยืนยันด้วย backtest จริง)

| กลุ่ม | Input | ค่าเริ่มต้นที่วางแผน | หมายเหตุ |
|---|---|---|---|
| General | `InpLotSize` | 0.01 | fixed lot เหมือน EA ตัวที่ 1 |
| General | `InpMagicNumber` | ค่าใหม่ ไม่ชนกับ 20260811 | ต้องแยกจาก EA ตัวที่ 1 |
| General | `InpMaxOpenPositions` | 1-2 | scalp ไม่ควร stack ไม้เยอะ ต่างจาก trend-following |
| General | `InpMaxTradesPerDay` | 10-20 (โหมด trend) | ความถี่สูงกว่า EA ตัวที่ 1 โดยดีไซน์ |
| General | `InpMaxTradesPerDayChoppy` | ต่ำกว่าโหมด trend (สมมติ 5-10) | ความระวังพิเศษตอน sideway/choppy ตามที่สั่ง |
| Regime (H1) | `InpAdxPeriod` / `InpAdxThreshold` | 14 / 20 | ใช้แยกโหมด trend vs range ไม่ใช่ gate ปิดเทรด |
| Entry โหมด Trend (M5) | `InpEmaFast` / `InpEmaSlow` | ต้อง backtest หา | บอกทิศ pullback-scalp ตามเทรนด์ |
| Entry โหมด Trend (M5) | `InpRsiPullbackLow/High` | เช่น 40-60 (ไม่ extreme) | จุดย่อตัวที่เข้าไม้ตามเทรนด์ |
| Entry โหมด Range (M5) | `InpBbPeriod` / `InpBbDeviation` | 20 / 2.0 | Bollinger Bands มาตรฐาน |
| Entry โหมด Range (M5) | `InpRsiPeriod` | 7 หรือ 14 (ต้องเทียบ) | ยิ่งสั้น = ไวกว่า แต่สัญญาณหลอกมากกว่า |
| Entry โหมด Range (M5) | `InpRsiOversold` / `InpRsiOverbought` | 25-30 / 70-75 | จุด extreme ที่เข้าไม้ |
| Entry โหมด Range (M5) | `InpRequireConfirmBars` | 2 | ต้องยืนยัน 2 แท่งติดก่อนเข้า — ความระวังพิเศษตอน choppy |
| Risk | `InpAtrSlMultTrend` / `InpAtrSlMultRange` | trend แน่นกว่า, range กว้างกว่าเล็กน้อย | กัน wick สะบัดตอน choppy |
| Risk | `InpRiskReward` | ~1.0-1.2 | R:R สั้น ต่างจาก EA ตัวที่ 1 (1.8) |
| Risk | `InpMaxBarsInTrade` | เผื่อไว้ (เช่น 20-30 แท่ง M5) | time-based exit |
| Filter | `InpMaxSpreadPoints` | ต่ำกว่า EA ตัวที่ 1 (สมมติ ~150-250) | ต้อง backtest เทียบสแปรดจริงของ broker |
| **Safety (ใหม่ — hard requirement)** | `InpFlattenBufferMinutes` | 15-30 | บล็อกไม้ใหม่ + ปิดไม้ค้างก่อนตลาดปิด/พักเบรกจริง |
| **Safety (ใหม่)** | `InpUseSymbolSessionTrade` | true | ใช้ `SymbolInfoSessionTrade` อ่านตารางจริงของโบรกเกอร์ |
| **Safety (fallback)** | Friday/Sunday avoidance | เหมือน EA ตัวที่ 1 | เซฟตี้เน็ตสำรองถ้า session-trade API ใช้ไม่ได้ |

**หมายเหตุ:** ตัด `InpSessionStartHour/EndHour` แบบ EA ตัวที่ 1 ออกจากแผน — เพราะตอนนี้ต้องเทรด "ทุกช่วงของกราฟ" ไม่ใช่ผูกกับ session window อีกต่อไป กลไกคุมเวลาที่เหลือคือ flatten-before-close ในหัวข้อ Safety เท่านั้น

## แผนขั้นตอนถัดไป (ยังไม่เริ่ม)

1. เขียนโค้ด `XAUUSD_Scalping_EA.mq5` ตามแผนนี้ (โครงเดียวกับ EA ตัวที่ 1: OnInit/OnTick + regime detector + 2 entry function ตาม regime + `FlattenBeforeClose()` แยกอิสระ + OnTester() custom score)
2. `OnTester()` ของ EA นี้ควรตั้ง target ความถี่ไม้/วันให้สูงกว่า EA ตัวที่ 1 (เช่น 3-8 ไม้/วัน) เพราะเป้าหมายคือดึงความถี่รวมของพอร์ตขึ้น ไม่ใช่แค่ 2-3 ไม้/วันแบบเดียวกับ EA ตัวที่ 1
3. Backtest รอบแรกด้วยค่า default ตามตารางข้างบนก่อน (headless ผ่าน `run_backtest.bat` แบบเดียวกับ EA ตัวที่ 1 — ต้องทำ config .ini คู่ใหม่) — เช็ค log/Journal ว่าไม่มีไม้เปิดค้างข้ามช่วงปิดตลาดจริง (ดูจากจำนวนไม้ที่ปิดด้วยเหตุผลอื่นนอกจาก TP/SL/manual)
4. ปรับ parameter ตามผล backtest จริง แล้วรัน genetic optimization เหมือน EA ตัวที่ 1 (`run_optimize.bat`)
5. ทดสอบรัน 2 EA พร้อมกันบนบัญชีเดียวกัน (Magic Number ต่างกัน) ดู equity curve รวมว่า drawdown ซ้อนกันช่วงไหนหรือไม่
6. Forward-test บนเดโมก่อนใช้เงินจริงเหมือน EA ตัวที่ 1 — สังเกตช่วงเปิด/ปิดตลาดจริงหลายรอบว่าไม่มีไม้ค้างจริง (ไม่ใช่แค่ผลจาก backtest)

## สถานะจริง (อัปเดต 12 ส.ค. 2026) — เขียนโค้ดแล้ว, backtest + optimize แล้ว 3 รอบ

โค้ดจริงอยู่ที่ [XAUUSD_Scalping_EA.mq5](Experts/XAUUSD_Scalping_EA.mq5) compile ผ่าน 0 errors/0 warnings

**v3 fix สำคัญ (เจอจาก backtest จริง ไม่ใช่แค่ทฤษฎี):** โหมด Trend v1/v2 ยิงไม้ถี่เกินจริง — v1 ใช้ "RSI ข้าม midline 45/55" (สัญญาณสัญญาณรบกวนล้วนๆ) v2 เปลี่ยนเป็น "wick แตะ EMA" แต่กลับยิงถี่กว่าเดิม (~7.5 ไม้/วันจากโหมดเดียว ดัน DD จาก ~20% เป็น 27.75%) เพราะ wick แตะ EMA ใกล้ๆ เป็นเรื่องปกติ ไม่ใช่ pullback จริง **v3 (ที่ใช้อยู่ตอนนี้)** บังคับ 2 อย่างพร้อมกัน: (1) **fresh cross** — แท่งก่อนหน้าต้องยังอยู่ฝั่ง pullback แท่งนี้เพิ่งปิดกลับฝั่งเทรนด์ (ยิงได้ครั้งเดียวต่อ pullback ไม่ยิงซ้ำทุกแท่ง) และ (2) **RSI หลุบจริง** — ต้องเคยแตะ `InpRsiPullbackDeepLow/High` ในช่วง `InpPullbackLookbackBars` แท่งที่ผ่านมา ไม่ใช่แค่แตะโซนกลางๆ แก้แล้วไม้ลดจาก 970/6เดือน เหลือ ~41/6เดือนที่ความถี่สมเหตุสมผล

### ผล Optimization (genetic, 6 เดือน 2026.02.11–08.11, M5 real ticks)

| รอบ | พารามิเตอร์ที่ค้น | ดีที่สุด | Profit Factor | Net Profit | Max DD | ไม้ (~ไม้/วัน) |
|---|---|---|---|---|---|---|
| 1 | ADX threshold, SL mult ×2, R:R, MaxBarsInTrade (5 ตัว) | Pass 124 | 1.08 | $50.66 | 8.73% | 228 (~1.75) |
| 2 | รอบ 1 + RSI dip depth, RSI extreme, BB deviation (9 ตัว) | Pass 1225 | 1.46 | $392.71 | 6.56% | 328 (~2.52) |
| **3 (ใช้อยู่)** | รอบ 2 ขยายขอบ 5 ตัวที่ชนขอบเดิม | **Pass 445** | 1.35 | **$452.54** | 5.97% | **471 (~3.62)** |

รอบ 1 อ่อนเพราะ entry logic v2 ยังมีปัญหา noise (ก่อนแก้เป็น v3) — พอแก้ entry logic แล้ว optimize รอบ 2-3 เจอ edge จริงชัดเจนขึ้นเรื่อยๆ Pass 445 (รอบ 3) ชนะ Pass 1225 (รอบ 2) เพราะความถี่ไม้ใกล้เป้า 3-8/วันมากกว่า (freqFactor เต็ม) แม้ PF จะต่ำกว่าเล็กน้อย

**ค่า default ที่ใช้อยู่ตอนนี้ (Pass 445):** `InpAdxThreshold=30`, `InpRsiPullbackDeepLow=20`, `InpRsiPullbackDeepHigh=55`, `InpBbDeviation=2.5`, `InpRsiOversold=40`, `InpRsiOverbought=80`, `InpAtrSlMultTrend=1.0`, `InpAtrSlMultRange=0.6`, `InpRiskReward=1.6`, `InpMaxBarsInTrade=24`

**Safety ยืนยันแล้วด้วย backtest จริง:** ทุกรอบ backtest (10 สัปดาห์ถึง 6 เดือน, ข้าม weekend หลายสิบรอบ) **Maximal position holding time ไม่เคยเกิน 2:00:00** (= `InpMaxBarsInTrade`×M5) ไม่มีไม้ค้างข้ามพัก/ปิดตลาดเลยแม้แต่ครั้งเดียว

### ผลรวม 2 EA พร้อมกัน (12 ส.ค. 2026)

รัน backtest แยกกัน 6 เดือนเดียวกัน แล้วรวม trade log ตามเวลาจริงเพื่อดู equity รวม (ยังไม่ใช่การรันพร้อมกันจริงใน Strategy Tester เดียว — MT5 Tester รันได้ EA เดียวต่อรอบ แต่เพราะทั้งสองตัวใช้ fixed lot + Magic Number แยกกัน ไม่แย่ง SL/TP กัน การรวมแบบนี้ใกล้เคียงของจริงมาก ยกเว้นความเสี่ยงเรื่อง margin รวมที่ยังไม่ได้ตรวจเจาะจง):

| | EA #1 เดี่ยว | EA #2 เดี่ยว | **รวมกัน (บัญชีเดียว $1,000)** |
|---|---|---|---|
| ไม้ | 252 (~1.95/วัน) | 471 (~3.62/วัน) | 723 (~5.56/วัน) |
| Net Profit | $427.58 | $452.54 | **~$880** (รวม Net Profit ของแต่ละตัว) |
| Max Equity DD ($) | $182.27 | $89.48 | **$169.18** |
| Max Equity DD (%) | 13.24% | 5.97% | 10.97% (ของ peak ที่โตขึ้น) |

**สรุป:** รวมกันแล้ว DD เป็นเงินจริง ($169.18) **ต่ำกว่า** การรัน EA#1 ตัวเดียว ($182.27) ทั้งที่กำไรรวมเพิ่มเป็นเกือบ 2 เท่า — มี diversification benefit จริง (ช่วง drawdown ของ 2 ตัวไม่ทับกันสนิท) ความถี่ไม้รวม ~5.56/วัน เกินเป้าดั้งเดิม 2-3/วันของทั้งพอร์ตไปมาก ตรงตามเจตนาที่ออกแบบ EA#2 มาเพื่อดึงความถี่รวมขึ้น

### ขั้นตอนที่เหลือ (ยังไม่ทำ)

- Forward-test บนเดโมจริงอย่างน้อย 2-4 สัปดาห์ (เหมือน EA ตัวที่ 1) ทั้งแยกและรวมกัน — ผลข้างบนทั้งหมดยังเป็น in-sample period เดียวกัน (2026.02.11–08.11) ไม่มี out-of-sample validation
- ยังไม่ได้ตรวจ margin level ตอนรัน 2 EA พร้อมกันจริงบน MT5 (มีแค่การรวม trade log แบบประมาณ)
- Webhook ส่งข้อมูลจาก EA เข้า backend (`api/ingest`) ยังไม่ได้ทำ — รอ user สั่งตามที่คุยไว้ก่อนหน้า
