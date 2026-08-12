-- =============================================================================
-- MIGRATION: 20260914000001_analytics_events_revival.sql
-- CHANGE:    analytics-events-revival (emisión — grupo 2 de tasks.md)
--
-- QUÉ HACE:
--   Hallazgo F5 (docs/plan-remediacion-kpis-2026-08-11.md, verificado
--   2026-08-11/12): las rutas VIVAS de escritura de ventas
--   (rpc_create_sale_operation / rpc_create_sale_operation_v2), compras
--   (rpc_create_purchase_operation / _v2) y gastos (expense_repository.py vía
--   FastAPI) NO emiten `analytics_events`. El único emisor que sigue vivo es
--   el legacy `frontend/lib/supabase/services.ts:createExpense`, que la UI ya
--   no usa. Resultado: activación/retención/UMV miden ruido — verificado en
--   prod (task 1.2 de tasks.md): 7 usuarios con `first_operation` duplicado
--   (hasta 21 filas para uno solo), producto del patrón legacy
--   IF NOT EXISTS...THEN INSERT, que corre carrera.
--
--   Esta migración crea un CHOKE POINT ÚNICO a nivel de base de datos:
--     1. `analytics_events` gana `account_id uuid` (nullable, FK accounts,
--        ON DELETE CASCADE) + índice (account_id, created_at). Aditivo.
--     2. Limpieza idempotente de los duplicados históricos de
--        `first_operation` (conserva el más antiguo por user_id).
--     3. Dos índices únicos parciales (dedupe estructural, sin carrera):
--        - ux_analytics_first_operation_user: máx. 1 `first_operation` por
--          usuario.
--        - ux_analytics_operation_entity: máx. 1 `operation_created` por
--          operación (event_data->>'entity_id'), sin colisionar con eventos
--          legacy que usan las claves sale_id/purchase_id/expense_id.
--     4. Función `public.analytics_emit_operation_event()` — SECURITY
--        DEFINER, trigger-only, cuerpo envuelto en
--        BEGIN...EXCEPTION WHEN OTHERS THEN RAISE WARNING...END (degrade-
--        don't-fail, precedente exacto: seed de handle_new_user en
--        20260812000001). Deriva user_id/account_id de NEW (nunca de
--        auth.uid(), que no está disponible en todas las rutas: backend con
--        JWT-passthrough, jobs, migraciones).
--     5. REVOKE ALL ... FROM PUBLIC, anon, authenticated en el mismo archivo
--        (gotcha del proyecto: DROP+CREATE resetea ACLs). La función es
--        trigger-only — PostgreSQL verifica EXECUTE al crear el trigger, no
--        en cada disparo, así que revocarla no rompe la emisión (probado por
--        el gate 5/3.6 de supabase/tests/test_analytics_events.sql).
--     6. Triggers `trg_analytics_operation_created` AFTER INSERT FOR EACH ROW
--        en sales, purchases, expenses.
--     7. Gate auto-limpiante (DO $$ ... $$, patrón Parte C de
--        20260812000001): smoke test de emisión + unicidad de activación +
--        degrade-don't-fail con anchor sintético; degrada con NOTICE si el
--        contexto no lo permite (prod real). La cobertura EXHAUSTIVA (7
--        gates: emisión, unicidad, atomicidad, degrade-don't-fail, ACL/RLS,
--        idempotencia, granularidad) vive en
--        supabase/tests/test_analytics_events.sql (corre en CI vía
--        KPI_Validation.yml).
--
--   Fuera de alcance de ESTA migración (BLOQUEADO por sign-off OQ-2 del PO,
--   ver design.md "Open Questions" y tasks.md grupo 6): el backfill histórico
--   derivado de sales/purchases/expenses. La emisión es autónoma y no
--   depende de esa decisión (D10 del design).
--
--   También fuera de alcance: el retiro del emisor legacy de
--   frontend/lib/supabase/services.ts (D7) — es un cambio de aplicación, va
--   en un commit de frontend separado del mismo PR, no en esta migración SQL.
--
-- GOVERNANCE: MEDIO — no toca dinero, auth ni datos de negocio. El peor caso
--   de un bug en el emisor es telemetría faltante (degrade-don't-fail
--   garantizado por el EXCEPTION handler y probado por gate), nunca una
--   operación de negocio perdida.
--
-- IDEMPOTENCIA / BOTH-WORLDS-SAFE: la integración GitHub de Supabase auto-
--   aplica migraciones al mergear a main ANTES del `db push` de Actions →
--   esta migración puede correr más de una vez.
--     - ADD COLUMN IF NOT EXISTS / CREATE INDEX IF NOT EXISTS / CREATE UNIQUE
--       INDEX IF NOT EXISTS para todo el DDL aditivo.
--     - La limpieza de duplicados es un DELETE condicionado por ROW_NUMBER():
--       en la segunda corrida no quedan duplicados, así que no borra nada.
--     - CREATE OR REPLACE FUNCTION + DROP TRIGGER IF EXISTS/CREATE TRIGGER
--       para la función y los triggers.
--     - El gate final es un DO $$ ... $$ auto-limpiante: crea su propio
--       anchor sintético y lo borra al final (accounts=0), sin dejar rastro
--       en corridas repetidas.
--
-- APPLY: vía CI al mergear a main (GitHub Actions: build + deploy + db
--   push). NUNCA aplicar con el MCP `apply_migration` (desincroniza el
--   historial de migraciones respecto al proyecto real gxdhpxvdjjkmxhdkkwyb).
--
-- ROLLBACK: `DROP TRIGGER trg_analytics_operation_created` en las tres
--   tablas (la función y los índices quedan inertes sin triggers y pueden
--   permanecer). La columna `account_id` y los eventos ya emitidos NO se
--   revierten: son datos legítimos y borrarlos destruiría telemetría real.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Tenancy del evento: account_id (aditivo, nullable)
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.analytics_events
  ADD COLUMN IF NOT EXISTS account_id uuid REFERENCES public.accounts(id) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS idx_analytics_events_account_created
  ON public.analytics_events (account_id, created_at);


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Limpieza idempotente de duplicados históricos de first_operation
--    Precondición verificada en prod (task 1.2, 2026-08-12): 7 usuarios con
--    duplicados (máximo 21 filas para uno solo) — el path legacy usaba
--    IF NOT EXISTS...THEN INSERT, que corre carrera bajo concurrencia. Debe
--    correr ANTES del índice único del paso 3 y en la misma transacción: si
--    la limpieza no fuera posible, la creación del índice fallaría y
--    abortaría la migración entera (sin estado a medias).
-- ─────────────────────────────────────────────────────────────────────────────
DELETE FROM public.analytics_events ae
USING (
  SELECT id,
         ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY created_at ASC, id ASC) AS rn
  FROM   public.analytics_events
  WHERE  event_name = 'first_operation'
    AND  user_id IS NOT NULL
) dedup
WHERE ae.id = dedup.id
  AND dedup.rn > 1;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Deduplicación estructural (índices únicos parciales) — D4 del design
-- ─────────────────────────────────────────────────────────────────────────────
CREATE UNIQUE INDEX IF NOT EXISTS ux_analytics_first_operation_user
  ON public.analytics_events (user_id)
  WHERE event_name = 'first_operation';

CREATE UNIQUE INDEX IF NOT EXISTS ux_analytics_operation_entity
  ON public.analytics_events (event_name, (event_data->>'entity_id'))
  WHERE event_name = 'operation_created' AND event_data ? 'entity_id';


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Función emisora — SECURITY DEFINER, trigger-only, degrade-don't-fail
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.analytics_emit_operation_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_entity_type text;
BEGIN
  -- Todo el cuerpo va envuelto: un fallo acá degrada a WARNING y JAMÁS aborta
  -- la venta/compra/gasto (D3 del design; precedente: 20260812000001).
  BEGIN
    v_entity_type := CASE TG_TABLE_NAME
      WHEN 'sales'     THEN 'sale'
      WHEN 'purchases' THEN 'purchase'
      WHEN 'expenses'  THEN 'expense'
      ELSE TG_TABLE_NAME
    END;

    INSERT INTO public.analytics_events (user_id, account_id, event_name, event_data)
    VALUES (
      NEW.user_id,
      NEW.account_id,
      'operation_created',
      jsonb_build_object(
        'entity_id',   NEW.id,
        'entity_type', v_entity_type,
        'source',      'trigger'
      )
    )
    ON CONFLICT (event_name, (event_data->>'entity_id'))
      WHERE event_name = 'operation_created' AND event_data ? 'entity_id'
    DO NOTHING;

    -- Se intenta siempre; el árbitro sin carreras es el índice único parcial
    -- (D4), no un EXISTS previo — evita el bug de doble activación bajo
    -- concurrencia que tenía el path legacy.
    INSERT INTO public.analytics_events (user_id, account_id, event_name, event_data)
    VALUES (
      NEW.user_id,
      NEW.account_id,
      'first_operation',
      jsonb_build_object(
        'entity_id',   NEW.id,
        'entity_type', v_entity_type,
        'source',      'trigger'
      )
    )
    ON CONFLICT (user_id)
      WHERE event_name = 'first_operation'
    DO NOTHING;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING 'analytics_emit_operation_event: no se pudo emitir telemetría para %.% id=% (la operación de negocio continúa). SQLERRM=%',
        TG_TABLE_NAME, TG_OP, NEW.id, SQLERRM;
  END;

  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.analytics_emit_operation_event IS
  'analytics-events-revival: choke point único de telemetría de producto — '
  'emite operation_created (y first_operation la primera vez) por cada fila '
  'insertada en sales/purchases/expenses, sin importar la ruta de escritura. '
  'Trigger-only (EXECUTE revocado de PUBLIC/anon/authenticated en esta misma '
  'migración). degrade-don''t-fail: un fallo del emisor nunca aborta la '
  'operación de negocio (BEGIN...EXCEPTION WHEN OTHERS, patrón 20260812000001).';

-- DROP+CREATE (y CREATE OR REPLACE de una función nueva) resetea ACLs al
-- default (EXECUTE a PUBLIC) → re-aplicar el REVOKE en el mismo archivo
-- (gotcha del proyecto, regla del backlog de advisors 0028). Es interna,
-- nunca se llama como RPC: revocar authenticated es seguro (a diferencia de
-- las 27 funciones backend-called de 20260830000001, ésta no participa del
-- SET LOCAL ROLE authenticated del paso 2 de v31-tenancy-pool-rls porque no
-- es invocada directamente, solo disparada por el motor).
REVOKE ALL ON FUNCTION public.analytics_emit_operation_event() FROM PUBLIC, anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Triggers — AFTER INSERT FOR EACH ROW en las tres tablas de operaciones
-- ─────────────────────────────────────────────────────────────────────────────
DROP TRIGGER IF EXISTS trg_analytics_operation_created ON public.sales;
CREATE TRIGGER trg_analytics_operation_created
  AFTER INSERT ON public.sales
  FOR EACH ROW EXECUTE FUNCTION public.analytics_emit_operation_event();

DROP TRIGGER IF EXISTS trg_analytics_operation_created ON public.purchases;
CREATE TRIGGER trg_analytics_operation_created
  AFTER INSERT ON public.purchases
  FOR EACH ROW EXECUTE FUNCTION public.analytics_emit_operation_event();

DROP TRIGGER IF EXISTS trg_analytics_operation_created ON public.expenses;
CREATE TRIGGER trg_analytics_operation_created
  AFTER INSERT ON public.expenses
  FOR EACH ROW EXECUTE FUNCTION public.analytics_emit_operation_event();


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Gate de comportamiento auto-limpiante (patrón Parte C de
--    20260812000001): anchor sintético dispara handle_new_user, un gasto
--    real prueba la emisión + degrade-don't-fail; cleanup hijo→padre.
--    Degrada con RAISE NOTICE si el contexto no lo permite (prod real).
--    Cobertura exhaustiva (7 gates) en supabase/tests/test_analytics_events.sql.
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_anchor_email   text := 'analytics-events-revival-migration-gate@test.local';
  v_user_id        uuid := gen_random_uuid();
  v_account_id     uuid;
  v_branch_id      uuid;
  v_expense_id_1   uuid;
  v_expense_id_2   uuid;
  v_force_fail_id  uuid;
  v_first_op_count integer;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_id, 'authenticated', 'authenticated', v_anchor_email, now(), now(),
          jsonb_build_object('name', 'Gate Analytics Migration', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_id
  FROM   public.account_members
  WHERE  user_id = v_user_id
  ORDER  BY created_at
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE NOTICE 'GATE ANALYTICS-EVENTS-REVIVAL (migración): no se pudo resolver una account para el anchor sintético (contexto no permite el gate) — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id INTO v_branch_id
  FROM   public.branches
  WHERE  account_id = v_account_id
  ORDER  BY created_at
  LIMIT  1;

  -- Assert 1: primera operación emite operation_created + first_operation.
  INSERT INTO public.expenses (user_id, account_id, branch_id, category, amount, date)
  VALUES (v_user_id, v_account_id, v_branch_id, '__migration_gate_expense_1__', 100, now())
  RETURNING id INTO v_expense_id_1;

  IF NOT EXISTS (
    SELECT 1 FROM public.analytics_events
    WHERE event_name = 'operation_created' AND event_data->>'entity_id' = v_expense_id_1::text
      AND event_data->>'entity_type' = 'expense' AND account_id = v_account_id
  ) THEN
    RAISE EXCEPTION 'GATE ANALYTICS-EVENTS-REVIVAL (migración) FAILED: el primer gasto no emitió operation_created con payload/account_id correctos.';
  END IF;

  SELECT count(*) INTO v_first_op_count
  FROM public.analytics_events WHERE user_id = v_user_id AND event_name = 'first_operation';

  IF v_first_op_count <> 1 THEN
    RAISE EXCEPTION 'GATE ANALYTICS-EVENTS-REVIVAL (migración) FAILED: se esperaba 1 first_operation, hay %.', v_first_op_count;
  END IF;

  -- Assert 2: segunda operación no duplica first_operation.
  INSERT INTO public.expenses (user_id, account_id, branch_id, category, amount, date)
  VALUES (v_user_id, v_account_id, v_branch_id, '__migration_gate_expense_2__', 200, now())
  RETURNING id INTO v_expense_id_2;

  SELECT count(*) INTO v_first_op_count
  FROM public.analytics_events WHERE user_id = v_user_id AND event_name = 'first_operation';

  IF v_first_op_count <> 1 THEN
    RAISE EXCEPTION 'GATE ANALYTICS-EVENTS-REVIVAL (migración) FAILED: la segunda operación duplicó first_operation, hay %.', v_first_op_count;
  END IF;

  -- Assert 3: degrade-don't-fail — emisor forzado a fallar no aborta la operación.
  ALTER TABLE public.analytics_events
    ADD CONSTRAINT tmp_analytics_force_fail CHECK (event_name <> 'operation_created') NOT VALID;

  INSERT INTO public.expenses (user_id, account_id, branch_id, category, amount, date)
  VALUES (v_user_id, v_account_id, v_branch_id, '__migration_gate_force_fail__', 300, now())
  RETURNING id INTO v_force_fail_id;

  IF NOT EXISTS (SELECT 1 FROM public.expenses WHERE id = v_force_fail_id) THEN
    ALTER TABLE public.analytics_events DROP CONSTRAINT tmp_analytics_force_fail;
    RAISE EXCEPTION 'GATE ANALYTICS-EVENTS-REVIVAL (migración) FAILED: el gasto debería sobrevivir aunque el emisor falle (degrade-don''t-fail roto).';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.analytics_events
    WHERE event_data->>'entity_id' = v_force_fail_id::text AND event_name = 'operation_created'
  ) THEN
    ALTER TABLE public.analytics_events DROP CONSTRAINT tmp_analytics_force_fail;
    RAISE EXCEPTION 'GATE ANALYTICS-EVENTS-REVIVAL (migración) FAILED: no debería existir operation_created cuando el CHECK forzado bloquea el INSERT del emisor.';
  END IF;

  ALTER TABLE public.analytics_events DROP CONSTRAINT tmp_analytics_force_fail;

  RAISE NOTICE 'GATE ANALYTICS-EVENTS-REVIVAL (migración) PASSED: emisión con payload/account_id correctos, first_operation único, degrade-don''t-fail verificado.';

  -- Limpieza hijo→padre por email del anchor (accounts=0 al final).
  DELETE FROM public.analytics_events      WHERE user_id = v_user_id;
  DELETE FROM public.expenses              WHERE account_id = v_account_id;
  DELETE FROM public.cashboxes             WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
  DELETE FROM public.branches              WHERE account_id = v_account_id;
  DELETE FROM public.account_members       WHERE account_id = v_account_id;
  DELETE FROM public.accounts              WHERE id = v_account_id;
  DELETE FROM public.profiles              WHERE id = v_user_id;
  DELETE FROM public.email_logs            WHERE user_id = v_user_id;
  DELETE FROM public.operation_idempotency WHERE user_id = v_user_id;
  DELETE FROM auth.users                   WHERE id = v_user_id;

EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE 'GATE ANALYTICS-EVENTS-REVIVAL%' THEN
      RAISE;
    END IF;
    -- Best-effort cleanup si algo falló a mitad de camino (p.ej. contexto
    -- inesperado en prod). Nunca dejar basura colgada del anchor sintético.
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'tmp_analytics_force_fail') THEN
        ALTER TABLE public.analytics_events DROP CONSTRAINT tmp_analytics_force_fail;
      END IF;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    BEGIN
      IF v_account_id IS NOT NULL THEN
        DELETE FROM public.analytics_events WHERE user_id = v_user_id;
        DELETE FROM public.expenses         WHERE account_id = v_account_id;
        DELETE FROM public.cashboxes        WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
        DELETE FROM public.branches         WHERE account_id = v_account_id;
        DELETE FROM public.account_members  WHERE account_id = v_account_id;
        DELETE FROM public.accounts         WHERE id = v_account_id;
      END IF;
      DELETE FROM public.profiles              WHERE id = v_user_id;
      DELETE FROM public.email_logs            WHERE user_id = v_user_id;
      DELETE FROM public.operation_idempotency WHERE user_id = v_user_id;
      DELETE FROM auth.users                   WHERE id = v_user_id;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;

-- =============================================================================
-- END OF MIGRATION 20260914000001_analytics_events_revival.sql
-- =============================================================================
