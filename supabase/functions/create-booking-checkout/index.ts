// Starts the secure Stripe payment page for a booking. The card is only HELD here; it is charged
// when an interpreter accepts. The amount always comes from the database, never from the browser.
// POST { assignment_id } -> { url }
// Secrets needed: STRIPE_SECRET_KEY, SITE_URL (optional).
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

  const { assignment_id: assignmentId } = await req.json().catch(() => ({}));
  if (typeof assignmentId !== "string") return reply({ error: "Missing assignment" }, 400);

  const { data: a } = await admin.from("assignments")
    .select("id, customer_id, status, language, specialty, duration_hours, authorized_amount_cents, currency, stripe_checkout_session_id")
    .eq("id", assignmentId).maybeSingle();
  if (!a || a.customer_id !== user.id) return reply({ error: "Booking not found" }, 404);
  if (a.status !== "awaiting_payment" || !a.authorized_amount_cents) {
    return reply({ error: "This booking is not waiting for payment" }, 409);
  }

  try {
    // Reuse the open payment page if the customer comes back to it.
    if (a.stripe_checkout_session_id) {
      const previous = await stripe.checkout.sessions.retrieve(a.stripe_checkout_session_id);
      if (previous.status === "open" && previous.url) return reply({ url: previous.url });
    }

    const session = await stripe.checkout.sessions.create({
      mode: "payment",
      customer_email: user.email ?? undefined,
      client_reference_id: a.id,
      metadata: { assignment_id: a.id },
      line_items: [{
        quantity: 1,
        price_data: {
          currency: a.currency,
          unit_amount: a.authorized_amount_cents,
          product_data: {
            name: `Interpreter booking: ${a.language}, ${a.specialty} (${a.duration_hours} h)`,
            description: "Your card is only held now. You are charged when an interpreter accepts, and the hold is released if nobody does.",
          },
        },
      }],
      payment_intent_data: {
        capture_method: "manual",
        transfer_group: `assignment_${a.id}`,
        metadata: { assignment_id: a.id },
      },
      expires_at: Math.floor(Date.now() / 1000) + 31 * 60,
      success_url: `${SITE_URL}?payment=success`,
      cancel_url: `${SITE_URL}?payment=cancelled`,
    }, { idempotencyKey: `checkout_${a.id}_${a.stripe_checkout_session_id ?? "first"}` });

    await admin.from("assignments").update({ stripe_checkout_session_id: session.id }).eq("id", a.id);
    return reply({ url: session.url });
  } catch (error) {
    console.error("create-booking-checkout failed", error);
    return reply({ error: "Could not open the payment page. Please try again." }, 500);
  }
});
