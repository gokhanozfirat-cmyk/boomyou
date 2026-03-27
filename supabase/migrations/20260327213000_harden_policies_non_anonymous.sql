-- Harden RLS policies against anonymous auth sessions.

drop function if exists public.is_non_anonymous_user();
create or replace function public.is_non_anonymous_user()
returns boolean
language sql
stable
as $$
  select auth.uid() is not null
    and coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) = false;
$$;

grant execute on function public.is_non_anonymous_user() to anon, authenticated;

-- user_profiles
drop policy if exists "user_profiles: owner read" on public.user_profiles;
create policy "user_profiles: owner read"
  on public.user_profiles for select
  to authenticated
  using (public.is_non_anonymous_user() and auth.uid() = id);

drop policy if exists "user_profiles: owner insert" on public.user_profiles;
create policy "user_profiles: owner insert"
  on public.user_profiles for insert
  to authenticated
  with check (public.is_non_anonymous_user() and auth.uid() = id);

drop policy if exists "user_profiles: owner update" on public.user_profiles;
create policy "user_profiles: owner update"
  on public.user_profiles for update
  to authenticated
  using (public.is_non_anonymous_user() and auth.uid() = id)
  with check (public.is_non_anonymous_user() and auth.uid() = id);

drop policy if exists "user_profiles: rumus readable by all" on public.user_profiles;
create policy "user_profiles: rumus readable by all"
  on public.user_profiles for select
  to authenticated
  using (public.is_non_anonymous_user());

-- vault_access
drop policy if exists "vault_access: owner read" on public.vault_access;
create policy "vault_access: owner read"
  on public.vault_access for select
  to authenticated
  using (public.is_non_anonymous_user() and auth.uid() = user_id);

drop policy if exists "vault_access: owner insert" on public.vault_access;
create policy "vault_access: owner insert"
  on public.vault_access for insert
  to authenticated
  with check (public.is_non_anonymous_user() and auth.uid() = user_id);

drop policy if exists "vault_access: owner delete" on public.vault_access;
create policy "vault_access: owner delete"
  on public.vault_access for delete
  to authenticated
  using (public.is_non_anonymous_user() and auth.uid() = user_id);

-- vaults
drop policy if exists "vaults: owner read" on public.vaults;
create policy "vaults: owner read"
  on public.vaults for select
  to authenticated
  using (
    public.is_non_anonymous_user()
    and (
      auth.uid() = user_id
      or exists (
        select 1
        from public.vault_access va
        where va.vault_id = vaults.id
          and va.user_id = auth.uid()
      )
    )
  );

drop policy if exists "vaults: owner insert" on public.vaults;
create policy "vaults: owner insert"
  on public.vaults for insert
  to authenticated
  with check (public.is_non_anonymous_user() and auth.uid() = user_id);

drop policy if exists "vaults: owner update" on public.vaults;
create policy "vaults: owner update"
  on public.vaults for update
  to authenticated
  using (public.is_non_anonymous_user() and auth.uid() = user_id)
  with check (public.is_non_anonymous_user() and auth.uid() = user_id);

drop policy if exists "vaults: owner delete" on public.vaults;
create policy "vaults: owner delete"
  on public.vaults for delete
  to authenticated
  using (public.is_non_anonymous_user() and auth.uid() = user_id);

-- conversations
drop policy if exists "conversations: participants read" on public.conversations;
create policy "conversations: participants read"
  on public.conversations for select
  to authenticated
  using (
    public.is_non_anonymous_user()
    and (auth.uid() = initiator_id or auth.uid() = participant_id)
  );

drop policy if exists "conversations: initiator insert" on public.conversations;
create policy "conversations: initiator insert"
  on public.conversations for insert
  to authenticated
  with check (
    public.is_non_anonymous_user()
    and (auth.uid() = initiator_id or auth.uid() = participant_id)
  );

drop policy if exists "conversations: participants update" on public.conversations;
create policy "conversations: participants update"
  on public.conversations for update
  to authenticated
  using (
    public.is_non_anonymous_user()
    and (auth.uid() = initiator_id or auth.uid() = participant_id)
  )
  with check (
    public.is_non_anonymous_user()
    and (auth.uid() = initiator_id or auth.uid() = participant_id)
  );

-- messages
drop policy if exists "messages: participants read" on public.messages;
create policy "messages: participants read"
  on public.messages for select
  to authenticated
  using (
    public.is_non_anonymous_user()
    and exists (
      select 1 from public.conversations c
      where c.id = messages.conversation_id
        and (c.initiator_id = auth.uid() or c.participant_id = auth.uid())
    )
  );

drop policy if exists "messages: sender insert" on public.messages;
create policy "messages: sender insert"
  on public.messages for insert
  to authenticated
  with check (
    public.is_non_anonymous_user()
    and auth.uid() = sender_id
    and (
      sender_vault_id is null
      or exists (
        select 1 from public.conversations c
        where c.id = messages.conversation_id
          and (
            c.initiator_vault_id = sender_vault_id
            or c.participant_vault_id = sender_vault_id
          )
      )
    )
    and exists (
      select 1 from public.conversations c
      where c.id = messages.conversation_id
        and (c.initiator_id = auth.uid() or c.participant_id = auth.uid())
    )
  );

-- one_time_photo_archive
drop policy if exists "one_time_photo_archive: participants read" on public.one_time_photo_archive;
create policy "one_time_photo_archive: participants read"
  on public.one_time_photo_archive for select
  to authenticated
  using (
    public.is_non_anonymous_user()
    and exists (
      select 1 from public.conversations c
      where c.id = one_time_photo_archive.conversation_id
        and (c.initiator_id = auth.uid() or c.participant_id = auth.uid())
    )
  );

-- message_archive
drop policy if exists "message_archive: participants read" on public.message_archive;
create policy "message_archive: participants read"
  on public.message_archive for select
  to authenticated
  using (
    public.is_non_anonymous_user()
    and exists (
      select 1 from public.conversations c
      where c.id = message_archive.conversation_id
        and (c.initiator_id = auth.uid() or c.participant_id = auth.uid())
    )
  );

-- conversation_reads
drop policy if exists "conversation_reads: owner read" on public.conversation_reads;
create policy "conversation_reads: owner read"
  on public.conversation_reads for select
  to authenticated
  using (
    public.is_non_anonymous_user()
    and auth.uid() = user_id
    and exists (
      select 1
      from public.conversations c
      where c.id = conversation_reads.conversation_id
        and (c.initiator_id = auth.uid() or c.participant_id = auth.uid())
        and (
          c.initiator_vault_id = conversation_reads.vault_id
          or c.participant_vault_id = conversation_reads.vault_id
        )
    )
  );

drop policy if exists "conversation_reads: owner upsert" on public.conversation_reads;
create policy "conversation_reads: owner upsert"
  on public.conversation_reads for insert
  to authenticated
  with check (
    public.is_non_anonymous_user()
    and auth.uid() = user_id
    and exists (
      select 1
      from public.conversations c
      where c.id = conversation_reads.conversation_id
        and (c.initiator_id = auth.uid() or c.participant_id = auth.uid())
        and (
          c.initiator_vault_id = conversation_reads.vault_id
          or c.participant_vault_id = conversation_reads.vault_id
        )
    )
  );

drop policy if exists "conversation_reads: owner update" on public.conversation_reads;
create policy "conversation_reads: owner update"
  on public.conversation_reads for update
  to authenticated
  using (public.is_non_anonymous_user() and auth.uid() = user_id)
  with check (public.is_non_anonymous_user() and auth.uid() = user_id);

-- device_push_tokens
drop policy if exists "device_push_tokens: owner read" on public.device_push_tokens;
create policy "device_push_tokens: owner read"
  on public.device_push_tokens for select
  to authenticated
  using (public.is_non_anonymous_user() and auth.uid() = user_id);

drop policy if exists "device_push_tokens: owner insert" on public.device_push_tokens;
create policy "device_push_tokens: owner insert"
  on public.device_push_tokens for insert
  to authenticated
  with check (public.is_non_anonymous_user() and auth.uid() = user_id);

drop policy if exists "device_push_tokens: owner update" on public.device_push_tokens;
create policy "device_push_tokens: owner update"
  on public.device_push_tokens for update
  to authenticated
  using (public.is_non_anonymous_user() and auth.uid() = user_id)
  with check (public.is_non_anonymous_user() and auth.uid() = user_id);

drop policy if exists "device_push_tokens: owner delete" on public.device_push_tokens;
create policy "device_push_tokens: owner delete"
  on public.device_push_tokens for delete
  to authenticated
  using (public.is_non_anonymous_user() and auth.uid() = user_id);

-- invites
drop policy if exists "invites: sender insert" on public.invites;
create policy "invites: sender insert"
  on public.invites for insert
  to authenticated
  with check (public.is_non_anonymous_user() and auth.uid() = from_user_id);

drop policy if exists "invites: sender read" on public.invites;
create policy "invites: sender read"
  on public.invites for select
  to authenticated
  using (public.is_non_anonymous_user() and auth.uid() = from_user_id);

drop policy if exists "invites: recipient read" on public.invites;
create policy "invites: recipient read"
  on public.invites for select
  to authenticated
  using (
    public.is_non_anonymous_user()
    and (
      to_rumus in (
        select v.rumus
        from public.vaults v
        where v.user_id = auth.uid()
          and v.rumus is not null
      )
      or to_rumus = (
        select rumus from public.user_profiles
        where id = auth.uid()
      )
    )
  );

drop policy if exists "invites: parties update" on public.invites;
create policy "invites: parties update"
  on public.invites for update
  to authenticated
  using (
    public.is_non_anonymous_user()
    and (
      auth.uid() = from_user_id or
      to_rumus in (
        select v.rumus
        from public.vaults v
        where v.user_id = auth.uid()
          and v.rumus is not null
      )
      or to_rumus = (
        select rumus from public.user_profiles
        where id = auth.uid()
      )
    )
  )
  with check (
    public.is_non_anonymous_user()
    and (
      auth.uid() = from_user_id or
      to_rumus in (
        select v.rumus
        from public.vaults v
        where v.user_id = auth.uid()
          and v.rumus is not null
      )
      or to_rumus = (
        select rumus from public.user_profiles
        where id = auth.uid()
      )
    )
  );

-- storage.objects (chat_attachments)
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
    )
  );

drop policy if exists "chat_attachments: owner insert" on storage.objects;
create policy "chat_attachments: owner insert"
  on storage.objects for insert
  to authenticated
  with check (
    public.is_non_anonymous_user()
    and bucket_id = 'chat_attachments'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "chat_attachments: owner update" on storage.objects;
create policy "chat_attachments: owner update"
  on storage.objects for update
  to authenticated
  using (
    public.is_non_anonymous_user()
    and bucket_id = 'chat_attachments'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    public.is_non_anonymous_user()
    and bucket_id = 'chat_attachments'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "chat_attachments: owner delete" on storage.objects;
create policy "chat_attachments: owner delete"
  on storage.objects for delete
  to authenticated
  using (
    public.is_non_anonymous_user()
    and bucket_id = 'chat_attachments'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
