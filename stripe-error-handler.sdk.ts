import { workflow, node, trigger, ifElse, sticky, expr } from '@n8n/workflow-sdk';

// Settings that the SDK file does not express (set via update_workflow):
//   Stripe Intake, Stripe Processor and Stripe Monitor have settings.errorWorkflow = this workflow's id.
// This workflow has no errorWorkflow itself, so an error here can never alert in a loop.

const onError = trigger({
  type: 'n8n-nodes-base.errorTrigger',
  version: 1,
  config: { name: 'Error Trigger', position: [200, 400] },
  output: [
    {
      execution: { id: '231', lastNodeExecuted: 'Claim Events', error: { message: 'connect ECONNREFUSED' }, mode: 'trigger' },
      workflow: { id: 'ylR2t9B0ZAH1cLfq', name: 'Stripe Processor' },
    },
  ],
});

const throttle = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Throttle and Format',
    parameters: {
      mode: 'runOnceForEachItem',
      language: 'javaScript',
      jsCode: `const WINDOW_MS = 15 * 60 * 1000;
const KEEP_MS = 24 * 60 * 60 * 1000;

const clean = (s) => String(s == null ? '' : s)
  .replace(/bot\\d+:[A-Za-z0-9_-]+/g, 'bot***')
  .replace(/\\d{6,}:[A-Za-z0-9_-]{20,}/g, '***')
  .replace(/whsec_[A-Za-z0-9]+/g, 'whsec_***')
  .replace(/(sk|rk|pk)_(test|live)_[A-Za-z0-9]+/g, '$1_$2_***')
  .replace(/postgres(ql)?:\\/\\/\\S+/gi, 'postgres://***')
  .replace(/\\s+/g, ' ')
  .trim();

const wf = (($json.workflow && $json.workflow.name) || 'unknown workflow');
const exec = $json.execution || {};
const failedNode = exec.lastNodeExecuted || (exec.error && exec.error.node && exec.error.node.name) || 'unknown node';
const rawMessage = (exec.error && exec.error.message)
  || ($json.trigger && $json.trigger.error && $json.trigger.error.message)
  || 'unknown error';
const message = clean(rawMessage).slice(0, 300);

// Throttle state lives in workflow static data, not Postgres, so it still works when the DB is the thing that is down.
const store = $getWorkflowStaticData('global');
store.throttle = store.throttle || {};
const now = Date.now();
for (const k of Object.keys(store.throttle)) {
  if (now - store.throttle[k].lastSent > KEEP_MS) delete store.throttle[k];
}

const key = wf + ' | ' + failedNode;
const entry = store.throttle[key];
if (entry && now - entry.lastSent < WINDOW_MS) {
  entry.suppressed = (entry.suppressed || 0) + 1;
  return { json: { send: false, key, suppressed: entry.suppressed } };
}

const suppressed = entry ? (entry.suppressed || 0) : 0;
store.throttle[key] = { lastSent: now, suppressed: 0 };

const lines = [
  'Workflow: ' + clean(wf),
  'Node: ' + clean(failedNode),
  'Execution id: ' + clean(exec.id || 'n/a'),
  'Error: ' + message,
];
if (suppressed > 0) lines.push(suppressed + ' similar errors suppressed since the last alert for this workflow and node');

return { json: { send: true, key, subject: 'Workflow error: ' + clean(wf) + ' / ' + clean(failedNode), body: lines.join('\\n') } };`,
    },
    position: [420, 400],
  },
  output: [{ send: true, key: 'k', subject: 'Workflow error: Stripe Processor / Claim Events', body: 'Workflow: Stripe Processor' }],
});

const shouldSend = ifElse({
  version: 2.4,
  config: {
    name: 'Send?',
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 },
        conditions: [
          {
            leftValue: expr('{{ $json.send }}'),
            rightValue: '',
            operator: { type: 'boolean', operation: 'true', singleValue: true },
          },
        ],
        combinator: 'and',
      },
    },
    position: [640, 400],
  },
});

const sendAlert = node({
  type: 'n8n-nodes-base.executeWorkflow',
  version: 1.4,
  config: {
    name: 'Send Alert',
    parameters: {
      source: 'database',
      workflowId: { __rl: true, mode: 'id', value: 'WO2ebvkZGK5NxzVo' },
      mode: 'once',
      options: { waitForSubWorkflow: true },
    },
    position: [860, 300],
  },
  output: [{ telegram: 'ok', email: 'ok' }],
});

const note = sticky(
  '## Stripe Error Handler\nSet as the errorWorkflow of Intake, Processor and Monitor. Fires only for PRODUCTION executions that crash (not for events marked failed: those are the Monitor\'s job).\n\n**Throttle:** at most one alert per (workflow | node) per 15 minutes. Suppressed repeats are counted and reported on the next alert. State is in workflow static data, so it works while Postgres is down. If the alert itself cannot be delivered, that window is still consumed (no retry).\n\nDelivery goes through the shared `Stripe Send Alert` sub-workflow (Telegram + email).',
  [],
  { color: 4, position: [200, 40], width: 640, height: 240 },
);

export default workflow('stripe-error-handler', 'Stripe Error Handler')
  .add(onError)
  .to(throttle)
  .to(shouldSend.onTrue(sendAlert))
  .add(note);
