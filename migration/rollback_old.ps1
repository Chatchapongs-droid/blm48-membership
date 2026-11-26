# Undo the freeze on the OLD project (site works on the old database again).
# Needs $env:OLD_DB_URL.
$ErrorActionPreference = 'Stop'
if (-not (Get-Command psql -ErrorAction SilentlyContinue)) { $env:Path += ';C:\Program Files\PostgreSQL\17\bin' }
psql $env:OLD_DB_URL -v ON_ERROR_STOP=1 -c "grant usage on schema public to public, anon, authenticated; select cron.alter_job(jobid, active := true) from cron.job;"
if ($LASTEXITCODE -ne 0) { throw 'rollback failed' }
Write-Host 'Old project unfrozen. Saved original ACL for reference:'
Get-Content (Join-Path $PSScriptRoot 'out\old_schema_acl.txt')
