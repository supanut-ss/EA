import { useCallback, useEffect, useState } from "react";
import type { DashboardSnapshot } from "../types/dashboard";
import { getMockSnapshot } from "../data/mockData";

const POLL_INTERVAL_MS = 10_000;

// ตั้งค่าผ่าน Frontend/.env.local ได้ เช่น VITE_API_BASE_URL=http://localhost:5008
// ไม่ตั้งก็ใช้ค่า default นี้ (ตรงกับ Backend/EaConsole.Api/Properties/launchSettings.json)
const API_BASE_URL = import.meta.env.VITE_API_BASE_URL ?? "http://localhost:5008";
const ACCOUNT_ID = import.meta.env.VITE_ACCOUNT_ID ?? "1";

async function fetchSnapshot(): Promise<DashboardSnapshot> {
  let response: Response;
  try {
    response = await fetch(`${API_BASE_URL}/api/dashboard/snapshot?accountId=${ACCOUNT_ID}`);
  } catch {
    // เข้า backend ไม่ได้เลย (ยังไม่ได้รัน / เน็ตหลุด) — ใช้ mock data แทน
    // ไม่ให้หน้าจอค้างว่างเปล่า พร้อม log เตือนไว้ให้เห็นใน console
    console.warn("เชื่อมต่อ backend ไม่ได้ กำลังโชว์ mock data แทนชั่วคราว");
    return getMockSnapshot();
  }

  if (!response.ok) {
    throw new Error(`Backend ตอบกลับผิดพลาด (HTTP ${response.status})`);
  }

  return (await response.json()) as DashboardSnapshot;
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
