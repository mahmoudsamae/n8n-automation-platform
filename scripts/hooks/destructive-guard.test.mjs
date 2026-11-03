// Proof for destructive-guard.mjs: it must BLOCK destructive text sent to an executor (exit 2, message names the pattern) and ALLOW the rest (exit 0).
// Every pattern in scripts/lib/destructive-patterns.json is tested through its own harmless `sample` (an echo), so a new pattern cannot go untested.
// Run: node scripts/hooks/destructive-guard.test.mjs   Exit 0 = every case behaved, 1 = a case did not.
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

// DESTRUCTIVE_GUARD_HOOK points the test at a stub hook, to prove the test itself can fail (a stub that allows or blocks everything must make it exit 1).
const hook = process.env.DESTRUCTIVE_GUARD_HOOK ?? fileURLToPath(new URL('./destructive-guard.mjs', import.meta.url));
const { patterns } = JSON.parse(readFileSync(new URL('../lib/destructive-patterns.json', import.meta.url), 'utf8'));
const b64 = (s) => Buffer.from(s, 'utf8').toString('base64');

const dir = mkdtempSync(join(tmpdir(), 'destructive-guard-'));
const badFile = join(dir, 'bad.sh');
const okFile = join(dir, 'ok.sh');
writeFileSync(badFile, "echo start\necho 'DROP TABLE x'\n");
writeFileSync(okFile, 'echo ok\n');

const cases = [
  // [name, tool, command, expected exit code]
  ...patterns.map((p) => [`BLOCK  pattern ${p.id} through wsl bash -c`, 'PowerShell', `wsl -d Ubuntu bash -c "${p.sample}"`, 2]),
  ...patterns.map((p) => [`BLOCK  pattern ${p.id} through wsl-sh.ps1 -Script`, 'PowerShell', `& scripts\\wsl-sh.ps1 -Script "${p.sample}"`, 2]),
  ['BLOCK  direct docker, PowerShell', 'PowerShell', 'docker compose down -v --help', 2],
  ['BLOCK  uppercase', 'PowerShell', 'wsl -d Ubuntu DOCKER VOLUME RM --help', 2],
  ['BLOCK  after && in Git Bash', 'Bash', 'cd /c/dev && docker volume prune --help', 2],
  ['BLOCK  sudo prefix', 'Bash', 'sudo -n docker system prune --volumes --help', 2],
  ['BLOCK  through ssh', 'Bash', "ssh ubuntu@m7-server 'docker volume ls; docker volume rm --help'", 2],
  ['BLOCK  inside $( )', 'Bash', 'echo $(psql -c "drop table x")', 2],
  ['BLOCK  variable as the command word (the known bypass)', 'Bash', 'd=docker; $d volume rm --help', 2],
  ['BLOCK  script assigned to a variable, then sent through the helper', 'PowerShell', "$sh = 'echo DELETE FROM x'\n& scripts\\server-sh.ps1 -Script $sh", 2],
  ['BLOCK  literal base64 piped to bash', 'PowerShell', `wsl -d Ubuntu bash -c "echo ${b64("echo 'TRUNCATE x'")} | base64 -d | bash"`, 2],
  ['BLOCK  helper -File target holds DROP', 'PowerShell', `& scripts\\wsl-sh.ps1 -File "${badFile}"`, 2],
  ['BLOCK  wrapped in powershell -Command', 'PowerShell', `powershell -NoProfile -Command "wsl -d Ubuntu psql -c 'drop table x'"`, 2],
  ['BLOCK  wrapped in cmd /c', 'PowerShell', 'cmd /c "wsl -d Ubuntu echo TRUNCATE x"', 2],
  ['BLOCK  helper as a child process, its -File target holds DROP', 'PowerShell', `powershell -NoProfile -File scripts\\wsl-sh.ps1 -File "${badFile}"`, 2],
  ['ALLOW  helper as a child process, harmless -File target', 'PowerShell', `powershell -NoProfile -File scripts\\wsl-sh.ps1 -File "${okFile}"`, 0],
  ['ALLOW  git commit message mentioning drop', 'PowerShell', 'git commit -m "drop the old column"', 0],
  ['ALLOW  grep for DELETE FROM', 'Bash', 'grep -rn "DELETE FROM" scripts', 0],
  ['ALLOW  clean-test-event.ps1 (gated by an ask rule, not this hook)', 'PowerShell', 'powershell -File scripts\\clean-test-event.ps1 -Id evt_test_x -DryRun', 0],
  ['ALLOW  plain docker ps through wsl', 'PowerShell', "wsl -d Ubuntu docker ps --format '{{.Names}}'", 0],
  ['ALLOW  the helper with a harmless script', 'PowerShell', "& scripts\\wsl-sh.ps1 -Script 'echo ok'", 0],
  ['ALLOW  helper -File target that is harmless', 'PowerShell', `& scripts\\wsl-sh.ps1 -File "${okFile}"`, 0],
  ['ALLOW  harmless base64 piped to bash', 'PowerShell', `wsl -d Ubuntu bash -c "echo ${b64('echo ok')} | base64 -d | bash"`, 0],
  ['ALLOW  assignment mentioning drop, no executor', 'PowerShell', "$msg = 'drop it'; git status", 0],
  ['ALLOW  e2e run', 'PowerShell', 'powershell -NoProfile -File scripts\\e2e.ps1', 0],
  ['IGNORE other tools', 'Read', 'wsl -d Ubuntu bash -c "echo DROP TABLE x"', 0],
];

let failed = 0;
for (const [name, tool, command, want] of cases) {
  const r = spawnSync(process.execPath, [hook], { input: JSON.stringify({ tool_name: tool, tool_input: { command }, cwd: process.cwd() }), encoding: 'utf8' });
  const named = r.stderr.includes('destructive-guard blocked');
  const ok = r.status === want && (want === 0 || named);
  if (!ok) failed++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}  -> exit ${r.status}${want === 2 && !named ? ', block message MISSING' : ''}`);
}
const malformed = spawnSync(process.execPath, [hook], { input: 'not json', encoding: 'utf8' });
if (malformed.status !== 0) failed++;
console.log(`${malformed.status === 0 ? 'PASS' : 'FAIL'}  ALLOW  malformed hook payload  -> exit ${malformed.status}`);

rmSync(dir, { recursive: true, force: true });
console.log(`\n${cases.length + 1 - failed}/${cases.length + 1} cases behaved`);
process.exit(failed === 0 ? 0 : 1);
