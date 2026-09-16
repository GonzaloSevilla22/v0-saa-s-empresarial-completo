-- =============================================================================
-- GATE: test_realtime_publication.sql
-- CHANGE: auth-hardening-jwt-cookies Parte A, grupo 8 (D14, spec
-- afip-fiscal-document "El cambio de estado del comprobante llega a la
-- interfaz en tiempo real").
--
-- FiscalDocumentBadge (frontend/components/fiscal/FiscalDocumentBadge.tsx:
-- 76-96) se suscribe a postgres_changes UPDATE sobre public.fiscal_documents
-- desde que se escribió y nunca recibió un evento: la publicación
-- supabase_realtime tenía UNA sola tabla, `notifications`. Una suscripción a
-- una tabla fuera de la publicación no falla ni avisa — se queda muda, que es
-- justo por lo que esto necesita un gate y no un comentario.
--
--   (1) `notifications` sigue en la publicación (control de no-regresión: el
--       ALTER de este change no debe desplazar lo que ya estaba).
--   (2) `fiscal_documents` está en la publicación, UNA sola vez.
--   (3) La RLS de fiscal_documents sigue activa. Es lo que hace segura la
--       publicación: el filtro que declara el cliente en su suscripción es
--       optimización de red, NO el límite de seguridad (spec
--       afip-fiscal-document). Publicar una tabla sin RLS sería difundir cada
--       cambio a todo suscriptor autenticado.
--   (4) El patrón del ALTER guardado es idempotente: se ejecuta DOS veces,
--       ninguna falla, y la tabla queda UNA sola vez.
--
-- POR QUÉ (4) CORRE SOBRE UNA PUBLICACIÓN DE SONDEO Y NO SOBRE
-- supabase_realtime: un gate que ejecutara el ALTER real dejaría la tabla
-- publicada como EFECTO SECUNDARIO, y entonces el bloque (2) pasaría en verde
-- en la siguiente corrida incluso sin la migración — el gate se volvería
-- ciego a exactamente lo que existe para detectar. Con la publicación de
-- sondeo el guard se ejercita de verdad (dos pasadas, la segunda sobre una
-- publicación que YA tiene la tabla: sin el guard, Postgres responde 42710) y
-- el estado compartido no se toca. La idempotencia del archivo de migración
-- COMPLETO, con su statement literal, la cubre además la cadena de
-- reaplicación de .github/workflows/KPI_Validation.yml.
-- =============================================================================

DO $$
DECLARE
  v_blocks_run int := 0;
  v_count      int;
BEGIN
  -- ── (1) notifications sigue publicada ──────────────────────────────────────
  SELECT COUNT(*) INTO v_count
  FROM pg_publication_tables
  WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'notifications';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE REALTIME-PUBLICATION FAILED (1): public.notifications aparece % veces en supabase_realtime (esperaba 1) -- las notificaciones in-app dejarían de llegar.', v_count;
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (1): public.notifications sigue en la publicación supabase_realtime.';

  -- ── (2) fiscal_documents publicada ─────────────────────────────────────────
  SELECT COUNT(*) INTO v_count
  FROM pg_publication_tables
  WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'fiscal_documents';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE REALTIME-PUBLICATION FAILED (2): public.fiscal_documents aparece % veces en supabase_realtime (esperaba 1) -- FiscalDocumentBadge se queda mudo en pending_cae hasta que el usuario recargue.', v_count;
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (2): public.fiscal_documents está en la publicación supabase_realtime.';

  -- ── (3) RLS activa sobre fiscal_documents ──────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname = 'fiscal_documents' AND c.relrowsecurity
  ) THEN
    RAISE EXCEPTION 'GATE REALTIME-PUBLICATION FAILED (3): fiscal_documents está publicada pero SIN row level security -- el flujo de tiempo real dejaría de estar acotado por cuenta.';
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (3): fiscal_documents conserva la RLS que acota el flujo de tiempo real por cuenta.';

  IF v_blocks_run <> 3 THEN
    RAISE EXCEPTION 'GATE REALTIME-PUBLICATION FAILED (conteo): se ejercitaron % de 3 bloques de estado esperados.', v_blocks_run;
  END IF;
END $$;

-- ── (4) idempotencia del patrón del ALTER guardado, sobre una publicación ────
--    de sondeo (ver el encabezado). El guard es el MISMO de
--    20261051000001 salvo el nombre de la publicación.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'gate_probe_realtime_publication') THEN
    -- Resto de una corrida abortada: se limpia antes de empezar.
    DROP PUBLICATION gate_probe_realtime_publication;
  END IF;
  CREATE PUBLICATION gate_probe_realtime_publication;

  -- 1ª pasada: la publicación de sondeo NO tiene la tabla -> la agrega.
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'gate_probe_realtime_publication'
      AND schemaname = 'public'
      AND tablename  = 'fiscal_documents'
  ) THEN
    ALTER PUBLICATION gate_probe_realtime_publication ADD TABLE public.fiscal_documents;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'gate_probe_realtime_publication'
      AND schemaname = 'public' AND tablename = 'fiscal_documents'
  ) THEN
    DROP PUBLICATION gate_probe_realtime_publication;
    RAISE EXCEPTION 'GATE REALTIME-PUBLICATION FAILED (4-alta): el ALTER guardado no agregó la tabla en la 1ª pasada.';
  END IF;

  -- 2ª pasada: la tabla YA está. Sin el guard, esto sería 42710.
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'gate_probe_realtime_publication'
      AND schemaname = 'public'
      AND tablename  = 'fiscal_documents'
  ) THEN
    ALTER PUBLICATION gate_probe_realtime_publication ADD TABLE public.fiscal_documents;
  END IF;

  IF (SELECT COUNT(*) FROM pg_publication_tables
      WHERE pubname = 'gate_probe_realtime_publication'
        AND schemaname = 'public' AND tablename = 'fiscal_documents') <> 1 THEN
    DROP PUBLICATION gate_probe_realtime_publication;
    RAISE EXCEPTION 'GATE REALTIME-PUBLICATION FAILED (4-idempotencia): tras dos pasadas la tabla no quedó exactamente una vez en la publicación de sondeo.';
  END IF;

  DROP PUBLICATION gate_probe_realtime_publication;
  RAISE NOTICE 'PASS (4): el patrón del ALTER PUBLICATION guardado es idempotente -- dos pasadas sin error, una sola entrada, y la publicación de sondeo queda eliminada.';
  RAISE NOTICE 'GATE REALTIME-PUBLICATION: 4/4 bloques PASS.';
EXCEPTION
  WHEN OTHERS THEN
    IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'gate_probe_realtime_publication') THEN
      DROP PUBLICATION gate_probe_realtime_publication;
    END IF;
    RAISE;
END $$;
