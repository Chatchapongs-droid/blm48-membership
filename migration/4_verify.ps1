# Step 5: compare row counts of every public table, old vs new.
# Needs $env:OLD_DB_URL and $env:NEW_DB_URL.
$ErrorActionPreference = 'Stop'
if (-not (Get-Command psql -ErrorAction SilentlyContinue)) { $env:Path += ';C:\Program Files\PostgreSQL\17\bin' }
$q = @'
select table_name || '=' || (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from public.%I', table_name), false, true, '')))[1]::text
from information_schema.tables where table_schema='public' and table_type='BASE TABLE'
  and table_name not in ('top_fans_cache','campaign_list_cache') order by 1
'@
$old = psql $env:OLD_DB_URL -At -c $q
$new = psql $env:NEW_DB_URL -At -c $q
$diff = Compare-Object $old $new
if ($diff) { Write-Host 'DIFFERENT:' -ForegroundColor Red; $diff | Format-Table } else { Write-Host ("All {0} tables match." -f $old.Count) -ForegroundColor Green }
$files = psql $env:NEW_DB_URL -At -c "select count(*) from storage.objects"
Write-Host "Storage objects in new project: $files (old had 1579 at planning time)"
