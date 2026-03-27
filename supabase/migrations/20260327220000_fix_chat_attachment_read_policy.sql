-- Fix attachment read policy so archived one-time/expired messages can still
-- authorize signed URL creation for conversation participants.

drop policy if exists "chat_attachments: participants read" on storage.objects;
create policy "chat_attachments: participants read"
  on storage.objects for select
  to authenticated
  using (
    public.is_non_anonymous_user()
    and bucket_id = 'chat_attachments'
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
      or exists (
        select 1
        from public.one_time_photo_archive otp
        join public.conversations c on c.id = otp.conversation_id
        where (c.initiator_id = auth.uid() or c.participant_id = auth.uid())
          and (
            position('"path":"' || name || '"' in otp.content) > 0
            or position('/chat_attachments/' || name in otp.content) > 0
          )
      )
      or exists (
        select 1
        from public.message_archive ma
        join public.conversations c on c.id = ma.conversation_id
        where (c.initiator_id = auth.uid() or c.participant_id = auth.uid())
          and (
            position('"path":"' || name || '"' in ma.content) > 0
            or position('/chat_attachments/' || name in ma.content) > 0
          )
      )
    )
  );
