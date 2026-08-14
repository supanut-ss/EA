import Box from "@mui/material/Box";
import Chip from "@mui/material/Chip";
import IconButton from "@mui/material/IconButton";
import MenuItem from "@mui/material/MenuItem";
import Select, { type SelectChangeEvent } from "@mui/material/Select";
import Stack from "@mui/material/Stack";
import Tooltip from "@mui/material/Tooltip";
import Typography from "@mui/material/Typography";
import DarkModeOutlinedIcon from "@mui/icons-material/DarkModeOutlined";
import LightModeOutlinedIcon from "@mui/icons-material/LightModeOutlined";
import type { AccountInfo, AccountListItem, ConnectionState } from "../types/dashboard";

interface TopBarProps {
  connection: ConnectionState;
  lastSyncedAt: string;
  brokerTime: string;
  localTime: string;
  mode: "light" | "dark";
  onToggleMode: () => void;
  accountInfo: AccountInfo;
  accounts: AccountListItem[];
  selectedAccountId: number;
  onSelectAccount: (accountId: number) => void;
}

function accountLabel(a: { mt5Login: number; brokerName: string; isDemo: boolean }): string {
  return `${a.isDemo ? "Demo" : "Live"} #${a.mt5Login} · ${a.brokerName}`;
}

export default function TopBar({
  connection,
  lastSyncedAt,
  brokerTime,
  localTime,
  mode,
  onToggleMode,
  accountInfo,
  accounts,
  selectedAccountId,
  onSelectAccount,
}: TopBarProps) {
  const connected = connection === "connected";

  const handleAccountChange = (event: SelectChangeEvent<number>) => {
    onSelectAccount(Number(event.target.value));
  };

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
          MT5 ·
        </Typography>
        {accounts.length > 1 ? (
          <Select
            size="small"
            variant="standard"
            value={selectedAccountId}
            onChange={handleAccountChange}
            disableUnderline
            sx={{ fontSize: "0.75rem", color: "text.secondary" }}
          >
            {accounts.map((a) => (
              <MenuItem key={a.accountId} value={a.accountId} sx={{ fontSize: "0.8125rem" }}>
                {accountLabel(a)}
              </MenuItem>
            ))}
          </Select>
        ) : (
          <Typography variant="caption" color="text.secondary">
            {accountLabel(accountInfo)}
          </Typography>
        )}
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
