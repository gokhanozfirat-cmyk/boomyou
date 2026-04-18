create or replace function public.debug_storage_info()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  result jsonb;
begin
  select jsonb_build_object(
    'total_objects', (select count(*) from storage.objects where bucket_id = 'chat_attachments'),
    'sample_objects', (
      select jsonb_agg(jsonb_build_object(
        'name', o.name,
        'folder', (storage.foldername(o.name))[1],
        'created_at', o.created_at
      ))
      from (select * from storage.objects where bucket_id = 'chat_attachments' order by created_at desc limit 5) o
    ),
    'recent_image_messages', (
      select jsonb_agg(jsonb_build_object(
        'msg_id', m.id,
        'sender_id', m.sender_id,
        'conv_id', m.conversation_id,
        'content_start', left(m.content, 200)
      ))
      from (
        select * from public.messages
        where content like '%__boomyou_payload_v1__%'
          and content like '%image%'
        order by created_at desc limit 5
      ) m
    ),
    'conversations_for_senders', (
      select jsonb_agg(jsonb_build_object(
        'conv_id', c.id,
        'initiator', c.initiator_id,
        'participant', c.participant_id
      ))
      from public.conversations c
      where c.initiator_id = '798aad19-ec94-449f-b928-94d07bc94902'
         or c.participant_id = '798aad19-ec94-449f-b928-94d07bc94902'
         or c.initiator_id = '8c06f021-1884-4d81-b3a8-574a53268859'
         or c.participant_id = '8c06f021-1884-4d81-b3a8-574a53268859'
    )
  ) into result;
  return result;
end;
$$;
grant execute on function public.debug_storage_info() to anon, authenticated;
