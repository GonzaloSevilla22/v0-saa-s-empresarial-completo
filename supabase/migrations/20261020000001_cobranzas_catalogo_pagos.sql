-- =============================================================================
-- cobranzas-catalogo-pagos — el cobro de cuenta corriente y el pago a
-- proveedor migran al catálogo payment_methods (7 kinds), espejo de
-- metodos-pago-operaciones / pos-catalogo-pagos / gastos-forma-pago /
-- caja-compras-cobranzas.
-- =============================================================================
--
-- Sign-off del PO (2026-09-02, "aplicalo con todas las recomendaciones") sobre
-- las 5 OQs del design: (1) credit se RECHAZA en cobros/pagos, doble capa
-- (selector no lo ofrece + servidor P0400); (2) other se ACEPTA como etiqueta
-- pura; (3) la columna payment_method (text) de payments_received/made se
-- DROPEA (0/7 filas pobladas); (4) contexto nuevo "collection" en
-- PaymentMethodSelect con su propio texto de apoyo; (5) destinos bancarios por
-- defecto en las 266 formas de pago quedan FUERA de alcance.
--
-- CHECKPOINT DE INTEGRIDAD (2026-09-02, MCP execute_sql, solo SELECT) — los 9
-- md5(pg_get_functiondef) del design.md coinciden EXACTOS contra prod:
--   rpc_register_payment_received  4d5de67480d67d064c1fba1198c9c6e3 (7656 chars)
--   rpc_register_payment_made      07acdadbbcab5eb3086e31e0f055067f (6751 chars)
--   _pay_register_operation_bank_movement / c28_register_cash_movement /
--   c30_get_or_create_customer_account / rpc_reverse_payment_received/_made /
--   _journal_post_from_event / rpc_register_supplier_charge — CERO divergencias.
-- payments_received/payments_made con payment_method IS NOT NULL: 0/6 y 0/1
-- (checkpoint 1.3, re-medido al escribir este archivo). Correlativa: MAX(version)
-- de prod y de origin/main coinciden en 20261019000001 (268 filas) → este
-- archivo usa 20261020000001, sin corrimiento esta vez.
--
-- GATE DE INTEGRIDAD DE FUNCIÓN: las dos RPCs reescritas parten del
-- pg_get_functiondef VIVO capturado arriba, NUNCA del último archivo de
-- migración (que ya divergió una vez en este proyecto, metodos-pago-operaciones).
--
-- BREAKING (firma): p_payment_method text (5º arg) → p_payment_method_id uuid,
-- misma posición, misma aridad (7). DROP FUNCTION explícito de la firma vieja
-- + CREATE (nunca CREATE OR REPLACE con el tipo cambiado — gotcha 42725,
-- dejaría un overload vivo). REVOKE ALL FROM PUBLIC + REVOKE EXECUTE FROM anon
-- + GRANT EXECUTE TO authenticated en el mismo archivo — un DROP+CREATE
-- resetea las ACLs.
--
-- BREAKING (schema): payments_received.payment_method / payments_made.payment_method
-- (text) se REEMPLAZAN por payment_method_id uuid NULL REFERENCES
-- payment_methods(id). Sin ON DELETE — la baja del catálogo es desactivación,
-- nunca borrado (requirement vigente de payment-method), así que la FK nunca
-- queda colgada. Sin backfill: 0/7 filas con el texto poblado.
--
-- Taxonomía aceptada: 6 de 7 kinds. wallet se suma (ya es kind bancario en
-- TODO el resto del sistema — isBankPaymentKind, _pay_register_operation_bank_movement,
-- el consumidor contable). other se suma (etiqueta pura, sin efecto en ningún
-- libro). credit se RECHAZA con P0400 (D2) — cancelar una cuenta corriente
-- con cuenta corriente es circular.
--
-- El ruteo bancario ADOPTA _pay_register_operation_bank_movement (D4) — el
-- mismo helper que venta/compra/gasto — que aporta wallet gratis, el guard de
-- período conciliado (P0424, ausente hasta hoy en estas dos RPCs) y el rechazo
-- de bank_account informado junto a un kind no bancario. El guard ESTRICTO de
-- cuenta bancaria (P0400/P0412) que ya existía para transfer/card/check se
-- CONSERVA sin cambios de comportamiento y se extiende a wallet: con 0/266
-- formas de pago con bank_account_id configurado, el fallback al default del
-- helper haría RETURN NULL sin error (hallazgo gemelo de gastos-forma-pago D5)
-- si no se mantuviera este guard explícito ANTES de llamar al helper.
--
-- El reverso (rpc_reverse_payment_received/_made) NO SE TOCA — firma y cuerpo
-- intactos (D7): las cuatro patas de compensación despachan por existencia del
-- movimiento, nunca por la columna de forma de pago (requirement vigente de
-- payment-reversal, escrito por cobranzas-reverso). Los gates que lo verifican
-- se migran a la firma nueva sin tocar ninguna aserción del reverso.
--
-- REUTILIZACIÓN ANTES QUE REPETICIÓN (regla PO 2026-08-02): cero helpers SQL
-- nuevos. _pay_register_operation_bank_movement, c28_register_cash_movement,
-- c30_get_or_create_customer_account/_supplier_account ya existen y se
-- reusan tal cual.
-- =============================================================================


-- ═══════════════════ (1) Schema: payment_method_id reemplaza al texto ════════

ALTER TABLE public.payments_received
  ADD COLUMN IF NOT EXISTS payment_method_id uuid NULL REFERENCES public.payment_methods(id);

ALTER TABLE public.payments_made
  ADD COLUMN IF NOT EXISTS payment_method_id uuid NULL REFERENCES public.payment_methods(id);

-- 0/7 filas con payment_method (text) poblado, re-verificado en el checkpoint
-- 1.3 del apply — no hay dato que backfillear (D3).
ALTER TABLE public.payments_received
  DROP COLUMN IF EXISTS payment_method;

ALTER TABLE public.payments_made
  DROP COLUMN IF EXISTS payment_method;


-- ═════════ (2) rpc_register_payment_received — DROP + CREATE ═════════════════

DROP FUNCTION IF EXISTS public.rpc_register_payment_received(
  text, uuid, numeric, uuid, text, uuid, uuid
);

CREATE FUNCTION public.rpc_register_payment_received(
  p_idempotency_key text,
  p_client_id uuid,
  p_amount numeric,
  p_reference_sale_id uuid DEFAULT NULL::uuid,
  -- cobranzas-catalogo-pagos (D1): 5º arg pasa de text a uuid, misma posición.
  -- El kind SIEMPRE se deriva del catálogo — nunca se acepta como texto.
  p_payment_method_id uuid DEFAULT NULL::uuid,
  p_bank_account_id uuid DEFAULT NULL::uuid,
  p_cash_session_id uuid DEFAULT NULL::uuid
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid                 uuid;
  v_account_id          uuid;
  v_customer_account_id uuid;
  v_inserted            integer;
  v_existing_op         uuid;
  v_new_op_id           uuid;
  v_movement_id         uuid;
  v_payment_id          uuid;
  v_balance_after        numeric(15,2);
  v_bank_account         public.bank_accounts%ROWTYPE;
  v_bank_movement_id     uuid;
  v_client               uuid;
  -- cobranzas-catalogo-pagos (D5): el kind derivado del catálogo — nunca del
  -- cliente. NULL cuando p_payment_method_id es NULL (sin imputar, D2 spec).
  v_kind                 text;
  -- caja-compras-cobranzas (D5):
  v_cash_movement_id     uuid;
  v_cash_session_status  text;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM public.current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'invalid_amount: amount debe ser > 0, recibido: %', p_amount
      USING ERRCODE = 'P0400';
  END IF;

  -- cobranzas-catalogo-pagos (D5): el kind se DERIVA del catálogo bajo el
  -- account_id del tenant — jamás se acepta como texto del cliente. Mensaje
  -- que NO revela si el id existe en otra cuenta (mismo criterio que el
  -- guard de tenencia del cliente, unas líneas más abajo). is_active +
  -- deleted_at: una forma de pago dada de baja no es imputable a un cobro
  -- NUEVO (mismo criterio que rpc_create_expense) — un cobro YA imputado a
  -- ella conserva su lectura histórica por el requirement de baja=desactivación.
  IF p_payment_method_id IS NOT NULL THEN
    SELECT kind INTO v_kind
    FROM public.payment_methods
    WHERE id = p_payment_method_id AND account_id = v_account_id
      AND is_active = TRUE AND deleted_at IS NULL;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'payment_method_not_found: %', p_payment_method_id
        USING ERRCODE = 'P0404';
    END IF;
  END IF;

  -- cobranzas-catalogo-pagos (D2): credit se rechaza — cancelar una cuenta
  -- corriente con cuenta corriente es circular (el cobro REDUCE la deuda,
  -- credit significa AUMENTARLA). Mismo ERRCODE y mismo criterio que
  -- gastos-forma-pago D3 aplicó al gasto.
  IF v_kind = 'credit' THEN
    RAISE EXCEPTION 'credit_payment_method_invalid: un cobro no puede imputarse a una forma de pago de cuenta corriente'
      USING ERRCODE = 'P0400';
  END IF;

  -- Guard ESTRICTO de cuenta bancaria (D4) — SIN CAMBIOS de comportamiento
  -- para transfer/card/check; wallet se suma porque ya es kind bancario en
  -- TODO el resto del sistema. Se mantiene ANTES de llamar al helper
  -- compartido para que p_bank_account_id nunca llegue NULL a un kind
  -- bancario — con 0/266 formas de pago con destino configurado, el
  -- fallback al default del helper haría RETURN NULL sin error.
  IF v_kind IN ('transfer', 'card', 'check', 'wallet') THEN
    IF p_bank_account_id IS NULL THEN
      RAISE EXCEPTION 'bank_account_required: la forma de pago elegida exige p_bank_account_id'
        USING ERRCODE = 'P0400';
    END IF;

    SELECT * INTO v_bank_account
    FROM public.bank_accounts
    WHERE id = p_bank_account_id
      AND account_id = v_account_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'bank_account_not_found: %', p_bank_account_id
        USING ERRCODE = 'P0412';
    END IF;

    IF NOT v_bank_account.is_active THEN
      RAISE EXCEPTION 'bank_account_inactive: la cuenta % está inactiva', p_bank_account_id
        USING ERRCODE = 'P0412';
    END IF;
  END IF;

  -- caja-compras-cobranzas (D5): informar sesión de caja con un kind
  -- distinto de cash se rechaza ANTES de tocar cualquier libro. IS DISTINCT
  -- FROM cubre v_kind NULL (sin imputar) igual que un kind bancario.
  IF p_cash_session_id IS NOT NULL AND v_kind IS DISTINCT FROM 'cash' THEN
    RAISE EXCEPTION 'cash_optin_requires_cash_kind: p_cash_session_id sólo aplica si el kind derivado es cash (recibido: %)', COALESCE(v_kind, 'NULL')
      USING ERRCODE = 'P0422';
  END IF;

  -- cuenta-corriente-party-guard (D1 capa 2 / D2): el cliente tiene que
  -- pertenecer al tenant.
  SELECT id INTO v_client
  FROM public.clients
  WHERE id = p_client_id AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'client_not_found: %', p_client_id USING ERRCODE = 'P0404';
  END IF;

  -- Idempotencia DEC-06 (OQ-5 C-30): operation_kind='payment_received'
  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency
    (user_id, idempotency_key, operation_kind, operation_id)
  VALUES
    (v_uid, p_idempotency_key, 'payment_received', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    -- Replay: devolver el resultado original sin re-ejecutar. El RETURN acá
    -- corta antes del bloque de caja / banco de más abajo — un replay NO
    -- postea un segundo movimiento.
    SELECT operation_id INTO v_existing_op
    FROM public.operation_idempotency
    WHERE user_id = v_uid
      AND operation_kind = 'payment_received'
      AND idempotency_key = p_idempotency_key;

    RETURN jsonb_build_object(
      'payment_id',           NULL,
      'customer_account_id',  NULL,
      'balance_after',        NULL,
      'replayed',             true,
      'operation_id',         v_existing_op
    );
  END IF;

  -- Resolver/crear la CustomerAccount (OQ-4 C-30 lazy auto-create)
  v_customer_account_id := public.c30_get_or_create_customer_account(v_account_id, p_client_id);

  -- Registrar el movimiento con signo negativo (reduce la deuda, OQ-1 C-30)
  v_payment_id := gen_random_uuid();
  v_movement_id := public.c30_register_customer_account_movement(
    v_customer_account_id,
    -p_amount,
    'payment_received',
    v_payment_id
  );

  SELECT balance_after INTO v_balance_after
  FROM public.customer_account_movements
  WHERE id = v_movement_id;

  -- cobranzas-catalogo-pagos (D3): payment_method_id reemplaza al texto — FK
  -- al catálogo, NULL = sin imputar.
  INSERT INTO public.payments_received
    (id, account_id, customer_account_id, client_id, amount, reference_sale_id, movement_id, created_by, payment_method_id)
  VALUES
    (v_payment_id, v_account_id, v_customer_account_id, p_client_id, p_amount, p_reference_sale_id, v_movement_id, v_uid, p_payment_method_id);

  -- ── caja-compras-cobranzas (D5) — OPT-IN DE CAJA, 2 condiciones ───────────
  -- Dentro del alcance de la clave de idempotencia (D12): la escritura queda
  -- adentro del bloque protegido, después de resolver la cuenta corriente y
  -- antes del commit.
  IF p_cash_session_id IS NOT NULL THEN
    SELECT status INTO v_cash_session_status
    FROM public.cash_sessions
    WHERE id = p_cash_session_id;

    IF v_cash_session_status IS DISTINCT FROM 'open' THEN
      RAISE EXCEPTION 'cash_optin_requires_open_session: la sesión de caja debe estar abierta'
        USING ERRCODE = 'P0422';
    END IF;

    v_cash_movement_id := public.c28_register_cash_movement(
      p_cash_session_id, p_amount, 'payment_received', v_payment_id, NULL
    );
  END IF;
  -- ── FIN OPT-IN DE CAJA ─────────────────────────────────────────────────────

  -- cobranzas-catalogo-pagos (D4): ruteo bancario delegado al helper
  -- compartido de operaciones — el mismo que venta/compra/gasto. Aporta
  -- wallet gratis (el mapa kind→movement_type del helper ya lo cubre), el
  -- guard de período conciliado (P0424, ausente hasta hoy acá) y el rechazo
  -- de bank_account informado junto a un kind no bancario (P0400). El guard
  -- estricto de arriba ya garantiza que p_bank_account_id no llega NULL para
  -- un kind bancario, así que el fallback al default del helper (0/266) no
  -- se ejerce nunca. Produce los MISMOS tres movement_type que el CASE
  -- inline que reemplaza (card_settlement / transfer_in), verificado contra
  -- el cuerpo vivo del helper — el reverso no ve ningún tipo nuevo.
  v_bank_movement_id := public._pay_register_operation_bank_movement(
    v_account_id, v_kind, p_payment_method_id, p_bank_account_id,
    p_amount, 'in', 'payment_received', v_payment_id,
    public.reporting_local_today(), NULL, NULL
  );

  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id,
    'PaymentReceived',
    'CustomerAccount',
    v_customer_account_id,
    jsonb_build_object(
      'account_id',           v_account_id,
      'customer_account_id',  v_customer_account_id,
      'client_id',            p_client_id,
      'payment_id',           v_payment_id,
      'amount',               p_amount,
      'balance_after',        v_balance_after,
      'reference_sale_id',    p_reference_sale_id,
      -- D8: el kind derivado reemplaza al texto crudo del cliente — mismo
      -- dominio de valores para los 4 que ya viajaban, así que
      -- _journal_post_from_event (checkpoint 1.4, sin cambios) no cambia de
      -- comportamiento para los casos existentes.
      'payment_method',       v_kind,
      'payment_method_id',    p_payment_method_id,
      'bank_account_id',      p_bank_account_id,
      'occurred_at',          now()
    ),
    now()
  );

  RETURN jsonb_build_object(
    'payment_id',           v_payment_id,
    'customer_account_id',  v_customer_account_id,
    'balance_after',        v_balance_after,
    'replayed',             false,
    'operation_id',         v_new_op_id
  );
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_register_payment_received(text, uuid, numeric, uuid, uuid, uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_register_payment_received(text, uuid, numeric, uuid, uuid, uuid, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_register_payment_received(text, uuid, numeric, uuid, uuid, uuid, uuid) TO authenticated;


-- ═════════ (3) rpc_register_payment_made — DROP + CREATE (espejo exacto) ═════

DROP FUNCTION IF EXISTS public.rpc_register_payment_made(
  text, uuid, numeric, uuid, text, uuid, uuid
);

CREATE FUNCTION public.rpc_register_payment_made(
  p_idempotency_key text,
  p_supplier_id uuid,
  p_amount numeric,
  p_reference_purchase_id uuid DEFAULT NULL::uuid,
  -- cobranzas-catalogo-pagos (D1): espejo exacto de rpc_register_payment_received.
  p_payment_method_id uuid DEFAULT NULL::uuid,
  p_bank_account_id uuid DEFAULT NULL::uuid,
  p_cash_session_id uuid DEFAULT NULL::uuid
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid                 uuid;
  v_account_id          uuid;
  v_supplier_account_id uuid;
  v_inserted            integer;
  v_existing_op         uuid;
  v_new_op_id           uuid;
  v_movement_id         uuid;
  v_payment_id          uuid;
  v_balance_after        numeric(15,2);
  v_bank_account         public.bank_accounts%ROWTYPE;
  v_bank_movement_id     uuid;
  v_supplier             uuid;
  v_kind                 text;
  -- caja-compras-cobranzas (D5):
  v_cash_movement_id     uuid;
  v_cash_session_status  text;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM public.current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'invalid_amount: amount debe ser > 0, recibido: %', p_amount
      USING ERRCODE = 'P0400';
  END IF;

  -- cobranzas-catalogo-pagos (D5): espejo exacto del cobro.
  IF p_payment_method_id IS NOT NULL THEN
    SELECT kind INTO v_kind
    FROM public.payment_methods
    WHERE id = p_payment_method_id AND account_id = v_account_id
      AND is_active = TRUE AND deleted_at IS NULL;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'payment_method_not_found: %', p_payment_method_id
        USING ERRCODE = 'P0404';
    END IF;
  END IF;

  -- cobranzas-catalogo-pagos (D2): espejo exacto — un pago no puede
  -- imputarse a cuenta corriente.
  IF v_kind = 'credit' THEN
    RAISE EXCEPTION 'credit_payment_method_invalid: un pago no puede imputarse a una forma de pago de cuenta corriente'
      USING ERRCODE = 'P0400';
  END IF;

  -- Guard ESTRICTO de cuenta bancaria (D4) — espejo exacto.
  IF v_kind IN ('transfer', 'card', 'check', 'wallet') THEN
    IF p_bank_account_id IS NULL THEN
      RAISE EXCEPTION 'bank_account_required: la forma de pago elegida exige p_bank_account_id'
        USING ERRCODE = 'P0400';
    END IF;

    SELECT * INTO v_bank_account
    FROM public.bank_accounts
    WHERE id = p_bank_account_id
      AND account_id = v_account_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'bank_account_not_found: %', p_bank_account_id
        USING ERRCODE = 'P0412';
    END IF;

    IF NOT v_bank_account.is_active THEN
      RAISE EXCEPTION 'bank_account_inactive: la cuenta % está inactiva', p_bank_account_id
        USING ERRCODE = 'P0412';
    END IF;
  END IF;

  -- caja-compras-cobranzas (D5): mismo guard que el cobro.
  IF p_cash_session_id IS NOT NULL AND v_kind IS DISTINCT FROM 'cash' THEN
    RAISE EXCEPTION 'cash_optin_requires_cash_kind: p_cash_session_id sólo aplica si el kind derivado es cash (recibido: %)', COALESCE(v_kind, 'NULL')
      USING ERRCODE = 'P0422';
  END IF;

  -- cuenta-corriente-party-guard (D1 capa 2 / D2): el proveedor tiene que
  -- pertenecer al tenant.
  SELECT id INTO v_supplier
  FROM public.suppliers
  WHERE id = p_supplier_id AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'supplier_not_found: %', p_supplier_id USING ERRCODE = 'P0404';
  END IF;

  -- Idempotencia DEC-06 (OQ-5 C-30): operation_kind='payment_made'
  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency
    (user_id, idempotency_key, operation_kind, operation_id)
  VALUES
    (v_uid, p_idempotency_key, 'payment_made', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    SELECT operation_id INTO v_existing_op
    FROM public.operation_idempotency
    WHERE user_id = v_uid
      AND operation_kind = 'payment_made'
      AND idempotency_key = p_idempotency_key;

    RETURN jsonb_build_object(
      'payment_id',          NULL,
      'supplier_account_id', NULL,
      'balance_after',       NULL,
      'replayed',            true,
      'operation_id',        v_existing_op
    );
  END IF;

  v_supplier_account_id := public.c30_get_or_create_supplier_account(v_account_id, p_supplier_id);

  v_payment_id := gen_random_uuid();
  v_movement_id := public.c30_register_supplier_account_movement(
    v_supplier_account_id,
    -p_amount,
    'payment_made',
    v_payment_id
  );

  SELECT balance_after INTO v_balance_after
  FROM public.supplier_account_movements
  WHERE id = v_movement_id;

  -- cobranzas-catalogo-pagos (D3): payment_method_id reemplaza al texto.
  INSERT INTO public.payments_made
    (id, account_id, supplier_account_id, supplier_id, amount, reference_purchase_id, movement_id, created_by, payment_method_id)
  VALUES
    (v_payment_id, v_account_id, v_supplier_account_id, p_supplier_id, p_amount, p_reference_purchase_id, v_movement_id, v_uid, p_payment_method_id);

  -- ── caja-compras-cobranzas (D5) — OPT-IN DE CAJA, 2 condiciones ───────────
  IF p_cash_session_id IS NOT NULL THEN
    SELECT status INTO v_cash_session_status
    FROM public.cash_sessions
    WHERE id = p_cash_session_id;

    IF v_cash_session_status IS DISTINCT FROM 'open' THEN
      RAISE EXCEPTION 'cash_optin_requires_open_session: la sesión de caja debe estar abierta'
        USING ERRCODE = 'P0422';
    END IF;

    v_cash_movement_id := public.c28_register_cash_movement(
      p_cash_session_id, -p_amount, 'payment_made', v_payment_id, NULL
    );
  END IF;
  -- ── FIN OPT-IN DE CAJA ─────────────────────────────────────────────────────

  -- cobranzas-catalogo-pagos (D4): espejo exacto — direction 'out'.
  v_bank_movement_id := public._pay_register_operation_bank_movement(
    v_account_id, v_kind, p_payment_method_id, p_bank_account_id,
    p_amount, 'out', 'payment_made', v_payment_id,
    public.reporting_local_today(), NULL, NULL
  );

  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id,
    'PaymentMade',
    'SupplierAccount',
    v_supplier_account_id,
    jsonb_build_object(
      'account_id',          v_account_id,
      'supplier_account_id', v_supplier_account_id,
      'supplier_id',         p_supplier_id,
      'payment_id',          v_payment_id,
      'amount',              p_amount,
      'balance_after',       v_balance_after,
      'payment_method',      v_kind,
      'payment_method_id',   p_payment_method_id,
      'bank_account_id',     p_bank_account_id,
      'occurred_at',         now()
    ),
    now()
  );

  RETURN jsonb_build_object(
    'payment_id',          v_payment_id,
    'supplier_account_id', v_supplier_account_id,
    'balance_after',       v_balance_after,
    'replayed',            false,
    'operation_id',        v_new_op_id
  );
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_register_payment_made(text, uuid, numeric, uuid, uuid, uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_register_payment_made(text, uuid, numeric, uuid, uuid, uuid, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_register_payment_made(text, uuid, numeric, uuid, uuid, uuid, uuid) TO authenticated;
