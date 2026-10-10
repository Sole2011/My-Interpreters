// Interpreter accepts a booking. In order: lock the offer, charge the customer's held card,
// move the interpreter's share to their Stripe account, then record the acceptance.
// Every step is safe to repeat, so an interrupted attempt can simply be retried.
// POST { assignment_id } -> { ok: true }
// Secrets needed: STRIPE_SECRET_KEY, PLATFORM_FEE_PERCENT (optional, default 10), SITE_URL (optional).
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

const feePercent = Math.min(50, Math.max(0, Number(Deno.env.get("PLATFORM_FEE_PERCENT") ?? "10") || 0));

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);

  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: auth } = await admin.auth.getUser(token);
  const user = auth?.user;
  if (!user) return reply({ error: "Please log in" }, 401);

  const { assignment_id: assignmentId } = await req.json().catch(() => ({}));
  if (typeof assignmentId !== "string") return reply({ error: "Missing assignment" }, 400);

  // 1. Lock the offer. The database checks the caller is the interpreter currently offered
  //    this job, that payment is authorized, and works out the amount from their rate.
  const { data: begun, error: beginError } = await admin.rpc("begin_assignment_acceptance", {
    p_assignment_id: assignmentId,
    p_interpreter_id: user.id,
  });
  if (beginError) return reply({ error: beginError.message }, 409);

  const { payment_intent_id: paymentIntentId, amount_cents: amount, currency, stripe_account_id: destination } = begun as {
    payment_intent_id: string; amount_cents: number; currency: string; stripe_account_id: string;
  };
  const fee = Math.floor((amount * feePercent) / 100);
  const payout = amount - fee;

  let captured = false;
  try {
    // 2. Charge the held card for the interpreter's actual total (never more than the hold).
    let intent = await stripe.paymentIntents.retrieve(paymentIntentId);
    if (intent.status === "requires_capture") {
      intent = await stripe.paymentIntents.capture(
        paymentIntentId,
        { amount_to_capture: amount },
        { idempotencyKey: `capture_${assignmentId}_${user.id}` },
      );
    }
    if (intent.status !== "succeeded" || intent.amount_received !== amount) {
      throw new Error(`Unexpected payment state: ${intent.status}`);
    }
    captured = true;
    const { error: recordError } = await admin.rpc("record_assignment_capture", {
      p_assignment_id: assignmentId,
      p_captured_cents: amount,
    });
    if (recordError) throw recordError;

    // 3. Pay the interpreter their share, tied to this exact charge.
    const chargeId = typeof intent.latest_charge === "string" ? intent.latest_charge : intent.latest_charge?.id;
    const transfer = await stripe.transfers.create({
      amount: payout,
      currency,
      destination,
      source_transaction: chargeId,
      metadata: { assignment_id: assignmentId, interpreter_id: user.id, platform_fee_cents: String(fee) },
    }, { idempotencyKey: `transfer_${assignmentId}_${user.id}` });

    // 4. Record it.
    const { error: finalizeError } = await admin.rpc("finalize_assignment_acceptance", {
      p_assignment_id: assignmentId,
      p_interpreter_id: user.id,
      p_captured_cents: amount,
      p_fee_cents: fee,
      p_transfer_id: transfer.id,
    });
    if (finalizeError) throw finalizeError;
    return reply({ ok: true });
  } catch (error) {
    console.error("accept-assignment failed", assignmentId, error);
    // Before any money moved the offer simply returns to normal. After capture it stays locked so
    // the interpreter can press Accept again to finish the remaining steps.
    if (!captured) await admin.rpc("abort_assignment_acceptance", { p_assignment_id: assignmentId });
    return reply({
      error: captured
        ? "Payment was received but confirmation did not finish. Please press Accept again."
        : "The customer's payment could not be completed. The offer is still open; please try again.",
    }, 502);
  }
});
