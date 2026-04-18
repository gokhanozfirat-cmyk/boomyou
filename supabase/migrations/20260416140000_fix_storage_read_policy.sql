-- Simplify chat_attachments read policy.
-- Old policy used fragile position() string matching on message content.
-- New policy: if the file's folder owner is in the same conversation as you, you can read it.

drop policy if exists "chat_attachments: participants read" on storage.objects;
create policy "chat_attachments: participants read"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'chat_attachments'
    and (
      -- Own folder: always readable
      (storage.foldername(name))[1] = auth.uid()::text
      -- Conversation partner's folder: readable if they share a conversation with you
      or exists (
        select 1
        from public.conversations c
        where (c.initiator_id = auth.uid() or c.participant_id = auth.uid())
          and (
            c.initiator_id::text = (storage.foldername(name))[1]
            or c.participant_id::text = (storage.foldername(name))[1]
          )
      )
    )
  );
