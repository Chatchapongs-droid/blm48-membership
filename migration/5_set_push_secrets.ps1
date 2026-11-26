# Step 6: deploy send-push to the NEW project and set its 4 secrets.
# Reads the new VAPID pair from out\vapid.json and the webhook secret from out\schema.sql
# (the value _notify_push sends), so nothing has to be copied by hand.
# Run `npx supabase login` (new account) first.
$ErrorActionPreference = 'Stop'
$NEW_REF = 'fgovrwnjvdwvtsjeuhjj'
$out = Join-Path $PSScriptRoot 'out'

$v = Get-Content "$out\vapid.json" -Raw | ConvertFrom-Json
$m = [regex]::Match((Get-Content "$out\schema.sql" -Raw), "x-webhook-secret'?\s*,\s*'([^']+)'")
if (-not $m.Success) { throw 'Webhook secret not found in out\schema.sql - run 1_freeze_and_export.ps1 first' }
$wh = $m.Groups[1].Value

Push-Location (Split-Path $PSScriptRoot -Parent)
try {
  npx supabase functions deploy send-push --project-ref $NEW_REF --no-verify-jwt
  if ($LASTEXITCODE -ne 0) { throw 'deploy failed' }
  npx supabase secrets set --project-ref $NEW_REF "VAPID_PUBLIC_KEY=$($v.VAPID_PUBLIC_KEY)" "VAPID_PRIVATE_KEY=$($v.VAPID_PRIVATE_KEY)" "VAPID_SUBJECT=$($v.VAPID_SUBJECT)" "PUSH_WEBHOOK_SECRET=$wh"
  if ($LASTEXITCODE -ne 0) { throw 'secrets set failed' }
} finally { Pop-Location }
Write-Host 'send-push deployed with new secrets.'
