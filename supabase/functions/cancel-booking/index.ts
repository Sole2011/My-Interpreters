// Customer cancels a booking before an interpreter accepts: the card hold is released, nothing is charged.
// Accepted (paid) bookings are not cancelled here; refunds for those are handled by hand in Stripe.
// POST { assignment_id } -> { ok: true, hold_released: boolean }
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

  const { data: result, error } = await admin.rpc("cancel_assignment_by_customer", {
    p_assignment_id: assignmentId,
    p_customer_id: user.id,
  });
  if (error) return reply({ error: error.message }, 409);

  const paymentIntentId = (result as { payment_intent_id: string | null }).payment_intent_id;
  if (!paymentIntentId) return reply({ ok: true, hold_released: false });

  try {
    await stripe.paymentIntents.cancel(paymentIntentId);
    await admin.rpc("mark_payment_released", { p_assignment_id: assignmentId });
    return reply({ ok: true, hold_released: true });
  } catch (stripeError) {
    // The booking is cancelled; Stripe also releases any uncaptured hold on its own within 7 days.
    console.error("cancel-booking: could not release hold", assignmentId, stripeError);
    return reply({ ok: true, hold_released: false });
  }
});
