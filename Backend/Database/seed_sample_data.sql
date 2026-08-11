-- =====================================================================
-- Sample data — ตรงกับ mock data ที่ใช้ใน Frontend (src/data/mockData.ts)
-- รันไฟล์นี้ต่อจาก schema.sql เพื่อทดสอบ query ใน dashboard_queries.sql
-- และ analysis_queries.sql ได้ทันที โดยไม่ต้องรอ backend/EA จริง
-- =====================================================================

USE ea_console;

INSERT INTO accounts (account_id, mt5_login, broker_name, server_name, currency, is_demo, broker_gmt_offset_minutes)
VALUES (1, 51234789, 'XM Global', 'XMGlobal-Demo', 'USD', 1, 120);

INSERT INTO eas (ea_id, account_id, magic_number, name, symbol, timeframe,
                  session_start_hour, session_end_hour, max_trades_per_day, status, deployed_at)
VALUES
  (1, 1, 100001, 'Trend Breakout', 'XAUUSD', 'M15/H1', 13, 21, 4, 'active', '2026-07-01 00:00:00'),
  (2, 1, 100002, 'Scalping & Session', 'XAUUSD', 'M1/M5', NULL, NULL, NULL, 'not_deployed', NULL);

UPDATE eas SET notes = 'รอผล backtest ของ EA ตัวที่ 1 ให้น่าพอใจก่อน จึงจะเริ่มออกแบบตัวที่สอง'
WHERE ea_id = 2;

-- Open positions (status = OPEN, close_* เป็น NULL)
INSERT INTO trades (account_id, ea_id, mt5_ticket, symbol, side, lot,
                     open_price, current_price, stop_loss, take_profit,
                     sl_amount, tp_amount, open_time_broker, status)
VALUES
  (1, 1, 900001, 'XAUUSD', 'BUY', 0.01, 2415.30, 2419.85, 2408.10, 2428.65,
   -7.20, 13.35, CONCAT(CURDATE(), ' 14:32:00'), 'OPEN'),
  (1, 1, 900002, 'XAUUSD', 'BUY', 0.01, 2412.90, 2419.85, 2405.70, 2426.25,
   -7.20, 13.35, CONCAT(CURDATE(), ' 13:58:00'), 'OPEN');

-- unrealized_pnl คำนวณแยกเพราะขึ้นกับ current_price ที่เปลี่ยนตลอด
UPDATE trades SET unrealized_pnl = 4.55 WHERE mt5_ticket = 900001;
UPDATE trades SET unrealized_pnl = 6.95 WHERE mt5_ticket = 900002;

-- Closed trades วันนี้ (status = CLOSED)
INSERT INTO trades (account_id, ea_id, mt5_ticket, symbol, side, lot,
                     open_price, close_price, pnl, open_time_broker, close_time_broker,
                     status, close_reason)
VALUES
  (1, 1, 900003, 'XAUUSD', 'SELL', 0.01, 2421.40, 2417.10, 4.30,
   CONCAT(CURDATE(), ' 10:40:00'), CONCAT(CURDATE(), ' 11:20:00'), 'CLOSED', 'TRAILING_STOP'),
  (1, 1, 900004, 'XAUUSD', 'BUY', 0.01, 2408.75, 2406.90, -1.85,
   CONCAT(CURDATE(), ' 09:30:00'), CONCAT(CURDATE(), ' 10:05:00'), 'CLOSED', 'SL'),
  (1, 1, 900005, 'XAUUSD', 'BUY', 0.01, 2402.15, 2408.10, 5.95,
   CONCAT(CURDATE(), ' 08:50:00'), CONCAT(CURDATE(), ' 09:12:00'), 'CLOSED', 'TP');

-- Account snapshots — 11 วันย้อนหลัง (คนละจุดต่อวัน) สำหรับ equity curve
INSERT INTO account_snapshots (account_id, captured_at_broker, balance, equity, margin, free_margin, margin_level_pct, spread_points)
VALUES
  (1, CONCAT(CURDATE() - INTERVAL 10 DAY, ' 20:00:00'), 5000, 5000.00, 30, 4970.00, 16667, 18),
  (1, CONCAT(CURDATE() - INTERVAL 9  DAY, ' 20:00:00'), 5000, 5012.00, 30, 4982.00, 16707, 17),
  (1, CONCAT(CURDATE() - INTERVAL 8  DAY, ' 20:00:00'), 5000, 5008.00, 30, 4978.00, 16693, 19),
  (1, CONCAT(CURDATE() - INTERVAL 7  DAY, ' 20:00:00'), 5000, 5030.00, 30, 5000.00, 16767, 18),
  (1, CONCAT(CURDATE() - INTERVAL 6  DAY, ' 20:00:00'), 5000, 5055.00, 30, 5025.00, 16850, 16),
  (1, CONCAT(CURDATE() - INTERVAL 5  DAY, ' 20:00:00'), 5000, 5040.00, 30, 5010.00, 16800, 18),
  (1, CONCAT(CURDATE() - INTERVAL 4  DAY, ' 20:00:00'), 5000, 5070.00, 30, 5040.00, 16900, 17),
  (1, CONCAT(CURDATE() - INTERVAL 3  DAY, ' 20:00:00'), 5000, 5095.00, 30, 5065.00, 16983, 18),
  (1, CONCAT(CURDATE() - INTERVAL 2  DAY, ' 20:00:00'), 5000, 5080.00, 30, 5050.00, 16933, 19),
  (1, CONCAT(CURDATE() - INTERVAL 1  DAY, ' 20:00:00'), 5000, 5115.00, 30, 5085.00, 17050, 17),
  (1, CONCAT(CURDATE(),                  ' 14:02:11'), 5000, 5142.30, 60, 5081.60, 8421, 18);

-- Activity log วันนี้
INSERT INTO activity_log (account_id, ea_id, level, message, event_time_broker)
VALUES
  (1, 1, 'ok',   'เปิดไม้ BUY 0.01 XAUUSD @2412.90', CONCAT(CURDATE(), ' 13:58:00')),
  (1, 1, 'info', 'ผ่าน session filter (spread 18pt < max 35pt)', CONCAT(CURDATE(), ' 13:45:00')),
  (1, 1, 'ok',   'ปิดไม้ด้วย trailing stop +$4.30', CONCAT(CURDATE(), ' 11:20:00')),
  (1, 1, 'warn', 'ข้ามสัญญาณ — ADX 17.2 ต่ำกว่าเกณฑ์ 20', CONCAT(CURDATE(), ' 09:02:00')),
  (1, NULL, 'info', 'เริ่มวันใหม่ รีเซ็ตตัวนับไม้/วัน', CONCAT(CURDATE(), ' 00:01:00'));
