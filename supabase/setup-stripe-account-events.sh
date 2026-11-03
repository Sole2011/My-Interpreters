#!/bin/bash
# Creates the Accounts v2 event destination (thin events) that tells the stripe-webhook function when an
# interpreter's payout account becomes (or stops being) able to receive transfers, and stores its
# signing secret in Supabase as STRIPE_ACCOUNT_EVENTS_SECRET. Nothing secret is printed.
# Run from the project folder: bash supabase/setup-stripe-account-events.sh
set -euo pipefail
cd "$(dirname "$0")/.."

KEY=$(sed -n 's/^STRIPE_SECRET_KEY=//p' supabase/.env.stripe | tr -d '[:space:]')
case "$KEY" in sk_test_*|sk_live_*|rk_test_*|rk_live_*) ;; *) echo "No Stripe secret key found in supabase/.env.stripe"; exit 1 ;; esac
URL="https://$(cat supabase/.temp/project-ref).supabase.co/functions/v1/stripe-webhook"

RESPONSE=$(curl -s https://api.stripe.com/v2/core/event_destinations \
  -H "Authorization: Bearer $KEY" \
  -H "Stripe-Version: 2026-09-30.endive" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"Exponent payout account status\",
    \"type\": \"webhook_endpoint\",
    \"event_payload\": \"thin\",
    \"events_from\": [\"@self\", \"@accounts\"],
    \"enabled_events\": [
      \"v2.core.account[configuration.recipient].capability_status_updated\",
      \"v2.core.account[configuration.recipient].updated\"
    ],
    \"webhook_endpoint\": { \"url\": \"$URL\" },
    \"include\": [\"webhook_endpoint.signing_secret\"]
  }")

SECRET=$(printf '%s' "$RESPONSE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
e = d.get('error')
print('ERROR: ' + e.get('message', 'unknown') if e else d['webhook_endpoint']['signing_secret'])")
if [[ "$SECRET" != whsec_* ]]; then echo "Could not create the event destination: $SECRET"; exit 1; fi

printf 'STRIPE_ACCOUNT_EVENTS_SECRET=%s\n' "$SECRET" > supabase/.env.webhooks.tmp
supabase secrets set --env-file supabase/.env.webhooks.tmp >/dev/null
rm -f supabase/.env.webhooks.tmp
echo "Created the event destination and saved its secret in Supabase."
echo "Now redeploy: supabase functions deploy stripe-webhook --no-verify-jwt"
