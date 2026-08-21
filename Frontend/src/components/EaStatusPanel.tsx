import Box from "@mui/material/Box";
import Card from "@mui/material/Card";
import CardContent from "@mui/material/CardContent";
import Divider from "@mui/material/Divider";
import LinearProgress from "@mui/material/LinearProgress";
import Stack from "@mui/material/Stack";
import Typography from "@mui/material/Typography";
import type { EaStatus } from "../types/dashboard";
import { numericSx } from "../theme";

interface EaStatusPanelProps {
  eaStatuses: EaStatus[];
}

const STATE_LABEL: Record<EaStatus["state"], string> = {
  active: "Active",
  standby: "Standby",
  error: "Error",
  not_deployed: "ยังไม่ deploy",
};

const STATE_COLOR: Record<EaStatus["state"], string> = {
  active: "success.main",
  standby: "text.disabled",
  error: "error.main",
  not_deployed: "text.disabled",
};

export default function EaStatusPanel({ eaStatuses }: EaStatusPanelProps) {
  const runningCount = eaStatuses.filter((ea) => ea.state === "active").length;

  return (
    <Card>
      <CardContent sx={{ p: 1.75, "&:last-child": { pb: 1.5 } }}>
        <Stack direction="row" justifyContent="space-between" alignItems="center" mb={1}>
          <Typography variant="subtitle1" fontWeight={700}>
            EA Status
          </Typography>
          <Typography variant="caption" color="text.disabled">
            {runningCount}/{eaStatuses.length} กำลังทำงาน
          </Typography>
        </Stack>

        <Stack divider={<Divider />}>
          {eaStatuses.map((ea) => {
            const deployed = ea.state !== "not_deployed";
            return (
              <Box key={ea.id} sx={{ py: 1.25 }}>
                <Stack direction="row" justifyContent="space-between" alignItems="flex-start" gap={1}>
                  <Box minWidth={0}>
                    <Typography
                      variant="body2"
                      fontWeight={700}
                      color={deployed ? "text.primary" : "text.secondary"}
                      lineHeight={1.35}
                    >
                      {ea.name}
                    </Typography>
                    <Typography variant="caption" sx={numericSx} color="text.disabled">
                      {ea.symbol} · {ea.timeframe}
                    </Typography>
                  </Box>
                  <Stack
                    direction="row"
                    alignItems="center"
                    gap={0.6}
                    sx={{
                      flexShrink: 0,
                      px: 0.9,
                      py: 0.4,
                      borderRadius: 99,
                      bgcolor: "action.hover",
                    }}
                  >
                    <Box
                      aria-hidden
                      sx={{ width: 6, height: 6, borderRadius: "50%", bgcolor: STATE_COLOR[ea.state] }}
                    />
                    <Typography
                      variant="caption"
                      fontWeight={700}
                      sx={{ color: STATE_COLOR[ea.state], lineHeight: 1.2 }}
                    >
                      {STATE_LABEL[ea.state]}
                    </Typography>
                  </Stack>
                </Stack>

                {deployed ? (
                  <>
                    <Box
                      sx={{
                        display: "grid",
                        gridTemplateColumns: "minmax(0, 1fr) auto",
                        gap: 1.5,
                        mt: 1.25,
                      }}
                    >
                      <Metric label="Session" value={ea.sessionWindow} />
                      <Metric label="ไม้วันนี้" value={`${ea.tradesToday} / ${ea.maxTradesPerDay}`} align="right" />
                    </Box>
                    <LinearProgress
                      variant="determinate"
                      value={
                        ea.maxTradesPerDay > 0 ? (ea.tradesToday / ea.maxTradesPerDay) * 100 : 0
                      }
                      sx={{ mt: 0.75, height: 4, borderRadius: 3 }}
                    />
                    <Box sx={{ mt: 1.1, p: 1, borderRadius: 1.25, bgcolor: "action.hover" }}>
                      <Typography variant="caption" color="text.disabled" sx={{ display: "block", mb: 0.35 }}>
                        สัญญาณล่าสุด
                      </Typography>
                      <Typography
                        variant="caption"
                        sx={{
                          ...numericSx,
                          display: "block",
                          color: "text.primary",
                          lineHeight: 1.5,
                          overflowWrap: "anywhere",
                        }}
                      >
                        {ea.lastSignal}
                      </Typography>
                    </Box>
                  </>
                ) : (
                  ea.note && (
                    <Typography
                      variant="caption"
                      sx={{
                        display: "block",
                        mt: 1,
                        p: 1,
                        borderRadius: 1,
                        bgcolor: "action.hover",
                        color: "text.disabled",
                        lineHeight: 1.5,
                      }}
                    >
                      {ea.note}
                    </Typography>
                  )
                )}
              </Box>
            );
          })}
        </Stack>
      </CardContent>
    </Card>
  );
}

function Metric({
  label,
  value,
  align = "left",
}: {
  label: string;
  value: string;
  align?: "left" | "right";
}) {
  return (
    <Box minWidth={0} sx={{ textAlign: align }}>
      <Typography variant="caption" color="text.disabled" sx={{ display: "block", mb: 0.2 }}>
        {label}
      </Typography>
      <Typography
        variant="caption"
        sx={{ ...numericSx, display: "block", color: "text.primary", overflowWrap: "anywhere" }}
      >
        {value}
      </Typography>
    </Box>
  );
}
