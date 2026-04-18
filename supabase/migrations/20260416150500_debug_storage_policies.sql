create or replace function public.debug_active_storage_policies()
returns jsonb
language sql
security definer
as $$
  select jsonb_agg(jsonb_build_object(
    'name', policyname,
    'cmd', cmd,
    'permissive', permissive,
    'roles', roles,
    'qual', left(qual, 500)
  ))
  from pg_policies
  where schemaname = 'storage' and tablename = 'objects';
$$;
grant execute on function public.debug_active_storage_policies() to anon, authenticated;
