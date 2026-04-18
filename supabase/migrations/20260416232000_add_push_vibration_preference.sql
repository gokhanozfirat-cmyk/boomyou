-- Persist per-device vibration preference for push notifications.
alter table public.device_push_tokens
  add column if not exists vibration_enabled boolean not null default true;

create index if not exists idx_device_push_tokens_vibration_enabled
  on public.device_push_tokens(vibration_enabled);
