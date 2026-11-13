import { workflow, node, trigger, ifElse, sticky, expr } from '@n8n/workflow-sdk';

// Settings that the SDK file does not express (set via update_workflow): settings.errorWorkflow = c2NT8k3JGpuS3r6I (Stripe Error Handler).
// Depends on: workflow Stripe Render Invoice (id 3dvdSRSD6ObBVsxy, called by id below: if it is recreated, update the id here),
// credential "Stripe read-only" (read-only Stripe test key, id qtmzPq7nRsOF9MAW), workflow Stripe Send Telegram (id Yel7C2ufq8wR5s3W, called by id: update it here if recreated)
// and the data table stripe_config, columns invoice_email_from (sender of the invoice email) and telegram_send_pdf (true/false: also send
// the invoice PDF to Telegram; no default). Workflows cannot read the environment (N8N_BLOCK_ENV_ACCESS_IN_NODE=true).

const everyMinute = trigger({
  type: 'n8n-nodes-base.scheduleTrigger',
  version: 1.4,
  config: {
    name: 'Every Minute',
    parameters: { rule: { interval: [{ field: 'minutes', minutesInterval: 1 }] } },
    position: [200, 400],
  },
  output: [{}],
});

// M7c: Stripe Intake starts a run right after it stored a new pending event (no waiting, its input is ignored), so a demo visitor
// does not wait for the next minute. Both triggers feed the same two branches; overlapping runs are safe (FOR UPDATE SKIP LOCKED).
const startedByIntake = trigger({
  type: 'n8n-nodes-base.executeWorkflowTrigger',
  version: 1.3,
  config: {
    name: 'Started by Intake',
    parameters: { inputSource: 'passthrough' },
    position: [200, 560],
  },
  output: [{}],
});

// Configuration: a second branch off the trigger, placed ABOVE the event chain (y 310 < 400) so n8n runs it first; the chain then
// reads $('Config').first(). The data table node replaces items with table rows, which is why it is not inline.
// Load Config absorbs its own error (continueRegularOutput) so Config can turn a missing table into a clear config_problem.
// The table is referenced by id, not by name: n8n's name mode matches LIKE '%name%' and takes the first hit, so a table called
// stripe_config_renamed or stripe_config_backup could be read instead (seen in M7b-3). Ids differ per n8n instance, like credential
// ids; scripts\check-n8n-env.ps1 checks that every referenced id exists and carries the expected name.
const loadConfig = node({
  type: 'n8n-nodes-base.dataTable',
  version: 1.1,
  config: {
    name: 'Load Config',
    parameters: {
      resource: 'row',
      operation: 'get',
      dataTableId: { __rl: true, mode: 'id', value: '7NM52PSapza2TNWP' },
      returnAll: true,
    },
    alwaysOutputData: true,
    executeOnce: true,
    onError: 'continueRegularOutput',
    position: [420, 310],
  },
  output: [{ id: 1, invoice_email_from: 'Musterwerk <rechnung@musterwerk.example>', telegram_send_pdf: 'true' }],
});

// Exactly one row, no defaults: anything else becomes config_problem, and every claimed event then fails with it as last_error.
const configNode = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Config',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: `const KEYS = ['invoice_email_from', 'telegram_send_pdf'];
const items = $input.all();
const failure = items.find((i) => i.json && i.json.error);
const rows = items.map((i) => i.json).filter((r) => r && r.id !== undefined && !r.error);
const row = rows.length === 1 ? rows[0] : {};
const out = {};
for (const k of KEYS) out[k] = row[k] == null ? '' : String(row[k]).trim();
let config_problem = '';
if (failure) config_problem = 'data table stripe_config could not be read: ' + String(failure.json.error.message || failure.json.error).slice(0, 150);
else if (rows.length !== 1) config_problem = 'data table stripe_config must have exactly one row, found ' + rows.length;
else {
  const empty = KEYS.filter((k) => !out[k]);
  if (empty.length) config_problem = 'data table stripe_config: ' + empty.join(', ') + ' is empty';
}
return [{ json: { ...out, config_problem } }];`,
    },
    position: [640, 310],
  },
  output: [{ invoice_email_from: 'Musterwerk <rechnung@musterwerk.example>', telegram_send_pdf: 'true', config_problem: '' }],
});

const releaseStuck = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.8,
  config: {
    name: 'Release Stuck Events',
    parameters: {
      resource: 'database',
      operation: 'executeQuery',
      query:
        "UPDATE stripe_events SET status = CASE WHEN attempts < 5 THEN 'pending' ELSE 'failed' END, pending_since = CASE WHEN attempts < 5 THEN now() ELSE pending_since END, last_error = 'Released: stuck in processing for over 10 minutes' WHERE status = 'processing' AND claimed_at < now() - interval '10 minutes';",
    },
    credentials: { postgres: { id: 'XVNN7sIThniqsuOf', name: 'Postgres automation' } },
    position: [420, 400],
  },
  output: [{ success: true }],
});

const claimEvents = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.8,
  config: {
    name: 'Claim Events',
    parameters: {
      resource: 'database',
      operation: 'executeQuery',
      query:
        "WITH picked AS (SELECT event_id FROM stripe_events WHERE status = 'pending' OR (status = 'failed' AND attempts < 5) ORDER BY received_at LIMIT 10 FOR UPDATE SKIP LOCKED) UPDATE stripe_events e SET status = 'processing', attempts = e.attempts + 1, claimed_at = now(), alerted_at = NULL FROM picked WHERE e.event_id = picked.event_id RETURNING e.event_id, e.attempts, e.payload, EXISTS (SELECT 1 FROM side_effects s WHERE s.event_id = e.event_id AND s.kind = 'email') AS email_done, EXISTS (SELECT 1 FROM side_effects s WHERE s.event_id = e.event_id AND s.kind = 'telegram') AS telegram_done, EXISTS (SELECT 1 FROM side_effects s WHERE s.event_id = e.event_id AND s.kind = 'telegram_document') AS telegram_document_done;",
    },
    credentials: { postgres: { id: 'XVNN7sIThniqsuOf', name: 'Postgres automation' } },
    position: [640, 400],
  },
  output: [{ event_id: 'evt_1', attempts: 1, payload: {}, email_done: false, telegram_done: false }],
});

const prepareEvent = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Prepare Event',
    parameters: {
      mode: 'runOnceForEachItem',
      language: 'javaScript',
      jsCode: `const row = $json;
let payload = row.payload;
if (typeof payload === 'string') {
  try { payload = JSON.parse(payload); } catch (e) { payload = {}; }
}
const obj = (payload && payload.data && payload.data.object) || {};
const details = obj.customer_details || {};

const email = typeof details.email === 'string' ? details.email.trim() : '';
const name = typeof details.name === 'string' ? details.name.trim() : '';
const sessionId = typeof obj.id === 'string' ? obj.id : '';
const currency = typeof obj.currency === 'string' ? obj.currency.toLowerCase() : '';
const amount = obj.amount_total;
// Whether the invoice PDF also goes to Telegram. No default: it must be set on purpose (it passes customer data to a third party).
const cfg = $('Config').first().json;
const sendPdfRaw = String(cfg.telegram_send_pdf || '').toLowerCase();
// M7c: no Telegram at all for a visitor demo payment (owner decision 2026-11-13, option C): its session carries metadata.demo = "true"
// (set only by the Demo Checkout workflow). Treated as already sent, so every path goes on to Mark Done without a send.
const isDemo = !!(obj.metadata && obj.metadata.demo === 'true');

let problem = '';
if (cfg.config_problem) problem = cfg.config_problem;
else if (sendPdfRaw !== 'true' && sendPdfRaw !== 'false') problem = 'telegram_send_pdf in data table stripe_config must be true or false';
else if (!email) problem = 'customer_details.email is missing in the event payload';
else if (!/^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$/.test(email)) problem = 'customer_details.email is not a valid address';
else if (!name) problem = 'customer_details.name is missing in the event payload';
else if (!/^cs_(test|live)_[A-Za-z0-9_]+$/.test(sessionId)) problem = 'checkout session id is missing or invalid in the event payload';
else if (!Number.isInteger(amount) || amount < 0) problem = 'amount_total is missing or invalid in the event payload';
else if (!/^[a-z]{3}$/.test(currency)) problem = 'currency is missing or invalid in the event payload';

const zeroDecimal = ['bif', 'clp', 'djf', 'gnf', 'jpy', 'kmf', 'krw', 'mga', 'pyg', 'rwf', 'ugx', 'vnd', 'vuv', 'xaf', 'xof', 'xpf'];
const threeDecimal = ['bhd', 'iqd', 'jod', 'kwd', 'lyd', 'omr', 'tnd'];
const digits = zeroDecimal.includes(currency) ? 0 : threeDecimal.includes(currency) ? 3 : 2;

let display = '';
if (!problem) {
  const major = amount / Math.pow(10, digits);
  try {
    display = new Intl.NumberFormat('de-DE', {
      style: 'currency',
      currency: currency.toUpperCase(),
      minimumFractionDigits: digits,
      maximumFractionDigits: digits,
    }).format(major);
  } catch (e) {
    display = major.toFixed(digits) + ' ' + currency.toUpperCase();
  }
}

return {
  json: {
    event_id: row.event_id,
    attempts: row.attempts,
    email_done: row.email_done,
    telegram_done: isDemo || row.telegram_done,
    telegram_document_done: row.telegram_document_done,
    send_pdf: !isDemo && sendPdfRaw === 'true',
    is_demo: isDemo,
    problem,
    customer_email: email,
    customer_name: name,
    session_id: sessionId,
    amount_minor: Number.isInteger(amount) ? amount : null,
    currency,
    amount_display: display,
  },
};`,
    },
    position: [860, 400],
  },
  output: [{ event_id: 'evt_1', attempts: 1, email_done: false, telegram_done: false, telegram_document_done: false, send_pdf: true, problem: '', customer_email: 'a@b.co', customer_name: 'Erika Mustermann', session_id: 'cs_test_a1', amount_minor: 3000, currency: 'eur', amount_display: '30,00 €' }],
});

const claimedEvent = ifElse({
  version: 2.4,
  config: {
    name: 'Claimed Event?',
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
    position: [750, 400],
  },
});

const eventValid = ifElse({
  version: 2.4,
  config: {
    name: 'Event Valid?',
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 },
        conditions: [
          {
            leftValue: expr('{{ $json.problem }}'),
            rightValue: '',
            operator: { type: 'string', operation: 'empty', singleValue: true },
          },
        ],
        combinator: 'and',
      },
    },
    position: [1080, 400],
  },
});

const createInvoice = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.8,
  config: {
    name: 'Create Invoice',
    parameters: {
      resource: 'database',
      operation: 'executeQuery',
      query:
        'WITH ins AS (INSERT INTO invoices (event_id, customer_email, amount_cents, currency, customer_name, payment_method, line_items) SELECT $1::text, $2::text, $3::bigint, $4::text, $5::text, $6::text, $7::jsonb WHERE NOT EXISTS (SELECT 1 FROM invoices WHERE event_id = $1::text) ON CONFLICT (event_id) DO NOTHING RETURNING invoice_number) SELECT invoice_number FROM ins UNION ALL SELECT invoice_number FROM invoices WHERE event_id = $1::text LIMIT 1;',
      options: {
        queryReplacement: expr(
          '{{ [$json.event_id, $json.customer_email, $json.amount_minor, $json.currency, $json.customer_name, $json.payment_method, $json.line_items_json] }}',
        ),
        queryBatching: 'independently',
      },
    },
    credentials: { postgres: { id: 'XVNN7sIThniqsuOf', name: 'Postgres automation' } },
    onError: 'continueErrorOutput',
    position: [3520, -380],
  },
  output: [{ invoice_number: 'INV-2026-000001' }],
});

const emailAlreadySent = ifElse({
  version: 2.4,
  config: {
    name: 'Email Already Sent?',
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 },
        conditions: [
          {
            leftValue: expr("{{ $('Prepare Event').item.json.email_done }}"),
            rightValue: '',
            operator: { type: 'boolean', operation: 'true', singleValue: true },
          },
        ],
        combinator: 'and',
      },
    },
    position: [1520, 300],
  },
});

const sendEmail = node({
  type: 'n8n-nodes-base.emailSend',
  version: 2.1,
  config: {
    name: 'Send Invoice Email',
    parameters: {
      operation: 'send',
      fromEmail: expr("{{ $('Config').first().json.invoice_email_from }}"),
      toEmail: expr("{{ $('Prepare Event').item.json.customer_email }}"),
      subject: expr("{{ $('Render Invoice').item.json.subject }}"),
      emailFormat: 'both',
      text: expr("{{ $('Render Invoice').item.json.text }}"),
      html: expr("{{ $('Render Invoice').item.json.html }}"),
      options: { appendAttribution: false, fileAttachments: 'invoice_pdf' },
    },
    credentials: { smtp: { id: 'nxXABuEVvevioUzb', name: 'Mailpit SMTP' } },
    onError: 'continueErrorOutput',
    position: [1740, 400],
  },
  output: [{ accepted: ['a@b.co'] }],
});

const recordEmail = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.8,
  config: {
    name: 'Record Email Sent',
    parameters: {
      resource: 'database',
      operation: 'executeQuery',
      query: "INSERT INTO side_effects (event_id, kind) VALUES ($1, 'email') ON CONFLICT (event_id, kind) DO NOTHING;",
      options: { queryReplacement: expr("{{ [$('Prepare Event').item.json.event_id] }}"), queryBatching: 'independently' },
    },
    credentials: { postgres: { id: 'XVNN7sIThniqsuOf', name: 'Postgres automation' } },
    onError: 'continueErrorOutput',
    position: [1960, 400],
  },
  output: [{ success: true }],
});

const telegramAlreadySent = ifElse({
  version: 2.4,
  config: {
    name: 'Telegram Already Sent?',
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 },
        conditions: [
          {
            leftValue: expr("{{ $('Prepare Event').item.json.telegram_done }}"),
            rightValue: '',
            operator: { type: 'boolean', operation: 'true', singleValue: true },
          },
        ],
        combinator: 'and',
      },
    },
    position: [2180, 300],
  },
});

const recordTelegram = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.8,
  config: {
    name: 'Record Telegram Sent',
    parameters: {
      resource: 'database',
      operation: 'executeQuery',
      query: "INSERT INTO side_effects (event_id, kind) VALUES ($1, 'telegram') ON CONFLICT (event_id, kind) DO NOTHING;",
      options: { queryReplacement: expr("{{ [$('Prepare Event').item.json.event_id] }}"), queryBatching: 'independently' },
    },
    credentials: { postgres: { id: 'XVNN7sIThniqsuOf', name: 'Postgres automation' } },
    onError: 'continueErrorOutput',
    position: [3080, 304],
  },
  output: [{ success: true }],
});

const markDone = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.8,
  config: {
    name: 'Mark Done',
    parameters: {
      resource: 'database',
      operation: 'executeQuery',
      query:
        "UPDATE stripe_events SET status = 'done', processed_at = now(), last_error = NULL WHERE event_id = $1 AND status = 'processing';",
      options: { queryReplacement: expr("{{ [$('Prepare Event').item.json.event_id] }}"), queryBatching: 'independently' },
    },
    credentials: { postgres: { id: 'XVNN7sIThniqsuOf', name: 'Postgres automation' } },
    position: [4840, 304],
  },
  output: [{ success: true }],
});

const describeFailure = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Describe Failure',
    parameters: {
      mode: 'runOnceForEachItem',
      language: 'javaScript',
      jsCode: `const prep = $('Prepare Event').item.json;
const err = $json.error;
let message = $json.problem;
if (!message) {
  if (typeof err === 'string') message = err;
  else if (err) {
    // n8n often keeps the useful text (the API's own message) in description, not in message
    const parts = [err.message, err.description].filter((x) => typeof x === 'string' && x.trim());
    message = parts.length === 2 && parts[1].includes(parts[0]) ? parts[1] : parts.join(': ');
  }
}
message = message || 'unknown error';
const where = err && err.node && err.node.name ? '[' + err.node.name + '] ' : '';
message = where + String(message);
message = message
  .replace(/bot\\d+:[A-Za-z0-9_-]+/g, 'bot***')
  .replace(/\\d{6,}:[A-Za-z0-9_-]{20,}/g, '***')
  .replace(/whsec_[A-Za-z0-9]+/g, 'whsec_***')
  .replace(/(sk|rk|pk)_(test|live)_[A-Za-z0-9]+/g, '$1_$2_***')
  .replace(/\\s+/g, ' ')
  .trim();
if (message.length > 200) message = message.slice(0, 197) + '...';
return { json: { event_id: prep.event_id, last_error: message } };`,
    },
    position: [2400, 760],
  },
  output: [{ event_id: 'evt_1', last_error: 'example' }],
});

const markFailed = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.8,
  config: {
    name: 'Mark Failed',
    parameters: {
      resource: 'database',
      operation: 'executeQuery',
      query: "UPDATE stripe_events SET status = 'failed', last_error = $2 WHERE event_id = $1 AND status = 'processing';",
      options: { queryReplacement: expr('{{ [$json.event_id, $json.last_error] }}'), queryBatching: 'independently' },
    },
    credentials: { postgres: { id: 'XVNN7sIThniqsuOf', name: 'Postgres automation' } },
    position: [2620, 760],
  },
  output: [{ success: true }],
});

const note = sticky(
  '## Stripe Processor\nEvery minute: release rows stuck in processing for 10+ min, claim up to 10 pending/failed(attempts<5) rows with FOR UPDATE SKIP LOCKED, then per event: invoice data -> render (Stripe Render Invoice) -> email with PDF -> Telegram text -> Telegram PDF document (if TELEGRAM_SEND_PDF=true) -> done. Failures mark only that event failed.\n\n**Invoice data:** if no invoice exists yet, ONE read-only Stripe lookup (3 tries, 2 s then 4 s backoff for 429/5xx/network) gets the product and the payment method actually used; they are stored on the invoice row together with the customer name. Retries and replays render from that row and never call Stripe again. Missing or inconsistent data fails the event, nothing is defaulted.\n\n**Telegram:** both messages go through the Stripe Send Telegram sub-workflow (one retry loop). Side effects: email, telegram (text), telegram_document. If the PDF cannot be produced the email is skipped, the owner text still goes out saying the PDF is missing, and the event ends failed with the real reason; the next run retries and sends only what is still missing.\n\n**Delivery guarantee: at-least-once.** Each send is followed by an INSERT into side_effects. If a run dies between a send and its INSERT, the retry can send that one message twice. Invoice creation is exactly-once (invoices.event_id is UNIQUE). The PDF is only rendered while the email or the document is still to be sent.',
  [],
  { color: 4, position: [200, 40], width: 640, height: 260 },
);

// ---- Invoice data (M-invoice): one read-only Stripe lookup per invoice, only when no invoice row exists yet ----

const findInvoice = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.8,
  config: {
    name: 'Find Invoice',
    parameters: {
      resource: 'database',
      operation: 'executeQuery',
      // Always one row (NULL when there is no invoice yet), so the next IF can tell the two cases apart.
      query: 'SELECT (SELECT invoice_number FROM invoices WHERE event_id = $1::text) AS invoice_number;',
      options: { queryReplacement: expr('{{ [$json.event_id] }}'), queryBatching: 'independently' },
    },
    credentials: { postgres: { id: 'XVNN7sIThniqsuOf', name: 'Postgres automation' } },
    position: [1100, -260],
  },
  output: [{ invoice_number: null }],
});

const invoiceExists = ifElse({
  version: 2.4,
  config: {
    name: 'Invoice Exists?',
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'loose', version: 2 },
        conditions: [
          {
            leftValue: expr('{{ $json.invoice_number }}'),
            rightValue: '',
            operator: { type: 'string', operation: 'notEmpty', singleValue: true },
          },
        ],
        combinator: 'and',
      },
    },
    position: [1320, -260],
  },
});

const fetchSession = (name: string, position: [number, number]) =>
  node({
    type: 'n8n-nodes-base.httpRequest',
    version: 4.5,
    config: {
      name,
      parameters: {
        method: 'GET',
        // The expand[] query is part of the URL on purpose: two query-parameter entries with the same name were serialised by n8n
        // as an object (expand[0]={"0":...}) and Stripe answered 400.
        url: expr(
          "{{ 'https://api.stripe.com/v1/checkout/sessions/' + $('Prepare Event').item.json.session_id + '?expand%5B%5D=line_items&expand%5B%5D=payment_intent.latest_charge' }}",
        ),
        authentication: 'predefinedCredentialType',
        nodeCredentialType: 'stripeApi',
        // Pinned, so the response shape does not follow the account's default version (laptop sandbox: 2026-09-30.endive). Same as the
        // server's webhook destination; all 14 fields read below were identical at endive and basil (docs/evidence.md, M7b-4).
        sendHeaders: true,
        headerParameters: { parameters: [{ name: 'Stripe-Version', value: '2025-03-31.basil' }] },
        options: { timeout: 20000 },
      },
      credentials: { stripeApi: { id: 'qtmzPq7nRsOF9MAW', name: 'Stripe read-only' } },
      onError: 'continueErrorOutput',
      position,
    },
    output: [{ object: 'checkout.session', id: 'cs_test_a1' }],
  });
const fetchSession1 = fetchSession('Fetch Session (try 1)', [1540, -380]);
const fetchSession2 = fetchSession('Fetch Session (try 2)', [2200, -380]);
const fetchSession3 = fetchSession('Fetch Session (try 3)', [2860, -380]);

const retryableText = expr(
  "{{ /too many requests|retry after|internal server error|bad gateway|service unavailable|gateway time-?out|timed? ?out|econn|enotfound|eai_again|socket hang up|\\b(429|5\\d\\d)\\b/i.test(String($json.error?.message ?? $json.error ?? '')) }}",
);
const retryableStripe = (name: string, position: [number, number]) =>
  ifElse({
    version: 2.4,
    config: {
      name,
      parameters: {
        conditions: {
          options: { caseSensitive: true, leftValue: '', typeValidation: 'loose', version: 2 },
          conditions: [{ leftValue: retryableText, rightValue: '', operator: { type: 'boolean', operation: 'true', singleValue: true } }],
          combinator: 'and',
        },
      },
      position,
    },
  });
const retryableS1 = retryableStripe('Retryable? (S1)', [1760, -260]);
const retryableS2 = retryableStripe('Retryable? (S2)', [2420, -260]);

const backoffS1 = node({
  type: 'n8n-nodes-base.wait',
  version: 1.1,
  config: { name: 'Backoff S 2s', parameters: { resume: 'timeInterval', amount: 2, unit: 'seconds' }, position: [1980, -380] },
  output: [{}],
});
const backoffS2 = node({
  type: 'n8n-nodes-base.wait',
  version: 1.1,
  config: { name: 'Backoff S 4s', parameters: { resume: 'timeInterval', amount: 4, unit: 'seconds' }, position: [2640, -380] },
  output: [{}],
});

const validateSession = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Validate Session',
    parameters: {
      mode: 'runOnceForEachItem',
      language: 'javaScript',
      jsCode: `// Turns Stripe's answer into the invoice document data, or a clear problem. Nothing is guessed or defaulted.
const prep = $('Prepare Event').item.json;
const s = $json;
const fail = (problem) => ({ json: { problem: String(problem), event_id: prep.event_id } });

if (!s || s.object !== 'checkout.session') return fail('Stripe lookup did not return a checkout session');
if (s.id !== prep.session_id) return fail('Stripe lookup returned a different checkout session');
if (s.payment_status !== 'paid') return fail('Stripe checkout session is not paid (payment_status=' + s.payment_status + ')');
if (String(s.currency || '').toLowerCase() !== prep.currency) return fail('Stripe session currency differs from the event');
if (s.amount_total !== prep.amount_minor) return fail('Stripe session amount differs from the event');

const li = s.line_items && Array.isArray(s.line_items.data) ? s.line_items.data : null;
if (!li || li.length === 0) return fail('Stripe session has no line items');
if (s.line_items.has_more) return fail('Stripe session has more line items than one page (not supported)');
const items = [];
for (const it of li) {
  const description = typeof it.description === 'string' ? it.description.trim() : '';
  const unit = it.price && Number.isInteger(it.price.unit_amount) ? it.price.unit_amount : null;
  if (!description || !Number.isInteger(it.quantity) || it.quantity < 1 || unit === null || !Number.isInteger(it.amount_total)) {
    return fail('Stripe line item is incomplete (description, quantity, unit amount or amount)');
  }
  items.push({ description, quantity: it.quantity, unit_amount: unit, amount_total: it.amount_total });
}
if (items.reduce((a, i) => a + i.amount_total, 0) !== prep.amount_minor) return fail('Stripe line items do not add up to the event amount');

const pi = s.payment_intent;
const charge = pi && typeof pi === 'object' ? pi.latest_charge : null;
const pmd = charge && typeof charge === 'object' ? charge.payment_method_details : null;
if (!pmd || typeof pmd.type !== 'string' || !pmd.type) return fail('Stripe session has no payment method details on its charge');
const brands = { visa: 'Visa', mastercard: 'Mastercard', amex: 'American Express', discover: 'Discover', diners: 'Diners Club', jcb: 'JCB', unionpay: 'UnionPay', cartes_bancaires: 'Cartes Bancaires', eftpos_au: 'EFTPOS' };
const types = { sepa_debit: 'SEPA-Lastschrift', paypal: 'PayPal', link: 'Link', klarna: 'Klarna', ideal: 'iDEAL', sofort: 'Sofort', giropay: 'giropay', bancontact: 'Bancontact', eps: 'EPS', p24: 'Przelewy24', amazon_pay: 'Amazon Pay', revolut_pay: 'Revolut Pay' };
let method;
if (pmd.type === 'card') {
  const brand = pmd.card && pmd.card.brand;
  if (typeof brand !== 'string' || !brand) return fail('Stripe charge has no card brand');
  method = 'Karte (' + (brands[brand] || brand) + ')';
} else {
  method = types[pmd.type] || pmd.type;
}

return { json: { problem: '', event_id: prep.event_id, customer_email: prep.customer_email, amount_minor: prep.amount_minor, currency: prep.currency, customer_name: prep.customer_name, payment_method: method, line_items_json: JSON.stringify(items) } };`,
    },
    position: [3080, -380],
  },
  output: [{ problem: '', event_id: 'evt_1', customer_email: 'a@b.co', amount_minor: 3000, currency: 'eur', customer_name: 'Erika Mustermann', payment_method: 'Karte (Visa)', line_items_json: '[]' }],
});

const sessionValid = ifElse({
  version: 2.4,
  config: {
    name: 'Session Valid?',
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'loose', version: 2 },
        conditions: [{ leftValue: expr('{{ $json.problem }}'), rightValue: '', operator: { type: 'string', operation: 'empty', singleValue: true } }],
        combinator: 'and',
      },
    },
    position: [3300, -380],
  },
});

// ---- Rendering: the Render Invoice sub-workflow builds subject, HTML, text, Telegram text and the PDF from the invoice row ----

const renderInput = node({
  type: 'n8n-nodes-base.set',
  version: 3.4,
  config: {
    name: 'Render Input',
    parameters: {
      mode: 'manual',
      assignments: {
        assignments: [
          { id: '7c2f1a10-0001-4a00-9000-000000000001', name: 'invoice_number', value: expr('{{ $json.invoice_number }}'), type: 'string' },
          // No PDF (so no Gotenberg call) once the email and, if TELEGRAM_SEND_PDF=true, the Telegram document are both sent: only the text is needed then.
          { id: '7c2f1a10-0002-4a00-9000-000000000002', name: 'include_pdf', value: expr("{{ !$('Prepare Event').item.json.email_done || ($('Prepare Event').item.json.send_pdf && !$('Prepare Event').item.json.telegram_document_done) }}"), type: 'boolean' },
        ],
      },
      includeOtherFields: false,
      options: {},
    },
    position: [3740, -260],
  },
  output: [{ invoice_number: 'INV-2026-000001', include_pdf: true }],
});

const renderInvoice = node({
  type: 'n8n-nodes-base.executeWorkflow',
  version: 1.4,
  config: {
    name: 'Render Invoice',
    parameters: { source: 'database', workflowId: { __rl: true, mode: 'id', value: '3dvdSRSD6ObBVsxy' }, mode: 'each', options: {} },
    onError: 'continueErrorOutput',
    position: [3960, -260],
  },
  output: [{ problem: '', subject: 's', html: 'h', text: 't', telegram_text: 'tg' }],
});

const renderOk = ifElse({
  version: 2.4,
  config: {
    name: 'Render OK?',
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'loose', version: 2 },
        conditions: [{ leftValue: expr("{{ $json.problem === '' }}"), rightValue: '', operator: { type: 'boolean', operation: 'true', singleValue: true } }],
        combinator: 'and',
      },
    },
    position: [4180, -260],
  },
});

const failure = describeFailure.to(markFailed);

// ---- Telegram (M-invoice): the owner text, then the invoice PDF as a document, both through the Stripe Send Telegram sub-workflow ----
// The sub-workflow holds the one retry loop (3 tries, 2 s then 4 s backoff on 429/5xx/network). Here: what is sent, and what is recorded.
// Side effects: 'telegram' (the text) and 'telegram_document' (the PDF, only when TELEGRAM_SEND_PDF=true). The text is also sent when the PDF
// could not be produced (it then says so); the event still ends failed with the real reason, and the next run sends only what is missing.

const canSendText = ifElse({
  version: 2.4,
  config: {
    name: 'Can Send Text?',
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'loose', version: 2 },
        conditions: [
          {
            leftValue: expr("{{ typeof $json.telegram_text === 'string' && $json.telegram_text !== '' }}"),
            rightValue: '',
            operator: { type: 'boolean', operation: 'true', singleValue: true },
          },
        ],
        combinator: 'and',
      },
    },
    position: [4400, -120],
  },
});

const telegramTextInput = node({
  type: 'n8n-nodes-base.set',
  version: 3.4,
  config: {
    name: 'Telegram Text Input',
    parameters: {
      mode: 'manual',
      assignments: {
        assignments: [
          { id: '7c2f1a10-0003-4a00-9000-000000000003', name: 'mode', value: 'text', type: 'string' },
          { id: '7c2f1a10-0004-4a00-9000-000000000004', name: 'text', value: expr("{{ $('Render Invoice').item.json.telegram_text }}"), type: 'string' },
        ],
      },
      includeOtherFields: false,
      options: {},
    },
    position: [2420, 304],
  },
  output: [{ mode: 'text', text: '<b>Zahlung eingegangen</b>' }],
});

const sendTelegramText = node({
  type: 'n8n-nodes-base.executeWorkflow',
  version: 1.4,
  config: {
    name: 'Send Telegram Text',
    parameters: { source: 'database', workflowId: { __rl: true, mode: 'id', value: 'Yel7C2ufq8wR5s3W' }, mode: 'each', options: {} },
    onError: 'continueErrorOutput',
    position: [2640, 304],
  },
  output: [{ ok: true, message_id: 1 }],
});

const okCondition = (name: string, position: [number, number]) =>
  ifElse({
    version: 2.4,
    config: {
      name,
      parameters: {
        conditions: {
          options: { caseSensitive: true, leftValue: '', typeValidation: 'loose', version: 2 },
          conditions: [{ leftValue: expr('{{ $json.ok === true }}'), rightValue: '', operator: { type: 'boolean', operation: 'true', singleValue: true } }],
          combinator: 'and',
        },
      },
      position,
    },
  });
const telegramTextOk = okCondition('Telegram Text OK?', [2860, 304]);

const renderFailed = ifElse({
  version: 2.4,
  config: {
    name: 'Render Failed?',
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'loose', version: 2 },
        conditions: [
          {
            leftValue: expr("{{ $('Render Invoice').item.json.problem !== '' }}"),
            rightValue: '',
            operator: { type: 'boolean', operation: 'true', singleValue: true },
          },
        ],
        combinator: 'and',
      },
    },
    position: [3300, 304],
  },
});

const renderProblem = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Render Problem',
    parameters: {
      mode: 'runOnceForEachItem',
      language: 'javaScript',
      jsCode: `// The PDF could not be produced: the owner text has gone out (or was sent before), now the event must end failed with the real reason.
return { json: { problem: $('Render Invoice').item.json.problem } };`,
    },
    position: [3300, 540],
  },
  output: [{ problem: 'Render PDF (Gotenberg): example' }],
});

const flagCondition = (name: string, field: string, position: [number, number]) =>
  ifElse({
    version: 2.4,
    config: {
      name,
      parameters: {
        conditions: {
          options: { caseSensitive: true, leftValue: '', typeValidation: 'loose', version: 2 },
          conditions: [
            { leftValue: expr("{{ $('Prepare Event').item.json." + field + ' }}'), rightValue: '', operator: { type: 'boolean', operation: 'true', singleValue: true } },
          ],
          combinator: 'and',
        },
      },
      position,
    },
  });
const sendPdf = flagCondition('Send PDF?', 'send_pdf', [3520, 304]);
const documentAlreadySent = flagCondition('Document Already Sent?', 'telegram_document_done', [3740, 304]);

const restorePdf = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Restore PDF',
    parameters: {
      mode: 'runOnceForEachItem',
      language: 'javaScript',
      jsCode: `// The Postgres nodes before this one dropped the PDF from the item: take it from the render result again.
const r = $('Render Invoice').item;
const out = { json: { mode: 'document', caption: r.json.telegram_caption || '' } };
if (r.binary) out.binary = r.binary;
return out;`,
    },
    position: [3960, 304],
  },
  output: [{ mode: 'document', caption: 'Rechnung INV-2026-000001' }],
});

const sendTelegramDocument = node({
  type: 'n8n-nodes-base.executeWorkflow',
  version: 1.4,
  config: {
    name: 'Send Telegram Document',
    parameters: { source: 'database', workflowId: { __rl: true, mode: 'id', value: 'Yel7C2ufq8wR5s3W' }, mode: 'each', options: {} },
    onError: 'continueErrorOutput',
    position: [4180, 304],
  },
  output: [{ ok: true, message_id: 1 }],
});
const telegramDocumentOk = okCondition('Telegram Document OK?', [4400, 304]);

const recordTelegramDocument = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.8,
  config: {
    name: 'Record Telegram Document',
    parameters: {
      resource: 'database',
      operation: 'executeQuery',
      query: "INSERT INTO side_effects (event_id, kind) VALUES ($1, 'telegram_document') ON CONFLICT (event_id, kind) DO NOTHING;",
      options: { queryReplacement: expr("{{ [$('Prepare Event').item.json.event_id] }}"), queryBatching: 'independently' },
    },
    credentials: { postgres: { id: 'XVNN7sIThniqsuOf', name: 'Postgres automation' } },
    onError: 'continueErrorOutput',
    position: [4620, 304],
  },
  output: [{ success: true }],
});

const documentStage = sendPdf
  .onTrue(
    documentAlreadySent
      .onTrue(markDone)
      .onFalse(
        restorePdf.to(
          sendTelegramDocument
            .onError(describeFailure)
            .to(telegramDocumentOk.onTrue(recordTelegramDocument.onError(describeFailure).to(markDone)).onFalse(describeFailure)),
        ),
      ),
  )
  .onFalse(markDone);

// Defined once; reached both when the text was sent before and right after it was sent now.
const renderFailedGate = renderFailed.onTrue(renderProblem.to(describeFailure)).onFalse(documentStage);

const telegramGate = telegramAlreadySent
  .onTrue(renderFailedGate)
  .onFalse(
    telegramTextInput.to(
      sendTelegramText
        .onError(describeFailure)
        .to(telegramTextOk.onTrue(recordTelegram.onError(describeFailure).to(renderFailed)).onFalse(describeFailure)),
    ),
  );

const emailGate = emailAlreadySent
  .onTrue(telegramGate)
  .onFalse(sendEmail.onError(describeFailure).to(recordEmail.onError(describeFailure).to(telegramAlreadySent)));

const renderStage = renderInput.to(
  renderInvoice.onError(describeFailure).to(renderOk.onTrue(emailGate).onFalse(canSendText.onTrue(telegramAlreadySent).onFalse(describeFailure))),
);

// Three tries at the Stripe lookup (2 s, then 4 s backoff, only for 429/5xx/network-looking errors), then validate, store, render.
const sessionLookup = fetchSession1
  .onError(
    retryableS1
      .onTrue(
        backoffS1.to(
          fetchSession2
            .onError(
              retryableS2
                .onTrue(backoffS2.to(fetchSession3.onError(describeFailure).to(validateSession)))
                .onFalse(describeFailure),
            )
            .to(validateSession),
        ),
      )
      .onFalse(describeFailure),
  )
  .to(
    validateSession.to(
      sessionValid.onTrue(createInvoice.onError(describeFailure).to(renderStage)).onFalse(describeFailure),
    ),
  );

export default workflow('stripe-processor', 'Stripe Processor')
  .add(everyMinute)
  .to(loadConfig)
  .to(configNode)
  .add(startedByIntake)
  .to(loadConfig)
  .add(everyMinute)
  .to(releaseStuck)
  .add(startedByIntake)
  .to(releaseStuck)
  .to(claimEvents)
  .to(
    claimedEvent.onTrue(
      prepareEvent.to(
        eventValid
          .onTrue(findInvoice.to(invoiceExists.onTrue(renderInput).onFalse(sessionLookup)))
          .onFalse(failure),
      ),
    ),
  )
  .add(note);
