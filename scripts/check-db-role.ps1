# Proves the n8n_app role (migration 007) and the demo_reset role (migration 008) on the M7 server have exactly their privileges and nothing
# more, that n8n_app logs in over TCP, and that demo_reset (no password) cannot.
# Run: powershell -File scripts\check-db-role.ps1   Exit 0 = ok, 1 = problem. Prints privilege names and yes/no only, never the password.
# Privileges come from the ACLs (aclexplode), for the role and for PUBLIC, so a grant to PUBLIC counts too. Inherited ones are ruled out by "member of no other role".
# The query never names a privilege: the destructive guard refuses a privilege name that is also a statement, and it is right not to make exceptions.
# Prove it can fail (owner, by hand): GRANT TRUNCATE ON stripe_events TO n8n_app; run this (expect FAIL, exit 1); REVOKE TRUNCATE ON stripe_events FROM n8n_app.
# For demo_reset: GRANT UPDATE ON stripe_events TO demo_reset; run this (expect FAIL, exit 1); REVOKE UPDATE ON stripe_events FROM demo_reset.
$ErrorActionPreference = 'Stop'
$failed = 0
function Write-Step([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "[PASS] $Name" -ForegroundColor Green -NoNewline } else { Write-Host "[FAIL] $Name" -ForegroundColor Red -NoNewline; $script:failed++ }
    if ($Detail) { Write-Host " - $Detail" } else { Write-Host '' }
}

# What migrations 007 and 008 grant, per role. Anything else held on a public table, column or sequence is a FAIL, including on tables
# added later. demo_reset may only read and delete the pipeline and demo tables, for the nightly reset (infra/demo-reset.sql).
$resetTables = @('demo_limit_alerts', 'demo_sessions', 'event_replays', 'invoices', 'side_effects', 'stripe_events')
$roles = [ordered]@{
    n8n_app    = @{
        Table    = @('demo_limit_alerts:INSERT', 'demo_limit_alerts:SELECT', 'demo_sessions:INSERT', 'demo_sessions:SELECT', 'invoices:INSERT', 'invoices:SELECT',
                     'side_effects:INSERT', 'side_effects:SELECT', 'stripe_events:INSERT', 'stripe_events:SELECT', 'stripe_events:UPDATE')
        Column   = @('demo_sessions.checkout_session_id:UPDATE')
        Sequence = @('invoice_number_seq:USAGE', 'invoices_invoice_id_seq:USAGE')
    }
    demo_reset = @{
        Table    = @($resetTables | ForEach-Object { "${_}:DELETE"; "${_}:SELECT" })
        Column   = @()
        Sequence = @()
    }
}

# The SQL goes in through quoted heredocs, so the server's shell expands nothing inside them. The catalog block runs once per role (psql
# variable), and every line starts with the role name, so the two runs cannot be confused.
$sh = @'
for role in n8n_app demo_reset; do
docker exec -i postgres psql -U automation -d automation -tA -v ON_ERROR_STOP=1 -v role="$role" <<'SQL'
select :'role' || ':exists=' || count(*) from pg_roles where rolname = :'role';
select :'role' || ':attrs=' || concat_ws(',', case when rolsuper then 'superuser' end, case when rolcreatedb then 'createdb' end, case when rolcreaterole then 'createrole' end,
       case when rolreplication then 'replication' end, case when rolbypassrls then 'bypassrls' end, case when not rolcanlogin then 'nologin' end)
  from pg_roles where rolname = :'role';
select :'role' || ':member_of=' || count(*) from pg_auth_members m join pg_roles r on r.oid = m.member where r.rolname = :'role';
select :'role' || ':owns=' || ((select count(*) from pg_class where relowner = :'role'::regrole) + (select count(*) from pg_namespace where nspowner = :'role'::regrole)
       + (select count(*) from pg_proc where proowner = :'role'::regrole) + (select count(*) from pg_database where datdba = :'role'::regrole));
select distinct :'role' || ':tablepriv=' || c.relname || ':' || a.privilege_type from pg_class c join pg_namespace n on n.oid = c.relnamespace
  cross join lateral aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
  where n.nspname = 'public' and c.relkind in ('r','p','v','m','f') and a.grantee in (:'role'::regrole, 0) order by 1;
select distinct :'role' || ':colpriv=' || c.relname || '.' || att.attname || ':' || a.privilege_type from pg_attribute att
  join pg_class c on c.oid = att.attrelid join pg_namespace n on n.oid = c.relnamespace
  cross join lateral aclexplode(att.attacl) a
  where n.nspname = 'public' and att.attacl is not null and a.grantee in (:'role'::regrole, 0) order by 1;
select distinct :'role' || ':seqpriv=' || c.relname || ':' || a.privilege_type from pg_class c join pg_namespace n on n.oid = c.relnamespace
  cross join lateral aclexplode(coalesce(c.relacl, acldefault('s', c.relowner))) a
  where n.nspname = 'public' and c.relkind = 'S' and a.grantee in (:'role'::regrole, 0) order by 1;
select :'role' || ':schema_create=' || has_schema_privilege(:'role', 'public', 'CREATE');
select :'role' || ':db_connect=' || has_database_privilege(:'role', 'automation', 'CONNECT');
select :'role' || ':db_create=' || has_database_privilege(:'role', 'automation', 'CREATE');
select :'role' || ':db_temp=' || has_database_privilege(:'role', 'automation', 'TEMPORARY');
SQL
done
docker exec -i postgres psql -U automation -d automation -tA -v ON_ERROR_STOP=1 <<'SQL'
select 'public_db_acl=' || count(*) from pg_database d, aclexplode(d.datacl) a where d.datname = 'automation' and a.grantee = 0;
SQL
# TCP login from a throwaway container on the stack network: the postgres container trusts its own loopback, so only this tests the password.
pw="$(grep -m1 '^N8N_DB_PASSWORD=' ~/n8n-workflows/.env | cut -d= -f2-)"
if [ -z "$pw" ]; then echo "envpw=EMPTY"; else echo "envpw=set"; fi
login() { PGPASSWORD="$2" docker run --rm --network m7_default -e PGPASSWORD postgres:17.11-alpine psql -h postgres -U "$1" -d automation -tAc "select current_user" 2>/dev/null; }
if [ "$(login n8n_app "$pw")" = "n8n_app" ]; then echo "tcp_login=yes"; else echo "tcp_login=no"; fi
unset pw
if [ "$(login n8n_app "wrong-$(date +%s)")" = "n8n_app" ]; then echo "tcp_wrong_refused=no"; else echo "tcp_wrong_refused=yes"; fi
# demo_reset has no password (migration 008): over TCP it must never log in, whatever is sent. It works only through the local socket.
if [ "$(login demo_reset "any-$(date +%s)")" = "demo_reset" ]; then echo "reset_tcp_refused=no"; else echo "reset_tcp_refused=yes"; fi
'@
$out = @(& "$PSScriptRoot\server-sh.ps1" -Script $sh)
# Before migration 007 (n8n_app) or 008 (demo_reset) a role does not exist and the catalog query stops with an error: that is a FAIL too.
if ($LASTEXITCODE -ne 0) { Write-Step 'server reachable and catalog query ran (do roles n8n_app and demo_reset exist? migrations 007, 008)' $false "exit $LASTEXITCODE"; Write-Output '1 failed'; exit 1 }
function Get-Values([string]$Key) { @($out | Where-Object { "$_" -like "$Key=*" } | ForEach-Object { "$_".Substring($Key.Length + 1).Trim() }) }
function Get-One([string]$Key) { $v = @(Get-Values $Key); if ($v.Count) { $v[0] } else { '' } }
function Compare-Privileges([string]$Label, [string[]]$Held, [string[]]$Expected) {
    $extra = @($Held | Where-Object { $_ -notin $Expected })
    $missing = @($Expected | Where-Object { $_ -notin $Held })
    $detail = if ($extra.Count -or $missing.Count) { "extra: $($extra -join ', ') missing: $($missing -join ', ')" } else { "$($Held.Count) held" }
    Write-Step "$Label exactly as granted" ($extra.Count -eq 0 -and $missing.Count -eq 0) $detail
}

foreach ($role in $roles.Keys) {
    $e = $roles[$role]
    $exists = (Get-One "${role}:exists") -eq '1'
    Write-Step "role $role exists" $exists
    $attrs = Get-One "${role}:attrs"
    Write-Step "${role}: no superuser, createdb, createrole, replication or bypassrls; can log in" ($exists -and $attrs -eq '') $(if ($attrs) { $attrs } else { 'none' })
    Write-Step "${role}: member of no other role" ($exists -and (Get-One "${role}:member_of") -eq '0') "$(Get-One "${role}:member_of")"
    Write-Step "${role}: owns no table, sequence, schema, function or database (so ALTER and DROP are refused)" ($exists -and (Get-One "${role}:owns") -eq '0') "$(Get-One "${role}:owns") owned"
    Compare-Privileges "${role}: table privileges (no TRUNCATE, REFERENCES, TRIGGER, MAINTAIN)" @(Get-Values "${role}:tablepriv" | Sort-Object) $e.Table
    Compare-Privileges "${role}: column privileges" @(Get-Values "${role}:colpriv" | Sort-Object) $e.Column
    Compare-Privileges "${role}: sequence privileges" @(Get-Values "${role}:seqpriv" | Sort-Object) $e.Sequence
    Write-Step "${role}: no CREATE on schema public" ((Get-One "${role}:schema_create") -eq 'false') (Get-One "${role}:schema_create")
    Write-Step "${role}: CONNECT on database automation" ((Get-One "${role}:db_connect") -eq 'true') (Get-One "${role}:db_connect")
    Write-Step "${role}: no CREATE or TEMPORARY on database automation" ((Get-One "${role}:db_create") -eq 'false' -and (Get-One "${role}:db_temp") -eq 'false') "create=$(Get-One "${role}:db_create") temp=$(Get-One "${role}:db_temp")"
}
Write-Step 'PUBLIC has no grant on database automation' ((Get-One 'public_db_acl') -eq '0') "$(Get-One 'public_db_acl') entries"

Write-Step 'N8N_DB_PASSWORD set in the server .env' ((Get-One 'envpw') -eq 'set') (Get-One 'envpw')
Write-Step 'n8n_app logs in over TCP from another container with the .env password' ((Get-One 'tcp_login') -eq 'yes') (Get-One 'tcp_login')
Write-Step 'a wrong password is refused over TCP' ((Get-One 'tcp_wrong_refused') -eq 'yes') (Get-One 'tcp_wrong_refused')
Write-Step 'demo_reset (no password) cannot log in over TCP' ((Get-One 'reset_tcp_refused') -eq 'yes') (Get-One 'reset_tcp_refused')

# Write-Output, not Write-Host: e2e -Target Server runs this in-process and reads the line from the pipeline (M7b-4 finding).
Write-Output ("{0} failed" -f $failed)
if ($failed -gt 0) { exit 1 }
exit 0
