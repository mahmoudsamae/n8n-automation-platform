import { workflow, node, trigger, ifElse, expr } from '@n8n/workflow-sdk';

// Demo Checkout (M7c, docs/tasks/m7c-demo.md): POST /webhook/demo-checkout, reached only through demo-web (Caddy) as POST /api/demo/checkout.
// Creates one Stripe Checkout session in the server's sandbox for a visitor and answers {"url": ...}; the page redirects there.
// Settings that the SDK file does not express (scripts\lib\workflows.ps1): errorWorkflow = c2NT8k3JGpuS3r6I (Stripe Error Handler),
// on the server no successful executions are saved (the token sits in this workflow's data).
// Depends on: credential "Stripe demo checkout" (restricted sandbox key, Checkout Sessions write only, server id kN7IKRSGZFcV7k9O),
// credential "Postgres automation" (n8n_app on the server), data table stripe_config (column demo_daily_limit, integer, no default),
// workflow Stripe Send Alert (id WO2ebvkZGK5NxzVo, called by id: update it here if recreated).
// Order, so a refused request never calls Stripe: reserve a demo_sessions row (cap check and insert in ONE statement), then create the
// session with Idempotency-Key = sha256(token) (a retry returns the same session), then store the session id on the row.
// The cap is soft: two requests in the same instant can both see 49 and both insert (READ COMMITTED). Accepted for a demo (owner scope
// cut 2026-11-13); the overshoot is bounded by the number of truly simultaneous requests.

const demoCheckoutWebhook = trigger({
  type: 'n8n-nodes-base.webhook',
  version: 2.2,
  config: {
    name: 'Demo Checkout Webhook',
    parameters: { httpMethod: 'POST', path: 'demo-checkout', authentication: 'none', responseMode: 'responseNode', options: {} },
    position: [200, 400],
  },
  output: [{ headers: {}, body: {} }],
});

// By id, not by name: n8n's name mode matches LIKE '%name%' (see the Processor). Ids differ per instance (infra\n8n-ids.server.json).
const loadConfig = node({
  type: 'n8n-nodes-base.dataTable',
  version: 1.1,
  config: {
    name: 'Load Config',
    parameters: { resource: 'row', operation: 'get', dataTableId: { __rl: true, mode: 'id', value: '7NM52PSapza2TNWP' }, returnAll: true },
    alwaysOutputData: true,
    executeOnce: true,
    onError: 'continueRegularOutput',
    position: [420, 400],
  },
  output: [{ id: 1, demo_daily_limit: 50 }],
});

// A config problem throws: n8n answers 500 and the Error Handler alerts the owner. No default limit.
const prepareSession = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Prepare Session',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: `const crypto = require('crypto');
const items = $input.all();
if (items.some((i) => i.json && i.json.error)) throw new Error('data table stripe_config could not be read');
const rows = items.map((i) => i.json).filter((r) => r && r.id !== undefined);
if (rows.length !== 1) throw new Error('data table stripe_config must have exactly one row, found ' + rows.length);
const limit = Number(rows[0].demo_daily_limit);
if (!Number.isInteger(limit) || limit < 1 || limit > 1000) throw new Error('demo_daily_limit in data table stripe_config must be an integer from 1 to 1000');

// 32 random bytes: unguessable, so the stored sha256 needs no salt. The token itself is never stored; it reaches the visitor only in
// the success_url fragment (#...), which browsers never send to a server.
const token = crypto.randomBytes(32).toString('base64url');
const tokenHash = crypto.createHash('sha256').update(token).digest('hex');
// A generated address on the owner's domain (no MX): Checkout shows it prefilled, the invoice email only ever reaches Mailpit.
const demoEmail = 'demo-' + crypto.randomBytes(4).toString('hex') + '@demo.mahmud-alhussen.de';
const origin = 'https://invoice.mahmud-alhussen.de';
// Form-encoded by hand: the Code node's sandbox has no URLSearchParams (ReferenceError, seen 2026-11-13).
const fields = {
  mode: 'payment',
  'payment_method_types[0]': 'card',
  'line_items[0][quantity]': '1',
  'line_items[0][price_data][currency]': 'eur',
  'line_items[0][price_data][unit_amount]': '3000',
  'line_items[0][price_data][product_data][name]': 'Demo-Rechnung',
  customer_email: demoEmail,
  success_url: origin + '/r#' + token,
  cancel_url: origin + '/',
  // Stripe requires at least 30 minutes.
  expires_at: String(Math.floor(Date.now() / 1000) + 31 * 60),
  'metadata[demo]': 'true',
  // Adaptive Pricing converts the currency and made the amount check fail (checkout_amount_mismatch on the laptop sandbox).
  'adaptive_pricing[enabled]': 'false',
};
const form = Object.entries(fields).map(([k, v]) => encodeURIComponent(k) + '=' + encodeURIComponent(v)).join('&');
return [{ json: { token_hash: tokenHash, demo_email: demoEmail, daily_limit: limit, form } }];`,
    },
    position: [640, 400],
  },
  output: [{ token_hash: 'ab', demo_email: 'demo-0a1b2c3d@demo.mahmud-alhussen.de', daily_limit: 50, form: 'mode=payment' }],
});

// Zero rows (cap reached) still emits one {"success":true} item (CLAUDE.md gotcha), so the next node checks demo_email.
const reserveSlot = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.8,
  config: {
    name: 'Reserve Slot',
    parameters: {
      resource: 'database',
      operation: 'executeQuery',
      query:
        "INSERT INTO demo_sessions (token_hash, demo_email) SELECT decode($1, 'hex'), $2 WHERE (SELECT count(*) FROM demo_sessions WHERE created_at >= (date_trunc('day', now() AT TIME ZONE 'Europe/Berlin') AT TIME ZONE 'Europe/Berlin')) < $3::int RETURNING demo_email;",
      options: { queryReplacement: expr('{{ [$json.token_hash, $json.demo_email, $json.daily_limit] }}') },
    },
    credentials: { postgres: { id: 'XVNN7sIThniqsuOf', name: 'Postgres automation' } },
    position: [860, 400],
  },
  output: [{ demo_email: 'demo-0a1b2c3d@demo.mahmud-alhussen.de' }],
});

const slotReserved = ifElse({
  version: 2.4,
  config: {
    name: 'Slot Reserved?',
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 },
        conditions: [{ leftValue: expr('{{ $json.demo_email }}'), rightValue: '', operator: { type: 'string', operation: 'exists', singleValue: true } }],
        combinator: 'and',
      },
    },
    position: [1080, 400],
  },
});

// 10 s timeout, 2 tries 1 s apart. Safe to repeat: the Idempotency-Key makes Stripe return the first session for the same key.
const createSession = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.5,
  config: {
    name: 'Create Checkout Session',
    parameters: {
      method: 'POST',
      url: 'https://api.stripe.com/v1/checkout/sessions',
      authentication: 'predefinedCredentialType',
      nodeCredentialType: 'stripeApi',
      sendHeaders: true,
      headerParameters: {
        parameters: [
          { name: 'Stripe-Version', value: '2025-03-31.basil' },
          { name: 'Idempotency-Key', value: expr("{{ 'demo-' + $('Prepare Session').item.json.token_hash }}") },
        ],
      },
      sendBody: true,
      contentType: 'raw',
      rawContentType: 'application/x-www-form-urlencoded',
      body: expr("{{ $('Prepare Session').item.json.form }}"),
      options: { timeout: 10000 },
    },
    credentials: { stripeApi: { id: 'kN7IKRSGZFcV7k9O', name: 'Stripe demo checkout' } },
    retryOnFail: true,
    maxTries: 2,
    waitBetweenTries: 1000,
    onError: 'continueErrorOutput',
    position: [1300, 300],
  },
  output: [{ id: 'cs_test_a1', url: 'https://checkout.stripe.com/c/pay/cs_test_a1' }],
});

const checkSession = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Check Session',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: `const s = $input.first().json;
const id = typeof s.id === 'string' ? s.id : '';
const url = typeof s.url === 'string' ? s.url : '';
// Sandbox only: a live-mode session id is refused here and by the CHECK on demo_sessions.checkout_session_id.
const ok = /^cs_test_[A-Za-z0-9]+$/.test(id) && url.startsWith('https://checkout.stripe.com/');
return [{ json: { ok, session_id: ok ? id : '', url: ok ? url : '' } }];`,
    },
    position: [1520, 300],
  },
  output: [{ ok: true, session_id: 'cs_test_a1', url: 'https://checkout.stripe.com/c/pay/cs_test_a1' }],
});

const sessionOk = ifElse({
  version: 2.4,
  config: {
    name: 'Session OK?',
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 },
        conditions: [{ leftValue: expr('{{ $json.ok }}'), rightValue: '', operator: { type: 'boolean', operation: 'true', singleValue: true } }],
        combinator: 'and',
      },
    },
    position: [1740, 300],
  },
});

const storeSessionId = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.8,
  config: {
    name: 'Store Session Id',
    parameters: {
      resource: 'database',
      operation: 'executeQuery',
      query: "UPDATE demo_sessions SET checkout_session_id = $1 WHERE token_hash = decode($2, 'hex') AND checkout_session_id IS NULL RETURNING checkout_session_id;",
      options: { queryReplacement: expr("{{ [$json.session_id, $('Prepare Session').item.json.token_hash] }}") },
    },
    credentials: { postgres: { id: 'XVNN7sIThniqsuOf', name: 'Postgres automation' } },
    onError: 'continueErrorOutput',
    position: [1960, 220],
  },
  output: [{ checkout_session_id: 'cs_test_a1' }],
});

const respondUrl = node({
  type: 'n8n-nodes-base.respondToWebhook',
  version: 1.5,
  config: {
    name: 'Respond 200 Checkout URL',
    parameters: {
      respondWith: 'json',
      responseBody: expr("{{ JSON.stringify({ url: $('Check Session').item.json.url }) }}"),
      options: { responseCode: 200 },
    },
    position: [2180, 140],
  },
  output: [{}],
});

// Stripe unreachable or refused, an unexpected answer, or the row update failed: the visitor gets a plain retry message. The reserved
// row stays and counts against the daily cap (fail-safe direction); the reset removes it.
const respondUnavailable = node({
  type: 'n8n-nodes-base.respondToWebhook',
  version: 1.5,
  config: {
    name: 'Respond 502 Unavailable',
    parameters: { respondWith: 'json', responseBody: '{"error": "checkout_unavailable"}', options: { responseCode: 502 } },
    position: [2180, 400],
  },
  output: [{}],
});

const respondDailyLimit = node({
  type: 'n8n-nodes-base.respondToWebhook',
  version: 1.5,
  config: {
    name: 'Respond 429 Daily Limit',
    parameters: { respondWith: 'json', responseBody: '{"error": "daily_limit"}', options: { responseCode: 429 } },
    position: [1300, 560],
  },
  output: [{}],
});

// One owner alert per Berlin day: only the request whose insert returns a row sends it. The row is written before the send, so an
// undeliverable alert is not retried that day (accepted; the cap itself still works).
const recordCapAlert = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.8,
  config: {
    name: 'Record Cap Alert',
    parameters: {
      resource: 'database',
      operation: 'executeQuery',
      query: "INSERT INTO demo_limit_alerts (day) VALUES ((now() AT TIME ZONE 'Europe/Berlin')::date) ON CONFLICT (day) DO NOTHING RETURNING day::text AS day;",
    },
    credentials: { postgres: { id: 'XVNN7sIThniqsuOf', name: 'Postgres automation' } },
    onError: 'continueRegularOutput',
    position: [1520, 560],
  },
  output: [{ day: '2026-11-13' }],
});

const firstCapToday = ifElse({
  version: 2.4,
  config: {
    name: 'First Cap Today?',
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 },
        conditions: [{ leftValue: expr('{{ $json.day }}'), rightValue: '', operator: { type: 'string', operation: 'exists', singleValue: true } }],
        combinator: 'and',
      },
    },
    position: [1740, 560],
  },
});

const capAlertInput = node({
  type: 'n8n-nodes-base.set',
  version: 3.4,
  config: {
    name: 'Cap Alert Input',
    parameters: {
      mode: 'manual',
      assignments: {
        assignments: [
          { id: '9d1e2f30-0001-4b00-9000-000000000001', name: 'subject', value: 'Demo: daily cap reached', type: 'string' },
          {
            id: '9d1e2f30-0002-4b00-9000-000000000002',
            name: 'body',
            value: expr(
              "{{ 'The visitor demo reached its daily cap of ' + $('Prepare Session').item.json.daily_limit + ' checkout sessions on ' + $json.day + ' (Berlin). Further visitors get 429 until midnight. Kill switch: Cloudflare WAF rule m7-demo-closed.' }}",
            ),
            type: 'string',
          },
        ],
      },
      includeOtherFields: false,
      options: {},
    },
    position: [1960, 560],
  },
  output: [{ subject: 'Demo: daily cap reached', body: 'details' }],
});

const sendCapAlert = node({
  type: 'n8n-nodes-base.executeWorkflow',
  version: 1.4,
  config: {
    name: 'Send Cap Alert',
    parameters: {
      source: 'database',
      workflowId: { __rl: true, mode: 'id', value: 'WO2ebvkZGK5NxzVo' },
      mode: 'once',
      options: { waitForSubWorkflow: true },
    },
    onError: 'continueRegularOutput',
    position: [2180, 560],
  },
  output: [{}],
});

export default workflow('demo-checkout', 'Demo Checkout')
  .add(demoCheckoutWebhook)
  .to(loadConfig)
  .to(prepareSession)
  .to(reserveSlot)
  .to(
    slotReserved
      .onTrue(
        createSession
          .onError(respondUnavailable)
          .to(checkSession.to(sessionOk.onTrue(storeSessionId.onError(respondUnavailable).to(respondUrl)).onFalse(respondUnavailable))),
      )
      .onFalse(respondDailyLimit.to(recordCapAlert.to(firstCapToday.onTrue(capAlertInput.to(sendCapAlert))))),
  );
