import { workflow, node, trigger, sticky, expr } from '@n8n/workflow-sdk';

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
  '## Stripe Monitor\nEvery 5 min: finds events that need a human and sends ONE alert listing up to 10 of them (oldest first; the rest are picked up on the next run).\n\n- **dead**: failed with attempts >= 5 (never retried again). Alert includes the replay command.\n- **stale pending**: pending for 10+ min, measured from `pending_since` (not `received_at`, so a row just released by stuck-row recovery or just replayed is not stale).\n- **stuck failed**: failed with attempts < 5 and `COALESCE(claimed_at, pending_since)` older than 10 min. The Processor retries these every minute, so the Processor is probably not running.\n\n**Idempotency:** `alerted_at` is set only AFTER the alert was delivered (at-least-once). A crash between sending and `Mark Alerted` can send one alert twice. The Processor clears `alerted_at` when it claims a row again, so a later stuck episode alerts again.\n\n- **stuck processing**: `processing` with `claimed_at` older than 20 min (twice the Processor\'s 10 min release, so a healthy Processor always releases first).\n\n**Not covered:** if n8n or WSL is down nothing alerts here (M5: external dead man\'s switch).',
  [],
  { color: 4, position: [200, 40], width: 900, height: 330 },
);

export default workflow('stripe-monitor', 'Stripe Monitor')
  .add(everyFiveMinutes)
  .to(findAlertable)
  .to(buildAlert)
  .to(sendAlert)
  .to(markAlerted)
  .add(note);
