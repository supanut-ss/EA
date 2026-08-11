import Alert from "@mui/material/Alert";
import AlertTitle from "@mui/material/AlertTitle";
import type { ConnectionState, EaStatus } from "../types/dashboard";

interface StatusBannersProps {
  connection: ConnectionState;
  eaStatuses: EaStatus[];
}

export default function StatusBanners({ connection, eaStatuses }: StatusBannersProps) {
  const deployed = eaStatuses.filter((ea) => ea.state !== "not_deployed");
  const allStandby = deployed.length > 0 && deployed.every((ea) => ea.state === "standby");

  if (connection === "disconnected") {
    return (
      <Alert severity="error" variant="outlined">
        <AlertTitle>ขาดการเชื่อมต่อกับ MT5 Terminal</AlertTitle>
        ไม่ได้รับข้อมูลใหม่จาก EA — ตัวเลขที่แสดงด้านล่างอาจไม่ใช่ค่าล่าสุด ตรวจสอบว่า Terminal
        เปิดอยู่และ EA ยัง attach กับกราฟ
      </Alert>
    );
  }

  if (allStandby) {
    return (
      <Alert severity="warning" variant="outlined">
        <AlertTitle>นอกช่วงเวลาเทรด — ไม่ใช่ error</AlertTitle>
        ตอนนี้อยู่นอกช่วง session ที่ตั้งค่าไว้ EA จะไม่เปิดไม้ใหม่จนกว่าจะถึงรอบถัดไป
        แต่ยังทำงานอยู่เบื้องหลังเพื่อติดตามราคา
      </Alert>
    );
  }

  return null;
}
