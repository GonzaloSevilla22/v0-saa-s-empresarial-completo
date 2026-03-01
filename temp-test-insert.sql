-- test_trigger.sql
INSERT INTO auth.users (
    id,
    instance_id,
    email,
    aud,
    role,
    encrypted_password,
    raw_user_meta_data
) VALUES (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'testwelcome2@eie.com',
    'authenticated',
    'authenticated',
    'encrypted_password',
    '{"name": "Prueba Trigger"}'::jsonb
);
