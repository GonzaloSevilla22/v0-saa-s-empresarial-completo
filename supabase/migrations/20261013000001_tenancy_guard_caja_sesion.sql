-- =============================================================================
-- tenancy-guard-caja-outbox — TRAMO h1: guard de tenencia de la SESIÓN DE CAJA
-- en el camino del POS, en dos capas.
-- =============================================================================
--
-- ALCANCE DE ESTE ARCHIVO: sólo h1. El tramo h2 (outbox legible y marcable
-- cross-tenant + el relay Python duplicado) YA SALIÓ, antes y por separado, en
-- el hotfix 20261012000001_revoke_outbox_cross_tenant.sql (PR #460) — así lo
-- resolvió el PO en la OQ-1 del change ("h2 sale como hotfix ahora, h1
-- después"). Acá no se repite ni una línea de aquello: los grupos de tareas 4
-- y 5 están cerrados. Los dos tramos no comparten un solo objeto de base de
-- datos (design.md D5), que es exactamente lo que permitió partirlos.
--
-- Hallazgo h1 (auditoría de tenencia de cuenta-corriente-party-guard, hallazgo
-- lateral h1; verificado contra prod el 2026-08-23 y re-verificado el
-- 2026-08-24, y reproducido en local con dos tenants sintéticos).
--
--   `_c29_confirm_order_core` (SECURITY DEFINER, ejecutable por
--   `authenticated`) es el core que confirman los dos wrappers públicos del
--   POS: rpc_quick_sale y rpc_confirm_sales_order. Valida is_account_writer
--   sobre la orden, valida la forma de pago (WHERE account_id = v_account_id),
--   la sucursal y la cuenta bancaria — pero del `p_cash_session_id` SÓLO
--   chequea `IS NULL` (cash_requires_session, P0400) y lo pasa crudo a
--   c28_register_cash_movement, que es SECURITY INVOKER y sólo exige
--   status='open' + sucursal activa: ni account_id, ni current_account_ids(),
--   ni que la caja sea la de la sucursal efectiva de la venta. Como todos sus
--   callers son SECURITY DEFINER y corren como `postgres`, la RLS de
--   cash_movements no interviene. Resultado reproducido: una venta del tenant
--   A confirmada con la sesión de caja abierta del tenant B tiene éxito y le
--   deja a B una fila en cash_movements — un INGRESO FANTASMA en su arqueo —
--   mientras la caja de A no registra nada.
--
--   El contraste que define el fix vive en el mismo dominio: el FORMULARIO de
--   venta (rpc_create_sale_operation_v2) SÍ lo cierra, con
--   `cash_optin_requires_open_session` (cs.status = 'open' AND
--   cb.branch_id = v_gate_branch → P0422). El guard existía y no se replicó en
--   el POS. Este archivo lo replica; no inventa nada.
--
--   Exposición medida en prod (2026-08-24): los 65 movimientos de caja vivos
--   tienen reference_id en sales_orders, o sea que el 100 % del ledger de caja
--   entró por este único camino sin guard, y hay 3 sesiones de caja abiertas
--   de 3 tenants distintos. Daño histórico medido: 0 de 2 consultas con filas
--   (el hueco está abierto y es alcanzable, pero todavía no produjo datos
--   corruptos) — auditoría en
--   openspec/changes/tenancy-guard-caja-outbox/baseline/.
--
-- DECISIÓN — DOS CAPAS, INVARIANTES DISTINTOS (design.md D1). No son
-- redundantes: expresan cosas diferentes y ninguna cubre lo de la otra.
--
--   CAPA 1, en _c29_confirm_order_core: invariante de SUCURSAL. Es la ÚNICA
--   capa que puede expresarlo, porque `v_gate_branch` —la sucursal efectiva de
--   la venta— sólo existe dentro del core. Cierra el POS por sus dos wrappers
--   de una sola vez: ni rpc_quick_sale ni rpc_confirm_sales_order se tocan
--   (heredan el guard; el gate de este change lo verifica leyendo sus cuerpos
--   vivos).
--
--   CAPA 2, en c28_register_cash_movement: invariante de TENANT. Es la ÚNICA
--   que cubre callers futuros: cualquier función nueva que registre caja
--   hereda el backstop sin acordarse de nada. Resuelve la cuenta por la cadena
--   cash_sessions → cashboxes → branches.account_id COPIANDO el SELECT que
--   rpc_register_cash_movement ya hace (20261006000001 §4), y exige
--   `= ANY(current_account_ids())` → P0401 unauthorized.
--
--   MEMBRESÍA, NO is_account_writer (D1 iii). rpc_register_cash_movement usa
--   is_account_writer (owner/admin), pero copiarlo al helper de bajo nivel
--   ENDURECERÍA el rol del camino del formulario, que hoy resuelve con
--   current_account_ids(): un miembro no-owner que hoy puede registrar una
--   venta en efectivo dejaría de poder. Sería una regresión de permiso
--   encubierta dentro de un change de seguridad. La capa 2 es un backstop de
--   tenencia; la autorización sigue donde está (y el gate verifica que
--   rpc_register_cash_movement conserve su is_account_writer).
--
-- UBICACIÓN DEL GUARD (D2): en el core va con las demás validaciones de
-- payload, inmediatamente después de `cash_requires_session` y ANTES de la
-- primera escritura (el INSERT en operation_idempotency). En el helper va
-- antes del INSERT en cash_movements. El gate del change congela las dos
-- posiciones leyendo el cuerpo vivo, no sólo el comportamiento.
--   Detalle honesto: en ese punto del cuerpo `v_gate_branch` todavía no está
--   asignada — la asignación (`v_gate_branch := v_order.branch_id;`) está unas
--   líneas más abajo y es LITERALMENTE ese valor. El guard compara entonces
--   contra `v_order.branch_id`, que es el mismo dato. Se prefirió eso a mover
--   una línea del baseline: la única diferencia admisible contra el cuerpo
--   vivo de prod es el bloque de guard y sus variables.
--
-- SIN ERRCODEs NUEVOS (D8), y uno de los dos NO es negociable:
--   · Capa 1 → P0422 con el mensaje canónico `cash_optin_requires_open_session`,
--     LITERALMENTE el mismo del formulario, para que las dos superficies
--     produzcan el mismo error y el frontend no tenga que distinguirlas.
--   · Capa 2 → P0401 `unauthorized`, el que rpc_register_cash_movement ya usa
--     para el mismo predicado de tenencia de caja.
--     ⚠ NO puede ser P0001. El gate de comportamiento embebido en
--     20260804000003_fix_c28_cash_movement_balance.sql §(b) invoca este helper
--     tres veces sobre un anchor sintético cuyo usuario NO queda en
--     account_members de la cuenta del anchor, así que con la capa 2 puesta el
--     guard lo rechaza; su manejador es
--     `EXCEPTION WHEN raise_exception … WHEN OTHERS THEN RAISE NOTICE`, y
--     `raise_exception` matchea ÚNICAMENTE P0001. Con P0401 cae en WHEN OTHERS
--     y degrada a NOTICE; con P0001 re-lanzaría y ABORTARÍA `supabase db
--     reset`. Verificado empíricamente (task 3.6), no razonado.
--     Ese gate (b) queda entonces auto-degradado en toda DB fresca. La
--     cobertura NO se pierde: su aserción de saldo firmado (opening 1000, luego
--     +500 / −200 / +300 → 1500 / 1300 / 1600; con el bug viejo de
--     MAX(balance_after) el tercero daría 1800) se REPLICA sobre un tenant bien
--     provisionado en supabase/tests/test_tenancy_guard_caja_outbox.sql (3.7).
--     NO se edita 20260804000003: es una migración ya aplicada en prod, y
--     editarla es el anti-patrón que produjo la regresión de julio.
--
-- BREAKING (dominio): una confirmación de POS con una sesión de caja que no es
-- de la sucursal efectiva de la venta —aunque sea del MISMO tenant— pasa a
-- fallar con P0422. Hoy tiene éxito. Ningún camino de UI puede producir ese
-- input: el selector de caja del POS lista sólo las cajas de la sucursal
-- seleccionada. Es exactamente el caso que hoy corrompe un arqueo.
-- Sin superficie frontend (excepción declarada en el proposal): el único
-- efecto observable por un usuario legítimo es un P0422 en lugar de un éxito
-- silencioso, y ese camino de error ya está construido.
--
-- MAX(version) vivo en prod verificado el 2026-08-24, JUSTO antes de escribir
-- este archivo: 20261012000001 (261 migraciones, con el hotfix de h2 ya
-- aplicado) → el archivo nace como 20261013000001. El propose lo había
-- previsto como 20261012000001; ese número lo tomó el hotfix. Se re-verifica
-- antes del push: en cuenta-corriente-party-guard el número se movió TRES
-- veces porque otras ramas tomaron los intermedios, y un archivo con número
-- menor o igual al MAX remoto no lo aplica NUNCA el push automático de
-- Supabase.
--
-- GATE DE INTEGRIDAD DE FUNCIÓN (regla de la casa desde la saga de métodos de
-- pago): las dos reescrituras parten del `pg_get_functiondef` VIVO de prod,
-- capturado en openspec/changes/tenancy-guard-caja-outbox/baseline/ con md5 y
-- length verificados contra los que registró el propose —los 5 coinciden, o
-- sea que nada cambió en prod desde entonces—, NUNCA del archivo de migración:
--   · _c29_confirm_order_core(text,uuid,text,uuid,text,uuid,text,uuid,uuid)
--     md5 cecd8c5454611f267a5e131d73bf7928 · length 15110
--   · c28_register_cash_movement(uuid,numeric,text,uuid,text)
--     md5 510adc8e150fb5c315e6e9a2635eaff8 · length 2288 · SECURITY INVOKER
-- La ÚNICA diferencia contra ese baseline es el bloque de guard y las
-- variables que declara (verificado mecánicamente: se extrae cada cuerpo de
-- este archivo, se le quita el guard y se diffea contra el baseline → byte
-- idéntico). En julio se perdió un bloque entero (el `credit` de C-30) por
-- reescribir desde el archivo en vez del cuerpo vivo.
--
-- NINGUNA FIRMA CAMBIA → CREATE OR REPLACE puro, sin DROP, sin riesgo de
-- overload 42725 (gate anti-overload al final). c28_register_cash_movement
-- sigue SECURITY INVOKER; _c29_confirm_order_core sigue SECURITY DEFINER.
--
-- Gotcha #432: prod concede EXECUTE a anon/authenticated DIRECTO, no vía el
-- pseudo-rol PUBLIC — un REVOKE que se ve limpio en local puede dejar prod
-- abierto. Por eso el REVOKE de reafirmación nombra la lista completa
-- `PUBLIC, anon`. `service_role` NO se nombra en ningún REVOKE: conserva su
-- EXECUTE (es el rol de los jobs administrativos, no el de la app).
-- Las dos funciones CONSERVAN su GRANT a `authenticated`:
--   · _c29_confirm_order_core está en la allowlist del chequeo (4) del gate de
--     ACLs; revocarla no arregla nada (el hueco era alcanzable igual por sus
--     wrappers rpc_*, que quedan fuera del filtro de nombre de ese chequeo) y
--     sí arriesga el POS. Este archivo cierra el hueco de verdad, así que la
--     justificación de esa entrada se actualiza en el mismo PR.
--   · c28_register_cash_movement conserva el suyo por decisión de la OQ-4: es
--     SECURITY INVOKER (no cae en los chequeos (3) ni (4), que filtran por
--     prosecdef) y con la capa 2 puesta deja de ser una primitiva
--     cross-tenant. Revocarla igual sería más limpio, pero exige auditar si
--     algún camino la invoca directo desde PostgREST, y revocar algo del hot
--     path de caja sin esa auditoría es cómo se rompe el POS un sábado. Queda
--     anotada como candidata.
--
-- Idempotente: CREATE OR REPLACE + REVOKE/GRANT + COMMENT, todos re-aplicables
-- sin efecto (verificado con triple apply en local: sin error y sin cambio del
-- fingerprint de cuerpos + ACLs + COMMENT). Sin BOM UTF-8 (hay gate en CI).
-- ERRCODEs de 5 caracteres (hay gate en CI).
--
-- ORDEN EN CI: este archivo se suma como ÚLTIMO eslabón de la cadena de
-- reapply del step "Verify G1/G4 migrations are idempotent on reapply" de
-- .github/workflows/KPI_Validation.yml. Va último por el mismo motivo que el
-- eslabón anterior: reaplicar migraciones viejas redefine funciones y
-- re-otorga GRANTs en silencio, y varias de esa cadena (20261002000001,
-- 20261003000001, 20261004000001, 20261006000001) redefinen justamente las dos
-- funciones que este archivo reescribe — puesto antes, la cadena le borraría
-- los guards y el gate del change fallaría por orden, no por regresión.
-- =============================================================================


-- =============================================================================
-- 1. CAPA 1 — _c29_confirm_order_core: invariante de SUCURSAL.
--    Cuerpo copiado del baseline vivo de prod (md5
--    cecd8c5454611f267a5e131d73bf7928). La ÚNICA diferencia son las dos
--    variables v_cash_session_status / v_cash_session_branch —los mismos
--    nombres que usa el formulario— y el bloque de guard marcado abajo.
--    Firma sin cambios → CREATE OR REPLACE. Sigue SECURITY DEFINER.
-- =============================================================================

CREATE OR REPLACE FUNCTION public._c29_confirm_order_core(p_idempotency_key text, p_sales_order_id uuid, p_payment_method text, p_cash_session_id uuid DEFAULT NULL::uuid, p_comprobante_type text DEFAULT NULL::text, p_point_of_sale_id uuid DEFAULT NULL::uuid, p_canal text DEFAULT NULL::text, p_payment_method_id uuid DEFAULT NULL::uuid, p_bank_account_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid              uuid;
  v_account_id       uuid;
  v_order            public.sales_orders%ROWTYPE;
  v_gate_branch      uuid;
  v_branch           RECORD;
  v_item             RECORD;
  v_product          RECORD;
  v_branch_qty       numeric(15,4);
  v_qty_norm         numeric(15,4);
  v_existing_op      uuid;
  v_new_op_id        uuid;
  v_new_sale_id      uuid;
  v_fiscal_doc_id    uuid;
  v_fiscal_result    jsonb;
  v_inserted         integer;
  v_canal            text;
  v_total            numeric(15,2) := 0;
  v_qty_before       numeric;
  v_qty_after        numeric;
  -- pos-catalogo-pagos (D2/D3): resolución de kind y cuenta corriente.
  v_kind                 text;
  v_pm_is_active         boolean;
  -- tenancy-guard-caja-outbox (h1, capa 1): mismos nombres que en
  -- rpc_create_sale_operation_v2, de donde se copia el predicado.
  v_cash_session_status  text;
  v_cash_session_branch  uuid;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Validar idempotency_key
  IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P0400';
  END IF;

  -- Cargar la orden
  SELECT * INTO v_order
  FROM public.sales_orders
  WHERE id = p_sales_order_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'sales_order_not_found' USING ERRCODE = 'P0404';
  END IF;

  v_account_id := v_order.account_id;

  -- Guard: permiso de escritura
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- Validar estado de la orden
  IF v_order.status <> 'draft' THEN
    RAISE EXCEPTION 'order_not_in_draft: estado %', v_order.status
      USING ERRCODE = 'P0409';
  END IF;

  -- ─── pos-catalogo-pagos (D2): resolver el kind — el cliente no elige la
  -- taxonomía, la RPC la deriva del catálogo y no le cree al texto que
  -- venga junto. Va con los demás guards de entrada, antes de tocar stock.
  IF p_payment_method_id IS NOT NULL THEN
    SELECT kind, is_active INTO v_kind, v_pm_is_active
    FROM public.payment_methods
    WHERE id = p_payment_method_id
      AND account_id = v_account_id
      AND deleted_at IS NULL;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'payment_method_not_found: % no pertenece a la cuenta o no existe', p_payment_method_id
        USING ERRCODE = 'P0404';
    END IF;

    IF NOT v_pm_is_active THEN
      RAISE EXCEPTION 'payment_method_inactive: % está desactivada', p_payment_method_id
        USING ERRCODE = 'P0400';
    END IF;

    IF p_payment_method IS NOT NULL AND p_payment_method <> v_kind THEN
      RAISE EXCEPTION 'payment_method_mismatch: el texto % no coincide con el kind % de la forma de pago', p_payment_method, v_kind
        USING ERRCODE = 'P0400';
    END IF;
  ELSE
    -- Camino legacy (D2, limpiezas-pagos-admin): sin payment_method_id, el
    -- kind es el texto recibido (o 'other' si viene NULL). A diferencia del
    -- comportamiento anterior (que dejaba el kind viviendo solo en la
    -- columna de texto sales_orders.payment_method, ahora retirada), se
    -- intenta resolver la forma de pago viva y activa de la cuenta con ese
    -- kind (desempate por sort_order, luego id) para imputar
    -- p_payment_method_id. Si no hay ninguna forma de pago sembrada de ese
    -- kind (p.ej. 'check', ver OQ-1), la orden queda sin imputar — no
    -- aborta, es el mismo criterio "sin especificar" que ya contempla la
    -- capability payment-method.
    v_kind := COALESCE(p_payment_method, 'other');

    SELECT id INTO p_payment_method_id
    FROM public.payment_methods
    WHERE account_id = v_account_id
      AND kind = v_kind
      AND is_active = true
      AND deleted_at IS NULL
    ORDER BY sort_order, id
    LIMIT 1;
  END IF;

  -- D6: validación cash sin session → P0400 (ramifica sobre v_kind, no sobre
  -- el texto crudo — D4).
  IF v_kind = 'cash' AND p_cash_session_id IS NULL THEN
    RAISE EXCEPTION 'cash_requires_session: payment_method=cash exige cash_session_id'
      USING ERRCODE = 'P0400';
  END IF;

  -- ╔═══ tenancy-guard-caja-outbox (h1, CAPA 1 — invariante de SUCURSAL) ════╗
  -- El p_cash_session_id llega del payload y hasta acá NADIE lo validaba: sólo
  -- se chequeaba IS NULL (arriba) y se lo pasaba crudo a
  -- c28_register_cash_movement, que no mira account_id. Una sesión de caja de
  -- OTRO TENANT se confirmaba y le dejaba un ingreso fantasma en el arqueo.
  -- El predicado se COPIA de rpc_create_sale_operation_v2 (el formulario, que
  -- ya lo cumplía): sesión abierta Y de la sucursal efectiva de la venta.
  -- Mismo ERRCODE y MISMO mensaje literal: que dos caminos den errores
  -- distintos para la misma condición es deuda, no feature.
  -- Ubicación (D2): junto a las demás validaciones de payload, inmediatamente
  -- después de cash_requires_session y ANTES de la primera escritura (el
  -- INSERT en operation_idempotency, más abajo). Se compara contra
  -- v_order.branch_id porque `v_gate_branch := v_order.branch_id` se asigna
  -- unas líneas más abajo: es el mismo valor, y mover esa asignación habría
  -- introducido una diferencia contra el baseline vivo que no es el guard.
  IF p_cash_session_id IS NOT NULL THEN
    SELECT cs.status, cb.branch_id INTO v_cash_session_status, v_cash_session_branch
    FROM public.cash_sessions cs
    JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
    WHERE cs.id = p_cash_session_id;

    IF v_cash_session_status IS DISTINCT FROM 'open' OR v_cash_session_branch IS DISTINCT FROM v_order.branch_id THEN
      RAISE EXCEPTION 'cash_optin_requires_open_session: la sesión de caja debe estar abierta y pertenecer a la sucursal efectiva de la venta'
        USING ERRCODE = 'P0422';
    END IF;
  END IF;
  -- ╚════════════════════════════════════════════════════════════════════════╝

  -- pos-catalogo-pagos (D3): restaurar el guard credit_requires_client del
  -- bloque C-30 (20260720000001), ANTES de tocar stock — junto con los
  -- demás guards de entrada.
  IF v_kind = 'credit' AND v_order.client_id IS NULL THEN
    RAISE EXCEPTION 'credit_requires_client: una venta a crédito exige client_id en la orden'
      USING ERRCODE = 'P0400';
  END IF;

  -- Validar payment_method (D4: vocabulario completo del catálogo, los 7 kind)
  IF v_kind NOT IN ('cash', 'transfer', 'card', 'check', 'wallet', 'credit', 'other') THEN
    RAISE EXCEPTION 'invalid_payment_method: %', v_kind
      USING ERRCODE = 'P0400';
  END IF;

  -- Resolver branch del gate (ya está en la orden; usamos la branch de la orden)
  v_gate_branch := v_order.branch_id;

  -- Validar que la branch esté activa
  SELECT id, status INTO v_branch
  FROM public.branches
  WHERE id = v_gate_branch AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found' USING ERRCODE = 'P0404';
  END IF;

  IF v_branch.status = 'closed' THEN
    RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
  END IF;

  -- Canal normalizado
  v_canal := NULLIF(trim(COALESCE(p_canal, '')), '');

  -- ─── Idempotencia (DEC-06) ───────────────────────────────────────────────
  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency
    (user_id, idempotency_key, operation_kind, operation_id)
  VALUES
    (v_uid, p_idempotency_key, 'sale', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    -- Replay: devolver la operación original sin re-ejecutar
    -- (v3-document-status-history: el return temprano garantiza que el replay
    -- NO inserta historial duplicado). La forma de pago del replay se ignora
    -- (pos-catalogo-pagos: mismo criterio, ahora también para payment_method_id).
    SELECT operation_id INTO v_existing_op
    FROM public.operation_idempotency
    WHERE user_id = v_uid
      AND operation_kind = 'sale'
      AND idempotency_key = p_idempotency_key;

    RETURN jsonb_build_object(
      'sales_order_id',  p_sales_order_id,
      'operation_id',    v_existing_op,
      'replayed',        true
    );
  END IF;

  -- ─── Calcular total y descontar stock por línea ──────────────────────────
  FOR v_item IN
    SELECT * FROM public.sales_order_items
    WHERE sales_order_id = p_sales_order_id
    ORDER BY id
  LOOP
    v_total := v_total + v_item.subtotal;

    IF v_item.product_id IS NOT NULL THEN
      -- v3-snapshot-pattern: se agrega sku, cost al lock existente.
      SELECT id, user_id, name, sku, cost INTO v_product
      FROM public.products
      WHERE id = v_item.product_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'product_not_found: %', v_item.product_id
          USING ERRCODE = 'P0404';
      END IF;

      v_qty_norm := v_item.quantity;

      -- Gate per-branch
      SELECT COALESCE(quantity, 0) INTO v_branch_qty
      FROM public.branch_stock
      WHERE product_id = v_item.product_id AND branch_id = v_gate_branch;

      v_branch_qty := COALESCE(v_branch_qty, 0);

      IF v_branch_qty < v_qty_norm THEN
        RAISE EXCEPTION 'stock_insuficiente para producto %: disponible %, solicitado %',
          v_item.product_id, v_branch_qty, v_qty_norm
          USING ERRCODE = 'P0409';
      END IF;

      v_qty_before := v_branch_qty;
      v_qty_after  := v_branch_qty - v_qty_norm;

      -- Descontar stock (C-21 helper)
      PERFORM public.c21_apply_branch_stock_delta(
        v_account_id, v_item.product_id, v_gate_branch, -v_qty_norm
      );

      -- Insertar fila legacy sales (retrocompat D4). app-timezone-argentina
      -- (task 5): día argentino, no CURRENT_DATE (UTC del servidor).
      -- pos-catalogo-pagos: cada fila legacy nace con payment_method_id (D2).
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity,
         unit_id, total, currency, date, operation_id, branch_id, canal,
         payment_method_id)
      VALUES
        (v_uid, v_account_id, v_order.client_id, v_item.product_id,
         v_item.price, v_item.quantity,
         v_item.unit_id, v_item.subtotal, 'ARS', public.reporting_local_today(),
         v_new_op_id, v_gate_branch, v_canal, p_payment_method_id)
      RETURNING id INTO v_new_sale_id;

      -- v3-snapshot-pattern: congelar name/sku/cost desde v_product (2.4).
      -- iva_rate_snapshot NULL (D3).
      INSERT INTO public.sale_items (
        sale_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
        name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot
      ) VALUES (
        v_new_sale_id, v_item.product_id, v_account_id, NULL,
        v_item.quantity, v_item.unit_id, v_item.price, v_item.subtotal,
        v_product.name, v_product.sku, v_product.cost, NULL
      );

      -- stock_movements (reference_type='sale') — v3-snapshot-pattern: costo congelado.
      INSERT INTO public.stock_movements (
        user_id, account_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id, reference_type, performed_by,
        operation_group_id, branch_id, unit_cost_snapshot
      ) VALUES (
        v_uid, v_account_id, v_item.product_id, v_product.name, 'sale',
        -v_qty_norm, v_qty_before, v_qty_after,
        v_new_sale_id, 'sale', v_uid,
        v_new_op_id, v_gate_branch, v_product.cost
      );
    ELSE
      -- Línea de servicio sin producto — solo fila legacy (2.6: sin snapshot,
      -- name_snapshot ya vive en sales_order_items.name_snapshot desde su
      -- propia creación en quick_sale/confirm_sales_order — no aplica acá).
      -- app-timezone-argentina (task 5): día argentino, no CURRENT_DATE.
      -- pos-catalogo-pagos: también nace con payment_method_id (D2).
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity,
         unit_id, total, currency, date, operation_id, branch_id, canal,
         payment_method_id)
      VALUES
        (v_uid, v_account_id, v_order.client_id, NULL,
         v_item.price, v_item.quantity,
         v_item.unit_id, v_item.subtotal, 'ARS', public.reporting_local_today(),
         v_new_op_id, v_gate_branch, v_canal, p_payment_method_id)
      RETURNING id INTO v_new_sale_id;
    END IF;
  END LOOP;

  -- ─── Caja (C-28 helper intra-transacción) ───────────────────────────────
  -- pos-catalogo-pagos (D4): ramifica sobre v_kind, no sobre el texto crudo.
  IF v_kind = 'cash' THEN
    PERFORM public.c28_register_cash_movement(
      p_cash_session_id,
      v_total,
      'sale',
      p_sales_order_id
    );
  END IF;

  -- ─── pagos-cableados-restantes (D2): cuenta corriente del cliente — el
  -- bloque inline restaurado por pos-catalogo-pagos (D3) se REEMPLAZA por
  -- la llamada al helper compartido _pay_register_party_charge (D1), la
  -- misma definición que usa el formulario de venta (rpc_create_sale_
  -- operation_v2). client_id ya validado arriba (credit_requires_client
  -- antes del descuento de stock). El helper posta el cargo C-30 y emite
  -- CustomerAccountCharged en la misma operación atómica — nada de esto
  -- se relaja, sólo deja de estar duplicado.
  IF v_kind = 'credit' THEN
    PERFORM public._pay_register_party_charge(
      v_account_id, 'customer', v_order.client_id, v_total, p_sales_order_id, v_new_op_id
    );
  END IF;

  -- ─── pos-banco-movimientos (D5): movimiento bancario operativo — después
  -- de caja/cuenta corriente, ANTES del bloque fiscal (task 4.1). NULL si no
  -- corresponde escribir (kind no bancario, o bancario sin cuenta resuelta —
  -- D2). value_date = día ART (D4, el POS nunca dispara P0424: opera siempre
  -- sobre hoy).
  PERFORM public._pay_register_operation_bank_movement(
    v_account_id, v_kind, p_payment_method_id, p_bank_account_id,
    v_total, 'in', 'sale', p_sales_order_id,
    public.reporting_local_today(), v_gate_branch, NULL
  );

  -- ─── Numeración fiscal (C-27, opcional) ─────────────────────────────────
  -- GATE OQ-G: bloque fiscal copiado SIN TOCAR NI UNA LÍNEA desde la
  -- definición viva capturada 2026-08-19. No modificar sin sign-off del PO.
  IF p_comprobante_type IS NOT NULL THEN
    SELECT public.rpc_emit_pending_cae(
      p_comprobante_type,
      v_total,
      v_order.client_id,
      p_point_of_sale_id
    ) INTO v_fiscal_result;

    v_fiscal_doc_id := (v_fiscal_result->>'fiscal_document_id')::uuid;
  END IF;

  -- ─── INSERT outbox (DEC-20 — SaleConfirmed) ─────────────────────────────
  -- pos-catalogo-pagos: el payload lleva el kind EFECTIVO (v_kind), no el
  -- texto crudo del cliente — coherente con lo que persiste sales_orders.
  -- limpiezas-pagos-admin (D1 de design.md): esta clave NO cambia — el
  -- consumidor (_journal_post_from_event) lee el PAYLOAD, nunca la columna.
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id,
    'SaleConfirmed',
    'SalesOrder',
    p_sales_order_id,
    jsonb_build_object(
      'account_id',      v_account_id,
      'branch_id',       v_gate_branch,
      'sales_order_id',  p_sales_order_id,
      'operation_id',    v_new_op_id,
      'total',           v_total,
      'payment_method',  v_kind,
      'client_id',       v_order.client_id,
      'occurred_at',     now()
    ),
    now()
  );

  -- v3-document-status-history (RN-A1): transición draft→confirmed en la
  -- misma transacción atómica (junto con stock, caja, fiscal y outbox)
  PERFORM public.record_status_transition(
    v_account_id, 'sales_order', p_sales_order_id, 'draft', 'confirmed', v_uid, NULL);

  -- ─── Transicionar la orden a confirmed ───────────────────────────────────
  -- limpiezas-pagos-admin (G1b): la columna de texto payment_method fue
  -- retirada — la orden persiste únicamente payment_method_id (resuelto
  -- arriba, explícito o vía la resolución legacy D2). El kind efectivo
  -- (v_kind) sigue viajando en el payload del evento SaleConfirmed.
  UPDATE public.sales_orders
  SET
    status              = 'confirmed',
    payment_method_id   = p_payment_method_id,
    total               = v_total,
    sale_operation_id   = v_new_op_id,
    fiscal_document_id  = v_fiscal_doc_id
  WHERE id = p_sales_order_id;

  RETURN jsonb_build_object(
    'sales_order_id',  p_sales_order_id,
    'operation_id',    v_new_op_id,
    'total',           v_total,
    'fiscal_doc_id',   v_fiscal_doc_id,
    'replayed',        false
  );
END;
$function$;

COMMENT ON FUNCTION public._c29_confirm_order_core(text, uuid, text, uuid, text, uuid, text, uuid, uuid) IS
  'C-29 (sales-order): core transaccional de la confirmación de una '
  'SalesOrder — lo comparten los dos wrappers públicos del POS, rpc_quick_sale '
  'y rpc_confirm_sales_order. '
  'tenancy-guard-caja-outbox (h1, capa 1): valida el p_cash_session_id con el '
  'MISMO predicado que el formulario de venta (rpc_create_sale_operation_v2) — '
  'la sesión debe estar abierta Y pertenecer a la sucursal efectiva de la '
  'venta — y falla con P0422 cash_optin_requires_open_session. Antes sólo '
  'chequeaba IS NULL y pasaba el id crudo a c28_register_cash_movement, así '
  'que una sesión de caja de OTRO TENANT (o de otra sucursal del mismo tenant) '
  'se confirmaba y dejaba un ingreso fantasma en el arqueo de la víctima. '
  'El guard va entre cash_requires_session y la primera escritura (D2); los '
  'dos wrappers lo HEREDAN y por eso no se tocan. Backstop de tenant en '
  'c28_register_cash_movement (P0401). Candado: '
  'supabase/tests/test_tenancy_guard_caja_outbox.sql.';

-- Reafirmación de ACLs (CREATE OR REPLACE las preserva; se reafirman igual,
-- patrón uniforme del proyecto). CONSERVA su GRANT a `authenticated`: es el
-- helper que ejecutan los dos wrappers del POS y está en la allowlist del
-- chequeo (4) de test_function_acl_gate.sql, con justificación actualizada en
-- este mismo PR. `service_role` no se nombra: conserva su EXECUTE.
REVOKE ALL ON FUNCTION public._c29_confirm_order_core(text, uuid, text, uuid, text, uuid, text, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._c29_confirm_order_core(text, uuid, text, uuid, text, uuid, text, uuid, uuid) TO authenticated;


-- =============================================================================
-- 2. CAPA 2 — c28_register_cash_movement: backstop de TENANT.
--    Cuerpo copiado del baseline vivo de prod (md5
--    510adc8e150fb5c315e6e9a2635eaff8). La ÚNICA diferencia es la variable
--    v_owner_account_id y el bloque de guard marcado abajo. Firma sin cambios
--    → CREATE OR REPLACE. SIGUE SIENDO SECURITY INVOKER (no se convierte en
--    DEFINER: se invoca siempre desde funciones que ya lo son).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.c28_register_cash_movement(p_session_id uuid, p_amount numeric, p_type text, p_reference_id uuid DEFAULT NULL::uuid, p_description text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_session      public.cash_sessions%ROWTYPE;
  v_branch_status text;
  v_prev_balance  numeric(12,2);
  v_balance_after numeric(12,2);
  v_movement_id   uuid;
  v_user_id       uuid;
  -- tenancy-guard-caja-outbox (h1, capa 2): cuenta dueña de la sesión.
  v_owner_account_id uuid;
BEGIN
  -- D3: lock de fila de la sesión para serializar cálculo de balance_after
  SELECT * INTO v_session
  FROM public.cash_sessions
  WHERE id = p_session_id
  FOR UPDATE;

  -- Validar que la sesión esté open
  IF v_session.id IS NULL OR v_session.status <> 'open' THEN
    RAISE EXCEPTION 'no_open_session'
      USING ERRCODE = 'P0409';
  END IF;

  -- ╔═══ tenancy-guard-caja-outbox (h1, CAPA 2 — backstop de TENANT) ════════╗
  -- Este helper es el choke point de TODA escritura en caja y era SECURITY
  -- INVOKER sin una sola mención a account_id: cualquier caller SECURITY
  -- DEFINER (corren como postgres, la RLS no interviene) podía imputarle un
  -- movimiento a la caja de otro tenant pasándole el id de su sesión. Lo
  -- explotaba _c29_confirm_order_core; el guard de acá cubre además a todo
  -- caller FUTURO, que es lo que la capa 1 no puede hacer.
  -- El SELECT de resolución se COPIA de rpc_register_cash_movement
  -- (20261006000001 §4): misma cadena de FKs, no una consulta nueva. Por eso
  -- la firma no cambia — el tenant es derivable de lo que ya se recibe.
  -- MEMBRESÍA (current_account_ids), NO is_account_writer: es un backstop de
  -- tenencia dentro de operaciones ya autorizadas; exigir permiso de escritura
  -- acá endurecería en silencio el rol del camino del formulario (D1 iii).
  -- Se usa `IN (SELECT public.current_account_ids())`, la forma canónica del
  -- proyecto (la función devuelve SETOF uuid, no un array: `= ANY(...)` falla
  -- con "op ANY/ALL (array) requires array on right side").
  -- Falla cerrado si la cuenta no resuelve (inalcanzable: los FKs
  -- cash_sessions→cashboxes→branches son NOT NULL y la sesión ya existe).
  -- ERRCODE P0401, el mismo que rpc_register_cash_movement usa para este
  -- predicado. NO puede ser P0001: abortaría el gate embebido de
  -- 20260804000003 §(b), cuyo handler matchea sólo ese código (ver cabecera).
  SELECT b.account_id INTO v_owner_account_id
  FROM public.cash_sessions cs
  JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
  JOIN public.branches b   ON b.id  = cb.branch_id
  WHERE cs.id = p_session_id;

  IF v_owner_account_id IS NULL
     OR v_owner_account_id NOT IN (SELECT public.current_account_ids()) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;
  -- ╚════════════════════════════════════════════════════════════════════════╝

  -- Validar que la sucursal esté activa
  SELECT b.status INTO v_branch_status
  FROM public.cashboxes cb
  JOIN public.branches b ON b.id = cb.branch_id
  WHERE cb.id = v_session.cashbox_id;

  IF v_branch_status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'branch_closed'
      USING ERRCODE = 'P0422';
  END IF;

  -- Calcular el saldo previo = opening_balance + SUM(amount de los movimientos previos).
  -- (SUM(amount), NO MAX(balance_after): el saldo corriente puede BAJAR tras un egreso,
  --  y MAX devolvería el pico histórico, no el saldo actual. El FOR UPDATE de arriba
  --  serializa el cálculo, así que SUM es seguro. Mismo patrón que _register_bank_movement.)
  SELECT v_session.opening_balance + COALESCE(SUM(cm.amount), 0)
  INTO v_prev_balance
  FROM public.cash_movements cm
  WHERE cm.session_id = p_session_id;

  v_balance_after := v_prev_balance + p_amount;

  -- Resolver el usuario actual del JWT
  v_user_id := auth.uid();

  -- Insertar el movimiento (append-only). banco-caja-historial-ajustes:
  -- suma description — cash_movements_adjustment_needs_reason rechaza un
  -- adjustment sin motivo no vacío, sin código nuevo acá.
  INSERT INTO public.cash_movements
    (session_id, amount, movement_type, reference_id, balance_after, created_by, description)
  VALUES
    (p_session_id, p_amount, p_type, p_reference_id, v_balance_after, v_user_id, p_description)
  RETURNING id INTO v_movement_id;

  RETURN v_movement_id;
END;
$function$;

COMMENT ON FUNCTION public.c28_register_cash_movement(uuid, numeric, text, uuid, text) IS
  'C-28 (cash-session): helper intra-transacción que registra un movimiento de '
  'caja (append-only) y calcula balance_after como opening_balance + '
  'SUM(amount), con FOR UPDATE sobre la sesión. SECURITY INVOKER. '
  'tenancy-guard-caja-outbox (h1, capa 2): resuelve la cuenta dueña de la '
  'sesión por cash_sessions → cashboxes → branches.account_id —el mismo SELECT '
  'que rpc_register_cash_movement— y exige que esté en current_account_ids(), '
  'si no P0401 unauthorized. Es el BACKSTOP DE TENANT: cubre a todo caller, '
  'presente y futuro, incluido el que se olvide de validar. Membresía, NO '
  'is_account_writer (la autorización sigue en el caller). El invariante de '
  'SUCURSAL —que la caja sea la de la sucursal de la venta— no se puede '
  'expresar acá: vive en _c29_confirm_order_core y en '
  'rpc_create_sale_operation_v2 (P0422). Candado: '
  'supabase/tests/test_tenancy_guard_caja_outbox.sql.';

-- Reafirmación de ACLs. CONSERVA su GRANT a `authenticated` (OQ-4: no se
-- revoca en este change — ver cabecera). `service_role` no se nombra.
REVOKE ALL ON FUNCTION public.c28_register_cash_movement(uuid, numeric, text, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.c28_register_cash_movement(uuid, numeric, text, uuid, text) TO authenticated;


-- =============================================================================
-- 3. Gates de la propia migración.
-- =============================================================================

DO $$
DECLARE
  v_count integer;
  v_bad   text;
  v_def   text;
BEGIN
  -- (a) ANTI-OVERLOAD 42725: ninguna de las dos funciones cambió de firma, así
  --     que tiene que haber exactamente una definición de cada una. Cualquier
  --     valor distinto de 2 es un overload fantasma (un CREATE que no
  --     reemplazó nada).
  SELECT count(*) INTO v_count
  FROM pg_proc
  WHERE pronamespace = 'public'::regnamespace
    AND proname IN ('_c29_confirm_order_core', 'c28_register_cash_movement');

  IF v_count <> 2 THEN
    RAISE EXCEPTION 'tenancy-guard-caja-outbox ANTI-OVERLOAD: esperaba exactamente 2 definiciones (una por función, ninguna cambió de firma), hay %. Revisar overloads fantasma con: SELECT proname, pg_get_function_identity_arguments(oid) FROM pg_proc WHERE pronamespace = ''public''::regnamespace AND proname IN (''_c29_confirm_order_core'', ''c28_register_cash_movement'');', v_count;
  END IF;

  -- (b) Los dos guards quedaron efectivamente escritos en el cuerpo vivo. Es
  --     el candado contra un reapply de una migración vieja que redefina
  --     alguna de las dos y borre el guard en silencio (la cadena de reapply
  --     de CI tiene cuatro eslabones que redefinen una u otra).
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = '_c29_confirm_order_core';
  IF position('cash_optin_requires_open_session' in v_def) = 0 THEN
    RAISE EXCEPTION 'tenancy-guard-caja-outbox GUARD: el cuerpo vivo de _c29_confirm_order_core no contiene el guard cash_optin_requires_open_session (capa 1).';
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'c28_register_cash_movement';
  IF position('current_account_ids' in v_def) = 0 THEN
    RAISE EXCEPTION 'tenancy-guard-caja-outbox GUARD: el cuerpo vivo de c28_register_cash_movement no resuelve la cuenta por current_account_ids() (capa 2).';
  END IF;

  -- Entorno sin roles de Supabase (p.ej. postgres pelado): no hay ACL que verificar.
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    RAISE NOTICE 'tenancy-guard-caja-outbox: roles de Supabase ausentes — se omite la verificación de ACLs.';
    RETURN;
  END IF;

  -- (c) Las dos funciones conservan EXECUTE para `authenticated` y NO lo
  --     tienen para `anon`. Sólo se afirma esto: el privilegio de
  --     `service_role` difiere entre entornos (en prod lo tiene, en local no,
  --     porque nacieron con REVOKE ALL FROM PUBLIC + GRANT sólo a
  --     authenticated) y este gate corre contra local. Lo que importa —que
  --     ningún REVOKE de este archivo nombre a service_role— se sostiene por
  --     inspección del archivo.
  SELECT string_agg(sig, ', ') INTO v_bad
  FROM (
    SELECT unnest(ARRAY[
      'public._c29_confirm_order_core(text,uuid,text,uuid,text,uuid,text,uuid,uuid)',
      'public.c28_register_cash_movement(uuid,numeric,text,uuid,text)'
    ]) AS sig
  ) s
  WHERE NOT has_function_privilege('authenticated', s.sig::regprocedure, 'EXECUTE')
     OR      has_function_privilege('anon',         s.sig::regprocedure, 'EXECUTE');

  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'tenancy-guard-caja-outbox ACL: las dos funciones reescritas deben conservar EXECUTE para authenticated y NO tenerlo para anon, están mal: %', v_bad;
  END IF;

  -- (d) Los wrappers públicos del POS siguen expuestos y SIN el guard escrito:
  --     lo heredan del core. Si alguien lo duplicara acá tendríamos dos
  --     definiciones del mismo invariante, que es cómo divergen.
  SELECT string_agg(sig, ', ') INTO v_bad
  FROM (
    SELECT unnest(ARRAY[
      'public.rpc_quick_sale(text,uuid,jsonb,text,uuid,text,uuid,uuid,text,uuid,uuid)',
      'public.rpc_confirm_sales_order(text,uuid,text,uuid,text,uuid,uuid,text,uuid,uuid)'
    ]) AS sig
  ) s
  WHERE NOT has_function_privilege('authenticated', s.sig::regprocedure, 'EXECUTE');

  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'tenancy-guard-caja-outbox ACL: los wrappers públicos del POS perdieron su EXECUTE para authenticated: %', v_bad;
  END IF;

  -- (e) VERIFICACIÓN (no REVOKE) heredada de los dos eslabones anteriores de
  --     la cadena de reapply: los helpers de dinero que revocó el hotfix
  --     20261010000001 (PR #454) y las dos RPCs del outbox que revocó el
  --     hotfix 20261012000001 (PR #460) tienen que seguir cerrados. Este
  --     archivo es el último en tocar el schema, así que es el lugar natural
  --     para detectar que un eslabón intermedio los reabrió. Si esto falla, el
  --     problema NO está acá: está en el orden de la cadena o en una migración
  --     nueva que volvió a arrastrar el bloque REVOKE+GRANT "de plantilla".
  SELECT string_agg(sig, ', ') INTO v_bad
  FROM (
    SELECT unnest(ARRAY[
      'public._pay_register_party_charge(uuid,text,uuid,numeric,uuid,uuid)',
      'public._journal_post_from_event(public.events)',
      'public.rpc_process_outbox_batch(integer)',
      'public.rpc_mark_event_processed(uuid)'
    ]) AS sig
  ) s
  WHERE has_function_privilege('anon',          s.sig::regprocedure, 'EXECUTE')
     OR has_function_privilege('authenticated', s.sig::regprocedure, 'EXECUTE');

  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'tenancy-guard-caja-outbox ACL: funciones cerradas por los hotfixes #454 y #460 volvieron a ser ejecutables por anon/authenticated: %', v_bad;
  END IF;

  RAISE NOTICE 'tenancy-guard-caja-outbox (h1) OK: 2 funciones con una sola definición y su guard escrito, ACLs intactas (authenticated sí, anon no), wrappers del POS expuestos y sin duplicar el guard, y los cierres de #454/#460 en pie.';
END $$;
