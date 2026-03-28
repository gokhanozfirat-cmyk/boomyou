-- Server-side guard for 6-digit game code attempts.
-- Lock cycle on each 5 consecutive failures:
-- 1st lock 10 minutes, 2nd lock 24 hours, then repeats.

create table if not exists public.vault_code_guard (
  user_id uuid primary key references auth.users(id) on delete cascade,
  failed_six_digit_attempts integer not null default 0,
  next_lock_is_long boolean not null default false,
  lockout_until timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint vault_code_guard_failed_non_negative check (failed_six_digit_attempts >= 0)
);

alter table public.vault_code_guard enable row level security;

drop function if exists public.check_vault_code_guarded(text);
create or replace function public.check_vault_code_guarded(input_code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  normalized_code text;
  hashed text;
  target_vault_id uuid;
  failed_count integer := 0;
  lock_until timestamptz;
  next_lock_long boolean := false;
  now_utc timestamptz := now();
  lock_duration interval;
begin
  caller := auth.uid();
  if caller is null then
    raise exception 'not_authenticated';
  end if;

  normalized_code := trim(coalesce(input_code, ''));
  if normalized_code !~ '^[0-9]{6}$' then
    return null;
  end if;

  select
    g.failed_six_digit_attempts,
    g.lockout_until,
    g.next_lock_is_long
  into
    failed_count,
    lock_until,
    next_lock_long
  from public.vault_code_guard g
  where g.user_id = caller
  for update;

  if not found then
    failed_count := 0;
    lock_until := null;
    next_lock_long := false;
  end if;

  if lock_until is not null and lock_until > now_utc then
    return null;
  end if;

  if lock_until is not null and lock_until <= now_utc then
    lock_until := null;
    failed_count := 0;
  end if;

  hashed := encode(digest(normalized_code, 'sha256'), 'hex');

  select v.id
    into target_vault_id
  from public.vaults v
  where v.user_id = caller
    and v.code_hash = hashed
  order by v.created_at desc
  limit 1;

  if target_vault_id is null then
    begin
      select va.vault_id
        into target_vault_id
      from public.vault_access va
      where va.user_id = caller
        and va.code_hash = hashed
      order by va.created_at desc
      limit 1;
    exception
      when undefined_table then
        target_vault_id := null;
    end;
  end if;

  if target_vault_id is not null then
    failed_count := 0;
    lock_until := null;
  else
    failed_count := failed_count + 1;
    if failed_count >= 5 then
      lock_duration := case
        when next_lock_long then interval '24 hours'
        else interval '10 minutes'
      end;
      lock_until := now_utc + lock_duration;
      failed_count := 0;
      next_lock_long := not next_lock_long;
    end if;
  end if;

  insert into public.vault_code_guard (
    user_id,
    failed_six_digit_attempts,
    next_lock_is_long,
    lockout_until,
    created_at,
    updated_at
  )
  values (
    caller,
    failed_count,
    next_lock_long,
    lock_until,
    now_utc,
    now_utc
  )
  on conflict (user_id) do update
    set failed_six_digit_attempts = excluded.failed_six_digit_attempts,
        next_lock_is_long = excluded.next_lock_is_long,
        lockout_until = excluded.lockout_until,
        updated_at = now_utc;

  return target_vault_id;
end;
$$;

grant execute on function public.check_vault_code_guarded(text) to authenticated;
