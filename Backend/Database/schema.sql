-- =====================================================================
-- EA Console — MySQL Schema
-- เก็บข้อมูลจาก EA (ผ่าน backend API) เพื่อแสดงผลบน dashboard และ
-- เก็บสถิติย้อนหลังไว้วิเคราะห์ต่อ
--
-- แนวทางการเขียนข้อมูลเข้า: MQL5 เรียก MySQL ตรงๆ ไม่ได้ ให้ EA ยิง
-- WebRequest (HTTP POST) ไปที่ backend C# แล้วให้ backend เป็นคน insert/update
-- ตารางพวกนี้แทน — ดู dashboard_queries.sql สำหรับ query ฝั่งอ่านที่ backend
-- ใช้ตอบ frontend
--
-- ทดสอบไวยากรณ์กับ MySQL 8.0 (ใช้ window function ในบาง view)
-- =====================================================================

CREATE DATABASE IF NOT EXISTS ea_console
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

USE ea_console;

-- ---------------------------------------------------------------------
-- 1) accounts — บัญชี MT5 ที่ติดตาม (ออกแบบให้รองรับหลายบัญชีในอนาคต
--    แม้ตอนนี้จะใช้จริงแค่บัญชีเดียว)
-- ---------------------------------------------------------------------
CREATE TABLE accounts (
  account_id                 INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  mt5_login                  BIGINT UNSIGNED NOT NULL,
  broker_name                VARCHAR(100) NOT NULL,
  server_name                VARCHAR(100) NOT NULL,
  currency                   CHAR(3) NOT NULL DEFAULT 'USD',
  is_demo                    TINYINT(1) NOT NULL DEFAULT 1,
  -- ต่างจาก UTC กี่นาที ใช้แปลง broker time <-> local time บนหน้า dashboard
  -- กันความสับสนที่ spec ของ EA เตือนไว้ (broker time vs local time)
  broker_gmt_offset_minutes  SMALLINT NOT NULL DEFAULT 0,
  created_at                 DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uq_accounts_login_server (mt5_login, server_name)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 2) eas — ทะเบียน EA แต่ละตัวที่ deploy บนบัญชี ระบุตัวตนด้วย magic number
--    (ต้องตั้ง magic number ไม่ซ้ำกันต่อ EA ต่อบัญชีใน MT5)
-- ---------------------------------------------------------------------
CREATE TABLE eas (
  ea_id                 INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  account_id            INT UNSIGNED NOT NULL,
  magic_number           INT UNSIGNED NOT NULL,
  name                  VARCHAR(100) NOT NULL,        -- เช่น 'Trend Breakout'
  symbol                VARCHAR(20) NOT NULL,          -- เช่น 'XAUUSD'
  timeframe             VARCHAR(20) NOT NULL,          -- เช่น 'M15/H1'
  session_start_hour    TINYINT UNSIGNED NULL,         -- broker time
  session_end_hour      TINYINT UNSIGNED NULL,         -- broker time
  max_trades_per_day    TINYINT UNSIGNED NULL,
  status                ENUM('active','standby','error','not_deployed')
                          NOT NULL DEFAULT 'not_deployed',
  deployed_at           DATETIME NULL,
  notes                 VARCHAR(255) NULL,
  created_at            DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at            DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                          ON UPDATE CURRENT_TIMESTAMP,
  CONSTRAINT fk_eas_account FOREIGN KEY (account_id)
    REFERENCES accounts(account_id) ON DELETE CASCADE,
  UNIQUE KEY uq_eas_account_magic (account_id, magic_number)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 3) trades — ticket-based, 1 แถวต่อ 1 position ครอบคลุมทั้งช่วงเปิด-ปิด
--    ใช้ตอบทั้ง "Open Positions" (status='OPEN') และ
--    "Trade History" (status='CLOSED') ด้วยตารางเดียว กัน sync สอง
--    ตารางไม่ตรงกัน — backend UPSERT แถวเดิมด้วย (account_id, mt5_ticket)
--    ทุกครั้งที่ EA รายงานสถานะเข้ามา
-- ---------------------------------------------------------------------
CREATE TABLE trades (
  trade_id            BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  account_id          INT UNSIGNED NOT NULL,
  ea_id               INT UNSIGNED NOT NULL,
  mt5_ticket          BIGINT UNSIGNED NOT NULL,   -- ticket จาก MT5
  symbol              VARCHAR(20) NOT NULL,
  side                ENUM('BUY','SELL') NOT NULL,
  lot                 DECIMAL(10,2) NOT NULL,

  open_price          DECIMAL(18,5) NOT NULL,
  close_price         DECIMAL(18,5) NULL,
  stop_loss           DECIMAL(18,5) NULL,
  take_profit         DECIMAL(18,5) NULL,

  -- ราคาปัจจุบัน/P&L ลอยตัว อัปเดตทุกครั้งที่ EA heartbeat เข้ามา
  -- (มีความหมายเฉพาะตอน status='OPEN' เท่านั้น)
  current_price       DECIMAL(18,5) NULL,
  unrealized_pnl      DECIMAL(14,2) NULL,

  -- มูลค่า SL/TP เป็นเงิน คำนวณฝั่ง MQL5 ด้วย OrderCalcProfit() ตอนเปิดไม้
  -- แล้วส่งมาเก็บตรงๆ (ไม่คำนวณใหม่ใน SQL เพราะสูตร pip value ต่างกันตาม
  -- symbol/contract size — SQL คำนวณเองไม่แม่นเท่า MQL5)
  sl_amount           DECIMAL(14,2) NULL,
  tp_amount           DECIMAL(14,2) NULL,

  open_time_broker    DATETIME NOT NULL,
  close_time_broker   DATETIME NULL,
  status              ENUM('OPEN','CLOSED') NOT NULL DEFAULT 'OPEN',
  pnl                 DECIMAL(14,2) NULL,     -- realized P/L สุดท้าย (NULL จนกว่าจะปิด)
  swap                DECIMAL(14,2) NOT NULL DEFAULT 0,
  commission          DECIMAL(14,2) NOT NULL DEFAULT 0,
  close_reason        ENUM('TP','SL','TRAILING_STOP','MANUAL','EA_LOGIC','OTHER') NULL,

  created_at          DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at          DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                        ON UPDATE CURRENT_TIMESTAMP,

  CONSTRAINT fk_trades_account FOREIGN KEY (account_id)
    REFERENCES accounts(account_id) ON DELETE CASCADE,
  CONSTRAINT fk_trades_ea FOREIGN KEY (ea_id)
    REFERENCES eas(ea_id) ON DELETE CASCADE,
  UNIQUE KEY uq_trades_account_ticket (account_id, mt5_ticket)
) ENGINE=InnoDB;

CREATE INDEX idx_trades_status       ON trades (account_id, status);
CREATE INDEX idx_trades_ea_closed    ON trades (ea_id, close_time_broker);
CREATE INDEX idx_trades_open_time    ON trades (open_time_broker);
CREATE INDEX idx_trades_close_time   ON trades (close_time_broker);

-- ---------------------------------------------------------------------
-- 4) account_snapshots — time series ของ balance/equity/margin
--    สำหรับ equity curve และคำนวณ drawdown — EA/backend ยิงเข้ามาเป็น
--    ระยะ (แนะนำทุก 1-5 นาที ระหว่าง session, หรือทุกครั้งที่มี tick
--    สำคัญ) ยิ่งถี่ยิ่งคำนวณ intraday drawdown ได้แม่นขึ้นแต่ตารางโตเร็วขึ้น
-- ---------------------------------------------------------------------
CREATE TABLE account_snapshots (
  snapshot_id         BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  account_id          INT UNSIGNED NOT NULL,
  captured_at_broker  DATETIME NOT NULL,
  balance             DECIMAL(14,2) NOT NULL,
  equity              DECIMAL(14,2) NOT NULL,
  margin              DECIMAL(14,2) NOT NULL DEFAULT 0,
  free_margin         DECIMAL(14,2) NOT NULL DEFAULT 0,
  margin_level_pct    DECIMAL(9,2) NULL,
  spread_points       INT NULL,
  connection_state    ENUM('connected','disconnected') NOT NULL DEFAULT 'connected',
  created_at          DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_snapshots_account FOREIGN KEY (account_id)
    REFERENCES accounts(account_id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE INDEX idx_snapshots_account_time ON account_snapshots (account_id, captured_at_broker);

-- ---------------------------------------------------------------------
-- 5) activity_log — event/log จาก EA (สัญญาณเข้า, ผ่าน/ไม่ผ่าน filter,
--    error, ข้อความระบบ) ตรงกับ widget "Activity Log" บน dashboard
-- ---------------------------------------------------------------------
CREATE TABLE activity_log (
  log_id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  account_id          INT UNSIGNED NOT NULL,
  ea_id               INT UNSIGNED NULL,        -- NULL = event ระดับระบบ ไม่ผูก EA ตัวใดตัวหนึ่ง
  level               ENUM('ok','info','warn','error') NOT NULL DEFAULT 'info',
  message             VARCHAR(500) NOT NULL,
  event_time_broker   DATETIME NOT NULL,
  created_at          DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_log_account FOREIGN KEY (account_id)
    REFERENCES accounts(account_id) ON DELETE CASCADE,
  CONSTRAINT fk_log_ea FOREIGN KEY (ea_id)
    REFERENCES eas(ea_id) ON DELETE SET NULL
) ENGINE=InnoDB;

CREATE INDEX idx_log_account_time ON activity_log (account_id, event_time_broker DESC);
CREATE INDEX idx_log_level        ON activity_log (level);

-- ---------------------------------------------------------------------
-- 6) daily_performance — rollup สถิติรายวันต่อ EA เก็บไว้ query ย้อนหลัง
--    ยาวๆ ได้เร็ว โดยไม่ต้อง GROUP BY ตาราง trades ทั้งก้อนทุกครั้ง
--    เติมข้อมูลด้วย sp_refresh_daily_performance (ดูท้ายไฟล์)
-- ---------------------------------------------------------------------
CREATE TABLE daily_performance (
  ea_id             INT UNSIGNED NOT NULL,
  trade_date        DATE NOT NULL,
  trades_count      INT UNSIGNED NOT NULL DEFAULT 0,
  win_count         INT UNSIGNED NOT NULL DEFAULT 0,
  loss_count        INT UNSIGNED NOT NULL DEFAULT 0,
  gross_profit      DECIMAL(14,2) NOT NULL DEFAULT 0,
  gross_loss        DECIMAL(14,2) NOT NULL DEFAULT 0,
  net_pnl           DECIMAL(14,2) NOT NULL DEFAULT 0,
  win_rate_pct      DECIMAL(5,2) NOT NULL DEFAULT 0,
  profit_factor     DECIMAL(8,2) NULL,
  PRIMARY KEY (ea_id, trade_date),
  CONSTRAINT fk_daily_ea FOREIGN KEY (ea_id)
    REFERENCES eas(ea_id) ON DELETE CASCADE
) ENGINE=InnoDB;

-- =====================================================================
-- Views — สำหรับ query ที่ backend เรียกบ่อยๆ ตอนตอบ dashboard
-- =====================================================================

-- Open positions พร้อมชื่อ EA — ตรงกับ widget "Open Positions"
CREATE OR REPLACE VIEW v_open_positions AS
SELECT
  t.trade_id, t.account_id, t.ea_id, e.name AS ea_name, t.symbol, t.side, t.lot,
  t.open_price, t.current_price, t.stop_loss, t.take_profit,
  t.unrealized_pnl, t.open_time_broker
FROM trades t
JOIN eas e ON e.ea_id = t.ea_id
WHERE t.status = 'OPEN';

-- สรุปผลงาน all-time ต่อ EA (win rate / profit factor) — ตรงกับ
-- หัวข้อ "Win rate · PF" บน Trade History card
CREATE OR REPLACE VIEW v_ea_performance_summary AS
SELECT
  e.ea_id,
  e.name AS ea_name,
  COUNT(*) AS trades_count,
  SUM(t.pnl > 0) AS win_count,
  SUM(t.pnl <= 0) AS loss_count,
  ROUND(SUM(t.pnl > 0) / COUNT(*) * 100, 2) AS win_rate_pct,
  ROUND(
    SUM(CASE WHEN t.pnl > 0 THEN t.pnl ELSE 0 END) /
    NULLIF(ABS(SUM(CASE WHEN t.pnl < 0 THEN t.pnl ELSE 0 END)), 0)
  , 2) AS profit_factor,
  SUM(t.pnl) AS net_pnl
FROM trades t
JOIN eas e ON e.ea_id = t.ea_id
WHERE t.status = 'CLOSED'
GROUP BY e.ea_id, e.name;

-- Equity curve รายวัน (เอา snapshot ล่าสุดของแต่ละวันมาเป็นจุดกราฟ)
CREATE OR REPLACE VIEW v_equity_curve_daily AS
SELECT account_id, snap_date, equity, balance, captured_at_broker
FROM (
  SELECT
    account_id,
    DATE(captured_at_broker) AS snap_date,
    equity,
    balance,
    captured_at_broker,
    ROW_NUMBER() OVER (
      PARTITION BY account_id, DATE(captured_at_broker)
      ORDER BY captured_at_broker DESC
    ) AS rn
  FROM account_snapshots
) ranked
WHERE rn = 1;

-- =====================================================================
-- Stored procedure + event — เติม daily_performance อัตโนมัติทุกเที่ยงคืน
-- ต้องเปิด event scheduler ก่อน: SET GLOBAL event_scheduler = ON;
--
-- หมายเหตุ: DELIMITER เป็นคำสั่งเฉพาะของ mysql CLI ใช้บอก client ว่า ";"
-- ข้างในตัว procedure ไม่ใช่จุดจบ statement — ถ้ารันผ่าน driver อื่น (เช่น
-- MySqlConnector ใน C#, migration tool) ให้ส่งเนื้อ CREATE PROCEDURE...END
-- เป็น 1 คำสั่งไปตรงๆ โดยไม่ต้องมี DELIMITER เลย
-- =====================================================================
DELIMITER $$

CREATE PROCEDURE sp_refresh_daily_performance(IN p_date DATE)
BEGIN
  REPLACE INTO daily_performance
    (ea_id, trade_date, trades_count, win_count, loss_count,
     gross_profit, gross_loss, net_pnl, win_rate_pct, profit_factor)
  SELECT
    ea_id,
    p_date,
    COUNT(*),
    SUM(pnl > 0),
    SUM(pnl <= 0),
    SUM(CASE WHEN pnl > 0 THEN pnl ELSE 0 END),
    ABS(SUM(CASE WHEN pnl < 0 THEN pnl ELSE 0 END)),
    SUM(pnl),
    ROUND(SUM(pnl > 0) / COUNT(*) * 100, 2),
    ROUND(
      SUM(CASE WHEN pnl > 0 THEN pnl ELSE 0 END) /
      NULLIF(ABS(SUM(CASE WHEN pnl < 0 THEN pnl ELSE 0 END)), 0)
    , 2)
  FROM trades
  WHERE status = 'CLOSED' AND DATE(close_time_broker) = p_date
  GROUP BY ea_id;
END$$

DELIMITER ;

CREATE EVENT IF NOT EXISTS ev_refresh_daily_performance
  ON SCHEDULE EVERY 1 DAY
  STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL 1 DAY + INTERVAL 5 MINUTE)
  DO CALL sp_refresh_daily_performance(CURRENT_DATE - INTERVAL 1 DAY);
