import { useCallback, useEffect, useRef, useState } from "react";
import type { AccountListItem, DashboardSnapshot } from "../types/dashboard";

const POLL_INTERVAL_MS = 10_000;

export interface AccountEntry {
  info: AccountListItem;
  data: DashboardSnapshot | null;
  error: string | null;
  isLoading: boolean;
}

interface UseAllAccountsDataResult {
  accounts: AccountEntry[];
  isLoadingList: boolean;
  listError: string | null;
}

async function fetchAccountList(): Promise<AccountListItem[]> {
  const res = await fetch("/api/dashboard/accounts");
  if (!res.ok) throw new Error(`โหลดรายชื่อบัญชีไม่สำเร็จ (HTTP ${res.status})`);
  return res.json();
}

async function fetchSnapshot(accountId: number): Promise<DashboardSnapshot> {
  const res = await fetch(`/api/dashboard/snapshot?accountId=${accountId}`);
  if (!res.ok) {
    if (res.status === 404) throw new Error("ยังไม่มีข้อมูล — รอ EA ยิง heartbeat เข้ามาก่อน");
    throw new Error(`โหลดข้อมูลไม่สำเร็จ (HTTP ${res.status})`);
  }
  return res.json();
}

// ดึงข้อมูลทุกบัญชีพร้อมกัน แล้ว poll ต่อเนื่องแบบ "เงียบ" (silent update) -
// ทุก tick หลังจากโหลดครั้งแรกจะอัปเดตค่าที่มีอยู่ในที่เดิม ไม่เคลียร์ data
// เป็น null ก่อน ไม่มี spinner/กระพริบระหว่างที่หน้าจอยังเปิดดูอยู่ - ต่างจาก
// useDashboardData เดิมตรงที่ตัวนี้ดึง "ทุกบัญชีพร้อมกัน" ไม่ใช่เลือกดูทีละบัญชี
// (ดู App.tsx: ผู้ใช้อยากเห็นทุกพอร์ตในหน้าเดียวโดยไม่ต้องสลับ)
export function useAllAccountsData(): UseAllAccountsDataResult {
  const [list, setList] = useState<AccountListItem[]>([]);
  const [listError, setListError] = useState<string | null>(null);
  const [isLoadingList, setIsLoadingList] = useState(true);
  const [byAccountId, setByAccountId] = useState<Record<number, { data: DashboardSnapshot | null; error: string | null; isLoading: boolean }>>({});

  // เก็บ list ปัจจุบันไว้ใน ref กัน closure ใน interval แคบ ๆ อ้าง list เก่า
  const listRef = useRef<AccountListItem[]>([]);
  listRef.current = list;

  const loadOneAccount = useCallback(async (accountId: number) => {
    try {
      const snapshot = await fetchSnapshot(accountId);
      setByAccountId((prev) => ({
        ...prev,
        [accountId]: { data: snapshot, error: null, isLoading: false },
      }));
    } catch (e) {
      setByAccountId((prev) => ({
        ...prev,
        [accountId]: {
          data: prev[accountId]?.data ?? null, // เก็บข้อมูลเก่าไว้โชว์ต่อ แม้ poll รอบนี้จะพลาด
          error: e instanceof Error ? e.message : "โหลดข้อมูลไม่สำเร็จ",
          isLoading: false,
        },
      }));
    }
  }, []);

  const loadList = useCallback(async () => {
    try {
      const accounts = await fetchAccountList();
      setList(accounts);
      setListError(null);
      // บัญชีใหม่ (ยังไม่เคยเห็น) เริ่มที่ isLoading=true ให้เห็น skeleton ตอนแรก
      setByAccountId((prev) => {
        const next = { ...prev };
        for (const a of accounts) {
          if (!(a.accountId in next)) next[a.accountId] = { data: null, error: null, isLoading: true };
        }
        return next;
      });
      await Promise.all(accounts.map((a) => loadOneAccount(a.accountId)));
    } catch (e) {
      setListError(e instanceof Error ? e.message : "โหลดรายชื่อบัญชีไม่สำเร็จ");
    } finally {
      setIsLoadingList(false);
    }
  }, [loadOneAccount]);

  useEffect(() => {
    loadList();
    const listId = setInterval(loadList, POLL_INTERVAL_MS);
    return () => clearInterval(listId);
  }, [loadList]);

  const accounts: AccountEntry[] = list.map((info) => ({
    info,
    data: byAccountId[info.accountId]?.data ?? null,
    error: byAccountId[info.accountId]?.error ?? null,
    isLoading: byAccountId[info.accountId]?.isLoading ?? true,
  }));

  return { accounts, isLoadingList, listError };
}
