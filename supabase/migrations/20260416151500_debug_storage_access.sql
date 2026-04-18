-- Test: can user 798aad19 access a file in folder 8c06f021?
create or replace function public.debug_test_storage_access()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  test_name text := '8c06f021-1884-4d81-b3a8-574a53268859/1776364378295_scaled_6128.jpg';
  test_user uuid := '798aad19-ec94-449f-b928-94d07bc94902'::uuid;
  folder text;
  obj_exists boolean;
  conv_match boolean;
begin
  folder := (storage.foldername(test_name))[1];
  obj_exists := exists(select 1 from storage.objects where bucket_id = 'chat_attachments' and name = test_name);
  conv_match := exists(
    select 1 from public.conversations c
    where (c.initiator_id = test_user or c.participant_id = test_user)
      and (c.initiator_id::text = folder or c.participant_id::text = folder)
  );

  return jsonb_build_object(
    'test_name', test_name,
    'folder_extracted', folder,
    'object_exists', obj_exists,
    'conversation_match', conv_match,
    'user_owns_folder', (folder = test_user::text),
    'should_have_access', (folder = test_user::text) or conv_match
  );
end;
$$;
grant execute on function public.debug_test_storage_access() to anon, authenticated;
