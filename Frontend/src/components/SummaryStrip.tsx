import Box from "@mui/material/Box";
import Paper from "@mui/material/Paper";
import Typography from "@mui/material/Typography";
import type { AccountSummary } from "../types/dashboard";
import { numericSx } from "../theme";
import { formatUsd } from "../utils/format";

interface SummaryStripProps {
  account: AccountSummary;
}

interface StatCellProps {
  label: string;
  value: string;
  delta: string;
  deltaColor?: "success.main" | "text.secondary";
}

function StatCell({ label, value, delta, deltaColor = "text.secondary" }: StatCellProps) {
  return (
    <Box sx={{ bgcolor: "background.paper", p: "14px 16px", minWidth: 0 }}>
      <Typography
        variant="caption"
        sx={{
          display: "block",
          textTransform: "uppercase",
          letterSpacing: "0.06em",
          color: "text.disabled",
          fontWeight: 600,
          mb: 0.5,
        }}
      >
        {label}
      </Typography>
      <Typography sx={{ ...numericSx, fontSize: 20, fontWeight: 600, letterSpacing: "-0.01em" }}>
        {value}
      </Typography>
      <Typography variant="caption" sx={{ ...numericSx, color: deltaColor }}>
        {delta}
      </Typography>
    </Box>
  );
}

export default function SummaryStrip({ account }: SummaryStripProps) {
  const equityDeltaPct = (((account.equity - account.balance) / account.balance) * 100).toFixed(
    2,
  );

  return (
    <Paper
      variant="outlined"
      sx={{
        display: "grid",
        gridTemplateColumns: { xs: "repeat(2, 1fr)", sm: "repeat(3, 1fr)", md: "repeat(6, 1fr)" },
        gap: "1px",
        bgcolor: "divider",
        overflow: "hidden",
      }}
    >
      <StatCell label="Balance" value={formatUsd(account.balance)} delta="Deposit base" />
      <StatCell
        label="Equity"
        value={formatUsd(account.equity)}
        delta={`▲ ${equityDeltaPct}%`}
        deltaColor="success.main"
      />
      <StatCell
        label="Floating P/L"
        value={formatUsd(account.floatingPnl, true)}
        delta={`${account.tradesToday === 1 ? "1 open position" : `${account.tradesToday} open positions`}`}
        deltaColor="success.main"
      />
      <StatCell
        label="Today Realized"
        value={formatUsd(account.todayRealizedPnl, true)}
        delta={`${account.todayClosedCount} closed`}
        deltaColor="success.main"
      />
      <StatCell
        label="Margin Level"
        value={`${account.marginLevelPct}%`}
        delta={`Free ${formatUsd(account.freeMargin)}`}
      />
      <StatCell
        label="Trades Today"
        value={`${account.tradesToday}/${account.maxTradesPerDay}`}
        delta="Max/day limit"
      />
    </Paper>
  );
}
