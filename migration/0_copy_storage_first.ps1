# Step 0.5: first (bulk) Storage copy OLD -> NEW while the site is still live.
# Only asks for ONE thing: the new project's secret key (hidden input, kept in this window's
# memory only and cleared at the end). The file list comes from a temporary token-guarded
# read-only function on the old project (_migr_storage_manifest), so no DB password is needed.
# Safe to run again: files already copied are skipped.
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

$OLD_URL = 'https://rqhwzbrcgnpxtuaeoxml.supabase.co'
# old project's public anon key (same one the website uses today)
$OLD_ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJxaHd6YnJjZ25weHR1YWVveG1sIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODUyMjczNjAsImV4cCI6MjEwMDgwMzM2MH0.J0iiUikxLoJKZ5SF9KSz86yf2LU89z8NdPb9rEB89Gw'

function Read-Secret($prompt) {
  $s = Read-Host -AsSecureString $prompt
  $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
  try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

try {
  New-Item -ItemType Directory -Force 'migration\out' | Out-Null
  $token = (Get-Content 'migration\out\migr_token.txt' -Raw).Trim()

  Write-Host ''
  Write-Host '1) Getting the file list from the old project...' -ForegroundColor Cyan
  $list = Invoke-RestMethod -Method Post -Uri "$OLD_URL/rest/v1/rpc/_migr_storage_manifest" `
    -Headers @{ apikey = $OLD_ANON; Authorization = "Bearer $OLD_ANON" } `
    -ContentType 'application/json' -Body (@{ p_token = $token } | ConvertTo-Json)
  $rows = foreach ($r in $list) { [pscustomobject]@{ bucket_id = $r[0]; name = $r[1]; mimetype = $r[2] } }
  $rows | Export-Csv -Path 'migration\out\storage_manifest.csv' -NoTypeInformation -Encoding UTF8
  Write-Host ("   {0} files found" -f @($rows).Count) -ForegroundColor Green

  if (-not $env:NEW_SERVICE_ROLE_KEY) {
    Write-Host ''
    Write-Host '2) Paste the NEW project secret key, then press Enter.' -ForegroundColor Yellow
    Write-Host '   (Nothing will appear on screen while you paste - that is normal.)' -ForegroundColor Yellow
    $env:NEW_SERVICE_ROLE_KEY = (Read-Secret '   Secret key').Trim()
  }
  if ($env:NEW_SERVICE_ROLE_KEY -notmatch '^(sb_secret_|eyJ)') { throw 'That does not look like a secret key (it should start with sb_secret_). Run again and paste the secret key.' }
  $env:NEW_SUPABASE_URL = 'https://fgovrwnjvdwvtsjeuhjj.supabase.co'

  Write-Host ''
  Write-Host '3) Copying files to the new project (about 870 MB, can take 10-30 min)...' -ForegroundColor Cyan
  node migration\copy-storage.mjs
  if ($LASTEXITCODE -ne 0) { Write-Host 'Some files failed - run this again to retry only those.' -ForegroundColor Yellow }
  else { Write-Host ''; Write-Host 'STORAGE COPY DONE' -ForegroundColor Green }
} finally {
  Remove-Item Env:NEW_SERVICE_ROLE_KEY -ErrorAction SilentlyContinue
}
