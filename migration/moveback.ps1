# ย้ายกลับไปโปรเจกต์เดิม (rqhwzbrcgnpxtuaeoxml) จาก Singapore (fgovrwnjvdwvtsjeuhjj)
# ถามรหัสผ่านฐานข้อมูล 2 ตัว + secret key ของโปรเจกต์เดิม 1 ตัว (พิมพ์แล้วไม่ขึ้นบนจอ)
# ทำให้เอง: ปิด Singapore + ดึงข้อมูล -> แทนข้อมูลในโปรเจกต์เดิม -> ตรวจ -> เปิดโปรเจกต์เดิม
#           -> ก๊อปรูปที่อัปหลังย้าย -> ตั้ง key แจ้งเตือนของโปรเจกต์เดิม
# รหัสผ่านอยู่ในหน้าต่างนี้เท่านั้น ไม่ได้บันทึกลงไฟล์
# ถ้าพังก่อนขั้น 5: ข้อมูลโปรเจกต์เดิมไม่ถูกแตะ (โหลดใน transaction เดียว) -> เปิด Singapore กลับด้วย .\moveback.ps1 -UnfreezeSingapore

param([switch]$UnfreezeSingapore)
$ErrorActionPreference = 'Stop'
if (-not (Get-Command psql -ErrorAction SilentlyContinue)) { $env:Path += ';C:\Program Files\PostgreSQL\17\bin' }
Set-Location $PSScriptRoot
$OLD_REF = 'rqhwzbrcgnpxtuaeoxml'
$SG_REF  = 'fgovrwnjvdwvtsjeuhjj'
$out = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force $out | Out-Null

function Read-Plain($prompt) {
  $s = Read-Host -AsSecureString $prompt
  $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
  try { return ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)).Trim() } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}
function Assert-Ok($what) { if ($LASTEXITCODE -ne 0) { throw "$what ไม่สำเร็จ (exit $LASTEXITCODE) - ส่งข้อความนี้ให้ Claude" } }
function Test-Db($url, $name) {
  $ErrorActionPreference = 'Continue'
  for ($i = 1; $i -le 10; $i++) {
    $r = psql $url -At -c 'show server_version_num' 2>&1
    if ($LASTEXITCODE -eq 0) { return }
    if ("$r" -match 'password authentication failed') { throw "รหัสผ่านฐานข้อมูล$name ไม่ถูกต้อง - รันใหม่แล้วใส่อีกครั้ง" }
    Write-Host "  ยังเชื่อมต่อฐานข้อมูล$name ไม่ได้ (ครั้งที่ $i/10) รอ 15 วินาที..."
    Start-Sleep -Seconds 15
  }
  throw "เชื่อมต่อฐานข้อมูล$name ไม่ได้ - ส่งข้อความนี้ให้ Claude"
}

Write-Host ''
Write-Host '=== ย้าย BLM48 กลับไปโปรเจกต์เดิม ===' -ForegroundColor Cyan
Write-Host 'ตอนพิมพ์/วาง จะไม่มีอะไรขึ้นบนจอ เป็นเรื่องปกติ วางแล้วกด Enter ได้เลย' -ForegroundColor Yellow
$sgPw = [uri]::EscapeDataString((Read-Plain "1) รหัสผ่านฐานข้อมูล Singapore ($SG_REF)"))
$env:SG_DB_URL = "postgresql://postgres.${SG_REF}:$sgPw@aws-1-ap-southeast-1.pooler.supabase.com:5432/postgres?sslmode=require"

if ($UnfreezeSingapore) {
  Test-Db $env:SG_DB_URL ' Singapore'
  psql $env:SG_DB_URL -v ON_ERROR_STOP=1 -c "grant usage on schema public to anon, authenticated, service_role; select cron.alter_job(jobid, active := true) from cron.job;"; Assert-Ok 'เปิด Singapore'
  Write-Host 'เปิด Singapore กลับแล้ว เว็บใช้งานได้เหมือนเดิม' -ForegroundColor Green
  return
}

$oldPw = [uri]::EscapeDataString((Read-Plain "2) รหัสผ่านฐานข้อมูล โปรเจกต์เดิม ($OLD_REF)"))
$env:OLD_DB_URL = "postgresql://postgres.${OLD_REF}:$oldPw@aws-0-ap-southeast-1.pooler.supabase.com:5432/postgres?sslmode=require"
$env:OLD_SERVICE_ROLE_KEY = Read-Plain "3) Secret key ของโปรเจกต์เดิม (sb_secret_... หรือ service_role eyJ... ที่ Settings > API Keys ของ $OLD_REF)"
if ($env:OLD_SERVICE_ROLE_KEY -notmatch '^(sb_secret_|eyJ)') { throw 'อันนี้ไม่ใช่ secret key (ต้องขึ้นต้นด้วย sb_secret_ หรือ eyJ) - รันใหม่อีกครั้ง' }
$vapidPath = 'C:\Users\User\Documents\BLM48-backup\vapid_2026-11-23.json'
if (-not (Test-Path $vapidPath)) { throw "ไม่เจอไฟล์ VAPID สำรองที่ $vapidPath" }

Write-Host ''
Write-Host '[ขั้น 1/7] เช็กฐานข้อมูลทั้งสองฝั่ง + โครงสร้างตารางต้องตรงกัน...' -ForegroundColor Cyan
Test-Db $env:SG_DB_URL ' Singapore'
Test-Db $env:OLD_DB_URL 'เดิม'
$colQ = "select table_name||'.'||column_name||':'||data_type from information_schema.columns c join information_schema.tables t using (table_schema,table_name) where c.table_schema='public' and t.table_type='BASE TABLE' order by 1"
$colsSg  = psql $env:SG_DB_URL  -At -c $colQ; Assert-Ok 'อ่านโครงสร้าง Singapore'
$colsOld = psql $env:OLD_DB_URL -At -c $colQ; Assert-Ok 'อ่านโครงสร้างโปรเจกต์เดิม'
$d = Compare-Object $colsOld $colsSg
if ($d) { $d | Format-Table; throw 'โครงสร้างตารางสองฝั่งไม่ตรงกัน (ด้านบน) - หยุดก่อน ยังไม่ได้แตะอะไร ส่งข้อความนี้ให้ Claude' }
Write-Host ("  ตรงกันทั้ง {0} คอลัมน์" -f $colsSg.Count) -ForegroundColor Green

Write-Host ''
Write-Host '[ขั้น 2/7] ปิด Singapore (เว็บจะใช้ไม่ได้ตั้งแต่ตอนนี้) + ดึงข้อมูล...' -ForegroundColor Cyan
psql $env:SG_DB_URL -v ON_ERROR_STOP=1 -c "select cron.alter_job(jobid, active := false) from cron.job; revoke usage on schema public from public, anon, authenticated;"; Assert-Ok 'ปิด Singapore'
Start-Sleep -Seconds 5
pg_dump $env:SG_DB_URL --schema=public --data-only --no-owner `
  --exclude-table-data=public.top_fans_cache --exclude-table-data=public.campaign_list_cache `
  -f "$out\sg_data.sql"; Assert-Ok 'ดึงข้อมูล Singapore'
$csvSg = $out.Replace('\', '/') + '/sg_storage.csv'
$csvOld = $out.Replace('\', '/') + '/old_storage.csv'
psql $env:SG_DB_URL -v ON_ERROR_STOP=1 -c "\copy (select bucket_id, name, coalesce(metadata->>'mimetype','application/octet-stream') as mimetype from storage.objects order by 1,2) to '$csvSg' with csv header"; Assert-Ok 'รายชื่อไฟล์ Singapore'
psql $env:OLD_DB_URL -v ON_ERROR_STOP=1 -c "\copy (select bucket_id, name, coalesce(metadata->>'mimetype','application/octet-stream') as mimetype from storage.objects order by 1,2) to '$csvOld' with csv header"; Assert-Ok 'รายชื่อไฟล์โปรเจกต์เดิม'
Write-Host ('  ดึงข้อมูลแล้ว {0:N0} MB' -f ((Get-Item "$out\sg_data.sql").Length / 1MB)) -ForegroundColor Green

Write-Host ''
Write-Host '[ขั้น 3/7] แทนข้อมูลในโปรเจกต์เดิมด้วยข้อมูล Singapore (ทำใน transaction เดียว พังกลางทาง = ไม่เปลี่ยนอะไร)...' -ForegroundColor Cyan
$tables = psql $env:OLD_DB_URL -At -c "select string_agg(format('public.%I', tablename), ', ' order by tablename) from pg_tables where schemaname='public'"; Assert-Ok 'รายชื่อตาราง'
psql $env:OLD_DB_URL --single-transaction -v ON_ERROR_STOP=1 `
  -c "SET session_replication_role = replica; TRUNCATE $tables CASCADE;" `
  -f "$out\sg_data.sql"; Assert-Ok 'ใส่ข้อมูลเข้าโปรเจกต์เดิม'
psql $env:OLD_DB_URL -v ON_ERROR_STOP=1 -v from_ref=$SG_REF -v to_ref=$OLD_REF -f (Join-Path $PSScriptRoot 'moveback_post.sql'); Assert-Ok 'แก้ URL รูป'

Write-Host ''
Write-Host '[ขั้น 4/7] ตรวจจำนวนข้อมูลทุกตาราง...' -ForegroundColor Cyan
$q = @'
select table_name || '=' || (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from public.%I', table_name), false, true, '')))[1]::text
from information_schema.tables where table_schema='public' and table_type='BASE TABLE'
  and table_name not in ('top_fans_cache','campaign_list_cache') order by 1
'@
$a = psql $env:SG_DB_URL -At -c $q; Assert-Ok 'นับ Singapore'
$b = psql $env:OLD_DB_URL -At -c $q; Assert-Ok 'นับโปรเจกต์เดิม'
$diff = Compare-Object $a $b
if ($diff) { $diff | Format-Table; throw 'จำนวนแถวไม่ตรงกัน (ด้านบน) - โปรเจกต์เดิมยังปิดอยู่ ส่งข้อความนี้ให้ Claude' }
Write-Host ("  ตรงกันทั้ง {0} ตาราง" -f $a.Count) -ForegroundColor Green

Write-Host ''
Write-Host '[ขั้น 5/7] เปิดโปรเจกต์เดิม (API + cron)...' -ForegroundColor Cyan
psql $env:OLD_DB_URL -v ON_ERROR_STOP=1 -c "grant usage on schema public to anon, authenticated, service_role; select cron.alter_job(jobid, active := true) from cron.job;"; Assert-Ok 'เปิดโปรเจกต์เดิม'
Write-Host '  เปิดแล้ว (หน้าเว็บจะใช้ได้เมื่อ Claude push โค้ดที่ชี้กลับโปรเจกต์เดิม)' -ForegroundColor Green

Write-Host ''
Write-Host '[ขั้น 6/7] ก๊อปรูปที่อัปโหลดใน Singapore หลังย้าย กลับมาโปรเจกต์เดิม...' -ForegroundColor Cyan
$have = @{}; Import-Csv "$out\old_storage.csv" | ForEach-Object { $have["$($_.bucket_id)/$($_.name)"] = 1 }
$missing = Import-Csv "$out\sg_storage.csv" | Where-Object { -not $have.ContainsKey("$($_.bucket_id)/$($_.name)") }
@($missing) | Export-Csv "$out\moveback_missing.csv" -NoTypeInformation -Encoding UTF8
Write-Host ("  ไฟล์ที่ต้องก๊อป: {0}" -f @($missing).Count)
node .\moveback-copy-storage.mjs
if ($LASTEXITCODE -ne 0) { Write-Host '  มีไฟล์ก๊อปไม่ผ่าน (ดู out\moveback_failed.txt) - รันขั้นนี้ซ้ำได้ทีหลัง ไม่กระทบอย่างอื่น' -ForegroundColor Yellow }
Remove-Item Env:OLD_SERVICE_ROLE_KEY -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '[ขั้น 7/7] ตั้ง key แจ้งเตือนของโปรเจกต์เดิม: จะเปิดเบราว์เซอร์ให้ล็อกอิน Supabase' -ForegroundColor Cyan
Write-Host "  ล็อกอินด้วยบัญชีที่เป็นเจ้าของโปรเจกต์เดิม ($OLD_REF) แล้วกลับมาที่หน้าต่างนี้" -ForegroundColor Yellow
$v = Get-Content $vapidPath -Raw | ConvertFrom-Json
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
  npx supabase login
  npx supabase functions deploy send-push --project-ref $OLD_REF --no-verify-jwt; Assert-Ok 'deploy send-push'
  npx supabase secrets set --project-ref $OLD_REF "VAPID_PUBLIC_KEY=$($v.VAPID_PUBLIC_KEY)" "VAPID_PRIVATE_KEY=$($v.VAPID_PRIVATE_KEY)" "VAPID_SUBJECT=$($v.VAPID_SUBJECT)"; Assert-Ok 'ตั้ง VAPID secrets'
} finally { Pop-Location }

Write-Host ''
Write-Host '=== เสร็จแล้ว! กลับไปบอก Claude ว่า "ย้ายกลับเสร็จแล้ว" ===' -ForegroundColor Green
