// Creates Stripe Checkout / Customer Portal sessions for the signed-in organization.
import Stripe from "npm:stripe@17";
import { createClient } from "npm:@supabase/supabase-js@2";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, { httpClient: Stripe.createFetchHttpClient() });
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const SITE_URL = Deno.env.get("SITE_URL")!;
const PRICES: Record<string, string | undefined> = {
  month: Deno.env.get("PRICE_PRO_MONTHLY"),
  year: Deno.env.get("PRICE_PRO_YEARLY"),
};

const cors = {
  "Access-Control-Allow-Origin": SITE_URL,
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return reply({ error: "POST only" }, 405);

  const token = req.headers.get("Authorization")?.replace("Bearer ", "") ?? "";
  const { data: { user } } = await admin.auth.getUser(token);
  if (!user) return reply({ error: "Log in required" }, 401);

  const { data: profile } = await admin.from("profiles")
    .select("role, plan, stripe_customer_id, org_name, full_name").eq("id", user.id).single();
  if (profile?.role !== "organization") return reply({ error: "Organizations only" }, 403);

  const { action, interval } = await req.json().catch(() => ({}));

  if (action === "portal") {
    if (!profile.stripe_customer_id) return reply({ error: "No subscription yet" }, 409);
    const s = await stripe.billingPortal.sessions.create({ customer: profile.stripe_customer_id, return_url: SITE_URL });
    return reply({ url: s.url });
  }

  if (action === "checkout") {
    const price = PRICES[interval];
    if (!price) return reply({ error: "Unknown billing interval" }, 400);
    if (profile.plan !== "free") return reply({ error: "Already on a paid plan" }, 409);

    let customer = profile.stripe_customer_id;
    if (!customer) {
      const c = await stripe.customers.create({
        email: user.email, name: profile.org_name ?? profile.full_name ?? undefined, metadata: { user_id: user.id },
      });
      customer = c.id;
      await admin.from("profiles").update({ stripe_customer_id: customer }).eq("id", user.id);
    }
    const s = await stripe.checkout.sessions.create({
      mode: "subscription",
      customer,
      client_reference_id: user.id,
      line_items: [{ price, quantity: 1 }],
      success_url: `${SITE_URL}/?billing=success`,
      cancel_url: `${SITE_URL}/?billing=cancel`,
    });
    return reply({ url: s.url });
  }

  return reply({ error: "Unknown action" }, 400);
});
