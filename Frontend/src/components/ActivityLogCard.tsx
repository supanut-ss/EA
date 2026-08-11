import Box from "@mui/material/Box";
import Card from "@mui/material/Card";
import CardContent from "@mui/material/CardContent";
import Divider from "@mui/material/Divider";
import Link from "@mui/material/Link";
import Stack from "@mui/material/Stack";
import Typography from "@mui/material/Typography";
import type { ActivityLogEntry } from "../types/dashboard";
import { numericSx } from "../theme";

interface ActivityLogCardProps {
  entries: ActivityLogEntry[];
}

const LEVEL_COLOR: Record<ActivityLogEntry["level"], string> = {
  ok: "success.main",
  info: "info.main",
  warn: "primary.main",
  error: "error.main",
};

export default function ActivityLogCard({ entries }: ActivityLogCardProps) {
  return (
    <Card>
      <CardContent sx={{ pb: "0 !important" }}>
        <Stack direction="row" justifyContent="space-between" alignItems="center" mb={0.5}>
          <Typography variant="subtitle1" fontWeight={700}>
            Activity Log
          </Typography>
          <Typography variant="caption" color="text.disabled">
            ล่าสุด {entries.length} รายการ
          </Typography>
        </Stack>

        <Stack divider={<Divider />} sx={{ mx: -2 }}>
          {entries.map((entry) => (
            <Stack
              key={entry.id}
              direction="row"
              gap={1.25}
              sx={{ px: 2, py: 1, fontSize: 12.5 }}
            >
              <Typography variant="caption" sx={{ ...numericSx, color: "text.disabled", width: 44 }}>
                {entry.timeBroker}
              </Typography>
              <Box
                sx={{
                  width: 7,
                  height: 7,
                  borderRadius: "50%",
                  bgcolor: LEVEL_COLOR[entry.level],
                  mt: "5px",
                  flexShrink: 0,
                }}
              />
              <Typography variant="caption" color="text.primary">
                <Box component="span" sx={{ color: "text.secondary", fontWeight: 600, mr: 0.5 }}>
                  {entry.eaName}
                </Box>
                {entry.message}
              </Typography>
            </Stack>
          ))}
        </Stack>
      </CardContent>
      <Box sx={{ textAlign: "center", py: 1.25, borderTop: 1, borderColor: "divider" }}>
        <Link href="#" underline="none" variant="caption" fontWeight={600}>
          ดูทั้งหมด →
        </Link>
      </Box>
    </Card>
  );
}
