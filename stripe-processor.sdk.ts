import { workflow, node, trigger, ifElse, sticky, expr } from '@n8n/workflow-sdk';

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

const releaseStuck = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.8,
  config: {
    name: 'Release Stuck Events',
    parameters: {
      resource: 'database',
      operation: 'executeQuery',
      query:
        "UPDATE stripe_events SET status = CASE WHEN attempts < 5 THEN 'pending' ELSE 'failed' END, last_error = 'Released: stuck in processing for over 10 minutes' WHERE status = 'processing' AND claimed_at < now() - interval '10 minutes';",
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
        "WITH picked AS (SELECT event_id FROM stripe_events WHERE status = 'pending' OR (status = 'failed' AND attempts < 5) ORDER BY received_at LIMIT 10 FOR UPDATE SKIP LOCKED) UPDATE stripe_events e SET status = 'processing', attempts = e.attempts + 1, claimed_at = now() FROM picked WHERE e.event_id = picked.event_id RETURNING e.event_id, e.attempts, e.payload, EXISTS (SELECT 1 FROM side_effects s WHERE s.event_id = e.event_id AND s.kind = 'email') AS email_done, EXISTS (SELECT 1 FROM side_effects s WHERE s.event_id = e.event_id AND s.kind = 'telegram') AS telegram_done;",
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
const currency = typeof obj.currency === 'string' ? obj.currency.toLowerCase() : '';
const amount = obj.amount_total;

let problem = '';
if (!email) problem = 'customer_details.email is missing in the event payload';
else if (!/^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$/.test(email)) problem = 'customer_details.email is not a valid address';
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
    telegram_done: row.telegram_done,
    problem,
    customer_email: email,
    amount_minor: Number.isInteger(amount) ? amount : null,
    currency,
    amount_display: display,
  },
};`,
    },
    position: [860, 400],
  },
  output: [{ event_id: 'evt_1', attempts: 1, email_done: false, telegram_done: false, problem: '', customer_email: 'a@b.co', amount_minor: 1000, currency: 'eur', amount_display: '10,00 €' }],
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
        'WITH ins AS (INSERT INTO invoices (event_id, customer_email, amount_cents, currency) SELECT $1::text, $2::text, $3::bigint, $4::text WHERE NOT EXISTS (SELECT 1 FROM invoices WHERE event_id = $1::text) ON CONFLICT (event_id) DO NOTHING RETURNING invoice_number) SELECT invoice_number FROM ins UNION ALL SELECT invoice_number FROM invoices WHERE event_id = $1::text LIMIT 1;',
      options: {
        queryReplacement: expr('{{ [$json.event_id, $json.customer_email, $json.amount_minor, $json.currency] }}'),
        queryBatching: 'independently',
      },
    },
    credentials: { postgres: { id: 'XVNN7sIThniqsuOf', name: 'Postgres automation' } },
    onError: 'continueErrorOutput',
    position: [1300, 300],
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
      fromEmail: 'stripe-processor@example.test',
      toEmail: expr("{{ $('Prepare Event').item.json.customer_email }}"),
      subject: expr("Invoice {{ $('Create Invoice').item.json.invoice_number }} - payment received ({{ $('Prepare Event').item.json.event_id }})"),
      emailFormat: 'text',
      text: expr(
        "Thank you for your payment.\n\nInvoice: {{ $('Create Invoice').item.json.invoice_number }}\nAmount: {{ $('Prepare Event').item.json.amount_display }}\nReference: {{ $('Prepare Event').item.json.event_id }}\n",
      ),
      options: { appendAttribution: false },
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

const telegramText = expr(
  "Payment received\nInvoice: {{ $('Create Invoice').item.json.invoice_number }}\nAmount: {{ $('Prepare Event').item.json.amount_display }}\nEvent: {{ $('Prepare Event').item.json.event_id }}",
);

const sendTelegram1 = node({
  type: 'n8n-nodes-base.telegram',
  version: 1.2,
  config: {
    name: 'Send Telegram (try 1)',
    parameters: {
      resource: 'message',
      operation: 'sendMessage',
      chatId: expr('{{ $env.TELEGRAM_CHAT_ID }}'),
      text: telegramText,
      additionalFields: { appendAttribution: false, parse_mode: 'HTML' },
    },
    credentials: { telegramApi: { id: 'kNsPsjXulOh7i4RQ', name: 'Telegram alerts' } },
    onError: 'continueErrorOutput',
    position: [2400, 400],
  },
  output: [{ ok: true }],
});

const retryable1 = ifElse({
  version: 2.4,
  config: {
    name: 'Retryable? (1)',
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'loose', version: 2 },
        conditions: [
          {
            leftValue: expr('{{ /too many requests|retry after|internal server error|bad gateway|service unavailable|gateway time-?out|timed? ?out|econn|enotfound|eai_again|socket hang up|\\b(429|5\\d\\d)\\b/i.test(String($json.error?.message ?? $json.error ?? "")) }}'),
            rightValue: '',
            operator: { type: 'boolean', operation: 'true', singleValue: true },
          },
        ],
        combinator: 'and',
      },
    },
    position: [2620, 560],
  },
});

const backoff1 = node({
  type: 'n8n-nodes-base.wait',
  version: 1.1,
  config: {
    name: 'Backoff 2s',
    parameters: { resume: 'timeInterval', amount: 2, unit: 'seconds' },
    position: [2840, 480],
  },
  output: [{}],
});

const sendTelegram2 = node({
  type: 'n8n-nodes-base.telegram',
  version: 1.2,
  config: {
    name: 'Send Telegram (try 2)',
    parameters: {
      resource: 'message',
      operation: 'sendMessage',
      chatId: expr('{{ $env.TELEGRAM_CHAT_ID }}'),
      text: telegramText,
      additionalFields: { appendAttribution: false, parse_mode: 'HTML' },
    },
    credentials: { telegramApi: { id: 'kNsPsjXulOh7i4RQ', name: 'Telegram alerts' } },
    onError: 'continueErrorOutput',
    position: [3060, 480],
  },
  output: [{ ok: true }],
});

const retryable2 = ifElse({
  version: 2.4,
  config: {
    name: 'Retryable? (2)',
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'loose', version: 2 },
        conditions: [
          {
            leftValue: expr('{{ /too many requests|retry after|internal server error|bad gateway|service unavailable|gateway time-?out|timed? ?out|econn|enotfound|eai_again|socket hang up|\\b(429|5\\d\\d)\\b/i.test(String($json.error?.message ?? $json.error ?? "")) }}'),
            rightValue: '',
            operator: { type: 'boolean', operation: 'true', singleValue: true },
          },
        ],
        combinator: 'and',
      },
    },
    position: [3280, 640],
  },
});

const backoff2 = node({
  type: 'n8n-nodes-base.wait',
  version: 1.1,
  config: {
    name: 'Backoff 4s',
    parameters: { resume: 'timeInterval', amount: 4, unit: 'seconds' },
    position: [3500, 560],
  },
  output: [{}],
});

const sendTelegram3 = node({
  type: 'n8n-nodes-base.telegram',
  version: 1.2,
  config: {
    name: 'Send Telegram (try 3)',
    parameters: {
      resource: 'message',
      operation: 'sendMessage',
      chatId: expr('{{ $env.TELEGRAM_CHAT_ID }}'),
      text: telegramText,
      additionalFields: { appendAttribution: false, parse_mode: 'HTML' },
    },
    credentials: { telegramApi: { id: 'kNsPsjXulOh7i4RQ', name: 'Telegram alerts' } },
    onError: 'continueErrorOutput',
    position: [3720, 560],
  },
  output: [{ ok: true }],
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
    position: [3940, 400],
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
    position: [4160, 400],
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
let message = $json.problem || (typeof err === 'string' ? err : (err && (err.message || err.description))) || 'unknown error';
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
  '## Stripe Processor\nEvery minute: release rows stuck in processing for 10+ min, claim up to 10 pending/failed(attempts<5) rows with FOR UPDATE SKIP LOCKED, then per event: invoice -> email -> Telegram -> done. Failures mark only that event failed.\n\n**Delivery guarantee: at-least-once.** Each send is followed by an INSERT into side_effects. If a run dies between a send and its INSERT, the retry can send that one message twice. Invoice creation is exactly-once (invoices.event_id is UNIQUE).',
  [],
  { color: 4, position: [200, 40], width: 640, height: 260 },
);

const failure = describeFailure.to(markFailed);

const telegramGate = telegramAlreadySent
  .onTrue(markDone)
  .onFalse(
    sendTelegram1
      .onError(
        retryable1
          .onTrue(
            backoff1.to(
              sendTelegram2
                .onError(
                  retryable2
                    .onTrue(backoff2.to(sendTelegram3.onError(describeFailure).to(recordTelegram)))
                    .onFalse(describeFailure),
                )
                .to(recordTelegram),
            ),
          )
          .onFalse(describeFailure),
      )
      .to(recordTelegram.onError(describeFailure).to(markDone)),
  );

export default workflow('stripe-processor', 'Stripe Processor')
  .add(everyMinute)
  .to(releaseStuck)
  .to(claimEvents)
  .to(
    claimedEvent.onTrue(
      prepareEvent.to(
        eventValid
          .onTrue(
            createInvoice
              .onError(describeFailure)
              .to(
                emailAlreadySent
                  .onTrue(telegramGate)
                  .onFalse(
                    sendEmail
                      .onError(describeFailure)
                      .to(recordEmail.onError(describeFailure).to(telegramAlreadySent)),
                  ),
              ),
          )
          .onFalse(failure),
      ),
    ),
  )
  .add(note);
