# Step 2: freeze the OLD project and export it.
# Needs (set them yourself in this terminal, they are not saved anywhere):
#   $env:OLD_DB_URL = "<old project Session pooler connection string, with password>"
# Output: migration\out\ (schema.sql, data.sql, storage_manifest.csv, old_schema_acl.txt)
# Every database call is retried, because the old project's pooler sometimes refuses
# a new connection ("EAUTHQUERY ... connection to database not available").

$ErrorActionPreference = 'Stop'
if (-not (Get-Command psql -ErrorAction SilentlyContinue)) { $env:Path += ';C:\Program Files\PostgreSQL\17\bin' }
function Invoke-Retry($what, [scriptblock]$cmd) {
  for ($i = 1; $i -le 8; $i++) {
    & $cmd
    if ($LASTEXITCODE -eq 0) { return }
    Write-Host "    $what : connection failed (try $i/8), retrying in 15 s..." -ForegroundColor Yellow
    Start-Sleep -Seconds 15
  }
  throw "$what failed 8 times"
}

if (-not $env:OLD_DB_URL) { throw 'Set $env:OLD_DB_URL first' }
$out = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force $out | Out-Null

# Resume: if a previous run already froze the old project and finished the data dump,
# do not dump again (a schema dump taken after the freeze would miss the anon grant).
$dataDone = (Test-Path "$out\data.sql") -and (Test-Path "$out\schema.sql") -and
  ((Get-Content "$out\data.sql" -Tail 8) -match 'PostgreSQL database dump complete')
if ($dataDone) {
  Write-Host '1-4/5 Already exported in an earlier run (schema.sql + complete data.sql) - skipping.' -ForegroundColor Green
} else {

Write-Host '1/5 Exporting schema (before freeze, so the anon GRANTs are captured)...'
Invoke-Retry 'schema dump' { pg_dump $env:OLD_DB_URL --schema=public --schema-only --no-owner -f "$out\schema.sql" }

Write-Host '2/5 Saving current access rights on schema public (for rollback)...'
Invoke-Retry 'acl save' { psql $env:OLD_DB_URL -At -o "$out\old_schema_acl.txt" -c "select coalesce(nspacl::text,'') from pg_namespace where nspname='public'" }

Write-Host '3/5 FREEZING old project: stop cron jobs and block the website API...'
Invoke-Retry 'freeze' { psql $env:OLD_DB_URL -v ON_ERROR_STOP=1 -c "select cron.alter_job(jobid, active := false) from cron.job; revoke usage on schema public from public, anon, authenticated;" }
$script:still = ''
Invoke-Retry 'freeze check' { $script:still = psql $env:OLD_DB_URL -At -c "select has_schema_privilege('anon','public','usage')" }
if ("$script:still".Trim() -ne 'f') { throw 'Freeze did not take effect (anon still has access) - stopping. Run .\rollback_old.ps1 to re-enable cron.' }
Write-Host '    Old site is now blocked. Rollback: .\rollback_old.ps1'
Start-Sleep -Seconds 5

Write-Host '4/5 Exporting data...'
Invoke-Retry 'data dump' {
  pg_dump $env:OLD_DB_URL --schema=public --data-only --no-owner `
    --exclude-table-data=public.top_fans_cache --exclude-table-data=public.campaign_list_cache `
    -f "$out\data.sql"
}
}

Write-Host '5/5 Exporting storage file list...'
$csv = $out.Replace('\', '/') + '/storage_manifest.csv'
Invoke-Retry 'manifest' { psql $env:OLD_DB_URL -v ON_ERROR_STOP=1 -c "\copy (select bucket_id, name, coalesce(metadata->>'mimetype','application/octet-stream') as mimetype from storage.objects order by 1,2) to '$csv' with csv header" }

Get-ChildItem $out | Format-Table Name, Length
Write-Host 'Export done. Next: .\2_import.ps1'
