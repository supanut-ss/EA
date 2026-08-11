import Card from "@mui/material/Card";
import CardContent from "@mui/material/CardContent";
import Stack from "@mui/material/Stack";
import Typography from "@mui/material/Typography";
import type { RiskSnapshot } from "../types/dashboard";
import { numericSx } from "../theme";
import { formatUsd } from "../utils/format";

interface RiskSnapshotCardProps {
  risk: RiskSnapshot;
}

export default function RiskSnapshotCard({ risk }: RiskSnapshotCardProps) {
  const rows: { label: string; value: string; color?: string }[] = [
    { label: "Max Drawdown (วันนี้)", value: `${risk.maxDrawdownTodayPct}%` },
    { label: "SL รวม (open)", value: formatUsd(risk.openSlTotal, true), color: "error.main" },
    { label: "TP รวม (open)", value: formatUsd(risk.openTpTotal, true), color: "success.main" },
    { label: "Avg R:R (30 วัน)", value: risk.avgRiskReward },
    { label: "Spread ปัจจุบัน", value: `${risk.currentSpreadPts} pt` },
  ];

  return (
    <Card>
      <CardContent sx={{ pb: "12px !important" }}>
        <Typography variant="subtitle1" fontWeight={700} mb={0.5}>
          Risk Snapshot
        </Typography>
        <Stack>
          {rows.map((row, i) => (
            <Stack
              key={row.label}
              direction="row"
              justifyContent="space-between"
              alignItems="center"
              sx={{
                py: 1,
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
