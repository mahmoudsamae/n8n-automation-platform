// PostToolUse hook: after an n8n MCP call that changes a workflow, remind Claude to export it to its
// .sdk.ts file and diff against live. Prevents drift between the repo and the live workflow.
// Reads the hook event JSON on stdin; prints additionalContext JSON, or nothing when no reminder is due.

const WORKFLOW_FILES = {
  '3j0pWVoxvDY2sdO5': 'stripe-intake.sdk.ts',
  'ylR2t9B0ZAH1cLfq': 'stripe-processor.sdk.ts',
};

let raw = '';
for await (const chunk of process.stdin) raw += chunk;

let event;
try {
  event = JSON.parse(raw);
} catch {
  process.exit(0); // never break a tool call because of a malformed hook payload
}

const tool = String(event.tool_name ?? '').replace(/^mcp__n8n__/, '');
const response = event.tool_response;
const responseText = typeof response === 'string' ? response : JSON.stringify(response ?? '');

// A failed call changed nothing, so there is nothing to export.
if (response?.isError === true || response?.is_error === true) process.exit(0);

const input = event.tool_input ?? {};
const idMatch = responseText.match(/"(?:workflowId|id)"\s*:\s*"([A-Za-z0-9]+)"/);
const workflowId = input.workflowId ?? input.id ?? idMatch?.[1];
const file = WORKFLOW_FILES[workflowId];

const target = workflowId
  ? `workflow ${workflowId}${file ? ` (${file})` : ' (not in the CLAUDE.md map: pick or create its .sdk.ts file)'}`
  : 'the workflow you just changed';

const message =
  `n8n drift check: ${tool} changed ${target}. Before finishing: ` +
  `(1) export the live workflow to its .sdk.ts file, ` +
  `(2) diff that file against live (get_workflow_details) and fix any difference, ` +
  `(3) show me the diff result. Do not report the change as done until this is clean.`;

process.stdout.write(
  JSON.stringify({ hookSpecificOutput: { hookEventName: 'PostToolUse', additionalContext: message } }),
);
