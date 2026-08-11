import { useCallback, useEffect, useState } from "react";
import type { DashboardSnapshot } from "../types/dashboard";
import { getMockSnapshot } from "../data/mockData";

const POLL_INTERVAL_MS = 10_000;

// จุดเดียวที่ผูกกับแหล่งข้อมูลจริง — ตอนต่อ backend ให้แทนบรรทัดข้างล่างด้วย
// เช่น `const res = await fetch('/api/dashboard/snapshot'); return res.json();`
// โดยไม่ต้องแก้ component ไหนเลย เพราะทุกอย่างอ่านผ่าน useDashboardData()
async function fetchSnapshot(): Promise<DashboardSnapshot> {
  return getMockSnapshot();
}

interface UseDashboardDataResult {
  data: DashboardSnapshot | null;
  error: string | null;
  isLoading: boolean;
  refresh: () => void;
}

export function useDashboardData(): UseDashboardDataResult {
  const [data, setData] = useState<DashboardSnapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(true);

  const load = useCallback(async () => {
    try {
      const snapshot = await fetchSnapshot();
      setData(snapshot);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : "โหลดข้อมูล dashboard ไม่สำเร็จ");
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
    const id = setInterval(load, POLL_INTERVAL_MS);
    return () => clearInterval(id);
  }, [load]);

  return { data, error, isLoading, refresh: load };
}
