// Result page: the token is in the URL fragment (#...), which the browser never sends to a server. It goes to the API only in a POST body.
(function () {
  var token = window.location.hash.slice(1);
  var LABELS = {
    checkout: 'Checkout erstellt / Checkout created',
    webhook: 'Zahlung bei Stripe, Webhook geprüft und gespeichert / Payment at Stripe, webhook verified and stored',
    processing: 'Verarbeitung gestartet / Processing started',
    invoice: 'Rechnung erstellt / Invoice created',
    email: 'E-Mail mit PDF versendet (an Mailpit) / Email with PDF sent (to Mailpit)',
    done: 'Fertig / Done',
  };
  var state = document.getElementById('state');
  var steps = document.getElementById('steps');
  var results = document.getElementById('results');
  var started = Date.now();
  var previewLoaded = false;

  function note(cls, text) {
    state.className = 'note ' + cls;
    state.textContent = text;
  }
  function api(part) {
    return fetch('/api/demo/result', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ token: token, part: part }) });
  }
  function time(iso) {
    return iso ? new Date(iso).toLocaleTimeString('de-DE', { hour: '2-digit', minute: '2-digit', second: '2-digit' }) : '';
  }
  function render(s) {
    steps.textContent = '';
    var firstOpen = true;
    s.steps.forEach(function (step) {
      var li = document.createElement('li');
      li.className = step.at ? 'done' : firstOpen ? 'active' : '';
      if (!step.at) firstOpen = false;
      var dot = document.createElement('span');
      dot.className = 'dot';
      var label = document.createElement('span');
      label.className = 'label';
      label.textContent = LABELS[step.key] + (step.detail ? ': ' + step.detail : '');
      var t = document.createElement('span');
      t.className = 'time';
      t.textContent = time(step.at);
      li.append(dot, label, t);
      steps.append(li);
    });
  }
  function loadPreview() {
    previewLoaded = true;
    api('preview')
      .then(function (r) { if (!r.ok) throw new Error(String(r.status)); return r.json(); })
      .then(function (p) {
        document.getElementById('email-meta').textContent = p.subject + ' → ' + p.to;
        // Shown as a sandboxed srcdoc: no scripts, no same origin, so the email cannot touch this page.
        document.getElementById('email-frame').srcdoc = p.email_html;
        document.getElementById('telegram-text').textContent = p.telegram_text || '(keine Vorschau / no preview)';
        results.classList.remove('hidden');
      })
      .catch(function () { previewLoaded = false; });
  }
  function poll() {
    api('status')
      .then(function (r) {
        if (r.status === 404) {
          note('warn', 'Diese Demo-Zahlung wurde nicht gefunden oder bereits zurückgesetzt (jede Nacht um 02:30). / This demo payment was not found or has been reset (nightly at 02:30).');
          return null;
        }
        if (!r.ok) throw new Error(String(r.status));
        return r.json();
      })
      .then(function (s) {
        if (!s) return;
        render(s);
        var waited = (Date.now() - started) / 1000;
        if (s.state === 'done') {
          note('ok', 'Fertig: Rechnung ' + s.invoice_number + ' über ' + s.amount + '. / Done: invoice ' + s.invoice_number + ', ' + s.amount + '.');
          if (!previewLoaded) loadPreview();
          return;
        }
        if (s.state === 'failed') {
          note('error', 'Die Verarbeitung ist fehlgeschlagen; der Betreiber wurde benachrichtigt. / Processing failed; the owner has been alerted.');
          return;
        }
        var text = s.state === 'waiting_payment' ? 'Warte auf die Zahlungsbestätigung von Stripe … / Waiting for Stripe\'s payment confirmation …'
          : s.state === 'retrying' ? 'Ein Schritt wird wiederholt … / Retrying a step …'
          : 'Wird verarbeitet … / Processing …';
        if (waited > 180) {
          note('warn', 'Das dauert länger als üblich. Status: ' + s.state + '. Die Seite kann später neu geladen werden. / This takes longer than usual; reload later.');
          return;
        }
        note('ok', text);
        setTimeout(poll, 2000);
      })
      .catch(function () {
        if ((Date.now() - started) / 1000 > 180) { note('error', 'Keine Verbindung. / No connection.'); return; }
        setTimeout(poll, 4000);
      });
  }

  document.getElementById('pdf').addEventListener('click', function () {
    var b = this;
    b.disabled = true;
    api('pdf')
      .then(function (r) { if (!r.ok) throw new Error(String(r.status)); return r.blob(); })
      .then(function (blob) {
        var a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = 'Rechnung.pdf';
        document.body.append(a);
        a.click();
        a.remove();
        setTimeout(function () { URL.revokeObjectURL(a.href); }, 10000);
      })
      .catch(function () { alert('PDF nicht verfügbar. / PDF not available.'); })
      .then(function () { b.disabled = false; });
  });

  if (!/^[A-Za-z0-9_-]{43}$/.test(token)) {
    note('warn', 'Kein gültiger Link. Bitte die Demo auf der Startseite starten. / Not a valid link; start the demo on the home page.');
    return;
  }
  poll();
})();
