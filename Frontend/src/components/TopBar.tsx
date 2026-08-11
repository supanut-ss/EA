import Box from "@mui/material/Box";
import Chip from "@mui/material/Chip";
import IconButton from "@mui/material/IconButton";
import Stack from "@mui/material/Stack";
import Tooltip from "@mui/material/Tooltip";
import Typography from "@mui/material/Typography";
import DarkModeOutlinedIcon from "@mui/icons-material/DarkModeOutlined";
import LightModeOutlinedIcon from "@mui/icons-material/LightModeOutlined";
import type { ConnectionState } from "../types/dashboard";

interface TopBarProps {
  connection: ConnectionState;
  lastSyncedAt: string;
  brokerTime: string;
  localTime: string;
  mode: "light" | "dark";
  onToggleMode: () => void;
}

export default function TopBar({
  connection,
  lastSyncedAt,
  brokerTime,
  localTime,
  mode,
  onToggleMode,
}: TopBarProps) {
  const connected = connection === "connected";

  return (
    <Stack
      direction="row"
      flexWrap="wrap"
      alignItems="center"
      justifyContent="space-between"
      gap={2}
    >
      <Stack direction="row" alignItems="baseline" gap={1.25}>
        <Typography variant="h6" fontWeight={700} letterSpacing="-0.01em">
          XAU
          <Box component="span" sx={{ color: "primary.main" }}>
            EA
          </Box>{" "}
          Console
        </Typography>
        <Typography variant="caption" color="text.secondary">
          MT5 · Demo #51234789 · Broker XM Global
        </Typography>
      </Stack>

      <Stack direction="row" alignItems="center" flexWrap="wrap" gap={1}>
        <Tooltip title={`Broker ${brokerTime} · Local ${localTime}`}>
          <Chip
            size="small"
            color={connected ? "success" : "error"}
            variant="outlined"
            label={connected ? "Terminal Connected" : "Terminal Disconnected"}
          />
        </Tooltip>
        <Chip size="small" variant="outlined" label={`Synced ${lastSyncedAt}`} />
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
