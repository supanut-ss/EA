-- Register Counter Trend (EA3) under the DEMO account so a demo instance can
-- report as itself instead of writing into the live account's data.
--
-- Background: an eas row belongs to exactly one account (schema.sql,
-- fk_eas_account), and DashboardQueryService.BuildEaStatusesAsync lists EAs
-- with `WHERE account_id = @account` then filters trades to that account's
-- ea_ids. So EA3's existing row (ea_id=3, account_id=2, the live
-- Exness-MT5Real8 port) cannot be reused from the demo port - trades and logs
-- sent under account_id=1 with ea_id=3 are silently dropped from every per-EA
-- view on the dashboard.
--
-- Accounts as registered on 2026-08-28 (GET /api/dashboard/accounts):
--   account_id=1  login 279661518  Exness-MT5Trial8  is_demo=1   <- demo
--   account_id=2  login 411757774  Exness-MT5Real8   is_demo=0   <- live
--
-- Run this once against the production DB, then set the new ea_id as
-- InpBackendEaId on the demo instance (InpBackendAccountId = 1).

INSERT INTO eas (account_id, magic_number, name, symbol, timeframe,
                 session_start_hour, session_end_hour, max_trades_per_day,
                 status, notes)
VALUES (1, 88188, 'Counter Trend (Demo)', 'XAUUSD', 'M15',
        NULL, NULL, NULL,
        'active', 'EA3 on the demo port - see add_ea3_to_demo_account.sql');

-- The new ea_id is auto-assigned. Read it back and use it for InpBackendEaId:
SELECT ea_id, account_id, magic_number, name
FROM eas
WHERE account_id = 1
ORDER BY ea_id;
