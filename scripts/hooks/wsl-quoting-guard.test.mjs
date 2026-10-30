// Proof for wsl-quoting-guard.mjs: it must BLOCK unsafe wsl command lines (exit 2, message names scripts/wsl-sh.ps1) and ALLOW normal ones (exit 0).
// Run: node scripts/hooks/wsl-quoting-guard.test.mjs   Exit 0 = every case behaved, 1 = a case did not.
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// WSL_GUARD_HOOK points the test at a stub hook, to prove the test itself can fail (a stub that allows or blocks everything must make it exit 1).
const hook = process.env.WSL_GUARD_HOOK ?? fileURLToPath(new URL('./wsl-quoting-guard.mjs', import.meta.url));
const T = '`'; // PowerShell escape character

const cases = [
  // [name, tool, command, expected exit code]
  ['BLOCK  the leak: PowerShell-escaped $( inside wsl bash -c', 'PowerShell', `wsl -d Ubuntu bash -c "v=${T}$(docker exec n8n printenv HEARTBEAT_URL); echo done"`, 2],
  ['BLOCK  $( in a single-quoted bash -c (Git Bash form)', 'Bash', `wsl -d Ubuntu bash -c 'echo $(date -u)'`, 2],
  ['BLOCK  backslash-escaped \\$ inside wsl bash -c', 'PowerShell', `wsl -d Ubuntu bash -c "awk '{print \\$1}' /etc/passwd"`, 2],
  ['BLOCK  printenv of a secret-looking name', 'PowerShell', 'wsl -d Ubuntu docker exec n8n printenv POSTGRES_PASSWORD', 2],
  ['BLOCK  grep on the .env file', 'PowerShell', 'wsl -d Ubuntu bash -c "grep POSTGRES ~/n8n/.env"', 2],
  ['BLOCK  docker compose config (prints interpolated secrets)', 'Bash', 'wsl -d Ubuntu bash -c "cd ~/n8n && docker compose config"', 2],
  ['ALLOW  plain docker ps', 'PowerShell', `wsl -d Ubuntu docker ps --format '{{.Names}}'`, 0],
  ['ALLOW  compose up', 'PowerShell', 'wsl -d Ubuntu bash -c "cd ~/n8n && docker compose up -d"', 0],
  ['ALLOW  docker compose config --quiet (prints nothing)', 'Bash', 'wsl -d Ubuntu bash -c "cd ~/n8n && docker compose config --quiet && echo ok"', 0],
  ['ALLOW  printenv of a non-secret name', 'PowerShell', 'wsl -d Ubuntu docker exec n8n printenv TZ', 0],
  ['ALLOW  the base64 pattern, script with $( on its own lines', 'PowerShell', `$script = @'\nv=$(docker exec n8n printenv HEARTBEAT_URL)\n'@\n$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script))\nwsl -d Ubuntu bash -c "echo $b64 | base64 -d | bash"`, 0],
  ['ALLOW  the helper itself', 'PowerShell', `& scripts\\wsl-sh.ps1 -Script 'v=$(printenv HEARTBEAT_URL); [ -n "$v" ] && echo yes'`, 0],
  ['ALLOW  a heredoc body with $( (not the wsl argument)', 'Bash', `wsl -d Ubuntu bash -c 'cat > /tmp/x' <<'EOF'\necho $(date)\nEOF`, 0],
  ['ALLOW  a command with no wsl at all', 'PowerShell', 'git status; "$(Get-Date)"', 0],
  ['IGNORE other tools', 'Read', `wsl -d Ubuntu bash -c "echo ${T}$(id)"`, 0],
];

let failed = 0;
for (const [name, tool, command, want] of cases) {
  const r = spawnSync(process.execPath, [hook], { input: JSON.stringify({ tool_name: tool, tool_input: { command } }), encoding: 'utf8' });
  const namesHelper = r.stderr.includes('scripts/wsl-sh.ps1');
  const ok = r.status === want && (want === 0 || namesHelper);
  if (!ok) failed++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}  -> exit ${r.status}${want === 2 ? (namesHelper ? ', message names scripts/wsl-sh.ps1' : ', message MISSING scripts/wsl-sh.ps1') : ''}`);
}
console.log(`\n${cases.length - failed}/${cases.length} cases behaved`);
process.exit(failed === 0 ? 0 : 1);
