-- Add vibration_enabled column to device_push_tokens
alter table public.device_push_tokens
  add column if not exists vibration_enabled boolean not null default true;
