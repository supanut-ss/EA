-- Clears all trading log data so counters/history start from zero again.
-- Keeps `accounts` and `eas` (master data) intact.
-- Run against the production database, e.g.:
--   mysql -u thaipes_sa -p thaipes_ea < clear_trade_logs.sql

USE thaipes_ea;

SET FOREIGN_KEY_CHECKS = 0;

TRUNCATE TABLE trades;
TRUNCATE TABLE daily_performance;
TRUNCATE TABLE account_snapshots;
TRUNCATE TABLE activity_log;

SET FOREIGN_KEY_CHECKS = 1;
