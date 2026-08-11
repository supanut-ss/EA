import Stack from "@mui/material/Stack";
import ToggleButton from "@mui/material/ToggleButton";
import ToggleButtonGroup from "@mui/material/ToggleButtonGroup";
import Typography from "@mui/material/Typography";
import type { EaStatus } from "../types/dashboard";

interface EaFilterBarProps {
  eaStatuses: EaStatus[];
  value: string;
  onChange: (value: string) => void;
}

export default function EaFilterBar({ eaStatuses, value, onChange }: EaFilterBarProps) {
  return (
    <Stack direction="row" alignItems="center" flexWrap="wrap" gap={1.5}>
      <Typography
        variant="caption"
        sx={{
          textTransform: "uppercase",
          letterSpacing: "0.06em",
          color: "text.disabled",
          fontWeight: 700,
        }}
      >
        กรองตาม EA
      </Typography>
      <ToggleButtonGroup
        size="small"
        exclusive
        value={value}
        onChange={(_, next) => next && onChange(next)}
        aria-label="กรองตาม EA"
      >
        <ToggleButton value="all" sx={{ px: 1.5, textTransform: "none" }}>
          ทั้งหมด
        </ToggleButton>
        {eaStatuses.map((ea) => (
          <ToggleButton key={ea.id} value={ea.id} sx={{ px: 1.5, textTransform: "none" }}>
            {ea.name}
          </ToggleButton>
        ))}
      </ToggleButtonGroup>
    </Stack>
  );
}
