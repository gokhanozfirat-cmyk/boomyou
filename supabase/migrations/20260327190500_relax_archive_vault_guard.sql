-- Relax archive guard for legacy/mixed vault conversations.
-- Some old conversations may have null vault columns; authenticated participants
-- should still be allowed to archive expired read messages.

drop function if exists public.archive_expired_read_messages(uuid, uuid, timestamptz);
create or replace function public.archive_expired_read_messages(
  input_conversation_id uuid,
  input_vault_id uuid,
  input_read_before timestamptz
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  deleted_count integer := 0;
begin
  caller := auth.uid();
  if caller is null then
    raise exception 'not_authenticated';
  end if;

  if input_conversation_id is null
     or input_read_before is null then
    return 0;
  end if;

  if not exists (
    select 1
    from public.conversations c
    where c.id = input_conversation_id
      and (
        (
          c.initiator_id = caller
          and (
            c.initiator_vault_id is null
            or input_vault_id is null
            or c.initiator_vault_id = input_vault_id
          )
        )
        or (
          c.participant_id = caller
          and (
            c.participant_vault_id is null
            or input_vault_id is null
            or c.participant_vault_id = input_vault_id
          )
        )
      )
  ) then
    raise exception 'forbidden';
  end if;

  with candidates as (
    select
      m.id,
      m.conversation_id,
      m.sender_id,
      m.sender_vault_id,
      m.content,
      m.created_at
    from public.messages m
    where m.conversation_id = input_conversation_id
      and m.created_at <= input_read_before
  ),
  archived as (
    insert into public.message_archive (
      source_message_id,
      conversation_id,
      sender_id,
      sender_vault_id,
      content,
      created_at,
      archived_at,
      archived_by_user_id,
      archived_reason
    )
    select
      c.id,
      c.conversation_id,
      c.sender_id,
      c.sender_vault_id,
      c.content,
      c.created_at,
      now(),
      caller,
      'read_expired_1h'
    from candidates c
    on conflict (source_message_id) do nothing
    returning source_message_id
  ),
  deleted as (
    delete from public.messages m
    using candidates c
    where m.id = c.id
    returning m.id
  )
  select count(*)::integer
    into deleted_count
  from deleted;

  return coalesce(deleted_count, 0);
end;
$$;

grant execute on function public.archive_expired_read_messages(uuid, uuid, timestamptz) to authenticated;
