import Alert from "@mui/material/Alert";
import Box from "@mui/material/Box";
import Card from "@mui/material/Card";
import CardContent from "@mui/material/CardContent";
import Chip from "@mui/material/Chip";
import Stack from "@mui/material/Stack";
import Table from "@mui/material/Table";
import TableBody from "@mui/material/TableBody";
import TableCell from "@mui/material/TableCell";
import TableContainer from "@mui/material/TableContainer";
import TableHead from "@mui/material/TableHead";
import TableRow from "@mui/material/TableRow";
import Typography from "@mui/material/Typography";
import type { ConnectionState, Position } from "../types/dashboard";
import { numericSx } from "../theme";
import { formatPrice, formatUsd } from "../utils/format";

interface OpenPositionsCardProps {
  positions: Position[];
  connection: ConnectionState;
  eaFilter: string;
  emptyMessage: string;
}

// ระยะห่างจากราคาปัจจุบันถึง SL/TP และ R:R ต่อไม้ - คำนวณฝั่ง frontend
// ล้วนๆ จากราคาที่มีอยู่แล้ว (ไม่ต้องมีข้อมูลใหม่จาก backend) ถือว่า
// SL/TP = 0 คือยังไม่ได้ตั้งไว้ (backend ส่ง null -> 0 เมื่อไม่มีค่า)
function distance(current: number, target: number): number | null {
  if (!target) return null;
  return Math.abs(current - target);
}

function riskReward(distSl: number | null, distTp: number | null): string {
  if (distSl === null || distTp === null || distSl === 0) return "-";
  return `1:${(distTp / distSl).toFixed(1)}`;
}

export default function OpenPositionsCard({
  positions,
  connection,
  eaFilter,
  emptyMessage,
}: OpenPositionsCardProps) {
  const filtered =
    eaFilter === "all" ? positions : positions.filter((p) => p.eaId === eaFilter);

  return (
    <Card>
      <CardContent sx={{ pb: "8px !important" }}>
        <Stack direction="row" justifyContent="space-between" alignItems="center" mb={1}>
          <Typography variant="subtitle1" fontWeight={700}>
            Open Positions
          </Typography>
          <Typography variant="caption" color="text.disabled">
            {filtered.length} รายการ
          </Typography>
        </Stack>

        {connection === "disconnected" && (
          <Alert severity="error" variant="outlined" sx={{ mb: 1.5, py: 0 }}>
            ข้อมูลอาจไม่ real-time — ขาดการเชื่อมต่อกับ Terminal
          </Alert>
        )}

        <TableContainer sx={{ overflowX: "auto" }}>
          <Table size="small" sx={{ minWidth: 760 }}>
            <TableHead>
              <TableRow>
                <TableCell>EA</TableCell>
                <TableCell>Symbol</TableCell>
                <TableCell>Side</TableCell>
                <TableCell align="right">Lot</TableCell>
                <TableCell align="right">Open</TableCell>
                <TableCell align="right">Current</TableCell>
                <TableCell align="right">S/L</TableCell>
                <TableCell align="right">T/P</TableCell>
                <TableCell align="right">To SL / TP</TableCell>
                <TableCell align="right">R:R</TableCell>
                <TableCell align="right">P/L</TableCell>
                <TableCell>Opened (Broker)</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {filtered.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={12} align="center" sx={{ py: 4, color: "text.disabled" }}>
                    {emptyMessage}
                  </TableCell>
                </TableRow>
              ) : (
                filtered.map((p) => {
                  const distSl = distance(p.currentPrice, p.stopLoss);
                  const distTp = distance(p.currentPrice, p.takeProfit);
                  return (
                    <TableRow key={p.id} hover>
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
                            {p.eaName}
                          </Typography>
                        </Stack>
                      </TableCell>
                      <TableCell>{p.symbol}</TableCell>
                      <TableCell>
                        <Chip
                          size="small"
                          label={p.side}
                          color={p.side === "BUY" ? "success" : "error"}
                          sx={{ ...numericSx, fontWeight: 700, fontSize: 11.5 }}
                        />
                      </TableCell>
                      <TableCell align="right" sx={numericSx}>
                        {p.lot.toFixed(2)}
                      </TableCell>
                      <TableCell align="right" sx={numericSx}>
                        {formatPrice(p.openPrice)}
                      </TableCell>
                      <TableCell align="right" sx={numericSx}>
                        {formatPrice(p.currentPrice)}
                      </TableCell>
                      <TableCell align="right" sx={numericSx}>
                        {formatPrice(p.stopLoss)}
                      </TableCell>
                      <TableCell align="right" sx={numericSx}>
                        {formatPrice(p.takeProfit)}
                      </TableCell>
                      <TableCell align="right" sx={{ ...numericSx, color: "text.secondary" }}>
                        {distSl === null ? "-" : formatPrice(distSl)} /{" "}
                        {distTp === null ? "-" : formatPrice(distTp)}
                      </TableCell>
                      <TableCell align="right" sx={numericSx}>
                        {riskReward(distSl, distTp)}
                      </TableCell>
                      <TableCell
                        align="right"
                        sx={{ ...numericSx, color: p.pnl >= 0 ? "success.main" : "error.main" }}
                      >
                        {formatUsd(p.pnl, true)}
                      </TableCell>
                      <TableCell sx={numericSx}>{p.openedAtBroker}</TableCell>
                    </TableRow>
                  );
                })
              )}
            </TableBody>
          </Table>
        </TableContainer>
      </CardContent>
    </Card>
  );
}
