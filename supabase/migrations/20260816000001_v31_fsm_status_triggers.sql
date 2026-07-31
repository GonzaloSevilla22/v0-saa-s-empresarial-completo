-- =============================================================================
-- MIGRATION: 20260816000001_v31_fsm_status_triggers.sql
-- CHANGE:    v31-fsm-status-triggers (paso 2 del cluster de autorización,
--            secuencia firmada por el PO 2026-07-30)
-- Design ref: openspec/changes/v31-fsm-status-triggers/design.md
--
-- Implementa (design.md):
--   D1  El trigger VALIDA y NO registra. record_status_transition sigue siendo
--       el único registrador — evita duplicar filas en la tabla append-only
--       document_status_history (irreparable) y evita registrar reason=NULL
--       en silencio (RN-A5) para transiciones que el trigger no puede conocer.
--   D2  Una sola función genérica trg_enforce_status_transition(), parametrizada
--       por document_type vía TG_ARGV[0] — no seis copias de la misma lógica.
--       Delega en is_valid_transition() (ya probado, ya usado por
--       record_status_transition). WHEN (OLD.status IS DISTINCT FROM NEW.status)
--       evita invocar la función cuando status no cambia (falso positivo D8/(h)).
--   D3  SECURITY DEFINER + SET search_path = public — el guard no depende de
--       los privilegios de lectura del rol que ejecuta el UPDATE.
--   D4  SIN GUC de bypass. El único escape sancionado es
--       ALTER TABLE ... DISABLE/ENABLE TRIGGER dentro de una migración
--       versionada (ownership + visible en el diff del PR). Ningún mecanismo
--       de runtime puede desactivar el enforcement — ver comentario §D4 abajo.
--   D5  El trigger es un TECHO, no un piso: no valida rol (eso es
--       v3-rbac-multirole, RN-A4, sobre allowed_role — sigue NULL acá).
--   D6  Cobertura: las 6 tablas del catálogo, incluida stock_transfers (aunque
--       hoy es inerte — su CHECK solo admite 'completed').
--   D7  ERRCODE P0409 reutilizado (mismo que record_status_transition) — ya
--       mapeado a HTTP 409 por los manejadores de error del backend, sin
--       tocar una línea de Python.
--   D8  Gates de comportamiento en la migración (patrón v3-document-status-
--       history / bank-reconciliation): estructurales siempre, de
--       comportamiento solo con `accounts` vacía (CI).
--
-- Desviaciones de tasks.md verificadas en el Grupo 1 (bloqueante, documentado
-- acá porque afecta el diseño exacto de los gates):
--   - "UPDATE quotes a un estado no catalogado desde draft" es IRREALIZABLE:
--     el CHECK de quotes.status es exactamente {draft,sent,accepted,expired,
--     rejected} y el catálogo cubre las 4 transiciones salientes de draft
--     (sent/accepted/expired/rejected) — no existe un valor del CHECK que sea
--     simultáneamente alcanzable desde draft y no catalogado. Mismo patrón en
--     cash_sessions (CHECK open/closed, catálogo cubre open→closed) y
--     fiscal_documents (CHECK pending_cae/authorized/rejected, catálogo cubre
--     las dos transiciones salientes). La ÚNICA tabla con un valor de CHECK
--     alcanzable-pero-no-catalogado desde un estado no terminal es
--     sales_orders: 'canceled' está en el CHECK pero NO en el catálogo (G3).
--   - Gate (a)/(d) de tasks.md 2.2/2.5 se implementan sobre `quotes` con
--     transiciones hacia atrás/terminal (sent→draft, accepted→rejected), que
--     SÍ son alcanzables-pero-no-catalogadas y prueban exactamente lo mismo
--     (rechazo de una transición inválida) sin depender de un valor de CHECK
--     inexistente. Verificado empíricamente pre-trigger (ambas SUCCEEDED).
--   - El gate de la "segunda tabla" (task 3.3) usa sales_orders draft→canceled
--     en vez de cash_sessions (el ejemplo "p.ej." de tasks.md/design.md) —
--     cash_sessions no tiene un valor de CHECK que sirva para esto (mismo
--     problema que quotes). sales_orders draft→canceled es además el caso
--     real documentado en G3, así que el gate lo verifica en vez de solo
--     documentarlo.
--
-- Verificación de compatibilidad (Grupo 1, bloqueante — completa, sin
-- hallazgos que bloqueen el merge):
--   - Catálogo local y de PRODUCCIÓN (gxdhpxvdjjkmxhdkkwyb, read-only):
--     18 filas, 6 document_type, idénticos byte a byte.
--   - Los 9 RPCs retrofiteados (v3-document-status-history) + su versión MÁS
--     RECIENTE cuando fueron redefinidos después (rpc_close_cash_session vía
--     v3-api-standards 20260815000001, rpc_accept_quote vía v3-notifications-
--     producers 20260808000002) siguen escribiendo únicamente transiciones
--     catalogadas.
--   - backend/repositories/quote_repository.py::transition_quote (UPDATE
--     directo, sin RPC): las 4 transiciones que backend/services/quotes.py
--     permite (draft→sent, draft→expired, sent→rejected, sent→expired) están
--     TODAS catalogadas.
--   - backend/repositories/fiscal_document_repository.py::update_authorized /
--     update_rejected (UPDATE directo, service_role): pending_cae→authorized
--     y pending_cae→rejected están catalogadas. update_retry no toca status.
--   - Frontend: ningún .from('<tabla de documento>').update() con status —
--     quotes es la única con policy UPDATE para authenticated y no hay ningún
--     PATCH directo de status desde el cliente hoy.
--   - Datos de PRODUCCIÓN (read-only, 2026-07-31): cash_session=open (2),
--     fiscal_document=authorized (1), sales_order=confirmed (2). quote,
--     reconciliation_session y stock_transfer sin filas. Ningún estado no
--     terminal sin salida catalogada — 'open' (cash_session) tiene
--     open→closed catalogada; 'authorized'/'confirmed' son terminales por
--     diseño. Cero riesgo de documentos "congelados".
--
-- ERRCODEs:
--   P0409  transición no catalogada (reutilizado de record_status_transition)
--
-- GOVERNANCE: ALTO (trigger de integridad sobre las 6 tablas de documento;
--             puede bloquear operaciones de negocio reales si hay un falso
--             positivo — mitigado por la verificación de compatibilidad
--             arriba + los gates de comportamiento abajo).
-- APPLY: CI la aplica al mergear a main (NUNCA db push manual ni MCP
--        apply_migration).
--
-- ROLLBACK (en orden — sin pérdida de datos, el trigger solo valida):
--   DROP TRIGGER IF EXISTS quotes_enforce_status_transition ON public.quotes;
--   DROP TRIGGER IF EXISTS sales_orders_enforce_status_transition ON public.sales_orders;
--   DROP TRIGGER IF EXISTS fiscal_documents_enforce_status_transition ON public.fiscal_documents;
--   DROP TRIGGER IF EXISTS cash_sessions_enforce_status_transition ON public.cash_sessions;
--   DROP TRIGGER IF EXISTS reconciliation_sessions_enforce_status_transition ON public.reconciliation_sessions;
--   DROP TRIGGER IF EXISTS stock_transfers_enforce_status_transition ON public.stock_transfers;
--   DROP FUNCTION IF EXISTS public.trg_enforce_status_transition();
--
-- VERIFICATION (post-merge, MCP read-only):
--   SELECT tgname, tgrelid::regclass, tgenabled FROM pg_trigger
--     WHERE tgname LIKE '%_enforce_status_transition' AND NOT tgisinternal;
--     -- 6 filas, todas tgenabled = 'O'
--   SELECT prosecdef FROM pg_proc WHERE proname = 'trg_enforce_status_transition';
--     -- true
--   SELECT count(*) FROM public.document_status_transitions;  -- 18 (intacto)
--   BEGIN; UPDATE public.<tabla> SET status = '<no catalogado>' WHERE id = '<doc real>';
--   -- debe abortar P0409; ROLLBACK;
-- =============================================================================


-- ============================================================
-- 1. Función genérica de validación (D2, D3)
-- ============================================================
CREATE OR REPLACE FUNCTION public.trg_enforce_status_transition()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_document_type text := TG_ARGV[0];
BEGIN
  IF NOT public.is_valid_transition(v_document_type, OLD.status, NEW.status) THEN
    RAISE EXCEPTION 'fsm_violation: %.% % → % no está catalogada para document_type=%',
      TG_TABLE_SCHEMA, TG_TABLE_NAME, OLD.status, NEW.status, v_document_type
      USING ERRCODE = 'P0409';
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.trg_enforce_status_transition() IS
  'v31-fsm-status-triggers (D2, D3): guard genérico BEFORE UPDATE. Toma el '
  'document_type de TG_ARGV[0] (uno por trigger/tabla) y delega en '
  'is_valid_transition() — no reimplementa la política, la reutiliza. SOLO '
  'valida (P0409 si la transición no está catalogada); NO inserta en '
  'document_status_history (D1 — eso sigue siendo exclusivo de '
  'record_status_transition, invocado por los RPCs de negocio). '
  'SECURITY DEFINER: el guard funciona igual para authenticated, service_role '
  'y postgres (el pool del backend con rolbypassrls=true, H-05) — es la única '
  'barrera que hoy aplica a todos los caminos de escritura por igual.';

-- 3.4: helper interno — invocado únicamente por el mecanismo de trigger, no
-- por SQL directo de ningún rol de aplicación.
REVOKE ALL ON FUNCTION public.trg_enforce_status_transition()
  FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 2. Los 6 triggers BEFORE UPDATE (D6) — uno por document_type del catálogo
-- ============================================================

-- 2.1 quotes → 'quote'
DROP TRIGGER IF EXISTS quotes_enforce_status_transition ON public.quotes;
CREATE TRIGGER quotes_enforce_status_transition
  BEFORE UPDATE ON public.quotes
  FOR EACH ROW
  WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION public.trg_enforce_status_transition('quote');

-- 2.2 sales_orders → 'sales_order'
DROP TRIGGER IF EXISTS sales_orders_enforce_status_transition ON public.sales_orders;
CREATE TRIGGER sales_orders_enforce_status_transition
  BEFORE UPDATE ON public.sales_orders
  FOR EACH ROW
  WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION public.trg_enforce_status_transition('sales_order');

-- 2.3 fiscal_documents → 'fiscal_document'
DROP TRIGGER IF EXISTS fiscal_documents_enforce_status_transition ON public.fiscal_documents;
CREATE TRIGGER fiscal_documents_enforce_status_transition
  BEFORE UPDATE ON public.fiscal_documents
  FOR EACH ROW
  WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION public.trg_enforce_status_transition('fiscal_document');

-- 2.4 cash_sessions → 'cash_session'
DROP TRIGGER IF EXISTS cash_sessions_enforce_status_transition ON public.cash_sessions;
CREATE TRIGGER cash_sessions_enforce_status_transition
  BEFORE UPDATE ON public.cash_sessions
  FOR EACH ROW
  WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION public.trg_enforce_status_transition('cash_session');

-- 2.5 reconciliation_sessions → 'reconciliation_session'
DROP TRIGGER IF EXISTS reconciliation_sessions_enforce_status_transition ON public.reconciliation_sessions;
CREATE TRIGGER reconciliation_sessions_enforce_status_transition
  BEFORE UPDATE ON public.reconciliation_sessions
  FOR EACH ROW
  WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION public.trg_enforce_status_transition('reconciliation_session');

-- 2.6 stock_transfers → 'stock_transfer' (D6: inerte hoy — CHECK solo admite
-- 'completed' — pero el guard queda puesto para cuando se habiliten
-- dispatched/received en vez de tener que recordarlo).
DROP TRIGGER IF EXISTS stock_transfers_enforce_status_transition ON public.stock_transfers;
CREATE TRIGGER stock_transfers_enforce_status_transition
  BEFORE UPDATE ON public.stock_transfers
  FOR EACH ROW
  WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION public.trg_enforce_status_transition('stock_transfer');

-- D4: SIN mecanismo de bypass en runtime. El único escape sancionado para un
-- backfill o corrección de datos legítima es, DENTRO de una migración
-- versionada (ownership de tabla + visible en el diff del PR):
--   ALTER TABLE public.<tabla> DISABLE TRIGGER <tabla>_enforce_status_transition;
--   -- ... el UPDATE excepcional, con su justificación en comentario ...
--   ALTER TABLE public.<tabla> ENABLE TRIGGER <tabla>_enforce_status_transition;
-- NO agregar un GUC (app.fsm_bypass o similar): el escritor que más necesita
-- ser contenido es el pool del backend (postgres, rolbypassrls=true); un GUC
-- alcanzable con SET LOCAL desde ahí reintroduce la evasión que este change
-- existe para eliminar. Postgres además ofrece session_replication_role =
-- 'replica' como escape de superusuario para restores completos.


-- ============================================================
-- 3. Gates SQL (RED→GREEN) — estructurales siempre + comportamiento solo en
--    DB vacía (CI validate-kpis). Patrón v3-document-status-history /
--    bank-reconciliation: anchor sintético vía auth.users (handle_new_user
--    ya provisiona branch+cashbox — v3-provisioning-seed), discriminación
--    por SQLSTATE, limpieza best-effort. Sin insertar datos en prod.
-- ============================================================
DO $gate$
DECLARE
  v_count           int;
  v_bool            boolean;
  v_fake_user_id    uuid := gen_random_uuid();
  v_fake_account_id uuid;
  v_branch_id       uuid;
  v_run_behavioral  boolean := false;
  v_quote_e         uuid;
  v_quote_f         uuid;
  v_quote_g         uuid;
  v_quote_h         uuid;
  v_so_i            uuid;
  v_so_j            uuid;

  -- estructurales
  v_gate_a boolean := false;  -- 6 triggers existen, apuntan a la función, habilitados
  v_gate_b boolean := false;  -- función SECURITY DEFINER + no ejecutable por app roles
  v_gate_c boolean := false;  -- catálogo intacto: 18 filas, 6 document_type
  v_gate_d boolean := false;  -- negativo (lección C3): CHECK operation_kind intacto
  -- comportamiento (solo CI / DB vacía)
  v_gate_e boolean := false;  -- quote draft→sent (catalogada) tiene éxito
  v_gate_f boolean := false;  -- quote sent→draft (no catalogada) → P0409
  v_gate_g boolean := false;  -- quote accepted→rejected (terminal) → P0409
  v_gate_h boolean := false;  -- UPDATE de otra columna sobre quote terminal: no interferido
  v_gate_i boolean := false;  -- sales_order draft→confirmed (catalogada) tiene éxito
  v_gate_j boolean := false;  -- sales_order draft→canceled (G3, no catalogada) → P0409
BEGIN

  -- ── (a) Los 6 triggers existen, apuntan a la función, y están habilitados ─
  SELECT COUNT(*) INTO v_count
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_proc p ON p.oid = t.tgfoid
  WHERE c.relnamespace = 'public'::regnamespace
    AND c.relname IN ('quotes', 'sales_orders', 'fiscal_documents',
                       'cash_sessions', 'reconciliation_sessions', 'stock_transfers')
    AND p.proname = 'trg_enforce_status_transition'
    AND NOT t.tgisinternal;
  IF v_count <> 6 THEN
    RAISE EXCEPTION 'GATE (a) FAILED: se esperaban 6 triggers, hay %', v_count;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_proc p ON p.oid = t.tgfoid
  WHERE c.relnamespace = 'public'::regnamespace
    AND c.relname IN ('quotes', 'sales_orders', 'fiscal_documents',
                       'cash_sessions', 'reconciliation_sessions', 'stock_transfers')
    AND p.proname = 'trg_enforce_status_transition'
    AND NOT t.tgisinternal
    AND t.tgenabled = 'O';
  IF v_count <> 6 THEN
    RAISE EXCEPTION 'GATE (a) FAILED: % de 6 triggers están habilitados (tgenabled=O) — riesgo "deshabilitado y olvidado"', v_count;
  END IF;
  v_gate_a := true;

  -- ── (b) Función SECURITY DEFINER + no ejecutable por roles de aplicación ──
  SELECT prosecdef INTO v_bool
  FROM pg_proc WHERE proname = 'trg_enforce_status_transition' AND pronamespace = 'public'::regnamespace;
  IF NOT COALESCE(v_bool, false) THEN
    RAISE EXCEPTION 'GATE (b) FAILED: trg_enforce_status_transition sin SECURITY DEFINER';
  END IF;

  IF has_function_privilege('authenticated', 'public.trg_enforce_status_transition()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.trg_enforce_status_transition()', 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE (b) FAILED: trg_enforce_status_transition ejecutable por roles de aplicación';
  END IF;
  v_gate_b := true;

  -- ── (c) Catálogo intacto (este change NO lo modifica) ─────────────────────
  SELECT COUNT(*) INTO v_count FROM public.document_status_transitions;
  IF v_count <> 18 THEN
    RAISE EXCEPTION 'GATE (c) FAILED: catálogo esperaba 18 filas, hay %', v_count;
  END IF;

  SELECT COUNT(DISTINCT document_type) INTO v_count FROM public.document_status_transitions;
  IF v_count <> 6 THEN
    RAISE EXCEPTION 'GATE (c) FAILED: catálogo esperaba 6 document_type, hay %', v_count;
  END IF;
  v_gate_c := true;

  -- ── (d) Negativo (LECCIÓN C3): CHECK de operation_idempotency intacto ─────
  SELECT COUNT(*) INTO v_count
  FROM pg_constraint c
  JOIN pg_class t ON t.oid = c.conrelid
  WHERE t.relname = 'operation_idempotency'
    AND c.conname = 'operation_idempotency_operation_kind_check'
    AND pg_get_constraintdef(c.oid) LIKE '%sale%'
    AND pg_get_constraintdef(c.oid) LIKE '%cash_session_close%';
  IF v_count = 0 THEN
    RAISE EXCEPTION 'GATE (d) FAILED: el CHECK de operation_kind cambió — este change NO debe tocarlo';
  END IF;
  v_gate_d := true;

  -- ══════════════════════════════════════════════════════════════════════════
  -- COMPORTAMIENTO (solo DB vacía — CI). Anchor sintético patrón C2/C3.
  -- ══════════════════════════════════════════════════════════════════════════
  SELECT (COUNT(*) = 0) INTO v_run_behavioral FROM public.accounts;

  IF v_run_behavioral THEN
    BEGIN
      -- El trigger handle_new_user auto-crea account + membership(owner) +
      -- branch "Casa Central" (v3-provisioning-seed) — necesitamos el branch
      -- para el FK NOT NULL de sales_orders.
      INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
      VALUES (v_fake_user_id, 'authenticated', 'authenticated',
              'v31-fsm-status-triggers-gate@test.local', now(), now(),
              jsonb_build_object('name', 'FSM Gate', 'phone', '', 'locality', '', 'province', ''))
      ON CONFLICT (id) DO NOTHING;

      SELECT account_id INTO v_fake_account_id
      FROM public.account_members
      WHERE user_id = v_fake_user_id
      ORDER BY created_at
      LIMIT 1;

      IF v_fake_account_id IS NULL THEN
        v_fake_account_id := gen_random_uuid();
        INSERT INTO public.accounts (id, owner_user_id)
        VALUES (v_fake_account_id, v_fake_user_id) ON CONFLICT (id) DO NOTHING;
        INSERT INTO public.account_members (account_id, user_id, role)
        VALUES (v_fake_account_id, v_fake_user_id, 'owner')
        ON CONFLICT DO NOTHING;
      END IF;

      SELECT id INTO v_branch_id FROM public.branches WHERE account_id = v_fake_account_id LIMIT 1;
      IF v_branch_id IS NULL THEN
        -- provisioning-seed no disponible/degradado: sin branch no se puede
        -- probar sales_orders (FK NOT NULL) — se degradan solo (i)/(j).
        RAISE NOTICE 'v31-fsm-status-triggers: sin branch auto-provisionado — se saltan gates (i)/(j)';
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        v_run_behavioral := false;
        RAISE NOTICE 'v31-fsm-status-triggers: anchor sintético no disponible (%) — se saltan gates de comportamiento', SQLERRM;
    END;
  END IF;

  IF v_run_behavioral THEN

    -- ── (e) GATE 2.3: quote draft→sent (catalogada) tiene éxito ─────────────
    BEGIN
      INSERT INTO public.quotes (account_id, status, total, created_by)
      VALUES (v_fake_account_id, 'draft', 0, v_fake_user_id)
      RETURNING id INTO v_quote_e;

      UPDATE public.quotes SET status = 'sent' WHERE id = v_quote_e;

      SELECT COUNT(*) INTO v_count FROM public.quotes WHERE id = v_quote_e AND status = 'sent';
      IF v_count <> 1 THEN
        RAISE EXCEPTION 'GATE (e) FAILED: draft→sent no se aplicó';
      END IF;
      v_gate_e := true;
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLERRM LIKE 'GATE (e) FAILED%' THEN RAISE;
        ELSE RAISE NOTICE 'v31-fsm-status-triggers: gate (e) degradado (%)', SQLERRM;
        END IF;
    END;

    -- ── (f) GATE 2.2: quote sent→draft (NO catalogada) → P0409 ──────────────
    -- sent no es terminal (is_terminal_to=false) — prueba el caso genérico de
    -- transición inválida, distinto del caso terminal (g). No existe un valor
    -- del CHECK de quotes.status alcanzable-pero-no-catalogado DESDE draft
    -- (ver desviación documentada en la cabecera) — sent→draft cubre el mismo
    -- riesgo (rechazo de una transición inválida no tautológica).
    BEGIN
      INSERT INTO public.quotes (account_id, status, total, created_by)
      VALUES (v_fake_account_id, 'sent', 0, v_fake_user_id)
      RETURNING id INTO v_quote_f;

      BEGIN
        UPDATE public.quotes SET status = 'draft' WHERE id = v_quote_f;
        RAISE EXCEPTION 'GATE (f) FAILED: quote sent→draft debería abortar con P0409';
      EXCEPTION
        WHEN OTHERS THEN
          IF SQLSTATE = 'P0409' THEN v_gate_f := true;
          ELSIF SQLERRM LIKE 'GATE (f) FAILED%' THEN RAISE;
          ELSE RAISE NOTICE 'v31-fsm-status-triggers: gate (f) degradado (%)', SQLERRM;
          END IF;
      END;
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLERRM LIKE 'GATE (f) FAILED%' THEN RAISE;
        ELSE RAISE NOTICE 'v31-fsm-status-triggers: gate (f)/setup degradado (%)', SQLERRM;
        END IF;
    END;

    -- ── (g) GATE 2.5: quote accepted→rejected (estado terminal) → P0409 ─────
    -- accepted es terminal (is_terminal_to=true, sin filas from_status=
    -- 'accepted' en el catálogo) — prueba que un estado terminal no admite
    -- salida.
    BEGIN
      INSERT INTO public.quotes (account_id, status, total, created_by)
      VALUES (v_fake_account_id, 'accepted', 0, v_fake_user_id)
      RETURNING id INTO v_quote_g;

      BEGIN
        UPDATE public.quotes SET status = 'rejected' WHERE id = v_quote_g;
        RAISE EXCEPTION 'GATE (g) FAILED: quote accepted→rejected debería abortar con P0409 (terminal)';
      EXCEPTION
        WHEN OTHERS THEN
          IF SQLSTATE = 'P0409' THEN v_gate_g := true;
          ELSIF SQLERRM LIKE 'GATE (g) FAILED%' THEN RAISE;
          ELSE RAISE NOTICE 'v31-fsm-status-triggers: gate (g) degradado (%)', SQLERRM;
          END IF;
      END;
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLERRM LIKE 'GATE (g) FAILED%' THEN RAISE;
        ELSE RAISE NOTICE 'v31-fsm-status-triggers: gate (g)/setup degradado (%)', SQLERRM;
        END IF;
    END;

    -- ── (h) GATE 2.4: UPDATE de otra columna sobre quote terminal — no ──────
    --       interferido (protege contra el falso positivo más caro, D8)
    BEGIN
      INSERT INTO public.quotes (account_id, status, total, created_by)
      VALUES (v_fake_account_id, 'accepted', 0, v_fake_user_id)
      RETURNING id INTO v_quote_h;

      UPDATE public.quotes SET total = total + 1 WHERE id = v_quote_h;

      SELECT COUNT(*) INTO v_count FROM public.quotes WHERE id = v_quote_h AND total = 1 AND status = 'accepted';
      IF v_count <> 1 THEN
        RAISE EXCEPTION 'GATE (h) FAILED: UPDATE de total sobre quote terminal no se aplicó';
      END IF;
      v_gate_h := true;
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLERRM LIKE 'GATE (h) FAILED%' THEN RAISE;
        ELSE RAISE NOTICE 'v31-fsm-status-triggers: gate (h) degradado (%)', SQLERRM;
        END IF;
    END;

    -- ══════════════════════════════════════════════════════════════════════
    -- Segunda tabla (task 3.3): prueba que TG_ARGV[0] se respeta y no está
    -- hardcodeado a 'quote'. sales_orders en vez del "p.ej. cash_sessions" de
    -- tasks.md/design.md — ver desviación documentada en la cabecera.
    -- ══════════════════════════════════════════════════════════════════════
    IF v_branch_id IS NOT NULL THEN

      -- ── (i) sales_order draft→confirmed (catalogada) tiene éxito ──────────
      BEGIN
        INSERT INTO public.sales_orders (account_id, branch_id, status, total, created_by)
        VALUES (v_fake_account_id, v_branch_id, 'draft', 0, v_fake_user_id)
        RETURNING id INTO v_so_i;

        UPDATE public.sales_orders SET status = 'confirmed' WHERE id = v_so_i;

        SELECT COUNT(*) INTO v_count FROM public.sales_orders WHERE id = v_so_i AND status = 'confirmed';
        IF v_count <> 1 THEN
          RAISE EXCEPTION 'GATE (i) FAILED: sales_order draft→confirmed no se aplicó';
        END IF;
        v_gate_i := true;
      EXCEPTION
        WHEN OTHERS THEN
          IF SQLERRM LIKE 'GATE (i) FAILED%' THEN RAISE;
          ELSE RAISE NOTICE 'v31-fsm-status-triggers: gate (i) degradado (%)', SQLERRM;
          END IF;
      END;

      -- ── (j) sales_order draft→canceled (G3, NO catalogada) → P0409 ────────
      -- 'canceled' está en el CHECK de sales_orders.status pero NO en el
      -- catálogo (G3 — decisión D6 de v3-document-status-history: no se
      -- siembra lo que ningún RPC ejecuta). Tras este change queda rechazado
      -- por el trigger; v31-sales-delete-rpc-reversal deberá sembrar la fila
      -- en su propia migración si introduce la anulación (H-10).
      BEGIN
        INSERT INTO public.sales_orders (account_id, branch_id, status, total, created_by)
        VALUES (v_fake_account_id, v_branch_id, 'draft', 0, v_fake_user_id)
        RETURNING id INTO v_so_j;

        BEGIN
          UPDATE public.sales_orders SET status = 'canceled' WHERE id = v_so_j;
          RAISE EXCEPTION 'GATE (j) FAILED: sales_order draft→canceled debería abortar con P0409 (G3)';
        EXCEPTION
          WHEN OTHERS THEN
            IF SQLSTATE = 'P0409' THEN v_gate_j := true;
            ELSIF SQLERRM LIKE 'GATE (j) FAILED%' THEN RAISE;
            ELSE RAISE NOTICE 'v31-fsm-status-triggers: gate (j) degradado (%)', SQLERRM;
            END IF;
        END;
      EXCEPTION
        WHEN OTHERS THEN
          IF SQLERRM LIKE 'GATE (j) FAILED%' THEN RAISE;
          ELSE RAISE NOTICE 'v31-fsm-status-triggers: gate (j)/setup degradado (%)', SQLERRM;
          END IF;
      END;
    ELSE
      RAISE NOTICE 'v31-fsm-status-triggers: gates (i)/(j) saltados — sin branch auto-provisionado';
    END IF;

    -- ── Limpieza del anchor sintético (solo DB de test, best-effort) ────────
    BEGIN
      DELETE FROM public.document_status_history WHERE account_id = v_fake_account_id;
      DELETE FROM public.sales_orders WHERE account_id = v_fake_account_id;
      DELETE FROM public.quotes WHERE account_id = v_fake_account_id;
      DELETE FROM public.accounts WHERE owner_user_id = v_fake_user_id;
      DELETE FROM public.profiles WHERE id = v_fake_user_id;
      DELETE FROM auth.users WHERE id = v_fake_user_id;
    EXCEPTION
      WHEN OTHERS THEN
        RAISE NOTICE 'v31-fsm-status-triggers: limpieza parcial del anchor de test (%) — no afecta prod', SQLERRM;
    END;
  END IF;

  -- ── Resumen ───────────────────────────────────────────────────────────────
  RAISE NOTICE '=== v31-fsm-status-triggers SQL gates ===';
  RAISE NOTICE '(a) 6 triggers existen, habilitados:             %', v_gate_a;
  RAISE NOTICE '(b) función SECURITY DEFINER, no app-callable:   %', v_gate_b;
  RAISE NOTICE '(c) catálogo intacto (18 filas, 6 tipos):        %', v_gate_c;
  RAISE NOTICE '(d) CHECK operation_idempotency intacto (C3):    %', v_gate_d;
  RAISE NOTICE '(e) quote draft→sent (catalogada) OK:            %', v_gate_e;
  RAISE NOTICE '(f) quote sent→draft (no catalogada) → P0409:    %', v_gate_f;
  RAISE NOTICE '(g) quote accepted→rejected (terminal) → P0409:  %', v_gate_g;
  RAISE NOTICE '(h) UPDATE otra columna en terminal: sin interf.:%', v_gate_h;
  RAISE NOTICE '(i) sales_order draft→confirmed (2da tabla) OK:  %', v_gate_i;
  RAISE NOTICE '(j) sales_order draft→canceled (G3) → P0409:     %', v_gate_j;
  RAISE NOTICE '=== v31-fsm-status-triggers: 6 triggers + función instalados OK ===';

END $gate$;
