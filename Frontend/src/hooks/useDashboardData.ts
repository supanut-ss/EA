import { useCallback, useEffect, useState } from "react";
import type { DashboardSnapshot } from "../types/dashboard";

const POLL_INTERVAL_MS = 10_000;

// บัญชีเดียวที่ใช้งานจริงตอนนี้ (ดู schema.sql: ออกแบบรองรับหลายบัญชีใน
// อนาคต แต่ยังใช้จริงแค่ account_id=1 — ตรงกับที่ SignalsController/
// IngestController ฝั่ง backend hardcode ไว้เหมือนกัน)
const ACCOUNT_ID = 1;

async function fetchSnapshot(): Promise<DashboardSnapshot> {
  const res = await fetch(`/api/dashboard/snapshot?accountId=${ACCOUNT_ID}`);
  if (!res.ok) {
    if (res.status === 404) {
      throw new Error(`ยังไม่มีข้อมูล snapshot สำหรับบัญชี ${ACCOUNT_ID} (รอ EA ยิง heartbeat เข้ามาก่อน)`);
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
