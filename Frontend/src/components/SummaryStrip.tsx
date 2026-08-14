import Box from "@mui/material/Box";
import Paper from "@mui/material/Paper";
import Typography from "@mui/material/Typography";
import type { AccountSummary, RiskSnapshot } from "../types/dashboard";
import { numericSx } from "../theme";
import { formatUsd } from "../utils/format";

interface SummaryStripProps {
  account: AccountSummary;
  risk: RiskSnapshot;
  openPositionsCount: number;
  totalLots: number;
  eaActiveCount: number;
  eaTotalCount: number;
}

interface StatCellProps {
  label: string;
  value: string;
  delta: string;
  deltaColor?: string;
}

function StatCell({ label, value, delta, deltaColor = "text.secondary" }: StatCellProps) {
  return (
    <Box sx={{ bgcolor: "background.paper", p: "8px 12px", minWidth: 0 }}>
      <Typography
        variant="caption"
        sx={{
          display: "block",
          textTransform: "uppercase",
          letterSpacing: "0.06em",
          color: "text.disabled",
          fontWeight: 600,
          mb: 0.25,
          fontSize: 9.5,
        }}
      >
        {label}
      </Typography>
      <Typography sx={{ ...numericSx, fontSize: 15, fontWeight: 700, letterSpacing: "-0.01em" }}>
        {value}
      </Typography>
      <Typography variant="caption" sx={{ ...numericSx, color: deltaColor, fontSize: 10 }}>
        {delta}
      </Typography>
    </Box>
  );
}

// เกณฑ์สีตาม doc: DD < 5% ปกติ, 5-10% ระวัง, > 10% เสี่ยงสูง
function ddColor(pct: number): string {
  const abs = Math.abs(pct);
  if (abs > 10) return "error.main";
  if (abs >= 5) return "warning.main";
  return "success.main";
}

// 8 ตัวชี้วัดหลักตาม doc requirements (หัวข้อ "โครงสร้างหน้าจอที่แนะนำ" ->
// หน้า Overview) - ทุกค่ามาจากข้อมูลที่มีอยู่แล้วใน DashboardSnapshot ไม่มี
// field ใหม่จาก backend เพิ่ม (ยกเว้น maxDrawdown30dPct ที่เพิ่มเข้า risk)
export default function SummaryStrip({
  account,
  risk,
  openPositionsCount,
  totalLots,
  eaActiveCount,
  eaTotalCount,
}: SummaryStripProps) {
  const todayPnl = account.floatingPnl + account.todayRealizedPnl;

  return (
    <Paper variant="outlined" sx={{ overflow: "hidden" }}>
      <Box
        sx={{
          display: "grid",
          gridTemplateColumns: { xs: "repeat(2, 1fr)", sm: "repeat(4, 1fr)", md: "repeat(8, 1fr)" },
          gap: "1px",
          bgcolor: "divider",
        }}
      >
        <StatCell label="Equity" value={formatUsd(account.equity)} delta="Balance base" />
        <StatCell
          label="Today P/L"
          value={formatUsd(todayPnl, true)}
          delta={`Realized ${formatUsd(account.todayRealizedPnl, true)}`}
          deltaColor={todayPnl >= 0 ? "success.main" : "error.main"}
        />
        <StatCell
          label="Current DD"
          value={`${risk.maxDrawdownTodayPct}%`}
          delta="วันนี้"
          deltaColor={ddColor(risk.maxDrawdownTodayPct)}
        />
        <StatCell
          label="Max DD"
          value={`${risk.maxDrawdown30dPct}%`}
          delta="30 วัน"
          deltaColor={ddColor(risk.maxDrawdown30dPct)}
        />
        <StatCell label="Open Positions" value={`${openPositionsCount}`} delta="ไม้ที่เปิดอยู่" />
        <StatCell label="Total Lots" value={totalLots.toFixed(2)} delta="รวมทุกไม้" />
        <StatCell
          label="EA Status"
          value={`${eaActiveCount}/${eaTotalCount}`}
          delta="Active"
          deltaColor={eaActiveCount > 0 ? "success.main" : "text.secondary"}
        />
        <StatCell label="Spread" value={`${risk.currentSpreadPts} pt`} delta="XAUUSD" />
      </Box>
    </Paper>
  );
}
