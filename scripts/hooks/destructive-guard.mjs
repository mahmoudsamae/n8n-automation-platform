// PreToolUse hook (PowerShell and Bash): block a command line that sends destructive text (DROP, down -v, ...) to an executor.
// Why: the deny rules in ~/.claude/settings.json match the command text only; they cannot see a DROP inside base64 or inside a script file
// handed to scripts/wsl-sh.ps1 or scripts/server-sh.ps1. The helpers refuse such text themselves (scripts/lib/destructive-guard.ps1); this hook
// stops it one step earlier and covers direct `wsl`, `docker`, `psql`, `ssh`, `bash`, `sh` calls too. Both read scripts/lib/destructive-patterns.json.
// Reads the hook event JSON on stdin. Exit 2 + stderr = block (the message goes to Claude); exit 0 = allow.
// Acts only when an executor is the command word of a segment (start, or after | ; && || ( or the & call operator), so `git commit -m "drop x"`
// and `grep drop` stay allowed. Then it scans the whole command, every literal base64 token that decodes to text, and the -File target
// of the two helpers. It never reads `powershell -File <script>` targets: clean-test-event.ps1 holds DELETE FROM and is gated by an ask rule instead.
// Limits: a text heuristic. It cannot see text built at runtime, files one level down (`psql -f`), or other routes (Docker socket, Python, MCP).

import { readFileSync, statSync } from 'node:fs';
import { isAbsolute, resolve } from 'node:path';

let raw = '';
for await (const chunk of process.stdin) raw += chunk;

let event;
try {
  event = JSON.parse(raw);
} catch {
  process.exit(0); // never break a tool call because of a malformed hook payload
}

if (!['PowerShell', 'Bash'].includes(event.tool_name)) process.exit(0);
const command = String(event.tool_input?.command ?? '');
const cwd = event.cwd || process.cwd();

const EXECUTORS = new Set(['wsl', 'docker', 'psql', 'ssh', 'bash', 'sh', 'wsl-sh.ps1', 'server-sh.ps1']);
const HELPERS = new Set(['wsl-sh.ps1', 'server-sh.ps1']);
const WRAPPERS = new Set(['powershell', 'pwsh', 'cmd', 'invoke-expression', 'iex']);
const FILE_ARG = /-File\s+(?:"([^"]+)"|'([^']+)'|(\S+))/gi;

// `& scripts\wsl-sh.ps1`, `. .\x.ps1`, `"C:\x\docker.exe"`, `sudo docker` -> first word without call operator, prefix command and quotes.
const firstWord = (segment) => {
  const m = segment.match(/^\s*(?:&\s*|\.\s+)?(?:(?:sudo|nohup|exec|time|env)\s+(?:-\S+\s+)*)*("[^"]*"|'[^']*'|\S+)/);
  return m ? m[1].replace(/^["']|["']$/g, '') : '';
};
const commandName = (word) => word.split(/[\\/]/).pop().toLowerCase().replace(/\.exe$/, '');
const fileArgs = (segment) => [...segment.matchAll(FILE_ARG)].map((m) => m[1] ?? m[2] ?? m[3]);

let executor = false;
const files = [];
for (const segment of command.split(/\r?\n|\|\||&&|[|;(]/)) {
  const word = firstWord(segment);
  const name = commandName(word);
  // A variable as the command word (`d=docker; $d volume rm x`, `& $d ...`) may be an executor: scan rather than guess. Assignments are not.
  const variable = /^\$\{?\w+\}?$/.test(word) && !/^\s*\$\w+\s*=/.test(segment);
  if (HELPERS.has(name)) {
    executor = true;
    files.push(...fileArgs(segment));
  } else if (WRAPPERS.has(name)) {
    // A wrapper's text (`powershell -Command "..."`, `cmd /c ...`, `iex ...`) is part of the command, so it gets scanned.
    executor = true;
    // Only `powershell|pwsh -File <helper> -File <target>` names a file to read: the -File arguments after the helper are its targets.
    // Any other -File target (clean-test-event.ps1, e2e.ps1) is never read; cmd and iex name no file.
    if (name === 'powershell' || name === 'pwsh') {
      const args = fileArgs(segment);
      const helperAt = args.findIndex((f) => HELPERS.has(commandName(f)));
      if (helperAt >= 0) files.push(...args.slice(helperAt + 1));
    }
  } else if (EXECUTORS.has(name) || variable) {
    executor = true;
  }
}
if (!executor) process.exit(0);

const block = (reason) => {
  process.stderr.write(
    `destructive-guard blocked this command: ${reason}.\n` +
      'There is no override. If this is really needed, the owner runs it by hand outside Claude. ' +
      'Test rows are removed with scripts/clean-test-event.ps1 (it asks first). See PLAN.md, "Safety guards".\n',
  );
  process.exit(2);
};

let patterns;
try {
  patterns = JSON.parse(readFileSync(new URL('../lib/destructive-patterns.json', import.meta.url), 'utf8')).patterns.map((p) => ({
    ...p,
    re: new RegExp(p.regex, 'i'),
  }));
  if (patterns.length === 0) throw new Error('no patterns');
} catch (e) {
  block(`the pattern file scripts/lib/destructive-patterns.json cannot be read (${e.message}), so an executor command is refused (fail closed)`);
}

const texts = [command];
// Literal base64 (`echo <b64> | base64 -d | bash`): decode tokens that turn into readable text; random words decode to binary and are skipped.
for (const token of command.match(/[A-Za-z0-9+/]{16,}={0,2}/g) ?? []) {
  const decoded = Buffer.from(token, 'base64').toString('utf8');
  if (decoded && !decoded.includes('\uFFFD') && !/[\x00-\x08\x0B\x0C\x0E-\x1F]/.test(decoded)) texts.push(decoded);
}
for (const f of files) {
  try {
    const path = isAbsolute(f) ? f : resolve(cwd, f);
    if (statSync(path).size <= 1024 * 1024) texts.push(readFileSync(path, 'utf8'));
  } catch {
    // a missing file is the helper's error to report, not a destructive command
  }
}

for (const text of texts) {
  for (const line of text.split(/\r?\n/)) {
    const hit = patterns.find((p) => p.re.test(line));
    if (hit) block(`pattern \`${hit.id}\` (${hit.why})`);
  }
}
process.exit(0);
