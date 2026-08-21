import { useState } from "react";
import Box from "@mui/material/Box";
import Card from "@mui/material/Card";
import CardContent from "@mui/material/CardContent";
import Chip from "@mui/material/Chip";
import Collapse from "@mui/material/Collapse";
import IconButton from "@mui/material/IconButton";
import Stack from "@mui/material/Stack";
import Tab from "@mui/material/Tab";
import Table from "@mui/material/Table";
import TableBody from "@mui/material/TableBody";
import TableCell from "@mui/material/TableCell";
import TableContainer from "@mui/material/TableContainer";
import TableHead from "@mui/material/TableHead";
import TableRow from "@mui/material/TableRow";
import Tabs from "@mui/material/Tabs";
import Typography from "@mui/material/Typography";
import ExpandMoreIcon from "@mui/icons-material/ExpandMore";
import type { ClosedTrade, Performance } from "../types/dashboard";
import { numericSx } from "../theme";
import { formatEaName, formatPrice, formatSide, formatUsd } from "../utils/format";

interface TradeHistoryCardProps {
  trades: ClosedTrade[];
  eaFilter: string;
  emptyMessage: string;
  performance: Performance;
  brokerToday: string;
}

const RANGES: { label: string; key: keyof Performance; maxAgeDays: number }[] = [
  { label: "วันนี้", key: "today", maxAgeDays: 0 },
  { label: "7 วัน", key: "last7d", maxAgeDays: 6 },
  { label: "30 วัน", key: "last30d", maxAgeDays: 29 },
];

// จำนวนวันปฏิทินระหว่าง broker "วันนี้" กับวันที่ปิดไม้ - ทั้งคู่เป็นวันที่
// ปฏิทินของ broker ล้วนๆ (yyyy-MM-dd ไม่มีเวลา/timezone ปน) จึงลบกันตรงๆ
// ได้แม่นยำ ไม่ต้องเดา timezone ของผู้ใช้
function daysAgo(brokerToday: string, closedDateBroker: string): number {
  const msPerDay = 24 * 60 * 60 * 1000;
  return Math.round(
    (new Date(`${brokerToday}T00:00:00Z`).getTime() -
      new Date(`${closedDateBroker}T00:00:00Z`).getTime()) /
      msPerDay,
  );
}

export default function TradeHistoryCard({
  trades,
  eaFilter,
  emptyMessage,
  performance,
  brokerToday,
}: TradeHistoryCardProps) {
  const [range, setRange] = useState(0);
  const [expanded, setExpanded] = useState(true);
  const stats = performance[RANGES[range].key];
  const maxAgeDays = RANGES[range].maxAgeDays;
  const filtered = trades
    .filter((t) => eaFilter === "all" || t.eaId === eaFilter)
    .filter((t) => daysAgo(brokerToday, t.closedDateBroker) <= maxAgeDays);

  return (
    <Card>
      <CardContent sx={{ pb: "8px !important" }}>
        <Stack direction="row" justifyContent="space-between" alignItems="center" gap={1} mb={0.5}>
          <Typography variant="subtitle1" fontWeight={700}>
            Trade History
          </Typography>
          <Stack direction="row" alignItems="center" gap={0.5} minWidth={0}>
            <Typography
              variant="caption"
              color="text.disabled"
              noWrap
              sx={{ display: { xs: "none", sm: "block" } }}
            >
              Win rate {stats.winRatePct}% · PF {stats.profitFactor} · Expectancy{" "}
              {formatUsd(stats.expectancy, true)}
            </Typography>
            <IconButton
              size="small"
              aria-label={`${expanded ? "ย่อ" : "ขยาย"} Trade History`}
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
          <Tabs
            value={range}
            onChange={(_, v) => setRange(v)}
            sx={{ minHeight: 36, mb: 1, borderBottom: 1, borderColor: "divider" }}
          >
            {RANGES.map((r) => (
              <Tab key={r.key} label={r.label} sx={{ minHeight: 36, textTransform: "none" }} />
            ))}
          </Tabs>

          <TableContainer sx={{ overflowX: "auto" }}>
            <Table
              size="small"
              sx={{
                minWidth: 720,
                "& .MuiTableCell-root": { whiteSpace: "nowrap", px: 1.25 },
              }}
            >
            <TableHead>
              <TableRow>
                <TableCell>EA</TableCell>
                <TableCell>Symbol</TableCell>
                <TableCell>Side</TableCell>
                <TableCell align="right">Lot</TableCell>
                <TableCell align="right">Open</TableCell>
                <TableCell align="right">Close</TableCell>
                <TableCell align="right">P/L</TableCell>
                <TableCell>ปิดไม้ (ไทย)</TableCell>
                <TableCell>เหตุผล</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {filtered.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={9} align="center" sx={{ py: 4, color: "text.disabled" }}>
                    {emptyMessage}
                  </TableCell>
                </TableRow>
              ) : (
                filtered.map((t) => (
                  <TableRow key={t.id} hover>
                    <TableCell>
                      <Stack direction="row" alignItems="center" gap={0.75}>
                        <Box
                          sx={{
                            width: 6,
                            height: 6,
                            borderRadius: "50%",
                            bgcolor: "primary.main",
                          }}
                        />
                        <Typography variant="body2" color="text.secondary">
                          {formatEaName(t.eaName)}
                        </Typography>
                      </Stack>
                    </TableCell>
                    <TableCell>{t.symbol}</TableCell>
                    <TableCell>
                      <Chip
                        size="small"
                        label={formatSide(t.side)}
                        color={t.side === "BUY" ? "success" : "error"}
                        sx={{ ...numericSx, fontWeight: 700, fontSize: 11.5 }}
                      />
                    </TableCell>
                    <TableCell align="right" sx={numericSx}>
                      {t.lot.toFixed(2)}
                    </TableCell>
                    <TableCell align="right" sx={numericSx}>
                      {formatPrice(t.openPrice)}
                    </TableCell>
                    <TableCell align="right" sx={numericSx}>
                      {formatPrice(t.closePrice)}
                    </TableCell>
                    <TableCell
                      align="right"
                      sx={{ ...numericSx, color: t.pnl >= 0 ? "success.main" : "error.main" }}
                    >
                      {formatUsd(t.pnl, true)}
                    </TableCell>
                    <TableCell sx={numericSx}>{t.closedAtThai}</TableCell>
                    <TableCell>{t.closeReason}</TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
            </Table>
          </TableContainer>
        </Collapse>
      </CardContent>
    </Card>
  );
}
