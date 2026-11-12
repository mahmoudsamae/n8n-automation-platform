// Tests for apply-ids.mjs. Run: node scripts/sdk-drift/apply-ids.test.mjs   Exit 0 = all pass.
import assert from 'node:assert/strict';
import { applyIds } from './apply-ids.mjs';

const map = { credentials: { credLaptop000001: 'credServer000001' }, dataTables: { tableLaptop00001: 'tableServer00001' } };
const wf = () => ({
  nodes: [
    { name: 'DB', credentials: { postgres: { id: 'credLaptop000001', name: 'Postgres automation' } }, parameters: { query: 'select 1' } },
    { name: 'Load Config', parameters: { dataTableId: { __rl: true, mode: 'id', value: 'tableLaptop00001' } } },
    { name: 'Code', parameters: { jsCode: "const x = 'credLaptop000001';" } },
  ],
  connections: {},
});
let n = 0;
const t = (name, fn) => { fn(); n++; console.log('ok  ' + name); };

t('credential ids are mapped', () => {
  const out = applyIds(wf(), map);
  assert.equal(out.workflow.nodes[0].credentials.postgres.id, 'credServer000001');
  assert.equal(out.workflow.nodes[0].credentials.postgres.name, 'Postgres automation');
});
t('data table ids are mapped', () => {
  assert.equal(applyIds(wf(), map).workflow.nodes[1].parameters.dataTableId.value, 'tableServer00001');
});
t('text elsewhere is untouched (only credential and data table references change)', () => {
  assert.equal(applyIds(wf(), map).workflow.nodes[2].parameters.jsCode, "const x = 'credLaptop000001';");
});
t('the count of replaced references is reported', () => {
  assert.equal(applyIds(wf(), map).replaced, 2);
});
t('an id missing from the map is an error, not passed through', () => {
  const w = wf(); w.nodes[0].credentials.postgres.id = 'credUnknown00001';
  assert.throws(() => applyIds(w, map), /credential "Postgres automation" \(credUnknown00001\) in node "DB" is not in the id map/);
});
t('a data table id missing from the map is an error', () => {
  const w = wf(); w.nodes[1].parameters.dataTableId.value = 'tableUnknown0001';
  assert.throws(() => applyIds(w, map), /data table tableUnknown0001 in node "Load Config" is not in the id map/);
});
t('a name-mode data table reference is an error (ids only, see M7b-3)', () => {
  const w = wf(); w.nodes[1].parameters.dataTableId.mode = 'name';
  assert.throws(() => applyIds(w, map), /not referenced by id/);
});
t('a malformed map is refused', () => {
  assert.throws(() => applyIds(wf(), { credentials: { a: 'b' } }), /dataTables/);
  assert.throws(() => applyIds(wf(), { credentials: { credLaptop000001: '' }, dataTables: {} }), /empty or not a string/);
});
t('the input object is not modified', () => {
  const w = wf(); applyIds(w, map);
  assert.equal(w.nodes[0].credentials.postgres.id, 'credLaptop000001');
});
console.log(`${n} passed`);
