// Stripe webhook: the only place plan changes and booking payments are confirmed.
// Deploy with --no-verify-jwt; authenticity comes from the signature.
import Stripe from "npm:stripe@17";
import { createClient } from "npm:@supabase/supabase-js@2";
import { recipientReady } from "../_shared/stripe-accounts.ts";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, { httpClient: Stripe.createFetchHttpClient() });
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
// Connected-account events (interpreter payout status) arrive on a separate Stripe endpoint with its own secret.
const SECRETS = [Deno.env.get("STRIPE_WEBHOOK_SECRET"), Deno.env.get("STRIPE_CONNECT_WEBHOOK_SECRET")]
  .filter((secret): secret is string => Boolean(secret));

// The customer's card hold succeeded: offer the booking to the interpreter.
// Returns an error message to make Stripe retry, or null when handled.
async function confirmBookingHold(session: Stripe.Checkout.Session): Promise<string | null> {
  const assignmentId = session.metadata!.assignment_id;
  const intentId = typeof session.payment_intent === "string" ? session.payment_intent : session.payment_intent?.id;
  if (!intentId) return null;

  const intent = await stripe.paymentIntents.retrieve(intentId);
  if (intent.status !== "requires_capture") return null; // payment did not authorize

  const { data: assignment } = await admin.from("assignments")
    .select("authorized_amount_cents, currency").eq("id", assignmentId).maybeSingle();
  const matches = assignment && intent.amount === assignment.authorized_amount_cents && intent.currency === assignment.currency;
  if (!matches) {
    console.error("Booking hold does not match the booking; releasing it", assignmentId);
    await stripe.paymentIntents.cancel(intentId);
    return null;
  }

  const { data: outcome, error } = await admin.rpc("activate_assignment", {
    p_assignment_id: assignmentId,
    p_payment_intent_id: intentId,
  });
  if (error) return "DB error";
  if (outcome === "cancelled") {
    // Booking expired or was cancelled while the customer was paying: release the hold.
    await stripe.paymentIntents.cancel(intentId);
    await admin.rpc("mark_payment_released", { p_assignment_id: assignmentId });
  }
  return null;
}

Deno.serve(async (req) => {
  const sig = req.headers.get("stripe-signature");
  if (!sig) return new Response("Missing signature", { status: 400 });

  const payload = await req.text();
  let event: Stripe.Event | undefined;
  for (const secret of SECRETS) {
    try {
      event = await stripe.webhooks.constructEventAsync(payload, sig, secret, undefined, Stripe.createSubtleCryptoProvider());
      break;
    } catch { /* try the next endpoint's secret */ }
  }
  if (!event) return new Response("Invalid signature", { status: 400 });

  // 'unlimited' is granted manually, so webhooks never overwrite it.
  if (event.type === "checkout.session.completed") {
    const s = event.data.object as Stripe.Checkout.Session;
    if (s.mode === "payment" && s.metadata?.assignment_id) {
      const failed = await confirmBookingHold(s);
      if (failed) return new Response(failed, { status: 500 });
    } else if (s.mode === "subscription" && s.client_reference_id) {
      const { error } = await admin.from("profiles")
        .update({ plan: "pro", stripe_customer_id: s.customer as string, stripe_subscription_id: s.subscription as string })
        .eq("id", s.client_reference_id).neq("plan", "unlimited");
      if (error) return new Response("DB error", { status: 500 });
    }
  } else if (event.type === "checkout.session.expired") {
    const s = event.data.object as Stripe.Checkout.Session;
    if (s.mode === "payment" && s.metadata?.assignment_id) {
      // The customer never completed payment, so the request is dropped before any interpreter sees it.
      await admin.from("assignments").update({ status: "cancelled" })
        .eq("id", s.metadata.assignment_id).eq("status", "awaiting_payment");
    }
  } else if (event.type === "account.updated") {
    // An interpreter's payout account finished (or lost) verification: keep bookability in sync.
    // Payout accounts are Accounts v2, so the readiness check reads the v2 recipient configuration.
    const accountId = (event.data.object as Stripe.Account).id;
    const { data: known } = await admin.from("interpreter_payout_accounts")
      .select("interpreter_id").eq("stripe_account_id", accountId).maybeSingle();
    if (known) {
      const enabled = await recipientReady(accountId).catch(() => null);
      if (enabled === null) return new Response("Stripe error", { status: 500 });
      const { error } = await admin.from("interpreter_payout_accounts")
        .update({ payouts_enabled: enabled, updated_at: new Date().toISOString() })
        .eq("stripe_account_id", accountId);
      if (error) return new Response("DB error", { status: 500 });
    }
  } else if (event.type === "customer.subscription.updated" || event.type === "customer.subscription.deleted") {
    const sub = event.data.object as Stripe.Subscription;
    // past_due stays on Pro while Stripe retries the payment.
    const active = event.type !== "customer.subscription.deleted" && ["active", "trialing", "past_due"].includes(sub.status);
    const { error } = await admin.from("profiles")
      .update({ plan: active ? "pro" : "free", stripe_subscription_id: sub.id })
      .eq("stripe_customer_id", sub.customer as string).neq("plan", "unlimited");
    if (error) return new Response("DB error", { status: 500 });
  }

  return new Response("ok");
});
