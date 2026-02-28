-- test_community.sql

-- 1. Insert a Meeting
INSERT INTO public.meetings (title, description, meeting_url, start_time)
VALUES (
  'Taller de Ventas Q1',
  'Aprende a cerrar más ventas con estas 5 técnicas comprobadas.',
  'https://zoom.us/j/1234567890',
  now() + interval '1 day'
);

-- 2. Insert a Purchase Pool
INSERT INTO public.purchase_pools (title, description, target_amount, closes_at)
VALUES (
  'Licencias de Software en Grupo',
  'Compraremos 50 licencias de CRM con 40% de descuento.',
  5000.00,
  now() + interval '7 days'
);
