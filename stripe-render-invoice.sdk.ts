import { workflow, node, trigger, ifElse, sticky, expr } from '@n8n/workflow-sdk';

// Settings that the SDK file does not express (set via update_workflow): none. No errorWorkflow on purpose:
// the Processor (the caller) already reports a failure, so a second alert for the same problem would only be noise.
// Expected problems (unknown invoice, missing document data, Gotenberg down) are RETURNED as `problem`, not thrown,
// so the caller gets the real message instead of n8n's generic "Error in sub-workflow".

const request = trigger({
  type: 'n8n-nodes-base.executeWorkflowTrigger',
  version: 1.3,
  config: {
    name: 'Invoice Request',
    parameters: { inputSource: 'passthrough' },
    position: [200, 400],
  },
  output: [{ invoice_number: 'INV-2026-000001', include_pdf: true }],
});

const loadInvoice = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.8,
  config: {
    name: 'Load Invoice',
    parameters: {
      resource: 'database',
      operation: 'executeQuery',
      // Always one row (invoice is NULL for an unknown number), so "not found" is a clear message, not an empty run.
      query:
        'SELECT $1::text AS requested_number, (SELECT row_to_json(i) FROM invoices i WHERE i.invoice_number = $1::text) AS invoice;',
      options: { queryReplacement: expr('{{ [$json.invoice_number] }}'), queryBatching: 'independently' },
    },
    credentials: { postgres: { id: 'XVNN7sIThniqsuOf', name: 'Postgres automation' } },
    position: [420, 400],
  },
  output: [{ requested_number: 'INV-2026-000001', invoice: { invoice_number: 'INV-2026-000001' } }],
});

const buildDocuments = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Build Documents',
    parameters: {
      mode: 'runOnceForEachItem',
      language: 'javaScript',
      jsCode: `// Everything below comes from the stored invoice row only: never from the Stripe event, never from the clock.
const req = $('Invoice Request').item.json;
const requested = typeof req.invoice_number === 'string' ? req.invoice_number : '';
const includePdf = req.include_pdf === true;
const fail = (problem) => ({ json: { problem: String(problem).replace(/\\s+/g, ' ').trim().slice(0, 200), invoice_number: requested, include_pdf: includePdf } });

if (!/^INV-\\d{4}-\\d{6}$/.test(requested)) return fail('Render Invoice: invalid invoice number');
const inv = $json.invoice;
if (!inv) return fail('Render Invoice: no invoice ' + requested);
const items = inv.line_items;
if (!inv.customer_name || !inv.payment_method || !Array.isArray(items) || items.length === 0) {
  return fail('Render Invoice: invoice ' + requested + ' has no document data');
}
const currency = String(inv.currency || '').toLowerCase();
if (!/^[a-z]{3}$/.test(currency)) return fail('Render Invoice: invoice ' + requested + ' has an invalid currency');

const zeroDecimal = ['bif', 'clp', 'djf', 'gnf', 'jpy', 'kmf', 'krw', 'mga', 'pyg', 'rwf', 'ugx', 'vnd', 'vuv', 'xaf', 'xof', 'xpf'];
const threeDecimal = ['bhd', 'iqd', 'jod', 'kwd', 'lyd', 'omr', 'tnd'];
const digits = zeroDecimal.includes(currency) ? 0 : threeDecimal.includes(currency) ? 3 : 2;
const money = (minor) => {
  const major = Number(minor) / Math.pow(10, digits);
  try {
    return new Intl.NumberFormat('de-DE', { style: 'currency', currency: currency.toUpperCase(), minimumFractionDigits: digits, maximumFractionDigits: digits }).format(major);
  } catch (e) {
    return major.toFixed(digits) + ' ' + currency.toUpperCase();
  }
};

let sum = 0;
for (const it of items) {
  const ok = it && typeof it.description === 'string' && it.description.trim() && Number.isInteger(it.quantity) && it.quantity >= 1
    && Number.isInteger(it.unit_amount) && it.unit_amount >= 0 && Number.isInteger(it.amount_total) && it.amount_total >= 0;
  if (!ok) return fail('Render Invoice: invoice ' + requested + ' has an invalid line item');
  sum += it.amount_total;
}
if (sum !== Number(inv.amount_cents)) return fail('Render Invoice: line items of ' + requested + ' do not add up to the invoice amount');

// Customer-controlled text (name, email, product) is escaped everywhere it is shown.
const esc = (s) => String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
const name = String(inv.customer_name).trim();
const firstName = name.split(/\\s+/)[0];
const date = new Intl.DateTimeFormat('de-DE', { timeZone: 'Europe/Berlin', day: '2-digit', month: '2-digit', year: 'numeric' }).format(new Date(inv.created_at));
const total = money(inv.amount_cents);
const product = items.map((it) => it.description.trim()).join(', ').slice(0, 150);
const number = inv.invoice_number;

const td = 'padding:10px 8px;border-bottom:1px solid #e4e7ec;';
const th = 'padding:8px;background:#f5f7fa;border-bottom:2px solid #1d3557;color:#1d3557;font-size:12px;text-transform:uppercase;letter-spacing:0.04em;';
const rows = items.map((it, i) =>
  '<tr><td style="' + td + 'color:#667085;width:28px">' + (i + 1) + '</td><td style="' + td + '">' + esc(it.description.trim()) + '</td>'
  + '<td style="' + td + 'text-align:right">' + it.quantity + '</td><td style="' + td + 'text-align:right;white-space:nowrap">' + esc(money(it.unit_amount)) + '</td>'
  + '<td style="' + td + 'text-align:right;white-space:nowrap">' + esc(money(it.amount_total)) + '</td></tr>').join('');

const body =
  '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:640px;margin:0 auto;font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:1.5;color:#1a1a1a">'
  + '<tr><td style="padding:0 0 18px;border-bottom:3px solid #1d3557"><table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr>'
  + '<td style="vertical-align:top"><div style="font-size:24px;font-weight:bold;color:#1d3557">Musterwerk</div><div style="color:#667085;font-size:12px">Musterstra&szlig;e 1 &middot; 12345 Musterstadt</div></td>'
  + '<td style="vertical-align:top;text-align:right"><div style="font-size:20px;font-weight:bold">Rechnung</div><div style="color:#667085;font-size:12px">Nr. ' + esc(number) + '<br>Datum: ' + esc(date) + '</div></td>'
  + '</tr></table></td></tr>'
  + '<tr><td style="padding:22px 0 6px"><div style="color:#667085;font-size:12px;text-transform:uppercase;letter-spacing:0.04em">Rechnung an</div>'
  + '<div style="font-weight:bold">' + esc(name) + '</div><div>' + esc(inv.customer_email) + '</div></td></tr>'
  + '<tr><td style="padding:14px 0">Guten Tag ' + esc(name) + ',<br>vielen Dank f&uuml;r Ihre Zahlung. Hier ist Ihre Rechnung.</td></tr>'
  + '<tr><td><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse">'
  + '<tr><th style="' + th + 'text-align:left;width:28px">Pos.</th><th style="' + th + 'text-align:left">Beschreibung</th><th style="' + th + 'text-align:right">Menge</th>'
  + '<th style="' + th + 'text-align:right">Einzelpreis</th><th style="' + th + 'text-align:right">Gesamt</th></tr>' + rows
  + '<tr><td colspan="4" style="padding:12px 8px;text-align:right;font-weight:bold">Gesamtbetrag</td><td style="padding:12px 8px;text-align:right;font-weight:bold;font-size:16px;white-space:nowrap;color:#1d3557">' + esc(total) + '</td></tr>'
  + '</table></td></tr>'
  + '<tr><td style="padding:16px 0 0">Zahlungsart: ' + esc(inv.payment_method) + '<br>Status: bezahlt</td></tr>'
  + '<tr><td style="padding:34px 0 0;border-top:1px solid #e4e7ec;margin-top:24px;color:#667085;font-size:11px">Portfolio-Demo aus der Stripe-Sandbox. Keine Rechnung im Sinne von &sect; 14 UStG.<br>Referenz: ' + esc(inv.event_id) + '</td></tr>'
  + '</table>';

const css = 'body{margin:0;padding:0}@page{size:A4;margin:16mm}';
const htmlEmail = '<!doctype html><html lang="de"><head><meta charset="utf-8"><title>Rechnung ' + esc(number) + '</title></head><body style="margin:0;padding:16px;background:#ffffff">' + body + '</body></html>';
// The PDF page may not load anything: the CSP blocks every request, so injected markup cannot reach the Docker network.
const htmlPdf = '<!doctype html><html lang="de"><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src &#39;none&#39;; style-src &#39;unsafe-inline&#39;; img-src data:"><title>Rechnung ' + esc(number) + '</title><style>' + css + '</style></head><body>' + body + '</body></html>';

const lines = items.map((it, i) => (i + 1) + '. ' + it.description.trim() + ' | ' + it.quantity + ' x ' + money(it.unit_amount) + ' = ' + money(it.amount_total));
const text = [
  'Musterwerk',
  '',
  'Guten Tag ' + name + ',',
  'vielen Dank für Ihre Zahlung. Hier ist Ihre Rechnung.',
  '',
  'Rechnung Nr. ' + number,
  'Datum: ' + date,
  '',
  ...lines,
  '',
  'Gesamtbetrag: ' + total,
  'Zahlungsart: ' + inv.payment_method,
  'Status: bezahlt',
  '',
  'Portfolio-Demo aus der Stripe-Sandbox. Keine Rechnung im Sinne von § 14 UStG.',
  'Referenz: ' + inv.event_id,
].join('\\n');

const telegramText = [
  '<b>Zahlung eingegangen</b>',
  'Betrag: ' + esc(total),
  'Kunde: ' + esc(firstName),
  'Rechnung: ' + esc(number),
  'Produkt: ' + esc(product),
].join('\\n');

const json = {
  problem: '', invoice_number: number, event_id: inv.event_id, include_pdf: includePdf,
  subject: 'Ihre Rechnung ' + number, html: htmlEmail, text, telegram_text: telegramText, pdf_name: 'Rechnung-' + number + '.pdf',
};
if (!includePdf) return { json };
const indexhtml = await this.helpers.prepareBinaryData(Buffer.from(htmlPdf, 'utf8'), 'index.html', 'text/html');
return { json, binary: { indexhtml } };`,
    },
    position: [640, 400],
  },
  output: [{ problem: '', invoice_number: 'INV-2026-000001', subject: 's', html: '<p>h</p>', text: 't', telegram_text: 'tg', pdf_name: 'Rechnung-INV-2026-000001.pdf', include_pdf: true }],
});

const needsPdf = ifElse({
  version: 2.4,
  config: {
    name: 'PDF Needed?',
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'loose', version: 2 },
        conditions: [
          {
            leftValue: expr("{{ $json.problem === '' && $json.include_pdf === true }}"),
            rightValue: '',
            operator: { type: 'boolean', operation: 'true', singleValue: true },
          },
        ],
        combinator: 'and',
      },
    },
    position: [860, 400],
  },
});

const noPdf = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Result (no PDF)',
    parameters: { mode: 'runOnceForEachItem', language: 'javaScript', jsCode: `return { json: $json };` },
    position: [1080, 560],
  },
  output: [{ problem: '', subject: 's' }],
});

const gotenberg = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.5,
  config: {
    name: 'Render PDF (Gotenberg)',
    parameters: {
      method: 'POST',
      url: 'http://gotenberg:3000/forms/chromium/convert/html',
      sendBody: true,
      contentType: 'multipart-form-data',
      bodyParameters: {
        parameters: [
          { parameterType: 'formBinaryData', name: 'files', inputDataFieldName: 'indexhtml' },
          { name: 'preferCssPageSize', value: 'true' },
          { name: 'printBackground', value: 'true' },
        ],
      },
      options: { timeout: 35000, response: { response: { responseFormat: 'file', outputPropertyName: 'data' } } },
    },
    onError: 'continueErrorOutput',
    position: [1080, 320],
  },
  output: [{}],
});

const attachPdf = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Attach PDF',
    parameters: {
      mode: 'runOnceForEachItem',
      language: 'javaScript',
      jsCode: `const doc = $('Build Documents').item.json;
let buf = null;
try { buf = await this.helpers.getBinaryDataBuffer($itemIndex, 'data'); } catch (e) { buf = null; }
if (!buf || buf.length < 1000 || buf.slice(0, 5).toString('latin1') !== '%PDF-') {
  return { json: { ...doc, problem: 'Render PDF (Gotenberg): the response was not a PDF' } };
}
const invoicePdf = await this.helpers.prepareBinaryData(buf, doc.pdf_name, 'application/pdf');
return { json: doc, binary: { invoice_pdf: invoicePdf } };`,
    },
    position: [1300, 320],
  },
  output: [{ problem: '', subject: 's' }],
});

const pdfFailed = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'PDF Failed',
    parameters: {
      mode: 'runOnceForEachItem',
      language: 'javaScript',
      jsCode: `const doc = $('Build Documents').item.json;
const err = $json.error;
let message = (typeof err === 'string' ? err : (err && (err.message || err.description))) || 'unknown error';
message = 'Render PDF (Gotenberg): ' + String(message).replace(/\\s+/g, ' ').trim();
return { json: { invoice_number: doc.invoice_number, include_pdf: true, problem: message.slice(0, 200) } };`,
    },
    position: [1300, 480],
  },
  output: [{ problem: 'Render PDF (Gotenberg): example' }],
});

const note = sticky(
  '## Stripe Render Invoice\nThe ONLY place that builds the invoice documents. Input: `invoice_number`, `include_pdf` (bool). It reads the invoice row by number and builds subject, HTML, plain text, Telegram text and, if asked, the PDF (Gotenberg, Chromium) from that row alone, never from the event or the clock, so a retry or a later re-render gives the same document. Callable again for any existing invoice (the public demo, M7, will reuse it).\n\nExpected problems come back in `problem` (empty = ok) so the caller can show the real message. `include_pdf: false` skips Gotenberg, so a Gotenberg outage cannot block a Telegram message when the email was already sent.\n\nNo errorWorkflow on purpose: the caller reports failures.',
  [],
  { color: 4, position: [200, 40], width: 720, height: 280 },
);

export default workflow('stripe-render-invoice', 'Stripe Render Invoice')
  .add(request)
  .to(loadInvoice)
  .to(buildDocuments)
  .to(
    needsPdf
      .onTrue(gotenberg.onError(pdfFailed).to(attachPdf))
      .onFalse(noPdf),
  )
  .add(note);
