-- Archive read messages on the server even when no chat screen is open.
-- A message becomes eligible one hour after its recipient first read it.

alter table public.messages add column if not exists read_at timestamptz;
create index if not exists idx_messages_read_at on public.messages(read_at);

create or replace function public.archive_due_read_messages()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  deleted_count integer := 0;
begin
  with candidates as (
    select
      m.id,
      m.conversation_id,
      m.sender_id,
      m.sender_vault_id,
      m.content,
      m.created_at
    from public.messages m
    where m.read_at is not null
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
      null,
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

grant execute on function public.archive_due_read_messages() to authenticated;

create extension if not exists pg_cron with schema extensions;

do $$
declare
  existing_job_id bigint;
begin
  for existing_job_id in
    select jobid
    from cron.job
    where jobname = 'archive_due_read_messages_every_minute'
  loop
    perform cron.unschedule(existing_job_id);
  end loop;
end;
$$;

select cron.schedule(
  'archive_due_read_messages_every_minute',
  '* * * * *',
  $cron$select public.archive_due_read_messages();$cron$
);
