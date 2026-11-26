# Step 3: restore into the NEW project.
# Needs (set them yourself in this terminal):
#   $env:NEW_DB_URL = "<new project Session pooler connection string, with password>"
#   $env:NEW_REF    = "<new project ref, the part before .supabase.co>"

$ErrorActionPreference = 'Stop'
if (-not (Get-Command psql -ErrorAction SilentlyContinue)) { $env:Path += ';C:\Program Files\PostgreSQL\17\bin' }
function Assert-Ok($what) { if ($LASTEXITCODE -ne 0) { throw "$what failed (exit $LASTEXITCODE)" } }

$OLD_REF = 'rqhwzbrcgnpxtuaeoxml'
if (-not $env:NEW_DB_URL) { throw 'Set $env:NEW_DB_URL first' }
if (-not $env:NEW_REF -or $env:NEW_REF -notmatch '^[a-z0-9]{20}$') { throw 'Set $env:NEW_REF to the 20-letter project ref' }
if ($env:NEW_REF -eq $OLD_REF) { throw 'NEW_REF is the old project' }
$out = Join-Path $PSScriptRoot 'out'
if (-not (Test-Path "$out\schema.sql")) { throw 'Run 1_freeze_and_export.ps1 first' }

Write-Host '3a Extensions + storage policies...'
psql $env:NEW_DB_URL -v ON_ERROR_STOP=1 -f (Join-Path $PSScriptRoot '0_prepare.sql'); Assert-Ok 'prepare'

Write-Host '3b Schema (old project URL -> new in functions, e.g. push webhook)...'
$schema = [IO.File]::ReadAllText("$out\schema.sql")
$schema = $schema.Replace($OLD_REF, $env:NEW_REF)
$schema = [regex]::Replace($schema, '(?m)^CREATE SCHEMA "?public"?;', '-- (public already exists)')
$schema = [regex]::Replace($schema, '(?m)^CREATE EXTENSION (?!IF NOT EXISTS)', 'CREATE EXTENSION IF NOT EXISTS ')
# supabase_admin's default privileges are Supabase's own and already set; postgres may not change them
$schema = [regex]::Replace($schema, '(?m)^ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin ', '-- (supabase default) ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin ')
[IO.File]::WriteAllText("$out\schema.new.sql", $schema, (New-Object Text.UTF8Encoding($false)))
psql $env:NEW_DB_URL --single-transaction -v ON_ERROR_STOP=1 -f "$out\schema.new.sql"; Assert-Ok 'schema restore'

Write-Host '3c Data (triggers off, so no notifications/push are sent while loading)...'
psql $env:NEW_DB_URL --single-transaction -v ON_ERROR_STOP=1 -c 'SET session_replication_role = replica' -f "$out\data.sql"; Assert-Ok 'data restore'

Write-Host '3d Realtime, URL rewrite, cron jobs...'
psql $env:NEW_DB_URL -v ON_ERROR_STOP=1 -v old_ref=$OLD_REF -v new_ref=$env:NEW_REF -f (Join-Path $PSScriptRoot '3_post.sql'); Assert-Ok 'post steps'

Write-Host 'Import done. Next: node migration\copy-storage.mjs, then .\4_verify.ps1'
