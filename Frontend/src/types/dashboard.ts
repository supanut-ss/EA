export type ConnectionState = "connected" | "disconnected";

export type EaRuntimeState = "active" | "standby" | "error" | "not_deployed";

export interface AccountInfo {
  accountId: number;
  mt5Login: number;
  brokerName: string;
  isDemo: boolean;
}

// One row in the account picker (GET /api/dashboard/accounts) - every
// registered account, not just the one currently being viewed.
export interface AccountListItem {
  accountId: number;
  mt5Login: number;
  brokerName: string;
  serverName: string;
  isDemo: boolean;
}

export interface AccountSummary {
  balance: number;
  equity: number;
  floatingPnl: number;
  todayRealizedPnl: number;
  todayClosedCount: number;
  marginLevelPct: number;
  freeMargin: number;
  tradesToday: number;
  maxTradesPerDay: number;
}

export interface Position {
  id: string;
  eaId: string;
  eaName: string;
  symbol: string;
  side: "BUY" | "SELL";
  lot: number;
  openPrice: number;
  currentPrice: number;
  stopLoss: number;
  takeProfit: number;
  pnl: number;
  openedAtBroker: string;
}

export interface ClosedTrade {
  id: string;
  eaId: string;
  eaName: string;
  symbol: string;
  side: "BUY" | "SELL";
  lot: number;
  openPrice: number;
  closePrice: number;
  pnl: number;
  closedAtBroker: string;
  closeReason: string;
}

export interface EaStatus {
  id: string;
  name: string;
  symbol: string;
  timeframe: string;
  state: EaRuntimeState;
  sessionWindow: string;
  lastSignal: string;
  tradesToday: number;
  maxTradesPerDay: number;
  note?: string;
}

export interface EquityPoint {
  label: string;
  equity: number;
  balance: number;
}

export interface ActivityLogEntry {
  id: string;
  timeBroker: string;
  eaName: string;
  message: string;
  level: "ok" | "info" | "warn" | "error";
}

export interface RiskSnapshot {
  maxDrawdownTodayPct: number;
  openSlTotal: number;
  openTpTotal: number;
  avgRiskReward: string;
  currentSpreadPts: number;
}

export interface DashboardSnapshot {
  connection: ConnectionState;
  lastSyncedAt: string;
  brokerTime: string;
  localTime: string;
  accountInfo: AccountInfo;
  account: AccountSummary;
  equityCurve: EquityPoint[];
  openPositions: Position[];
  closedTrades: ClosedTrade[];
  eaStatuses: EaStatus[];
  risk: RiskSnapshot;
  activityLog: ActivityLogEntry[];
}

export type EaFilter = "all" | string;
