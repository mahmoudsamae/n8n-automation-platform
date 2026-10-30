# Case study text (CV and LinkedIn)

Ready to copy, in English and German. Every claim is one this repository proves; the table at the end says where. Re-check the numbers (42 e2e checks) before pasting if the project has moved on.
The links are relative to this file; replace them with the repository URL when you paste.
Two things are deliberately not claimed: that Telegram's real 429/5xx backoff works, and that two whole Processor runs were raced. Both are listed in [`evidence.md`](evidence.md#not-proven).

## CV, English

> **Stripe payment automation** (n8n, PostgreSQL, Docker; portfolio project, Stripe sandbox)
> - Built an event pipeline of five n8n workflows that verifies Stripe webhook signatures, stores events idempotently, and asynchronously creates invoices and sends email and Telegram notifications.
> - Tested failure handling by stopping services on purpose: 42-check end-to-end script, replay script with audit trail, alerts for permanently failed and stuck events, an external heartbeat (down alert after about 15 minutes of silence) and a rehearsed PostgreSQL restore.
> - Built with Claude Code and Codex as coding agents: I wrote the acceptance criteria, reviewed every AI plan and corrected five design errors (for example `CASCADE` to `RESTRICT` on financial tables). [How it was built](../README.md#how-it-was-built)

## CV, Deutsch

> **Stripe-Zahlungsautomatisierung** (n8n, PostgreSQL, Docker; Portfolioprojekt, Stripe-Sandbox)
> - Event-Pipeline aus fünf n8n-Workflows entwickelt, die Stripe-Webhook-Signaturen prüft, Events idempotent speichert, asynchron Rechnungen erstellt und E-Mail- sowie Telegram-Benachrichtigungen versendet.
> - Fehlerverhalten durch gezieltes Stoppen von Diensten getestet: End-to-End-Skript mit 42 Prüfungen, Replay-Skript mit Audit-Trail, Alarme bei endgültig fehlgeschlagenen und hängenden Events, externer Heartbeat (Alarm nach etwa 15 Minuten ohne Signal) und eine geprobte PostgreSQL-Wiederherstellung.
> - Mit Claude Code und Codex als Coding-Agenten entwickelt: Ich habe die Akzeptanzkriterien geschrieben, jeden KI-Plan geprüft und fünf Designfehler korrigiert (zum Beispiel `CASCADE` zu `RESTRICT` bei Finanztabellen). [So ist es entstanden](../README.md#how-it-was-built)

## LinkedIn, English

> I built a Stripe payment pipeline with n8n and PostgreSQL, mainly to practise what happens when things break. Webhooks are verified and stored before anything slow runs. Duplicates don't create a second invoice or email. Failed events raise alerts and can be replayed with an audit trail. An external heartbeat reports when the whole system goes silent. I stopped services on purpose to check this, and I rehearsed a database restore. I built it with Claude Code and Codex as coding agents: I wrote the acceptance criteria, reviewed every AI plan and corrected five design errors, for example `CASCADE` to `RESTRICT` on financial tables ([how it was built](../README.md#how-it-was-built)). The limits are documented too: it runs only in Stripe's sandbox, delivery is at-least-once, and Telegram backoff against a real 429/5xx is unproven.

## LinkedIn, Deutsch

> Ich habe mit n8n und PostgreSQL eine Stripe-Zahlungspipeline gebaut, vor allem um zu üben, was passiert, wenn etwas ausfällt. Webhooks werden geprüft und gespeichert, bevor langsame Schritte laufen. Duplikate erzeugen keine zweite Rechnung und keine zweite E-Mail. Fehlgeschlagene Events lösen Alarme aus und lassen sich mit Audit-Trail erneut verarbeiten. Ein externer Heartbeat meldet, wenn das ganze System verstummt. Das habe ich durch gezieltes Stoppen von Diensten geprüft und eine Datenbank-Wiederherstellung geprobt. Entwickelt habe ich es mit Claude Code und Codex als Coding-Agenten: Ich habe die Akzeptanzkriterien geschrieben, jeden KI-Plan geprüft und fünf Designfehler korrigiert, zum Beispiel `CASCADE` zu `RESTRICT` bei Finanztabellen ([so ist es entstanden](../README.md#how-it-was-built)). Auch die Grenzen sind dokumentiert: Das Projekt läuft nur in der Stripe-Sandbox, die Zustellung erfolgt mindestens einmal (at-least-once), und der Telegram-Backoff bei echten 429/5xx-Fehlern ist nicht belegt.

## Where each claim comes from

| Claim | Evidence |
|---|---|
| Five n8n workflows | [PLAN.md milestone table](../PLAN.md#plan) and the five `.sdk.ts` files in the repo root |
| Verifies signatures, stores idempotently | [fake signature](evidence.md#fake-signature-400), [stale timestamp](evidence.md#stale-timestamp-400), [duplicate event](evidence.md#duplicate-event-200-duplicate-1-row) |
| Creates invoices, sends email and Telegram, no duplicates | [re-run on the same event](evidence.md#re-run-on-the-same-event-no-second-invoice-or-message) |
| 42-check end-to-end script | [the e2e run](evidence.md#the-e2e-run) |
| Stopped services on purpose | [Postgres down](evidence.md#database-down-500-then-the-resend-stores-1-row), [Mailpit down](evidence.md#mailpit-down-failed-then-done-with-1-email), [Postgres down during Processor runs](evidence.md#postgres-down-one-throttled-crash-alert) |
| Replay with audit trail, alerts for permanently failed and stuck events | [alerts and replay](evidence.md#alerts-and-replay) |
| External heartbeat, about 15 minutes | [heartbeat](evidence.md#heartbeat) (that outage ended in an unplanned reboot) |
| Rehearsed restore | [backup and restore](evidence.md#backup-and-restore) |
| Built with Claude Code and Codex; criteria written, AI plans reviewed, five design errors corrected | [README, How it was built](../README.md#how-it-was-built) lists the five; the owner's own account, not something a test proves |
| At-least-once, sandbox only, Telegram backoff unproven | [README known limits](../README.md#known-limits) and [not proven](evidence.md#not-proven) |
