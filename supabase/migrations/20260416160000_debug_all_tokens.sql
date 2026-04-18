create or replace function public.debug_all_tokens()
returns jsonb
language sql
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'enabled_count', (select count(*) from device_push_tokens where notifications_enabled = true),
    'disabled_count', (select count(*) from device_push_tokens where notifications_enabled = false),
    'total_count', (select count(*) from device_push_tokens),
    'all_tokens', (
      select jsonb_agg(jsonb_build_object(
        'user_id', d.user_id,
        'platform', d.platform,
        'enabled', d.notifications_enabled,
        'updated', d.updated_at,
        'token_start', left(d.token, 12)
      ) order by d.updated_at desc)
      from device_push_tokens d
    ),
    'total_auth_users', (select count(*) from auth.users)
  );
$$;
grant execute on function public.debug_all_tokens() to anon, authenticated;
