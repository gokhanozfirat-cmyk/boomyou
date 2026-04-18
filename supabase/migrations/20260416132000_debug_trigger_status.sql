-- Check if the push trigger exists and is enabled
create or replace function public.debug_trigger_status()
returns jsonb
language sql
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'triggers', (
      select jsonb_agg(jsonb_build_object(
        'name', t.tgname,
        'enabled', t.tgenabled,
        'table', c.relname,
        'function', p.proname
      ))
      from pg_trigger t
      join pg_class c on c.oid = t.tgrelid
      join pg_proc p on p.oid = t.tgfoid
      where c.relname = 'messages'
    ),
    'pg_net_installed', exists(select 1 from pg_extension where extname = 'pg_net'),
    'net_functions', (
      select jsonb_agg(p.proname)
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('net', 'extensions')
        and p.proname like 'http%'
    )
  );
$$;
grant execute on function public.debug_trigger_status() to anon, authenticated;
