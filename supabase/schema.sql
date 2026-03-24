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
create policy "user_profiles: owner read"
  on public.user_profiles for select
  using (auth.uid() = id);

-- Users can insert their own profile
create policy "user_profiles: owner insert"
  on public.user_profiles for insert
  with check (auth.uid() = id);

-- Users can update their own profile
create policy "user_profiles: owner update"
  on public.user_profiles for update
  using (auth.uid() = id);

-- All authenticated users can read rumus (needed for invite search)
create policy "user_profiles: rumus readable by all"
  on public.user_profiles for select
  using (auth.role() = 'authenticated' or auth.role() = 'anon');

-- ============================================================
-- vaults
-- ============================================================
create table if not exists public.vaults (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  code_hash text not null,
  is_setup boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.vaults enable row level security;

-- Only vault owner can read their vaults
create policy "vaults: owner read"
  on public.vaults for select
  using (auth.uid() = user_id);

-- Only vault owner can insert
create policy "vaults: owner insert"
  on public.vaults for insert
  with check (auth.uid() = user_id);

-- Only vault owner can update
create policy "vaults: owner update"
  on public.vaults for update
  using (auth.uid() = user_id);

-- Only vault owner can delete
create policy "vaults: owner delete"
  on public.vaults for delete
  using (auth.uid() = user_id);

-- ============================================================
-- conversations
-- ============================================================
create table if not exists public.conversations (
  id uuid primary key default gen_random_uuid(),
  initiator_id uuid not null references auth.users(id) on delete cascade,
  participant_id uuid references auth.users(id) on delete set null,
  initiator_vault_id uuid references public.vaults(id) on delete set null,
  participant_vault_id uuid references public.vaults(id) on delete set null,
  created_at timestamptz not null default now()
);

alter table public.conversations enable row level security;

-- Participants (initiator or participant) can read
create policy "conversations: participants read"
  on public.conversations for select
  using (
    auth.uid() = initiator_id or
    auth.uid() = participant_id
  );

-- Authenticated users can insert (initiator creates conversation)
create policy "conversations: initiator insert"
  on public.conversations for insert
  with check (auth.uid() = initiator_id or auth.uid() = participant_id);

-- Participants can update (e.g., setting participant_vault_id)
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
  content text not null,
  created_at timestamptz not null default now()
);

alter table public.messages enable row level security;

-- Conversation participants can read messages
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
create policy "messages: sender insert"
  on public.messages for insert
  with check (
    auth.uid() = sender_id and
    exists (
      select 1 from public.conversations c
      where c.id = messages.conversation_id
        and (c.initiator_id = auth.uid() or c.participant_id = auth.uid())
    )
  );

-- ============================================================
-- invites
-- ============================================================
create table if not exists public.invites (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid references public.conversations(id) on delete set null,
  from_user_id uuid not null references auth.users(id) on delete cascade,
  from_rumus text not null,
  to_rumus text not null,
  status text not null default 'pending',
  created_at timestamptz not null default now(),
  constraint invites_status_check check (status in ('pending', 'accepted', 'declined'))
);

alter table public.invites enable row level security;

-- Sender can insert invites
create policy "invites: sender insert"
  on public.invites for insert
  with check (auth.uid() = from_user_id);

-- Sender can read their sent invites
create policy "invites: sender read"
  on public.invites for select
  using (auth.uid() = from_user_id);

-- Recipient can read invites addressed to their rumus
create policy "invites: recipient read"
  on public.invites for select
  using (
    to_rumus = (
      select rumus from public.user_profiles
      where id = auth.uid()
    )
  );

-- Either party can update invite status
create policy "invites: parties update"
  on public.invites for update
  using (
    auth.uid() = from_user_id or
    to_rumus = (
      select rumus from public.user_profiles
      where id = auth.uid()
    )
  );

-- ============================================================
-- Indexes for performance
-- ============================================================
create index if not exists idx_vaults_user_id on public.vaults(user_id);
create index if not exists idx_vaults_code_hash on public.vaults(code_hash);
create index if not exists idx_conversations_initiator on public.conversations(initiator_id);
create index if not exists idx_conversations_participant on public.conversations(participant_id);
create index if not exists idx_conversations_initiator_vault on public.conversations(initiator_vault_id);
create index if not exists idx_conversations_participant_vault on public.conversations(participant_vault_id);
create index if not exists idx_messages_conversation on public.messages(conversation_id);
create index if not exists idx_messages_created_at on public.messages(created_at);
create index if not exists idx_invites_to_rumus on public.invites(to_rumus);
create index if not exists idx_invites_from_user on public.invites(from_user_id);
create index if not exists idx_invites_status on public.invites(status);

-- ============================================================
-- Realtime: enable for messages table
-- ============================================================
alter publication supabase_realtime add table public.messages;
