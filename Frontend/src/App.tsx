import { useMemo, useState } from "react";
import Box from "@mui/material/Box";
import CircularProgress from "@mui/material/CircularProgress";
import CssBaseline from "@mui/material/CssBaseline";
import Stack from "@mui/material/Stack";
import Typography from "@mui/material/Typography";
import { ThemeProvider, type PaletteMode } from "@mui/material/styles";

import TopBar from "./components/TopBar";
import StatusBanners from "./components/StatusBanners";
import SummaryStrip from "./components/SummaryStrip";
import EaFilterBar from "./components/EaFilterBar";
import EquityCurveCard from "./components/EquityCurveCard";
import OpenPositionsCard from "./components/OpenPositionsCard";
import TradeHistoryCard from "./components/TradeHistoryCard";
import EaStatusPanel from "./components/EaStatusPanel";
import RiskSnapshotCard from "./components/RiskSnapshotCard";
import ActivityLogCard from "./components/ActivityLogCard";

import { useDashboardData } from "./hooks/useDashboardData";
import { getTheme } from "./theme";
import { computeTradeStats } from "./utils/stats";

const MODE_STORAGE_KEY = "ea-console-theme-mode";

function getInitialMode(): PaletteMode {
  const stored = localStorage.getItem(MODE_STORAGE_KEY);
  if (stored === "light" || stored === "dark") return stored;
  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

export default function App() {
  const [mode, setMode] = useState<PaletteMode>(getInitialMode);
  const [eaFilter, setEaFilter] = useState("all");
  const theme = useMemo(() => getTheme(mode), [mode]);
  const { data, error, isLoading } = useDashboardData();

  const toggleMode = () => {
    setMode((prev) => {
      const next = prev === "dark" ? "light" : "dark";
      localStorage.setItem(MODE_STORAGE_KEY, next);
      return next;
    });
  };

  const stats = useMemo(
    () => computeTradeStats(data?.closedTrades ?? []),
    [data?.closedTrades],
  );

  return (
    <ThemeProvider theme={theme}>
      <CssBaseline />
      <Box sx={{ maxWidth: 1320, mx: "auto", px: { xs: 1.5, sm: 3 }, py: 2.5, pb: 8 }}>
        {isLoading && !data ? (
          <Stack alignItems="center" justifyContent="center" sx={{ height: "60vh" }} gap={2}>
            <CircularProgress size={28} />
            <Typography variant="body2" color="text.secondary">
              กำลังโหลดข้อมูล dashboard...
            </Typography>
          </Stack>
        ) : error && !data ? (
          <Stack alignItems="center" justifyContent="center" sx={{ height: "60vh" }} gap={1}>
            <Typography variant="body1" fontWeight={700} color="error.main">
              โหลดข้อมูลไม่สำเร็จ
            </Typography>
            <Typography variant="body2" color="text.secondary">
              {error}
            </Typography>
          </Stack>
        ) : data ? (
          <Stack gap={2.5}>
            <TopBar
              connection={data.connection}
              lastSyncedAt={data.lastSyncedAt}
              brokerTime={data.brokerTime}
              localTime={data.localTime}
              mode={mode}
              onToggleMode={toggleMode}
            />

            <StatusBanners connection={data.connection} eaStatuses={data.eaStatuses} />

            <SummaryStrip account={data.account} />

            <EaFilterBar
              eaStatuses={data.eaStatuses}
              value={eaFilter}
              onChange={setEaFilter}
            />

            <Box
              sx={{
                display: "grid",
                gridTemplateColumns: { xs: "1fr", md: "minmax(0, 1fr) 320px" },
                gap: 2,
                alignItems: "start",
              }}
            >
              <Stack gap={2} minWidth={0}>
                <EquityCurveCard points={data.equityCurve} />
                <OpenPositionsCard
                  positions={data.openPositions}
                  connection={data.connection}
                  eaFilter={eaFilter}
                  emptyMessage={
                    eaFilter === "scalp"
                      ? "Scalping ยังไม่ deploy — ไม่มีข้อมูล"
                      : "ยังไม่มีไม้เปิดวันนี้"
                  }
                />
                <TradeHistoryCard
                  trades={data.closedTrades}
                  eaFilter={eaFilter}
                  emptyMessage={
                    eaFilter === "scalp"
                      ? "Scalping ยังไม่ deploy — ไม่มีข้อมูล"
                      : "ยังไม่มีประวัติการเทรดวันนี้"
                  }
                  winRatePct={stats.winRatePct}
                  profitFactor={stats.profitFactor}
                />
              </Stack>

              <Stack gap={2} minWidth={0}>
                <EaStatusPanel eaStatuses={data.eaStatuses} />
                <RiskSnapshotCard risk={data.risk} />
                <ActivityLogCard entries={data.activityLog} />
              </Stack>
            </Box>

            <Typography variant="caption" color="text.disabled" textAlign="center">
              EA Console · ข้อมูลตัวอย่างสำหรับ dev (mock data) — ยังไม่เชื่อมต่อ backend จริง
            </Typography>
          </Stack>
        ) : null}
      </Box>
    </ThemeProvider>
  );
}
