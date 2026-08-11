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
          <Table size="small" sx={{ minWidth: 640 }}>
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
                <TableCell align="right">P/L</TableCell>
                <TableCell>Opened (Broker)</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {filtered.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={10} align="center" sx={{ py: 4, color: "text.disabled" }}>
                    {emptyMessage}
                  </TableCell>
                </TableRow>
              ) : (
                filtered.map((p) => (
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
                    <TableCell
                      align="right"
                      sx={{ ...numericSx, color: p.pnl >= 0 ? "success.main" : "error.main" }}
                    >
                      {formatUsd(p.pnl, true)}
                    </TableCell>
                    <TableCell sx={numericSx}>{p.openedAtBroker}</TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </TableContainer>
      </CardContent>
    </Card>
  );
}
