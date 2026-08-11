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

export function formatRelativeTimeThai(isoTimestamp: string): string {
  const seconds = Math.max(0, Math.round((Date.now() - new Date(isoTimestamp).getTime()) / 1000));
  if (seconds < 60) return `${seconds} วินาทีที่แล้ว`;
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes} นาทีที่แล้ว`;
  const hours = Math.round(minutes / 60);
  return `${hours} ชั่วโมงที่แล้ว`;
}
