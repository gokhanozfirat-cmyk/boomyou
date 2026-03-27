-- Make one-time photo matcher tolerant to payload variants/spaces.

drop function if exists public.archive_one_time_message(uuid);
create or replace function public.archive_one_time_message(input_message_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  msg_row public.messages%rowtype;
begin
  caller := auth.uid();
  if caller is null then
    raise exception 'not_authenticated';
  end if;

  if exists (
    select 1
    from public.one_time_photo_archive otp
    where otp.source_message_id = input_message_id
  ) then
    return true;
  end if;

  if exists (
    select 1
    from public.message_archive ma
    where ma.source_message_id = input_message_id
  ) then
    return true;
  end if;

  select m.*
    into msg_row
  from public.messages m
  join public.conversations c on c.id = m.conversation_id
  where m.id = input_message_id
    and (c.initiator_id = caller or c.participant_id = caller)
    and (
      m.content ~ '"oneTime"[[:space:]]*:[[:space:]]*true'
      or m.content ~ '"one_time"[[:space:]]*:[[:space:]]*true'
    )
    and (
      m.content ~ '"type"[[:space:]]*:[[:space:]]*"image"'
      or m.content ~ '"kind"[[:space:]]*:[[:space:]]*"image"'
      or m.content ~ '"mimeType"[[:space:]]*:[[:space:]]*"image/'
      or m.content ~ '"mime_type"[[:space:]]*:[[:space:]]*"image/'
    )
  limit 1;

  if not found then
    return false;
  end if;

  insert into public.one_time_photo_archive (
    source_message_id,
    conversation_id,
    sender_id,
    sender_vault_id,
    content,
    created_at,
    opened_at,
    opened_by_user_id
  )
  values (
    msg_row.id,
    msg_row.conversation_id,
    msg_row.sender_id,
    msg_row.sender_vault_id,
    msg_row.content,
    msg_row.created_at,
    now(),
    caller
  )
  on conflict (source_message_id) do nothing;

  delete from public.messages
  where id = msg_row.id;

  return true;
end;
$$;

grant execute on function public.archive_one_time_message(uuid) to authenticated;
