// Interpreter payout accounts via Stripe Connect Accounts v2 (Stripe no longer allows new platforms
// to create accounts with v1). The stripe npm SDK used elsewhere only covers v1, so these are plain
// HTTPS calls. Charges and transfers keep using v1, which works with v2 accounts.
const STRIPE_VERSION = "2026-09-30.endive";
const KEY = Deno.env.get("STRIPE_SECRET_KEY")!;

async function stripeV2(method: "GET" | "POST", path: string, body?: unknown, idempotencyKey?: string) {
  const res = await fetch(`https://api.stripe.com${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${KEY}`,
      "Stripe-Version": STRIPE_VERSION,
      ...(body ? { "Content-Type": "application/json" } : {}),
      ...(idempotencyKey ? { "Idempotency-Key": idempotencyKey } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data?.error?.message ?? `Stripe request failed (${res.status})`);
  return data;
}

// A recipient only receives transfers from the platform (separate charges and transfers), and
// Stripe hosts the onboarding and Express dashboard where the interpreter adds ID and bank details.
export async function createRecipientAccount(interpreterId: string, email: string | undefined, country: string) {
  const account = await stripeV2("POST", "/v2/core/accounts", {
    contact_email: email,
    dashboard: "express",
    identity: { country: country.toLowerCase(), entity_type: "individual" },
    configuration: { recipient: { capabilities: { stripe_balance: { stripe_transfers: { requested: true } } } } },
    defaults: { responsibilities: { fees_collector: "application", losses_collector: "application" } },
    metadata: { interpreter_id: interpreterId },
  }, `connect_v2_account_${interpreterId}`);
  return account.id as string;
}

export async function createOnboardingLink(accountId: string, returnUrl: string, refreshUrl: string) {
  const link = await stripeV2("POST", "/v2/core/account_links", {
    account: accountId,
    use_case: {
      type: "account_onboarding",
      account_onboarding: { configurations: ["recipient"], return_url: returnUrl, refresh_url: refreshUrl },
    },
  });
  return link.url as string;
}

// Bookable once Stripe has verified the interpreter and they can receive transfers.
export async function recipientReady(accountId: string) {
  const account = await stripeV2("GET", `/v2/core/accounts/${encodeURIComponent(accountId)}?include[0]=configuration.recipient`);
  return account?.configuration?.recipient?.capabilities?.stripe_balance?.stripe_transfers?.status === "active";
}
