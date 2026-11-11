import { workflow, node, trigger, expr } from '@n8n/workflow-sdk';

// Throwaway probe, not a pipeline workflow: create it, run it manually, read the output, archive it.
// It tries every route from workflow code to the n8n environment and reports names and READABLE/denied only, never a value.
// Used for M7b-3 (laptop) and M7b-5 (server). Expected with N8N_BLOCK_ENV_ACCESS_IN_NODE=true: every line "denied" or "empty".

const start = trigger({
  type: 'n8n-nodes-base.manualTrigger',
  version: 1,
  config: { name: 'Run Probe', position: [200, 300] },
  output: [{}],
});

const codeProbe = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Code Probe',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: `const report = {};
const probe = (label, fn) => {
  try {
    const v = fn();
    report[label] = v === undefined || v === null || v === '' || v === 0 ? 'empty' : 'READABLE';
  } catch (e) {
    report[label] = 'denied: ' + String((e && e.message) || e).replace(/\\s+/g, ' ').slice(0, 90);
  }
};
probe('$env.N8N_ENCRYPTION_KEY', () => $env.N8N_ENCRYPTION_KEY);
probe('$env.STRIPE_WEBHOOK_SECRET', () => $env.STRIPE_WEBHOOK_SECRET);
probe('$env.HEARTBEAT_URL', () => $env.HEARTBEAT_URL);
probe('$env.TZ', () => $env.TZ);
probe('Object.keys($env)', () => Object.keys($env).length);
probe('process.env', () => Object.keys(process.env).filter((k) => /KEY|SECRET|URL|PASSWORD/i.test(k)).length);
probe("require('fs') /proc/self/environ", () => require('fs').readFileSync('/proc/self/environ').length);
probe("require('child_process')", () => require('child_process').execSync('env').length);
return [{ json: report }];`,
    },
    position: [420, 300],
  },
  output: [{ '$env.TZ': 'denied' }],
});

const expressionProbe = node({
  type: 'n8n-nodes-base.set',
  version: 3.4,
  config: {
    name: 'Expression Probe',
    parameters: {
      mode: 'manual',
      assignments: {
        assignments: [
          { id: 'tz', name: 'expression_env_tz_is_set', value: expr('{{ !!$env.TZ }}'), type: 'boolean' },
          { id: 'key', name: 'expression_env_encryption_key_is_set', value: expr('{{ !!$env.N8N_ENCRYPTION_KEY }}'), type: 'boolean' },
        ],
      },
      includeOtherFields: true,
      options: {},
    },
    onError: 'continueRegularOutput',
    position: [640, 300],
  },
  output: [{ expression_env_tz_is_set: false }],
});

export default workflow('env-probe', 'M7b env probe (throwaway)').add(start).to(codeProbe).to(expressionProbe);
