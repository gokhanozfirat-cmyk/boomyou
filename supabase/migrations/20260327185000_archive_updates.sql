-- Archive updates:
-- 1) Move opened one-time photos out of messages into one_time_photo_archive
-- 2) Move read-expired messages (older than read cutoff) into message_archive

create table if not exists public.one_time_photo_archive (
  source_message_id uuid primary key,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid references auth.users(id) on delete set null,
  sender_vault_id uuid references public.vaults(id) on delete set null,
  content text not null,
  created_at timestamptz not null,
  opened_at timestamptz not null default now(),
  opened_by_user_id uuid references auth.users(id) on delete set null
);

alter table public.one_time_photo_archive enable row level security;

drop policy if exists "one_time_photo_archive: participants read" on public.one_time_photo_archive;
create policy "one_time_photo_archive: participants read"
  on public.one_time_photo_archive for select
  using (
    exists (
      select 1
      from public.conversations c
      where c.id = one_time_photo_archive.conversation_id
        and (c.initiator_id = auth.uid() or c.participant_id = auth.uid())
    )
  );

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
    and m.content like '__boomyou_payload_v1__%'
    and position('"oneTime":true' in m.content) > 0
    and position('"type":"image"' in m.content) > 0
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
     or input_vault_id is null
     or input_read_before is null then
    return 0;
  end if;

  if not exists (
    select 1
    from public.conversations c
    where c.id = input_conversation_id
      and (c.initiator_id = caller or c.participant_id = caller)
      and (
        c.initiator_vault_id = input_vault_id
        or c.participant_vault_id = input_vault_id
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

create index if not exists idx_one_time_photo_archive_conversation on public.one_time_photo_archive(conversation_id);
create index if not exists idx_one_time_photo_archive_opened_at on public.one_time_photo_archive(opened_at);
