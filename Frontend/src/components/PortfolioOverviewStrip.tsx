import Box from "@mui/material/Box";
import Paper from "@mui/material/Paper";
import Skeleton from "@mui/material/Skeleton";
import Stack from "@mui/material/Stack";
import Typography from "@mui/material/Typography";
import { alpha } from "@mui/material/styles";
import type { AccountEntry } from "../hooks/useAllAccountsData";
import { numericSx } from "../theme";
import { formatUsd } from "../utils/format";

interface PortfolioOverviewStripProps {
  accounts: AccountEntry[];
  onSelect: (accountId: number) => void;
}

// การ์ดสรุปย่อของแต่ละบัญชี - กดแล้วเลื่อนไปหาส่วนของบัญชีนั้นในหน้าเดียวกัน
// (ไม่ใช่การ "สลับหน้า" ข้อมูลบัญชีอื่นยังอยู่ครบ แค่ scroll ไปหาให้เร็วขึ้น)
function AccountCard({ entry, onSelect }: { entry: AccountEntry; onSelect: (id: number) => void }) {
  const { info, data, error, isLoading } = entry;
  const connected = data?.connection === "connected";
  const pnlToday = data?.account.todayRealizedPnl ?? 0;
  const pnlColor = pnlToday > 0 ? "success.main" : pnlToday < 0 ? "error.main" : "text.secondary";

  if (isLoading && !data) {
    return (
      <Paper
        variant="outlined"
        sx={{ minWidth: 220, p: 1.75, flexShrink: 0, scrollSnapAlign: "start" }}
      >
        <Skeleton width="70%" />
        <Skeleton width="50%" height={32} sx={{ my: 0.5 }} />
        <Skeleton width="40%" />
      </Paper>
    );
  }

  return (
    <Paper
      variant="outlined"
      role="button"
      tabIndex={0}
      aria-label={`เลื่อนไปดูบัญชี ${info.isDemo ? "Demo" : "Live"} #${info.mt5Login}`}
      onClick={() => onSelect(info.accountId)}
      onKeyDown={(e) => {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          onSelect(info.accountId);
        }
      }}
      sx={{
        minWidth: 220,
        p: 1.75,
        flexShrink: 0,
        scrollSnapAlign: "start",
        cursor: "pointer",
        transition: "border-color 120ms, background-color 120ms",
        "&:hover": {
          borderColor: "primary.main",
          bgcolor: (t) => alpha(t.palette.primary.main, 0.04),
        },
        "&:focus-visible": {
          outline: (t) => `2px solid ${t.palette.primary.main}`,
          outlineOffset: 2,
        },
      }}
    >
      <Stack direction="row" alignItems="center" gap={0.75} sx={{ mb: 0.75 }}>
        <Box
          sx={{
            width: 7,
            height: 7,
            borderRadius: "50%",
            bgcolor: connected ? "success.main" : "error.main",
            flexShrink: 0,
          }}
        />
        <Typography variant="caption" fontWeight={700} noWrap>
          {info.isDemo ? "Demo" : "Live"} #{info.mt5Login}
        </Typography>
      </Stack>
      <Typography variant="caption" color="text.disabled" sx={{ display: "block", mb: 0.5 }}>
        {info.brokerName}
      </Typography>

      {error ? (
        <Typography variant="caption" color="warning.main">
          {error}
        </Typography>
      ) : (
        <>
          <Typography sx={{ ...numericSx, fontSize: 22, fontWeight: 700, letterSpacing: "-0.01em" }}>
            {formatUsd(data!.account.equity)}
          </Typography>
          <Typography variant="caption" sx={{ ...numericSx, color: pnlColor }}>
            วันนี้ {formatUsd(pnlToday, true)}
          </Typography>
        </>
      )}
    </Paper>
  );
}

export default function PortfolioOverviewStrip({ accounts, onSelect }: PortfolioOverviewStripProps) {
  if (accounts.length === 0) return null;

  return (
    <Stack gap={0.75}>
      <Typography
        variant="caption"
        sx={{
          textTransform: "uppercase",
          letterSpacing: "0.06em",
          color: "text.disabled",
          fontWeight: 700,
        }}
      >
        ทุกพอร์ต ({accounts.length})
      </Typography>
      <Stack
        direction="row"
        gap={1.25}
        sx={{
          overflowX: "auto",
          scrollSnapType: "x proximity",
          pb: 0.5,
          // ซ่อน scrollbar แต่ยัง scroll/swipe ได้ปกติ (มือถือ swipe อยู่แล้ว
          // โดยธรรมชาติ, บนเดสก์ท็อปลาก/ใช้ trackpad ได้)
          "&::-webkit-scrollbar": { height: 6 },
          "&::-webkit-scrollbar-thumb": { bgcolor: "divider", borderRadius: 3 },
        }}
      >
        {accounts.map((entry) => (
          <AccountCard key={entry.info.accountId} entry={entry} onSelect={onSelect} />
        ))}
      </Stack>
    </Stack>
  );
}
