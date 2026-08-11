-- =====================================================================
-- Analysis queries — ไม่ได้ใช้ตอบ dashboard แบบ real-time แต่ไว้ query
-- เองเวลาอยากวิเคราะห์ผลงาน EA ย้อนหลัง (เช่นก่อนตัดสินใจปรับ parameter
-- ตามที่ระบุไว้ใน MQ5/XAUUSD_TrendBreakout_Spec.md)
--
-- ทดสอบได้ทันทีหลังรัน schema.sql + seed_sample_data.sql (ข้อมูลตัวอย่าง
-- มีน้อย บางคำตอบเลยดูไม่มีนัยสำคัญ — ของจริงต้องมีอย่างน้อยหลักสิบ-ร้อยไม้
-- ถึงจะเชื่อถือได้)
-- =====================================================================

USE ea_console;
SET @account_id = 1;

-- ---------------------------------------------------------------------
-- 1) สรุปผลงานรายเดือนต่อ EA — เอาไว้ดูว่าเดือนไหนดี/แย่กว่ากัน
-- ---------------------------------------------------------------------
SELECT
  e.name AS ea_name,
  DATE_FORMAT(t.close_time_broker, '%Y-%m') AS month,
  COUNT(*) AS trades_count,
  SUM(t.pnl > 0) AS win_count,
  ROUND(SUM(t.pnl > 0) / COUNT(*) * 100, 2) AS win_rate_pct,
  ROUND(SUM(t.pnl), 2) AS net_pnl,
  ROUND(
    SUM(CASE WHEN t.pnl > 0 THEN t.pnl ELSE 0 END) /
    NULLIF(ABS(SUM(CASE WHEN t.pnl < 0 THEN t.pnl ELSE 0 END)), 0)
  , 2) AS profit_factor
FROM trades t
JOIN eas e ON e.ea_id = t.ea_id
WHERE t.account_id = @account_id AND t.status = 'CLOSED'
GROUP BY e.name, DATE_FORMAT(t.close_time_broker, '%Y-%m')
ORDER BY month DESC, e.name;

-- ---------------------------------------------------------------------
-- 2) ผลงานแยกตามชั่วโมงที่เปิดไม้ (broker time) — เอาไว้เช็คว่า session
--    filter ปัจจุบัน (13:00-21:00 ตาม spec) ยังเหมาะสมไหม หรือควรขยับ
-- ---------------------------------------------------------------------
SELECT
  HOUR(t.open_time_broker) AS open_hour_broker,
  COUNT(*) AS trades_count,
  ROUND(SUM(t.pnl > 0) / COUNT(*) * 100, 2) AS win_rate_pct,
  ROUND(SUM(t.pnl), 2) AS net_pnl,
  ROUND(AVG(t.pnl), 2) AS avg_pnl_per_trade
FROM trades t
WHERE t.account_id = @account_id AND t.status = 'CLOSED'
GROUP BY HOUR(t.open_time_broker)
ORDER BY open_hour_broker;

-- ---------------------------------------------------------------------
-- 3) กระจายตัวของ Risk:Reward จริงที่ปิดออกมา เทียบกับที่ตั้งไว้ตอนเปิด
--    (ใช้เช็คว่า trailing stop ทำให้ได้ R:R ดีกว่าหรือแย่กว่าที่ตั้งไว้)
-- ---------------------------------------------------------------------
-- หมายเหตุ: "* 100" คือ contract size โดยประมาณของ XAUUSD (100 oz/lot) ใช้
-- แปลงระยะราคาเป็นเงินคร่าวๆ เท่านั้น ถ้าจะใช้กับ symbol อื่นต้องเปลี่ยนตัวคูณ
-- ให้ตรงกับ contract size จริง หรือให้ EA ส่ง realized R-multiple มาคำนวณเอง
-- ฝั่ง MQL5 ด้วย OrderCalcProfit() แทนความแม่นยำจะดีกว่า
SELECT
  t.trade_id, t.mt5_ticket, t.side,
  ROUND(ABS(t.take_profit - t.open_price) / NULLIF(ABS(t.open_price - t.stop_loss), 0), 2) AS planned_rr,
  ROUND(t.pnl / NULLIF(ABS(t.open_price - t.stop_loss) * t.lot * 100, 0), 2) AS realized_r_multiple,
  t.close_reason,
  t.close_time_broker
FROM trades t
WHERE t.account_id = @account_id AND t.status = 'CLOSED'
  AND t.stop_loss IS NOT NULL AND t.take_profit IS NOT NULL
ORDER BY t.close_time_broker DESC;

-- ---------------------------------------------------------------------
-- 4) Consecutive win/loss streak ปัจจุบัน (นับจากไม้ล่าสุดย้อนกลับไป)
--    ใช้เทคนิค "gaps and islands" ด้วย window function แทนตัวแปร
--    session (@var := ...) เพราะ MySQL 8 ไม่การันตีลำดับการ evaluate
--    ตัวแปรใน SELECT ที่มี ORDER BY — ผลลัพธ์อาจผิดแบบเงียบๆ ได้
-- ---------------------------------------------------------------------
WITH ordered AS (
  SELECT
    t.trade_id,
    IF(t.pnl > 0, 1, 0) AS is_win,
    ROW_NUMBER() OVER (ORDER BY t.close_time_broker DESC) AS rn
  FROM trades t
  WHERE t.account_id = @account_id AND t.status = 'CLOSED'
),
grp AS (
  SELECT
    trade_id, is_win, rn,
    rn - ROW_NUMBER() OVER (PARTITION BY is_win ORDER BY rn) AS island_id
  FROM ordered
),
latest AS (
  SELECT is_win, island_id FROM grp WHERE rn = 1
)
SELECT
  IF(g.is_win = 1, 'WIN', 'LOSS') AS streak_type,
  COUNT(*) AS streak_length
FROM grp g
JOIN latest l ON l.is_win = g.is_win AND l.island_id = g.island_id
GROUP BY g.is_win;

-- ---------------------------------------------------------------------
-- 5) ไม้ที่ดีที่สุด / แย่ที่สุด 5 อันดับ
-- ---------------------------------------------------------------------
(SELECT 'BEST' AS category, t.trade_id, t.mt5_ticket, e.name AS ea_name,
        t.side, t.pnl, t.open_time_broker, t.close_time_broker, t.close_reason
 FROM trades t JOIN eas e ON e.ea_id = t.ea_id
 WHERE t.account_id = @account_id AND t.status = 'CLOSED'
 ORDER BY t.pnl DESC LIMIT 5)
UNION ALL
(SELECT 'WORST' AS category, t.trade_id, t.mt5_ticket, e.name AS ea_name,
        t.side, t.pnl, t.open_time_broker, t.close_time_broker, t.close_reason
 FROM trades t JOIN eas e ON e.ea_id = t.ea_id
 WHERE t.account_id = @account_id AND t.status = 'CLOSED'
 ORDER BY t.pnl ASC LIMIT 5);

-- ---------------------------------------------------------------------
-- 6) เหตุผลที่ปิดไม้ แยกตามผลลัพธ์ — เอาไว้เช็คว่า TP/SL/trailing stop
--    ตัวไหนเป็นสัดส่วนหลักของกำไร/ขาดทุนรวม
-- ---------------------------------------------------------------------
SELECT
  close_reason,
  COUNT(*) AS trades_count,
  ROUND(SUM(pnl), 2) AS net_pnl,
  ROUND(AVG(pnl), 2) AS avg_pnl
FROM trades
WHERE account_id = @account_id AND status = 'CLOSED'
GROUP BY close_reason
ORDER BY net_pnl DESC;

-- ---------------------------------------------------------------------
-- 7) Drawdown สูงสุดต่อวัน ย้อนหลัง N วัน — เอาไว้ plot กราฟ DD หรือเช็ค
--    ว่าวันไหนเข้าใกล้ threshold ที่ยอมรับได้ (spec ตั้งเป้า Max DD < 20-25%)
-- ---------------------------------------------------------------------
SELECT snap_date, MIN(dd_pct) AS max_drawdown_pct
FROM (
  SELECT
    DATE(captured_at_broker) AS snap_date,
    equity,
    MAX(equity) OVER (
      PARTITION BY DATE(captured_at_broker) ORDER BY captured_at_broker
    ) AS running_peak,
    ROUND(
      (equity - MAX(equity) OVER (
        PARTITION BY DATE(captured_at_broker) ORDER BY captured_at_broker
      )) / MAX(equity) OVER (
        PARTITION BY DATE(captured_at_broker) ORDER BY captured_at_broker
      ) * 100
    , 2) AS dd_pct
  FROM account_snapshots
  WHERE account_id = @account_id
    AND captured_at_broker >= CURDATE() - INTERVAL 30 DAY
) x
GROUP BY snap_date
ORDER BY snap_date DESC;

-- ---------------------------------------------------------------------
-- 8) เปรียบเทียบผลงานระหว่าง EA (พอมี EA ตัวที่ 2 ใช้งานจริงแล้ว)
-- ---------------------------------------------------------------------
SELECT
  e.name AS ea_name,
  p.trades_count, p.win_rate_pct, p.profit_factor, p.net_pnl
FROM v_ea_performance_summary p
JOIN eas e ON e.ea_id = p.ea_id
WHERE e.account_id = @account_id
ORDER BY p.net_pnl DESC;
