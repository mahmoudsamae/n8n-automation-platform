#!/bin/bash
# Outside probe of the public intake (M7b-7), run by .github/workflows/outside-probe.yml on GitHub's runners, i.e. from outside the server,
# through Cloudflare's edge, the WAF rule, the tunnel and n8n: the path Stripe uses. The server's own heartbeat pings outward and stays green
# while any of those is broken (automation-review HIGH on M7b-5b).
# A POST with a fresh timestamp and a signature that cannot match must get 400 {"error":"invalid signature"} from the Intake: that answer
# needs n8n, the credential and the signature check to work, and it stores nothing (scripts\check-probe-quiet.ps1 proves no row, no alert).
# 3 tries, 10 s apart. Success pings PING_URL; anything else pings PING_URL/fail, so Healthchecks alerts at once. A probe that never runs
# (GitHub outage, the schedule disabled after 60 days without repo activity) sends nothing, and the check's grace time alerts.
# The log is PUBLIC (public repo): it prints only the HTTP status and n8n's short error text, never a body (Cloudflare's block page holds
# the caller's IP) and never PING_URL (it goes to curl through stdin).
#   PING_URL=... bash scripts/outside-probe.sh      DRY_RUN=1 bash scripts/outside-probe.sh  (no ping, prints what it would do)
set -u
url="${PROBE_URL:-https://invoice.mahmud-alhussen.de/webhook/stripe-intake}"
body="$(mktemp)"
trap 'rm -f "$body"' EXIT
zeros="$(printf '0%.0s' $(seq 64))"

ok=0
for i in 1 2 3; do
  t="$(date -u +%s)"
  code="$(curl -s -o "$body" -w '%{http_code}' --max-time 20 -X POST -H 'Content-Type: application/json' \
    -H "Stripe-Signature: t=$t,v1=$zeros" --data-binary '{"id":"evt_outside_probe","type":"probe"}' "$url")" || code="${code:-000}"
  # Only the short "error" field (n8n's JSON), no jq needed. A body without it gives '' and fails the probe (fails closed).
  err="$(grep -o '"error" *: *"[^"]\{0,60\}"' "$body" 2>/dev/null | head -1 | sed 's/.*: *"//; s/"$//')" || err=''
  echo "try $i: HTTP $code${err:+, error: $err}"
  if [ "$code" = 400 ] && [ "$err" = 'invalid signature' ]; then ok=1; break; fi
  [ "$i" = 3 ] || sleep 10
done

if [ "${DRY_RUN:-0}" = 1 ]; then
  [ "$ok" = 1 ] && echo 'DRY_RUN: would ping (ok)' || echo 'DRY_RUN: would ping /fail'
  [ "$ok" = 1 ]; exit
fi
[ -n "${PING_URL:-}" ] || { echo 'PING_URL is not set (repository secret HC_PUBLIC_PROBE_URL)'; exit 1; }
suffix=''; [ "$ok" = 1 ] || suffix='/fail'
# --retry: 429, 5xx and network errors, exponential backoff.
printf 'url = "%s%s"\n' "$PING_URL" "$suffix" | curl --config - -fsS --retry 3 --connect-timeout 10 --max-time 20 -o /dev/null \
  || { echo 'could not reach Healthchecks'; exit 1; }
if [ "$ok" = 1 ]; then echo 'probe ok, pinged'; else echo 'probe FAILED, reported /fail'; exit 1; fi
