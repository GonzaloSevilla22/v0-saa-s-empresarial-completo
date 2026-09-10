-- ============================================================================
-- importador-gastos-transaccional (2026-09-09)
--
-- El importador de gastos deja de emitir una llamada HTTP por fila y pasa a
-- ser UNA SOLA transacción de servidor (DEC-24): todo el archivo o nada,
-- reporte de errores fila por fila en el retorno normal. `rpc_import_expenses`
-- INVOCA `rpc_create_expense` por fila — no reimplementa ni una sola regla del
-- alta (kind derivado del catálogo, rechazo de credit, guards de sucursal /
-- centro de costo / cuenta bancaria / período conciliado). Molde copiado de
-- `rpc_import_bank_statement` (C3, bank-reconciliation): dedupe de dominio por
-- (account_id, file_hash) + idempotencia técnica vía `operation_idempotency`.
--
-- Integridad de función — verificado contra el cuerpo VIVO el 2026-09-09
-- (md5 sin \r del checkout Windows; el checkout local con \r da un md5
-- distinto pero EQUIVALENTE, ver design.md §Context):
--   rpc_create_expense(text,numeric,date,text,uuid,uuid,uuid,uuid,uuid)
--     = c8f2ef987a6efe06ba0303e93d367d6a (12701 bytes) — NO SE TOCA.
--   _pay_resolve_bank_account(uuid,uuid,uuid)
--     = 0a9dcc86484b07a7bf66a52c64b213d0 (1488 bytes) — NO SE TOCA.
--   rpc_import_bank_statement(text,uuid,text,text,jsonb)
--     = 78131fb9f169485e70508be5664dca24 (5504 bytes) — molde, NO SE TOCA.
--   _pay_register_operation_bank_movement(...)
--     = 89bd5f041fbee39a44925d1f3aff61c6 (3231 bytes) — NO SE TOCA (llamada
--       indirecta, dentro de rpc_create_expense).
--
-- ERRCODEs nuevos (barrido de P0[0-9]{3} sobre el repo, ambos libres):
--   P0427 → payload del lote malformado (no es array, vacío, tope excedido,
--           fila sin campos mínimos, metadata de archivo faltante) — 422.
--   P0429 → señal INTERNA de rollback del lote (errores de fila o
--           simulación) — NUNCA sale de la función, se captura en su propio
--           EXCEPTION (D2 del design). No requiere mapeo en errors.py.
--
-- Idempotente: reaplicable sin duplicar nada (IF NOT EXISTS / DROP+CREATE /
-- CREATE OR REPLACE en todo el archivo).
-- ============================================================================

-- ── 1) Tabla expense_imports — espejo mínimo de bank_statement_imports ──────

CREATE TABLE IF NOT EXISTS public.expense_imports (
  id             uuid        NOT NULL DEFAULT gen_random_uuid(),
  account_id     uuid        NOT NULL REFERENCES public.accounts(id),
  imported_by    uuid        NOT NULL,
  file_name      text        NOT NULL,
  file_hash      text        NOT NULL,
  row_count      integer     NOT NULL,
  imported_count integer     NOT NULL DEFAULT 0,
  created_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT expense_imports_pkey PRIMARY KEY (id),
  CONSTRAINT expense_imports_row_count_check CHECK (row_count > 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS expense_imports_account_hash_uq
  ON public.expense_imports (account_id, file_hash);

ALTER TABLE public.expense_imports ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS expense_imports_select ON public.expense_imports;
CREATE POLICY expense_imports_select
  ON public.expense_imports
  FOR SELECT
  USING (account_id IN (SELECT public.current_account_ids()));

-- Sin INSERT/UPDATE/DELETE para ningún rol de aplicación: la escritura es
-- exclusiva de rpc_import_expenses (SECURITY DEFINER). Nada para `anon`,
-- alineado con 20261035000001_revoke_anon_table_writes.sql.
--
-- ⚠️ `authenticated` (y `service_role`) reciben INSERT/UPDATE/DELETE/TRUNCATE
-- por ALTER DEFAULT PRIVILEGES en cuanto la tabla nace — GRANT SELECT solo NO
-- alcanza para dejarlo en sólo-lectura, hace falta el REVOKE explícito de los
-- cuatro privilegios de escritura (medido en la base local: `authenticated`
-- ya tenía INSERT/UPDATE/DELETE/TRUNCATE sobre expense_imports recién creada,
-- antes de este bloque).
REVOKE ALL ON public.expense_imports FROM PUBLIC;
REVOKE ALL ON public.expense_imports FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.expense_imports FROM authenticated;
GRANT SELECT ON public.expense_imports TO authenticated;

COMMENT ON TABLE public.expense_imports IS
  'importador-gastos-transaccional: una fila por lote de importación de gastos aplicado. '
  'Escritura exclusiva de rpc_import_expenses (SECURITY DEFINER). Espejo reducido de bank_statement_imports.';

-- ── 2) expenses.import_id — trazabilidad de qué gasto vino de qué lote ─────

ALTER TABLE public.expenses ADD COLUMN IF NOT EXISTS import_id uuid;

ALTER TABLE public.expenses DROP CONSTRAINT IF EXISTS expenses_import_id_fkey;
ALTER TABLE public.expenses
  ADD CONSTRAINT expenses_import_id_fkey
  FOREIGN KEY (import_id) REFERENCES public.expense_imports(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_expenses_import_id ON public.expenses (import_id);

-- ── 3) operation_idempotency.operation_kind — sumar 'expense_import' ───────
-- Lista copiada de la definición VIVA (pg_get_constraintdef), NO del último
-- archivo de migración que la tocó (checkpoint 1.4).

ALTER TABLE public.operation_idempotency
  DROP CONSTRAINT IF EXISTS operation_idempotency_operation_kind_check;
ALTER TABLE public.operation_idempotency
  ADD CONSTRAINT operation_idempotency_operation_kind_check
  CHECK (operation_kind = ANY (ARRAY[
    'sale', 'purchase', 'payment_received', 'payment_made', 'supplier_charge',
    'bank_movement', 'event_consumer', 'bank_statement_import',
    'cash_session_close', 'subscription_webhook', 'credit_note',
    'expense_import'
  ]::text[]));

COMMENT ON CONSTRAINT operation_idempotency_operation_kind_check ON public.operation_idempotency IS
  'importador-gastos-transaccional: suma expense_import al vocabulario cerrado de operation_kind.';

-- ── 4) rpc_import_expenses — la unidad de trabajo del lote ─────────────────
--
-- Todo o nada (D2): un bloque BEGIN...EXCEPTION de PL/pgSQL es una
-- SUBTRANSACCIÓN — cuando su excepción se captura, TODO el estado de base de
-- datos escrito dentro del bloque se deshace y la transacción exterior queda
-- SANA (no abortada). Las VARIABLES LOCALES de PL/pgSQL, en cambio, NO se
-- deshacen con ese rollback — es la única razón por la que v_errors/v_imported
-- sobreviven al RAISE deliberado y pueden volver por el RETURN normal. Esto
-- importa porque con tenancy_tx_scope_enabled ON el request de FastAPI corre
-- DENTRO de una transacción explícita: si la excepción escapara de esta
-- función, esa transacción quedaría abortada (25P02) y el service no podría
-- volver a tocar la base para construir la respuesta.

CREATE OR REPLACE FUNCTION public.rpc_import_expenses(
  p_idempotency_key text,
  p_rows jsonb,
  p_file_name text,
  p_file_hash text,
  p_default_payment_method_id uuid DEFAULT NULL,
  p_default_branch_id uuid DEFAULT NULL,
  p_default_cost_center_id uuid DEFAULT NULL,
  p_fallback_bank_account_id uuid DEFAULT NULL,
  p_dry_run boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid              uuid;
  v_account_id       uuid;
  v_row_count        integer;
  v_bad_rows         integer;
  v_import_id        uuid;
  v_inserted         integer;
  v_existing_op      uuid;
  v_existing_import  public.expense_imports%ROWTYPE;
  v_committed        boolean := true;
  v_imported         integer := 0;
  v_errors           jsonb := '[]'::jsonb;
  v_notices          jsonb := '[]'::jsonb;
  r                  record;
  v_payment_method_id uuid;
  v_branch_id        uuid;
  v_cost_center_id   uuid;
  v_bank_account_id  uuid;
  v_kind             text;
  v_expense_result   jsonb;
  v_expense_id       uuid;
BEGIN
  -- ── Guards de sesión / tenant / rol de escritura (idénticos a rpc_create_
  -- expense y rpc_import_bank_statement: el tenant se resuelve SIEMPRE desde
  -- la SESIÓN, nunca desde un parámetro) ────────────────────────────────────
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- ── Validación de FORMA del payload (P0427) — fuera del bloque de lote:
  -- un payload malformado no es un error de fila, es un error de protocolo ──
  IF p_file_name IS NULL OR btrim(p_file_name) = ''
     OR p_file_hash IS NULL OR btrim(p_file_hash) = '' THEN
    RAISE EXCEPTION 'import_payload_invalido: file_name y file_hash son obligatorios'
      USING ERRCODE = 'P0427';
  END IF;

  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'import_payload_invalido: p_rows debe ser un array JSON de filas de gasto'
      USING ERRCODE = 'P0427';
  END IF;

  v_row_count := jsonb_array_length(p_rows);
  IF v_row_count < 1 THEN
    RAISE EXCEPTION 'import_payload_invalido: el archivo no tiene filas de datos'
      USING ERRCODE = 'P0427';
  END IF;
  IF v_row_count > 500 THEN
    RAISE EXCEPTION 'import_cap_excedido: máximo 500 filas por lote (recibidas %) — partí el archivo en lotes más chicos', v_row_count
      USING ERRCODE = 'P0427';
  END IF;

  -- Shape mínimo por fila: row_no, description, category, amount y date no
  -- nulos (mismo criterio que rpc_import_bank_statement). Las tres columnas
  -- de catálogo (payment_method_name/branch_name/cost_center_name) son
  -- SIEMPRE opcionales (D4).
  SELECT COUNT(*) INTO v_bad_rows
  FROM jsonb_to_recordset(p_rows) AS x(
    row_no int, description text, category text, amount numeric, date date,
    payment_method_name text, branch_name text, cost_center_name text
  )
  WHERE x.row_no IS NULL OR x.description IS NULL OR x.category IS NULL
     OR x.amount IS NULL OR x.date IS NULL;

  IF v_bad_rows > 0 THEN
    RAISE EXCEPTION 'import_payload_invalido: % fila(s) sin row_no/description/category/amount/date', v_bad_rows
      USING ERRCODE = 'P0427';
  END IF;

  -- ── Subtransacción del LOTE (D2) ──────────────────────────────────────────
  BEGIN
    -- Dedupe de dominio (D7): mismo archivo ya importado por esta cuenta →
    -- replay, sin escribir un segundo lote. Corre incluso en dry_run: no hay
    -- nada nuevo que deshacer si esta rama se toma (ningún INSERT precede).
    SELECT * INTO v_existing_import
    FROM public.expense_imports
    WHERE account_id = v_account_id AND file_hash = p_file_hash;

    IF FOUND THEN
      RETURN jsonb_build_object(
        'committed',  true,
        'import_id',  v_existing_import.id,
        'imported',   v_existing_import.imported_count,
        'errors',     '[]'::jsonb,
        'notices',    '[]'::jsonb,
        'replayed',   true,
        'dry_run',    false
      );
    END IF;

    -- Idempotencia técnica (D7): slot en operation_idempotency. Un reintento
    -- con la misma clave (p.ej. la simulación y la confirmación del MISMO
    -- archivo comparten clave — task 7.4) recupera el lote ya aplicado.
    v_import_id := gen_random_uuid();

    INSERT INTO public.operation_idempotency
      (user_id, idempotency_key, operation_kind, operation_id)
    VALUES
      (v_uid, p_idempotency_key, 'expense_import', v_import_id)
    ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    IF v_inserted = 0 THEN
      SELECT operation_id INTO v_existing_op
      FROM public.operation_idempotency
      WHERE user_id = v_uid
        AND operation_kind = 'expense_import'
        AND idempotency_key = p_idempotency_key;

      SELECT * INTO v_existing_import
      FROM public.expense_imports
      WHERE id = v_existing_op;

      IF v_existing_import.id IS NOT NULL THEN
        RETURN jsonb_build_object(
          'committed',  true,
          'import_id',  v_existing_import.id,
          'imported',   v_existing_import.imported_count,
          'errors',     '[]'::jsonb,
          'notices',    '[]'::jsonb,
          'replayed',   true,
          'dry_run',    false
        );
      END IF;
      -- v_existing_import.id IS NULL: la clave se usó para un lote que se
      -- RECHAZÓ (D2 — "un lote rechazado no quema la clave"). Como el INSERT
      -- de operation_idempotency de ESE intento anterior vivía dentro de SU
      -- propio bloque de lote, quedó deshecho junto con todo lo demás — así
      -- que acá nunca deberíamos entrar (el ON CONFLICT no tendría con qué
      -- chocar). Se deja la rama por defensa en profundidad: si de algún modo
      -- ocurriera, se sigue de largo y se procesa como un lote nuevo con un
      -- v_import_id recién generado más abajo — nunca se retorna un resultado
      -- vacío en silencio.
      v_import_id := gen_random_uuid();
      INSERT INTO public.operation_idempotency
        (user_id, idempotency_key, operation_kind, operation_id)
      VALUES
        (v_uid, p_idempotency_key || ':' || v_import_id::text, 'expense_import', v_import_id)
      ON CONFLICT DO NOTHING;
    END IF;

    -- Fila de importación (D7) — nace con imported_count=0 y se corrige al
    -- final del lote si commitea.
    INSERT INTO public.expense_imports
      (id, account_id, imported_by, file_name, file_hash, row_count, imported_count)
    VALUES
      (v_import_id, v_account_id, v_uid, btrim(p_file_name), p_file_hash, v_row_count, 0);

    -- ── Loop por fila, cada una en su propia subtransacción (D3) ───────────
    FOR r IN
      SELECT * FROM jsonb_to_recordset(p_rows) AS x(
        row_no int, description text, category text, amount numeric, date date,
        payment_method_name text, branch_name text, cost_center_name text
      )
      ORDER BY x.row_no
    LOOP
      BEGIN
        v_payment_method_id := NULL;
        v_branch_id         := NULL;
        v_cost_center_id    := NULL;
        v_bank_account_id   := NULL;
        v_kind               := NULL;

        -- Forma de pago: nombre → uuid, SÓLO activas y no borradas de ESTA
        -- cuenta (D4). Celda vacía → default del lote (o NULL). Nombre que
        -- NO resuelve → error de fila, NUNCA default silencioso.
        IF r.payment_method_name IS NOT NULL AND btrim(r.payment_method_name) <> '' THEN
          SELECT id INTO v_payment_method_id
          FROM public.payment_methods
          WHERE account_id = v_account_id AND is_active = TRUE AND deleted_at IS NULL
            AND lower(btrim(name)) = lower(btrim(r.payment_method_name));
          IF NOT FOUND THEN
            RAISE EXCEPTION 'payment_method_name_not_found: la forma de pago "%" no existe en el catálogo de la cuenta', r.payment_method_name
              USING ERRCODE = 'P0404';
          END IF;
        ELSE
          v_payment_method_id := p_default_payment_method_id;
        END IF;

        -- Sucursal: mismo criterio (branches no tiene deleted_at, sólo is_active).
        IF r.branch_name IS NOT NULL AND btrim(r.branch_name) <> '' THEN
          SELECT id INTO v_branch_id
          FROM public.branches
          WHERE account_id = v_account_id AND is_active = TRUE
            AND lower(btrim(name)) = lower(btrim(r.branch_name));
          IF NOT FOUND THEN
            RAISE EXCEPTION 'branch_name_not_found: la sucursal "%" no existe en el catálogo de la cuenta', r.branch_name
              USING ERRCODE = 'P0404';
          END IF;
        ELSE
          v_branch_id := p_default_branch_id;
        END IF;

        -- Centro de costo: mismo criterio que forma de pago.
        IF r.cost_center_name IS NOT NULL AND btrim(r.cost_center_name) <> '' THEN
          SELECT id INTO v_cost_center_id
          FROM public.cost_centers
          WHERE account_id = v_account_id AND is_active = TRUE AND deleted_at IS NULL
            AND lower(btrim(name)) = lower(btrim(r.cost_center_name));
          IF NOT FOUND THEN
            RAISE EXCEPTION 'cost_center_name_not_found: el centro de costo "%" no existe en el catálogo de la cuenta', r.cost_center_name
              USING ERRCODE = 'P0404';
          END IF;
        ELSE
          v_cost_center_id := p_default_cost_center_id;
        END IF;

        -- kind informativo (NO autoritativo — rpc_create_expense vuelve a
        -- derivarlo con su propio guard, que es la fuente de verdad). Se usa
        -- acá SOLO para decidir si corresponde intentar el respaldo bancario
        -- del lote (D1 de este design) y para el aviso cash_not_posted (D6).
        -- Un payment_method_id ajeno/inactivo/inexistente deja v_kind en
        -- NULL: la fila igual pasa por rpc_create_expense, que es quien la
        -- rechaza con el P0404 real.
        IF v_payment_method_id IS NOT NULL THEN
          SELECT kind INTO v_kind
          FROM public.payment_methods
          WHERE id = v_payment_method_id AND account_id = v_account_id
            AND is_active = TRUE AND deleted_at IS NULL;
        END IF;

        -- Respaldo de cuenta bancaria (D1/D5): SÓLO se aplica si la forma de
        -- pago NO tiene ya un destino configurado — el configurado SIEMPRE
        -- conserva precedencia. _pay_resolve_bank_account(cuenta, pm, NULL)
        -- es el MISMO helper que usa rpc_create_expense: no hay una segunda
        -- definición de "qué cuenta corresponde".
        IF v_kind IN ('transfer', 'card', 'check', 'wallet')
           AND public._pay_resolve_bank_account(v_account_id, v_payment_method_id, NULL) IS NULL
        THEN
          v_bank_account_id := p_fallback_bank_account_id;
        END IF;

        -- ── ALTA — invoca rpc_create_expense, NO la reimplementa (D1) ──────
        -- p_cash_session_id: SIEMPRE NULL en el lote (D6) — el lote NUNCA
        -- postea en caja, cualquiera sea el kind, la fecha o el estado de las
        -- sesiones de la cuenta. Es NO-OP para rpc_create_expense (no un
        -- rechazo): el gasto se registra igual, sin efecto en caja.
        v_expense_result := public.rpc_create_expense(
          r.category, r.amount, r.date, r.description,
          v_branch_id, v_cost_center_id, v_payment_method_id,
          NULL,               -- p_cash_session_id: SIEMPRE NULL (D6)
          v_bank_account_id
        );

        v_expense_id := (v_expense_result ->> 'expense_id')::uuid;

        UPDATE public.expenses SET import_id = v_import_id WHERE id = v_expense_id;

        -- D6: aviso obligatorio, nunca silencioso, para toda fila cuyo kind
        -- resuelto es 'cash' — el gasto SÍ se registró, pero no movió caja.
        IF v_kind = 'cash' THEN
          v_notices := v_notices || jsonb_build_object(
            'row', r.row_no,
            'code', 'cash_not_posted',
            'message', 'Gasto registrado sin impacto en la caja — para que impacte el arqueo, cargalo desde el formulario.'
          );
        END IF;

        v_imported := v_imported + 1;
      EXCEPTION WHEN OTHERS THEN
        -- D3: el SQLSTATE viaja siempre, incluso para un error ESTRUCTURAL
        -- (no de dominio) — nunca se traga en silencio, y el lote entero se
        -- rechaza igual más abajo.
        v_errors := v_errors || jsonb_build_object(
          'row', r.row_no,
          'code', SQLSTATE,
          'message', SQLERRM
        );
      END;
    END LOOP;

    -- D2/D9: cualquier error de fila O modo simulación fuerza el rollback de
    -- TODO el bloque de lote (gasto, movimientos, expense_imports, el slot de
    -- idempotencia — todo). Las variables locales (v_errors/v_imported/
    -- v_notices) sobreviven y viajan por el RETURN normal de más abajo.
    IF jsonb_array_length(v_errors) > 0 OR p_dry_run THEN
      RAISE EXCEPTION 'batch_rollback' USING ERRCODE = 'P0429';
    END IF;

    UPDATE public.expense_imports SET imported_count = v_imported WHERE id = v_import_id;
  EXCEPTION WHEN SQLSTATE 'P0429' THEN
    v_committed := false;
  END;

  RETURN jsonb_build_object(
    'committed',  v_committed,
    'import_id',  CASE WHEN v_committed THEN v_import_id ELSE NULL END,
    'imported',   v_imported,
    'errors',     v_errors,
    'notices',    v_notices,
    'replayed',   false,
    'dry_run',    p_dry_run
  );
END;
$function$;

-- ACLs explícitas EN EL MISMO ARCHIVO que la función (v3-api-standards):
-- función nueva → CREATE OR REPLACE alcanza, sin DROP previo, sin riesgo de
-- overload 42725.
REVOKE ALL ON FUNCTION public.rpc_import_expenses(
  text, jsonb, text, text, uuid, uuid, uuid, uuid, boolean
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_import_expenses(
  text, jsonb, text, text, uuid, uuid, uuid, uuid, boolean
) FROM anon;
GRANT EXECUTE ON FUNCTION public.rpc_import_expenses(
  text, jsonb, text, text, uuid, uuid, uuid, uuid, boolean
) TO authenticated;

COMMENT ON FUNCTION public.rpc_import_expenses(
  text, jsonb, text, text, uuid, uuid, uuid, uuid, boolean
) IS
  'importador-gastos-transaccional: lote transaccional de alta de gastos, todo o nada. '
  'Invoca rpc_create_expense por fila (no duplica sus reglas). Nunca postea en caja '
  '(p_cash_session_id siempre NULL). Idempotente por clave y deduplicado por file_hash. '
  'p_dry_run=true ejecuta el mismo camino y siempre revierte (vista previa).';
