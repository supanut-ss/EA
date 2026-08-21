using EaConsole.Api.Data;
using EaConsole.Api.Services;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.EntityFrameworkCore;

var builder = WebApplication.CreateBuilder(args);

var connectionString = builder.Configuration.GetConnectionString("EaConsole")
    ?? throw new InvalidOperationException("Missing ConnectionStrings:EaConsole in configuration.");

// บั๊กที่เจอจริง: ตอนแรกเรียก ServerVersion.AutoDetect(connectionString) อยู่
// "ข้างใน" lambda ที่ส่งให้ AddDbContext — lambda นั้นถูกเรียกใหม่ทุกครั้งที่
// DI สร้าง DbContext ของ scope ใหม่ (คือแทบทุก request) แปลว่าทุก request
// จะเปิดคอนเนกชันเปล่าๆ ไปที่ DB แค่เพื่อถาม version ก่อน แล้วค่อยเปิดจริงอีกที
// พอ DB อยู่ไกล/ช้า อาการนี้ทำให้ request หลุด connect timeout ได้ง่ายมาก —
// ต้อง detect ครั้งเดียวตอน startup แล้ว cache ผลไว้ใช้ซ้ำแทน
var serverVersion = ServerVersion.AutoDetect(connectionString);

// Real incident (2026-08-13 to 08-20): this host's MariaDB rejects new
// connections once thaipes_sa hits max_user_connections=30 - under bursty
// concurrent load (EA1/EA2 heartbeats, trade posts, EA3 signals, and
// dashboard polling all landing near the same 10s tick) that limit gets hit
// often enough to matter (85k+ Aborted_connects observed on this server).
// Each rejection used to surface as an unhandled MySqlException -> bare
// HTTP 500 to the EA, and a POST that never gets retried by the EA client
// means that trade/log event is gone forever. EnableRetryOnFailure makes
// EF Core retry the transient connection/command failure itself before
// giving up, so a momentary connection-limit blip no longer drops data.
builder.Services.AddDbContext<EaConsoleDbContext>(options =>
    options.UseMySql(connectionString, serverVersion, mySqlOptions =>
        mySqlOptions.EnableRetryOnFailure(maxRetryCount: 4, maxRetryDelay: TimeSpan.FromSeconds(4), errorNumbersToAdd: null)));

builder.Services.AddScoped<IDashboardQueryService, DashboardQueryService>();
builder.Services.AddScoped<IIngestService, IngestService>();
builder.Services.AddHostedService<SnapshotRetentionService>();

var allowedOrigins = builder.Configuration.GetSection("Cors:AllowedOrigins").Get<string[]>() ?? [];
builder.Services.AddCors(options =>
{
    options.AddPolicy("Frontend", policy =>
        policy.WithOrigins(allowedOrigins).AllowAnyHeader().AllowAnyMethod());
});

builder.Services.AddControllers();
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();

var app = builder.Build();

// ต้องอยู่ก่อน middleware อื่นที่สนใจ scheme/remote IP จริง — จำเป็นเมื่อ
// deploy หลัง reverse proxy/load balancer (nginx, IIS, หรือ PaaS ส่วนใหญ่)
// ที่ terminate TLS ให้แล้วส่งต่อมาเป็น HTTP ข้างใน ไม่ใส่ตัวนี้ app จะเห็น
// ทุก request เป็น HTTP เสมอและไม่รู้ remote IP จริงของผู้เรียก
app.UseForwardedHeaders(new ForwardedHeadersOptions
{
    ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto,
});

// Real incident (2026-08-13): EA2's InpIngestBaseUrl was misconfigured with
// a trailing slash ("https://.../" + "/api/ingest/snapshot" = a literal
// "//api/ingest/snapshot"). ASP.NET Core's router treats the doubled slash
// as a distinct, non-matching path - not "the same route", just 404 - so
// every heartbeat silently failed with no data ever reaching the DB. A
// stray slash in a client config is exactly the kind of thing that WILL
// happen again (copy-paste, re-entering settings), so collapse repeated
// slashes here rather than trusting every client to get the URL exactly
// right forever.
app.Use(async (context, next) =>
{
    var path = context.Request.Path.Value;
    if (!string.IsNullOrEmpty(path) && path.Contains("//"))
    {
        while (path.Contains("//")) path = path.Replace("//", "/");
        context.Request.Path = path;
    }
    await next();
});

if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

// Serve the built Frontend (Vite dist output) from wwwroot for the
// single-host deploy (deploy.ps1 copies Frontend/dist into wwwroot before
// `dotnet publish`) — no-op in local dev since wwwroot stays empty there
// (dev uses the separate Vite dev server on :5173 instead, via CORS above).
app.UseDefaultFiles();
app.UseStaticFiles();

// Health check endpoint สำหรับ platform ที่ deploy จริง (load balancer /
// uptime monitor / container healthcheck ส่วนใหญ่ต้องการ endpoint แบบนี้)
// "release" มาจาก Release:Id (env var Release__Id ที่ deploy/build.ps1 เขียน
// ลง web.config ตอน build) - ให้ deploy script poll endpoint นี้หลัง deploy
// จนกว่า release ที่ตอบกลับจะตรงกับตัวที่เพิ่ง ship แทนที่จะเชื่อแค่ HTTP 200
// เฉยๆ (process เก่าอาจยังตอบ 200 อยู่ระหว่างที่ IIS กำลัง recycle ไป process ใหม่)
app.MapGet("/health", (IConfiguration config) =>
    Results.Ok(new { status = "ok", release = config["Release:Id"] ?? "unknown" }));

// ตั้งใจไม่ใส่ UseHttpsRedirection ตอนนี้ — dev server รันเป็น HTTP ตรงๆ
// คู่กับ Vite frontend (http://localhost:5173) เวลา deploy จริงให้
// reverse proxy (nginx/IIS) หรือ PaaS เป็นคน terminate TLS แทน
app.UseCors("Frontend");

// Gate เฉพาะ endpoint ที่ EA ยิงเข้ามา (/api/ingest ของ EA1/EA2, /api/signals
// ของ EA3) ด้วย shared API key ก่อน deploy จริง — ตอนนี้ปิดอยู่โดย default
// (Ingest:ApiKey ว่าง = ไม่เช็ค, พฤติกรรมเดิมเป๊ะสำหรับ dev บน localhost)
// ตั้งค่า Ingest:ApiKey (หรือ env var Ingest__ApiKey) แล้ว EA ต้องส่ง header
// X-Api-Key มาให้ตรงกันถึงจะผ่าน — endpoint ฝั่งอ่าน (Dashboard) ไม่โดน gate
// นี้ เพราะ frontend เรียกจาก browser ผ่าน CORS ไม่มีที่เก็บ secret ให้ปลอดภัย
var ingestApiKey = app.Configuration["Ingest:ApiKey"];
app.Use(async (context, next) =>
{
    var path = context.Request.Path;
    bool isGatedPath = path.StartsWithSegments("/api/ingest") || path.StartsWithSegments("/api/signals");
    if (!string.IsNullOrEmpty(ingestApiKey) && isGatedPath)
    {
        if (!context.Request.Headers.TryGetValue("X-Api-Key", out var provided) || provided != ingestApiKey)
        {
            context.Response.StatusCode = StatusCodes.Status401Unauthorized;
            return;
        }
    }
    await next();
});

app.UseAuthorization();
app.MapControllers();

app.Run();
