#!/bin/bash
# Creates the two Stripe webhook endpoints for the stripe-webhook function and stores their
# signing secrets in Supabase. Reads the key from supabase/.env.stripe; nothing secret is printed.
# Run from the project folder: bash supabase/setup-stripe-webhooks.sh
set -euo pipefail
cd "$(dirname "$0")/.."

KEY=$(sed -n 's/^STRIPE_SECRET_KEY=//p' supabase/.env.stripe | tr -d '[:space:]')
case "$KEY" in sk_test_*|sk_live_*|rk_test_*|rk_live_*) ;; *) echo "No Stripe secret key found in supabase/.env.stripe"; exit 1 ;; esac
URL="https://$(cat supabase/.temp/project-ref).supabase.co/functions/v1/stripe-webhook"

field() { python3 -c "import sys,json; d=json.load(sys.stdin); e=d.get('error'); print('ERROR: '+e['message']) if e else print(d$1)"; }

echo "Checking the Stripe key..."
ACCOUNT=$(curl -s -u "$KEY:" https://api.stripe.com/v1/account | field "['id']")
echo "$ACCOUNT"
if [[ "$ACCOUNT" == ERROR* ]]; then echo "Fix the key in supabase/.env.stripe (and save the file), then run this again."; exit 1; fi
supabase secrets set --env-file supabase/.env.stripe >/dev/null
echo "Saved the Stripe key in Supabase."
echo "Checking Connect is enabled..."
CONNECT=$(curl -s -u "$KEY:" "https://api.stripe.com/v1/accounts?limit=1" | field "['object']")
if [[ "$CONNECT" == ERROR* ]]; then echo "$CONNECT"; echo "Enable Connect in the Stripe dashboard, then run this again."; exit 1; fi

EXISTING=$(curl -s -u "$KEY:" "https://api.stripe.com/v1/webhook_endpoints?limit=100" \
  | python3 -c "import sys,json; print(sum(1 for e in json.load(sys.stdin)['data'] if e['url']=='$URL'))")
if [ "$EXISTING" != "0" ]; then
  echo "Stripe already has $EXISTING webhook(s) for $URL. Delete them in Developers > Webhooks, then run this again."
  exit 1
fi

create() { # $1 = secret name, $2 = "true" for connected-account events, rest = events
  local name=$1 connect=$2; shift 2
  local args=(-d "url=$URL" -d "connect=$connect" -d "description=Exponent $name")
  for event in "$@"; do args+=(-d "enabled_events[]=$event"); done
  local secret
  secret=$(curl -s -u "$KEY:" https://api.stripe.com/v1/webhook_endpoints "${args[@]}" | field "['secret']")
  if [[ "$secret" != whsec_* ]]; then echo "Could not create the $name endpoint: $secret"; exit 1; fi
  printf '%s=%s\n' "$name" "$secret" > supabase/.env.webhooks.tmp
  supabase secrets set --env-file supabase/.env.webhooks.tmp >/dev/null
  rm -f supabase/.env.webhooks.tmp
  echo "Created $name endpoint and saved its secret in Supabase."
}

create STRIPE_WEBHOOK_SECRET false checkout.session.completed checkout.session.expired \
  customer.subscription.updated customer.subscription.deleted
create STRIPE_CONNECT_WEBHOOK_SECRET true account.updated
echo "Done."
