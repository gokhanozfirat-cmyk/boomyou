-- Guard archive_expired_read_messages with server-side read marker checks.
-- This prevents archiving unseen messages when client-side read timestamp is missing.

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
  caller_vault_id uuid;
  effective_vault_id uuid;
  server_last_read_at timestamptz;
  cutoff_at timestamptz;
  deleted_count integer := 0;
begin
  caller := auth.uid();
  if caller is null then
    raise exception 'not_authenticated';
  end if;

  if input_conversation_id is null then
    return 0;
  end if;

  select
    case
      when c.initiator_id = caller then c.initiator_vault_id
      when c.participant_id = caller then c.participant_vault_id
      else null
    end
  into caller_vault_id
  from public.conversations c
  where c.id = input_conversation_id;

  if not found then
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

  select cr.last_read_at
    into server_last_read_at
  from public.conversation_reads cr
  where cr.conversation_id = input_conversation_id
    and cr.vault_id = effective_vault_id
    and cr.user_id = caller;

  if server_last_read_at is null then
    return 0;
  end if;

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
