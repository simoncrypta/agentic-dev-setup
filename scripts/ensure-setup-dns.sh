#!/usr/bin/env bash
# Create/update the setup.simoncrypta.dev CNAME for agentic-dev-setup Pages.
# Requires CLOUDFLARE_API_TOKEN with Zone.DNS Edit on simoncrypta.dev.
set -euo pipefail

ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-0911918246a46bfced4610f39e6b7eb5}"
ZONE_NAME="${CLOUDFLARE_ZONE:-simoncrypta.dev}"
DOMAIN="${SETUP_DOMAIN:-setup.simoncrypta.dev}"
PROJECT="${PAGES_PROJECT:-agentic-dev-setup}"
API="https://api.cloudflare.com/client/v4"

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  printf 'error: set CLOUDFLARE_API_TOKEN (Zone.DNS Edit on %s)\n' "$ZONE_NAME" >&2
  printf 'Create one at: https://dash.cloudflare.com/profile/api-tokens\n' >&2
  exit 1
fi

auth() { printf 'Authorization: Bearer %s' "$CLOUDFLARE_API_TOKEN"; }

api() {
  local method="$1" url="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -fsS -X "$method" -H "$(auth)" -H "Content-Type: application/json" \
      "$url" -d "$body"
  else
    curl -fsS -X "$method" -H "$(auth)" "$url"
  fi
}

TARGET="$(api GET "$API/accounts/$ACCOUNT_ID/pages/projects/$PROJECT" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['subdomain'])")"

ZONE_ID="$(api GET "$API/zones?name=$ZONE_NAME" \
  | python3 -c "import json,sys; r=json.load(sys.stdin)['result']; print(r[0]['id'])")"

ENCODED="$(python3 -c "import urllib.parse; print(urllib.parse.quote('$DOMAIN'))")"
EXISTING="$(api GET "$API/zones/$ZONE_ID/dns_records?type=CNAME&name=$ENCODED" \
  | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin).get('result') or []))")"

PAYLOAD="$(python3 - <<PY
import json
print(json.dumps({
  "type": "CNAME",
  "name": "$DOMAIN",
  "content": "$TARGET",
  "ttl": 1,
  "proxied": True,
}))
PY
)"

RECORD_ID="$(python3 - <<PY
import json
for r in json.loads('''$EXISTING'''):
  print(r.get("id", ""))
  break
PY
)"

if [[ -n "$RECORD_ID" ]]; then
  api PUT "$API/zones/$ZONE_ID/dns_records/$RECORD_ID" "$PAYLOAD" >/dev/null
  printf 'updated DNS: %s -> %s\n' "$DOMAIN" "$TARGET"
else
  api POST "$API/zones/$ZONE_ID/dns_records" "$PAYLOAD" >/dev/null
  printf 'created DNS: %s -> %s\n' "$DOMAIN" "$TARGET"
fi

# Ensure Pages custom domain is attached (idempotent).
api GET "$API/accounts/$ACCOUNT_ID/pages/projects/$PROJECT/domains/$DOMAIN" >/dev/null 2>&1 \
  || api POST "$API/accounts/$ACCOUNT_ID/pages/projects/$PROJECT/domains" \
    "{\"name\":\"$DOMAIN\"}" >/dev/null

printf 'waiting for Pages domain activation...\n'
for _ in $(seq 1 30); do
  STATUS="$(api GET "$API/accounts/$ACCOUNT_ID/pages/projects/$PROJECT/domains/$DOMAIN" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['status'])")"
  printf '  status: %s\n' "$STATUS"
  [[ "$STATUS" == "active" ]] && break
  sleep 5
done

printf 'verify: dig +short %s\n' "$DOMAIN"
dig +short "$DOMAIN" A AAAA CNAME || true
