// Rewrites the laptop's credential and data table ids in a compiled workflow to another n8n instance's ids (infra/n8n-ids.<target>.json).
// The .sdk.ts files stay the one source; this runs between compile and compare (check-sdk-drift.ps1 -Target Server) and before an import.
// Only credential references and dataTableId values change. An id that is not in the map is an error: passing it through would give
// the server a workflow pointing at a credential that does not exist there.
// Usage: node apply-ids.mjs <map.json> <compiled.json> <out.json>   Exit 0 = written, 1 = error (printed).
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

export function applyIds(workflow, map) {
  for (const k of ['credentials', 'dataTables']) {
    if (!map || typeof map[k] !== 'object' || map[k] === null) throw new Error(`id map has no "${k}" object`);
    for (const [from, to] of Object.entries(map[k])) {
      if (typeof to !== 'string' || !to) throw new Error(`id map ${k}.${from} is empty or not a string`);
    }
  }
  const wf = structuredClone(workflow);
  let replaced = 0;
  for (const node of wf.nodes || []) {
    for (const ref of Object.values(node.credentials || {})) {
      const to = map.credentials[ref.id];
      if (!to) throw new Error(`credential "${ref.name}" (${ref.id}) in node "${node.name}" is not in the id map`);
      ref.id = to;
      replaced++;
    }
    const dt = node.parameters && node.parameters.dataTableId;
    if (dt) {
      if (dt.mode !== 'id') throw new Error(`data table in node "${node.name}" is not referenced by id (mode ${dt.mode})`);
      const to = map.dataTables[dt.value];
      if (!to) throw new Error(`data table ${dt.value} in node "${node.name}" is not in the id map`);
      dt.value = to;
      replaced++;
    }
  }
  return { workflow: wf, replaced };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [mapPath, inPath, outPath] = process.argv.slice(2);
  try {
    const { workflow, replaced } = applyIds(JSON.parse(fs.readFileSync(inPath, 'utf8')), JSON.parse(fs.readFileSync(mapPath, 'utf8')));
    fs.writeFileSync(outPath, JSON.stringify(workflow, null, 2));
    console.log('mapped', replaced, 'references');
  } catch (e) {
    console.error('apply-ids: ' + e.message);
    process.exit(1);
  }
}
