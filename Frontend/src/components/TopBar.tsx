import Box from "@mui/material/Box";
import IconButton from "@mui/material/IconButton";
import Stack from "@mui/material/Stack";
import Tooltip from "@mui/material/Tooltip";
import Typography from "@mui/material/Typography";
import DarkModeOutlinedIcon from "@mui/icons-material/DarkModeOutlined";
import LightModeOutlinedIcon from "@mui/icons-material/LightModeOutlined";

interface TopBarProps {
  mode: "light" | "dark";
  onToggleMode: () => void;
  connectedCount: number;
  totalCount: number;
}

// เดิม TopBar มี dropdown เลือกบัญชีเดียวมาดู - เอาออกแล้วเพราะตอนนี้ทุกบัญชี
// แสดงพร้อมกันในหน้าเดียว (ดู PortfolioOverviewStrip + AccountSection ใน
// App.tsx) เหลือแค่ควบคุมระดับหน้าจอจริง ๆ (โหมดสี) กับสรุปสถานะรวมสั้น ๆ
export default function TopBar({ mode, onToggleMode, connectedCount, totalCount }: TopBarProps) {
  const allConnected = totalCount > 0 && connectedCount === totalCount;
  const noneConnected = connectedCount === 0;

  return (
    <Stack
      direction="row"
      flexWrap="wrap"
      alignItems="center"
      justifyContent="space-between"
      gap={2}
    >
      <Typography variant="h6" fontWeight={700} letterSpacing="-0.01em">
        XAU
        <Box component="span" sx={{ color: "primary.main" }}>
          EA
        </Box>{" "}
        Console
      </Typography>

      <Stack direction="row" alignItems="center" flexWrap="wrap" gap={1.25}>
        {totalCount > 0 && (
          <Tooltip title="อัปเดตข้อมูลอัตโนมัติทุก 10 วินาที แบบไม่รบกวนหน้าจอ">
            <Stack direction="row" alignItems="center" gap={0.75}>
              <Box
                sx={{
                  width: 7,
                  height: 7,
                  borderRadius: "50%",
                  bgcolor: allConnected ? "success.main" : noneConnected ? "error.main" : "warning.main",
                  animation: "ea-pulse 2s ease-in-out infinite",
                  "@keyframes ea-pulse": {
                    "0%, 100%": { opacity: 1 },
                    "50%": { opacity: 0.35 },
                  },
                }}
              />
              <Typography variant="caption" color="text.secondary">
                {connectedCount}/{totalCount} เชื่อมต่อ
              </Typography>
            </Stack>
          </Tooltip>
        )}
        <IconButton
          size="small"
          onClick={onToggleMode}
          aria-label="สลับโหมดสี"
          sx={{ border: 1, borderColor: "divider" }}
        >
          {mode === "dark" ? (
            <LightModeOutlinedIcon fontSize="small" />
          ) : (
            <DarkModeOutlinedIcon fontSize="small" />
          )}
        </IconButton>
      </Stack>
    </Stack>
  );
}
