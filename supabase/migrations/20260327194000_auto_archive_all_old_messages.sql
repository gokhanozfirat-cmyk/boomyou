-- Auto-archive all messages older than 1 hour globally.
-- 1) Backfill existing old messages now.
-- 2) Keep running automatically on every new insert.

create table if not exists public.message_archive (
  source_message_id uuid primary key,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid references auth.users(id) on delete set null,
  sender_vault_id uuid references public.vaults(id) on delete set null,
  content text not null,
  created_at timestamptz not null,
  archived_at timestamptz not null default now(),
  archived_by_user_id uuid references auth.users(id) on delete set null,
  archived_reason text not null default 'opened_one_time'
);

alter table public.message_archive enable row level security;

drop policy if exists "message_archive: participants read" on public.message_archive;
create policy "message_archive: participants read"
  on public.message_archive for select
  using (
    exists (
      select 1
      from public.conversations c
      where c.id = message_archive.conversation_id
        and (c.initiator_id = auth.uid() or c.participant_id = auth.uid())
    )
  );

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
    where m.created_at <= cutoff_at
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
      'auto_expired_1h'
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

drop function if exists public.trigger_archive_old_messages();
create or replace function public.trigger_archive_old_messages()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.archive_messages_older_than_one_hour();
  return null;
end;
$$;

drop trigger if exists trg_archive_old_messages_on_insert on public.messages;
create trigger trg_archive_old_messages_on_insert
after insert on public.messages
for each statement
execute function public.trigger_archive_old_messages();

-- Backfill existing rows older than 1 hour immediately.
select public.archive_messages_older_than_one_hour();

create index if not exists idx_message_archive_conversation on public.message_archive(conversation_id);
create index if not exists idx_message_archive_archived_at on public.message_archive(archived_at);
