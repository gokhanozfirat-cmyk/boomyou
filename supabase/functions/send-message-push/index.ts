const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  // Push is intentionally disabled.
  await req.json().catch(() => ({}));

  return new Response(
    JSON.stringify({
      ok: true,
      sent: 0,
      failed: 0,
      total: 0,
      reason: "push_disabled",
    }),
    {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    },
  );
});
