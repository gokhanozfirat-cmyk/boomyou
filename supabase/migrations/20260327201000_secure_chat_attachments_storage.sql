-- Secure chat attachments storage
-- 1) Force bucket to private
-- 2) Use strict RLS policies for upload/read/update/delete

insert into storage.buckets (id, name, public)
values ('chat_attachments', 'chat_attachments', false)
on conflict (id) do update
set public = false;

drop policy if exists "chat_attachments: participants read" on storage.objects;
create policy "chat_attachments: participants read"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'chat_attachments'
    and (
      (storage.foldername(name))[1] = auth.uid()::text
      or exists (
        select 1
        from public.messages m
        join public.conversations c on c.id = m.conversation_id
        where (c.initiator_id = auth.uid() or c.participant_id = auth.uid())
          and (
            position('"path":"' || name || '"' in m.content) > 0
            or position('/chat_attachments/' || name in m.content) > 0
          )
      )
    )
  );

drop policy if exists "chat_attachments: owner insert" on storage.objects;
create policy "chat_attachments: owner insert"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'chat_attachments'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "chat_attachments: owner update" on storage.objects;
create policy "chat_attachments: owner update"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'chat_attachments'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'chat_attachments'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "chat_attachments: owner delete" on storage.objects;
create policy "chat_attachments: owner delete"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'chat_attachments'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
