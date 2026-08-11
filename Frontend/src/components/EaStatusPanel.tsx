import Box from "@mui/material/Box";
import Card from "@mui/material/Card";
import CardContent from "@mui/material/CardContent";
import Divider from "@mui/material/Divider";
import LinearProgress from "@mui/material/LinearProgress";
import Stack from "@mui/material/Stack";
import Switch from "@mui/material/Switch";
import Tooltip from "@mui/material/Tooltip";
import Typography from "@mui/material/Typography";
import type { EaStatus } from "../types/dashboard";
import { numericSx } from "../theme";

interface EaStatusPanelProps {
  eaStatuses: EaStatus[];
}

const STATE_LABEL: Record<EaStatus["state"], string> = {
  active: "● Active",
  standby: "○ Standby",
  error: "● Error",
  not_deployed: "○ ยังไม่ deploy",
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
      <CardContent sx={{ pb: "8px !important" }}>
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
              <Box key={ea.id} sx={{ py: 1.5 }}>
                <Stack direction="row" justifyContent="space-between" alignItems="center">
                  <Box>
                    <Typography
                      variant="body2"
                      fontWeight={700}
                      color={deployed ? "text.primary" : "text.secondary"}
                    >
                      {ea.name}
                    </Typography>
                    <Typography variant="caption" sx={numericSx} color="text.disabled">
                      {ea.symbol} · {ea.timeframe}
                    </Typography>
                  </Box>
                  <Tooltip title="แสดงสถานะจาก Terminal เท่านั้น — การควบคุมเปิด/ปิด EA ระยะไกลยังไม่รองรับในเวอร์ชันนี้">
                    <span>
                      <Switch
                        size="small"
                        checked={ea.state === "active" || ea.state === "standby"}
                        disabled
                        inputProps={{ "aria-label": `สถานะ ${ea.name}` }}
                      />
                    </span>
                  </Tooltip>
                </Stack>

                <MetaRow label="สถานะ" value={STATE_LABEL[ea.state]} valueColor={STATE_COLOR[ea.state]} />

                {deployed ? (
                  <>
                    <MetaRow label="Session" value={ea.sessionWindow} />
                    <MetaRow label="สัญญาณล่าสุด" value={ea.lastSignal} />
                    <MetaRow label="ไม้วันนี้" value={`${ea.tradesToday} / ${ea.maxTradesPerDay}`} />
                    <LinearProgress
                      variant="determinate"
                      value={
                        ea.maxTradesPerDay > 0 ? (ea.tradesToday / ea.maxTradesPerDay) * 100 : 0
                      }
                      sx={{ mt: 0.5, height: 5, borderRadius: 3 }}
                    />
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

function MetaRow({
  label,
  value,
  valueColor,
}: {
  label: string;
  value: string;
  valueColor?: string;
}) {
  return (
    <Stack direction="row" justifyContent="space-between" sx={{ mt: 1, fontSize: 12.5 }}>
      <Typography variant="caption" color="text.secondary">
        {label}
      </Typography>
      <Typography variant="caption" sx={{ ...numericSx, color: valueColor ?? "text.primary" }}>
        {value}
      </Typography>
    </Stack>
  );
}
