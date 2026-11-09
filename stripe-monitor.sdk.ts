import { workflow, node, trigger, ifElse, sticky, expr } from '@n8n/workflow-sdk';

// Settings that the SDK file does not express (set via update_workflow):
//   settings.errorWorkflow = c2NT8k3JGpuS3r6I (Stripe Error Handler), so a crashing Monitor is reported too.

const everyFiveMinutes = trigger({
  type: 'n8n-nodes-base.scheduleTrigger',
  version: 1.4,
  config: {
    name: 'Every 5 Minutes',
    parameters: { rule: { interval: [{ field: 'minutes', minutesInterval: 5 }] } },
    position: [200, 400],
  },
  output: [{}],
});

// Dead man's switch: a second branch off the trigger, placed ABOVE the alert chain (y 240 < 400) so n8n runs it first and a
// Postgres failure in the chain cannot suppress it. GET on the Healthchecks.io ping URL; the URL is the only credential, so it
// lives in the n8n data table stripe_heartbeat (n8n's own database, so it is readable while Postgres is down) and never in this
// file; workflows cannot read the environment. It has a table of its own so the URL never appears in other workflows' execution data.
// 3 tries 5 s apart (n8n's retry wait is fixed, not exponential: the ping is harmless to repeat and the 10 min grace tolerates
// misses), then the error is absorbed (continueRegularOutput) so a ping failure never crashes the Monitor or fires the Error Handler.
// No row means no ping, so Healthchecks alerts: the missing URL is reported, not hidden.
// The ping is also skipped when the alert settings in stripe_config are incomplete (M7b-3 review, HIGH): without them every alert
// fails on both channels, so the only way left to tell a human is Healthchecks' own email. A green heartbeat therefore means
// "n8n's scheduler runs AND alerts can be addressed", still not "Postgres or the Processor work". Both tables are n8n-internal,
// so this branch keeps working while Postgres is down.
const loadHeartbeat = node({
  type: 'n8n-nodes-base.dataTable',
  version: 1.1,
  config: {
    name: 'Load Heartbeat URL',
    parameters: {
      resource: 'row',
      operation: 'get',
      dataTableId: { __rl: true, mode: 'id', value: 'bD28CJQQfPQBR61R' },
      returnAll: true,
    },
    onError: 'continueRegularOutput',
    position: [420, 240],
  },
  output: [{ id: 1, heartbeat_url: 'https://hc-ping.com/example' }],
});

const loadAlertConfig = node({
  type: 'n8n-nodes-base.dataTable',
  version: 1.1,
  config: {
    name: 'Load Alert Config',
    parameters: {
      resource: 'row',
      operation: 'get',
      dataTableId: { __rl: true, mode: 'id', value: '7NM52PSapza2TNWP' },
      returnAll: true,
    },
    alwaysOutputData: true,
    executeOnce: true,
    onError: 'continueRegularOutput',
    position: [640, 240],
  },
  output: [{ id: 1, telegram_chat_id: '123', alert_email_to: 'ops@alerts.invalid', alert_email_from: 'n8n@alerts.invalid' }],
});

// Same rules as Send Alert's Config (exactly one row, the three alert columns set), but it outputs only the verdict, not the values.
const alertConfig = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Alert Config',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: `const KEYS = ['telegram_chat_id', 'alert_email_to', 'alert_email_from'];
const items = $input.all();
const failure = items.find((i) => i.json && i.json.error);
const rows = items.map((i) => i.json).filter((r) => r && r.id !== undefined && !r.error);
let config_problem = '';
if (failure) config_problem = 'data table stripe_config could not be read: ' + String(failure.json.error.message || failure.json.error).slice(0, 150);
else if (rows.length !== 1) config_problem = 'data table stripe_config must have exactly one row, found ' + rows.length;
else {
  const empty = KEYS.filter((k) => rows[0][k] == null || String(rows[0][k]).trim() === '');
  if (empty.length) config_problem = 'data table stripe_config: ' + empty.join(', ') + ' is empty';
}
return [{ json: { alerts_deliverable: !config_problem, config_problem } }];`,
    },
    position: [860, 240],
  },
  output: [{ alerts_deliverable: true, config_problem: '' }],
});

const alertsDeliverable = ifElse({
  version: 2.4,
  config: {
    name: 'Alerts Deliverable?',
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 },
        conditions: [
          {
            leftValue: expr('{{ $json.alerts_deliverable }}'),
            rightValue: '',
            operator: { type: 'boolean', operation: 'true', singleValue: true },
          },
        ],
        combinator: 'and',
      },
    },
    position: [1080, 240],
  },
});

const heartbeatPing = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.5,
  config: {
    name: 'Heartbeat Ping',
    parameters: {
      method: 'GET',
      url: expr("{{ $('Load Heartbeat URL').first().json.heartbeat_url }}"),
      options: { timeout: 10000 },
    },
    retryOnFail: true,
    maxTries: 3,
    waitBetweenTries: 5000,
    onError: 'continueRegularOutput',
    position: [1300, 240],
  },
  output: [{ data: 'OK' }],
});

// Three kinds of event that need a human. All skip rows already alerted (alerted_at set).
//   dead          failed and attempts >= 5: the Processor will never retry it.
//   stale_pending pending for 10+ min since pending_since: the Processor is not picking events up.
//   stuck_failed  failed with attempts < 5 whose last claim is 10+ min old: the Processor retries these every minute,
//                 so an old claimed_at means it is not running.
//   stuck_processing  processing with claimed_at 20+ min old. The Processor releases such rows at 10 min, so 20 (twice
//                 that) means a healthy Processor always acts first and the Monitor never races it.
const findAlertable = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.8,
  config: {
    name: 'Find Alertable Events',
    parameters: {
      resource: 'database',
      operation: 'executeQuery',
      query:
        "SELECT event_id, event_type, attempts, last_error, CASE WHEN status = 'failed' AND attempts >= 5 THEN 'dead' WHEN status = 'pending' THEN 'stale_pending' WHEN status = 'processing' THEN 'stuck_processing' ELSE 'stuck_failed' END AS reason FROM stripe_events WHERE alerted_at IS NULL AND ((status = 'failed' AND attempts >= 5) OR (status = 'pending' AND pending_since < now() - interval '10 minutes') OR (status = 'processing' AND claimed_at < now() - interval '20 minutes') OR (status = 'failed' AND attempts < 5 AND COALESCE(claimed_at, pending_since) < now() - interval '10 minutes')) ORDER BY received_at LIMIT 10;",
    },
    credentials: { postgres: { id: 'XVNN7sIThniqsuOf', name: 'Postgres automation' } },
    position: [420, 400],
  },
  output: [{ event_id: 'evt_1', event_type: 'checkout.session.completed', attempts: 5, last_error: 'example', reason: 'dead' }],
});

const buildAlert = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Build Alert',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: `const clean = (s) => String(s == null ? '' : s)
  .replace(/bot\\d+:[A-Za-z0-9_-]+/g, 'bot***')
  .replace(/\\d{6,}:[A-Za-z0-9_-]{20,}/g, '***')
  .replace(/whsec_[A-Za-z0-9]+/g, 'whsec_***')
  .replace(/(sk|rk|pk)_(test|live)_[A-Za-z0-9]+/g, '$1_$2_***')
  .replace(/\\s+/g, ' ')
  .trim();

const rows = $input.all().map((i) => i.json).filter((r) => r && typeof r.event_id === 'string' && r.event_id);
if (rows.length === 0) return [];

const label = {
  dead: 'DEAD: retries exhausted, needs a manual replay',
  stale_pending: 'STALE PENDING: waiting 10+ min, is the Processor running?',
  stuck_failed: 'STUCK FAILED: retry overdue 10+ min, is the Processor running?',
  stuck_processing: 'STUCK PROCESSING: claimed 20+ min ago and never released, is the Processor running?',
};

const blocks = rows.map((r) => {
  const lines = [
    '[' + (label[r.reason] || r.reason) + ']',
    'Event: ' + clean(r.event_id) + ' (' + clean(r.event_type).slice(0, 80) + ')',
    'Attempts: ' + r.attempts,
    'Last error: ' + (clean(r.last_error).slice(0, 200) || '(none)'),
  ];
  if (r.reason === 'dead' && /^evt_[A-Za-z0-9_]+$/.test(r.event_id)) {
    lines.push('Replay: .\\\\scripts\\\\replay.ps1 -EventId ' + r.event_id + ' -Reason "<why>"');
  }
  return lines.join('\\n');
});

const n = rows.length;
return [{
  json: {
    subject: 'Stripe pipeline: ' + n + ' event' + (n === 1 ? '' : 's') + ' need' + (n === 1 ? 's' : '') + ' attention',
    body: blocks.join('\\n\\n'),
    event_ids: rows.map((r) => r.event_id),
  },
}];`,
    },
    position: [640, 400],
  },
  output: [{ subject: 'Stripe pipeline: 1 event needs attention', body: 'details', event_ids: ['evt_1'] }],
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
    position: [860, 400],
  },
  output: [{ telegram: 'ok', email: 'ok' }],
});

// Runs only if Send Alert did not throw, i.e. at least one channel delivered. Otherwise alerted_at stays NULL and the next run retries.
const markAlerted = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.8,
  config: {
    name: 'Mark Alerted',
    parameters: {
      resource: 'database',
      operation: 'executeQuery',
      query:
        'UPDATE stripe_events SET alerted_at = now() WHERE alerted_at IS NULL AND event_id IN (SELECT jsonb_array_elements_text($1::jsonb));',
      options: {
        queryReplacement: expr("{{ [JSON.stringify($('Build Alert').first().json.event_ids)] }}"),
        queryBatching: 'independently',
      },
    },
    credentials: { postgres: { id: 'XVNN7sIThniqsuOf', name: 'Postgres automation' } },
    position: [1080, 400],
  },
  output: [{ success: true }],
});

const note = sticky(
  '## Stripe Monitor\nEvery 5 min: finds events that need a human and sends ONE alert listing up to 10 of them (oldest first; the rest are picked up on the next run).\n\n- **dead**: failed with attempts >= 5 (never retried again). Alert includes the replay command.\n- **stale pending**: pending for 10+ min, measured from `pending_since` (not `received_at`, so a row just released by stuck-row recovery or just replayed is not stale).\n- **stuck failed**: failed with attempts < 5 and `COALESCE(claimed_at, pending_since)` older than 10 min. The Processor retries these every minute, so the Processor is probably not running.\n- **stuck processing**: `processing` with `claimed_at` older than 20 min (twice the Processor\'s 10 min release, so a healthy Processor always releases first).\n\n**Idempotency:** `alerted_at` is set only AFTER the alert was delivered (at-least-once). A crash between sending and `Mark Alerted` can send one alert twice. The Processor clears `alerted_at` when it claims a row again, so a later stuck episode alerts again.\n\n**Heartbeat (dead man\'s switch):** `Heartbeat Ping` is a separate branch off the trigger, placed ABOVE the alert chain so it runs first and a Postgres failure in the chain cannot suppress it. It GETs the URL in the n8n data table `stripe_heartbeat` (Healthchecks.io, period 5 min, grace 10 min) on every run; about 15 min of silence makes Healthchecks.io email the owner, which covers n8n or WSL being down. 3 tries 5 s apart (n8n\'s retry wait is fixed, not exponential; the ping is harmless to repeat), then the error is absorbed so a ping failure never crashes the Monitor. A green heartbeat proves n8n\'s scheduler and network only, NOT Postgres or the Processor. The URL is the only credential: it lives in that data table (n8n\'s own database, readable while Postgres is down), never in this file; no row means no ping, so Healthchecks alerts. The ping is also skipped when the alert settings in `stripe_config` are incomplete (then no alert could reach anyone), so Healthchecks reports that too. Pause the check before a planned shutdown.',
  [],
  { color: 4, position: [200, -360], width: 900, height: 330 },
);

export default workflow('stripe-monitor', 'Stripe Monitor')
  .add(everyFiveMinutes)
  .to(loadHeartbeat)
  .to(loadAlertConfig)
  .to(alertConfig)
  .to(alertsDeliverable.onTrue(heartbeatPing))
  .add(everyFiveMinutes)
  .to(findAlertable)
  .to(buildAlert)
  .to(sendAlert)
  .to(markAlerted)
  .add(note);
