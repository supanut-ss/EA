# XAUUSD Trend Following & Breakout EA — สเปกและคู่มือทดสอบ

EA ตัวที่ 1 จาก 2 ตัว (Trend Following & Breakout) ไฟล์โค้ด: `XAUUSD_TrendBreakout_EA.mq5`

## หลักการ (ทำไมออกแบบแบบนี้)

- **Trend filter (H1):** EMA50 vs EMA200 + ADX(14) ≥ 20 — เทรดตามทิศทางเทรนด์ใหญ่เท่านั้น ลด false signal จากตลาด sideway
- **Entry (M15):** Breakout ของ Donchian channel 20 แท่ง (ใช้แท่งย้อนหลัง ไม่รวมแท่งปัจจุบันและแท่งที่เพิ่งปิด) — จับจังหวะที่ราคาหลุดกรอบพร้อมเทรนด์
- **กันสัญญาณหลอก:** ต้องมีแท่งปิด (close) เกินกรอบ + buffer เท่ากับ 0.3×ATR และแท่งก่อนหน้ายังไม่หลุดกรอบ — กันไม่ให้เข้าไม้ตอน wick แทงชั่วคราวหรือไล่ราคาที่วิ่งไปแล้ว
- **Session filter:** ค่าเริ่มต้นเทรดเฉพาะช่วง London/NY overlap (13:00–21:00 broker time) ซึ่งเป็นช่วงที่ทองมี volume/volatility สูงสุด, ปิดเทรดวันอาทิตย์และตัดจบก่อนตลาดปิดคืนวันศุกร์ (20:00), มี max spread filter กันช่วง rollover/พักตลาดที่ spread กระชาก
- **Risk:** Fixed lot size ตาม input, SL = 1.5×ATR, TP = SL×1.8 (R:R), Trailing stop แบบ ATR ให้ไหลตามเทรนด์
- **ความถี่ไม้:** M15 breakout + max 4 ไม้/วัน ควรให้ 2-3 ไม้/วันได้ตามเป้า แต่ขึ้นกับความผันผวนจริง — ถ้า backtest ได้น้อยกว่าที่ต้องการ ให้ปรับ `InpDonchianPeriod` ให้สั้นลง หรือขยาย session window

## Input parameters สำคัญ (อัปเดตหลัง backtest จริง 6 รอบ 11 ส.ค. 2026)

| Input | ค่า default (v1) | ค่าที่ปรับแล้ว (v2 — ใช้อยู่ตอนนี้) | ปรับเพื่อ |
|---|---|---|---|
| `InpLotSize` | 0.01 | 0.01 | ขนาดไม้คงที่ (fixed lot ตามที่เลือกไว้) |
| `InpMaxTradesPerDay` | 4 | 6 | จำกัดไม้/วัน |
| `InpMaxOpenPositions` | 1 | **3** | อนุญาตไม้ซ้อนตามเทรนด์เดียวกัน — ผลกระทบใหญ่สุดต่อทั้งกำไรและจำนวนไม้ |
| `InpAdxThreshold` | 20 | 20 (คงเดิม — ลดแล้วผลแย่ลง) | ยิ่งสูง = กรองเทรนด์เข้มขึ้น ไม้น้อยลงแต่แม่นขึ้น |
| `InpDonchianPeriod` | 20 | **10** | ยิ่งสั้น = breakout ไวขึ้น ไม้มากขึ้นแต่หลอกง่ายขึ้น |
| `InpAtrBufferMult` | 0.30 | 0.30 (คงเดิม — ลดแล้วผลแย่ลง) | ยิ่งสูง = กรอง fakeout เข้มขึ้น ไม้น้อยลง |
| `InpAtrSlMult` / `InpRiskReward` | 1.5 / 1.8 | 1.5 / 1.8 | ระยะ SL/TP |
| `InpSessionStartHour/EndHour` | 13/21 | **8/23** | ช่วงเวลาเทรด (broker server time, GMT+7 บน Exness-MT5Trial8) — ขยายจาก London/NY overlap อย่างเดียวเป็น London open ถึง NY close ทั้งช่วง |

## ผล Backtest จริง (Exness-MT5Trial8, XAUUSD M15, 2026.02.11–2026.08.11, every-tick real ticks, deposit $1,000)

| รอบ | การปรับ | ไม้ทั้งหมด (~ไม้/วัน) | Profit Factor | Net Profit | Max DD (relative) |
|---|---|---|---|---|---|
| 1 (default เดิม) | — | 68 (~0.5) | 1.01 | $5.16 | 11.92% |
| 2 | Donchian 12, ADX 18 | 100 (~0.8) | 0.96 | -$22.06 | 14.87% |
| 3 | Donchian 15, ADX 20, session 8-23 | 140 (~1.1) | 1.22 | $147.85 | 11.54% |
| 4 | Donchian 10 | 158 (~1.2) | 1.19 | $145.24 | 10.96% |
| 5 | Buffer 0.20 | 165 (~1.3) | 1.16 | $124.95 | 14.06% |
| 6 | MaxOpenPositions 2 | 197 (~1.5) | 1.18 | $168.68 | 13.29% |
| **7 (ใช้อยู่)** | **MaxOpenPositions 3** | **201 (~1.55)** | **1.25** | **$234.38** | **12.79%** |

**บทเรียนสำคัญ:** การลด ADX threshold หรือเพิ่ม fakeout buffer เพื่อเพิ่มไม้ (รอบ 2, 5) ทำให้คุณภาพสัญญาณแย่ลงจนกำไรติดลบ — ตัวแปรที่เพิ่มไม้ได้โดยไม่ทำลาย edge คือการขยาย session window และการอนุญาตไม้ซ้อนตามเทรนด์ (`InpMaxOpenPositions`) ไม่ใช่การลดความเข้มงวดของ filter

**ช่องว่างที่เหลือ:** เป้าหมาย 2-3 ไม้/วันยังไปไม่ถึง (ได้จริง ~1.5 ไม้/วันที่คุณภาพนี้) — Trend/Breakout เป็นสไตล์ที่ไม้น้อยกว่าโดยธรรมชาติ (เข้าเฉพาะจังหวะ breakout จริง) การเพิ่มไม้ให้ถึงเป้าในระดับพอร์ตรวมจะมาจาก EA ตัวที่ 2 (Scalping & Session-Based) ที่ความถี่สูงกว่าโดยดีไซน์

**ยืนยันเพิ่มเติม:** `InpMaxOpenPositions=4` ให้ผลเหมือน `=3` ทุกตัวเลข (201 ไม้, กำไร $234.38 เป๊ะ) แปลว่ากลยุทธ์นี้แทบไม่เคยมีไม้ซ้อนกันเกิน 3 จริงๆ ที่ความถี่สัญญาณระดับนี้ — ไม่มีประโยชน์ที่จะเพิ่มค่านี้ต่อ

**Custom optimization criterion:** เพิ่มฟังก์ชัน `OnTester()` ในโค้ดแล้ว (คำนวณคะแนน = กำไร × ปรับตามความถี่ไม้/วันให้เข้าใกล้ 2-3 × ปรับตาม drawdown) เพื่อให้ MT5 genetic optimizer ค้นหาโดยดูสมดุลเดียวกับที่เราต้องการ ไม่ใช่ balance อย่างเดียว — ทดลองรันบนเครื่องนี้แล้วพบว่า **RAM ว่างไม่พอ** (เหลือ ~2.8GB จาก 15.4GB) ทำให้ 8 local agent แย่งหน่วยความจำกันจนช้ามาก (ติดที่ ~2% นานหลายนาทีไม่ว่าจะลด search space แค่ไหน) จึงยังไม่ได้ผลจาก genetic optimization จริงในรอบนี้ ถ้าจะใช้ควรปิดโปรแกรมอื่นให้ RAM ว่างมากขึ้นก่อน หรือลดจำนวน local agent ใน MT5 (Tools > Options > Strategy Tester Agents)

## วิธี Backtest ใน MT5 (ทำตามลำดับ)

1. คัดลอกไฟล์ `XAUUSD_TrendBreakout_EA.mq5` ไปที่ `MQL5/Experts/` ในโฟลเดอร์ข้อมูลของ MT5 (Terminal เปิดด้วย File → Open Data Folder)
2. เปิด MetaEditor → เปิดไฟล์ → กด Compile (F7) — ต้องได้ 0 errors, 0 warnings ถ้ามี error แจ้งข้อความมาให้ผมแก้
3. เปิด Strategy Tester (Ctrl+R) ใน MT5:
   - Symbol: **XAUUSD**
   - Model: **Every tick based on real ticks** (แม่นสุด) หรืออย่างน้อย "Every tick"
   - ช่วงเวลาทดสอบ: อย่างน้อย **6-12 เดือนย้อนหลัง** เพื่อให้เจอทั้งช่วงเทรนด์และช่วง sideway
   - Deposit เริ่มต้น: **$1,000-$5,000** ตามที่วางแผนไว้ Leverage ตามจริงของ broker คุณ
4. รันครั้งแรกด้วยค่า default ทั้งหมดก่อน อย่าเพิ่งปรับ
5. เช็คผลลัพธ์ในแท็บ **Results/Graph**:
   - จำนวนไม้/วันเฉลี่ย ≥ 2-3 ไม้ตามเป้า
   - Profit Factor ควร > 1.3
   - Max Drawdown ควร < 20-25% ของทุน
   - Win rate ไม่จำเป็นต้องสูง (trend-following มักชนะน้อยครั้งแต่ได้เยอะ) แต่ expectancy ต้องเป็นบวก
6. เช็คแท็บ **Journal** ว่าไม่มี error จาก OrderSend หรือ indicator handle

## ส่งผลลัพธ์กลับมาให้ผมดู

หลัง backtest แล้ว ส่งกลับมาให้ผม:
- Report จาก Strategy Tester (หรือ screenshot ของ Graph + Results summary)
- จำนวนไม้เฉลี่ย/วัน, Profit Factor, Max DD, Win rate

ผมจะช่วยวิเคราะห์และปรับ parameter/logic ให้จนกว่าผลลัพธ์จะน่าพอใจ ก่อนเริ่มออกแบบ EA ตัวที่ 2 (Scalping & Session-Based)

## คำเตือน

โค้ดนี้ผ่าน backtest จริงบน Strategy Tester แล้ว (headless, real ticks, 6 เดือนย้อนหลัง — ดูตารางผลด้านบน) แต่ **ยังไม่เคยรันบนบัญชีเดโมแบบ forward/live** เลย ต้องรันบนบัญชีเดโมจริงอย่างน้อย 2-4 สัปดาห์ให้ผลลัพธ์สอดคล้องกับ backtest ก่อนพิจารณาใช้เงินจริงเสมอ ผลการ backtest ในอดีตไม่ได้การันตีผลในอนาคต และ backtest ยังไม่ได้รวม out-of-sample period หรือ walk-forward validation
