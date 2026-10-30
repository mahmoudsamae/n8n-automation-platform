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
const gross = Number(inv.amount_cents);
if (sum !== gross) return fail('Render Invoice: line items of ' + requested + ' do not add up to the invoice amount');

// Stripe's total is gross. net = round(gross / 1.19) in integer arithmetic (no float rounding surprises), VAT = gross - net,
// so net + VAT is always exactly the total.
const net = Math.floor((200 * gross + 119) / 238);
const vat = gross - net;

// Customer-controlled text (name, email, product) is escaped everywhere it is shown.
const esc = (s) => String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
const name = String(inv.customer_name).trim();
const date = new Intl.DateTimeFormat('de-DE', { timeZone: 'Europe/Berlin', day: '2-digit', month: '2-digit', year: 'numeric' }).format(new Date(inv.created_at));
const total = money(gross);
const netText = money(net);
const vatText = money(vat);
const product = items.map((it) => it.description.trim()).join(', ').slice(0, 150);
const number = inv.invoice_number;
const method = String(inv.payment_method);

// ---- identity: original inline SVG monogram (no remote assets, so the PDF's CSP stays strict) ----
const logo = '<svg xmlns="http://www.w3.org/2000/svg" width="44" height="44" viewBox="0 0 48 48" role="img" aria-label="Musterwerk">'
  + '<rect width="48" height="48" rx="11" fill="#1e3a5f"/>'
  + '<path d="M13 35V13l11 14 11-14v22" fill="none" stroke="#5dcaa5" stroke-width="4.5" stroke-linecap="round" stroke-linejoin="round"/></svg>';
const badge = '<span style="display:inline-block;padding:4px 14px;border-radius:999px;background:#dff5ea;border:1px solid #9fd8bd;color:#14633f;font-size:12px;font-weight:bold;letter-spacing:0.04em">Bezahlt</span>';

const cell = 'padding:11px 8px;border-bottom:1px solid #e4e7ec;';
const head = 'padding:9px 8px;background:#1e3a5f;color:#ffffff;font-size:11px;text-transform:uppercase;letter-spacing:0.05em;';
const rows = items.map((it, i) =>
  '<tr><td style="' + cell + 'color:#667085;width:28px">' + (i + 1) + '</td><td style="' + cell + '">' + esc(it.description.trim()) + '</td>'
  + '<td style="' + cell + 'text-align:right">' + it.quantity + '</td><td style="' + cell + 'text-align:right;white-space:nowrap">' + esc(money(it.unit_amount)) + '</td>'
  + '<td style="' + cell + 'text-align:right;white-space:nowrap">' + esc(money(it.amount_total)) + '</td></tr>').join('');

const lab = 'color:#667085;font-size:12px;padding:2px 16px 2px 0;white-space:nowrap;';
const val = 'font-size:13px;padding:2px 0;white-space:nowrap;';
const info = '<table role="presentation" align="right" cellpadding="0" cellspacing="0">'
  + '<tr><td style="' + lab + '">Rechnungs-Nr.</td><td style="' + val + 'font-weight:bold">' + esc(number) + '</td></tr>'
  + '<tr><td style="' + lab + '">Rechnungsdatum</td><td style="' + val + '">' + esc(date) + '</td></tr>'
  + '<tr><td style="' + lab + '">Leistungsdatum</td><td style="' + val + '">' + esc(date) + '</td></tr>'
  + '<tr><td style="' + lab + '">Zahlungsart</td><td style="' + val + '">' + esc(method) + '</td></tr></table>';

const tl = 'padding:5px 0;font-size:13px;';
const tv = 'padding:5px 0;font-size:13px;text-align:right;white-space:nowrap;';
const totals = '<table role="presentation" align="right" cellpadding="0" cellspacing="0" style="width:56%;margin-top:6px">'
  + '<tr><td style="' + tl + '">Nettobetrag</td><td style="' + tv + '">' + esc(netText) + '</td></tr>'
  + '<tr><td style="' + tl + '">zzgl. 19 % USt.</td><td style="' + tv + '">' + esc(vatText) + '</td></tr>'
  + '<tr><td style="padding:9px 0 0;border-top:2px solid #1e3a5f;font-weight:bold;font-size:15px">Gesamtbetrag</td>'
  + '<td style="padding:9px 0 0;border-top:2px solid #1e3a5f;text-align:right;white-space:nowrap;font-weight:bold;font-size:15px;color:#1e3a5f">' + esc(total) + '</td></tr></table>';

const main =
  '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-bottom:3px solid #1e3a5f"><tr>'
  + '<td style="vertical-align:middle;width:56px;padding-bottom:14px">' + logo + '</td>'
  + '<td style="vertical-align:middle;padding:0 0 14px 12px"><div style="font-size:22px;font-weight:bold;color:#1e3a5f;line-height:1.15">Musterwerk</div>'
  + '<div style="font-size:12px;color:#667085">Workshops f&uuml;r Automatisierung</div></td>'
  + '<td style="vertical-align:middle;text-align:right;padding-bottom:14px">' + badge + '</td></tr></table>'
  + '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-top:26px"><tr>'
  + '<td style="vertical-align:top;width:52%">'
  + '<div style="font-size:10px;color:#667085;border-bottom:1px solid #c9ced6;padding-bottom:3px;margin-bottom:8px;display:inline-block">Musterwerk &middot; Musterstra&szlig;e 1 &middot; 12345 Musterstadt</div>'
  + '<div style="font-weight:bold;font-size:14px">' + esc(name) + '</div><div style="font-size:13px">' + esc(inv.customer_email) + '</div></td>'
  + '<td style="vertical-align:top">' + info + '</td></tr></table>'
  + '<div style="font-size:24px;font-weight:bold;color:#1e3a5f;margin:30px 0 8px">Rechnung</div>'
  + '<div style="margin-bottom:16px">Guten Tag ' + esc(name) + ',<br>vielen Dank f&uuml;r Ihre Zahlung. Hier ist Ihre Rechnung.</div>'
  + '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse">'
  + '<tr style="background:#1e3a5f"><th style="' + head + 'text-align:left;width:28px">Pos.</th><th style="' + head + 'text-align:left">Beschreibung</th><th style="' + head + 'text-align:right">Menge</th>'
  + '<th style="' + head + 'text-align:right">Einzelpreis</th><th style="' + head + 'text-align:right">Gesamt</th></tr>' + rows + '</table>'
  + totals + '<div style="clear:both"></div>'
  + '<div style="margin-top:26px;padding:12px 14px;background:#f2faf6;border-left:4px solid #5dcaa5;font-size:13px">Der Betrag wurde am ' + esc(date) + ' per ' + esc(method)
  + ' beglichen. Es ist nichts mehr zu zahlen.</div>';

const fcol = 'vertical-align:top;width:33%;padding:12px 12px 0 0;font-size:11px;line-height:1.55;color:#667085;';
const fhead = 'display:block;color:#1e3a5f;font-weight:bold;font-size:10px;text-transform:uppercase;letter-spacing:0.05em;margin-bottom:2px;';
const foot =
  '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-top:2px solid #1e3a5f;margin-top:34px"><tr>'
  + '<td style="' + fcol + '"><span style="' + fhead + '">Anschrift</span>Musterwerk<br>Musterstra&szlig;e 1<br>12345 Musterstadt</td>'
  + '<td style="' + fcol + '"><span style="' + fhead + '">Kontakt</span>rechnung@musterwerk.example<br>musterwerk.example</td>'
  + '<td style="' + fcol + '"><span style="' + fhead + '">Hinweis</span>Portfolio-Demo, Stripe-Sandbox.<br>Keine Rechnung i. S. d. &sect; 14 UStG.</td></tr>'
  + '<tr><td colspan="3" style="padding:10px 0 0;font-size:10px;color:#98a2b3">Referenz: ' + esc(inv.event_id) + '</td></tr></table>';

const wrap = (inner) => '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:640px;margin:0 auto;font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:1.5;color:#1a1a1a"><tr><td>' + inner + '</td></tr></table>';
const htmlEmail = '<!doctype html><html lang="de"><head><meta charset="utf-8"><title>Rechnung ' + esc(number) + '</title></head><body style="margin:0;padding:16px;background:#ffffff">' + wrap(main + foot) + '</body></html>';
// The PDF page may not load anything: the CSP blocks every request, so injected markup cannot reach the Docker network.
// The footer sits at the bottom of the A4 page (flex column) and simply follows the content if a long invoice needs a second page.
const css = '@page{size:A4;margin:14mm 16mm}body{margin:0;padding:0}.page{display:flex;flex-direction:column;min-height:269mm}.page>div{width:100%}.foot{margin-top:auto}';
const htmlPdf = '<!doctype html><html lang="de"><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src &#39;none&#39;; style-src &#39;unsafe-inline&#39;; img-src data:"><title>Rechnung ' + esc(number) + '</title><style>' + css + '</style></head><body><div class="page"><div>' + wrap(main) + '</div><div class="foot">' + wrap(foot) + '</div></div></body></html>';

const lines = items.map((it, i) => (i + 1) + '. ' + it.description.trim() + ' | ' + it.quantity + ' x ' + money(it.unit_amount) + ' = ' + money(it.amount_total));
const text = [
  'Musterwerk - Workshops für Automatisierung',
  '',
  'Guten Tag ' + name + ',',
  'vielen Dank für Ihre Zahlung. Hier ist Ihre Rechnung.',
  '',
  'Rechnung Nr. ' + number + ' (BEZAHLT)',
  'Rechnungsdatum: ' + date,
  'Leistungsdatum: ' + date,
  'Zahlungsart: ' + method,
  '',
  ...lines,
  '',
  'Nettobetrag: ' + netText,
  'zzgl. 19 % USt.: ' + vatText,
  'Gesamtbetrag: ' + total,
  '',
  'Der Betrag wurde am ' + date + ' per ' + method + ' beglichen. Es ist nichts mehr zu zahlen.',
  '',
  'Musterwerk, Musterstraße 1, 12345 Musterstadt | rechnung@musterwerk.example',
  'Portfolio-Demo, Stripe-Sandbox. Keine Rechnung i. S. d. § 14 UStG.',
  'Referenz: ' + inv.event_id,
].join('\\n');

// Owner message (Telegram HTML parse mode): every customer-controlled value is escaped. No event id.
const telegramText = [
  '<b>Zahlung eingegangen</b>',
  'Betrag: ' + esc(total),
  'Kunde: ' + esc(name),
  'Zahlungsart: ' + esc(method),
  'Rechnung: ' + esc(number),
  'Produkt: ' + esc(product),
].join('\\n');

const json = {
  problem: '', invoice_number: number, event_id: inv.event_id, include_pdf: includePdf,
  net_cents: net, vat_cents: vat,
  subject: 'Ihre Rechnung ' + number, html: htmlEmail, text, telegram_text: telegramText, telegram_caption: 'Rechnung ' + number,
  pdf_name: 'Rechnung-' + number + '.pdf',
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
  // the owner text still goes out, saying that the PDF is missing
  return { json: { ...doc, problem: 'Render PDF (Gotenberg): the response was not a PDF', telegram_text: doc.telegram_text + '\\nPDF fehlt: konnte nicht erstellt werden. Es wird erneut versucht.' } };
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
// the owner text still goes out, saying that the PDF is missing (fixed wording, no internal error text)
return { json: { invoice_number: doc.invoice_number, include_pdf: true, problem: message.slice(0, 200), telegram_text: doc.telegram_text + '\\nPDF fehlt: konnte nicht erstellt werden. Es wird erneut versucht.' } };`,
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
