-- =============================================================================
-- GATE: test_sales_order_payment_method_drop.sql
-- CHANGE: limpiezas-pagos-admin (G1a/G1c, task 4.1 RED / 6.3 GREEN)
--
-- Estático — verifica que el retiro de sales_orders.payment_method (G1) es
-- completo:
--   (1) la columna sales_orders.payment_method no existe;
--   (2) el CHECK sales_orders_payment_method_check no existe;
--   (3) ninguna función de public referencia la columna de texto fuera de
--       payment_method_id / payment_methods (tabla) / la clave del payload
--       de eventos ('payment_method' entre comillas) — token completo
--       "payment_method" sin prefijo _ (p_payment_method, v_payment_method)
--       ni sufijo _algo (payment_method_id, payment_method_mismatch, ...)
--       ni comillas (el literal del payload), lo que en la práctica solo
--       matchea una referencia cruda a la columna (p.ej. so.payment_method
--       o un literal de columna en un INSERT/UPDATE).
-- =============================================================================

DO $$
DECLARE
  v_offenders text;
BEGIN
  -- (1) Columna ausente
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'sales_orders' AND column_name = 'payment_method'
  ) THEN
    RAISE EXCEPTION 'GATE SALES-ORDER-PAYMENT-METHOD-DROP FAILED (1): sales_orders.payment_method todavía existe.';
  END IF;
  RAISE NOTICE 'PASS (1): sales_orders.payment_method no existe.';

  -- (2) CHECK ausente
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sales_orders_payment_method_check') THEN
    RAISE EXCEPTION 'GATE SALES-ORDER-PAYMENT-METHOD-DROP FAILED (2): sales_orders_payment_method_check todavía existe.';
  END IF;
  RAISE NOTICE 'PASS (2): sales_orders_payment_method_check no existe.';

  -- (3) Cero referencias crudas a la columna en funciones vivas de public.
  -- Se despoja el prosrc de comentarios de bloque (/* */), comentarios de
  -- línea (--) y literales de texto ('...') ANTES de matchear — si no, el
  -- propio texto descriptivo ("se retiró sales_orders.payment_method") o un
  -- mensaje de error ("payment_method=cash exige...") dispara un falso
  -- positivo. Sobre lo que queda (SQL real), el token "payment_method"
  -- excluyendo: prefijo _ (parámetros/variables p_payment_method/
  -- v_payment_method — CONSERVADOS por diseño) y sufijo _*/s (payment_
  -- method_id, payment_method_mismatch, payment_methods) es, en la
  -- práctica, solo una referencia cruda a la columna retirada.
  SELECT string_agg(s.proname, ', ')
  INTO v_offenders
  FROM (
    SELECT p.proname,
           regexp_replace(
             regexp_replace(
               regexp_replace(p.prosrc, '/\*.*?\*/', '', 'g'),
               '--[^\n]*', '', 'g'
             ),
             '''([^'']|'''''')*''', '', 'g'
           ) AS body
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
  ) s
  WHERE s.body ~ '(?<![A-Za-z0-9_])payment_method(?![A-Za-z0-9_])';

  IF v_offenders IS NOT NULL THEN
    RAISE EXCEPTION 'GATE SALES-ORDER-PAYMENT-METHOD-DROP FAILED (3): funciones que aún referencian la columna de texto payment_method (fuera de payment_method_id/payment_methods/el literal del payload): %', v_offenders;
  END IF;
  RAISE NOTICE 'PASS (3): ninguna función de public referencia la columna de texto sales_orders.payment_method.';

  RAISE NOTICE 'GATE SALES-ORDER-PAYMENT-METHOD-DROP PASSED.';
END $$;
