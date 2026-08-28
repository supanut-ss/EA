# EA3 — XAUUSD_COUNTER_TREND — สรุป Logic ทั้งหมด

**ไฟล์:** [MQ5/Experts/XAUUSD_COUNTER_TREND.mq5](../MQ5/Experts/XAUUSD_COUNTER_TREND.mq5) (v2.22)
พร้อมไฟล์ทดลองรุ่นแก้ไข [XAUUSD_COUNTER_TREND_V223.mq5](../MQ5/Experts/XAUUSD_COUNTER_TREND_V223.mq5) (v2.23) และ [XAUUSD_COUNTER_TREND_V224.mq5](../MQ5/Experts/XAUUSD_COUNTER_TREND_V224.mq5) (v2.24)

**ชื่อในระบบ backend:** EA3 (ea_id=3, magic=88188) — ใช้โปรโตคอล "ATS" ของตัวเอง แยกจาก EA1/EA2 (`EaIngestClient.mqh`) โดยสิ้นเชิง — ดู [SignalsController.cs](../Backend/EaConsole.Api/Controllers/SignalsController.cs) และ [SignalsDtos.cs](../Backend/EaConsole.Api/Dtos/SignalsDtos.cs)
บัญชีที่ผูกไว้: `account_id = 2` (Exness-MT5Real8 login 411757774, บัญชี Live แยกจาก EA1/EA2)

---

## 1. ภาพรวมกลยุทธ์

EA3 เป็น EA แนว **Counter-Trend / Pullback** บน Price Structure ล้วน (ไม่ใช้ indicator เป็นตัวตัดสินหลัก) โดยอิงแนวคิดจาก ICT/Smart-Money concepts:

- **Pivot High/Low** → ใช้หา **CHoCH** (Change of Character) และยืนยัน **BOS** (Break of Structure) เพื่อกำหนด `trend` (1 = ขาขึ้น, -1 = ขาลง)
- **FVG (Fair Value Gap)** และ **OB (Order Block)** → โซนที่ราคาน่าจะ "ย้อนกลับมาเติม" ก่อนไปต่อตามเทรนด์
- **Premium/Discount Zone** → วัด retracement จากจุดสูงสุด/ต่ำสุดของ swing เพื่อหาโซนราคาที่ "ถูก/แพง" เทียบกับเทรนด์
- เข้าไม้แบบ **counter-pullback**: เทรนด์เป็นขาขึ้น (`trend==1`) → รอราคาย่อกลับมาโซน Discount แล้วเปิด **BUY** ตามเทรนด์ (ไม่ใช่การเปิดสวนเทรนด์จริง ๆ แต่เป็นการเข้าเมื่อราคาย่อ/สวนกลับเข้าโซนมาก่อนแล้วค่อยไปต่อ)
- มีโหมดเสริม **Confirmed Trend Breakout** (ปิดอยู่โดย default) สำหรับเข้าไม้ตามแรงเบรกที่ยืนยันแล้ว

โค้ดยังรองรับ **Webhook signal** จาก backend (โปรโตคอล ATS เดิม) ให้เปิด/ปิดออเดอร์ตามคำสั่งจากภายนอกได้ด้วย ควบคู่ไปกับกลยุทธ์ที่ EA ตัดสินใจเอง

---

## 2. โครงสร้างสถานะหลัก (Global State)

| ตัวแปร | ความหมาย |
|---|---|
| `last_ph`, `last_pl`, `prev_ph`, `prev_pl` | Pivot High/Low ล่าสุด และค่าก่อนหน้า |
| `trend`, `prev_trend` | ทิศทางเทรนด์ปัจจุบัน (1/-1/0) |
| `swing_high`, `swing_low` | กรอบ swing ปัจจุบันของเทรนด์ ใช้คำนวณ Premium/Discount |
| `touched_discount`, `touched_premium` | ราคาเคยแตะโซน Discount/Premium ของ swing ปัจจุบันหรือยัง |
| `choch_bull`, `choch_bear` (+`_age`) | สถานะ CHoCH แต่ละฝั่ง พร้อมอายุเป็นจำนวนแท่ง (หมดอายุตาม `InpCHoCHMaxAgeBars`) |
| `pending_bos_*` | ตัวนับยืนยัน BOS (ต้องปิดแท่งเกินระดับ pivot ติดต่อกันตาม `InpBOSConfirmBars`) |
| `fvg_bull_*`, `fvg_bear_*`, `ob_bull_*`, `ob_bear_*` (+`_age`) | โซน FVG/OB ที่ active พร้อมอายุ (หมดอายุตาม `InpFVGMaxAgeBars` / `InpOBMaxAgeBars`) |
| `tracked_positions[]` | รายการโพซิชันที่ EA เปิดเอง ใช้ sync สถานะไป backend |

---

## 3. Pivot → CHoCH → BOS (`ExecuteStrategyLogic`, ทำงานทุกแท่งใหม่)

1. **หา Pivot**: ใช้หน้าต่าง `2*InpPivotLength+1` แท่ง เทียบแท่งกลาง (shift `InpPivotLength+1`) ว่าเป็นจุดสูงสุด/ต่ำสุดในช่วงหรือไม่
2. **CHoCH**: ถ้าเทรนด์เป็นขาขึ้นอยู่ (`trend==1`) แต่ Pivot High ใหม่ **ต่ำกว่า** Pivot High ก่อนหน้า → ตั้ง `choch_bear` (สัญญาณเทรนด์อาจกำลังกลับ); ตรงข้ามกันสำหรับขาลง → `choch_bull`
3. **BOS (`UpdateBOSTrend`)**: เมื่อราคาปิดทะลุ Pivot ฝั่งตรงข้ามเทรนด์ปัจจุบัน จะเปิด "candidate" ทิศทางใหม่ แล้วต้อง**ปิดแท่งอยู่เกินระดับนั้นติดต่อกัน** ครบ `InpBOSConfirmBars` แท่ง (ภายใน `InpBOSMaxPendingBars` แท่ง มิฉะนั้นสถานะ candidate จะถูกล้าง) จึงจะยืนยันเปลี่ยน `trend` จริง — ป้องกันสัญญาณหลอกจากการทะลุแค่แท่งเดียว
4. เมื่อ trend เปลี่ยน → รีเซ็ต `swing_high`/`swing_low` ใหม่จาก pivot ล่าสุด และ **ล้างโซน FVG/OB ทั้งหมด** (`UpdateZoneLifecycle` กับ `trend_changed=true`)

---

## 4. FVG / Order Block (`DetectFVGAtShift`, `DetectOBAtShift`)

ตรวจจากแท่งที่เพิ่งปิด (`shift=1`) เทียบกับแท่ง 2 แท่งก่อนหน้า (`shift+2`):

- **Bullish FVG**: high ของแท่งเก่า < low ของแท่งปัจจุบัน (ช่องว่างราคาระหว่าง 2 แท่ง)
- **Bearish FVG**: low ของแท่งเก่า > high ของแท่งปัจจุบัน
- **Bullish OB**: แท่งเก่าเป็นแท่งแดง (bearish) แล้วแท่งปัจจุบันเป็นแท่งเขียวที่ปิด**เหนือ high** ของแท่งเก่า (impulse move) → แท่งแดงนั้นกลายเป็น Order Block ขาขึ้น
- **Bearish OB**: กลับกัน

แต่ละโซนมีอายุ (`_age`) นับเป็นแท่ง จะถูกล้างเมื่อ: เกิน `InpFVGMaxAgeBars`/`InpOBMaxAgeBars`, ราคาปิดหลุดออกจากโซนไปฝั่งตรงข้าม, หรือเทรนด์เปลี่ยน

---

## 5. Premium / Discount Zone

```
sr = swing_high - swing_low
dl  = swing_low  + sr * InpPDThreshold   // เส้น Discount (v2.22)
pl2 = swing_high - sr * InpPDThreshold   // เส้น Premium (v2.22)
```

- เทรนด์ขาขึ้น (`trend==1`) และราคาลง**แตะ/หลุดต่ำกว่า** `dl` → `touched_discount = true` (โซนราคาถูก รอ BUY)
- เทรนด์ขาลง (`trend==-1`) และราคาขึ้น**แตะ/สูงกว่า** `pl2` → `touched_premium = true` (โซนราคาแพง รอ SELL)
- สถานะจะถูกล้างเมื่อมีโพซิชันฝั่งนั้นเปิดอยู่แล้ว (`ps>0`/`ps<0`) หรือราคาวิ่งกลับไปพ้นโซนตรงข้าม

> **⚠️ หมายเหตุสำคัญ:** สูตรใน v2.22 (ไฟล์หลักปัจจุบัน) ตีความ `InpPDThreshold` เป็น "ระยะจาก extreme ตรงข้าม" (เช่น 0.700 หมายถึงวัดขึ้นจาก swing_low) ส่วนใน v2.23/v2.24 มีการ "แก้ไข" สูตรให้วัด **retracement depth จาก extreme ของฝั่งอิมพัลส์เอง** แทน:
> ```
> dl  = swing_high - sr * InpPDThreshold   // v2.23/2.24
> pl2 = swing_low  + sr * InpPDThreshold
> ```
> พร้อมปรับค่า default: v2.22 = `0.700`, v2.23 = `0.550` (55% retracement), v2.24 = `0.350` (35%, "balanced-frequency" — ปรับให้ความถี่การเข้าไม้สมดุลขึ้น) ทั้งสามไฟล์เป็นซอร์สเกือบเหมือนกันทุกจุดอื่น ต่างกันแค่สูตร/ค่านี้กับ version string

---

## 6. Price Action Confirmation (4-layer filter)

ต้องเป็นแท่งกลับตัวจากแดง→เขียว (bull) หรือเขียว→แดง (bear) ของ 2 แท่งล่าสุด แล้วผ่านเงื่อนไขทั้งหมด:

| เงื่อนไข | ค่า default | ความหมาย |
|---|---|---|
| Body ratio ≥ `InpPABodyMin` | 0.20 | เนื้อเทียนต้องมีขนาดพอสมควรเทียบ range |
| Wick ratio ≤ `InpPAWickMax` | 0.65 | ไส้เทียนฝั่งตรงข้ามทิศทางต้องไม่ยาวเกินไป |
| Close position ≥ `InpPACloseMin` | 0.60 | ราคาปิดต้องอยู่ใกล้ปลายแท่งด้านที่ต้องการ |
| Engulfing (`InpPAEngulf`) | true | ปิดต้องเกินสุดของแท่งก่อนหน้า (กลืนกินเต็มแท่ง) |

---

## 7. ตัวกรองเทรนด์/ทิศทาง (Trend & HTF Filters)

- **EMA (M5, `InpEMALength=200`)**: ปิดต้องอยู่เหนือ/ใต้ EMA ตามทิศ order
- **H1 EMA(21)** และ **H4 EMA(21)**: อ่านเทรนด์แต่ละ TF (bull/bear) — ถ้าเปิดใช้แต่ดึงข้อมูลไม่ได้ ถือว่า **fail-closed** (บล็อกการเข้า ไม่ปล่อยผ่าน)
- **`InpFilterCounterTrend=true` (ค่า default)**: ปฏิเสธการเข้าไม้ที่ "สวน" เทรนด์ H1/H4 — เช่น จะ BUY ได้ก็ต่อเมื่อ H1/H4 ไม่ได้เป็นขาลง กล่าวคือ **baseline ที่ผ่านการทดสอบดีที่สุดคือเข้าตาม H1/H4 trend เท่านั้น** (ไม่ใช่สวนเทรนด์ใหญ่จริง ๆ)

---

## 8. ตัวกรองสภาพตลาด (Sideway/Volatility)

| ตัวกรอง | เงื่อนไขบล็อก | Default |
|---|---|---|
| ADX (`InpUseADXFilter`) | ADX(14) < `InpADXMinThreshold` | 14.0 |
| Choppiness Index (`InpUseChopFilter`) | CHOP > `InpChopMaxThreshold` | 70.0 |
| ATR Ratio (`InpUseATRFilter`) | ATR(14)/SMA50(ATR14) < `InpATRMinRatio` | 0.95 |
| News session (`InpUseNewsFilter`) | เวลาปัจจุบันอยู่ในช่วง `InpNewsSession` (เช่น "0300-0500:23456") ตาม timezone ที่กำหนด | เปิด |
| Volume Spike (`InpUseVolFilter`) | ปริมาณเทรดแท่งล่าสุด > SMA(20)×`InpVolSpikeMult` (2.2) | เปิด (บล็อกเฉพาะ entry ปกติ, breakout เข้าได้ถ้า `InpBreakoutAllowVolumeSpike`) |

---

## 9. เงื่อนไขการเข้าไม้ (Entry Conditions)

### 9.1 Entry Mode (`InpEntryMode`)
- `DISCOUNT_ONLY` (default, "Original 54% WR"): ใช้แค่ `touched_discount`/`touched_premium`
- `ANY_FVG`: เข้าได้เมื่ออยู่ใน FVG **หรือ** OB **หรือ** touched discount/premium (ความถี่สูงสุด)
- `STRICT_ICT`: ต้องอยู่ใน FVG/OB **และ** อยู่ในโซน Discount/Premium พร้อมกัน (เข้มที่สุด)

### 9.2 เงื่อนไข BUY ปกติ (`normalLongCond`)
ต้องเป็นจริงพร้อมกันทั้งหมด:
`trend==1` · CHoCH ผ่าน (ถ้าบังคับ `InpRequireCHoCH`) · เข้าโซนตาม Entry Mode (`fvg_ob_bull`) · Bullish PA ผ่าน · เหนือ EMA · ผ่านตัวกรอง H1/H4 (`lok`) · ไม่มีโพซิชันอยู่ (`no_pos`) · ไม่ถูก early-exit ปิดไปเมื่อกี้ · ไม่ sideway-blocked/force-close/daily-loss/loss-cooldown · ไม่ถูก news/volume บล็อก

SELL ปกติ (`normalShortCond`) สมมาตรกัน

### 9.3 Confirmed Trend Breakout (ปิดโดย default, `InpUseTrendBreakout`)
`IsConfirmedTrendBreakout`: ยืนยัน breakout เดียวต่อ pivot หนึ่งจุด โดย:
- แท่งแรกที่ทะลุ pivot ต้องมี body ≥ `InpBreakoutMinBodyATR`×ATR (0.50) และปิดใกล้ปลายแท่ง (wick ratio ≤ `InpBreakoutMaxCloseWickRatio`=0.25)
- แท่งถัด ๆ ไปอีก `InpBreakoutConfirmBars` (=2) แท่ง ต้องปิดเลย pivot ต่อเนื่อง (ห้ามหลุดกลับ)
- ราคาปัจจุบันต้องยังไม่ยืดไกลเกิน `InpBreakoutMaxExtensionATR`×ATR (0.75) จาก pivot — กัน chase ไกลเกินไป
- ถ้า `InpBreakoutRequireHTFAlignment=true` ต้องให้ H1/H4 **สอดคล้องทิศทางเดียวกันทั้งคู่** (ไม่ใช่แค่ "ไม่สวน" แบบ entry ปกติ)

เมื่อทั้ง normal และ breakout เป็นจริงพร้อมกัน **breakout จะถูกใช้เป็นหลัก** (`long_entry_is_breakout`) เพื่อกำหนด SL/comment/entry tag

### 9.4 การกำหนด SL/TP ตอนเข้าไม้
- **Fixed SL (default `InpUseFixedSL=true`)**: SL = ราคาเข้า ± `InpFixedSLPips` (10,000 points)
- **Structure-based SL** (เมื่อปิด Fixed SL): ใช้ `swing_low - buffer` (BUY) / `swing_high + buffer` (SELL), หรือถ้าเป็น breakout ใช้ pivot ที่เพิ่งเบรกแทน swing, และถ้ามี OB ที่กว้างกว่าจะขยาย SL ไปถึงขอบ OB นั้น; ถ้า risk เกิน `InpMaxSLPips` จะ cap ไว้
- **TP**: คงที่ที่ `InpTPPips` (37,500 points) จากราคาเข้า
- **Lot**: คงที่ `InpFixedLot` (0.05) ทุกไม้ที่ EA เปิดเอง (ไม่มี position sizing ตาม risk %)
- เข้าได้ทีละ 1 ไม้เท่านั้น (`no_pos` ต้องเป็น true — ไม่ pyramiding)

---

## 10. การจัดการออกจากออเดอร์ (Exit Management)

### 10.1 Early Exit (`ManageEarlyExit`, ปิดแบบ "soft" ก่อนถึง Hard SL จริง)
ทำงานทุกแท่งใหม่ ไล่เช็คทุกโพซิชันที่ EA ถืออยู่ แยกนับ "แท่งแย่ติดต่อกัน" ของฝั่ง BUY/SELL อิสระจากกัน จะปิดไม้เมื่อเข้าเงื่อนไขใดเงื่อนไขหนึ่ง:

1. **Confirmed exit**: มีสัญญาณลบ (`buy_bad_signal`/`sell_bad_signal`) ต่อเนื่องครบ `InpExitConfirmBars` (2) แท่ง โดยสัญญาณลบมาจาก (ตามลำดับความสำคัญของเหตุผลที่รายงาน):
   - **Structure Break** (`InpExitOnStructureBreak`): ราคาปิดหลุด pivot ฝั่งป้องกันของไม้ (เช่น BUY แล้วปิดต่ำกว่า `last_pl`)
   - **CHoCH ตรงข้าม** (`InpExitOnOppositeCHoCH`)
   - **H1/H4 Reversal** (`InpExitOnHTFReversal`, ปิดโดย default) — ต้องกลับทิศพร้อมกันทุก TF ที่เปิดใช้
2. **Risk emergency**: ขาดทุนถึง `InpEarlyExitRiskR` (0.65R) ของ SL เดิม แล้วมีสัญญาณลบ → ปิดทันทีโดยไม่ต้องรอครบ confirm bars
3. **Time Stop** (`InpUseTimeStop`): ถือเกิน `InpTimeStopBars` (20 แท่ง) และยังขาดทุนอยู่ (`profit<=0`) → ปิดทิ้ง

> Hard SL ที่ broker ยังคงอยู่เสมอเป็น safety net สุดท้าย — Early Exit เป็นแค่การปิดไม้ก่อนถึง SL จริงเมื่อโครงสร้างเสียแล้ว

### 10.2 Breakeven & Stepped Trailing Stop (`CheckBEAndTrailing`, ทำงานทุก tick)
ไล่ตาม `MAX_PRICE`/`MIN_PRICE` ที่ราคาเคยไปถึงตั้งแต่เปิดไม้ (เก็บใน Global Variable):

- **Level 1 — Breakeven**: กำไรถึง `InpBEPips` (5,000 pts; หรือ `InpBELowVolPips` ถ้า `InpUseAdaptiveBE` และไม้นี้เปิดตอนวอลุ่มต่ำ) → เลื่อน SL ไปที่ entry + `InpBECostBufferPoints` (200 pts กันค่าคอมมิชชัน)
- **Level 2 — Trailing**: กำไรถึง `InpTrailLevel1Pips` (15,000 pts) → เลื่อน SL ตามราคาแบบ **stepped** (`InpUseSteppedTrail`): ล็อกกำไรเป็นขั้นบันไดทีละ `InpTrailLevel1LockPips` (7,000 pts) แทนการเลื่อนต่อเนื่องทุก tick
- มี guard กันการยิง `PositionModify` ซ้ำไปที่ target เดิมที่เพิ่งถูก broker ปฏิเสธ (`LAST_FAILED_SL`) — ป้องกัน retry วนลูปทุก tick เมื่อ SL ใหม่ยังชิดราคาตลาดเกินไป (invalid stops)

### 10.3 Force Close ตามช่วงเวลา (`InpUseForceClose`, ทุก tick)
ถึงช่วงเวลา `InpForceCloseSession` (default `"0400-0405:23456"` ตาม timezone ที่กำหนด) → ปิดโพซิชันทั้งหมดของ EA ทันที (เช่น ปิดก่อนสิ้นสุด session ตลาด)

### 10.4 Daily Loss Guard / Loss Cooldown
- **Daily Loss Guard**: นับไม้ที่ปิดขาดทุนของ symbol+magic นี้นับจากเที่ยงคืน (timezone ที่กำหนด, รองรับ DST ของ New York) ถ้าครบ `InpMaxDailyLossCount` (3 ไม้) → บล็อกการเปิดไม้ใหม่ทั้งจากกลยุทธ์และจาก webhook จนกว่าจะขึ้นวันใหม่
- **Loss Cooldown**: หลังไม้แพ้ล่าสุดปิดไป จะพักไม่เปิดไม้ใหม่เป็นเวลา `InpLossCooldownMins` (75 นาที)

---

## 11. Webhook Integration (โปรโตคอล ATS, แยกจาก EA1/EA2)

### 11.1 Polling (`OnTimer`, ทุก `InpPollInterval`=37,000 ms)
- ยิง `POST {backend}/api/signals/pending` พร้อม state บัญชี+โพซิชันปัจจุบันเป็น JSON (`GetMT5StateJson`) — เอนด์พอยต์นี้ตอบกลับ `[]` เสมอ (ยังไม่มี remote dispatcher จริง) จึงทำหน้าที่เป็น **heartbeat/snapshot** ไปด้วยในตัว ไม่ใช่แค่ poll สัญญาณ
- ค่า interval 37 วินาทีถูกเลือกให้เป็นค่าที่ "prime-ish" ต่างจาก EA1/EA2 (29s/31s) เพื่อไม่ให้ timer ของทั้ง 3 EA synchron กันแล้วยิง request พร้อมกันจน backend (shared host, `max_user_connections` ต่ำ) รับไม่ไหว
- ปิดการทำงานอัตโนมัติเมื่ออยู่ใน Strategy Tester/Optimization (`IsExternalIntegrationAllowed()`)

### 11.2 การประมวลผลสัญญาณ (`ProcessSignals` → JSON parser มือเขียนเอง)
รับ array ของ signal object ตรวจ schema (`id`/`action`/`status`/`symbol` ต้องครบและสอดคล้องกัน) จากนั้น dispatch ไปที่ `ExecuteBuy` / `ExecuteSell` / `ExecuteClose` ตาม `status` (`PENDING_BUY`/`PENDING_SELL`/`PENDING_CLOSE`)

### 11.3 Idempotency / กันเปิดซ้ำ (`TryClaimSignal` / `CompleteSignalClaim`)
ใช้ Global Variables (คงอยู่ข้าม EA restart) เป็น distributed lock ต่อ `signal_id`:
- Hash `signal_id` (FNV-1a + djb2) เป็น key แทน string ยาว
- Claim สำเร็จ → ดำเนินการเปิด/ปิดไม้ แล้วบันทึกผล (ticket, price, สำเร็จ/ล้มเหลว) ก่อน mark state ว่า "completed" เสมอ — ถ้าโปรแกรม crash ระหว่างนั้น สถานะจะค้างเป็น "in-flight" (fail-closed) ไม่มีทางเปิดไม้ซ้ำโดยไม่ได้ตั้งใจ
- สัญญาณซ้ำ (duplicate webhook delivery) ที่เคยเปิดสำเร็จแล้ว → ตอบ "OPEN" กลับไปเฉย ๆ (replay) ไม่เปิดไม้ใหม่
- ล้าง claim เก่าที่หมดอายุ (`InpSignalDedupDays`=30 วัน) ตอน `OnInit` (`CleanupExpiredSignalClaims`)

### 11.4 การเปิด/ปิดไม้จาก Webhook
- `ExecuteBuy`/`ExecuteSell`: เช็ค Daily Loss Guard + Loss Cooldown ก่อนเสมอ, ตรวจ/ปรับ SL-TP ให้ถูกต้องตาม broker stops level (`PrepareMarketStops`), คำนวณ lot ที่อนุญาตจาก risk cap (`PrepareWebhookVolume`: จำกัดด้วย `InpWebhookMaxLot`=0.05, `InpWebhookMaxRiskPct`=1% ของ equity, spread สูงสุด `InpWebhookMaxSpreadPrice`, จำนวน position สูงสุด `InpWebhookMaxPositions`=1, บังคับต้องมี SL ถ้า `InpWebhookRequireSL`) แล้วส่งผลลัพธ์กลับ backend ผ่าน `UpdateSignalStatus` (`OPEN`/`FAILED`)
- `ExecuteClose`: resolve ตำแหน่งที่จะปิดจาก ticket ที่ระบุ หรือถ้าไม่ระบุ ticket จะหาไม้ที่ EA เป็นเจ้าของเอง (symbol+magic ตรงกัน) — ถ้าเจอมากกว่า 1 ไม้ (`AMBIGUOUS_OWNED_POSITIONS`) จะปฏิเสธ ต้อง revalidate ความเป็นเจ้าของอีกครั้งก่อนยิงปิดจริง (กันเงื่อนไข race)

### 11.5 Sync กลับไป Backend (ทุก tick, `SyncPositionsWithBackend`)
เทียบโพซิชันปัจจุบันกับ `tracked_positions[]`:
- **ไม้ใหม่ที่ไม่เคย track** (เช่น EA เพิ่งเปิดเอง) → เพิ่มเข้า list และส่ง `OPEN` ไป backend (`/api/signals/local`)
- **ไม้ที่หายไปจาก list ปัจจุบัน** (ปิดแล้ว) → ดึงผลจาก history (`GetClosedPositionResult`), คำนวณ MFE/MAE, ระบุ `close_reason` (ให้สิทธิ์ `DEAL_REASON` ของ MT5 เองก่อนเสมอสำหรับ TP/SL/Manual เพราะเป็นข้อมูลจาก broker; ถ้า MT5 บอกแค่ "EXPERT closed" ถึงจะใช้เหตุผลที่ EA บันทึกไว้เอง เช่น "Structure Break", "Bearish CHoCH", "Time Stop", "Force Close (Session End)") → ส่ง `WIN`/`LOSS` ไป backend แล้วลบ analytics state ทิ้ง
- Activity log ของเหตุการณ์โครงสร้าง (Pivot High/Low, CHoCH) ก็ถูกส่งไป `/api/ingest/log` ด้วย (`SendActivityLog`) ให้ขึ้น dashboard เหมือน EA1/EA2 แม้จะคนละ client library

---

## 12. Lifecycle สรุป

- **`OnInit`**: validate input ทั้งหมด (`ValidateInputParameters`) → สร้าง indicator handle (ADX/ATR/EMA ถ้าเปิดใช้) → rebuild สถานะ pivot/CHoCH/BOS/FVG/OB ย้อนหลัง 500 แท่ง (`InitStateFromHistory`) → โหลดโพซิชันที่ถืออยู่เข้า tracking (`InitTrackedPositions`) → ถ้าอนุญาต external integration ตั้ง timer สำหรับ webhook polling
- **`OnTick`** (ทุก tick): sync โพซิชันไป backend → เช็ค BE/Trailing → เช็ค Force Close ตามเวลา → ถ้าเป็นแท่งใหม่ (`IsNewBar`) เรียก `ExecuteStrategyLogic` (pivot/CHoCH/BOS/FVG/OB/entry ทั้งหมดอยู่ในนี้)
- **`OnTimer`** (ทุก 37s, เฉพาะ live/demo ไม่ใช่ tester): poll webhook signal + ส่ง heartbeat state
- **`OnDeinit`**: kill timer, release indicator handles

---

## 13. สรุปพารามิเตอร์สำคัญ (ค่า default ปัจจุบัน)

| กลุ่ม | พารามิเตอร์ | ค่า |
|---|---|---|
| Trade | Magic / Lot / Slippage | 88188 / 0.05 / 20 pts |
| Structure | Pivot length / BOS confirm / CHoCH max age | 4 / 2 แท่ง / 12 แท่ง |
| PD Zone | `InpPDThreshold` | 0.700 (v2.22) / 0.550 (v2.23) / 0.350 (v2.24) |
| Entry mode | `InpEntryMode` | Discount/Premium Only |
| Trend filter | H1/H4 EMA(21), M5 EMA(200), Counter-trend filter | เปิดทั้งหมด |
| SL/TP | Fixed SL / TP | 10,000 pts / 37,500 pts |
| BE/Trailing | BE trigger / Trail trigger / Trail lock | 5,000 / 15,000 / 7,000 pts |
| Risk guard | Daily loss count / Loss cooldown | 3 ไม้ / 75 นาที |
| Sideway filter | ADX min / CHOP max / ATR ratio min | 14 / 70 / 0.95 |
| Webhook risk | Max lot / Max risk% / Max positions | 0.05 / 1.0% / 1 |
| Force close | Session | 04:00–04:05 (Asia/Bangkok) ทุกวัน |
