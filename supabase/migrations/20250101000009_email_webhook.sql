do $$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'supabase_functions') then
    execute 'create or replace trigger on_email_log_insert
      after insert on public.email_logs
      for each row execute function supabase_functions.http_request(
        ''http://host.docker.internal:54321/functions/v1/send-email'',
        ''POST'',
        ''{"Content-type":"application/json"}'',
        ''{}'',
        ''5000''
      )';
  else
    raise notice 'Schema "supabase_functions" not found. Skipping trigger creation. (This is expected in production if Database Webhooks are not enabled in the dashboard).';
  end if;
end $$;
