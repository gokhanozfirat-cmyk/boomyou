-- Enable pg_net extension for making HTTP requests from PostgreSQL
create extension if not exists pg_net with schema extensions;

-- Trigger function: fires on every new message INSERT,
-- calls the send-message-push edge function automatically.
create or replace function public.trigger_send_push_on_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  edge_url  text;
  svc_key   text;
begin
  -- Build the edge function URL from project ref
  edge_url := rtrim(current_setting('app.settings.supabase_url', true), '/')
              || '/functions/v1/send-message-push';

  -- If app.settings is not configured, fall back to env-based URL
  if edge_url is null or edge_url = '' or edge_url = '/functions/v1/send-message-push' then
    edge_url := 'https://pzxkjjdhwypedwxkwrxo.supabase.co/functions/v1/send-message-push';
  end if;

  svc_key := coalesce(
    current_setting('app.settings.service_role_key', true),
    current_setting('supabase.service_role_key', true),
    ''
  );

  -- If we can't resolve service key from settings, use the anon key as fallback
  if svc_key = '' then
    svc_key := coalesce(
      current_setting('app.settings.supabase_anon_key', true),
      ''
    );
  end if;

  -- Fire-and-forget HTTP POST to the edge function
  perform extensions.http_post(
    url     := edge_url,
    body    := jsonb_build_object(
      'conversation_id', NEW.conversation_id,
      'sender_id',       NEW.sender_id
    ),
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || svc_key
    )
  );

  return NEW;
exception
  when others then
    -- Never block message insert if push fails
    raise warning 'push trigger failed: %', SQLERRM;
    return NEW;
end;
$$;

-- Attach trigger to messages table (AFTER INSERT, for each row)
drop trigger if exists trg_send_push_on_new_message on public.messages;
create trigger trg_send_push_on_new_message
  after insert on public.messages
  for each row
  execute function public.trigger_send_push_on_message();
