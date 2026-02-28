create or replace trigger on_email_log_insert
  after insert on public.email_logs
  for each row execute function supabase_functions.http_request(
    'http://host.docker.internal:54321/functions/v1/send-email',
    'POST',
    '{"Content-type":"application/json"}',
    '{}',
    '5000'
  );
