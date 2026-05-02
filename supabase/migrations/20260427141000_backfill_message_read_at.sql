-- Backfill read_at for messages that were already read before read_at existed.
-- This lets the server-side archive job pick up older stuck messages.

update public.messages m
set read_at = (
  select min(cr.last_read_at)
  from public.conversations c
  join public.conversation_reads cr
    on cr.conversation_id = c.id
  where c.id = m.conversation_id
    and cr.last_read_at >= m.created_at
    and (
      (
        m.sender_vault_id is not null
        and m.sender_vault_id = c.initiator_vault_id
        and cr.vault_id = c.participant_vault_id
      )
      or (
        m.sender_vault_id is not null
        and m.sender_vault_id = c.participant_vault_id
        and cr.vault_id = c.initiator_vault_id
      )
      or (
        m.sender_vault_id is null
        and m.sender_id = c.initiator_id
        and cr.vault_id = c.participant_vault_id
      )
      or (
        m.sender_vault_id is null
        and m.sender_id = c.participant_id
        and cr.vault_id = c.initiator_vault_id
      )
    )
)
where m.read_at is null
  and exists (
    select 1
    from public.conversations c
    join public.conversation_reads cr
      on cr.conversation_id = c.id
    where c.id = m.conversation_id
      and cr.last_read_at >= m.created_at
      and (
        (
          m.sender_vault_id is not null
          and m.sender_vault_id = c.initiator_vault_id
          and cr.vault_id = c.participant_vault_id
        )
        or (
          m.sender_vault_id is not null
          and m.sender_vault_id = c.participant_vault_id
          and cr.vault_id = c.initiator_vault_id
        )
        or (
          m.sender_vault_id is null
          and m.sender_id = c.initiator_id
          and cr.vault_id = c.participant_vault_id
        )
        or (
          m.sender_vault_id is null
          and m.sender_id = c.participant_id
          and cr.vault_id = c.initiator_vault_id
        )
      )
  );

select public.archive_due_read_messages();
