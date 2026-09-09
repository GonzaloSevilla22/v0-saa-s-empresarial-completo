-- =============================================================================
-- charge-due-date-update — cobranzas-vencimientos OQ-1: corregir el
-- vencimiento de un cargo abierto (SEVERIDAD ALTA: escribe en el ledger de
-- cuentas corrientes — sólo la columna due_date, pero es la PRIMERA mutación
-- sobre customer_account_movements/supplier_account_movements desde que
-- existen: son append-only por diseño, ningún UPDATE las tocó nunca antes de
-- este archivo. Se acota al máximo: dos RPCs SECURITY DEFINER nuevas, un solo
-- UPDATE cada una, un solo INSERT de auditoría.
--
-- Contexto (design.md de cobranzas-vencimientos, sign-off del PO: "dejarlo
-- así" en su momento): la operación con cargo posteado es inmutable (P0423),
-- así que hoy la única salida para un vencimiento mal cargado es borrar la
-- venta/compra y rehacerla. Este change agrega la salida quirúrgica: cambiar
-- SOLO el due_date de un cargo, sin tocar el resto del documento.
--
-- Diseño (aprobado por el PO): rpc_update_customer_charge_due_date /
-- rpc_update_supplier_charge_due_date, molde de guards de
-- rpc_register_payment_received (20261020000001_cobranzas_catalogo_pagos.sql):
--   auth.uid() NULL              → insufficient_privilege
--   sin cuenta activa            → P0403
--   NOT is_account_writer        → P0401 (ya exige owner/admin — pg_get_functiondef
--                                    verificado: is_account_writer sólo cuenta
--                                    membresías con role IN ('owner','admin'))
--   fila no resuelta por id+account_id → P0404 (nunca revela si existe en OTRA cuenta)
--   movement_type no es un CARGO → P0400 (mismo vocabulario FIFO que
--                                    rpc_receivables_report/rpc_payables_report,
--                                    20261022000001: sale/adjustment>0 en
--                                    cliente, purchase/adjustment>0 en proveedor)
--   cargo ya saldado (open_amount = 0 por la MISMA regla FIFO)  → P0400
--   p_due_date NULL permitido = limpiar el vencimiento (mismo criterio que
--     rpc_set_default_payment_terms: NULL nunca es un error, es "sin vencimiento")
--
-- Efecto: UPDATE due_date (scoped por id + account_id) + INSERT en
-- audit_logs (action = customer_charge.due_date_changed /
-- supplier_charge.due_date_changed, con before/after/reason/movement_type/
-- amount en metadata — molde fn_audit_branch_lifecycle, 20261014000001).
-- audit_logs.entity_type/entity_id/metadata ya existen en la cadena desde
-- 20261014000001 (ADD COLUMN IF NOT EXISTS, drift-tolerant) — no se repite acá.
--
-- El open_amount de UN cargo se deriva con la MISMA ventana FIFO que
-- rpc_receivables_report (20261022000001, líneas ~1627-1652): pool de
-- crédito (todo lo que NO es cargo, con su signo) + suma acumulada de cargos
-- ordenada por (COALESCE(due_date, fecha local del posteo), created_at, id).
-- Acá se evalúa ANTES de aplicar el cambio (con el due_date VIEJO, que es el
-- que ordenó los cargos hasta ahora) — cambiar el vencimiento de un cargo
-- reordena el FIFO hacia adelante, que es el efecto buscado, no un bug.
--
-- ERRCODEs: sólo P0400/P0401/P0403/P0404, todos ya usados y mapeados en
-- backend/core/errors.py (_BUSINESS_ERRCODE_STATUS) — ninguno nuevo.
-- GRANT/REVOKE: REVOKE ALL FROM PUBLIC, anon; GRANT EXECUTE TO authenticated
-- (el frontend llama vía backend, que usa JWT-passthrough — mismo criterio
-- que el resto de las RPCs de cuenta corriente).
-- =============================================================================


-- ═══════════════════ (1) rpc_update_customer_charge_due_date ═══════════════

CREATE OR REPLACE FUNCTION public.rpc_update_customer_charge_due_date(
  p_movement_id uuid,
  p_due_date    date,
  p_reason      text DEFAULT NULL::text
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid              uuid;
  v_account_id       uuid;
  v_movement         public.customer_account_movements%ROWTYPE;
  v_open_amount       numeric(15,2);
  v_due_date_before   date;
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

  -- Tenencia: id + account_id — nunca revela si el cargo existe en OTRA cuenta.
  SELECT * INTO v_movement
  FROM public.customer_account_movements
  WHERE id = p_movement_id AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'charge_not_found: %', p_movement_id USING ERRCODE = 'P0404';
  END IF;

  -- Mismo vocabulario FIFO que rpc_receivables_report: sólo sale + adjustment
  -- positivo son CARGO. Un cobro/nota/reversa no tiene vencimiento propio que
  -- editar (D7 de cobranzas-vencimientos: due_date sólo existe en la fila del
  -- cargo — un no-cargo con due_date sería un estado nunca producido).
  IF NOT (v_movement.movement_type = 'sale'
          OR (v_movement.movement_type = 'adjustment' AND v_movement.amount > 0)) THEN
    RAISE EXCEPTION 'not_a_charge: movement_type=%, amount=%', v_movement.movement_type, v_movement.amount
      USING ERRCODE = 'P0400';
  END IF;

  -- open_amount del cargo (ANTES del cambio) — misma derivación FIFO que
  -- rpc_receivables_report, acotada al customer_account_id de este cargo.
  WITH pool AS (
    SELECT COALESCE(SUM(-m.amount), 0) AS credit
    FROM public.customer_account_movements m
    WHERE m.customer_account_id = v_movement.customer_account_id
      AND NOT (m.movement_type = 'sale' OR (m.movement_type = 'adjustment' AND m.amount > 0))
  ),
  charges AS (
    SELECT m.id, m.amount,
           SUM(m.amount) OVER (
             ORDER BY COALESCE(m.due_date, (m.created_at AT TIME ZONE 'America/Argentina/Mendoza')::date),
                      m.created_at, m.id
           ) AS cum_amount
    FROM public.customer_account_movements m
    WHERE m.customer_account_id = v_movement.customer_account_id
      AND (m.movement_type = 'sale' OR (m.movement_type = 'adjustment' AND m.amount > 0))
  )
  SELECT LEAST(ch.amount, GREATEST(0::numeric, ch.cum_amount - p.credit))
  INTO v_open_amount
  FROM charges ch CROSS JOIN pool p
  WHERE ch.id = p_movement_id;

  IF COALESCE(v_open_amount, 0) <= 0 THEN
    RAISE EXCEPTION 'charge_fully_settled: el cargo % no tiene saldo abierto', p_movement_id
      USING ERRCODE = 'P0400';
  END IF;

  v_due_date_before := v_movement.due_date;

  -- ÚNICA mutación de este ledger append-only: SOLO due_date, scoped por
  -- id + account_id (defensa en profundidad, ya validado arriba).
  UPDATE public.customer_account_movements
  SET due_date = p_due_date
  WHERE id = p_movement_id AND account_id = v_account_id;

  INSERT INTO public.audit_logs
    (account_id, user_id, action, entity_type, entity_id, metadata, created_at)
  VALUES (
    v_account_id, v_uid, 'customer_charge.due_date_changed', 'customer_account_movement', p_movement_id,
    jsonb_build_object(
      'due_date_before', v_due_date_before,
      'due_date_after',  p_due_date,
      'reason',          p_reason,
      'movement_type',   v_movement.movement_type,
      'amount',          v_movement.amount
    ),
    now()
  );

  RETURN jsonb_build_object(
    'movement_id',       p_movement_id,
    'due_date',          p_due_date,
    'previous_due_date', v_due_date_before
  );
END;
$function$;

COMMENT ON FUNCTION public.rpc_update_customer_charge_due_date(uuid, date, text) IS
    'cobranzas-vencimientos OQ-1: corrige el vencimiento de un cargo (sale/'
    'adjustment>0) abierto de customer_account_movements. Guard is_account_writer '
    '(owner/admin, P0401); P0403 sin cuenta activa; P0404 cargo de otra cuenta; '
    'P0400 no-cargo o cargo saldado. p_due_date NULL limpia el vencimiento. '
    'Única mutación permitida sobre este ledger append-only — auditada en '
    'audit_logs (customer_charge.due_date_changed) con before/after.';

REVOKE ALL     ON FUNCTION public.rpc_update_customer_charge_due_date(uuid, date, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_update_customer_charge_due_date(uuid, date, text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_update_customer_charge_due_date(uuid, date, text) TO authenticated;


-- ═══════════════════ (2) rpc_update_supplier_charge_due_date ═══════════════
-- Espejo exacto de (1) sobre supplier_account_movements (purchase en vez de
-- sale; supplier_account_id en vez de customer_account_id).

CREATE OR REPLACE FUNCTION public.rpc_update_supplier_charge_due_date(
  p_movement_id uuid,
  p_due_date    date,
  p_reason      text DEFAULT NULL::text
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid              uuid;
  v_account_id       uuid;
  v_movement         public.supplier_account_movements%ROWTYPE;
  v_open_amount       numeric(15,2);
  v_due_date_before   date;
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

  SELECT * INTO v_movement
  FROM public.supplier_account_movements
  WHERE id = p_movement_id AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'charge_not_found: %', p_movement_id USING ERRCODE = 'P0404';
  END IF;

  IF NOT (v_movement.movement_type = 'purchase'
          OR (v_movement.movement_type = 'adjustment' AND v_movement.amount > 0)) THEN
    RAISE EXCEPTION 'not_a_charge: movement_type=%, amount=%', v_movement.movement_type, v_movement.amount
      USING ERRCODE = 'P0400';
  END IF;

  WITH pool AS (
    SELECT COALESCE(SUM(-m.amount), 0) AS credit
    FROM public.supplier_account_movements m
    WHERE m.supplier_account_id = v_movement.supplier_account_id
      AND NOT (m.movement_type = 'purchase' OR (m.movement_type = 'adjustment' AND m.amount > 0))
  ),
  charges AS (
    SELECT m.id, m.amount,
           SUM(m.amount) OVER (
             ORDER BY COALESCE(m.due_date, (m.created_at AT TIME ZONE 'America/Argentina/Mendoza')::date),
                      m.created_at, m.id
           ) AS cum_amount
    FROM public.supplier_account_movements m
    WHERE m.supplier_account_id = v_movement.supplier_account_id
      AND (m.movement_type = 'purchase' OR (m.movement_type = 'adjustment' AND m.amount > 0))
  )
  SELECT LEAST(ch.amount, GREATEST(0::numeric, ch.cum_amount - p.credit))
  INTO v_open_amount
  FROM charges ch CROSS JOIN pool p
  WHERE ch.id = p_movement_id;

  IF COALESCE(v_open_amount, 0) <= 0 THEN
    RAISE EXCEPTION 'charge_fully_settled: el cargo % no tiene saldo abierto', p_movement_id
      USING ERRCODE = 'P0400';
  END IF;

  v_due_date_before := v_movement.due_date;

  UPDATE public.supplier_account_movements
  SET due_date = p_due_date
  WHERE id = p_movement_id AND account_id = v_account_id;

  INSERT INTO public.audit_logs
    (account_id, user_id, action, entity_type, entity_id, metadata, created_at)
  VALUES (
    v_account_id, v_uid, 'supplier_charge.due_date_changed', 'supplier_account_movement', p_movement_id,
    jsonb_build_object(
      'due_date_before', v_due_date_before,
      'due_date_after',  p_due_date,
      'reason',          p_reason,
      'movement_type',   v_movement.movement_type,
      'amount',          v_movement.amount
    ),
    now()
  );

  RETURN jsonb_build_object(
    'movement_id',       p_movement_id,
    'due_date',          p_due_date,
    'previous_due_date', v_due_date_before
  );
END;
$function$;

COMMENT ON FUNCTION public.rpc_update_supplier_charge_due_date(uuid, date, text) IS
    'cobranzas-vencimientos OQ-1: espejo de rpc_update_customer_charge_due_date '
    'sobre supplier_account_movements (purchase/adjustment>0 es cargo). Guard '
    'is_account_writer (owner/admin, P0401); P0403 sin cuenta activa; P0404 '
    'cargo de otra cuenta; P0400 no-cargo o cargo saldado. p_due_date NULL '
    'limpia el vencimiento. Auditado en audit_logs (supplier_charge.due_date_changed).';

REVOKE ALL     ON FUNCTION public.rpc_update_supplier_charge_due_date(uuid, date, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_update_supplier_charge_due_date(uuid, date, text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_update_supplier_charge_due_date(uuid, date, text) TO authenticated;
