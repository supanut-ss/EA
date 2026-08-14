import { useCallback, useEffect, useState } from "react";
import type { DashboardSnapshot } from "../types/dashboard";

const POLL_INTERVAL_MS = 10_000;

async function fetchSnapshot(accountId: number): Promise<DashboardSnapshot> {
  const res = await fetch(`/api/dashboard/snapshot?accountId=${accountId}`);
  if (!res.ok) {
    if (res.status === 404) {
      throw new Error(`ยังไม่มีข้อมูล snapshot สำหรับบัญชี ${accountId} (รอ EA ยิง heartbeat เข้ามาก่อน)`);
    }
    throw new Error(`โหลดข้อมูล dashboard ไม่สำเร็จ (HTTP ${res.status})`);
  }
  return res.json();
}

interface UseDashboardDataResult {
  data: DashboardSnapshot | null;
  error: string | null;
  isLoading: boolean;
  refresh: () => void;
}

// accountId มาจากตัวเลือกบัญชีบน UI (ดู useAccounts + App.tsx) - เปลี่ยน
// บัญชีแล้ว effect ด้านล่างจะ refetch ให้เองเพราะ accountId อยู่ใน deps
export function useDashboardData(accountId: number): UseDashboardDataResult {
  const [data, setData] = useState<DashboardSnapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(true);

  const load = useCallback(async () => {
    try {
      const snapshot = await fetchSnapshot(accountId);
      setData(snapshot);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : "โหลดข้อมูล dashboard ไม่สำเร็จ");
    } finally {
      setIsLoading(false);
    }
  }, [accountId]);

  useEffect(() => {
    setData(null);
    setIsLoading(true);
    load();
    const id = setInterval(load, POLL_INTERVAL_MS);
    return () => clearInterval(id);
  }, [load]);

  return { data, error, isLoading, refresh: load };
}
