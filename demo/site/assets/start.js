// Landing page: asks the server for a Stripe Checkout session and goes there. No data is sent: the server creates everything.
(function () {
  var button = document.getElementById('start');
  var msg = document.getElementById('start-msg');
  function show(cls, text) {
    msg.className = 'note ' + cls;
    msg.textContent = text;
  }
  button.addEventListener('click', function () {
    button.disabled = true;
    show('ok', 'Zahlung wird vorbereitet … / Preparing the payment …');
    fetch('/api/demo/checkout', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' })
      .then(function (r) {
        return r.json().catch(function () { return {}; }).then(function (body) { return { status: r.status, body: body }; });
      })
      .then(function (res) {
        if (res.status === 200 && typeof res.body.url === 'string' && res.body.url.indexOf('https://checkout.stripe.com/') === 0) {
          window.location.assign(res.body.url);
          return;
        }
        button.disabled = false;
        if (res.status === 429 && res.body.error === 'daily_limit') {
          show('warn', 'Das Tageslimit für Demo-Zahlungen ist erreicht. Ab 0 Uhr geht es wieder. / Today\'s demo limit is reached; it resets at midnight (Berlin).');
        } else if (res.status === 429) {
          show('warn', 'Zu viele Anfragen, bitte kurz warten. / Too many requests, please wait a moment.');
        } else {
          show('error', 'Die Demo ist gerade nicht erreichbar. Bitte später erneut versuchen. / The demo is unavailable right now, please try again later.');
        }
      })
      .catch(function () {
        button.disabled = false;
        show('error', 'Keine Verbindung. Bitte erneut versuchen. / No connection, please try again.');
      });
  });
})();
