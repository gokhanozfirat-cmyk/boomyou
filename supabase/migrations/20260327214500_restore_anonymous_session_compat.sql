-- Restore BoomYou auth compatibility:
-- The app initializes with signInAnonymously(), so policy guard must allow
-- authenticated anonymous sessions too.

create or replace function public.is_non_anonymous_user()
returns boolean
language sql
stable
as $$
  select auth.uid() is not null;
$$;

grant execute on function public.is_non_anonymous_user() to anon, authenticated;
