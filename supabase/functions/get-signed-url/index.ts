import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch {
    return new Response(
      JSON.stringify({ error: "invalid_json" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const path = body.path as string | undefined;
  const conversationId = body.conversation_id as string | undefined;
  const viewerVaultIdRaw = body.viewer_vault_id as string | undefined;
  const viewerVaultId = (viewerVaultIdRaw ?? "").trim();
  const expiresIn = (body.expires_in as number) || 900;

  if (!path || !conversationId) {
    return new Response(
      JSON.stringify({ error: "missing_fields" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

  if (!supabaseUrl || !supabaseKey) {
    return new Response(
      JSON.stringify({ error: "missing_env" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const adminClient = createClient(supabaseUrl, supabaseKey);

  // Verify the caller is authenticated
  const authHeader = req.headers.get("Authorization") ?? "";
  const accessToken = authHeader.replace(/^Bearer\s+/i, "").trim();
  if (!accessToken) {
    return new Response(
      JSON.stringify({ error: "not_authenticated" }),
      { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const { data: userData, error: userError } = await adminClient.auth.getUser(accessToken);
  const userId = userData?.user?.id;

  if (userError || !userId) {
    return new Response(
      JSON.stringify({ error: "not_authenticated", detail: userError?.message }),
      { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Use service role to check conversation membership
  const { data: conv } = await adminClient
    .from("conversations")
    .select("initiator_id, participant_id, initiator_vault_id, participant_vault_id")
    .eq("id", conversationId)
    .single();

  const isConversationUser =
    !!conv && (conv.initiator_id === userId || conv.participant_id === userId);

  let hasConversationVaultAccess = false;
  if (conv && !isConversationUser && viewerVaultId) {
    const belongsToConversation =
      conv.initiator_vault_id === viewerVaultId ||
      conv.participant_vault_id === viewerVaultId;

    if (belongsToConversation) {
      const { data: ownVault } = await adminClient
        .from("vaults")
        .select("id")
        .eq("id", viewerVaultId)
        .eq("user_id", userId)
        .maybeSingle();

      if (ownVault) {
        hasConversationVaultAccess = true;
      } else {
        const { data: delegatedAccess, error: delegatedAccessError } = await adminClient
          .from("vault_access")
          .select("vault_id")
          .eq("vault_id", viewerVaultId)
          .eq("user_id", userId)
          .maybeSingle();

        if (!delegatedAccessError && delegatedAccess) {
          hasConversationVaultAccess = true;
        }
      }
    }
  }

  if (!conv || (!isConversationUser && !hasConversationVaultAccess)) {
    return new Response(
      JSON.stringify({ error: "forbidden" }),
      { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Create signed URL using service role (bypasses storage RLS)
  const { data, error } = await adminClient.storage
    .from("chat_attachments")
    .createSignedUrl(path, expiresIn);

  if (error || !data?.signedUrl) {
    return new Response(
      JSON.stringify({ error: "signed_url_failed", detail: error?.message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  return new Response(
    JSON.stringify({ signedUrl: data.signedUrl }),
    { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
});
