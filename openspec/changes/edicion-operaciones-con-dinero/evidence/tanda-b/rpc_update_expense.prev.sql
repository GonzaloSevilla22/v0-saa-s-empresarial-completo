CREATE OR REPLACE FUNCTION public.rpc_update_expense(p_expense_id uuid, p_category text DEFAULT NULL::text, p_amount numeric DEFAULT NULL::numeric, p_date date DEFAULT NULL::date, p_description text DEFAULT NULL::text, p_payment_method_id uuid DEFAULT NULL::uuid, p_payment_method_provided boolean DEFAULT false, p_branch_id uuid DEFAULT NULL::uuid, p_branch_provided boolean DEFAULT false, p_cost_center_id uuid DEFAULT NULL::uuid, p_cost_center_provided boolean DEFAULT false)
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
  -- asiento-contable-gastos (D7): valores finales resultantes de la edición,
  -- para la carga de ExpenseAdjusted — mismo mapeo que ExpenseCreated.
  v_final_amount        numeric;
  v_final_date          date;
  v_final_kind          text;
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
  WHERE id = p_expense_id AND account_id = v_account_id
  FOR UPDATE;   -- edicion-operaciones-con-dinero (tanda A, D12): sin el lock, dos ediciones a la vez pierden una (lost update)

  IF NOT FOUND THEN
    RAISE EXCEPTION 'expense_not_found: el gasto no existe o no pertenece a esta cuenta'
      USING ERRCODE = 'P0404';
  END IF;

  -- ── D11: los dos guards de inmutabilidad, ANTES DE CUALQUIER ESCRITURA ────
  -- Mismos predicados y mismo ERRCODE que rpc_atomic_update_sale_operation
  -- (baseline). Los mensajes son distinguibles a propósito: el usuario tiene
  -- que saber cuál de los dos libros produjo el bloqueo.
  --
  -- asiento-contable-gastos (D6): la existencia de un ASIENTO contable NO se
  -- suma a estos guards. Un gasto sin movimiento de caja ni bancario sigue
  -- siendo plenamente editable aunque ya tenga su asiento posteado; la
  -- edición lo corrige por el par contra-asiento/asiento nuevo más abajo.
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

  -- ── Importe positivo, espejo del alta ─────────────────────────────────────
  -- Sin esto la edición sería el bypass del guard del alta: un gasto legítimo
  -- pasaría a importe negativo con un solo PUT. `NULL` conserva la semántica
  -- COALESCE heredada del UPDATE que este RPC reemplaza ("no cambia"), y por
  -- eso el predicado es IS NOT NULL AND <= 0 y no el del alta.
  IF p_amount IS NOT NULL AND p_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be greater than zero'
      USING ERRCODE = 'P0400';
  END IF;

  -- ── D12: tri-estado, campo por campo, con validación ANTES del UPDATE ─────
  IF p_payment_method_provided THEN
    -- ⚠️ La validación de reimputación se aplica SÓLO cuando el valor cambia.
    -- El formulario manda `paymentMethodId` SIEMPRE (está en el literal del
    -- payload) y en edición ofrece a propósito las formas dadas de baja
    -- (`includeInactive={isEdit}`, para que un gasto histórico siga nombrando
    -- la suya). Con el predicado aplicado sin excepción, desactivar una forma
    -- de pago volvía INOPERABLE todo gasto que la usara: cualquier edición
    -- —aunque sólo tocara el importe— rebotaba con P0404 hasta reactivarla.
    -- Reenviar el valor vigente es PRESERVAR, no reimputar. La TENENCIA sí se
    -- verifica siempre: lo que se relaja es `is_active`/`deleted_at`, nunca el
    -- `account_id`. Gate: sección 8.7, con control negativo (cambiar a OTRA
    -- forma inactiva sigue siendo P0404).
    IF p_payment_method_id IS NOT NULL
       AND p_payment_method_id IS DISTINCT FROM v_old.payment_method_id THEN
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
    ELSIF p_payment_method_id IS NOT NULL THEN
      -- Reenvío del valor vigente: sólo tenencia (el gasto ya es del tenant,
      -- pero la FK de payment_methods no está scopeada por cuenta y el guard
      -- de tenencia no se relaja nunca — lección de cuenta-corriente-party-guard).
      IF NOT EXISTS (
        SELECT 1 FROM public.payment_methods
        WHERE id = p_payment_method_id AND account_id = v_account_id
      ) THEN
        RAISE EXCEPTION 'payment_method_not_found or not active for this account'
          USING ERRCODE = 'P0404';
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

  -- compras-gastos-sucursal-por-defecto (D4/D5): un nulo de sucursal, informado o vigente
  -- (gasto histórico), se resuelve con la MISMA regla que el alta del gasto
  -- (rpc_create_expense): COALESCE con la principal. Sin guard de sucursal operativa
  -- (OQ-3 (a)): el gasto no mueve mercadería y el alta persiste el fallback. La
  -- intención de desimputar la sucursal desaparece del contrato tri-estado; forma de
  -- pago y centro de costo conservan las tres intenciones.
  v_final_branch_id := COALESCE(v_final_branch_id, public.c26_default_branch(v_account_id));

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

  -- ── asiento-contable-gastos (D7): ExpenseAdjusted, SÓLO si existe el alta ──
  -- El predicado evalúa la EXISTENCIA DEL EVENTO de alta, nunca la del
  -- asiento: un gasto creado y editado/borrado dentro de la misma ventana de
  -- relay tiene su ExpenseCreated sin procesar y todavía no tiene asiento, y
  -- tiene que emitir igual — el relay procesa en orden de ocurrencia y el
  -- fallo recuperable (P0451) del consumidor resuelve si quedan en corridas
  -- distintas. Un gasto histórico (sin ExpenseCreated) no emite nada: si
  -- emitiera, el consumidor jamás encontraría el asiento original y
  -- reintentaría con P0451 cada minuto, para siempre (evento envenenado).
  IF EXISTS (
    SELECT 1 FROM public.events
    WHERE event_type = 'ExpenseCreated' AND aggregate_type = 'Expense' AND aggregate_id = p_expense_id AND account_id = v_account_id
  ) THEN
    v_final_amount := COALESCE(p_amount, v_old.amount);
    v_final_date   := COALESCE(p_date, v_old.date::date);

    -- Corrección de findings (revisor, ronda 1, major): el `kind` que decide
    -- la CONTRAPARTIDA del asiento se deriva de lo que REALMENTE ocurrió en
    -- los libros de dinero (design.md D4: "el asiento nombra la cuenta del
    -- libro que efectivamente se movió"), NUNCA de la forma de pago
    -- declarada en el edit. rpc_update_expense jamás llama a
    -- _pay_register_operation_bank_movement ni a c28_register_cash_movement
    -- (la edición no mueve dinero, D6) — y el guard de inmutabilidad de
    -- arriba ya garantiza que, si llegamos hasta acá, el gasto NO tiene
    -- ningún bank_movement posteado. Sin este fix, cambiar la forma de pago
    -- a un kind bancario en la edición acreditaría 1110 Banco sin que exista
    -- ningún movimiento bancario real que lo respalde — un descuadre de
    -- conciliación esperando a pasar. La rama IS NULL (verdadera 100% del
    -- tiempo, por el guard de arriba) queda declarada por robustez, no por
    -- necesidad: si alguna vez cambia el guard, este derivado sigue siendo
    -- correcto sin tocarlo.
    IF EXISTS (
      SELECT 1 FROM public.bank_movements bm
      WHERE bm.source_doc_type = 'expense' AND bm.source_doc_ref = p_expense_id
    ) THEN
      -- Los cuatro kind bancarios son equivalentes para
      -- _journal_expense_credit_account (todos → 1110): cualquiera sirve.
      v_final_kind := 'transfer';
    ELSE
      v_final_kind := NULL;
    END IF;

    INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload)
    VALUES (
      v_account_id, 'ExpenseAdjusted', 'Expense', p_expense_id,
      jsonb_build_object(
        'account_id', v_account_id,
        'expense_id', p_expense_id,
        'amount', v_final_amount,
        'expense_date', v_final_date,
        'cost_center_id', v_final_cost_center_id,
        'kind', v_final_kind
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'expense_id',        p_expense_id,
    'payment_method_id', v_final_payment_method_id,
    'branch_id',         v_final_branch_id,
    'cost_center_id',    v_final_cost_center_id
  );
END;
$function$

