# Deploy Checklist — EaConsole.Api

**Live ตั้งแต่ 12-13 ส.ค. 2026: `https://ea.thaipesleague.com`** — shared IIS+Plesk hosting ผ่าน FTP เดียวกับโปรเจกต์ ATS เดิม (`94.237.76.153`) ยืนยันแล้วว่าทำงานจริงครบวงจร (`/health` → 200, root page → 200, `POST /api/ingest/snapshot` พร้อม `X-Api-Key` → 202 แล้วข้อมูลลง MySQL จริง, ไม่มี API key → 401, `web.config`/`logs/`/`swagger` ไม่ web-accessible) ดูสคริปต์จริงที่ [../deploy.ps1](../deploy.ps1) — หัวข้อนี้ยังเก็บหลักการทั่วไปไว้เผื่อย้าย host ในอนาคต ส่วนขั้นตอนที่ใช้จริงตอนนี้อยู่หัวข้อ "วิธี deploy จริง (FTP + IIS single-host)" ด้านล่าง

## บทเรียนจากการ deploy จริงรอบแรก (สำคัญ — อ่านก่อนรันซ้ำ)

Deploy จริงรอบแรกเจอปัญหาใหญ่ 3 อย่างเรียงกัน กว่าจะขึ้นสำเร็จ:

1. **Bitness: ต้องเป็น `win-x86`** — ลองสลับไป `win-x64` แล้วเจอ error ชัดเจน "500.32 - Failed to load .NET Core host: published for a different bitness than w3wp.exe" ยืนยันว่า App Pool ของ `ea.thaipesleague.com` เป็น 32-bit จริง ต้อง publish `-r win-x86` เท่านั้น (ตรงกับที่ตัวอย่าง ATS ใช้อยู่แล้ว — อย่าเปลี่ยนโดยไม่เช็ค IIS App Pool ก่อน)
2. **`upload-ftp.ps1` เคย silent-skip ไฟล์สำคัญ** — โค้ดเดิมเจอ error 550 บน attempt ที่ไม่ใช่ attempt แรก จะ mark ว่า "SKIPPED" แล้ว return success เงียบๆ (ไม่ throw) ทำให้ `System.Text.Json.dll` ไม่ได้ถูกอัปโหลดจริง แต่ script รายงาน exit 0 — แก้แล้วให้ throw เสมอถ้าอัปไม่สำเร็จจริงหลัง retry ครบ
3. **Host นี้มีอาการ "ghost success"** — FTP `STOR` ตอบ 226 (สำเร็จ) แต่ไฟล์บางไฟล์ (`EaConsole.Api.exe`, `Microsoft.Extensions.FileProviders.Abstractions.dll`) หายไปจริงในเวลาต่อมา ทั้งที่ log บอกว่า "Uploaded" — แก้โดยเพิ่ม **post-upload verification**: หลังอัปโหลดทุกไฟล์ เช็ค `GetFileSize` จริงบนเซิร์ฟเวอร์ทันที ถ้าไม่ตรง size ให้ retry ใหม่ ไม่เชื่อ response จาก FTP อย่างเดียว

**สรุป workflow ที่ใช้ได้จริงตอนนี้:** publish `win-x86` self-contained → patch web.config → อัปโหลดด้วย `upload-ftp.ps1` เวอร์ชันที่มี retry + post-upload verify แล้ว (ไม่ใช่เวอร์ชันตัวอย่างดิบๆ จาก ATS) → ทดสอบก่อนลบ `app_offline.htm` ทุกครั้ง อย่าลบทันทีที่ script คืน exit 0 อย่างเดียว

ไม่มี `appsettings.Production.json` ในโปรเจกต์นี้โดยตั้งใจ — ตั้งค่าที่ต่างกันต่อ environment (connection string, CORS origin, API key) ผ่าน **environment variables** แทน (มาตรฐาน 12-factor, ไม่ commit ค่าจริงลง git) ASP.NET Core override ค่าใน `appsettings.json` ด้วย env var โดยอัตโนมัติอยู่แล้ว ไม่ต้องแก้โค้ด — บน shared IIS hosting ที่ไม่มี UI ตั้ง env var ระดับ process ให้ `deploy.ps1` เป็นคนแก้ให้ผ่าน `web.config` ที่ `dotnet publish` สร้างมา (ดูหัวข้อด้านล่าง)

## Environment variables ที่ต้องตั้งจริงตอน deploy

| ตัวแปร | ตัวอย่าง | หมายเหตุ |
|---|---|---|
| `ASPNETCORE_ENVIRONMENT` | `Production` | ปิด Swagger UI อัตโนมัติ (เปิดแค่ตอน `Development`) |
| `ConnectionStrings__EaConsole` | `Server=your-db-host;Port=3306;Database=ea_console;User=ea_console_app;Password=REAL_PASSWORD;` | **ต้องตั้ง** ค่าใน `appsettings.json` เป็นแค่ placeholder (`CHANGE_ME`) เท่านั้น app จะ crash ตอน start ถ้าต่อ MySQL จริงไม่ได้ (`ServerVersion.AutoDetect` เช็คตั้งแต่ boot) |
| `Cors__AllowedOrigins__0` | `https://your-frontend-domain.com` | โดเมนจริงของ Frontend (Vite build) ค่า default ในไฟล์คือ `http://localhost:5173` เท่านั้น ถ้าไม่ตั้งใหม่ frontend ที่ deploy จริงจะโดน CORS บล็อก |
| `Ingest__ApiKey` | สุ่มค่ายาวๆ (เช่น `openssl rand -hex 32`) | **แนะนำอย่างยิ่งให้ตั้ง** — endpoint `/api/ingest/*` ไม่มี auth เลยถ้าไม่ตั้งค่านี้ (ออกแบบไว้ให้ปิดง่ายตอน dev บน localhost) เมื่อตั้งแล้ว EA ทุกตัวต้องส่ง header `X-Api-Key` มาให้ตรงกัน (ตั้งที่ input `InpIngestApiKey` ใน MT5) |
| `ASPNETCORE_URLS` | `http://+:8080` (หรือตาม platform กำหนด) | บางแพลตฟอร์ม (Docker, Azure App Service) กำหนด port ให้เองผ่าน env var `PORT`/`WEBSITES_PORT` ต้อง map ให้ตรง |

## ก่อน deploy ต้องมี MySQL 8.0 พร้อมสคีมาแล้ว

โปรเจกต์นี้**ไม่ได้ใช้ EF Core Migrations** — รัน SQL ตรงๆ:
1. `Backend/Database/schema.sql` (สร้าง database + ตาราง + view + stored procedure ทั้งหมด)
2. (ถ้าต้องการข้อมูลทดสอบ) `Backend/Database/seed_sample_data.sql`

ต้องรันบน MySQL instance จริงที่ backend จะต่อ (ผ่าน `ConnectionStrings__EaConsole` ข้างบน) ก่อน start backend ครั้งแรก

## Reverse proxy / TLS

`Program.cs` ตั้งใจไม่ใส่ `UseHttpsRedirection` — ให้ reverse proxy/PaaS (nginx, IIS, Azure App Service, Railway ฯลฯ) เป็นคน terminate TLS แทน แต่มี `UseForwardedHeaders()` เพิ่มแล้ว (อ่าน `X-Forwarded-For`/`X-Forwarded-Proto`) เพื่อให้ app เห็น scheme/remote IP จริงถูกต้องตอนอยู่หลัง proxy — ถ้า deploy หลัง reverse proxy ต้องแน่ใจว่า proxy ส่ง header เหล่านี้มาด้วย (nginx: `proxy_set_header X-Forwarded-Proto $scheme;` เป็นต้น)

## Health check

`GET /health` → `{"status":"ok"}` — ไม่ต่อ DB (เช็คแค่ process ตอบสนอง) ใช้กับ load balancer/uptime monitor/container healthcheck ได้ทันที

## หลัง deploy แล้ว ต้องอัปเดตที่ EA ด้วย

ทั้ง 2 EA (`XAUUSD_TrendBreakout_EA.mq5`, `XAUUSD_Scalping_EA.mq5`) มี input `InpIngestBaseUrl` (default ชี้ไป `http://localhost:5008` สำหรับ dev) ต้องเปลี่ยนเป็น URL จริงของ backend หลัง deploy แล้ว และ:
- เพิ่ม URL นั้นใน MT5: **Tools > Options > Expert Advisors > Allow WebRequest for listed URL**
- ถ้าตั้ง `Ingest__ApiKey` ไว้ ต้องตั้ง `InpIngestApiKey` ใน MT5 ให้ตรงกันด้วย (ดูหัวข้อ "Backend Ingest" ใน `MQ5/XAUUSD_TrendBreakout_EA_Summary.md`)

## วิธี deploy จริง (FTP + IIS single-host) — `deploy.ps1`

ทำตามแบบสคริปต์ deploy ที่ใช้กับโปรเจกต์ ATS เดิมบน host เดียวกัน — build Frontend, ก็อปปี้เข้า `Backend/EaConsole.Api/wwwroot` (serve เป็น static files ผ่าน `UseDefaultFiles()/UseStaticFiles()` ที่เพิ่มใน `Program.cs`), publish backend แบบ `win-x86 --self-contained true`, แก้ `web.config` ที่ publish ออกมาให้มี env var จริง แล้วอัปโหลดผ่าน FTP (พัก `app_offline.htm` ก่อนทับไฟล์ กันไฟล์ที่ IIS ล็อกไว้ระหว่างรัน):

```powershell
.\deploy.ps1 -DbConnectionString "Server=...;Port=3306;Database=ea_console;User=ea_console_app;Password=REAL_PASSWORD;" -IngestApiKey "ค่าสุ่มยาวๆ"
```

- `-Server`/`-Username`/`-Password`/`-RemotePath` มี default ชี้ไป `ea.thaipesleague.com` บนบัญชี FTP เดียวกับ ATS อยู่แล้ว ปกติไม่ต้องส่งซ้ำ
- `-DbConnectionString`/`-IngestApiKey` **ไม่มี default** — ถ้าไม่ส่งมา สคริปต์จะ warn ชัดเจนแล้ว deploy ต่อโดยไม่แก้ค่านั้นใน web.config (กัน deploy เงียบๆด้วยค่าที่ผิด)
- `-CorsOrigin` default เป็น `https://<RemotePath>` (ใช้ได้เลยเพราะ single-host — frontend อยู่ domain เดียวกับ backend ไม่ต้องพึ่ง CORS จริงจัง แต่ตั้งไว้เผื่ออนาคตแยก host)
- ไฟล์ `deploy.ps1` เอง (และ `upload-ftp.ps1`) ถูก commit เข้า git **พร้อม FTP credential แบบ plaintext** (ตามรูปแบบเดิมของสคริปต์ ATS ที่ใช้อ้างอิง) — **secret ของ backend เอง (DB password, Ingest API key) ไม่ได้ hardcode ในสคริปต์** ต้องส่งเป็น parameter ทุกครั้งที่ deploy เก็บไว้นอก git (เช่น password manager หรือไฟล์ local ที่ไม่ commit)

⚠️ **ต้องมี MySQL 8.0 จริงให้ backend ต่อได้ก่อน** (ดูหัวข้อด้านบน) และ subdomain `ea.thaipesleague.com` ต้องผูก IIS site + ASP.NET Core Module ไว้แล้วฝั่ง server (นอกเหนือจากที่ FTP อัปโหลดไฟล์ได้ — เป็นการตั้งค่าฝั่ง hosting panel ที่สคริปต์นี้ทำแทนไม่ได้)

## ยังไม่ได้ทำ

- ยังไม่เคยรัน `deploy.ps1` จริงเลย — รอ MySQL พร้อมก่อน (ดูหัวข้อด้านบน) และรอค่า DB password/Ingest API key จริงจากผู้ใช้
- ไม่มี retry policy ถ้า MySQL ยังไม่พร้อมตอน backend start (fail ทันทีด้วย exception ชัดเจน ไม่ retry เงียบๆ)
