-- Include sender_vault_id in push payload so edge function can resolve
-- recipient correctly for vault-based access sessions.
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
  begin
    select decrypted_secret into svc_key
    from vault.decrypted_secrets
    where name = 'supabase_service_role_key'
    limit 1;
  exception when others then
    svc_key := null;
  end;

  if svc_key is null or svc_key = '' then
    svc_key := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InB6eGtqamRod3lwZWR3eGt3cnhvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQzNzE5MzgsImV4cCI6MjA4OTk0NzkzOH0.DNGmT0K8zSujrW4JPoNqtBCMbXaS7eZFNuMPUqlYxfA';
  end if;

  payload := jsonb_build_object(
    'conversation_id', NEW.conversation_id,
    'sender_id', NEW.sender_id,
    'sender_vault_id', NEW.sender_vault_id
  );

  perform net.http_post(
    url     := edge_url,
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || svc_key
    ),
    body    := payload
  );

  return NEW;
exception
  when others then
    raise warning 'push notification trigger failed: %', SQLERRM;
    return NEW;
end;
$$;
