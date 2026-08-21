import { useState } from "react";
import Box from "@mui/material/Box";
import Card from "@mui/material/Card";
import CardContent from "@mui/material/CardContent";
import Collapse from "@mui/material/Collapse";
import IconButton from "@mui/material/IconButton";
import Stack from "@mui/material/Stack";
import Typography from "@mui/material/Typography";
import ExpandMoreIcon from "@mui/icons-material/ExpandMore";
import type { ActivityLogEntry } from "../types/dashboard";
import { numericSx } from "../theme";
import { formatEaName } from "../utils/format";

interface ActivityLogCardProps {
  entries: ActivityLogEntry[];
}

const LEVEL_COLOR: Record<ActivityLogEntry["level"], string> = {
  ok: "success.main",
  info: "info.main",
  warn: "primary.main",
  error: "error.main",
};

const LEVEL_LABEL: Record<ActivityLogEntry["level"], string> = {
  ok: "สำเร็จ",
  info: "ข้อมูล",
  warn: "แจ้งเตือน",
  error: "ผิดพลาด",
};

export default function ActivityLogCard({ entries }: ActivityLogCardProps) {
  const [expanded, setExpanded] = useState(true);

  return (
    <Card>
      <CardContent sx={{ p: 0, "&:last-child": { pb: 0 } }}>
        <Stack
          direction="row"
          justifyContent="space-between"
          alignItems="center"
          sx={{ px: 1.75, py: 1.25, borderBottom: 1, borderColor: "divider" }}
        >
          <Box>
            <Typography variant="subtitle1" fontWeight={700} lineHeight={1.25}>
              Activity Log
            </Typography>
            <Typography variant="caption" color="text.disabled">
              เหตุการณ์ล่าสุด
            </Typography>
          </Box>
          <Stack direction="row" alignItems="center" gap={0.5}>
            <Box
              aria-label={`${entries.length} รายการ`}
              sx={{
                minWidth: 25,
                height: 25,
                px: 0.75,
                display: "grid",
                placeItems: "center",
                borderRadius: 99,
                bgcolor: "action.hover",
                color: "text.secondary",
                ...numericSx,
                fontSize: 11,
                fontWeight: 700,
              }}
            >
              {entries.length}
            </Box>
            <IconButton
              size="small"
              aria-label={`${expanded ? "ย่อ" : "ขยาย"} Activity Log`}
              aria-expanded={expanded}
              onClick={() => setExpanded((value) => !value)}
            >
              <ExpandMoreIcon
                fontSize="small"
                sx={{
                  transform: expanded ? "rotate(180deg)" : "none",
                  transition: "transform 150ms",
                }}
              />
            </IconButton>
          </Stack>
        </Stack>

        <Collapse in={expanded} timeout="auto">
          {entries.length === 0 ? (
            <Stack alignItems="center" justifyContent="center" sx={{ minHeight: 112, px: 2 }}>
              <Typography variant="body2" color="text.secondary">
                ยังไม่มีกิจกรรมล่าสุด
              </Typography>
            </Stack>
          ) : (
            <Box
              role="log"
              aria-label="เหตุการณ์ล่าสุด"
              sx={{
                maxHeight: 252,
                overflowY: "auto",
                overscrollBehavior: "contain",
                scrollbarGutter: "stable",
                "&::-webkit-scrollbar": { width: 6 },
                "&::-webkit-scrollbar-thumb": {
                  bgcolor: "divider",
                  borderRadius: 99,
                },
              }}
            >
              {entries.map((entry, index) => (
              <Box
                key={entry.id}
                sx={{
                  display: "grid",
                  gridTemplateColumns: "34px 9px minmax(0, 1fr)",
                  columnGap: 0.75,
                  px: 1.5,
                  py: 0.9,
                  borderBottom: index < entries.length - 1 ? 1 : 0,
                  borderColor: "divider",
                  "&:hover": { bgcolor: "action.hover" },
                }}
              >
                <Typography
                  component="time"
                  variant="caption"
                  sx={{ ...numericSx, color: "text.disabled", pt: "1px", fontSize: 10.5 }}
                >
                  {entry.timeThai}
                </Typography>

                <Box sx={{ position: "relative", display: "flex", justifyContent: "center" }}>
                  {index < entries.length - 1 && (
                    <Box
                      aria-hidden
                      sx={{
                        position: "absolute",
                        top: 10,
                        bottom: -14,
                        width: "1px",
                        bgcolor: "divider",
                      }}
                    />
                  )}
                  <Box
                    component="span"
                    aria-label={LEVEL_LABEL[entry.level]}
                    sx={{
                      position: "relative",
                      width: 7,
                      height: 7,
                      mt: "5px",
                      borderRadius: "50%",
                      bgcolor: LEVEL_COLOR[entry.level],
                      boxShadow: (theme) => `0 0 0 2px ${theme.palette.background.paper}`,
                    }}
                  />
                </Box>

                <Box minWidth={0}>
                  <Typography
                    variant="caption"
                    color="text.secondary"
                    sx={{ display: "block", fontWeight: 700, lineHeight: 1.35 }}
                    noWrap
                    title={formatEaName(entry.eaName)}
                  >
                    {formatEaName(entry.eaName)}
                  </Typography>
                  <Typography
                    variant="caption"
                    color="text.primary"
                    sx={{ display: "block", lineHeight: 1.45, overflowWrap: "anywhere" }}
                  >
                    {entry.message}
                  </Typography>
                </Box>
              </Box>
              ))}
            </Box>
          )}

          {entries.length > 0 && (
            <Typography
              variant="caption"
              color="text.disabled"
              sx={{ display: "block", px: 1.75, py: 0.8, borderTop: 1, borderColor: "divider" }}
            >
              ใหม่สุดอยู่ด้านบน · เลื่อนเพื่อดูย้อนหลัง
            </Typography>
          )}
        </Collapse>
      </CardContent>
    </Card>
  );
}
