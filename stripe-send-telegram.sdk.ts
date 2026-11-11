import { workflow, node, trigger, ifElse, sticky, expr } from '@n8n/workflow-sdk';

// Settings that the SDK file does not express (set via update_workflow): none. No errorWorkflow on purpose:
// the caller (Stripe Processor) reports a failure and stores the returned `problem` as last_error.
// The ONE place that sends owner messages to Telegram for the pipeline: a text message or a document, with the retry rules in one loop.

const request = trigger({
  type: 'n8n-nodes-base.executeWorkflowTrigger',
  version: 1.3,
  config: {
    name: 'Telegram Request',
    parameters: { inputSource: 'passthrough' },
    position: [200, 400],
  },
  output: [{ mode: 'text', text: '<b>Zahlung eingegangen</b>' }],
});

// Configuration: a second branch off the trigger, placed ABOVE Check Input (y 280 < 400) so n8n runs it first. Not inline, because the
// data table node would replace the request items (and the PDF binary) with table rows. Workflows cannot read the environment.
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
    position: [420, 280],
  },
  output: [{ id: 1, telegram_chat_id: '123' }],
});

// Exactly one row, no defaults: anything else becomes config_problem, which Check Input returns as the problem.
const configNode = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Config',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: `const KEYS = ['telegram_chat_id'];
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
    position: [640, 280],
  },
  output: [{ telegram_chat_id: '123', config_problem: '' }],
});

const checkInput = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Check Input',
    parameters: {
      mode: 'runOnceForEachItem',
      language: 'javaScript',
      jsCode: `// Input: mode 'text' (needs text) or 'document' (needs the binary property invoice_pdf, optional plain-text caption).
const mode = $json.mode;
const text = typeof $json.text === 'string' ? $json.text : '';
const caption = typeof $json.caption === 'string' ? $json.caption : '';
const binary = $input.item.binary;
const cfg = $('Config').first().json;
let problem = '';
if (cfg.config_problem) problem = 'Send Telegram: ' + cfg.config_problem;
else if (mode === 'text') {
  if (!text.trim()) problem = 'Send Telegram: the text is empty';
  else if (text.length > 4096) problem = 'Send Telegram: the text is longer than 4096 characters';
} else if (mode === 'document') {
  if (!binary || !binary.invoice_pdf) problem = 'Send Telegram: the PDF is missing';
  else if (caption.length > 1024) problem = 'Send Telegram: the caption is longer than 1024 characters';
} else {
  problem = 'Send Telegram: unknown mode';
}
const out = { json: { mode, text, caption, problem } };
if (binary) out.binary = binary;
return out;`,
    },
    position: [420, 400],
  },
  output: [{ mode: 'text', text: 't', caption: '', problem: '' }],
});

const inputOk = ifElse({
  version: 2.4,
  config: {
    name: 'Input OK?',
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'loose', version: 2 },
        conditions: [{ leftValue: expr('{{ $json.problem }}'), rightValue: '', operator: { type: 'string', operation: 'empty', singleValue: true } }],
        combinator: 'and',
      },
    },
    position: [640, 400],
  },
});

// A failed try leaves an item without the PDF, so every try starts from the checked input again (binary included).
const reloadInput = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Reload Input',
    parameters: {
      mode: 'runOnceForEachItem',
      language: 'javaScript',
      jsCode: `const src = $('Check Input').item;
const out = { json: src.json };
if (src.binary) out.binary = src.binary;
return out;`,
    },
    position: [860, 300],
  },
  output: [{ mode: 'text', text: 't', caption: '', problem: '' }],
});

const isDocument = ifElse({
  version: 2.4,
  config: {
    name: 'Document?',
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'loose', version: 2 },
        conditions: [{ leftValue: expr("{{ $json.mode === 'document' }}"), rightValue: '', operator: { type: 'boolean', operation: 'true', singleValue: true } }],
        combinator: 'and',
      },
    },
    position: [1080, 300],
  },
});

const sendMessage = node({
  type: 'n8n-nodes-base.telegram',
  version: 1.2,
  config: {
    name: 'Send Message',
    parameters: {
      resource: 'message',
      operation: 'sendMessage',
      chatId: expr("{{ $('Config').first().json.telegram_chat_id }}"),
      text: expr('{{ $json.text }}'),
      additionalFields: { appendAttribution: false, parse_mode: 'HTML' },
    },
    credentials: { telegramApi: { id: 'kNsPsjXulOh7i4RQ', name: 'Telegram alerts' } },
    onError: 'continueErrorOutput',
    position: [1300, 400],
  },
  output: [{ ok: true, result: { message_id: 1 } }],
});

// The caption is plain text: no parse mode is set for the document.
const sendDocument = node({
  type: 'n8n-nodes-base.telegram',
  version: 1.2,
  config: {
    name: 'Send Document',
    parameters: {
      resource: 'message',
      operation: 'sendDocument',
      chatId: expr("{{ $('Config').first().json.telegram_chat_id }}"),
      binaryData: true,
      binaryPropertyName: 'invoice_pdf',
      additionalFields: { caption: expr('{{ $json.caption }}') },
    },
    credentials: { telegramApi: { id: 'kNsPsjXulOh7i4RQ', name: 'Telegram alerts' } },
    onError: 'continueErrorOutput',
    position: [1300, 200],
  },
  output: [{ ok: true, result: { message_id: 1, document: { file_name: 'x.pdf', file_size: 1 } } }],
});

// Try 1 is the first run of the send nodes; this IF is evaluated after each failed try ($runIndex counts its runs: 0, 1, 2).
// 429, 5xx and network-looking errors are retried, anything else fails at once; at most 3 tries in total.
const retryable = ifElse({
  version: 2.4,
  config: {
    name: 'Retryable?',
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'loose', version: 2 },
        conditions: [
          {
            leftValue: expr(
              "{{ $runIndex < 2 && /too many requests|retry after|internal server error|bad gateway|service unavailable|gateway time-?out|timed? ?out|econn|enotfound|eai_again|socket hang up|\\b(429|5\\d\\d)\\b/i.test(String($json.error?.message ?? $json.error ?? '')) }}",
            ),
            rightValue: '',
            operator: { type: 'boolean', operation: 'true', singleValue: true },
          },
        ],
        combinator: 'and',
      },
    },
    position: [1540, 500],
  },
});

const backoff = node({
  type: 'n8n-nodes-base.wait',
  version: 1.1,
  config: {
    name: 'Backoff',
    parameters: { resume: 'timeInterval', amount: expr('{{ $runIndex === 0 ? 2 : 4 }}'), unit: 'seconds' },
    position: [1760, 580],
  },
  output: [{}],
});

const sent = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Sent',
    parameters: {
      mode: 'runOnceForEachItem',
      language: 'javaScript',
      jsCode: `const r = $json.result || {};
return { json: { ok: true, message_id: r.message_id ?? null, file_name: (r.document && r.document.file_name) || null, file_size: (r.document && r.document.file_size) || null } };`,
    },
    position: [1760, 300],
  },
  output: [{ ok: true, message_id: 1, file_name: null, file_size: null }],
});

const failed = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Failed',
    parameters: {
      mode: 'runOnceForEachItem',
      language: 'javaScript',
      jsCode: `const err = $json.error;
let message = $json.problem;
if (!message) {
  if (typeof err === 'string') message = err;
  else if (err) {
    const parts = [err.message, err.description].filter((x) => typeof x === 'string' && x.trim());
    message = parts.length === 2 && parts[1].includes(parts[0]) ? parts[1] : parts.join(': ');
  }
}
message = 'Telegram: ' + String(message || 'unknown error')
  .replace(/bot\\d+:[A-Za-z0-9_-]+/g, 'bot***')
  .replace(/\\d{6,}:[A-Za-z0-9_-]{20,}/g, '***')
  .replace(/\\s+/g, ' ')
  .trim();
return { json: { ok: false, problem: message.slice(0, 200) } };`,
    },
    position: [1760, 760],
  },
  output: [{ ok: false, problem: 'Telegram: example' }],
});

const note = sticky(
  '## Stripe Send Telegram\nThe ONE place that sends the owner messages. Input: `mode` = `text` (with `text`, HTML parse mode, customer text already escaped) or `document` (binary property `invoice_pdf`, plain-text `caption`). Output: `{ ok: true, message_id }` or `{ ok: false, problem }`.\n\nOne retry loop for both: up to 3 tries, 2 s then 4 s backoff, only for 429/5xx/network-looking errors. `Reload Input` restores the PDF before every try because a failed try leaves an item without it. Nothing here writes to Postgres: the caller records the side effect after `ok`.\n\nNo errorWorkflow on purpose: the caller stores `problem` as last_error.',
  [],
  { color: 4, position: [200, 40], width: 760, height: 220 },
);

export default workflow('stripe-send-telegram', 'Stripe Send Telegram')
  .add(request)
  .to(loadConfig)
  .to(configNode)
  .add(request)
  .to(checkInput)
  .to(
    inputOk
      .onTrue(
        reloadInput.to(
          isDocument
            .onTrue(sendDocument.onError(retryable.onTrue(backoff.to(reloadInput)).onFalse(failed)).to(sent))
            .onFalse(sendMessage.onError(retryable).to(sent)),
        ),
      )
      .onFalse(failed),
  )
  .add(note);
