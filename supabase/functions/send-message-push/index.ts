import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

// Fun notification messages
const FUN_TITLES = [
  "Oyun zaman\u{0131}! \u{1F3AE}",
  "Haydi oyuna! \u{1F525}",
  "BoomYou! \u{1F4A3}",
  "Bomba haz\u{0131}r! \u{1F4A5}",
  "S\u{0131}ra sende! \u{1F3AF}",
];

const FUN_BODIES = [
  "Haydi kasana gir, seni bekliyorlar!",
  "Boom! Kasan\u{0131} patlatma vakti!",
  "Rakibin hamlesini yapt\u{0131}, s\u{0131}ra sende!",
  "Oyun ba\u{015F}l\u{0131}yor, haz\u{0131}r m\u{0131}s\u{0131}n?",
  "Kasan\u{0131} a\u{00E7}, oyun seni bekliyor!",
];

const ANDROID_CHANNEL_VIBRATE = "boomyou_messages_v3_vibrate";
const ANDROID_CHANNEL_SILENT = "boomyou_messages_v3_silent";

function randomPick(arr: string[]): string {
  return arr[Math.floor(Math.random() * arr.length)];
}

function toBase64Url(str: string): string {
  return btoa(str).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function getAccessToken(serviceAccount: {
  client_email: string;
  private_key: string;
  token_uri: string;
}): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = toBase64Url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const payload = toBase64Url(
    JSON.stringify({
      iss: serviceAccount.client_email,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: serviceAccount.token_uri,
      iat: now,
      exp: now + 3600,
    })
  );

  const encoder = new TextEncoder();
  const data = encoder.encode(`${header}.${payload}`);

  // Import RSA private key
  const pemContents = serviceAccount.private_key
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\n/g, "");
  const binaryKey = Uint8Array.from(atob(pemContents), (c) => c.charCodeAt(0));

  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8",
    binaryKey,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"]
  );

  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    cryptoKey,
    data
  );
  const sig = toBase64Url(String.fromCharCode(...new Uint8Array(signature)));

  const jwt = `${header}.${payload}.${sig}`;

  const tokenRes = await fetch(serviceAccount.token_uri, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}`,
  });

  const tokenData = await tokenRes.json();

  if (!tokenData.access_token) {
    throw new Error(
      `Token exchange failed: ${JSON.stringify(tokenData)}`
    );
  }

  return tokenData.access_token;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch {
    return new Response(
      JSON.stringify({ ok: false, error: "invalid_json" }),
      {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }

  const conversationId = body.conversation_id as string | undefined;
  const senderId = body.sender_id as string | undefined;
  const senderVaultIdRaw = body.sender_vault_id;
  const senderVaultId =
    typeof senderVaultIdRaw === "string" && senderVaultIdRaw.trim().length > 0
      ? senderVaultIdRaw.trim()
      : null;

  if (!conversationId || !senderId) {
    return new Response(
      JSON.stringify({ ok: false, error: "missing_fields" }),
      {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }

  // Init Supabase admin client
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const firebaseJson = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON") ?? "";

  if (!supabaseUrl || !supabaseKey || !firebaseJson) {
    return new Response(
      JSON.stringify({
        ok: false,
        error: "missing_env",
        has_url: !!supabaseUrl,
        has_key: !!supabaseKey,
        has_firebase: !!firebaseJson,
      }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }

  const supabase = createClient(supabaseUrl, supabaseKey);

  // Find the conversation to get the recipient
  const { data: conv, error: convErr } = await supabase
    .from("conversations")
    .select(
      "initiator_id, participant_id, initiator_vault_id, participant_vault_id"
    )
    .eq("id", conversationId)
    .single();

  if (!conv) {
    return new Response(
      JSON.stringify({
        ok: true,
        sent: 0,
        reason: "conversation_not_found",
        detail: convErr?.message,
      }),
      {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }

  // Resolve recipient by user id first; if sender id is stale in conversation
  // (vault-based access / re-login cases), fall back to sender vault mapping.
  let recipientId: string | null = null;
  let recipientVaultId: string | null = null;

  if (conv.initiator_id === senderId) {
    recipientId = conv.participant_id ?? null;
    recipientVaultId = conv.participant_vault_id ?? null;
  } else if (conv.participant_id === senderId) {
    recipientId = conv.initiator_id ?? null;
    recipientVaultId = conv.initiator_vault_id ?? null;
  } else if (
    senderVaultId &&
    conv.initiator_vault_id &&
    conv.initiator_vault_id === senderVaultId
  ) {
    recipientId = conv.participant_id ?? null;
    recipientVaultId = conv.participant_vault_id ?? null;
  } else if (
    senderVaultId &&
    conv.participant_vault_id &&
    conv.participant_vault_id === senderVaultId
  ) {
    recipientId = conv.initiator_id ?? null;
    recipientVaultId = conv.initiator_vault_id ?? null;
  }

  if (!recipientId && !recipientVaultId) {
    return new Response(
      JSON.stringify({
        ok: true,
        sent: 0,
        reason: "no_recipient",
        sender_id: senderId,
        sender_vault_id: senderVaultId,
      }),
      {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }

  // Build candidate recipient users.
  // We include the direct recipient id and all known users that can access the
  // recipient vault (owner + shared access) to handle account re-installs.
  const candidateUserIds = new Set<string>();
  if (recipientId) {
    candidateUserIds.add(recipientId);
  }

  if (recipientVaultId) {
    const { data: vaultOwner } = await supabase
      .from("vaults")
      .select("user_id")
      .eq("id", recipientVaultId)
      .maybeSingle();

    const ownerUserId = (vaultOwner?.user_id ?? "").toString().trim();
    if (ownerUserId) {
      candidateUserIds.add(ownerUserId);
    }

    const { data: vaultAccessRows } = await supabase
      .from("vault_access")
      .select("user_id")
      .eq("vault_id", recipientVaultId);

    for (const row of vaultAccessRows ?? []) {
      const accessUserId = (row.user_id ?? "").toString().trim();
      if (accessUserId) {
        candidateUserIds.add(accessUserId);
      }
    }
  }

  // Never notify the sender's own account.
  candidateUserIds.delete(senderId);
  const targetUserIds = Array.from(candidateUserIds);

  if (targetUserIds.length === 0) {
    return new Response(
      JSON.stringify({
        ok: true,
        sent: 0,
        reason: "no_recipient_candidates",
        recipient_id: recipientId,
        recipient_vault_id: recipientVaultId,
      }),
      {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }

  // Get recipient's enabled push tokens
  let tokens:
    | Array<{
        token: string;
        platform: string | null;
        vibration_enabled?: boolean | null;
      }>
    | null = null;
  let tokErr: { message?: string } | null = null;

  const withVibrationPref = await supabase
    .from("device_push_tokens")
    .select("token, platform, vibration_enabled")
    .in("user_id", targetUserIds)
    .eq("notifications_enabled", true);

  if (
    withVibrationPref.error &&
    (withVibrationPref.error.message ?? "").includes("vibration_enabled")
  ) {
    const fallbackTokens = await supabase
      .from("device_push_tokens")
      .select("token, platform")
      .in("user_id", targetUserIds)
      .eq("notifications_enabled", true);

    tokens = (fallbackTokens.data ?? []) as Array<{
      token: string;
      platform: string | null;
      vibration_enabled?: boolean | null;
    }>;
    tokErr = fallbackTokens.error;
  } else {
    tokens = (withVibrationPref.data ?? []) as Array<{
      token: string;
      platform: string | null;
      vibration_enabled?: boolean | null;
    }>;
    tokErr = withVibrationPref.error;
  }

  if (!tokens || tokens.length === 0) {
    return new Response(
      JSON.stringify({
        ok: true,
        sent: 0,
        reason: "no_tokens",
        recipient_id: recipientId,
        recipient_vault_id: recipientVaultId,
        candidate_user_ids: targetUserIds,
        token_error: tokErr?.message,
      }),
      {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }

  // Get FCM access token
  let serviceAccount: {
    client_email: string;
    private_key: string;
    token_uri: string;
    project_id: string;
  };
  try {
    serviceAccount = JSON.parse(firebaseJson);
  } catch {
    return new Response(
      JSON.stringify({ ok: false, error: "invalid_firebase_config" }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }

  let accessToken: string;
  try {
    accessToken = await getAccessToken(serviceAccount);
  } catch (e) {
    return new Response(
      JSON.stringify({
        ok: false,
        error: "fcm_auth_failed",
        detail: String(e),
      }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }

  const title = randomPick(FUN_TITLES);
  const messageBody = randomPick(FUN_BODIES);

  let sent = 0;
  let failed = 0;
  const errors: string[] = [];

  // Send to each token via FCM v1 API
  const fcmUrl = `https://fcm.googleapis.com/v1/projects/${serviceAccount.project_id}/messages:send`;

  for (const tokenRow of tokens) {
    const token = (tokenRow.token ?? "").trim();
    if (!token) continue;
    const platform = (tokenRow.platform ?? "").trim().toLowerCase();
    const vibrationEnabled = tokenRow.vibration_enabled !== false;
    const androidChannelId = vibrationEnabled
      ? ANDROID_CHANNEL_VIBRATE
      : ANDROID_CHANNEL_SILENT;

    const fcmPayload: Record<string, unknown> = {
      message: {
        token,
        notification: {
          title,
          body: messageBody,
        },
        data: {
          conversation_id: conversationId,
          click_action: "FLUTTER_NOTIFICATION_CLICK",
          title,
          body: messageBody,
        },
        ...(platform === "android"
          ? {
              android: {
                priority: "high",
                notification: {
                  channel_id: androidChannelId,
                  sound: "default",
                  default_vibrate_timings: vibrationEnabled,
                },
              },
            }
          : {}),
        ...(platform === "ios"
          ? {
              apns: {
                payload: {
                  aps: {
                    sound: "default",
                    badge: 1,
                  },
                },
              },
            }
          : {}),
      },
    };

    try {
      const res = await fetch(fcmUrl, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(fcmPayload),
      });

      if (res.ok) {
        sent++;
      } else {
        failed++;
        const errText = await res.text();
        errors.push(
          `token=${token.slice(0, 12)}... status=${res.status} err=${errText.slice(0, 300)}`
        );

        // Auto-cleanup: remove unregistered/invalid tokens from DB
        if (errText.includes("UNREGISTERED") || errText.includes("INVALID_ARGUMENT")) {
          try {
            await supabase
              .from("device_push_tokens")
              .delete()
              .eq("token", token);
          } catch (_) { /* best effort */ }
        }
      }
    } catch (e) {
      failed++;
      errors.push(`token=${token.slice(0, 12)}... exception=${String(e)}`);
    }
  }

  return new Response(
    JSON.stringify({ ok: true, sent, failed, total: tokens.length, errors }),
    {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    }
  );
});
