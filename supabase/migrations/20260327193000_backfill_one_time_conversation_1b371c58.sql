-- One-off backfill for conversation:
-- 1b371c58-fa5c-4ead-86c4-917361026a56
-- Move one-time image payload messages to one_time_photo_archive and
-- remove them from messages so they no longer reappear.

with candidates as (
  select
    m.id,
    m.conversation_id,
    m.sender_id,
    m.sender_vault_id,
    m.content,
    m.created_at
  from public.messages m
  where m.conversation_id = '1b371c58-fa5c-4ead-86c4-917361026a56'::uuid
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
),
archived as (
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
  select
    c.id,
    c.conversation_id,
    c.sender_id,
    c.sender_vault_id,
    c.content,
    c.created_at,
    now(),
    null
  from candidates c
  on conflict (source_message_id) do nothing
  returning source_message_id
)
delete from public.messages m
using candidates c
where m.id = c.id;
