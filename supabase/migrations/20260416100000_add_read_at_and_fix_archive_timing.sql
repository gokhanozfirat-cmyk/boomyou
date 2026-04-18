-- Add read_at column to messages: tracks when the RECIPIENT first read each message.
-- Archive logic will use (read_at + 1 hour) instead of (created_at + 1 hour).

-- 1) Add the column
alter table public.messages add column if not exists read_at timestamptz;
create index if not exists idx_messages_read_at on public.messages(read_at);

-- 2) RPC to stamp read_at on unread messages from the other party.
--    Called when a user opens a conversation (marks it as "read").
drop function if exists public.mark_messages_read_at(uuid, uuid);
create or replace function public.mark_messages_read_at(
  input_conversation_id uuid,
  input_reader_vault_id uuid
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  updated_count integer := 0;
begin
  caller := auth.uid();
  if caller is null then
    raise exception 'not_authenticated';
  end if;

  if input_conversation_id is null or input_reader_vault_id is null then
    return 0;
  end if;

  -- Verify caller belongs to this conversation
  if not exists (
    select 1 from public.conversations c
    where c.id = input_conversation_id
      and (c.initiator_id = caller or c.participant_id = caller)
  ) then
    raise exception 'forbidden';
  end if;

  -- Stamp read_at = now() on messages NOT sent by the reader (i.e., from the other party)
  -- Only where read_at is still NULL (first read only).
  update public.messages
  set read_at = now()
  where conversation_id = input_conversation_id
    and read_at is null
    and (
      sender_vault_id is distinct from input_reader_vault_id
      or (sender_vault_id is null and sender_id <> caller)
    );

  get diagnostics updated_count = row_count;
  return coalesce(updated_count, 0);
end;
$$;

grant execute on function public.mark_messages_read_at(uuid, uuid) to authenticated;

-- 3) Replace archive_expired_read_messages to use read_at + 1 hour.
drop function if exists public.archive_expired_read_messages(uuid, uuid, timestamptz);
create or replace function public.archive_expired_read_messages(
  input_conversation_id uuid,
  input_vault_id        uuid,
  input_read_before     timestamptz  -- kept for API compat, but now ignored in favor of read_at
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
  deleted_count       integer := 0;
  conv                record;
begin
  caller := auth.uid();
  if caller is null then
    raise exception 'not_authenticated';
  end if;

  if input_conversation_id is null then
    return 0;
  end if;

  -- Resolve caller's vault
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
  elsif conv.participant_id = caller then
    caller_vault_id := conv.participant_vault_id;
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

  -- Archive messages where:
  -- 1) read_at is set (recipient has read it)
  -- 2) read_at was at least 1 hour ago (enough time has passed)
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
      and m.read_at is not null
      and m.read_at <= (now() - interval '1 hour')
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

-- 4) Disable the old trigger that archives ALL messages older than 1 hour on insert.
--    This trigger used created_at which is wrong. The new logic handles it via read_at.
drop trigger if exists trg_archive_old_messages_on_insert on public.messages;
