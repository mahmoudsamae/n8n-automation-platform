// Read-only: execution counts per workflow and status from n8n's SQLite. Names and counts only.
// Piped into `docker exec -i n8n node -` by scripts\check-probe-quiet.ps1 for its before/after comparison.
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync('/home/node/.n8n/database.sqlite', { readOnly: true });
const rows = db.prepare('select w.name, e.status, count(*) n from execution_entity e join workflow_entity w on w.id = e.workflowId group by 1, 2').all();
for (const r of rows) console.log(`exec=${r.name}|${r.status}|${r.n}`);
