// Interpreter payout onboarding (Stripe Connect Express).
// POST { action: "start" }  -> { url }   Stripe-hosted form where the interpreter adds ID and bank details.
// POST { action: "status" } -> { payouts_enabled, details_submitted }   refreshes status after they return.
// Secrets needed: STRIPE_SECRET_KEY, SITE_URL (optional), PAYOUT_COUNTRY (optional, default US).
import Stripe from "npm:stripe@17";
import { createClient } from "npm:@supabase/supabase-js@2";

const SITE_URL = Deno.env.get("SITE_URL") ?? "https://sole2011.github.io/My-Interpreters/";
const cors = {
  "Access-Control-Allow-Origin": new URL(SITE_URL).origin,
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, { httpClient: Stripe.createFetchHttpClient() });
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);

  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: auth } = await admin.auth.getUser(token);
  const user = auth?.user;
  if (!user) return reply({ error: "Please log in" }, 401);

  const { data: profile, error: profileError } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
  if (profileError) {
    console.error("connect-onboarding: profile lookup failed", profileError);
    return reply({ error: `Could not load your account (${profileError.message})` }, 500);
  }
  if (!profile) return reply({ error: "Your account profile is missing. Please contact support." }, 404);
  if (profile.role !== "interpreter") return reply({ error: "Only interpreters can set up payouts" }, 403);

  const body = await req.json().catch(() => ({}));
  const action = body?.action === "status" ? "status" : "start";

  try {
    const { data: existing } = await admin.from("interpreter_payout_accounts")
      .select("stripe_account_id").eq("interpreter_id", user.id).maybeSingle();

    if (action === "status") {
      if (!existing) return reply({ payouts_enabled: false, details_submitted: false });
      const account = await stripe.accounts.retrieve(existing.stripe_account_id);
      const enabled = Boolean(account.details_submitted && account.payouts_enabled && account.capabilities?.transfers === "active");
      await admin.from("interpreter_payout_accounts")
        .update({ payouts_enabled: enabled, updated_at: new Date().toISOString() })
        .eq("interpreter_id", user.id);
      return reply({ payouts_enabled: enabled, details_submitted: Boolean(account.details_submitted) });
    }

    let accountId = existing?.stripe_account_id;
    if (!accountId) {
      const account = await stripe.accounts.create({
        type: "express",
        country: Deno.env.get("PAYOUT_COUNTRY") ?? "US",
        email: user.email ?? undefined,
        business_type: "individual",
        capabilities: { card_payments: { requested: true }, transfers: { requested: true } },
        metadata: { interpreter_id: user.id },
      }, { idempotencyKey: `connect_account_${user.id}` });
      accountId = account.id;
      const { error } = await admin.from("interpreter_payout_accounts")
        .insert({ interpreter_id: user.id, stripe_account_id: accountId });
      if (error) throw error;
    }

    const link = await stripe.accountLinks.create({
      account: accountId,
      type: "account_onboarding",
      refresh_url: `${SITE_URL}?payouts=refresh`,
      return_url: `${SITE_URL}?payouts=return`,
    });
    return reply({ url: link.url });
  } catch (error) {
    console.error("connect-onboarding failed", error);
    return reply({ error: "Could not set up payouts right now. Please try again." }, 500);
  }
});
