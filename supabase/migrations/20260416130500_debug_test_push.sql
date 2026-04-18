-- Debug: get a real conversation for testing push
create or replace function public.debug_get_test_data()
returns jsonb
language sql
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'conversation', (
      select jsonb_build_object('id', c.id, 'initiator_id', c.initiator_id, 'participant_id', c.participant_id)
      from public.conversations c limit 1
    ),
    'token_count', (select count(*) from public.device_push_tokens where notifications_enabled = true),
    'token_users', (
      select jsonb_agg(jsonb_build_object('user_id', d.user_id, 'platform', d.platform))
      from public.device_push_tokens d where notifications_enabled = true
    )
  );
$$;
grant execute on function public.debug_get_test_data() to anon, authenticated;
