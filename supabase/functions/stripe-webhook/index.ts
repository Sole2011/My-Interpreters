// Stripe webhook: the only place plan changes. Deploy with --no-verify-jwt; authenticity comes from the signature.
import Stripe from "npm:stripe@17";
import { createClient } from "npm:@supabase/supabase-js@2";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, { httpClient: Stripe.createFetchHttpClient() });
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const SECRET = Deno.env.get("STRIPE_WEBHOOK_SECRET")!;

Deno.serve(async (req) => {
  const sig = req.headers.get("stripe-signature");
  if (!sig) return new Response("Missing signature", { status: 400 });

  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(await req.text(), sig, SECRET, undefined, Stripe.createSubtleCryptoProvider());
  } catch {
    return new Response("Invalid signature", { status: 400 });
  }

  // 'unlimited' is granted manually, so webhooks never overwrite it.
  if (event.type === "checkout.session.completed") {
    const s = event.data.object as Stripe.Checkout.Session;
    if (s.mode === "subscription" && s.client_reference_id) {
      const { error } = await admin.from("profiles")
        .update({ plan: "pro", stripe_customer_id: s.customer as string, stripe_subscription_id: s.subscription as string })
        .eq("id", s.client_reference_id).neq("plan", "unlimited");
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
