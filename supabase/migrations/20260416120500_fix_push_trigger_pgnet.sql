-- Fix the push trigger to use correct pg_net function signature.
-- pg_net functions live in the 'net' schema on Supabase hosted.

create or replace function public.trigger_send_push_on_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  edge_url text := 'https://pzxkjjdhwypedwxkwrxo.supabase.co/functions/v1/send-message-push';
  svc_key  text;
  payload  jsonb;
begin
  -- Try to get service role key from Supabase vault/settings
  begin
    select decrypted_secret into svc_key
    from vault.decrypted_secrets
    where name = 'supabase_service_role_key'
    limit 1;
  exception when others then
    svc_key := null;
  end;

  -- Fallback: use the anon key (edge function uses its own service role internally)
  if svc_key is null or svc_key = '' then
    svc_key := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InB6eGtqamRod3lwZWR3eGt3cnhvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQzNzE5MzgsImV4cCI6MjA4OTk0NzkzOH0.DNGmT0K8zSujrW4JPoNqtBCMbXaS7eZFNuMPUqlYxfA';
  end if;

  payload := jsonb_build_object(
    'conversation_id', NEW.conversation_id,
    'sender_id',       NEW.sender_id
  );

  -- Use net.http_post (pg_net extension)
  perform net.http_post(
    url     := edge_url,
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || svc_key
    ),
    body    := payload::jsonb
  );

  return NEW;
exception
  when others then
    -- Never block message insert if push fails
    raise warning 'push notification trigger failed: %', SQLERRM;
    return NEW;
end;
$$;
