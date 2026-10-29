Build an end-to-end check script: scripts/e2e.ps1 (PowerShell, runs on Windows).



It must:

1\. Preflight: confirm postgres, mailpit and n8n are up (via wsl docker compose), and n8n answers on :5678.

2\. Start stripe listen in the background, forwarding to the intake webhook. Write its output to a temp file, never print it (it contains the signing secret), and stop it when the script ends, even on failure.

3\. Trigger checkout.session.completed. Tag the test event with Stripe metadata e2e=true if stripe trigger supports it (check stripe trigger --help).

4\. Find the new event in stripe\_events and poll until status is done (timeout 120s).

5\. Assert, each as its own PASS/FAIL line:

&#x20;  - exactly 1 invoice for that event

&#x20;  - side\_effects has exactly 1 email and 1 telegram row

&#x20;  - Mailpit API (localhost:8025) has exactly 1 message whose subject contains that invoice number

6\. Resend the same event, wait, and assert nothing was duplicated (invoice, side\_effects, Mailpit).

7\. POST a fake-signed request to the intake webhook and assert 400.

8\. Print a summary and exit 0 only if every check passed, otherwise exit 1.



Keep it fast and non-destructive: no stopping services. Never print secrets.

Plan first and wait for my approval.

After building, run it and show me the full output.

Then add one line to CLAUDE.md: before declaring any workflow change done, run scripts/e2e.ps1 and show the summary.

