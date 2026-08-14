import Card from "@mui/material/Card";
import CardContent from "@mui/material/CardContent";
import Stack from "@mui/material/Stack";
import Typography from "@mui/material/Typography";
import type { ClosedTrade } from "../types/dashboard";
import { numericSx } from "../theme";
import { formatUsd } from "../utils/format";

interface TradeSessionAnalyticsProps {
  trades: ClosedTrade[];
}

interface SessionBand {
  key: string;
  label: string;
  startHour: number;
  endHour: number;
}

// ช่วง session แบบประมาณ ไม่ overlap กัน (broker time) - ของจริง London/NY
// ทับกันช่วง 13:00-16:00 แต่ตัดให้ไม่ทับเพื่อไม่ให้ไม้เดียวถูกนับ 2 รอบ
const SESSIONS: SessionBand[] = [
  { key: "asian", label: "Asian", startHour: 0, endHour: 8 },
  { key: "london", label: "London", startHour: 8, endHour: 15 },
  { key: "ny", label: "New York", startHour: 15, endHour: 24 },
];

function sessionKeyForHour(hour: number): string {
  return SESSIONS.find((s) => hour >= s.startHour && hour < s.endHour)?.key ?? SESSIONS[0].key;
}

// วิเคราะห์ผลงานแยกตาม session (Asian/London/NY) - คำนวณล้วนจาก
// closedAtBroker (มีแค่ชั่วโมง ไม่มีวันที่ แต่พอสำหรับ bucket ตาม session)
// ไม่ต้องมีข้อมูลใหม่จาก backend
export default function TradeSessionAnalytics({ trades }: TradeSessionAnalyticsProps) {
  if (trades.length === 0) return null;

  const bySession = SESSIONS.map((s) => {
    const inSession = trades.filter(
      (t) => sessionKeyForHour(Number(t.closedAtBroker.split(":")[0])) === s.key,
    );
    return {
      ...s,
      count: inSession.length,
      pnl: inSession.reduce((sum, t) => sum + t.pnl, 0),
    };
  });

  return (
    <Card>
      <CardContent sx={{ pb: "8px !important" }}>
        <Typography variant="subtitle1" fontWeight={700} mb={0.75}>
          Trade Analytics — ตาม Session
        </Typography>
        <Stack>
          {bySession.map((s, i) => (
            <Stack
              key={s.key}
              direction="row"
              justifyContent="space-between"
              alignItems="center"
              sx={{
                py: 0.75,
                borderBottom: i < bySession.length - 1 ? "1px dashed" : "none",
                borderColor: "divider",
              }}
            >
              <Typography variant="caption" color="text.secondary">
                {s.label} ({s.count} ไม้)
              </Typography>
              <Typography
                variant="body2"
                fontWeight={600}
                sx={{ ...numericSx, color: s.pnl >= 0 ? "success.main" : "error.main" }}
              >
                {formatUsd(s.pnl, true)}
              </Typography>
            </Stack>
          ))}
        </Stack>
      </CardContent>
    </Card>
  );
}
