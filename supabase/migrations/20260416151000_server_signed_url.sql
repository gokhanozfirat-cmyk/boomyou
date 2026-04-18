-- Server-side signed URL generator that bypasses storage RLS.
-- The client calls this RPC with the file path, and gets back a signed URL.
-- Access control: caller must be a participant in a conversation where the file was shared.

create or replace function public.create_attachment_signed_url(
  input_path text,
  input_expires_in integer default 900
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  folder_owner text;
  signed jsonb;
begin
  caller := auth.uid();
  if caller is null then
    raise exception 'not_authenticated';
  end if;

  if input_path is null or input_path = '' then
    return null;
  end if;

  -- Extract the folder owner (first path component = user_id who uploaded)
  folder_owner := split_part(input_path, '/', 1);

  -- Check: caller owns the file OR shares a conversation with the uploader
  if folder_owner = caller::text then
    -- own file, allowed
    null;
  elsif exists (
    select 1 from public.conversations c
    where (c.initiator_id = caller or c.participant_id = caller)
      and (c.initiator_id::text = folder_owner or c.participant_id::text = folder_owner)
  ) then
    -- conversation partner's file, allowed
    null;
  else
    return null; -- not authorized
  end if;

  -- Create signed URL using storage admin API
  select content::jsonb into signed
  from extensions.http((
    'POST',
    current_setting('app.settings.supabase_url', true) || '/storage/v1/object/sign/chat_attachments/' || input_path,
    array[
      extensions.http_header('Authorization', 'Bearer ' || current_setting('supabase.service_role_key', true)),
      extensions.http_header('Content-Type', 'application/json')
    ],
    'application/json',
    '{"expiresIn":' || input_expires_in || '}'
  )::extensions.http_request);

  if signed is not null and signed->>'signedURL' is not null then
    return current_setting('app.settings.supabase_url', true) || '/storage/v1' || (signed->>'signedURL');
  end if;

  return null;
end;
$$;

grant execute on function public.create_attachment_signed_url(text, integer) to authenticated;
