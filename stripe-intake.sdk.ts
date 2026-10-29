import { workflow, node, trigger, ifElse, expr } from '@n8n/workflow-sdk';

// Settings that the SDK file does not express (set via update_workflow): settings.errorWorkflow = c2NT8k3JGpuS3r6I (Stripe Error Handler).

const stripeWebhook = trigger({
  type: 'n8n-nodes-base.webhook',
  version: 2.2,
  config: {
    name: 'Stripe Webhook',
    parameters: {
      httpMethod: 'POST',
      path: 'stripe-intake',
      authentication: 'none',
      responseMode: 'responseNode',
      options: { rawBody: true },
    },
    position: [240, 300],
  },
  output: [{ headers: { 'stripe-signature': 't=1,v1=abc' }, body: {} }],
});

const verifyAndClassify = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Verify Signature and Classify',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: `const crypto = require('crypto');
const invalid = () => [{ json: { valid: false } }];

const secret = $env.STRIPE_WEBHOOK_SECRET;
if (!secret) return invalid();

const item = $input.first();
const header = (item.json.headers || {})['stripe-signature'] || '';
let timestamp = null;
const signatures = [];
for (const part of header.split(',')) {
  const idx = part.indexOf('=');
  if (idx < 0) continue;
  const key = part.slice(0, idx).trim();
  const value = part.slice(idx + 1).trim();
  if (key === 't') timestamp = value;
  if (key === 'v1') signatures.push(value);
}
if (!timestamp || !/^\\d+$/.test(timestamp) || signatures.length === 0) return invalid();

const age = Math.floor(Date.now() / 1000) - Number(timestamp);
if (age > 300) return invalid();

const rawBuffer = await this.helpers.getBinaryDataBuffer(0, 'data');
const rawBody = rawBuffer.toString('utf8');

const expected = Buffer.from(
  crypto.createHmac('sha256', secret).update(timestamp + '.' + rawBody).digest('hex'),
);
const matches = signatures.some((sig) => {
  const candidate = Buffer.from(sig);
  return candidate.length === expected.length && crypto.timingSafeEqual(candidate, expected);
});
if (!matches) return invalid();

let event;
try {
  event = JSON.parse(rawBody);
} catch (e) {
  return invalid();
}
if (!event || typeof event.id !== 'string' || typeof event.type !== 'string') return invalid();

const object = (event.data && event.data.object) || {};
const isPending =
  (event.type === 'checkout.session.completed' && object.payment_status === 'paid') ||
  event.type === 'checkout.session.async_payment_succeeded';

return [{
  json: {
    valid: true,
    event_id: event.id,
    event_type: event.type,
    status: isPending ? 'pending' : 'ignored',
    payload: rawBody,
  },
}];`,
    },
    position: [540, 300],
  },
  output: [{ valid: true, event_id: 'evt_1', event_type: 'checkout.session.completed', status: 'pending', payload: '{}' }],
});

const isSignatureValid = ifElse({
  version: 2.4,
  config: {
    name: 'Signature Valid?',
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 },
        conditions: [
          {
            leftValue: expr('{{ $json.valid }}'),
            rightValue: '',
            operator: { type: 'boolean', operation: 'true', singleValue: true },
          },
        ],
        combinator: 'and',
      },
    },
    position: [840, 300],
  },
});

const respondInvalid = node({
  type: 'n8n-nodes-base.respondToWebhook',
  version: 1.5,
  config: {
    name: 'Respond 400 Invalid Signature',
    parameters: {
      respondWith: 'json',
      responseBody: '{"error": "invalid signature"}',
      options: { responseCode: 400 },
    },
    position: [1140, 480],
  },
  output: [{}],
});

const insertEvent = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.8,
  config: {
    name: 'Insert Event',
    parameters: {
      resource: 'database',
      operation: 'executeQuery',
      query:
        'INSERT INTO stripe_events (event_id, event_type, status, payload) VALUES ($1, $2, $3, $4::jsonb) ON CONFLICT (event_id) DO NOTHING RETURNING event_id;',
      options: {
        queryReplacement: expr('{{ [$json.event_id, $json.event_type, $json.status, $json.payload] }}'),
      },
    },
    credentials: { postgres: { id: 'XVNN7sIThniqsuOf', name: 'Postgres automation' } },
    onError: 'continueErrorOutput',
    position: [1140, 200],
  },
  output: [{ event_id: 'evt_1' }],
});

const isNewEvent = ifElse({
  version: 2.4,
  config: {
    name: 'New Event?',
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 },
        conditions: [
          {
            leftValue: expr('{{ $json.event_id }}'),
            rightValue: '',
            operator: { type: 'string', operation: 'exists', singleValue: true },
          },
        ],
        combinator: 'and',
      },
    },
    position: [1440, 120],
  },
});

const respondReceived = node({
  type: 'n8n-nodes-base.respondToWebhook',
  version: 1.5,
  config: {
    name: 'Respond 200 Received',
    parameters: {
      respondWith: 'json',
      responseBody: '{"received": true}',
      options: { responseCode: 200 },
    },
    position: [1740, 40],
  },
  output: [{}],
});

const respondDuplicate = node({
  type: 'n8n-nodes-base.respondToWebhook',
  version: 1.5,
  config: {
    name: 'Respond 200 Duplicate',
    parameters: {
      respondWith: 'json',
      responseBody: '{"received": true, "duplicate": true}',
      options: { responseCode: 200 },
    },
    position: [1740, 200],
  },
  output: [{}],
});

const respondStorageFailed = node({
  type: 'n8n-nodes-base.respondToWebhook',
  version: 1.5,
  config: {
    name: 'Respond 500 Storage Failed',
    parameters: {
      respondWith: 'json',
      responseBody: '{"error": "storage failed"}',
      options: { responseCode: 500 },
    },
    position: [1440, 340],
  },
  output: [{}],
});

export default workflow('stripe-intake', 'Stripe Intake')
  .add(stripeWebhook)
  .to(verifyAndClassify)
  .to(
    isSignatureValid
      .onTrue(
        insertEvent
          .to(isNewEvent.onTrue(respondReceived).onFalse(respondDuplicate))
          .onError(respondStorageFailed),
      )
      .onFalse(respondInvalid),
  );
