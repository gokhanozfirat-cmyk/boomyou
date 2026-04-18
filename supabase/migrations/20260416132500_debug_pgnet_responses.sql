-- Check pg_net request/response queue for push trigger activity
create or replace function public.debug_pgnet_activity()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  result jsonb;
begin
  -- Check recent requests in net._http_response
  begin
    select jsonb_build_object(
      'recent_responses', (
        select jsonb_agg(jsonb_build_object(
          'id', r.id,
          'status_code', r.status_code,
          'created', r.created,
          'error_msg', r.error_msg,
          'content_snippet', left(r.content::text, 200)
        ) order by r.created desc)
        from net._http_response r
        limit 10
      ),
      'total_responses', (select count(*) from net._http_response)
    ) into result;
  exception when others then
    result := jsonb_build_object('error', SQLERRM);
  end;
  return result;
end;
$$;
grant execute on function public.debug_pgnet_activity() to anon, authenticated;
