import { useState } from "react";
import Box from "@mui/material/Box";
import Card from "@mui/material/Card";
import Chip from "@mui/material/Chip";
import Collapse from "@mui/material/Collapse";
import Skeleton from "@mui/material/Skeleton";
import Stack from "@mui/material/Stack";
import Typography from "@mui/material/Typography";
import ExpandMoreIcon from "@mui/icons-material/ExpandMore";

import type { AccountListItem, DashboardSnapshot } from "../types/dashboard";
import StatusBanners from "./StatusBanners";
import SummaryStrip from "./SummaryStrip";
import EaFilterBar from "./EaFilterBar";
import EquityCurveCard from "./EquityCurveCard";
import OpenPositionsCard from "./OpenPositionsCard";
import TradeHistoryCard from "./TradeHistoryCard";
import TradeSessionAnalytics from "./TradeSessionAnalytics";
import EaStatusPanel from "./EaStatusPanel";
import RiskSnapshotCard from "./RiskSnapshotCard";
import ActivityLogCard from "./ActivityLogCard";
import { formatDateTime } from "../utils/format";

interface AccountSectionProps {
  domId: string;
  info: AccountListItem;
  data: DashboardSnapshot | null;
  error: string | null;
  isLoading: boolean;
  defaultExpanded: boolean;
}

// เนื้อหาเต็มของ 1 บัญชี (เดิมคือทั้งหน้า App.tsx) - ตอนนี้ทุกบัญชีแสดงแบบนี้
// ซ้อนกันในหน้าเดียว แต่ละบัญชีมี state ตัวกรอง EA + expand/collapse เป็นของ
// ตัวเอง ไม่ปนกัน
export default function AccountSection({
  domId,
  info,
  data,
  error,
  isLoading,
  defaultExpanded,
}: AccountSectionProps) {
  const [expanded, setExpanded] = useState(defaultExpanded);
  const [eaFilter, setEaFilter] = useState("all");

  const connected = data?.connection === "connected";
  const label = `${info.isDemo ? "Demo" : "Live"} #${info.mt5Login} · ${info.brokerName}`;

  return (
    <Card id={domId} variant="outlined" sx={{ scrollMarginTop: 84 }}>
      <Stack
        direction="row"
        alignItems="center"
        justifyContent="space-between"
        gap={1}
        role="button"
        tabIndex={0}
        aria-expanded={expanded}
        aria-label={`${expanded ? "ย่อ" : "ขยาย"}ส่วนของบัญชี ${label}`}
        onClick={() => setExpanded((v) => !v)}
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === " ") {
            e.preventDefault();
            setExpanded((v) => !v);
          }
        }}
        sx={{
          p: 1.5,
          cursor: "pointer",
          userSelect: "none",
          "&:focus-visible": {
            outline: (t) => `2px solid ${t.palette.primary.main}`,
            outlineOffset: -2,
          },
        }}
      >
        <Stack direction="row" alignItems="center" gap={1.25} flexWrap="wrap" minWidth={0}>
          <Box
            sx={{
              width: 8,
              height: 8,
              borderRadius: "50%",
              bgcolor: connected ? "success.main" : "error.main",
              flexShrink: 0,
            }}
          />
          <Typography sx={{ fontSize: 14.5, fontWeight: 700 }} noWrap>
            {label}
          </Typography>
          {data && (
            <Chip
              size="small"
              variant="outlined"
              label={`Synced ${formatDateTime(data.lastSyncedAt)}`}
              sx={{ display: { xs: "none", sm: "inline-flex" } }}
            />
          )}
        </Stack>
        <ExpandMoreIcon
          fontSize="small"
          aria-hidden
          sx={{
            color: "text.secondary",
            transform: expanded ? "rotate(180deg)" : "none",
            transition: "transform 150ms",
          }}
        />
      </Stack>

      <Collapse in={expanded} unmountOnExit={false}>
        <Box sx={{ px: 1.5, pb: 1.5 }}>
          {isLoading && !data ? (
            <Stack gap={1.5}>
              <Skeleton variant="rounded" height={90} />
              <Skeleton variant="rounded" height={200} />
            </Stack>
          ) : error && !data ? (
            <Typography variant="body2" color="text.secondary" sx={{ py: 2 }}>
              {error}
            </Typography>
          ) : data ? (
            <Stack gap={1.5}>
              <StatusBanners connection={data.connection} eaStatuses={data.eaStatuses} />
              <SummaryStrip
                account={data.account}
                risk={data.risk}
                openPositionsCount={data.openPositions.length}
                totalLots={data.openPositions.reduce((sum, p) => sum + p.lot, 0)}
                eaActiveCount={data.eaStatuses.filter((ea) => ea.state === "active").length}
                eaTotalCount={data.eaStatuses.length}
              />
              <EaFilterBar eaStatuses={data.eaStatuses} value={eaFilter} onChange={setEaFilter} />

              <Box
                sx={{
                  display: "grid",
                  gridTemplateColumns: { xs: "1fr", lg: "minmax(0, 1fr) 300px" },
                  gap: 1.5,
                  alignItems: "start",
                }}
              >
                <Stack gap={1.5} minWidth={0}>
                  <EquityCurveCard points={data.equityCurve} />
                  <OpenPositionsCard
                    positions={data.openPositions}
                    connection={data.connection}
                    eaFilter={eaFilter}
                    emptyMessage="ยังไม่มีไม้เปิดวันนี้"
                  />
                  <TradeHistoryCard
                    trades={data.closedTrades}
                    eaFilter={eaFilter}
                    emptyMessage="ยังไม่มีประวัติการเทรดวันนี้"
                    performance={data.performance}
                    brokerToday={data.brokerToday}
                  />
                  <TradeSessionAnalytics trades={data.closedTrades} />
                </Stack>

                <Stack gap={1.5} minWidth={0}>
                  <EaStatusPanel eaStatuses={data.eaStatuses} />
                  <RiskSnapshotCard risk={data.risk} account={data.account} />
                  <ActivityLogCard entries={data.activityLog} />
                </Stack>
              </Box>
            </Stack>
          ) : null}
        </Box>
      </Collapse>
    </Card>
  );
}
