// Compiles an n8n SDK workflow file to workflow JSON. Usage: node compile.mjs <file.sdk.ts> <out.json>
import { pathToFileURL, fileURLToPath } from 'node:url';
import fs from 'node:fs';
import path from 'node:path';
const [src, out] = process.argv.slice(2);
// The SDK file imports '@n8n/workflow-sdk', which resolves from scripts/sdk-drift/node_modules, so a copy of the file is placed beside this script (and removed again).
const copy = path.join(path.dirname(fileURLToPath(import.meta.url)), 'compiled-' + path.basename(src));
fs.copyFileSync(src, copy);
try {
  const mod = await import(pathToFileURL(copy).href);
  const wf = mod.default;
  const json = typeof wf.toJSON === 'function' ? wf.toJSON() : wf;
  fs.writeFileSync(out, JSON.stringify(json, null, 2));
  console.log('compiled', path.basename(src), '->', json.nodes.length, 'nodes,', Object.keys(json.connections).length, 'connection sources');
} finally {
  fs.rmSync(copy, { force: true });
}
