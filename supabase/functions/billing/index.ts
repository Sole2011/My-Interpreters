const SITE_URL = Deno.env.get("SITE_URL") ?? "https://sole2011.github.io";
const cors = {
  "Access-Control-Allow-Origin": SITE_URL,
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const reply = (body: unknown, status: number) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  return reply({ error: "Paid customer subscriptions are paused while Exponent grows its directory." }, 410);
});
