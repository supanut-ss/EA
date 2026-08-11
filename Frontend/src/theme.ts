import { createTheme, type PaletteMode, type ThemeOptions } from "@mui/material/styles";

declare module "@mui/material/styles" {
  interface Palette {
    trading: {
      profit: string;
      profitSoft: string;
      loss: string;
      lossSoft: string;
      info: string;
      infoSoft: string;
    };
  }
  interface PaletteOptions {
    trading?: Palette["trading"];
  }
}

export const FONT_BODY =
  '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif';

export const FONT_MONO =
  'ui-monospace, "Cascadia Mono", "SF Mono", Consolas, "Roboto Mono", monospace';

export const numericSx = {
  fontFamily: FONT_MONO,
  fontVariantNumeric: "tabular-nums",
} as const;

export function getTheme(mode: PaletteMode) {
  const isDark = mode === "dark";

  const options: ThemeOptions = {
    palette: {
      mode,
      background: {
        default: isDark ? "#12131a" : "#f6f4ee",
        paper: isDark ? "#1a1c25" : "#ffffff",
      },
      primary: { main: isDark ? "#c9a24b" : "#9c7a1f" },
      success: { main: isDark ? "#3fb27f" : "#1f8a5c" },
      error: { main: isDark ? "#e2626c" : "#c0313d" },
      info: { main: isDark ? "#5b9bd1" : "#2e6da4" },
      divider: isDark ? "#2e303c" : "#e1ddd0",
      text: {
        primary: isDark ? "#e9e7e2" : "#1d1b16",
        secondary: isDark ? "#8d909d" : "#6b6759",
        disabled: isDark ? "#5c5f6c" : "#9a9686",
      },
      trading: {
        profit: isDark ? "#3fb27f" : "#1f8a5c",
        profitSoft: isDark ? "rgba(63,178,127,0.14)" : "rgba(31,138,92,0.12)",
        loss: isDark ? "#e2626c" : "#c0313d",
        lossSoft: isDark ? "rgba(226,98,108,0.14)" : "rgba(192,49,61,0.12)",
        info: isDark ? "#5b9bd1" : "#2e6da4",
        infoSoft: isDark ? "rgba(91,155,209,0.14)" : "rgba(46,109,164,0.12)",
      },
    },
    shape: { borderRadius: 12 },
    typography: {
      fontFamily: FONT_BODY,
      fontSize: 13,
      h1: { fontWeight: 700 },
      h2: { fontWeight: 700 },
      button: { textTransform: "none", fontWeight: 600 },
    },
    components: {
      MuiCssBaseline: {
        styleOverrides: {
          body: {
            backgroundColor: isDark ? "#12131a" : "#f6f4ee",
          },
        },
      },
      MuiPaper: {
        styleOverrides: {
          root: {
            backgroundImage: "none",
          },
        },
      },
      MuiCard: {
        styleOverrides: {
          root: ({ theme }) => ({
            border: `1px solid ${theme.palette.divider}`,
            boxShadow: isDark
              ? "0 1px 2px rgba(0,0,0,0.3), 0 8px 24px -12px rgba(0,0,0,0.5)"
              : "0 1px 2px rgba(0,0,0,0.06), 0 8px 20px -14px rgba(0,0,0,0.2)",
          }),
        },
      },
      MuiChip: {
        styleOverrides: {
          label: {
            fontWeight: 600,
          },
        },
      },
      MuiTableCell: {
        styleOverrides: {
          head: ({ theme }) => ({
            fontSize: 11,
            textTransform: "uppercase",
            letterSpacing: "0.05em",
            fontWeight: 600,
            color: theme.palette.text.disabled,
          }),
        },
      },
    },
  };

  return createTheme(options);
}
