import { workflow, node, trigger, ifElse, expr } from '@n8n/workflow-sdk';

// Settings that the SDK file does not express (set via update_workflow): settings.errorWorkflow = c2NT8k3JGpuS3r6I (Stripe Error Handler).
// Depends on: credential "Stripe webhook secret" (type crypto, field Hmac Secret = the whsec_ of this environment's Stripe endpoint or stripe listen).

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

// The signature check is split in three so no workflow code ever holds the signing secret (workflows cannot read the environment:
// N8N_BLOCK_ENV_ACCESS_IN_NODE=true). 1. Parse Signature reads the header, checks the timestamp and builds the signed payload.
// 2. HMAC (Crypto node) computes the expected signature with the secret from the credential "Stripe webhook secret".
// 3. Verify Signature and Classify compares in constant time and classifies. A missing or empty credential makes the HMAC node
// fail, so n8n answers 500 (Stripe retries) and the Error Handler alerts, instead of rejecting every event with 400.
const parseSignature = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Parse Signature',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: `const invalid = () => [{ json: { header_ok: false } }];

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

return [{ json: { header_ok: true, signatures, raw_body: rawBody, signed_payload: timestamp + '.' + rawBody } }];`,
    },
    position: [460, 300],
  },
  output: [{ header_ok: true, signatures: ['abc'], raw_body: '{}', signed_payload: '1.{}' }],
});

const isHeaderOk = ifElse({
  version: 2.4,
  config: {
    name: 'Header OK?',
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 },
        conditions: [
          {
            leftValue: expr('{{ $json.header_ok }}'),
            rightValue: '',
            operator: { type: 'boolean', operation: 'true', singleValue: true },
          },
        ],
        combinator: 'and',
      },
    },
    position: [680, 300],
  },
});

const computeHmac = node({
  type: 'n8n-nodes-base.crypto',
  version: 2,
  config: {
    name: 'HMAC',
    parameters: {
      action: 'hmac',
      binaryData: false,
      type: 'SHA256',
      value: expr('{{ $json.signed_payload }}'),
      dataPropertyName: 'expected_signature',
      encoding: 'hex',
    },
    credentials: { crypto: { id: 'mvbcLKtDoh7B5WNW', name: 'Stripe webhook secret' } },
    position: [900, 200],
  },
  output: [{ header_ok: true, signatures: ['abc'], raw_body: '{}', signed_payload: '1.{}', expected_signature: 'abc' }],
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

const item = $input.first().json;
const expected = Buffer.from(String(item.expected_signature || ''));
if (!/^[0-9a-f]{64}$/.test(expected.toString())) return invalid();
const signatures = Array.isArray(item.signatures) ? item.signatures : [];
const matches = signatures.some((sig) => {
  const candidate = Buffer.from(String(sig));
  return candidate.length === expected.length && crypto.timingSafeEqual(candidate, expected);
});
if (!matches) return invalid();

const rawBody = String(item.raw_body || '');
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
    position: [1120, 200],
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
    position: [1340, 200],
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
    position: [1560, 480],
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
    position: [1560, 120],
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
    position: [1780, 40],
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
    position: [2000, -40],
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
    position: [2000, 120],
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
    position: [1780, 260],
  },
  output: [{}],
});

export default workflow('stripe-intake', 'Stripe Intake')
  .add(stripeWebhook)
  .to(parseSignature)
  .to(
    isHeaderOk
      .onTrue(
        computeHmac.to(
          verifyAndClassify.to(
            isSignatureValid
              .onTrue(
                insertEvent
                  .to(isNewEvent.onTrue(respondReceived).onFalse(respondDuplicate))
                  .onError(respondStorageFailed),
              )
              .onFalse(respondInvalid),
          ),
        ),
      )
      .onFalse(respondInvalid),
  );
