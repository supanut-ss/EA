export function formatUsd(value: number, withSign = false): string {
  const abs = Math.abs(value).toLocaleString("en-US", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
  if (!withSign) return `$${abs}`;
  const sign = value > 0 ? "+" : value < 0 ? "−" : "";
  return `${sign}$${abs}`;
}

export function formatPrice(value: number): string {
  return value.toLocaleString("en-US", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
}

export function formatDateTime(isoTimestamp: string): string {
  const d = new Date(isoTimestamp);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${pad(d.getDate())}/${pad(d.getMonth() + 1)}/${d.getFullYear()} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

export function formatRelativeTimeThai(isoTimestamp: string): string {
  const seconds = Math.max(0, Math.round((Date.now() - new Date(isoTimestamp).getTime()) / 1000));
  if (seconds < 60) return `${seconds} วินาทีที่แล้ว`;
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes} นาทีที่แล้ว`;
  const hours = Math.round(minutes / 60);
  return `${hours} ชั่วโมงที่แล้ว`;
}

// ย่อชื่อ EA สำหรับแสดงในตาราง: EA1 Trend Breakout = BO, EA2 Scalping = SP,
// EA3 Counter Trend = CT — จับคู่ด้วย keyword กันชื่อเต็มใน DB เปลี่ยนเล็กน้อย
// (เช่น "Scalping & Session") ชื่อที่ไม่เข้าเงื่อนไข (เช่น "System" ใน
// activity log ที่ไม่มี EA) ให้แสดงตามเดิม
export function formatEaName(name: string): string {
  const lower = name.toLowerCase();
  if (lower.includes("breakout")) return "BO";
  if (lower.includes("scalp")) return "SP";
  if (lower.includes("counter")) return "CT";
  return name;
}

export function formatSide(side: "BUY" | "SELL"): string {
  return side === "BUY" ? "B" : "S";
}
