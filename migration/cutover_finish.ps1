# ขั้นสุดท้าย (5-6) หลังใส่ข้อมูลเสร็จแล้ว: ก๊อปไฟล์รูป + ตั้งค่าระบบแจ้งเตือน
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

Write-Host ''
Write-Host '=== ขั้นสุดท้ายของการย้าย ===' -ForegroundColor Cyan
Write-Host 'ตอนวาง จะไม่มีอะไรขึ้นบนจอ เป็นเรื่องปกติ วางแล้วกด Enter ได้เลย' -ForegroundColor Yellow
$s = Read-Host -AsSecureString 'Secret key ของโปรเจกต์ใหม่ (ขึ้นต้นด้วย sb_secret_)'
$env:NEW_SERVICE_ROLE_KEY = ([Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))).Trim()
if ($env:NEW_SERVICE_ROLE_KEY -notmatch '^(sb_secret_|eyJ)') { throw 'อันนี้ไม่ใช่ secret key (ต้องขึ้นต้นด้วย sb_secret_) - รันใหม่อีกครั้ง' }
$env:NEW_SUPABASE_URL = 'https://fgovrwnjvdwvtsjeuhjj.supabase.co'

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
