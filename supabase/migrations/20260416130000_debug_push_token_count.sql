-- Temporary diagnostic function to check push token count (no RLS needed)
create or replace function public.debug_push_token_count()
returns integer
language sql
security definer
set search_path = public
as $$
  select count(*)::integer from public.device_push_tokens where notifications_enabled = true;
$$;

grant execute on function public.debug_push_token_count() to anon, authenticated;
