import Card from "@mui/material/Card";
import CardContent from "@mui/material/CardContent";
import Stack from "@mui/material/Stack";
import Box from "@mui/material/Box";
import Typography from "@mui/material/Typography";
import { useTheme } from "@mui/material/styles";
import { LineChart } from "@mui/x-charts/LineChart";
import type { EquityPoint } from "../types/dashboard";

interface EquityCurveCardProps {
  points: EquityPoint[];
}

export default function EquityCurveCard({ points }: EquityCurveCardProps) {
  const theme = useTheme();

  return (
    <Card>
      <CardContent sx={{ pb: "8px !important" }}>
        <Stack direction="row" justifyContent="space-between" alignItems="center" mb={1}>
          <Typography variant="subtitle1" fontWeight={700}>
            Equity Curve — 30 วัน
          </Typography>
          <Typography variant="caption" color="text.disabled">
            อัปเดตล่าสุด {points[points.length - 1]?.label}
          </Typography>
        </Stack>

        <Stack direction="row" gap={2} mb={0.5}>
          <Legend color={theme.palette.primary.main} label="Equity" />
          <Legend color={theme.palette.text.disabled} label="Balance" />
        </Stack>

        <Box sx={{ width: "100%", height: 220 }}>
          <LineChart
            series={[
              {
                data: points.map((p) => p.equity),
                label: "Equity",
                color: theme.palette.primary.main,
                area: true,
                showMark: false,
                curve: "monotoneX",
              },
              {
                data: points.map((p) => p.balance),
                label: "Balance",
                color: theme.palette.text.disabled,
                showMark: false,
                curve: "linear",
              },
            ]}
            xAxis={[
              {
                data: points.map((p) => p.label),
                scaleType: "point",
                tickLabelStyle: { fontSize: 10 },
              },
            ]}
            yAxis={[{ tickLabelStyle: { fontSize: 10 } }]}
            grid={{ horizontal: true }}
            slotProps={{ legend: { hidden: true } }}
            margin={{ left: 45, right: 10, top: 10, bottom: 24 }}
          />
        </Box>
      </CardContent>
    </Card>
  );
}

function Legend({ color, label }: { color: string; label: string }) {
  return (
    <Stack direction="row" alignItems="center" gap={0.75}>
      <Box sx={{ width: 9, height: 9, borderRadius: "2px", bgcolor: color }} />
      <Typography variant="caption" color="text.secondary">
        {label}
      </Typography>
    </Stack>
  );
}
