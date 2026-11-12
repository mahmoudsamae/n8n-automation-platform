# Proves the n8n_app role (migration 007) on the M7 server has exactly the privileges the workflows need and nothing more, and that it logs in over TCP.
# Run: powershell -File scripts\check-db-role.ps1   Exit 0 = ok, 1 = problem. Prints privilege names and yes/no only, never the password.
# Privileges come from the ACLs (aclexplode), for n8n_app and for PUBLIC, so a grant to PUBLIC counts too. Inherited ones are ruled out by "member of no other role".
# The query never names a privilege: the destructive guard refuses a privilege name that is also a statement, and it is right not to make exceptions.
# Prove it can fail (owner, by hand): GRANT TRUNCATE ON stripe_events TO n8n_app; run this (expect FAIL, exit 1); REVOKE TRUNCATE ON stripe_events FROM n8n_app.
$ErrorActionPreference = 'Stop'
$failed = 0
function Write-Step([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "[PASS] $Name" -ForegroundColor Green -NoNewline } else { Write-Host "[FAIL] $Name" -ForegroundColor Red -NoNewline; $script:failed++ }
    if ($Detail) { Write-Host " - $Detail" } else { Write-Host '' }
}

# What migration 007 grants. Anything else held on a public table or sequence is a FAIL, including on tables added later.
$expectedTable = @('invoices:INSERT', 'invoices:SELECT', 'side_effects:INSERT', 'side_effects:SELECT', 'stripe_events:INSERT', 'stripe_events:SELECT', 'stripe_events:UPDATE')
$expectedSequence = @('invoice_number_seq:USAGE', 'invoices_invoice_id_seq:USAGE')

# The SQL goes in through a quoted heredoc, so the server's shell expands nothing inside it.
$sh = @'
docker exec -i postgres psql -U automation -d automation -tA -v ON_ERROR_STOP=1 <<'SQL'
select 'exists=' || count(*) from pg_roles where rolname = 'n8n_app';
select 'attrs=' || concat_ws(',', case when rolsuper then 'superuser' end, case when rolcreatedb then 'createdb' end, case when rolcreaterole then 'createrole' end,
       case when rolreplication then 'replication' end, case when rolbypassrls then 'bypassrls' end, case when not rolcanlogin then 'nologin' end)
  from pg_roles where rolname = 'n8n_app';
select 'member_of=' || count(*) from pg_auth_members m join pg_roles r on r.oid = m.member where r.rolname = 'n8n_app';
select 'owns=' || (select count(*) from pg_class where relowner = 'n8n_app'::regrole) + (select count(*) from pg_namespace where nspowner = 'n8n_app'::regrole)
       + (select count(*) from pg_proc where proowner = 'n8n_app'::regrole) + (select count(*) from pg_database where datdba = 'n8n_app'::regrole);
select distinct 'tablepriv=' || c.relname || ':' || a.privilege_type from pg_class c join pg_namespace n on n.oid = c.relnamespace
  cross join lateral aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
  where n.nspname = 'public' and c.relkind in ('r','p','v','m','f') and a.grantee in ('n8n_app'::regrole, 0) order by 1;
select distinct 'seqpriv=' || c.relname || ':' || a.privilege_type from pg_class c join pg_namespace n on n.oid = c.relnamespace
  cross join lateral aclexplode(coalesce(c.relacl, acldefault('s', c.relowner))) a
  where n.nspname = 'public' and c.relkind = 'S' and a.grantee in ('n8n_app'::regrole, 0) order by 1;
select 'schema_create=' || has_schema_privilege('n8n_app', 'public', 'CREATE');
select 'db_connect=' || has_database_privilege('n8n_app', 'automation', 'CONNECT');
select 'db_create=' || has_database_privilege('n8n_app', 'automation', 'CREATE');
select 'db_temp=' || has_database_privilege('n8n_app', 'automation', 'TEMPORARY');
select 'public_db_acl=' || count(*) from pg_database d, aclexplode(d.datacl) a where d.datname = 'automation' and a.grantee = 0;
SQL
# TCP login from a throwaway container on the stack network: the postgres container trusts its own loopback, so only this tests the password.
pw="$(grep -m1 '^N8N_DB_PASSWORD=' ~/n8n-workflows/.env | cut -d= -f2-)"
if [ -z "$pw" ]; then echo "envpw=EMPTY"; else echo "envpw=set"; fi
login() { PGPASSWORD="$1" docker run --rm --network m7_default -e PGPASSWORD postgres:17.11-alpine psql -h postgres -U n8n_app -d automation -tAc "select current_user" 2>/dev/null; }
if [ "$(login "$pw")" = "n8n_app" ]; then echo "tcp_login=yes"; else echo "tcp_login=no"; fi
unset pw
if [ "$(login "wrong-$(date +%s)")" = "n8n_app" ]; then echo "tcp_wrong_refused=no"; else echo "tcp_wrong_refused=yes"; fi
'@
$out = @(& "$PSScriptRoot\server-sh.ps1" -Script $sh)
# Before migration 007 the role does not exist and the catalog query stops with an error: that is a FAIL too.
if ($LASTEXITCODE -ne 0) { Write-Step 'server reachable and catalog query ran (does role n8n_app exist?)' $false "exit $LASTEXITCODE"; Write-Output '1 failed'; exit 1 }
function Get-Values([string]$Key) { @($out | Where-Object { "$_" -like "$Key=*" } | ForEach-Object { "$_".Substring($Key.Length + 1).Trim() }) }
function Get-One([string]$Key) { $v = @(Get-Values $Key); if ($v.Count) { $v[0] } else { '' } }

$exists = (Get-One 'exists') -eq '1'
Write-Step 'role n8n_app exists' $exists
$attrs = Get-One 'attrs'
Write-Step 'no superuser, createdb, createrole, replication or bypassrls; can log in' ($exists -and $attrs -eq '') $(if ($attrs) { $attrs } else { 'none' })
Write-Step 'member of no other role' ($exists -and (Get-One 'member_of') -eq '0') "$(Get-One 'member_of')"
Write-Step 'owns no table, sequence, schema, function or database (so ALTER and DROP are refused)' ((Get-One 'owns') -eq '0') "$(Get-One 'owns') owned"

$tablePriv = @(Get-Values 'tablepriv' | Sort-Object)
$extra = @($tablePriv | Where-Object { $_ -notin $expectedTable })
$missing = @($expectedTable | Where-Object { $_ -notin $tablePriv })
Write-Step 'table privileges: nothing beyond migration 007 (no DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN)' ($exists -and $extra.Count -eq 0) $(if ($extra.Count) { 'extra: ' + ($extra -join ', ') } else { "$($tablePriv.Count) held" })
Write-Step 'table privileges: everything the workflows need' ($missing.Count -eq 0) $(if ($missing.Count) { 'missing: ' + ($missing -join ', ') })
$seqPriv = @(Get-Values 'seqpriv' | Sort-Object)
$seqExtra = @($seqPriv | Where-Object { $_ -notin $expectedSequence })
$seqMissing = @($expectedSequence | Where-Object { $_ -notin $seqPriv })
Write-Step 'sequence privileges: exactly USAGE on the two column-default sequences' ($seqExtra.Count -eq 0 -and $seqMissing.Count -eq 0) $(if ($seqExtra.Count -or $seqMissing.Count) { "extra: $($seqExtra -join ', ') missing: $($seqMissing -join ', ')" })

Write-Step 'no CREATE on schema public' ((Get-One 'schema_create') -eq 'false') (Get-One 'schema_create')
Write-Step 'CONNECT on database automation' ((Get-One 'db_connect') -eq 'true') (Get-One 'db_connect')
Write-Step 'no CREATE or TEMPORARY on database automation' ((Get-One 'db_create') -eq 'false' -and (Get-One 'db_temp') -eq 'false') "create=$(Get-One 'db_create') temp=$(Get-One 'db_temp')"
Write-Step 'PUBLIC has no grant on database automation' ((Get-One 'public_db_acl') -eq '0') "$(Get-One 'public_db_acl') entries"

Write-Step 'N8N_DB_PASSWORD set in the server .env' ((Get-One 'envpw') -eq 'set') (Get-One 'envpw')
Write-Step 'n8n_app logs in over TCP from another container with the .env password' ((Get-One 'tcp_login') -eq 'yes') (Get-One 'tcp_login')
Write-Step 'a wrong password is refused over TCP' ((Get-One 'tcp_wrong_refused') -eq 'yes') (Get-One 'tcp_wrong_refused')

# Write-Output, not Write-Host: e2e -Target Server runs this in-process and reads the line from the pipeline (M7b-4 finding).
Write-Output ("{0} failed" -f $failed)
if ($failed -gt 0) { exit 1 }
exit 0
