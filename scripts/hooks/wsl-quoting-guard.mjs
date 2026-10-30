// PreToolUse hook (PowerShell and Bash): block `wsl ...` command lines whose quoting is unsafe, and point to scripts/wsl-sh.ps1.
// Why: `wsl <cmd>` runs through an outer shell that expands $VAR and $(...) BEFORE bash sees them, so a failing command can echo an
// expanded secret into the session (this printed the heartbeat URL once, despite a CLAUDE.md line warning about it).
// Reads the hook event JSON on stdin. Exit 2 + stderr = block (the message goes to Claude); exit 0 = allow.
// Checks one line at a time, so a base64 here-string script that contains $(...) on its own lines is fine.
// Limits: it is a text heuristic. It cannot see inside variables or files, and it only guards `wsl` command lines.

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

// `wsl` as a command word; not scripts\wsl-sh.ps1 (preceded by \ or followed by -).
const WSL = /(?<![\w\\/.-])wsl(?:\.exe)?(?=\s)/i;
// The sanctioned patterns: the script travels as base64, or goes through the helper.
const SAFE = /base64|wsl-sh\.ps1/i;
// bash -c / sh -c given to wsl on this line.
const SHELL_C = /(?<![\w\\/.-])wsl(?:\.exe)?\s[^|;]*?\b(?:ba)?sh\s+-c\b(.*)$/i;
// Expansion that survives PowerShell/Git Bash quoting and reaches WSL's outer shell: $( , `$ (PowerShell escape), \$ (backslash escape).
const EXPANSION = /\$\(|`\$|\\\$/;
// Reads or prints secrets: a .env file, printenv of a secret-looking name, or `docker compose config` (prints interpolated values).
const SECRET_READ = /\.env\b|printenv\s+\S*(?:PASSWORD|SECRET|TOKEN|KEY|HEARTBEAT|URL)|compose\s+config(?!\s+--quiet)/i;

let reason = null;
for (const line of command.split(/\r?\n/)) {
  if (!WSL.test(line) || SAFE.test(line)) continue;
  const shell = line.match(SHELL_C);
  if (shell && EXPANSION.test(shell[1])) {
    reason = 'a `wsl ... bash -c` argument contains $( , `$ or \\$, which WSL\'s outer shell expands before bash runs';
    break;
  }
  if (SECRET_READ.test(line)) {
    reason = 'a `wsl` command reads or prints a .env file, a secret-looking variable, or `docker compose config`; its output (or an error message) would put the value in this session';
    break;
  }
}

if (!reason) process.exit(0);

process.stderr.write(
  `wsl-quoting-guard blocked this command: ${reason}.\n` +
    `Use scripts/wsl-sh.ps1 instead: & scripts\\wsl-sh.ps1 -Script '<bash script>' (or -File). The script travels as base64, so no outer shell touches it. ` +
    `Read secrets INSIDE the script, keep them in a shell variable and print only yes/no, never the value. See the CLAUDE.md gotchas.\n`,
);
process.exit(2);
