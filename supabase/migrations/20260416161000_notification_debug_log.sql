create table if not exists public.notification_debug_log (
  id serial primary key,
  user_id uuid,
  step text not null,
  detail text,
  created_at timestamptz default now()
);

alter table public.notification_debug_log enable row level security;

drop policy if exists "notif_debug: insert" on public.notification_debug_log;
create policy "notif_debug: insert"
  on public.notification_debug_log for insert
  to authenticated
  with check (true);

drop policy if exists "notif_debug: read" on public.notification_debug_log;
create policy "notif_debug: read"
  on public.notification_debug_log for select
  to authenticated
  using (true);

create or replace function public.debug_notif_log()
returns jsonb
language sql
security definer
set search_path = public
as $$
  select coalesce(
    jsonb_agg(jsonb_build_object(
      'step', l.step,
      'detail', l.detail,
      'user_id', l.user_id,
      'at', l.created_at
    ) order by l.id desc),
    '[]'::jsonb
  )
  from (select * from notification_debug_log order by id desc limit 20) l;
$$;
grant execute on function public.debug_notif_log() to anon, authenticated;
