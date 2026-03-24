-- ============================================================
-- BoomYou Supabase Schema
-- Run this in the Supabase SQL Editor
-- ============================================================

-- Enable UUID extension
create extension if not exists "pgcrypto";

-- ============================================================
-- user_profiles
-- ============================================================
create table if not exists public.user_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  rumus text unique not null,
  created_at timestamptz not null default now()
);

alter table public.user_profiles enable row level security;

-- Users can read their own profile
drop policy if exists "user_profiles: owner read" on public.user_profiles;
create policy "user_profiles: owner read"
  on public.user_profiles for select
  using (auth.uid() = id);

-- Users can insert their own profile
drop policy if exists "user_profiles: owner insert" on public.user_profiles;
create policy "user_profiles: owner insert"
  on public.user_profiles for insert
  with check (auth.uid() = id);

-- Users can update their own profile
drop policy if exists "user_profiles: owner update" on public.user_profiles;
create policy "user_profiles: owner update"
  on public.user_profiles for update
  using (auth.uid() = id);

-- All authenticated users can read rumus (needed for invite search)
drop policy if exists "user_profiles: rumus readable by all" on public.user_profiles;
create policy "user_profiles: rumus readable by all"
  on public.user_profiles for select
  using (auth.role() = 'authenticated' or auth.role() = 'anon');

-- ============================================================
-- vaults
-- ============================================================
create table if not exists public.vaults (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  rumus text unique,
  code_hash text not null,
  is_setup boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.vaults add column if not exists rumus text;
do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'vaults_rumus_key'
  ) then
    alter table public.vaults add constraint vaults_rumus_key unique (rumus);
  end if;
end $$;

alter table public.vaults enable row level security;

-- ============================================================
-- vault_access (device/user authorization for existing areas)
-- ============================================================
create table if not exists public.vault_access (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  vault_id uuid not null references public.vaults(id) on delete cascade,
  code_hash text not null,
  created_at timestamptz not null default now(),
  constraint vault_access_user_vault_unique unique (user_id, vault_id)
);

alter table public.vault_access enable row level security;

drop policy if exists "vault_access: owner read" on public.vault_access;
create policy "vault_access: owner read"
  on public.vault_access for select
  using (auth.uid() = user_id);

drop policy if exists "vault_access: owner insert" on public.vault_access;
create policy "vault_access: owner insert"
  on public.vault_access for insert
  with check (auth.uid() = user_id);

drop policy if exists "vault_access: owner delete" on public.vault_access;
create policy "vault_access: owner delete"
  on public.vault_access for delete
  using (auth.uid() = user_id);

-- Only vault owner can read their vaults
drop policy if exists "vaults: owner read" on public.vaults;
create policy "vaults: owner read"
  on public.vaults for select
  using (
    auth.uid() = user_id
    or exists (
      select 1
      from public.vault_access va
      where va.vault_id = vaults.id
        and va.user_id = auth.uid()
    )
  );

-- Only vault owner can insert
drop policy if exists "vaults: owner insert" on public.vaults;
create policy "vaults: owner insert"
  on public.vaults for insert
  with check (auth.uid() = user_id);

-- Only vault owner can update
drop policy if exists "vaults: owner update" on public.vaults;
create policy "vaults: owner update"
  on public.vaults for update
  using (auth.uid() = user_id);

-- Only vault owner can delete
drop policy if exists "vaults: owner delete" on public.vaults;
create policy "vaults: owner delete"
  on public.vaults for delete
  using (auth.uid() = user_id);

-- ============================================================
-- login_existing_vault
-- ============================================================
drop function if exists public.login_existing_vault(text, text);
create or replace function public.login_existing_vault(input_rumus text, input_code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  normalized_rumus text;
  hashed text;
  target_vault_id uuid;
begin
  caller := auth.uid();
  if caller is null then
    raise exception 'not_authenticated';
  end if;

  normalized_rumus := lower(trim(input_rumus));
  if normalized_rumus is null or normalized_rumus = '' then
    raise exception 'invalid_rumus';
  end if;

  if input_code is null or length(trim(input_code)) <> 6 then
    raise exception 'invalid_code';
  end if;

  hashed := encode(digest(trim(input_code), 'sha256'), 'hex');

  select v.id
    into target_vault_id
  from public.vaults v
  where v.rumus = normalized_rumus
    and v.code_hash = hashed
    and coalesce(v.is_setup, false) = true
  limit 1;

  if target_vault_id is null then
    raise exception 'invalid_credentials';
  end if;

  insert into public.vault_access(user_id, vault_id, code_hash)
  values (caller, target_vault_id, hashed)
  on conflict (user_id, vault_id) do update
    set code_hash = excluded.code_hash;

  return target_vault_id;
end;
$$;

grant execute on function public.login_existing_vault(text, text) to authenticated;

-- ============================================================
-- conversations
-- ============================================================
create table if not exists public.conversations (
  id uuid primary key default gen_random_uuid(),
  initiator_id uuid not null references auth.users(id) on delete cascade,
  participant_id uuid references auth.users(id) on delete set null,
  initiator_vault_id uuid references public.vaults(id) on delete set null,
  participant_vault_id uuid references public.vaults(id) on delete set null,
  is_closed boolean not null default false,
  closed_at timestamptz,
  closed_by_vault_id uuid references public.vaults(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.conversations add column if not exists is_closed boolean not null default false;
alter table public.conversations add column if not exists closed_at timestamptz;
alter table public.conversations add column if not exists closed_by_vault_id uuid references public.vaults(id) on delete set null;

alter table public.conversations enable row level security;

-- Participants (initiator or participant) can read
drop policy if exists "conversations: participants read" on public.conversations;
create policy "conversations: participants read"
  on public.conversations for select
  using (
    auth.uid() = initiator_id or
    auth.uid() = participant_id
  );

-- Authenticated users can insert (initiator creates conversation)
drop policy if exists "conversations: initiator insert" on public.conversations;
create policy "conversations: initiator insert"
  on public.conversations for insert
  with check (auth.uid() = initiator_id or auth.uid() = participant_id);

-- Participants can update (e.g., setting participant_vault_id)
drop policy if exists "conversations: participants update" on public.conversations;
create policy "conversations: participants update"
  on public.conversations for update
  using (
    auth.uid() = initiator_id or
    auth.uid() = participant_id
  );

-- ============================================================
-- messages
-- ============================================================
create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  sender_vault_id uuid references public.vaults(id) on delete set null,
  content text not null,
  created_at timestamptz not null default now()
);
alter table public.messages add column if not exists sender_vault_id uuid references public.vaults(id) on delete set null;

alter table public.messages enable row level security;

-- Conversation participants can read messages
drop policy if exists "messages: participants read" on public.messages;
create policy "messages: participants read"
  on public.messages for select
  using (
    exists (
      select 1 from public.conversations c
      where c.id = messages.conversation_id
        and (c.initiator_id = auth.uid() or c.participant_id = auth.uid())
    )
  );

-- Only the sender can insert messages (must be a participant)
drop policy if exists "messages: sender insert" on public.messages;
create policy "messages: sender insert"
  on public.messages for insert
  with check (
    auth.uid() = sender_id and
    (
      sender_vault_id is null
      or exists (
        select 1 from public.conversations c
        where c.id = messages.conversation_id
          and (
            c.initiator_vault_id = sender_vault_id
            or c.participant_vault_id = sender_vault_id
          )
      )
    ) and
    exists (
      select 1 from public.conversations c
      where c.id = messages.conversation_id
        and (c.initiator_id = auth.uid() or c.participant_id = auth.uid())
    )
  );

-- ============================================================
-- conversation_reads (unread tracking per conversation + vault)
-- ============================================================
create table if not exists public.conversation_reads (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  vault_id uuid not null references public.vaults(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  last_read_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (conversation_id, vault_id)
);

alter table public.conversation_reads add column if not exists user_id uuid references auth.users(id) on delete cascade;
alter table public.conversation_reads add column if not exists last_read_at timestamptz not null default now();
alter table public.conversation_reads add column if not exists created_at timestamptz not null default now();
alter table public.conversation_reads add column if not exists updated_at timestamptz not null default now();

alter table public.conversation_reads enable row level security;

drop policy if exists "conversation_reads: owner read" on public.conversation_reads;
create policy "conversation_reads: owner read"
  on public.conversation_reads for select
  using (
    auth.uid() = user_id
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
  with check (
    auth.uid() = user_id
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
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- ============================================================
-- device_push_tokens (FCM token registry)
-- ============================================================
create table if not exists public.device_push_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  token text not null unique,
  platform text not null default 'unknown',
  notifications_enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.device_push_tokens add column if not exists user_id uuid references auth.users(id) on delete cascade;
alter table public.device_push_tokens add column if not exists token text;
alter table public.device_push_tokens add column if not exists platform text not null default 'unknown';
alter table public.device_push_tokens add column if not exists notifications_enabled boolean not null default true;
alter table public.device_push_tokens add column if not exists created_at timestamptz not null default now();
alter table public.device_push_tokens add column if not exists updated_at timestamptz not null default now();

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'device_push_tokens_token_key'
  ) then
    alter table public.device_push_tokens
      add constraint device_push_tokens_token_key unique (token);
  end if;
end $$;

alter table public.device_push_tokens enable row level security;

drop policy if exists "device_push_tokens: owner read" on public.device_push_tokens;
create policy "device_push_tokens: owner read"
  on public.device_push_tokens for select
  using (auth.uid() = user_id);

drop policy if exists "device_push_tokens: owner insert" on public.device_push_tokens;
create policy "device_push_tokens: owner insert"
  on public.device_push_tokens for insert
  with check (auth.uid() = user_id);

drop policy if exists "device_push_tokens: owner update" on public.device_push_tokens;
create policy "device_push_tokens: owner update"
  on public.device_push_tokens for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists "device_push_tokens: owner delete" on public.device_push_tokens;
create policy "device_push_tokens: owner delete"
  on public.device_push_tokens for delete
  using (auth.uid() = user_id);

-- ============================================================
-- get_conversation_push_targets (secure recipient token lookup)
-- ============================================================
drop function if exists public.get_conversation_push_targets(uuid, uuid);
create or replace function public.get_conversation_push_targets(
  input_conversation_id uuid,
  input_sender_vault_id uuid default null
)
returns table (
  token text,
  recipient_user_id uuid,
  recipient_vault_id uuid
)
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid;
  initiator_id uuid;
  participant_id uuid;
  initiator_vault_id uuid;
  participant_vault_id uuid;
  recipient_id uuid;
  recipient_vault uuid;
begin
  caller := auth.uid();
  if caller is null then
    raise exception 'not_authenticated';
  end if;

  select
    c.initiator_id,
    c.participant_id,
    c.initiator_vault_id,
    c.participant_vault_id
  into
    initiator_id,
    participant_id,
    initiator_vault_id,
    participant_vault_id
  from public.conversations c
  where c.id = input_conversation_id
  limit 1;

  if initiator_id is null then
    raise exception 'conversation_not_found';
  end if;

  if caller <> initiator_id and caller <> participant_id then
    raise exception 'forbidden';
  end if;

  if input_sender_vault_id is not null and input_sender_vault_id = initiator_vault_id then
    recipient_id := participant_id;
    recipient_vault := participant_vault_id;
  elsif input_sender_vault_id is not null and input_sender_vault_id = participant_vault_id then
    recipient_id := initiator_id;
    recipient_vault := initiator_vault_id;
  elsif caller = initiator_id then
    recipient_id := participant_id;
    recipient_vault := participant_vault_id;
  else
    recipient_id := initiator_id;
    recipient_vault := initiator_vault_id;
  end if;

  return query
  select distinct
    dpt.token,
    recipient_id,
    recipient_vault
  from public.device_push_tokens dpt
  where dpt.user_id = recipient_id
    and dpt.notifications_enabled = true
    and dpt.token is not null
    and trim(dpt.token) <> '';
end;
$$;

grant execute on function public.get_conversation_push_targets(uuid, uuid) to authenticated;

-- ============================================================
-- invites
-- ============================================================
create table if not exists public.invites (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid references public.conversations(id) on delete set null,
  from_user_id uuid not null references auth.users(id) on delete cascade,
  from_vault_id uuid references public.vaults(id) on delete set null,
  from_rumus text not null,
  to_rumus text not null,
  status text not null default 'pending',
  created_at timestamptz not null default now(),
  constraint invites_status_check check (status in ('pending', 'accepted', 'declined'))
);
alter table public.invites add column if not exists from_vault_id uuid references public.vaults(id) on delete set null;

alter table public.invites enable row level security;

-- Sender can insert invites
drop policy if exists "invites: sender insert" on public.invites;
create policy "invites: sender insert"
  on public.invites for insert
  with check (auth.uid() = from_user_id);

-- Sender can read their sent invites
drop policy if exists "invites: sender read" on public.invites;
create policy "invites: sender read"
  on public.invites for select
  using (auth.uid() = from_user_id);

-- Recipient can read invites addressed to their rumus
drop policy if exists "invites: recipient read" on public.invites;
create policy "invites: recipient read"
  on public.invites for select
  using (
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
  );

-- Either party can update invite status
drop policy if exists "invites: parties update" on public.invites;
create policy "invites: parties update"
  on public.invites for update
  using (
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
  );

-- ============================================================
-- Indexes for performance
-- ============================================================
create index if not exists idx_vaults_user_id on public.vaults(user_id);
create index if not exists idx_vaults_code_hash on public.vaults(code_hash);
create index if not exists idx_vaults_rumus on public.vaults(rumus);
create index if not exists idx_vault_access_user_id on public.vault_access(user_id);
create index if not exists idx_vault_access_vault_id on public.vault_access(vault_id);
create index if not exists idx_vault_access_code_hash on public.vault_access(code_hash);
create index if not exists idx_conversations_initiator on public.conversations(initiator_id);
create index if not exists idx_conversations_participant on public.conversations(participant_id);
create index if not exists idx_conversations_initiator_vault on public.conversations(initiator_vault_id);
create index if not exists idx_conversations_participant_vault on public.conversations(participant_vault_id);
create index if not exists idx_conversations_is_closed on public.conversations(is_closed);
create index if not exists idx_messages_conversation on public.messages(conversation_id);
create index if not exists idx_messages_created_at on public.messages(created_at);
create index if not exists idx_messages_sender_vault on public.messages(sender_vault_id);
create index if not exists idx_conversation_reads_vault on public.conversation_reads(vault_id);
create index if not exists idx_conversation_reads_user on public.conversation_reads(user_id);
create index if not exists idx_conversation_reads_last_read_at on public.conversation_reads(last_read_at);
create index if not exists idx_device_push_tokens_user on public.device_push_tokens(user_id);
create index if not exists idx_device_push_tokens_enabled on public.device_push_tokens(notifications_enabled);
create index if not exists idx_invites_to_rumus on public.invites(to_rumus);
create index if not exists idx_invites_from_user on public.invites(from_user_id);
create index if not exists idx_invites_from_vault on public.invites(from_vault_id);
create index if not exists idx_invites_status on public.invites(status);

-- ============================================================
-- Realtime: enable for messages table
-- ============================================================
do $$
begin
  if not exists (
    select 1
    from pg_publication_rel pr
    join pg_class c on c.oid = pr.prrelid
    join pg_namespace n on n.oid = c.relnamespace
    join pg_publication p on p.oid = pr.prpubid
    where p.pubname = 'supabase_realtime'
      and n.nspname = 'public'
      and c.relname = 'messages'
  ) then
    execute 'alter publication supabase_realtime add table public.messages';
  end if;
end $$;
