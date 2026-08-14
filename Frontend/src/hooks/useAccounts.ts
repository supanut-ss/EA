import { useEffect, useState } from "react";
import type { AccountListItem } from "../types/dashboard";

interface UseAccountsResult {
  accounts: AccountListItem[];
  isLoading: boolean;
}

// รายชื่อบัญชีทั้งหมดสำหรับ account picker - โหลดครั้งเดียวตอน mount ไม่ต้อง
// poll ซ้ำแบบ dashboard snapshot เพราะบัญชีใหม่ไม่ได้ถูกเพิ่มบ่อย
export function useAccounts(): UseAccountsResult {
  const [accounts, setAccounts] = useState<AccountListItem[]>([]);
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    fetch("/api/dashboard/accounts")
      .then((res) => (res.ok ? res.json() : Promise.reject(new Error(`HTTP ${res.status}`))))
      .then((list: AccountListItem[]) => {
        if (!cancelled) setAccounts(list);
      })
      .catch(() => {
        if (!cancelled) setAccounts([]);
      })
      .finally(() => {
        if (!cancelled) setIsLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  return { accounts, isLoading };
}
