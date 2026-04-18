-- Debug: check if ANY conversation participant has a push token
create or replace function public.debug_push_match()
returns jsonb
language sql
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'total_conversations', (select count(*) from conversations),
    'total_tokens', (select count(*) from device_push_tokens where notifications_enabled = true),
    'conversations_with_tokens', (
      select count(distinct c.id)
      from conversations c
      where exists (
        select 1 from device_push_tokens d
        where d.notifications_enabled = true
          and (d.user_id = c.initiator_id or d.user_id = c.participant_id)
      )
    ),
    'sample_conversations', (
      select jsonb_agg(jsonb_build_object(
        'id', c.id,
        'initiator_id', c.initiator_id,
        'participant_id', c.participant_id,
        'initiator_has_token', exists(select 1 from device_push_tokens d where d.user_id = c.initiator_id and d.notifications_enabled = true),
        'participant_has_token', exists(select 1 from device_push_tokens d where d.user_id = c.participant_id and d.notifications_enabled = true)
      ))
      from (select * from conversations order by created_at desc limit 5) c
    )
  );
$$;
grant execute on function public.debug_push_match() to anon, authenticated;
