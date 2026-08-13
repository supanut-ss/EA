import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      // เฉพาะตอน dev เท่านั้น — production ให้ backend serve หน้า static
      // จาก wwwroot ตรงๆ ทำให้ frontend/backend เป็น origin เดียวกันอยู่แล้ว
      // (ดู deploy.ps1) จึงไม่ต้อง proxy ตอน build จริง
      "/api": "http://localhost:5008",
    },
  },
});
