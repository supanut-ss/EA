using EaConsole.Api.Data;
using EaConsole.Api.Services;
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

builder.Services.AddDbContext<EaConsoleDbContext>(options =>
    options.UseMySql(connectionString, serverVersion));

builder.Services.AddScoped<IDashboardQueryService, DashboardQueryService>();
builder.Services.AddScoped<IIngestService, IngestService>();

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

if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

// ตั้งใจไม่ใส่ UseHttpsRedirection ตอนนี้ — dev server รันเป็น HTTP ตรงๆ
// คู่กับ Vite frontend (http://localhost:5173) เวลา deploy จริงค่อยให้
// reverse proxy (nginx/IIS) เป็นคน terminate TLS แทน
app.UseCors("Frontend");
app.UseAuthorization();
app.MapControllers();

app.Run();
