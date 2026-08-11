-- =====================================================================
-- Dashboard queries — 1 query ต่อ 1 widget บน Frontend
-- (Frontend/src/components/*.tsx) ให้ backend (C#) เรียกตรงๆ แล้ว map
-- ผลลัพธ์เป็น DashboardSnapshot (Frontend/src/types/dashboard.ts)
--
-- ใช้ @account_id แทน parameter — ฝั่ง backend ให้ผูกเป็น parameter จริง
-- (เช่น Dapper: @AccountId) อย่า string-concat ค่าที่รับจาก request เข้า
-- SQL ตรงๆ เพราะเสี่ยง SQL injection
--
-- ทดสอบได้ทันทีหลังรัน schema.sql + seed_sample_data.sql
-- =====================================================================

USE ea_console;
SET @account_id = 1;

-- ---------------------------------------------------------------------
-- 1) SummaryStrip — balance/equity/floating P&L/today realized/margin/
--    trades วันนี้ (Frontend/src/components/SummaryStrip.tsx)
-- ---------------------------------------------------------------------
SELECT
  s.balance,
  s.equity,
  ROUND(s.equity - s.balance, 2)                              AS floating_pnl,
  s.margin_level_pct,
  s.free_margin,
  (SELECT COUNT(*) FROM trades t
     WHERE t.account_id = @account_id AND t.status = 'OPEN')  AS open_positions_count,
  (SELECT COALESCE(SUM(t.pnl), 0) FROM trades t
     WHERE t.account_id = @account_id AND t.status = 'CLOSED'
       AND DATE(t.close_time_broker) = CURDATE())             AS today_realized_pnl,
  (SELECT COUNT(*) FROM trades t
     WHERE t.account_id = @account_id AND t.status = 'CLOSED'
       AND DATE(t.close_time_broker) = CURDATE())             AS today_closed_count,
  (SELECT COUNT(*) FROM trades t
     WHERE t.account_id = @account_id
       AND DATE(t.open_time_broker) = CURDATE())               AS trades_today,
  -- หมายเหตุ: ใช้ MAX() เพราะตอนนี้มี EA active พร้อมกันแค่ตัวเดียว พอมี
  -- หลาย EA active พร้อมกันจริงและแต่ละตัว max_trades_per_day ไม่เท่ากัน
  -- เลขนี้จะกำกวม — ให้เปลี่ยนไป SUM() แทนถ้าอยากได้ "โควตารวมทั้งบัญชี"
  (SELECT COALESCE(MAX(max_trades_per_day), 0) FROM eas
     WHERE account_id = @account_id AND status != 'not_deployed') AS max_trades_per_day,
  s.captured_at_broker AS last_synced_at
FROM account_snapshots s
WHERE s.account_id = @account_id
ORDER BY s.captured_at_broker DESC
LIMIT 1;

-- ---------------------------------------------------------------------
-- 2) OpenPositionsCard (Frontend/src/components/OpenPositionsCard.tsx)
--    เติม WHERE ea_id = ? ต่อท้ายได้เวลา frontend กด filter เลือก EA เดียว
-- ---------------------------------------------------------------------
SELECT trade_id, ea_id, ea_name, symbol, side, lot,
       open_price, current_price, stop_loss, take_profit,
       unrealized_pnl, open_time_broker
FROM v_open_positions
WHERE account_id = @account_id
ORDER BY open_time_broker DESC;

-- ---------------------------------------------------------------------
-- 3) TradeHistoryCard (Frontend/src/components/TradeHistoryCard.tsx)
--    ตัวอย่างช่วง "วันนี้" — เปลี่ยน INTERVAL ตามแท็บที่กด (7 วัน/30 วัน)
-- ---------------------------------------------------------------------
SELECT t.trade_id, t.ea_id, e.name AS ea_name, t.symbol, t.side, t.lot,
       t.open_price, t.close_price, t.pnl, t.close_time_broker, t.close_reason
FROM trades t
JOIN eas e ON e.ea_id = t.ea_id
WHERE t.account_id = @account_id
  AND t.status = 'CLOSED'
  AND t.close_time_broker >= CURDATE()                 -- วันนี้
  -- AND t.close_time_broker >= CURDATE() - INTERVAL 7 DAY   -- 7 วัน
  -- AND t.close_time_broker >= CURDATE() - INTERVAL 30 DAY  -- 30 วัน
ORDER BY t.close_time_broker DESC;

-- Win rate / Profit factor ที่โชว์บนหัว TradeHistoryCard (all-time ต่อบัญชี)
SELECT
  ROUND(SUM(win_count) / SUM(trades_count) * 100, 2) AS win_rate_pct,
  ROUND(
    SUM(gross_profit) / NULLIF(SUM(gross_loss), 0)
  , 2) AS profit_factor
FROM (
  SELECT p.win_count, p.trades_count, p.gross_profit, p.gross_loss
  FROM v_ea_performance_summary p
  JOIN eas e ON e.ea_id = p.ea_id
  WHERE e.account_id = @account_id
) x;

-- ---------------------------------------------------------------------
-- 4) EaStatusPanel (Frontend/src/components/EaStatusPanel.tsx)
-- ---------------------------------------------------------------------
SELECT
  e.ea_id, e.name, e.symbol, e.timeframe, e.status,
  e.session_start_hour, e.session_end_hour, e.max_trades_per_day, e.notes,
  (SELECT COUNT(*) FROM trades t
     WHERE t.ea_id = e.ea_id AND DATE(t.open_time_broker) = CURDATE()) AS trades_today,
  (SELECT al.message FROM activity_log al
     WHERE al.ea_id = e.ea_id AND al.level IN ('ok','info')
     ORDER BY al.event_time_broker DESC LIMIT 1) AS last_signal
FROM eas e
WHERE e.account_id = @account_id
ORDER BY e.ea_id;

-- ---------------------------------------------------------------------
-- 5) RiskSnapshotCard (Frontend/src/components/RiskSnapshotCard.tsx)
-- ---------------------------------------------------------------------

-- Max drawdown วันนี้ (ใช้ running-peak เทียบ equity ปัจจุบัน ไม่ใช่แค่
-- max/min ทั้งวัน เพราะจุดต่ำสุดอาจเกิดก่อนจุดสูงสุดก็ได้)
SELECT MIN(dd_pct) AS max_drawdown_today_pct
FROM (
  SELECT
    equity,
    MAX(equity) OVER (ORDER BY captured_at_broker) AS running_peak,
    ROUND(
      (equity - MAX(equity) OVER (ORDER BY captured_at_broker))
      / MAX(equity) OVER (ORDER BY captured_at_broker) * 100
    , 2) AS dd_pct
  FROM account_snapshots
  WHERE account_id = @account_id AND DATE(captured_at_broker) = CURDATE()
) x;

-- SL/TP รวมของไม้ที่เปิดอยู่ (เป็นเงิน) — มาจากคอลัมน์ sl_amount/tp_amount
-- ที่ EA คำนวณด้วย OrderCalcProfit() ตอนเปิดไม้ ไม่ได้คำนวณใหม่ใน SQL
SELECT
  COALESCE(SUM(sl_amount), 0) AS open_sl_total,
  COALESCE(SUM(tp_amount), 0) AS open_tp_total
FROM trades
WHERE account_id = @account_id AND status = 'OPEN';

-- Average Risk:Reward ของไม้ที่ปิดแล้วใน 30 วันล่าสุด
SELECT ROUND(AVG(
  ABS(take_profit - open_price) / NULLIF(ABS(open_price - stop_loss), 0)
), 2) AS avg_risk_reward
FROM trades
WHERE account_id = @account_id
  AND status = 'CLOSED'
  AND stop_loss IS NOT NULL AND take_profit IS NOT NULL
  AND close_time_broker >= NOW() - INTERVAL 30 DAY;

-- Spread ปัจจุบัน (จาก snapshot ล่าสุด)
SELECT spread_points AS current_spread_pts
FROM account_snapshots
WHERE account_id = @account_id
ORDER BY captured_at_broker DESC
LIMIT 1;

-- ---------------------------------------------------------------------
-- 6) ActivityLogCard (Frontend/src/components/ActivityLogCard.tsx)
-- ---------------------------------------------------------------------
SELECT al.log_id, al.event_time_broker, COALESCE(e.name, 'System') AS ea_name,
       al.level, al.message
FROM activity_log al
LEFT JOIN eas e ON e.ea_id = al.ea_id
WHERE al.account_id = @account_id
ORDER BY al.event_time_broker DESC
LIMIT 20;

-- ---------------------------------------------------------------------
-- 7) EquityCurveCard (Frontend/src/components/EquityCurveCard.tsx)
--    30 วันล่าสุด จุดละ 1 วัน (snapshot ท้ายวัน)
-- ---------------------------------------------------------------------
SELECT snap_date, equity, balance
FROM v_equity_curve_daily
WHERE account_id = @account_id
  AND snap_date >= CURDATE() - INTERVAL 30 DAY
ORDER BY snap_date ASC;

-- ---------------------------------------------------------------------
-- 8) StatusBanners / connection state (Frontend/src/components/StatusBanners.tsx)
--    "disconnected" ถ้า snapshot ล่าสุดเก่ากว่า threshold ที่ backend ตั้งไว้
--    (เช่น ไม่มี heartbeat เข้ามาเกิน 2 นาที) — ฝั่ง backend เป็นคนตัดสิน
--    เวลาจริง query นี้แค่ให้ข้อมูลดิบ
-- ---------------------------------------------------------------------
SELECT
  captured_at_broker,
  TIMESTAMPDIFF(SECOND, captured_at_broker, UTC_TIMESTAMP()) AS seconds_since_last_snapshot
FROM account_snapshots
WHERE account_id = @account_id
ORDER BY captured_at_broker DESC
LIMIT 1;
