-- =============================================================================
-- gastos-forma-pago — el gasto imputa forma de pago y sus movimientos
-- concilian caja y banco.
-- =============================================================================
--
-- Pedido textual del PO (2026-08-28): "Modificar Módulo Gastos para incluir
-- identificación del gasto, ejemplo efectivo, transferencia y que estos
-- movimientos concilien caja y banco". Firma de sign-off (2026-08-29, "dale,
-- arranca con el apply") sobre los tres hechos que le cambian la experiencia:
--   (a) los 175 gastos históricos ($8.723.710,63) quedan SIN imputar y fuera
--       de la conciliación para siempre — no hay backfill honesto (D7);
--   (b) un gasto que ya impactó caja o banco pasa a ser INMUTABLE: se corrige
--       borrando y recargando (D11, P0423);
--   (c) borrar un gasto en efectivo exige la caja abierta (D8, P0426).
-- OQ-1 = opt-in de caja PRE-MARCADO; OQ-2 = selector de cuenta bancaria
-- OBLIGATORIO en el formulario + P0412 en servidor. OQ-3..OQ-11 salieron por
-- su opción recomendada (el PO autorizó el apply sin responderlas una por una,
-- precedente del proyecto).
--
-- MAX(version) de prod re-verificado 2026-08-29 (sólo SELECT, MCP) JUSTO antes
-- de escribir este archivo: 20261014000001 con 263 migraciones, idéntico al
-- último archivo de origin/main → este archivo usa 20261015000001. En este
-- proyecto la renumeración mordió tres veces; por eso se re-verifica acá y no
-- sólo al principio del apply.
--
-- GATE DE INTEGRIDAD DE FUNCIÓN (regla del proyecto, instaurada tras el G3 de
-- 20261003000001 reescrito in-place): las 11 funciones que este change
-- reescribe o de las que copia un predicado están capturadas por
-- pg_get_functiondef EN VIVO de prod en
-- openspec/changes/gastos-forma-pago/baseline/*.sql, con md5 y length. Las 11
-- coinciden EXACTO contra el stack local reseteado sobre las mismas 263
-- migraciones (cero divergencias). La reescritura de rpc_payment_method_report
-- de la sección 6 parte de ese baseline, NUNCA del archivo de migración.
--
-- REUTILIZACIÓN ANTES QUE REPETICIÓN (regla PO 2026-08-02): este archivo NO
-- crea ni un helper. Cada predicado se COPIA de venta o de compra:
--   · derivación del kind + las 3 condiciones del opt-in de caja
--     ← rpc_create_sale_operation_v2 (baseline)
--   · llamada incondicional a _pay_register_operation_bank_movement con 'out'
--     ← rpc_create_purchase_operation (baseline)
--   · guards P0423 de inmutabilidad y contrato tri-estado
--     ← rpc_atomic_update_sale_operation / rpc_atomic_update_purchase_operation
--   · compensación de las dos patas al borrar
--     ← rpc_delete_sale_operation (baseline) — CON UNA INVERSIÓN OBLIGATORIA
--       DEL GUARD DE SIGNO, documentada en la sección 5 (D8).
-- Los helpers compartidos (c28_register_cash_movement,
-- _pay_register_operation_bank_movement, _pay_resolve_bank_account,
-- _register_bank_movement) NO se tocan: el endurecimiento vive en el caller de
-- gasto (D5), porque la spec bank-movement exige que "sin cuenta resuelta la
-- venta sigue funcionando igual que antes".
--
-- ERRCODEs: CERO nuevos. P0400/P0401/P0403/P0404/P0409/P0412/P0422/P0423/
-- P0424/P0426 ya existen y ya están mapeados en backend/core/errors.py.
-- P0001 PROHIBIDO: el gate embebido en 20260804000003 §(b) lo re-lanza y
-- abortaría `supabase db reset`.
--
-- Idempotente: columna con IF NOT EXISTS, índice con IF NOT EXISTS, CHECK con
-- DROP+ADD, funciones con CREATE OR REPLACE (las 3 nuevas) o DROP+CREATE (el
-- reporte, que cambia su RETURNS TABLE — 42P13, D14), y REVOKE/GRANT explícito
-- de PUBLIC/anon/authenticated en el mismo archivo para las 4 (gotcha visto 6
-- veces en el proyecto: el default-privilege setup de Supabase hosted otorga
-- EXECUTE a anon/authenticated directamente sobre funciones nuevas del schema
-- public, "REVOKE ... FROM PUBLIC" solo no alcanza — 20261004000002).
--
-- FUERA DE ALCANCE, declarado: asiento contable del gasto (V2.6) y emisión de
-- eventos al outbox. Ninguna función de este archivo lee ni escribe
-- public.events → queda fuera del chequeo (5) del gate de ACLs. Ninguna crea
-- un helper interno con prefijo _/c2x_/c3x_ → queda fuera del chequeo (4).


-- =============================================================================
-- 1. Esquema — expenses.payment_method_id + índice + vocabulario de caja
-- =============================================================================

-- Espejo exacto de sales.payment_method_id y purchases.payment_method_id.
-- Nullable y SIN backfill: los 175 gastos históricos quedan como "Sin imputar"
-- (D7). Backfillear la etiqueta sin el libro sería inventar un dato que después
-- nadie puede distinguir de uno real.
ALTER TABLE public.expenses
    ADD COLUMN IF NOT EXISTS payment_method_id uuid NULL
        REFERENCES public.payment_methods(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.expenses.payment_method_id IS
  'gastos-forma-pago: forma de pago imputada al gasto (nullable, sin backfill).
  El kind se DERIVA en el servidor desde el catálogo y gobierna los efectos en
  libros: cash → movimiento de caja bajo opt-in; transfer/card/check/wallet →
  bank_movement; other → etiqueta sin efecto; credit → rechazado (P0400, D3:
  expenses no tiene contraparte con cuenta corriente).';

-- El filtro por forma de pago del listado y la agregación del reporte
-- recorren (account_id, payment_method_id) — mismo criterio que el índice
-- homónimo de sales/purchases.
CREATE INDEX IF NOT EXISTS idx_expenses_account_payment_method
    ON public.expenses (account_id, payment_method_id);

-- Vocabulario de caja: expense_reversal es la contra-partida del expense, con
-- el mismo patrón de contra-movimiento automático con tipo propio que
-- sale_reversal (D9). Dos taxonomías distintas que NO hay que mezclar: por
-- SIGNO expense_reversal es INGRESO (revertir un egreso repone plata — al
-- revés que sale_reversal, que es egreso); por FAMILIA del filtro del historial
-- de caja va a "Reversas", junto a sale_reversal, NO a "Ingresos".
-- DROP + ADD idempotente, mismo molde que 20261006000001 §1 (que agregó
-- 'adjustment'). Aditivo: ninguna fila histórica se invalida ni se reescribe.
ALTER TABLE public.cash_movements
  DROP CONSTRAINT IF EXISTS cash_movements_movement_type_check;

ALTER TABLE public.cash_movements
  ADD CONSTRAINT cash_movements_movement_type_check
  CHECK (movement_type = ANY (ARRAY[
    'sale'::text, 'purchase_payment'::text, 'expense'::text,
    'advance'::text, 'withdrawal'::text, 'sale_reversal'::text,
    'expense_reversal'::text, 'adjustment'::text
  ]));

COMMENT ON CONSTRAINT cash_movements_movement_type_check ON public.cash_movements IS
  'gastos-forma-pago: agrega expense_reversal — contra-movimiento automático del
  borrado de un gasto en efectivo, con tipo propio (no adjustment, que está
  reservado para la corrección manual y exige motivo). Signo esperado POSITIVO:
  revertir un egreso repone plata. Familia de UI: "Reversas", junto a
  sale_reversal (D9).';


-- =============================================================================
-- 2. rpc_create_expense — el alta del gasto como operación transaccional
-- =============================================================================
--
-- DEC-24: la unidad de trabajo es la RPC SECURITY DEFINER. Dos libros en una
-- transacción no se hacen desde asyncpg con INSERTs sueltos.
--
-- AUTORIZACIÓN DENTRO DEL DEFINER (D4): un SECURITY DEFINER deja la RLS fuera
-- de juego, así que el tenant SE RESUELVE DESDE LA SESIÓN — nunca por
-- parámetro. Es la lección directa del hotfix #454 (_pay_register_party_charge
-- recibía el account_id por parámetro con GRANT a authenticated = escritura
-- cross-tenant real).
--
-- El cuerpo está ordenado en tres tramos: (a) validaciones que no escriben,
-- (b) el INSERT del gasto, (c) los efectos en libros. Todo en la misma
-- transacción: cualquier RAISE de (c) revierte también (b).
CREATE OR REPLACE FUNCTION public.rpc_create_expense(
    p_category          text,
    p_amount            numeric,
    p_date              date,
    p_description       text DEFAULT NULL,
    p_branch_id         uuid DEFAULT NULL,
    p_cost_center_id    uuid DEFAULT NULL,
    p_payment_method_id uuid DEFAULT NULL,
    p_cash_session_id   uuid DEFAULT NULL,
    p_bank_account_id   uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid                 uuid;
  v_account_id          uuid;
  v_expense_id          uuid;
  v_branch              RECORD;
  v_gate_branch         uuid;
  v_kind                text;
  v_cash_movement_id    uuid;
  v_bank_movement_id    uuid;
  v_cash_session_status text;
  v_cash_session_branch uuid;
BEGIN
  -- ── (a) Autenticación, tenant desde la SESIÓN y rol de escritura ──────────
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede registrar el gasto'
      USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  -- ── Derivación del kind desde el catálogo ─────────────────────────────────
  -- COPIADO VERBATIM del baseline de rpc_create_sale_operation_v2: el kind se
  -- DERIVA del catálogo, nunca se acepta como texto del cliente, y el mismo
  -- predicado (id + account_id + is_active + deleted_at) cubre de una vez la
  -- forma de pago ajena, la inactiva y la borrada.
  IF p_payment_method_id IS NOT NULL THEN
    SELECT kind INTO v_kind
    FROM public.payment_methods
    WHERE id = p_payment_method_id AND account_id = v_account_id
      AND is_active = TRUE AND deleted_at IS NULL;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'payment_method_not_found or not active for this account'
        USING ERRCODE = 'P0404';
    END IF;
  END IF;

  -- ── D3: credit NO aplica a un gasto ───────────────────────────────────────
  -- expenses no tiene contraparte (ni supplier_id ni client_id): no hay cuenta
  -- corriente que cargar. Se rechaza en el servidor además de ocultarse en la
  -- UI, para que la API no sea un bypass del selector.
  IF v_kind = 'credit' THEN
    RAISE EXCEPTION 'credit_not_supported_for_expense: un gasto no tiene contraparte con cuenta corriente — para un egreso que vas a pagar después, cargalo como compra a proveedor'
      USING ERRCODE = 'P0400';
  END IF;

  -- ── Sucursal: mismo predicado y mismo COALESCE que la venta (C-26 / D6) ───
  IF p_branch_id IS NOT NULL THEN
    SELECT id, status INTO v_branch
    FROM public.branches
    WHERE id = p_branch_id AND account_id = v_account_id AND is_active = TRUE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'branch_not_found or not active for this account'
        USING ERRCODE = 'P0404';
    END IF;
    IF v_branch.status = 'closed' THEN
      RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
    END IF;
  END IF;

  v_gate_branch := COALESCE(p_branch_id, public.c26_default_branch(v_account_id));

  -- ── Centro de costo: mismo predicado que la edición de compra ─────────────
  -- (rpc_atomic_update_purchase_operation). El INSERT plano que este RPC
  -- reemplaza aceptaba cualquier cost_center_id, incluido el de otra cuenta:
  -- la FK no está scopeada por tenant.
  IF p_cost_center_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.cost_centers
      WHERE id = p_cost_center_id AND account_id = v_account_id AND is_active = TRUE
    ) THEN
      RAISE EXCEPTION 'cost_center_not_found or not active for this account'
        USING ERRCODE = 'P0404';
    END IF;
  END IF;

  -- ── D5: la cuenta bancaria deja de fallar en silencio EN EL GASTO ─────────
  -- BLOQUEANTE DE PRODUCTO MEDIDO: payment_methods con bank_account_id
  -- configurado = 0 de 37 cuentas. Con la cuenta sin resolver,
  -- _pay_register_operation_bank_movement retorna NULL SIN ERROR — o sea que,
  -- tal cual está, el pedido literal del PO ("que estos movimientos concilien
  -- banco") fallaría en silencio para el 100% de los tenants.
  --
  -- El guard vive ACÁ, en el caller, y NO en el helper: la spec bank-movement
  -- tiene un escenario explícito —"sin cuenta resuelta la venta sigue
  -- funcionando igual que antes"— y el helper es punto de paso de venta,
  -- compra y POS. El endurecimiento asimétrico es deliberado: el gasto NACE
  -- con este contrato, las ventas no.
  --
  -- CONDICIONADO a que la organización tenga al menos una cuenta bancaria
  -- activa: un guard incondicional dejaría a 33 de 37 tenants sin poder
  -- registrar un gasto por transferencia hasta que carguen una cuenta — un
  -- bloqueo de registro por un problema de configuración, el mismo error que
  -- D1 evita en caja.
  --
  -- La resolución se hace con el MISMO helper que usará después
  -- _pay_register_operation_bank_movement (override → default → NULL), así que
  -- no hay una segunda definición de "qué cuenta corresponde"; y si la cuenta
  -- informada es ajena, inactiva o borrada, el propio helper ya levanta P0412
  -- desde acá.
  IF v_kind IN ('transfer', 'card', 'check', 'wallet')
     AND public._pay_resolve_bank_account(v_account_id, p_payment_method_id, p_bank_account_id) IS NULL
     AND EXISTS (
       SELECT 1 FROM public.bank_accounts
       WHERE account_id = v_account_id AND is_active = TRUE AND deleted_at IS NULL
     )
  THEN
    RAISE EXCEPTION 'bank_account_required_for_expense: elegí la cuenta bancaria de la que sale el dinero — sin ella el gasto no aparecería nunca en la conciliación bancaria'
      USING ERRCODE = 'P0412';
  END IF;

  -- ── (b) El gasto ──────────────────────────────────────────────────────────
  -- D6: branch_id se persiste RESUELTO (COALESCE con la default), no crudo:
  -- el escenario de spec exige que un gasto sin sucursal informada quede con
  -- la sucursal por defecto de la cuenta. RN-93 estaba incumplida al 100%
  -- para gastos (0 de 175).
  INSERT INTO public.expenses
    (user_id, account_id, category, amount, description, date,
     branch_id, cost_center_id, payment_method_id)
  VALUES
    (v_uid, v_account_id, p_category, p_amount, p_description, p_date,
     v_gate_branch, p_cost_center_id, p_payment_method_id)
  RETURNING id INTO v_expense_id;

  -- ── (c) PATA DE CAJA — opt-in explícito con las tres condiciones ──────────
  -- COPIADO VERBATIM del baseline de rpc_create_sale_operation_v2 (bloque
  -- "pagos-cableados-restantes OQ-C/D4"), con las dos ÚNICAS adaptaciones que
  -- D1 autoriza:
  --   (a) p_date se declara `date` y se compara DIRECTO contra
  --       reporting_local_today(). ⚠️ PROHIBIDO `p_date timestamptz` con
  --       `p_date::date`: ese cast se resuelve en el TimeZone de la SESIÓN
  --       (UTC en este servidor) mientras reporting_local_today() es
  --       (now() AT TIME ZONE 'America/Argentina/Mendoza')::date, así que un
  --       gasto legítimo de hoy cargado entre las 21:00 y las 23:59 ART
  --       (= 00:00-02:59 UTC del día siguiente) se rechazaría con P0422 justo
  --       en la franja en que el microemprendedor cierra el día. Con `date` el
  --       resultado es invariante por construcción — y lo que ya viaja por el
  --       payload es una fecha pura (ExpenseCreate.date: datetime.date).
  --   (b) c28_register_cash_movement(sesión, -p_amount, 'expense', id_del_gasto):
  --       signo NEGATIVO (egreso) y el gasto como referencia.
  --
  -- La ausencia de p_cash_session_id es NO-OP: bloquear el alta porque no hay
  -- caja abierta convertiría un problema de arqueo en un problema de registro
  -- (D1). El helper aporta gratis P0409 (sesión abierta), P0401 (tenencia,
  -- agregada por tenancy-guard-caja-outbox — el gasto es exactamente el
  -- "caller futuro" que ese guard fue escrito para cubrir), P0422 (sucursal
  -- activa), balance_after serializado y created_by.
  IF p_cash_session_id IS NOT NULL THEN
    IF v_kind IS DISTINCT FROM 'cash' THEN
      RAISE EXCEPTION 'cash_optin_requires_cash_kind: p_cash_session_id sólo aplica si el kind derivado es cash (recibido: %)', COALESCE(v_kind, 'NULL')
        USING ERRCODE = 'P0422';
    END IF;

    SELECT cs.status, cb.branch_id INTO v_cash_session_status, v_cash_session_branch
    FROM public.cash_sessions cs
    JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
    WHERE cs.id = p_cash_session_id;

    IF v_cash_session_status IS DISTINCT FROM 'open' OR v_cash_session_branch IS DISTINCT FROM v_gate_branch THEN
      RAISE EXCEPTION 'cash_optin_requires_open_session: la sesión de caja debe estar abierta y pertenecer a la sucursal efectiva del gasto'
        USING ERRCODE = 'P0422';
    END IF;

    IF p_date <> public.reporting_local_today() THEN
      RAISE EXCEPTION 'cash_optin_requires_today: sólo se puede registrar en caja un gasto fechado hoy (%)', public.reporting_local_today()
        USING ERRCODE = 'P0422';
    END IF;

    v_cash_movement_id := public.c28_register_cash_movement(
      p_cash_session_id, -p_amount, 'expense', v_expense_id
    );
  END IF;

  -- ── PATA BANCARIA — llamada INCONDICIONAL al helper compartido ────────────
  -- CALCADA de la de rpc_create_purchase_operation (baseline), que ya despacha
  -- un EGRESO con este mismo helper. Sin ningún IF previo: el helper decide.
  -- Aporta gratis el predicado kind IN ('transfer','card','check','wallet'),
  -- la resolución override→default→NULL, la validación de la cuenta (P0412),
  -- el rechazo de cuenta bancaria sobre kind no bancario (P0400), el mapa
  -- kind→movement_type (card→card_settlement, resto out→transfer_out), el
  -- signo y el guard de período conciliado (P0424), que revierte la operación
  -- ENTERA si la fecha cae dentro de una reconciliation_sessions cerrada.
  --
  -- p_value_date = p_date, que ya es `date` (D1) y por lo tanto no arrastra
  -- ningún cast dependiente de la zona de la sesión. Va SÍ O SÍ: con NULL el
  -- movimiento caería en created_at y la sugerencia automática de conciliación
  -- (monto exacto, ventana ±3 días) se desalinearía del extracto.
  --
  -- p_branch_id = v_gate_branch: la sucursal EFECTIVA, la misma que se
  -- persistió en el gasto.
  v_bank_movement_id := public._pay_register_operation_bank_movement(
    v_account_id, v_kind, p_payment_method_id, p_bank_account_id,
    p_amount, 'out', 'expense', v_expense_id,
    p_date, v_gate_branch, NULL
  );

  RETURN jsonb_build_object(
    'expense_id',       v_expense_id,
    'branch_id',        v_gate_branch,
    'payment_method_kind', v_kind,
    'cash_movement_id', v_cash_movement_id,
    'bank_movement_id', v_bank_movement_id
  );
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_create_expense(text, numeric, date, text, uuid, uuid, uuid, uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_create_expense(text, numeric, date, text, uuid, uuid, uuid, uuid, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_create_expense(text, numeric, date, text, uuid, uuid, uuid, uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.rpc_create_expense(text, numeric, date, text, uuid, uuid, uuid, uuid, uuid) IS
  'gastos-forma-pago: alta atómica del gasto. Resuelve el tenant desde la sesión
  (nunca por parámetro — lección del hotfix #454), exige is_account_writer,
  deriva el kind del catálogo, rechaza credit (P0400, D3), persiste branch_id
  con el COALESCE de la venta (D6) y despacha los efectos en libros por kind:
  caja bajo opt-in con las 3 condiciones del servidor (D1) y banco por llamada
  incondicional al helper compartido (D2).';


-- =============================================================================
-- 3. rpc_update_expense — edición con inmutabilidad y contrato tri-estado
-- =============================================================================
--
-- D11: el gasto con dinero posteado es INMUTABLE (P0423), no se compensa. El
-- patrón de contra-asiento de asiento-venta-formulario aplica al JOURNAL, que
-- es un libro derivado, asíncrono y de nuestra propiedad exclusiva. Caja y
-- banco son distintos: la caja es un conteo FÍSICO con arqueo firmado, y el
-- banco puede estar ya conciliado contra un extracto real (y su reversa
-- toparía con el P0424 de período cerrado). El camino de corrección es borrar
-- y recargar, que rpc_delete_expense (sección 4) vuelve seguro.
--
-- D12: contrato TRI-ESTADO con el par (p_<campo>, p_<campo>_provided), calcado
-- de rpc_atomic_update_purchase_operation:
--     provided = false            → PRESERVAR el valor vigente
--     provided = true, valor uuid → reimputar
--     provided = true, valor NULL → desimputar
-- El router lo resuelve con `"<campo>" in payload.model_fields_set`, NUNCA con
-- `payload.<campo> is None`. Cierra dos pérdidas silenciosas pre-existentes:
-- el alta descartaba branch_id (0 de 175 gastos con sucursal) y la edición
-- borraba cost_center_id en cada pasada (0 de 175 con centro de costo).
--
-- category/amount/date/description conservan la semántica COALESCE del UPDATE
-- que este RPC reemplaza (NULL = no cambia): son columnas NOT NULL salvo
-- description, y no hay un caso de uso de "vaciarlas". No se les inventa un
-- tri-estado que nadie pidió.
--
-- ⚠️ La edición NO POSTEA MOVIMIENTOS, y por eso la firma NO recibe
-- p_cash_session_id ni p_bank_account_id: imputarle una forma de pago a un
-- gasto ya creado le pone la ETIQUETA y no mueve un peso en ningún libro
-- (D13). El texto de ayuda del importador tiene que decir exactamente eso.
CREATE OR REPLACE FUNCTION public.rpc_update_expense(
    p_expense_id              uuid,
    p_category                text    DEFAULT NULL,
    p_amount                  numeric DEFAULT NULL,
    p_date                    date    DEFAULT NULL,
    p_description             text    DEFAULT NULL,
    p_payment_method_id       uuid    DEFAULT NULL,
    p_payment_method_provided boolean DEFAULT false,
    p_branch_id               uuid    DEFAULT NULL,
    p_branch_provided         boolean DEFAULT false,
    p_cost_center_id          uuid    DEFAULT NULL,
    p_cost_center_provided    boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid                 uuid;
  v_account_id          uuid;
  v_old                 RECORD;
  v_branch              RECORD;
  v_final_payment_method_id uuid;
  v_final_branch_id     uuid;
  v_final_cost_center_id    uuid;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede editar el gasto'
      USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  -- Localización POR TENANT: si el gasto no aparece, P0404 — sin distinguir
  -- "no existe" de "es de otra cuenta" (D4).
  SELECT * INTO v_old
  FROM public.expenses
  WHERE id = p_expense_id AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'expense_not_found: el gasto no existe o no pertenece a esta cuenta'
      USING ERRCODE = 'P0404';
  END IF;

  -- ── D11: los dos guards de inmutabilidad, ANTES DE CUALQUIER ESCRITURA ────
  -- Mismos predicados y mismo ERRCODE que rpc_atomic_update_sale_operation
  -- (baseline). Los mensajes son distinguibles a propósito: el usuario tiene
  -- que saber cuál de los dos libros produjo el bloqueo.
  IF EXISTS (
    SELECT 1 FROM public.cash_movements cm
    WHERE cm.reference_id = p_expense_id
  ) THEN
    RAISE EXCEPTION 'expense_has_cash_movement_immutable: el gasto tiene un movimiento de caja posteado y no puede editarse — borralo y volvé a cargarlo (el borrado compensa la caja)'
      USING ERRCODE = 'P0423';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.bank_movements bm
    WHERE bm.source_doc_type = 'expense' AND bm.source_doc_ref = p_expense_id
  ) THEN
    RAISE EXCEPTION 'expense_has_bank_movement_immutable: el gasto tiene un movimiento bancario posteado y no puede editarse — borralo y volvé a cargarlo (el borrado registra el movimiento espejo)'
      USING ERRCODE = 'P0423';
  END IF;

  -- ── D12: tri-estado, campo por campo, con validación ANTES del UPDATE ─────
  IF p_payment_method_provided THEN
    IF p_payment_method_id IS NOT NULL THEN
      -- Mismo predicado que el alta: cuenta + activa + no borrada.
      IF NOT EXISTS (
        SELECT 1 FROM public.payment_methods
        WHERE id = p_payment_method_id AND account_id = v_account_id
          AND is_active = TRUE AND deleted_at IS NULL
      ) THEN
        RAISE EXCEPTION 'payment_method_not_found or not active for this account'
          USING ERRCODE = 'P0404';
      END IF;
      -- D3 también en la edición: la API no puede ser un bypass del selector.
      IF (SELECT kind FROM public.payment_methods WHERE id = p_payment_method_id) = 'credit' THEN
        RAISE EXCEPTION 'credit_not_supported_for_expense: un gasto no tiene contraparte con cuenta corriente — para un egreso que vas a pagar después, cargalo como compra a proveedor'
          USING ERRCODE = 'P0400';
      END IF;
    END IF;
    v_final_payment_method_id := p_payment_method_id;
  ELSE
    v_final_payment_method_id := v_old.payment_method_id;
  END IF;

  IF p_branch_provided THEN
    IF p_branch_id IS NOT NULL THEN
      SELECT id, status INTO v_branch
      FROM public.branches
      WHERE id = p_branch_id AND account_id = v_account_id AND is_active = TRUE;
      IF NOT FOUND OR v_branch.status = 'closed' THEN
        RAISE EXCEPTION 'branch_invalid: la sucursal no pertenece a la cuenta o no está operativa'
          USING ERRCODE = 'P0422';
      END IF;
    END IF;
    v_final_branch_id := p_branch_id;
  ELSE
    v_final_branch_id := v_old.branch_id;
  END IF;

  IF p_cost_center_provided THEN
    IF p_cost_center_id IS NOT NULL THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.cost_centers
        WHERE id = p_cost_center_id AND account_id = v_account_id AND is_active = TRUE
      ) THEN
        RAISE EXCEPTION 'cost_center_not_found or not active for this account'
          USING ERRCODE = 'P0404';
      END IF;
    END IF;
    v_final_cost_center_id := p_cost_center_id;
  ELSE
    v_final_cost_center_id := v_old.cost_center_id;
  END IF;

  UPDATE public.expenses
  SET category          = COALESCE(p_category, v_old.category),
      amount            = COALESCE(p_amount, v_old.amount),
      date              = COALESCE(p_date::timestamptz, v_old.date),
      description       = COALESCE(p_description, v_old.description),
      payment_method_id = v_final_payment_method_id,
      branch_id         = v_final_branch_id,
      cost_center_id    = v_final_cost_center_id
  WHERE id = p_expense_id AND account_id = v_account_id;

  RETURN jsonb_build_object(
    'expense_id',        p_expense_id,
    'payment_method_id', v_final_payment_method_id,
    'branch_id',         v_final_branch_id,
    'cost_center_id',    v_final_cost_center_id
  );
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_update_expense(uuid, text, numeric, date, text, uuid, boolean, uuid, boolean, uuid, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_update_expense(uuid, text, numeric, date, text, uuid, boolean, uuid, boolean, uuid, boolean) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_update_expense(uuid, text, numeric, date, text, uuid, boolean, uuid, boolean, uuid, boolean) TO authenticated;

COMMENT ON FUNCTION public.rpc_update_expense(uuid, text, numeric, date, text, uuid, boolean, uuid, boolean, uuid, boolean) IS
  'gastos-forma-pago: edición atómica del gasto. Bloquea con P0423 el gasto con
  movimiento de caja o bancario posteado, con mensajes distinguibles y ANTES de
  cualquier escritura (D11), y aplica el contrato tri-estado
  (p_<campo>, p_<campo>_provided) a forma de pago, sucursal y centro de costo
  (D12). NO postea movimientos: imputar una forma de pago por edición es sólo
  una etiqueta (D13).';


-- =============================================================================
-- 4. rpc_delete_expense — borrado con compensación de las dos patas
-- =============================================================================
--
-- D8. Copia el patrón de rpc_delete_sale_operation (baseline): resolver los
-- movimientos, compensar, y recién después borrar. Para el gasto los libros
-- compensables son EXACTAMENTE DOS —caja y banco— y ninguno más: un gasto no
-- tiene contraparte con cuenta corriente (D3), no mueve stock y no emite
-- eventos al outbox (D10).
--
-- Sin este borrado compensado, un alta que postea dinero conviviendo con el
-- DELETE crudo de expense_repository.py L52 es EXACTAMENTE el estado que
-- produjo un cargo fantasma real en producción y motivó delete-guard-ledgers
-- (204 operaciones backfilleadas).
CREATE OR REPLACE FUNCTION public.rpc_delete_expense(
    p_expense_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid              uuid;
  v_account_id       uuid;
  v_expense          RECORD;
  v_cashbox_id       uuid;
  v_cash_amount      numeric(12,2);
  v_open_session_id  uuid;
  v_cash_reversal_id uuid;
  v_bank_row         RECORD;
  v_reversed_type    text;
  v_bank_reversals   integer := 0;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede borrar el gasto'
      USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  SELECT * INTO v_expense
  FROM public.expenses
  WHERE id = p_expense_id AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'expense_not_found: el gasto no existe o no pertenece a esta cuenta'
      USING ERRCODE = 'P0404';
  END IF;

  -- ── Caja: contra-movimiento en la sesión abierta actual (P0426 si no hay) ─
  -- Copiado del baseline de rpc_delete_sale_operation (20261005000001:1205-1234)
  -- CON UNA INVERSIÓN OBLIGATORIA Y EXPLÍCITA DEL GUARD DE SIGNO.
  --
  -- ⚠️⚠️ El original es `IF v_cashbox_id IS NOT NULL AND v_cash_amount > 0`,
  -- porque los movimientos agrupados de una VENTA son de tipo 'sale' con
  -- importe POSITIVO. Los del GASTO son de tipo 'expense' con importe
  -- NEGATIVO (lo fija este mismo change: expense negativo, expense_reversal
  -- positivo). Copiado verbatim, `v_cash_amount > 0` es FALSO PARA TODO GASTO:
  -- se saltearía el bloque entero, no se registraría el expense_reversal,
  -- NUNCA se lanzaría P0426 y el DELETE procedería igual — se reintroduciría
  -- exactamente el borrado inseguro que motivó delete-guard-ledgers, desde el
  -- change que dice cerrarlo. Y sin levantar un solo error.
  --
  -- Por eso el guard correcto es `v_cash_amount < 0`, y por eso el gate tiene
  -- un CONTROL NEGATIVO obligatorio (5.4b): un test que sólo assertara "no
  -- hubo error" quedaría verde por omisión.
  --
  -- La sesión ORIGINAL nunca se toca: el ledger de caja es append-only. El
  -- contra-movimiento va SIEMPRE a la sesión abierta actual de la MISMA caja,
  -- con el mismo criterio que ya rige para el borrado de una venta en efectivo.
  SELECT cs.cashbox_id, v_sum.total
  INTO v_cashbox_id, v_cash_amount
  FROM (
    SELECT session_id, SUM(amount) AS total
    FROM public.cash_movements
    WHERE reference_id = p_expense_id AND movement_type = 'expense'
    GROUP BY session_id
  ) v_sum
  JOIN public.cash_sessions cs ON cs.id = v_sum.session_id;

  IF v_cashbox_id IS NOT NULL AND v_cash_amount < 0 THEN
    SELECT id INTO v_open_session_id
    FROM public.cash_sessions
    WHERE cashbox_id = v_cashbox_id AND status = 'open'
    ORDER BY opened_at DESC
    LIMIT 1;

    IF v_open_session_id IS NULL THEN
      RAISE EXCEPTION 'no_open_session_for_reversal: abrí la caja para poder borrar este gasto'
        USING ERRCODE = 'P0426';
    END IF;

    -- v_cash_amount es NEGATIVO, así que -v_cash_amount da el INGRESO positivo
    -- que repone la plata en el cajón.
    v_cash_reversal_id := public.c28_register_cash_movement(
      v_open_session_id, -v_cash_amount, 'expense_reversal', p_expense_id
    );
  END IF;

  -- ── Banco: espejo con dirección invertida, siempre unreconciled ───────────
  -- Loop calcado del de rpc_delete_sale_operation. Se usa _register_bank_movement
  -- (el escritor crudo) y NO _pay_register_operation_bank_movement: la reversa
  -- no tiene que volver a resolver la cuenta ni volver a evaluar el guard de
  -- período conciliado — va contra la MISMA cuenta del movimiento original.
  -- Es el único uso autorizado del escritor crudo en este change (D2).
  FOR v_bank_row IN
    SELECT id, bank_account_id, amount, movement_type, branch_id
    FROM public.bank_movements
    WHERE source_doc_type = 'expense' AND source_doc_ref = p_expense_id
  LOOP
    v_reversed_type := CASE v_bank_row.movement_type
      WHEN 'transfer_in'  THEN 'transfer_out'
      WHEN 'transfer_out' THEN 'transfer_in'
      ELSE v_bank_row.movement_type
    END;

    PERFORM public._register_bank_movement(
      v_bank_row.bank_account_id, -v_bank_row.amount, v_reversed_type,
      'expense', p_expense_id, CURRENT_DATE, v_bank_row.branch_id,
      'Reversión por borrado de gasto'
    );
    v_bank_reversals := v_bank_reversals + 1;
  END LOOP;

  -- ── El borrado, DESPUÉS de las dos compensaciones ────────────────────────
  DELETE FROM public.expenses WHERE id = p_expense_id AND account_id = v_account_id;

  RETURN jsonb_build_object(
    'expense_id',        p_expense_id,
    'deleted',           true,
    'cash_reversal_id',  v_cash_reversal_id,
    'bank_reversals',    v_bank_reversals
  );
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_delete_expense(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_delete_expense(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_delete_expense(uuid) TO authenticated;

COMMENT ON FUNCTION public.rpc_delete_expense(uuid) IS
  'gastos-forma-pago: borrado atómico del gasto con compensación de las DOS
  patas —caja (expense_reversal positivo en la sesión abierta actual de la
  misma caja, P0426 si no hay ninguna) y banco (espejo invertido)— antes del
  DELETE. ⚠️ El guard de signo está INVERTIDO respecto del de
  rpc_delete_sale_operation (v_cash_amount < 0): los movimientos de gasto son
  negativos y el guard positivo del original sería falso para todo gasto (D8).';


-- =============================================================================
-- 5. Gate ANTI-OVERLOAD de las tres RPCs nuevas
-- =============================================================================
-- Molde de 20260928000001 §9. Las tres se crean con CREATE OR REPLACE (no
-- cambian ninguna firma previa: no existían), así que un overload sólo puede
-- aparecer si alguien agrega o quita un parámetro sin el DROP correspondiente.
-- La próxima llamada posicional del backend reventaría con 42725.
DO $$
DECLARE
  v_proname text;
  v_count   integer;
BEGIN
  FOREACH v_proname IN ARRAY ARRAY[
    'rpc_create_expense',
    'rpc_update_expense',
    'rpc_delete_expense'
  ] LOOP
    SELECT COUNT(*) INTO v_count
    FROM   pg_proc p
    JOIN   pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = v_proname;

    IF v_count <> 1 THEN
      RAISE EXCEPTION 'GATE ANTI-OVERLOAD FAILED: % tiene % definiciones en public (esperaba exactamente 1) — quedó un overload fantasma y la próxima llamada posicional revienta con 42725.',
        v_proname, v_count;
    END IF;
  END LOOP;

  RAISE NOTICE 'GATE ANTI-OVERLOAD PASSED: las 3 RPCs de gasto tienen exactamente 1 definición cada una.';
END $$;


-- =============================================================================
-- 6. rpc_payment_method_report — los gastos entran al reporte [OQ-5, D14]
-- =============================================================================
--
-- El reporte se llama "formas de pago" y hoy cubre ventas y compras. Si los
-- gastos imputan forma de pago y no aparecen, el reporte MIENTE POR OMISIÓN
-- sobre un tercio del dinero.
--
-- ⚠️ MECÁNICA OBLIGATORIA — no alcanza CREATE OR REPLACE pelado.
-- La función vigente se creó con CREATE OR REPLACE SIN DROP previo
-- (20260928000001:1851) y su RETURNS TABLE tiene 7 columnas. Sumar total_spent
-- CAMBIA EL TIPO DE RETORNO y Postgres rechaza el CREATE OR REPLACE con 42P13
-- ("cannot change return type of existing function"). Entonces:
--   1. DROP FUNCTION IF EXISTS con la firma EXACTA.
--   2. CREATE con las 8 columnas.
--   3. RE-EMITIR LAS TRES ACLs en este mismo archivo: el DROP las RESETEA, y
--      sin eso la función queda con los defaults del schema public de Supabase
--      hosted, que otorgan EXECUTE a anon. El chequeo (2) del gate de ACLs es
--      la RED que atraparía el olvido; la migración no debe depender de la red.
--   4. Gate ANTI-OVERLOAD propio: si el DROP no matcheara la firma vieja, el
--      CREATE dejaría dos overloads y la próxima llamada posicional del
--      frontend reventaría con 42725.
--
-- ⚠️ EL CUERPO PARTE DEL pg_get_functiondef VIVO DE PROD, capturado en
-- openspec/changes/gastos-forma-pago/baseline/rpc_payment_method_report.sql
-- (md5 e452c30331368d3bdbc0c24bc305dda2, length 3370, verificado contra prod y
-- contra el stack local). NUNCA del archivo de migración: el antecedente es el
-- G3 de 20261003000001, reescrito in-place, cuya definición viva había
-- divergido de su archivo. Todo lo que sigue es el baseline TEXTUAL más la CTE
-- pm_expenses, la columna total_spent, el UNION y el LEFT JOIN.
--
-- Sobre la CADENA DE REAPPLY de KPI_Validation.yml: el paso re-aplica
-- 20260928000001 completo, y ese reapply YA FALLA HOY y está TOLERADO. Aborta
-- en su gate ANTI-OVERLOAD de la SECCIÓN 9 (línea 1838 medida), que corre ANTES
-- del CREATE de rpc_payment_method_report de la sección 10 (línea 1850), así
-- que con ON_ERROR_STOP=1 el archivo NUNCA llega al CREATE con la firma vieja
-- de 7 columnas y no se introduce ningún 42P13. Es una dependencia frágil y por
-- eso se VERIFICA reproduciendo la cadena en local DESPUÉS de aplicar esta
-- migración (task 1.5, segunda mitad), en vez de suponerla.

DROP FUNCTION IF EXISTS public.rpc_payment_method_report(uuid, date, date);

CREATE OR REPLACE FUNCTION public.rpc_payment_method_report(p_account_id uuid, p_start date, p_end date)
 RETURNS TABLE(payment_method_id uuid, payment_method_name text, payment_method_kind text, is_active boolean, total_sold numeric, total_purchased numeric, total_spent numeric, operation_count bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- Verify caller belongs to this account (espejo de rpc_cost_center_report).
  IF NOT EXISTS (
    SELECT 1 FROM public.account_members
    WHERE account_id = p_account_id
      AND user_id    = auth.uid()
  ) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  RETURN QUERY
  WITH
    pm_sales AS (
      SELECT
        s.payment_method_id                                       AS pm_id,
        -- RN-D: importe de línea COALESCE(total, amount).
        COALESCE(SUM(COALESCE(s.total, s.amount)), 0)             AS sold_total,
        -- RN-D: conteo de operaciones COUNT(DISTINCT COALESCE(operation_id, id)).
        COUNT(DISTINCT COALESCE(s.operation_id, s.id))::BIGINT    AS sold_ops
      FROM public.sales s
      WHERE s.account_id = p_account_id
        -- RN-D5: borde superior inclusivo hasta fin de día local.
        AND s.date >= p_start::timestamptz
        AND s.date <  (p_end + 1)::timestamptz
      GROUP BY s.payment_method_id
    ),
    pm_purchases AS (
      SELECT
        p.payment_method_id                                       AS pm_id,
        COALESCE(SUM(COALESCE(p.total, p.amount)), 0)             AS purchased_total,
        COUNT(DISTINCT COALESCE(p.operation_id, p.id))::BIGINT    AS purchased_ops
      FROM public.purchases p
      WHERE p.account_id = p_account_id
        AND p.date >= p_start::timestamptz
        AND p.date <  (p_end + 1)::timestamptz
      GROUP BY p.payment_method_id
    ),
    pm_expenses AS (
      -- gastos-forma-pago (D14): los gastos entran al reporte. Se suman por
      -- `amount` y se cuenta UNA UNIDAD POR FILA, con el mismo criterio con que
      -- rpc_cost_center_report ya los agrega: expenses no tiene operation_id ni
      -- columna total, así que el COALESCE(total, amount) y el
      -- COUNT(DISTINCT COALESCE(operation_id, id)) de arriba no aplican acá.
      SELECT
        e.payment_method_id                                       AS pm_id,
        COALESCE(SUM(e.amount), 0)                                AS spent_total,
        COUNT(*)::BIGINT                                          AS spent_rows
      FROM public.expenses e
      WHERE e.account_id = p_account_id
        AND e.date >= p_start::timestamptz
        AND e.date <  (p_end + 1)::timestamptz
      GROUP BY e.payment_method_id
    ),
    all_pm_ids AS (
      -- UNION (no UNION ALL) dedupe incluyendo la clave NULL: lo no imputado
      -- colapsa en una sola fila "Sin especificar". Los 175 gastos históricos
      -- de prod viven exactamente ahí (D7: sin backfill).
      SELECT pm_id FROM pm_sales
      UNION
      SELECT pm_id FROM pm_purchases
      UNION
      SELECT pm_id FROM pm_expenses
    )
  SELECT
    api.pm_id                                                            AS payment_method_id,
    COALESCE(pm.name, 'Sin especificar')                                 AS payment_method_name,
    pm.kind                                                              AS payment_method_kind,
    -- Las formas de pago desactivadas siguen apareciendo con su nombre
    -- histórico; la bandera deja que la UI las distinga sin consulta extra.
    COALESCE(pm.is_active, true)                                         AS is_active,
    COALESCE(ps.sold_total, 0)                                           AS total_sold,
    COALESCE(pp.purchased_total, 0)                                      AS total_purchased,
    COALESCE(pe.spent_total, 0)                                          AS total_spent,
    (COALESCE(ps.sold_ops, 0) + COALESCE(pp.purchased_ops, 0)
                              + COALESCE(pe.spent_rows, 0))::BIGINT      AS operation_count
  FROM all_pm_ids api
  LEFT JOIN public.payment_methods pm ON pm.id     = api.pm_id
  LEFT JOIN pm_sales               ps ON ps.pm_id  IS NOT DISTINCT FROM api.pm_id
  LEFT JOIN pm_purchases           pp ON pp.pm_id  IS NOT DISTINCT FROM api.pm_id
  LEFT JOIN pm_expenses            pe ON pe.pm_id  IS NOT DISTINCT FROM api.pm_id
  -- ORDER BY por expresión y no por el nombre de la columna OUT: evita la
  -- ambigüedad columna-vs-variable de plpgsql en RETURN QUERY.
  ORDER BY (COALESCE(ps.sold_total, 0) + COALESCE(pp.purchased_total, 0)
                                       + COALESCE(pe.spent_total, 0)) DESC;
END;
$function$;

COMMENT ON FUNCTION public.rpc_payment_method_report(uuid, date, date) IS
  'Distribución por forma de pago en un rango: total vendido, comprado y GASTADO.
  RN-D1: no resta notas de crédito (no tienen forma de pago atribuible).
  gastos-forma-pago (D14): suma total_spent — los gastos se agregan por amount y
  cuentan una unidad por fila, mismo criterio que rpc_cost_center_report.';

-- ── ACLs re-emitidas COMPLETAS: el DROP de arriba las reseteó ────────────────
-- Molde literal de 20260928000001:1945-1947.
REVOKE ALL     ON FUNCTION public.rpc_payment_method_report(uuid, date, date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_payment_method_report(uuid, date, date) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_payment_method_report(uuid, date, date) TO authenticated;

-- ── Gate ANTI-OVERLOAD propio del reporte (molde de 20260928000001:1813) ────
DO $$
DECLARE
  v_count integer;
  v_def   text;
BEGIN
  SELECT COUNT(*) INTO v_count
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'rpc_payment_method_report';

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE ANTI-OVERLOAD FAILED: rpc_payment_method_report tiene % definiciones en public (esperaba exactamente 1) — el DROP FUNCTION IF EXISTS no matcheó la firma vieja y quedó un overload fantasma (42725).', v_count;
  END IF;

  -- Y el cuerpo conserva los cuatro predicados que el gate de introspección de
  -- 20260928000001 §12 exige, para que ese gate siga verde sobre la definición
  -- nueva: la reescritura suma una CTE, no reemplaza los invariantes RN-D.
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'rpc_payment_method_report';

  IF position('COALESCE(s.total, s.amount)' in v_def) = 0
     OR position('COALESCE(p.total, p.amount)' in v_def) = 0
     OR position('(p_end + 1)::timestamptz' in v_def) = 0
     OR position('Sin especificar' in v_def) = 0
     OR position('journal_lines' in v_def) > 0 THEN
    RAISE EXCEPTION 'GATE REPORTE FAILED: la reescritura de rpc_payment_method_report perdió alguno de los invariantes RN-D que verifica 20260928000001 §12.';
  END IF;

  RAISE NOTICE 'GATE ANTI-OVERLOAD PASSED: rpc_payment_method_report tiene 1 definición, con las 8 columnas y los invariantes RN-D intactos.';
END $$;
