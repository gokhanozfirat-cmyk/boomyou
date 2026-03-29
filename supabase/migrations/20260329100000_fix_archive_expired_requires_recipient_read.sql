-- Fix archive_expired_read_messages: only archive messages that the RECIPIENT
-- has actually read. Previously it archived any message older than the caller's
-- own last_read_at, which caused unread messages to disappear.

drop function if exists public.archive_expired_read_messages(uuid, uuid, timestamptz);
create or replace function public.archive_expired_read_messages(
  input_conversation_id uuid,
  input_vault_id        uuid,
  input_read_before     timestamptz
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  caller              uuid;
  caller_vault_id     uuid;
  effective_vault_id  uuid;
  server_last_read_at timestamptz;
  cutoff_at           timestamptz;
  deleted_count       integer := 0;
  conv                record;
  other_vault_id      uuid;
  other_last_read_at  timestamptz;
begin
  caller := auth.uid();
  if caller is null then
    raise exception 'not_authenticated';
  end if;

  if input_conversation_id is null then
    return 0;
  end if;

  -- Resolve caller's vault and the other party's vault.
  select
    c.initiator_id,
    c.participant_id,
    c.initiator_vault_id,
    c.participant_vault_id
  into conv
  from public.conversations c
  where c.id = input_conversation_id;

  if not found then
    raise exception 'forbidden';
  end if;

  if conv.initiator_id = caller then
    caller_vault_id := conv.initiator_vault_id;
    other_vault_id  := conv.participant_vault_id;
  elsif conv.participant_id = caller then
    caller_vault_id := conv.participant_vault_id;
    other_vault_id  := conv.initiator_vault_id;
  else
    raise exception 'forbidden';
  end if;

  if input_vault_id is not null
     and caller_vault_id is not null
     and input_vault_id <> caller_vault_id then
    raise exception 'forbidden';
  end if;

  effective_vault_id := coalesce(input_vault_id, caller_vault_id);
  if effective_vault_id is null then
    return 0;
  end if;

  -- Caller must have a read marker (they opened the conversation).
  select cr.last_read_at
    into server_last_read_at
  from public.conversation_reads cr
  where cr.conversation_id = input_conversation_id
    and cr.vault_id = effective_vault_id
    and cr.user_id = caller;

  if server_last_read_at is null then
    return 0;
  end if;

  -- Other party's read marker (may be null if they never opened).
  select cr.last_read_at
    into other_last_read_at
  from public.conversation_reads cr
  where cr.conversation_id = input_conversation_id
    and cr.vault_id = other_vault_id
  limit 1;

  cutoff_at := least(server_last_read_at, now() - interval '1 hour');
  if input_read_before is not null then
    cutoff_at := least(cutoff_at, input_read_before);
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
      and m.created_at <= cutoff_at
      and (
        -- Message sent by the CALLER: archive only if the other party has read it.
        (
          m.sender_vault_id = effective_vault_id
          and other_last_read_at is not null
          and other_last_read_at >= m.created_at
        )
        or
        -- Message sent by the OTHER party: archive only if the CALLER has read it.
        (
          m.sender_vault_id <> effective_vault_id
          and server_last_read_at >= m.created_at
        )
        or
        -- Legacy rows without sender_vault_id: require both sides to have read.
        (
          m.sender_vault_id is null
          and server_last_read_at >= m.created_at
          and other_last_read_at is not null
          and other_last_read_at >= m.created_at
        )
      )
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
