import { workflow, node, trigger, ifElse, sticky, expr } from '@n8n/workflow-sdk';

// Settings that the SDK file does not express (set via update_workflow): none. No errorWorkflow on purpose,
// so a failing alert can never trigger another alert.

const fromParent = trigger({
  type: 'n8n-nodes-base.executeWorkflowTrigger',
  version: 1.3,
  config: {
    name: 'Alert Input',
    parameters: { inputSource: 'passthrough' },
    position: [200, 400],
  },
  output: [{ subject: 'Stripe pipeline: 1 event needs attention', body: 'details' }],
});

// Configuration: a second branch off the trigger, placed ABOVE Prepare Alert (y 300 < 400) so n8n runs it first. Workflows cannot
// read the environment. A config problem does not stop the alert: a missing chat id fails only Telegram, missing addresses fail only
// the email, so one channel still gets through; if both fail, Verdict names the config problem.
const loadConfig = node({
  type: 'n8n-nodes-base.dataTable',
  version: 1.1,
  config: {
    name: 'Load Config',
    parameters: {
      resource: 'row',
      operation: 'get',
      dataTableId: { __rl: true, mode: 'name', value: 'stripe_config' },
      returnAll: true,
    },
    alwaysOutputData: true,
    executeOnce: true,
    onError: 'continueRegularOutput',
    position: [420, 300],
  },
  output: [{ id: 1, telegram_chat_id: '123', alert_email_to: 'ops@alerts.invalid', alert_email_from: 'n8n@alerts.invalid' }],
});

// Exactly one row, no defaults: anything else becomes config_problem.
const configNode = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Config',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: `const KEYS = ['telegram_chat_id', 'alert_email_to', 'alert_email_from'];
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
    position: [640, 300],
  },
  output: [{ telegram_chat_id: '123', alert_email_to: 'ops@alerts.invalid', alert_email_from: 'n8n@alerts.invalid', config_problem: '' }],
});

const prepareAlert = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Prepare Alert',
    parameters: {
      mode: 'runOnceForEachItem',
      language: 'javaScript',
      jsCode: `const clean = (s) => String(s == null ? '' : s)
  .replace(/bot\\d+:[A-Za-z0-9_-]+/g, 'bot***')
  .replace(/\\d{6,}:[A-Za-z0-9_-]{20,}/g, '***')
  .replace(/whsec_[A-Za-z0-9]+/g, 'whsec_***')
  .replace(/(sk|rk|pk)_(test|live)_[A-Za-z0-9]+/g, '$1_$2_***');
const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

const subject = clean($json.subject).replace(/\\s+/g, ' ').trim().slice(0, 150);
let body = clean($json.body).trim();
if (!subject || !body) throw new Error('Send Alert needs a non-empty subject and body');
if (body.length > 3500) body = body.slice(0, 3497) + '...';

return { json: { subject, body, tg_text: '<b>' + esc(subject) + '</b>\\n' + esc(body) } };`,
    },
    position: [420, 400],
  },
  output: [{ subject: 's', body: 'b', tg_text: '<b>s</b>\nb' }],
});

const alertText = expr("{{ $('Prepare Alert').first().json.tg_text }}");

const sendTelegram1 = node({
  type: 'n8n-nodes-base.telegram',
  version: 1.2,
  config: {
    name: 'Alert Telegram (try 1)',
    parameters: {
      resource: 'message',
      operation: 'sendMessage',
      chatId: expr("{{ $('Config').first().json.telegram_chat_id }}"),
      text: alertText,
      additionalFields: { appendAttribution: false, parse_mode: 'HTML' },
    },
    credentials: { telegramApi: { id: 'kNsPsjXulOh7i4RQ', name: 'Telegram alerts' } },
    onError: 'continueErrorOutput',
    position: [640, 400],
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
    position: [860, 560],
  },
});

const backoff1 = node({
  type: 'n8n-nodes-base.wait',
  version: 1.1,
  config: {
    name: 'Backoff 2s',
    parameters: { resume: 'timeInterval', amount: 2, unit: 'seconds' },
    position: [1080, 480],
  },
  output: [{}],
});

const sendTelegram2 = node({
  type: 'n8n-nodes-base.telegram',
  version: 1.2,
  config: {
    name: 'Alert Telegram (try 2)',
    parameters: {
      resource: 'message',
      operation: 'sendMessage',
      chatId: expr("{{ $('Config').first().json.telegram_chat_id }}"),
      text: alertText,
      additionalFields: { appendAttribution: false, parse_mode: 'HTML' },
    },
    credentials: { telegramApi: { id: 'kNsPsjXulOh7i4RQ', name: 'Telegram alerts' } },
    onError: 'continueErrorOutput',
    position: [1300, 480],
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
    position: [1520, 640],
  },
});

const backoff2 = node({
  type: 'n8n-nodes-base.wait',
  version: 1.1,
  config: {
    name: 'Backoff 4s',
    parameters: { resume: 'timeInterval', amount: 4, unit: 'seconds' },
    position: [1740, 560],
  },
  output: [{}],
});

const sendTelegram3 = node({
  type: 'n8n-nodes-base.telegram',
  version: 1.2,
  config: {
    name: 'Alert Telegram (try 3)',
    parameters: {
      resource: 'message',
      operation: 'sendMessage',
      chatId: expr("{{ $('Config').first().json.telegram_chat_id }}"),
      text: alertText,
      additionalFields: { appendAttribution: false, parse_mode: 'HTML' },
    },
    credentials: { telegramApi: { id: 'kNsPsjXulOh7i4RQ', name: 'Telegram alerts' } },
    onError: 'continueErrorOutput',
    position: [1960, 560],
  },
  output: [{ ok: true }],
});

const telegramSent = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Telegram Sent',
    parameters: {
      mode: 'runOnceForEachItem',
      language: 'javaScript',
      jsCode: `return { json: { telegram: 'ok' } };`,
    },
    position: [2200, 400],
  },
  output: [{ telegram: 'ok' }],
});

const telegramFailed = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Telegram Failed',
    parameters: {
      mode: 'runOnceForEachItem',
      language: 'javaScript',
      jsCode: `const err = $json.error;
let message = (typeof err === 'string' ? err : (err && (err.message || err.description))) || 'unknown error';
message = String(message)
  .replace(/bot\\d+:[A-Za-z0-9_-]+/g, 'bot***')
  .replace(/\\d{6,}:[A-Za-z0-9_-]{20,}/g, '***')
  .replace(/\\s+/g, ' ')
  .trim()
  .slice(0, 200);
return { json: { telegram: 'failed', telegram_error: message } };`,
    },
    position: [2200, 720],
  },
  output: [{ telegram: 'failed', telegram_error: 'example' }],
});

const sendEmail = node({
  type: 'n8n-nodes-base.emailSend',
  version: 2.1,
  config: {
    name: 'Alert Email',
    parameters: {
      operation: 'send',
      fromEmail: expr("{{ $('Config').first().json.alert_email_from }}"),
      toEmail: expr("{{ $('Config').first().json.alert_email_to }}"),
      subject: expr("[Stripe alert] {{ $('Prepare Alert').first().json.subject }}"),
      emailFormat: 'text',
      text: expr("{{ $('Prepare Alert').first().json.body }}"),
      options: { appendAttribution: false },
    },
    credentials: { smtp: { id: 'nxXABuEVvevioUzb', name: 'Mailpit SMTP' } },
    onError: 'continueErrorOutput',
    position: [2420, 560],
  },
  output: [{ accepted: ['ops@alerts.invalid'] }],
});

const emailOk = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Email OK',
    parameters: { mode: 'runOnceForEachItem', language: 'javaScript', jsCode: `return { json: { email: 'ok' } };` },
    position: [2640, 480],
  },
  output: [{ email: 'ok' }],
});

const emailFailed = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Email Failed',
    parameters: { mode: 'runOnceForEachItem', language: 'javaScript', jsCode: `return { json: { email: 'failed' } };` },
    position: [2640, 680],
  },
  output: [{ email: 'failed' }],
});

// A node that did not run throws when read, which is how this tells "ok" from "failed" apart.
const verdict = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Verdict',
    parameters: {
      mode: 'runOnceForEachItem',
      language: 'javaScript',
      jsCode: `const ran = (name) => { try { $(name).first(); return true; } catch (e) { return false; } };
const telegram = ran('Telegram Sent');
const email = ran('Email OK');
let configProblem = '';
try { configProblem = $('Config').first().json.config_problem || ''; } catch (e) {}
if (!telegram && !email) throw new Error('Alert was not delivered on any channel (Telegram and email both failed)' + (configProblem ? ': ' + configProblem : ''));
return { json: { telegram: telegram ? 'ok' : 'failed', email: email ? 'ok' : 'failed' } };`,
    },
    position: [2860, 580],
  },
  output: [{ telegram: 'ok', email: 'ok' }],
});

const note = sticky(
  '## Stripe Send Alert\nShared by Stripe Error Handler and Stripe Monitor. Input: `subject`, `body` (plain text).\nSends Telegram (3 tries, 2 s then 4 s backoff, only for 429/5xx/network-looking errors) and then email. One channel failing is absorbed; if BOTH fail, `Verdict` throws, so the caller knows the alert was not delivered (the Monitor then leaves `alerted_at` empty and retries next run).\n\nNo errorWorkflow is set here on purpose: a failing alert must not trigger another alert.',
  [],
  { color: 4, position: [200, 40], width: 720, height: 240 },
);

const mailStage = sendEmail.onError(emailFailed.to(verdict)).to(emailOk.to(verdict));
const sentThenMail = telegramSent.to(mailStage);
const failedThenMail = telegramFailed.to(sendEmail);

export default workflow('stripe-send-alert', 'Stripe Send Alert')
  .add(fromParent)
  .to(loadConfig)
  .to(configNode)
  .add(fromParent)
  .to(prepareAlert)
  .to(
    sendTelegram1
      .onError(
        retryable1
          .onTrue(
            backoff1.to(
              sendTelegram2
                .onError(
                  retryable2
                    .onTrue(backoff2.to(sendTelegram3.onError(failedThenMail).to(telegramSent)))
                    .onFalse(telegramFailed),
                )
                .to(telegramSent),
            ),
          )
          .onFalse(telegramFailed),
      )
      .to(sentThenMail),
  )
  .add(note);
