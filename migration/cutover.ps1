# ย้ายเว็บไป Supabase ใหม่ (Singapore) ในครั้งเดียว
# ถามรหัสผ่าน 2 ตัว + secret key 1 ตัว (พิมพ์แล้วไม่ขึ้นบนจอ) แล้วทำให้เองทั้งหมด:
# ปิดโปรเจกต์เดิม + ดึงข้อมูล -> ใส่โปรเจกต์ใหม่ -> ตรวจ -> ก๊อปไฟล์ -> ตั้งค่าแจ้งเตือน
# รหัสผ่านอยู่ในหน้าต่างนี้เท่านั้น ไม่ได้บันทึกลงไฟล์

$ErrorActionPreference = 'Stop'
if (-not (Get-Command psql -ErrorAction SilentlyContinue)) { $env:Path += ';C:\Program Files\PostgreSQL\17\bin' }
Set-Location $PSScriptRoot

function Read-Secret($prompt) {
  $s = Read-Host -AsSecureString $prompt
  $p = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
  if (-not $p) { throw 'ไม่ได้ใส่รหัสผ่าน - รันใหม่อีกครั้ง' }
  return [uri]::EscapeDataString($p)
}
function Test-Db($url, $name) {
  $ErrorActionPreference = 'Continue'   # psql errors must not stop the retry loop
  for ($i = 1; $i -le 10; $i++) {
    $r = psql $url -At -c 'show server_version_num' 2>&1
    if ($LASTEXITCODE -eq 0) { return [int]("$r".Trim()) }
    if ("$r" -match 'password authentication failed') { throw "รหัสผ่านฐานข้อมูล$name ไม่ถูกต้อง - รันใหม่แล้วใส่อีกครั้ง" }
    Write-Host "  ยังเชื่อมต่อฐานข้อมูล$name ไม่ได้ (ครั้งที่ $i/10) รอ 15 วินาทีแล้วลองใหม่..."
    Start-Sleep -Seconds 15
  }
  throw "เชื่อมต่อฐานข้อมูล$name ไม่ได้ - ส่งข้อความนี้ให้ Claude"
}

Write-Host ''
Write-Host '=== ย้าย Supabase ของ BLM48 ===' -ForegroundColor Cyan
Write-Host 'ตอนพิมพ์/วาง จะไม่มีอะไรขึ้นบนจอ เป็นเรื่องปกติ วางแล้วกด Enter ได้เลย' -ForegroundColor Yellow
Write-Host ''
$oldPw = Read-Secret '1) รหัสผ่านฐานข้อมูล โปรเจกต์เดิม (rqhwzbrcgnpxtuaeoxml)'
$newPw = Read-Secret '2) รหัสผ่านฐานข้อมูล โปรเจกต์ใหม่ Singapore (fgovrwnjvdwvtsjeuhjj)'
$env:OLD_DB_URL = "postgresql://postgres.rqhwzbrcgnpxtuaeoxml:$oldPw@aws-0-ap-southeast-1.pooler.supabase.com:5432/postgres?sslmode=require"
$env:NEW_DB_URL = "postgresql://postgres.fgovrwnjvdwvtsjeuhjj:$newPw@aws-1-ap-southeast-1.pooler.supabase.com:5432/postgres?sslmode=require"
$env:NEW_REF = 'fgovrwnjvdwvtsjeuhjj'
$s = Read-Host -AsSecureString '3) Secret key ของโปรเจกต์ใหม่ (ขึ้นต้นด้วย sb_secret_ อยู่ที่ Settings > API Keys)'
$env:NEW_SERVICE_ROLE_KEY = ([Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))).Trim()
if ($env:NEW_SERVICE_ROLE_KEY -notmatch '^(sb_secret_|eyJ)') { throw 'อันนี้ไม่ใช่ secret key (ต้องขึ้นต้นด้วย sb_secret_) - รันใหม่อีกครั้ง' }
$env:NEW_SUPABASE_URL = 'https://fgovrwnjvdwvtsjeuhjj.supabase.co'

Write-Host ''
Write-Host '[ขั้น 1/6] เช็กฐานข้อมูลทั้งสองฝั่ง...' -ForegroundColor Cyan
$vo = Test-Db $env:OLD_DB_URL 'เดิม'
$vn = Test-Db $env:NEW_DB_URL 'ใหม่'
if ($vn -lt 170000) { throw "โปรเจกต์ใหม่ใช้ Postgres $vn แต่ต้องเป็น 17 - หยุดก่อน แล้วบอก Claude" }
$tables = psql $env:NEW_DB_URL -At -c "select count(*) from pg_tables where schemaname='public'"
if ([int]$tables -ne 0) { throw "โปรเจกต์ใหม่มีตารางอยู่แล้ว $tables ตาราง - หยุดก่อน แล้วบอก Claude" }
Write-Host '  เรียบร้อย: เชื่อมต่อได้ทั้งคู่ และโปรเจกต์ใหม่ยังว่าง' -ForegroundColor Green

Write-Host ''
Write-Host '[ขั้น 2/6] ปิดโปรเจกต์เดิม + ดึงข้อมูลออก (ข้อความต่อจากนี้เป็นภาษาอังกฤษ ไม่ต้องตกใจ)...' -ForegroundColor Cyan
.\1_freeze_and_export.ps1

Write-Host ''
Write-Host '[ขั้น 3/6] ใส่ข้อมูลเข้าโปรเจกต์ใหม่ (ใช้เวลาหลายนาที)...' -ForegroundColor Cyan
.\2_import.ps1

Write-Host ''
Write-Host '[ขั้น 4/6] ตรวจจำนวนข้อมูลทุกตาราง (ต้องขึ้น "All ... tables match." สีเขียว)...' -ForegroundColor Cyan
.\4_verify.ps1

Write-Host ''
Write-Host '[ขั้น 5/6] ก๊อปไฟล์รูป (จากโปรเจกต์ Tokyo เพราะ Storage เดิมถูกล็อก)...' -ForegroundColor Cyan
$env:SOURCE_SUPABASE_URL = 'https://xfonixnappsvswwvjlwg.supabase.co'
node .\copy-storage.mjs
if ($LASTEXITCODE -ne 0) { Write-Host '  มีไฟล์ขาดอยู่บ้าง (ประมาณ 126 ไฟล์ เป็นเรื่องปกติ) - Claude จะก๊อปให้ทีหลัง' -ForegroundColor Yellow }
Remove-Item Env:NEW_SERVICE_ROLE_KEY -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '[ขั้น 6/6] ตั้งค่าระบบแจ้งเตือน: จะเปิดเบราว์เซอร์ให้ล็อกอิน Supabase' -ForegroundColor Cyan
Write-Host '  ล็อกอินด้วยบัญชีที่เป็นเจ้าของโปรเจกต์ Singapore แล้วกลับมาที่หน้าต่างนี้' -ForegroundColor Yellow
npx supabase login
.\5_set_push_secrets.ps1

Write-Host ''
Write-Host '=== เสร็จแล้ว! กลับไปบอก Claude ว่า "ย้ายเสร็จแล้ว" ===' -ForegroundColor Green
