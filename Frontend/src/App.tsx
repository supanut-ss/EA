import { useMemo, useState } from "react";
import Box from "@mui/material/Box";
import CircularProgress from "@mui/material/CircularProgress";
import CssBaseline from "@mui/material/CssBaseline";
import Stack from "@mui/material/Stack";
import Typography from "@mui/material/Typography";
import { ThemeProvider, type PaletteMode } from "@mui/material/styles";

import TopBar from "./components/TopBar";
import PortfolioOverviewStrip from "./components/PortfolioOverviewStrip";
import AccountSection from "./components/AccountSection";

import { useAllAccountsData } from "./hooks/useAllAccountsData";
import { getTheme } from "./theme";

const MODE_STORAGE_KEY = "ea-console-theme-mode";

function getInitialMode(): PaletteMode {
  const stored = localStorage.getItem(MODE_STORAGE_KEY);
  if (stored === "light" || stored === "dark") return stored;
  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

function accountDomId(accountId: number): string {
  return `account-${accountId}`;
}

export default function App() {
  const [mode, setMode] = useState<PaletteMode>(getInitialMode);
  const theme = useMemo(() => getTheme(mode), [mode]);
  const { accounts, isLoadingList, listError } = useAllAccountsData();

  const toggleMode = () => {
    setMode((prev) => {
      const next = prev === "dark" ? "light" : "dark";
      localStorage.setItem(MODE_STORAGE_KEY, next);
      return next;
    });
  };

  const connectedCount = accounts.filter((a) => a.data?.connection === "connected").length;

  const scrollToAccount = (accountId: number) => {
    document.getElementById(accountDomId(accountId))?.scrollIntoView({ behavior: "smooth", block: "start" });
  };

  return (
    <ThemeProvider theme={theme}>
      <CssBaseline />
      <Box sx={{ maxWidth: 1480, mx: "auto", px: { xs: 1.5, sm: 3 }, py: 2.5, pb: 8 }}>
        <Stack gap={2.5}>
          <Box
            sx={{
              position: "sticky",
              top: 0,
              zIndex: 10,
              bgcolor: "background.default",
              pt: 0.5,
              pb: 1,
              mx: { xs: -1.5, sm: -3 },
              px: { xs: 1.5, sm: 3 },
            }}
          >
            <TopBar
              mode={mode}
              onToggleMode={toggleMode}
              connectedCount={connectedCount}
              totalCount={accounts.length}
            />
          </Box>

          {isLoadingList && accounts.length === 0 ? (
            <Stack alignItems="center" justifyContent="center" sx={{ height: "50vh" }} gap={2}>
              <CircularProgress size={28} />
              <Typography variant="body2" color="text.secondary">
                กำลังโหลดรายชื่อบัญชี...
              </Typography>
            </Stack>
          ) : listError && accounts.length === 0 ? (
            <Stack alignItems="center" justifyContent="center" sx={{ height: "50vh" }} gap={1}>
              <Typography variant="body1" fontWeight={700} color="error.main">
                โหลดข้อมูลไม่สำเร็จ
              </Typography>
              <Typography variant="body2" color="text.secondary">
                {listError}
              </Typography>
            </Stack>
          ) : (
            <>
              <PortfolioOverviewStrip accounts={accounts} onSelect={scrollToAccount} />

              <Stack gap={2}>
                {accounts.map((entry) => (
                  <AccountSection
                    key={entry.info.accountId}
                    domId={accountDomId(entry.info.accountId)}
                    info={entry.info}
                    data={entry.data}
                    error={entry.error}
                    isLoading={entry.isLoading}
                    defaultExpanded
                  />
                ))}
              </Stack>

              <Typography variant="caption" color="text.disabled" textAlign="center">
                EA Console · เชื่อมต่อ backend จริงแล้ว · แสดงทุกบัญชีพร้อมกัน
              </Typography>
            </>
          )}
        </Stack>
      </Box>
    </ThemeProvider>
  );
}
