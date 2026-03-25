import { createClient } from "npm:@supabase/supabase-js@2";
import { importPKCS8, SignJWT } from "npm:jose@5.9.6";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

type RequestPayload = {
  conversationId?: string;
  senderVaultId?: string | null;
  messagePreview?: string;
};

type FirebaseServiceAccount = {
  project_id?: string;
  client_email?: string;
  private_key?: string;
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "missing_authorization" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const body = (await req.json().catch(() => ({}))) as RequestPayload;
    const conversationId = (body.conversationId ?? "").trim();
    const senderVaultId = (body.senderVaultId ?? "").toString().trim();
    const messagePreview = (body.messagePreview ?? "").toString().trim();
    if (!conversationId) {
      return new Response(
        JSON.stringify({ error: "missing_conversation_id" }),
        {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
    const firebaseServiceAccountRaw = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON") ?? "";
    if (!supabaseUrl || !supabaseAnonKey) {
      return new Response(JSON.stringify({ error: "missing_supabase_env" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    if (!firebaseServiceAccountRaw) {
      return new Response(
        JSON.stringify({ error: "missing_firebase_service_account_json" }),
        {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    let firebaseServiceAccount: FirebaseServiceAccount;
    try {
      firebaseServiceAccount = JSON.parse(firebaseServiceAccountRaw) as FirebaseServiceAccount;
    } catch (_) {
      return new Response(
        JSON.stringify({ error: "invalid_firebase_service_account_json" }),
        {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    const firebaseProjectId = (firebaseServiceAccount.project_id ?? "").trim();
    const firebaseClientEmail = (firebaseServiceAccount.client_email ?? "").trim();
    const firebasePrivateKeyRaw = firebaseServiceAccount.private_key ?? "";
    const firebasePrivateKey = firebasePrivateKeyRaw.replace(/\\n/g, "\n").trim();

    if (!firebaseProjectId || !firebaseClientEmail || !firebasePrivateKey) {
      return new Response(
        JSON.stringify({ error: "firebase_service_account_missing_fields" }),
        {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    const supabaseClient = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const {
      data: { user },
      error: authError,
    } = await supabaseClient.auth.getUser();
    if (authError || !user?.id) {
      return new Response(JSON.stringify({ error: "unauthorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    const senderUserId = user.id;

    const {
      data: pushTargets,
      error: pushTargetError,
    } = await supabaseClient.rpc("get_conversation_push_targets", {
      input_conversation_id: conversationId,
      input_sender_vault_id: senderVaultId || null,
    });

    if (pushTargetError) {
      return new Response(
        JSON.stringify({
          error: "push_target_query_failed",
          details: pushTargetError.message,
        }),
        {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    const targets = (pushTargets ?? []) as Array<{
      token?: string;
      recipient_user_id?: string;
      recipient_vault_id?: string | null;
    }>;

    if (targets.length === 0) {
      return new Response(
        JSON.stringify({ ok: true, sent: 0, reason: "no_tokens" }),
        {
          status: 200,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    const recipientUserId = (targets[0]?.recipient_user_id ?? "").toString();
    const recipientVaultId = (targets[0]?.recipient_vault_id ?? "").toString().trim();
    const tokens = [
      ...new Set(
        targets
          .map((row) => (row.token ?? "").toString().trim())
          .filter((token) => token.length > 0),
      ),
    ];

    if (tokens.length === 0) {
      return new Response(
        JSON.stringify({ ok: true, sent: 0, reason: "no_tokens" }),
        {
          status: 200,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    const privateKey = await importPKCS8(firebasePrivateKey, "RS256");
    const now = Math.floor(Date.now() / 1000);
    const jwtAssertion = await new SignJWT({
      scope: "https://www.googleapis.com/auth/firebase.messaging",
    })
      .setProtectedHeader({ alg: "RS256", typ: "JWT" })
      .setIssuer(firebaseClientEmail)
      .setSubject(firebaseClientEmail)
      .setAudience("https://oauth2.googleapis.com/token")
      .setIssuedAt(now)
      .setExpirationTime(now + 3600)
      .sign(privateKey);

    const tokenResponse = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion: jwtAssertion,
      }),
    });

    if (!tokenResponse.ok) {
      const details = await tokenResponse.text();
      return new Response(
        JSON.stringify({ error: "google_oauth_failed", details }),
        {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    const tokenPayload = await tokenResponse.json() as { access_token?: string };
    const accessToken = (tokenPayload.access_token ?? "").trim();
    if (!accessToken) {
      return new Response(
        JSON.stringify({ error: "google_access_token_missing" }),
        {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    const route = recipientVaultId
      ? `/chat/${conversationId}?vaultId=${recipientVaultId}`
      : "/game";

    let sent = 0;
    let failed = 0;

    for (const token of tokens) {
      const response = await fetch(
        `https://fcm.googleapis.com/v1/projects/${firebaseProjectId}/messages:send`,
        {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${accessToken}`,
        },
        body: JSON.stringify({
          message: {
            token,
            notification: {
              title: "BoomYou",
              body: "hadi şimdi matematiğini geliştir",
            },
            data: {
              conversationId,
              vaultId: recipientVaultId,
              route,
              messagePreview,
              recipientUserId,
            },
            android: {
              priority: "high",
              notification: {
                sound: "default",
              },
            },
            apns: {
              headers: {
                "apns-priority": "10",
              },
              payload: {
                aps: {
                  sound: "default",
                },
              },
            },
          },
        }),
      },
      );

      if (response.ok) {
        sent += 1;
      } else {
        failed += 1;
      }
    }

    return new Response(JSON.stringify({ ok: true, sent, failed, total: tokens.length }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : "unexpected_error";
    return new Response(JSON.stringify({ error: message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
