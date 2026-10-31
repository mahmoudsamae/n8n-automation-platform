// Structural diff: compiled SDK file vs n8n's own export. Usage: node compare.mjs <compiled.json> <export.raw>
import fs from 'node:fs';
const [compiledPath, exportPath] = process.argv.slice(2);
const mine = JSON.parse(fs.readFileSync(compiledPath, 'utf8'));
const raw = fs.readFileSync(exportPath, 'utf8');
const live = JSON.parse(raw.slice(raw.indexOf('[')))[0];

// sticky notes get random names from n8n: match them by their text instead
const byName = (wf) => Object.fromEntries(wf.nodes.map((n) => [n.type === 'n8n-nodes-base.stickyNote' ? 'STICKY ' + String((n.parameters.content || '').slice(0, 40)) : n.name, n]));
const A = byName(mine), B = byName(live);
let problems = 0, notes = 0;
const say = (kind, msg) => { if (kind === 'DIFF') problems++; else notes++; console.log(kind + '  ' + msg); };

// deep compare that ignores what n8n normalises on its own: empty objects and the default resource
const clean = (v) => {
  if (Array.isArray(v)) return v.map(clean);
  if (v && typeof v === 'object') {
    const o = {};
    for (const [k, x] of Object.entries(v)) {
      if (k === 'id' && typeof x === 'string' && /^[0-9a-f-]{36}$/.test(x)) continue; // generated condition ids
      // values n8n omits on export because they are the node's defaults, and its own IF-condition schema version
      if (k === 'resource' && (x === 'database' || x === 'message')) continue;
      if (k === 'operation' && ['executeQuery', 'sendMessage', 'send'].includes(x)) continue;
      if (k === 'language' && x === 'javaScript') continue;
      if (k === 'resume' && x === 'timeInterval') continue;
      if (k === 'unit' && x === 'seconds') continue;
      if (k === 'version' && (x === 2 || x === 4) && 'caseSensitive' in v) continue;
      const c = clean(x);
      if (c && typeof c === 'object' && !Array.isArray(c) && Object.keys(c).length === 0) continue;
      o[k] = c;
    }
    return o;
  }
  return v;
};
const diffPaths = (a, b, p = '') => {
  if (JSON.stringify(a) === JSON.stringify(b)) return [];
  if (a && b && typeof a === 'object' && typeof b === 'object' && !Array.isArray(a) && !Array.isArray(b)) {
    return [...new Set([...Object.keys(a), ...Object.keys(b)])].flatMap((k) => diffPaths(a[k], b[k], p + '.' + k));
  }
  const s = (x) => { const t = JSON.stringify(x); return t === undefined ? '(absent)' : t.length > 90 ? t.slice(0, 90) + '...' : t; };
  return [p + ': file=' + s(a) + ' live=' + s(b)];
};

for (const name of Object.keys(A)) if (!B[name]) say('DIFF', 'node only in the file: ' + name);
for (const name of Object.keys(B)) if (!A[name]) say('DIFF', 'node only live: ' + name);
for (const name of Object.keys(A)) {
  if (!B[name]) continue;
  const a = A[name], b = B[name];
  if (a.type === 'n8n-nodes-base.stickyNote') { if ((a.parameters.content || '') !== (b.parameters.content || '')) say('DIFF', name + ': sticky text differs'); continue; }
  const probs = [];
  if (a.type !== b.type) probs.push('type ' + a.type + ' vs ' + b.type);
  if (a.typeVersion !== b.typeVersion) probs.push('typeVersion ' + a.typeVersion + ' vs ' + b.typeVersion);
  const ca = JSON.stringify(a.credentials || {}), cb = JSON.stringify(b.credentials || {});
  if (ca !== cb) probs.push('credentials file=' + ca + ' live=' + cb);
  if ((a.onError || 'stopWorkflow') !== (b.onError || 'stopWorkflow')) probs.push('onError ' + a.onError + ' vs ' + b.onError);
  probs.push(...diffPaths(clean(a.parameters), clean(b.parameters), 'parameters'));
  if (probs.length) { say('DIFF', name); probs.forEach((x) => console.log('        ' + x)); }
}

const edges = (wf) => Object.entries(wf.connections).flatMap(([src, c]) => (c.main || []).flatMap((outs, i) => (outs || []).map((t) => src + '[' + i + '] -> ' + t.node + '[' + t.index + ']'))).sort();
const ea = edges(mine), eb = edges(live);
for (const e of ea) if (!eb.includes(e)) say('DIFF', 'connection only in the file: ' + e);
for (const e of eb) if (!ea.includes(e)) say('DIFF', 'connection only live: ' + e);
const sa = JSON.stringify({ ...mine.settings }), sb = JSON.stringify({ ...live.settings });
console.log('settings  file=' + sa + '\n          live=' + sb + '  (errorWorkflow/binaryMode live-only settings are expected: the file cannot carry them)');
console.log('\nnodes file/live: ' + Object.keys(A).length + '/' + Object.keys(B).length + ', connections file/live: ' + ea.length + '/' + eb.length);
console.log(problems === 0 ? 'RESULT: no differences' : 'RESULT: ' + problems + ' difference(s)');
process.exit(problems === 0 ? 0 : 1);
