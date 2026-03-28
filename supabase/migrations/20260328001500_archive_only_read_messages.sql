-- Auto archive should only move messages that have been read.
-- If the message has not been seen by the other side, keep it in public.messages.

drop function if exists public.archive_messages_older_than_one_hour(timestamptz);
create or replace function public.archive_messages_older_than_one_hour(
  input_cutoff timestamptz default null
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  cutoff_at timestamptz;
  deleted_count integer := 0;
begin
  cutoff_at := coalesce(input_cutoff, now() - interval '1 hour');

  with candidates as (
    select
      m.id,
      m.conversation_id,
      m.sender_id,
      m.sender_vault_id,
      m.content,
      m.created_at
    from public.messages m
    join public.conversations c
      on c.id = m.conversation_id
    left join public.conversation_reads cr_initiator
      on cr_initiator.conversation_id = c.id
     and cr_initiator.vault_id = c.initiator_vault_id
    left join public.conversation_reads cr_participant
      on cr_participant.conversation_id = c.id
     and cr_participant.vault_id = c.participant_vault_id
    where m.created_at <= cutoff_at
      and (
        -- Message sent by initiator vault: archive only if participant read it.
        (
          m.sender_vault_id = c.initiator_vault_id
          and cr_participant.last_read_at is not null
          and cr_participant.last_read_at >= m.created_at
        )
        or
        -- Message sent by participant vault: archive only if initiator read it.
        (
          m.sender_vault_id = c.participant_vault_id
          and cr_initiator.last_read_at is not null
          and cr_initiator.last_read_at >= m.created_at
        )
        or
        -- Legacy rows without sender_vault_id: require both sides read.
        (
          m.sender_vault_id is null
          and cr_initiator.last_read_at is not null
          and cr_participant.last_read_at is not null
          and cr_initiator.last_read_at >= m.created_at
          and cr_participant.last_read_at >= m.created_at
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
      null,
      'auto_expired_1h_read_only'
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

grant execute on function public.archive_messages_older_than_one_hour(timestamptz) to authenticated;
