import Card from "@mui/material/Card";
import CardContent from "@mui/material/CardContent";
import Chip from "@mui/material/Chip";
import Stack from "@mui/material/Stack";
import Typography from "@mui/material/Typography";
import type { AccountSummary, RiskSnapshot } from "../types/dashboard";
import { numericSx } from "../theme";
import { formatUsd } from "../utils/format";

interface RiskSnapshotCardProps {
  risk: RiskSnapshot;
  account: AccountSummary;
}

type RiskLevel = "LOW" | "MEDIUM" | "HIGH" | "CRITICAL";

// เกณฑ์เดียวกับ SummaryStrip: DD < 5% ปกติ, 5-10% ระวัง, > 10% เสี่ยงสูง
// (เพิ่ม CRITICAL ที่ > 15% เอง เพราะ doc ระบุแค่ 3 ระดับ)
function riskLevel(ddTodayPct: number): RiskLevel {
  const abs = Math.abs(ddTodayPct);
  if (abs > 15) return "CRITICAL";
  if (abs > 10) return "HIGH";
  if (abs >= 5) return "MEDIUM";
  return "LOW";
}

const RISK_LEVEL_COLOR: Record<RiskLevel, "success" | "warning" | "error"> = {
  LOW: "success",
  MEDIUM: "warning",
  HIGH: "error",
  CRITICAL: "error",
};

export default function RiskSnapshotCard({ risk, account }: RiskSnapshotCardProps) {
  const level = riskLevel(risk.maxDrawdownTodayPct);

  const rows: { label: string; value: string; color?: string }[] = [
    { label: "Max Drawdown (วันนี้)", value: `${risk.maxDrawdownTodayPct}%` },
    { label: "Max Drawdown (30 วัน)", value: `${risk.maxDrawdown30dPct}%` },
    { label: "Margin Level", value: `${account.marginLevelPct}%` },
    { label: "Free Margin", value: formatUsd(account.freeMargin) },
    { label: "SL รวม (open)", value: formatUsd(risk.openSlTotal, true), color: "error.main" },
    { label: "TP รวม (open)", value: formatUsd(risk.openTpTotal, true), color: "success.main" },
    { label: "Avg R:R (30 วัน)", value: risk.avgRiskReward },
    { label: "Spread ปัจจุบัน", value: `${risk.currentSpreadPts} pt` },
  ];

  return (
    <Card>
      <CardContent sx={{ pb: "8px !important" }}>
        <Stack direction="row" justifyContent="space-between" alignItems="center" mb={0.75}>
          <Typography variant="subtitle1" fontWeight={700}>
            Risk Monitor
          </Typography>
          <Chip
            size="small"
            label={level}
            color={RISK_LEVEL_COLOR[level]}
            variant={level === "CRITICAL" ? "filled" : "outlined"}
            sx={{ fontWeight: 700, letterSpacing: "0.04em", fontSize: 10.5 }}
          />
        </Stack>
        <Stack>
          {rows.map((row, i) => (
            <Stack
              key={row.label}
              direction="row"
              justifyContent="space-between"
              alignItems="center"
              sx={{
                py: 0.75,
                borderBottom: i < rows.length - 1 ? "1px dashed" : "none",
                borderColor: "divider",
              }}
            >
              <Typography variant="caption" color="text.secondary">
                {row.label}
              </Typography>
              <Typography
                variant="body2"
                fontWeight={600}
                sx={{ ...numericSx, color: row.color ?? "text.primary" }}
              >
                {row.value}
              </Typography>
            </Stack>
          ))}
        </Stack>
      </CardContent>
    </Card>
  );
}
