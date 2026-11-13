import { workflow, node, trigger, ifElse, expr } from '@n8n/workflow-sdk';

// Demo Result (M7c, docs/tasks/m7c-demo.md): POST /webhook/demo-result, reached only through demo-web (Caddy) as POST /api/demo/result.
// Body {"token": "<43 chars>", "part": "status" | "preview" | "pdf"}. The token comes from the result page's URL fragment; only its sha256
// is stored (demo_sessions.token_hash), so a wrong, guessed or reset token gets the same 404.
//   status   the pipeline timeline from Postgres (polled every 2 s by the page; cheap: one SELECT)
//   preview  the invoice email as Mailpit caught it (HTML) and the owner Telegram text that Stripe Render Invoice builds; demo payments
//            send no Telegram (owner decision, option C), so the page labels it as a preview
//   pdf      the PDF attached to that email in Mailpit (the exact file that was "sent"; no Gotenberg render per click)
// Never returns last_error, the event payload or any other visitor's data: every lookup is keyed by this token's session.
// Settings that the SDK file does not express (scripts\lib\workflows.ps1): errorWorkflow = c2NT8k3JGpuS3r6I (Stripe Error Handler),
// on the server no successful executions are saved (visitor name and email pass through here).
// Depends on: credential "Postgres automation" (n8n_app on the server), workflow Stripe Render Invoice (id 3dvdSRSD6ObBVsxy, by id:
// update it here if recreated), Mailpit's API at http://mailpit:8025 (compose network, no credential).

const demoResultWebhook = trigger({
  type: 'n8n-nodes-base.webhook',
  version: 2.2,
  config: {
    name: 'Demo Result Webhook',
    parameters: { httpMethod: 'POST', path: 'demo-result', authentication: 'none', responseMode: 'responseNode', options: {} },
    position: [200, 400],
  },
  output: [{ headers: {}, body: { token: 'x', part: 'status' } }],
});

const checkRequest = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Check Request',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: `const crypto = require('crypto');
const b = ($input.first().json.body) || {};
const token = typeof b.token === 'string' ? b.token : '';
const part = typeof b.part === 'string' ? b.part : '';
const ok = /^[A-Za-z0-9_-]{43}$/.test(token) && ['status', 'preview', 'pdf'].includes(part);
return [{ json: { ok, part, token_hash: ok ? crypto.createHash('sha256').update(token).digest('hex') : '' } }];`,
    },
    position: [420, 400],
  },
  output: [{ ok: true, part: 'status', token_hash: 'ab' }],
});

const requestOk = ifElse({
  version: 2.4,
  config: {
    name: 'Request OK?',
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 },
        conditions: [{ leftValue: expr('{{ $json.ok }}'), rightValue: '', operator: { type: 'boolean', operation: 'true', singleValue: true } }],
        combinator: 'and',
      },
    },
    position: [640, 400],
  },
});

// The session, its checkout.session.completed event (matched by the session id in the payload), invoice and email side effect.
// alwaysOutputData: an unknown token gives one empty item, which Build Status turns into found=false (then 404).
const loadSession = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.8,
  config: {
    name: 'Load Session',
    parameters: {
      resource: 'database',
      operation: 'executeQuery',
      query:
        "SELECT s.created_at AS session_created_at, e.event_id, e.status, e.attempts, e.received_at, e.claimed_at, e.processed_at, i.invoice_number, i.amount_cents, i.currency, i.created_at AS invoice_created_at, (SELECT done_at FROM side_effects se WHERE se.event_id = e.event_id AND se.kind = 'email') AS email_at, e.payload->'data'->'object'->'customer_details'->>'email' AS recipient FROM demo_sessions s LEFT JOIN LATERAL (SELECT * FROM stripe_events ev WHERE ev.event_type = 'checkout.session.completed' AND ev.payload->'data'->'object'->>'id' = s.checkout_session_id ORDER BY ev.received_at LIMIT 1) e ON true LEFT JOIN invoices i ON i.event_id = e.event_id WHERE s.token_hash = decode($1, 'hex');",
      options: { queryReplacement: expr('{{ [$json.token_hash] }}') },
    },
    credentials: { postgres: { id: 'XVNN7sIThniqsuOf', name: 'Postgres automation' } },
    alwaysOutputData: true,
    position: [860, 300],
  },
  output: [{ session_created_at: '2026-11-13T10:00:00.000Z', event_id: 'evt_1', status: 'done', invoice_number: 'INV-2026-000001' }],
});

const buildStatus = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Build Status',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: `const r = $input.first().json || {};
const part = $('Check Request').first().json.part;
const found = !!r.session_created_at;
const iso = (v) => (v ? new Date(v).toISOString() : null);
let state = 'waiting_payment';
if (r.event_id) {
  if (r.status === 'done') state = 'done';
  else if (r.status === 'failed') state = Number(r.attempts) >= 5 ? 'failed' : 'retrying';
  else state = 'processing';
}
let amount = '';
if (r.invoice_number && Number.isInteger(Number(r.amount_cents)) && /^[a-z]{3}$/.test(String(r.currency || ''))) {
  amount = new Intl.NumberFormat('de-DE', { style: 'currency', currency: String(r.currency).toUpperCase() }).format(Number(r.amount_cents) / 100);
}
const steps = [
  { key: 'checkout', at: iso(r.session_created_at) },
  { key: 'webhook', at: iso(r.received_at) },
  { key: 'processing', at: iso(r.claimed_at) },
  { key: 'invoice', at: iso(r.invoice_created_at), detail: r.invoice_number || null },
  { key: 'email', at: iso(r.email_at) },
  { key: 'done', at: r.status === 'done' ? iso(r.processed_at) : null },
];
return [{
  json: {
    found,
    part,
    ready: !!(r.invoice_number && r.email_at && r.recipient),
    status: found ? { state, steps, invoice_number: r.invoice_number || null, amount } : null,
    invoice_number: r.invoice_number || '',
    recipient: r.recipient || '',
  },
}];`,
    },
    position: [1080, 300],
  },
  output: [{ found: true, part: 'status', ready: true, status: { state: 'done' }, invoice_number: 'INV-2026-000001', recipient: 'demo-0a1b2c3d@demo.mahmud-alhussen.de' }],
});

const flag = (name: string, test: string, position: [number, number]) =>
  ifElse({
    version: 2.4,
    config: {
      name,
      parameters: {
        conditions: {
          options: { caseSensitive: true, leftValue: '', typeValidation: 'loose', version: 2 },
          conditions: [{ leftValue: expr('{{ ' + test + ' }}'), rightValue: '', operator: { type: 'boolean', operation: 'true', singleValue: true } }],
          combinator: 'and',
        },
      },
      position,
    },
  });
const sessionFound = flag('Session Found?', '$json.found === true', [1300, 300]);
const wantsStatus = flag('Wants Status?', "$json.part === 'status'", [1520, 220]);
const invoiceReady = flag('Invoice Ready?', '$json.ready === true', [1740, 300]);
const wantsPdf = flag('Wants PDF?', "$json.part === 'pdf'", [1960, 220]);

const respond = (name: string, code: number, body: string, position: [number, number]) =>
  node({
    type: 'n8n-nodes-base.respondToWebhook',
    version: 1.5,
    config: {
      name,
      parameters: { respondWith: 'json', responseBody: body, options: { responseCode: code, responseHeaders: { entries: [{ name: 'Cache-Control', value: 'no-store' }] } } },
      position,
    },
    output: [{}],
  });
const respondNotFound = respond('Respond 404 Not Found', 404, '{"error": "not_found"}', [1520, 520]);
const respondStatus = respond('Respond 200 Status', 200, expr('{{ JSON.stringify($json.status) }}'), [1740, 140]);
const respondNotReady = respond('Respond 409 Not Ready', 409, '{"error": "not_ready"}', [1960, 440]);
const respondPreview = respond('Respond 200 Preview', 200, expr('{{ JSON.stringify($json) }}'), [2620, 300]);
const respondUnavailable = respond('Respond 502 Unavailable', 502, '{"error": "preview_unavailable"}', [2620, 520]);

// Mailpit: the message with this invoice's subject sent to this session's recipient. 5 s timeout, 2 tries per call.
const mailpitHelpers = `const base = 'http://mailpit:8025/api/v1';
const get = async (url, extra = {}) => {
  let last;
  for (let i = 0; i < 2; i++) {
    try { return await this.helpers.httpRequest({ method: 'GET', url, timeout: 5000, ...extra }); } catch (e) { last = e; }
  }
  throw last;
};
const findMessage = async (invoiceNumber, recipient) => {
  const query = 'subject:"Ihre Rechnung ' + invoiceNumber + '" to:"' + recipient + '"';
  const found = await get(base + '/search?limit=5&query=' + encodeURIComponent(query), { json: true });
  const id = found && Array.isArray(found.messages) && found.messages[0] && found.messages[0].ID;
  if (!id) throw new Error('invoice email not found in Mailpit');
  return await get(base + '/message/' + encodeURIComponent(id), { json: true });
};`;

const fetchPdf = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Fetch PDF from Mailpit',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode:
        mailpitHelpers +
        `
const r = $input.first().json;
const msg = await findMessage(r.invoice_number, r.recipient);
const att = (msg.Attachments || []).find((a) => a.ContentType === 'application/pdf');
if (!att) throw new Error('the invoice email in Mailpit has no PDF attachment');
const raw = await get(base + '/message/' + encodeURIComponent(msg.ID) + '/part/' + encodeURIComponent(att.PartID), { encoding: 'arraybuffer', json: false });
const buf = Buffer.from(raw);
if (buf.length < 1000 || buf.slice(0, 5).toString('latin1') !== '%PDF-') throw new Error('the Mailpit attachment is not a PDF');
const binary = await this.helpers.prepareBinaryData(buf, 'Rechnung-' + r.invoice_number + '.pdf', 'application/pdf');
return [{ json: { invoice_number: r.invoice_number }, binary: { data: binary } }];`,
    },
    onError: 'continueErrorOutput',
    position: [2180, 140],
  },
  output: [{ invoice_number: 'INV-2026-000001' }],
});

const respondPdf = node({
  type: 'n8n-nodes-base.respondToWebhook',
  version: 1.5,
  config: {
    name: 'Respond 200 PDF',
    parameters: {
      respondWith: 'binary',
      options: {
        responseCode: 200,
        responseHeaders: {
          entries: [
            { name: 'Content-Disposition', value: expr("{{ 'attachment; filename=\"Rechnung-' + $json.invoice_number + '.pdf\"' }}") },
            { name: 'Cache-Control', value: 'no-store' },
          ],
        },
      },
    },
    position: [2400, 140],
  },
  output: [{}],
});

const renderInput = node({
  type: 'n8n-nodes-base.set',
  version: 3.4,
  config: {
    name: 'Render Input',
    parameters: {
      mode: 'manual',
      assignments: {
        assignments: [
          { id: '9d1e2f30-0011-4b00-9000-000000000011', name: 'invoice_number', value: expr('{{ $json.invoice_number }}'), type: 'string' },
          { id: '9d1e2f30-0012-4b00-9000-000000000012', name: 'include_pdf', value: false, type: 'boolean' },
        ],
      },
      includeOtherFields: false,
      options: {},
    },
    position: [2180, 300],
  },
  output: [{ invoice_number: 'INV-2026-000001', include_pdf: false }],
});

// The renderer is the only place that builds the owner text; it reads the invoice row and calls nothing outside (no PDF here).
const renderInvoice = node({
  type: 'n8n-nodes-base.executeWorkflow',
  version: 1.4,
  config: {
    name: 'Render Invoice',
    parameters: { source: 'database', workflowId: { __rl: true, mode: 'id', value: '3dvdSRSD6ObBVsxy' }, mode: 'each', options: {} },
    onError: 'continueErrorOutput',
    position: [2400, 300],
  },
  output: [{ problem: '', telegram_text: '<b>Zahlung eingegangen</b>' }],
});

const buildPreview = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Build Preview',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode:
        mailpitHelpers +
        `
const r = $('Build Status').first().json;
const rendered = $input.first().json || {};
const msg = await findMessage(r.invoice_number, r.recipient);
// Telegram HTML parse mode -> plain text; the page sets it with textContent, never as HTML.
const telegram = String(rendered.telegram_text || '')
  .replace(/<[^>]+>/g, '')
  .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, '&');
// The email HTML goes into <iframe sandbox srcdoc> on the page: no scripts, no same origin.
return [{ json: { subject: String(msg.Subject || ''), to: r.recipient, email_html: String(msg.HTML || ''), telegram_text: telegram } }];`,
    },
    onError: 'continueErrorOutput',
    position: [2400, 460],
  },
  output: [{ subject: 'Ihre Rechnung INV-2026-000001', to: 'demo-0a1b2c3d@demo.mahmud-alhussen.de', email_html: '<p>h</p>', telegram_text: 'Zahlung eingegangen' }],
});

export default workflow('demo-result', 'Demo Result')
  .add(demoResultWebhook)
  .to(checkRequest)
  .to(
    requestOk
      .onTrue(
        loadSession.to(
          buildStatus.to(
            sessionFound
              .onTrue(
                wantsStatus
                  .onTrue(respondStatus)
                  .onFalse(
                    invoiceReady
                      .onTrue(
                        wantsPdf
                          .onTrue(fetchPdf.onError(respondUnavailable).to(respondPdf))
                          .onFalse(renderInput.to(renderInvoice.onError(respondUnavailable).to(buildPreview.onError(respondUnavailable).to(respondPreview)))),
                      )
                      .onFalse(respondNotReady),
                  ),
              )
              .onFalse(respondNotFound),
          ),
        ),
      )
      .onFalse(respondNotFound),
  );
