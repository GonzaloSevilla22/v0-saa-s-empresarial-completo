-- Drop the existing trigger and function to recreate them with email logic
drop trigger if exists on_auth_user_created on auth.users;
drop function if exists public.handle_new_user();

create or replace function public.handle_new_user()
returns trigger as $$
declare
  user_name text;
begin
  -- 1. Create the profile
  insert into public.profiles (id, role, plan)
  values (new.id, 'user', 'free');
  
  -- 2. Extract name from raw_user_meta_data if exists, else default
  user_name := coalesce(new.raw_user_meta_data->>'name', 'Emprendedor');

  -- 3. Queue the Welcome Email
  insert into public.email_logs (
    user_id, 
    event_type, 
    recipient, 
    subject, 
    metadata
  ) values (
    new.id,
    'welcome',
    new.email,
    '¡Bienvenido a EIE Emprendedores!',
    jsonb_build_object('name', user_name)
  );

  return new;
end;
$$ language plpgsql security definer;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();
