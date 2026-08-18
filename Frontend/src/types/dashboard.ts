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
  openedAtThai: string;
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
  /** วันที่ปฏิทินของ broker (yyyy-MM-dd) - ใช้เทียบกับ DashboardSnapshot.brokerToday เพื่อกรองตารางตามแท็บช่วงเวลาเท่านั้น อย่าเอาไปแสดงผล */
  closedDateBroker: string;
  /** เวลา broker (ไม่แปลง) - ใช้ bucket session ใน TradeSessionAnalytics.tsx เท่านั้น อย่าเอาไปแสดงผลตรงๆ ใช้ closedAtThai แทน */
  closedAtBroker: string;
  closedAtThai: string;
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
  timeThai: string;
  eaName: string;
  message: string;
  level: "ok" | "info" | "warn" | "error";
}

export interface RiskSnapshot {
  maxDrawdownTodayPct: number;
  maxDrawdown30dPct: number;
  openSlTotal: number;
  openTpTotal: number;
  avgRiskReward: string;
  currentSpreadPts: number;
}

export interface PerformanceRange {
  tradesCount: number;
  winRatePct: number;
  profitFactor: number;
  expectancy: number;
  avgWin: number;
  avgLoss: number;
}

export interface Performance {
  today: PerformanceRange;
  last7d: PerformanceRange;
  last30d: PerformanceRange;
}

export interface DashboardSnapshot {
  connection: ConnectionState;
  lastSyncedAt: string;
  brokerTime: string;
  /** วันที่ปฏิทินของ broker (yyyy-MM-dd) - ใช้เป็นจุดอ้างอิง "วันนี้" เทียบกับ closedDateBroker ของแต่ละ trade */
  brokerToday: string;
  accountInfo: AccountInfo;
  account: AccountSummary;
  equityCurve: EquityPoint[];
  openPositions: Position[];
  closedTrades: ClosedTrade[];
  eaStatuses: EaStatus[];
  risk: RiskSnapshot;
  performance: Performance;
  activityLog: ActivityLogEntry[];
}

export type EaFilter = "all" | string;
