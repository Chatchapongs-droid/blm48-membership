# Copy all Storage files from the old project to Singapore (fgovrwnjvdwvtsjeuhjj).
# Asks for the Singapore service_role / secret key here (hidden input) - the key never leaves this terminal.
$env:NEW_SUPABASE_URL = 'https://fgovrwnjvdwvtsjeuhjj.supabase.co'
if (-not $env:NEW_SERVICE_ROLE_KEY) {
  $sec = Read-Host 'Paste the Singapore service_role or sb_secret key (Project Settings > API Keys)' -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  $env:NEW_SERVICE_ROLE_KEY = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}
node "$PSScriptRoot\copy-storage.mjs"
Write-Host ''
Write-Host "exit code: $LASTEXITCODE  (0 = all copied; otherwise run this script again to retry the failed ones)"
