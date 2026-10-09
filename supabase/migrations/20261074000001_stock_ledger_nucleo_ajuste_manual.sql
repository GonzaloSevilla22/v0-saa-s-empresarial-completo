-- =============================================================================
-- stock-ledger-solo-rpc — TANDA B (G2 + G4 + resto de G5): un solo núcleo de
-- ajuste manual de stock, con rol y motivo exigidos EN LA BASE
-- =============================================================================
--
-- Governance ALTA (ledger de stock; reescribe las RPCs que mueven el saldo).
-- Sign-off del PO 2026-10-08: "firmo el candidato con las recomendaciones"
-- (5 decisiones: roles owner/admin/stock; el alta deja "Stock inicial" sola y la
-- edición deriva al modal; tanda A = G1 sola, tanda B = el resto; backfill ya
-- hecho por #617; importador -> ledger fuera de alcance) y "aplicá las tres
-- recomendaciones" (OQ-1: se quitan transfer_in/transfer_out del ajuste manual;
-- OQ-2: CAN_STOCK para el stock inicial del alta; OQ-3: las transferencias
-- siguen con is_account_writer). La tanda A (20261073000001, PR #620) ya está
-- en prod (verificada 2026-10-09): la escritura directa a stock_movements y
-- branch_stock está cerrada y la reversa dejó de ser pública.
-- Procedencia: openspec/changes/stock-ledger-solo-rpc/ (proposal, design D4-D13,
-- specs branch-stock / inventory-single-ledger / stock-transfer).
--
-- QUÉ RESIDUO CIERRA. Con la tanda A puesta quedaba abierto el AJUSTE SIN ROL:
--   · rpc_apply_product_stock_delta (EXECUTE para authenticated) aceptaba a
--     cualquier escritor, SIN motivo, y con p_log_movement = false CAMBIABA EL
--     SALDO SIN DEJAR MOVIMIENTO; con p_allow_negative = true bajaba a cero un
--     saldo sin chequeo (el "piso" de la reversa);
--   · rpc_adjust_branch_stock y rpc_stock_adjustment aceptaban a 7 de los 8
--     roles (is_account_writer), sin motivo obligatorio, cada una con su propia
--     aritmética, su propia tenencia y su propio sello (rpc_stock_adjustment
--     grababa el TOTAL del producto como antes/después; rpc_adjust_branch_stock
--     guardaba el motivo en `notes`; la tenencia de una era products.user_id y
--     la de la otra no existía: buscaba el producto sólo por id);
--   · rpc_transfer_stock buscaba el producto sólo por id (un producto de otra
--     cuenta se transfería entre sucursales propias).
-- Y una consecuencia de producto: el formulario de edición mandaba SIEMPRE el
-- stock que traía abierto, y el backend aplicaba `objetivo - saldo actual`: una
-- venta entre que se abría el formulario y se guardaba un cambio de PRECIO
-- re-sumaba las unidades vendidas como "Ajuste manual de stock" (ajuste
-- fantasma; reproducido en el stack local, evidence/logs/13_*).
--
-- LO QUE HACE (design D4-D11), en este orden y en UNA transacción:
--
--   1. _stock_assert_can_adjust(p_account_id) — INVOKER, STABLE, interna.
--      Calco de _quote_assert_can_write: is_account_writer (P0401) y rol ACTIVO
--      en {owner, admin, stock} (P0403 insufficient_role). El literal vive acá y
--      está atado por test a CAN_STOCK de backend/core/rbac.py y de
--      frontend/lib/rbac-capabilities.ts (D5).
--
--   2. _stock_apply_delta(cuenta, producto, delta, sucursal, p_allow_negative) —
--      INVOKER, interna. La ARITMÉTICA DEL SALDO, desde el cuerpo vivo de
--      rpc_apply_product_stock_delta (md5 de partida 6d8dcab9c533aab375ea8622d1b011d5):
--      lock del producto FILTRADO POR CUENTA, validación de sucursal
--      (P0404/P0422), resolución de la default operativa, piso en cero trazable
--      (floor_on_purchase_delete) o P0409, c21_apply_branch_stock_delta. La
--      cuenta entra por parámetro (nunca current_account_ids() LIMIT 1). NUNCA
--      escribe el movimiento principal (no existe p_log_movement): lo escribe
--      quien la llama. El único movimiento que escribe es el ajuste de piso,
--      que ya llevaba motivo, y ahora también cuenta y sucursal.
--
--   3. _stock_manual_adjustment(...) — INVOKER, interna. El NÚCLEO (D4-D8):
--      tenencia por products.account_id con lock filtrado (P0404 sin distinguir
--      "no existe" de "es de otra cuenta", y sin tomar jamás el lock de un
--      producto ajeno), rol, motivo no vacío (P0400 stock_adjustment_reason_required),
--      tipo de ajuste manual {adjustment, physical_count, loss, damage, expiry}
--      (P0400 stock_adjustment_type_invalid; loss/damage/expiry sólo restan),
--      RN-20 (padre variant_only/untracked: P0400
--      stock_adjustment_product_not_adjustable), cálculo del delta bajo lock con
--      alcance 'branch' (objetivo por sucursal) o 'total' (conteo físico del
--      modal de /stock, aplicado en la default operativa), UN movimiento sellado
--      con cuenta, sucursal (re-resuelta si c21 la creó perezosamente), autor y
--      motivo, y antes/después EXPRESADOS A NIVEL SUCURSAL.
--
--   4. Tres ENVOLTORIOS públicos, CREATE OR REPLACE con su firma, sus defaults y
--      la forma de su respuesta (así conservan la ACL viva y no hay overload):
--        · rpc_stock_adjustment(7 args)      -> núcleo, sucursal default, alcance 'total'
--        · rpc_adjust_branch_stock(4 args)   -> núcleo, tipo adjustment, alcance 'branch'
--        · rpc_apply_product_stock_delta(6)  -> rechaza p_log_movement <> true y
--          p_allow_negative <> false con P0400 stock_internal_flags_not_allowed;
--          el stock inicial del alta del backend (… 'Stock inicial', TRUE, FALSE)
--          sigue funcionando.
--
--   5. rpc_reverse_stock_movement — CREATE OR REPLACE desde su cuerpo vivo (md5
--      2885cd488052620a1a6309595348d54c), con UN solo cambio: llama a
--      _stock_apply_delta(cuenta, …, TRUE) en lugar de la RPC pública. VA EN LA
--      MISMA MIGRACIÓN que el envoltorio: si no, la reversa de venta/compra
--      chocaría con el P0400 de los flags y el borrado de operaciones se rompería
--      (riesgo R2 del design). Sigue interna (sin EXECUTE para authenticated).
--
--   6. rpc_transfer_stock — CREATE OR REPLACE desde su cuerpo vivo (md5
--      3de807fb783c1efd52104ee110121b68), con UN solo cambio funcional: el
--      producto se busca `WHERE id = p_product_id AND account_id = v_account_id`
--      (P0404, D11). Conserva is_account_writer como guard de rol (OQ-3).
--
--   7. CHECK stock_movements_manual_needs_reason — NOT VALID, sin VALIDATE (D6):
--      ningún escritor (ni siquiera uno SECURITY DEFINER) inserta un movimiento
--      de tipo manual sin motivo. Las 18 filas históricas de prod sin motivo
--      (12 adjustment + 6 physical_count, medido 2026-10-09) hacen fallar un
--      VALIDATE: un NOT VALID se aplica a TODA inserción y actualización futura
--      y deja las filas viejas como están (el ledger es append-only: rellenarlas
--      con un motivo inventado sería reescribirlo con un dato falso).
--
-- DECISIONES QUE CAMBIAN COMPORTAMIENTO VISIBLE (declaradas, firmadas):
--   · Roles: 7 de 8 podían ajustar; ahora sólo owner/admin/stock. Población
--     afectada hoy: 0 (0 cuentas multiusuario).
--   · Motivo obligatorio en los tres caminos (antes opcional); rpc_adjust_branch_stock
--     lo persiste en `reason`, no en `notes`.
--   · rpc_stock_adjustment: el antes/después del movimiento pasa del TOTAL del
--     producto a la SUCURSAL afectada, como todos los demás escritores. Para las
--     40 cuentas de una sola sucursal no cambia nada; para la única multisucursal
--     el historial pasa a ser coherente con el resto (riesgo R5).
--   · rpc_stock_adjustment y rpc_adjust_branch_stock dejan de aceptar
--     transfer_in/transfer_out (OQ-1): 0 filas así en prod; las 1.036
--     transferencias reales salen de rpc_transfer_stock.
--   · Los errores del ajuste dejan de ser check_violation/no_data_found/23000 y
--     pasan a P0400/P0404/P0409 con token (consistente con el resto del
--     dominio); el frontend los traduce en lib/operation-errors.ts.
--   · Tenencia por products.account_id, no por products.user_id: un segundo
--     miembro `admin` puede ajustar un producto que no creó.
--
-- QUÉ NO TOCA. c21_apply_branch_stock_delta (referencia), _delivery_note_*
-- (remitos), rpc_bulk_upsert_products (importador de productos: fuera de alcance,
-- decisión 5), el CHECK de tipos de stock_movements, los tipos `initial` y
-- `return` sin escritor vivo. Las policies y los privilegios de la tanda A.
--
-- MEDIDO ANTES (prod, sólo lectura, 2026-10-09; md5 de las 5 funciones idénticos
-- a los del Anexo A del design; evidence/logs/10_checkpoint_6_1_a_6_4.log):
-- 18 movimientos manuales sin motivo, 0 transfer_in/out manuales, 5 saldos de
-- padres variant_only (hallazgo lateral: no se corrigen acá), 0 cuentas con más de
-- un miembro, MAX(version) = 20261073000001 (320 migraciones).
--
-- ROLLBACK (no hay datos que deshacer): CREATE OR REPLACE de los cinco cuerpos del
-- Anexo A del design (conservan la ACL), ALTER TABLE public.stock_movements DROP
-- CONSTRAINT stock_movements_manual_needs_reason, DROP FUNCTION de las tres
-- internas nuevas y de _stock_assert_can_adjust; revert del PR de backend/frontend.
--
-- Idempotente: CREATE OR REPLACE, REVOKE/GRANT repetidos, DROP CONSTRAINT IF EXISTS
-- + ADD. NUNCA DROP FUNCTION de una RPC con callers (resetearía la ACL).
-- Gate: supabase/tests/test_stock_ledger_solo_rpc.sql (bloques f-m).
-- =============================================================================


-- ── 1. Guard de rol ─────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._stock_assert_can_adjust(p_account_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT public.is_account_writer(p_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;
  IF NOT (public.account_user_active_roles(p_account_id, auth.uid()) && ARRAY['owner', 'admin', 'stock']) THEN
    RAISE EXCEPTION 'insufficient_role: tu rol no permite ajustar el stock a mano (requiere depósito, administrador o dueño)'
      USING ERRCODE = 'P0403';
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public._stock_assert_can_adjust(uuid) FROM PUBLIC, anon, authenticated;


-- ── 2. Aritmética del saldo (sin movimiento principal) ──────────────────────
CREATE OR REPLACE FUNCTION public._stock_apply_delta(
  p_account_id     uuid,
  p_product_id     uuid,
  p_delta          numeric,
  p_branch_id      uuid,
  p_allow_negative boolean
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid           uuid;
  v_product       RECORD;
  v_branch        RECORD;
  v_target_branch uuid;
  v_branch_qty    numeric(15,4);
  v_applied       numeric(15,4);
  v_before        numeric(15,4);
  v_after         numeric(15,4);
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  IF p_delta IS NULL OR p_delta = 0 THEN
    RAISE EXCEPTION 'p_delta must be non-zero' USING ERRCODE = 'P0400';
  END IF;

  -- Lock de la fila del producto = mutex por producto, FILTRADO POR CUENTA: un
  -- producto ajeno no se bloquea ni se encuentra (P0404, sin distinguir "no
  -- existe" de "es de otra cuenta").
  SELECT id, name INTO v_product
  FROM   public.products
  WHERE  id = p_product_id AND account_id = p_account_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found: %', p_product_id USING ERRCODE = 'P0404';
  END IF;

  IF p_branch_id IS NOT NULL THEN
    SELECT id, status INTO v_branch
    FROM   public.branches
    WHERE  id = p_branch_id AND account_id = p_account_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'branch_not_found for this account' USING ERRCODE = 'P0404';
    END IF;
    IF v_branch.status = 'closed' THEN
      RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
    END IF;
  END IF;

  -- C-26: branch destino resuelta (explícita o default operativa)
  v_target_branch := COALESCE(p_branch_id, public.c26_default_branch(p_account_id));

  SELECT COALESCE(quantity, 0) INTO v_branch_qty
  FROM   public.branch_stock
  WHERE  product_id = p_product_id AND branch_id = v_target_branch;
  v_branch_qty := COALESCE(v_branch_qty, 0);

  v_applied := p_delta;

  IF p_delta < 0 AND v_branch_qty + p_delta < 0 THEN
    IF p_allow_negative THEN
      -- OQ-C: floor a 0 trazable — se aplica solo lo disponible y se registra
      -- el ajuste explícito (caso típico: reversa de compra ya vendida). Lleva
      -- motivo, cuenta y sucursal (satisface el CHECK stock_movements_manual_needs_reason).
      v_applied := -v_branch_qty;
      INSERT INTO public.stock_movements (
        user_id, account_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reason, notes, performed_by, branch_id
      ) VALUES (
        v_uid, p_account_id, p_product_id, v_product.name, 'adjustment',
        v_applied, v_branch_qty, 0,
        'floor_on_purchase_delete',
        format('Reversa solicitada: %s, aplicada: %s (stock ya vendido)', p_delta, v_applied),
        v_uid, v_target_branch
      );
    ELSE
      RAISE EXCEPTION 'Stock insuficiente. Disponible: %, delta: %', v_branch_qty, p_delta
        USING ERRCODE = 'P0409';
    END IF;
  END IF;

  v_before := v_branch_qty;
  v_after  := v_branch_qty + v_applied;

  IF v_applied <> 0 THEN
    PERFORM public.c21_apply_branch_stock_delta(
      p_account_id, p_product_id, v_target_branch, v_applied);
  END IF;

  -- Una cuenta sin sucursales recibe su "Casa Central" perezosamente dentro de
  -- c21_apply_branch_stock_delta: se re-resuelve para que el movimiento que
  -- escribe el llamador la selle (cierra el borde declarado de #617).
  IF v_target_branch IS NULL THEN
    v_target_branch := public.c26_default_branch(p_account_id);
  END IF;

  RETURN jsonb_build_object(
    'branch_id',       v_target_branch,
    'quantity_before', v_before,
    'quantity_after',  v_after,
    'quantity_delta',  v_applied,
    'floored',         (v_applied <> p_delta)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public._stock_apply_delta(uuid, uuid, numeric, uuid, boolean) FROM PUBLIC, anon, authenticated;


-- ── 3. Núcleo único de ajuste manual ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._stock_manual_adjustment(
  p_product_id      uuid,
  p_branch_id       uuid,
  p_type            text,
  p_delta           numeric,
  p_target_quantity numeric,
  p_target_scope    text,
  p_reason          text,
  p_notes           text,
  p_reference_id    uuid
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid          uuid;
  v_product      RECORD;
  v_account_id   uuid;
  v_reason       text;
  v_branch       RECORD;
  v_branch_id    uuid;
  v_base         numeric;
  v_branch_qty   numeric(15,4);
  v_delta        numeric;
  v_res          jsonb;
  v_before       numeric;
  v_after        numeric;
  v_applied      numeric;
  v_final_branch uuid;
  v_movement_id  uuid;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- 1. TENENCIA por products.account_id. El lock se toma recién acá y sólo sobre
  --    un producto de una cuenta del usuario: nunca se bloquea una fila ajena.
  --    La cuenta del ajuste es la del producto (no `current_account_ids() LIMIT 1`,
  --    ambiguo para un usuario de varias cuentas).
  SELECT id, name, stock_control_type, account_id INTO v_product
  FROM   public.products
  WHERE  id = p_product_id
    AND  account_id IN (SELECT public.current_account_ids())
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'product_not_found: el producto no existe o no pertenece a tu cuenta' USING ERRCODE = 'P0404';
  END IF;
  v_account_id := v_product.account_id;

  -- 2. ROL (en la base, no sólo en el formulario del cliente).
  PERFORM public._stock_assert_can_adjust(v_account_id);

  -- 3. MOTIVO no vacío tras recortar espacios, tabulaciones y saltos de línea (el CHECK de la
  --    sección 7 usa el mismo conjunto de caracteres).
  v_reason := NULLIF(btrim(p_reason, E' 	
'), '');
  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'stock_adjustment_reason_required: el ajuste de stock requiere un motivo'
      USING ERRCODE = 'P0400';
  END IF;

  -- 4. TIPO de ajuste manual. La transferencia entre sucursales tiene su propia
  --    entidad (rpc_transfer_stock): transfer_in/transfer_out no son ajustes.
  IF p_type IS NULL OR p_type NOT IN ('adjustment', 'physical_count', 'loss', 'damage', 'expiry') THEN
    RAISE EXCEPTION 'stock_adjustment_type_invalid: tipo de ajuste manual no válido (%). Una transferencia entre sucursales se registra con "Transferir stock".',
      COALESCE(p_type, 'NULL')
      USING ERRCODE = 'P0400';
  END IF;

  -- 5. RN-20: un padre variant_only no tiene stock propio y un untracked no tiene stock físico.
  IF v_product.stock_control_type IN ('variant_only', 'untracked') THEN
    RAISE EXCEPTION 'stock_adjustment_product_not_adjustable: este producto no permite ajuste manual de stock (control = %). Los productos con variantes se ajustan por sus variantes; los que no controlan stock no tienen existencias.',
      v_product.stock_control_type
      USING ERRCODE = 'P0400';
  END IF;

  IF p_target_scope IS NOT NULL AND p_target_scope NOT IN ('branch', 'total') THEN
    RAISE EXCEPTION 'p_target_scope debe ser branch o total (recibido: %)', p_target_scope USING ERRCODE = 'P0400';
  END IF;

  -- Sucursal sobre la que se calcula el antes: la explícita (validada contra la
  -- cuenta) o la default operativa.
  IF p_branch_id IS NOT NULL THEN
    SELECT id, status INTO v_branch
    FROM   public.branches
    WHERE  id = p_branch_id AND account_id = v_account_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'branch_not_found for this account' USING ERRCODE = 'P0404';
    END IF;
    IF v_branch.status = 'closed' THEN
      RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
    END IF;
  END IF;
  v_branch_id := COALESCE(p_branch_id, public.c26_default_branch(v_account_id));

  SELECT COALESCE(quantity, 0) INTO v_branch_qty
  FROM   public.branch_stock
  WHERE  product_id = p_product_id AND branch_id = v_branch_id;
  v_branch_qty := COALESCE(v_branch_qty, 0);

  -- Delta: objetivo - saldo del alcance pedido (bajo el lock del producto), o el delta dado.
  IF p_target_quantity IS NOT NULL THEN
    IF p_target_quantity < 0 THEN
      RAISE EXCEPTION 'La cantidad objetivo no puede ser negativa' USING ERRCODE = 'P0400';
    END IF;
    IF p_target_scope = 'total' THEN
      SELECT COALESCE(SUM(quantity), 0) INTO v_base
      FROM   public.branch_stock
      WHERE  product_id = p_product_id;
    ELSE
      v_base := v_branch_qty;
    END IF;
    v_delta := p_target_quantity - v_base;
  ELSE
    v_delta := p_delta;
    IF v_delta IS NULL OR v_delta = 0 THEN
      RAISE EXCEPTION 'Se requiere un delta distinto de cero o una cantidad objetivo' USING ERRCODE = 'P0400';
    END IF;
  END IF;

  -- loss / damage / expiry sólo restan.
  IF p_type IN ('loss', 'damage', 'expiry') AND v_delta >= 0 THEN
    RAISE EXCEPTION 'stock_adjustment_sign_invalid: un ajuste de % sólo puede restar stock (cantidad negativa)',
      CASE p_type WHEN 'loss' THEN 'pérdida' WHEN 'damage' THEN 'rotura' ELSE 'vencimiento' END
      USING ERRCODE = 'P0400';
  END IF;

  -- El conteo físico TOTAL se aplica sobre la default operativa: no puede dejarla negativa.
  IF p_target_quantity IS NOT NULL AND p_target_scope = 'total' AND v_delta < 0 AND v_branch_qty + v_delta < 0 THEN
    RAISE EXCEPTION 'El ajuste excede el stock de la sucursal principal (% disponibles). Usá el ajuste por sucursal.',
      v_branch_qty
      USING ERRCODE = 'P0409';
  END IF;

  IF v_delta <> 0 THEN
    -- Aritmética del saldo: un solo chequeo de negativos, a nivel de la sucursal afectada (P0409).
    v_res          := public._stock_apply_delta(v_account_id, p_product_id, v_delta, v_branch_id, FALSE);
    v_final_branch := (v_res->>'branch_id')::uuid;
    v_before       := (v_res->>'quantity_before')::numeric;
    v_after        := (v_res->>'quantity_after')::numeric;
    v_applied      := (v_res->>'quantity_delta')::numeric;
  ELSE
    -- Con objetivo, un delta 0 se registra igual: deja constancia del conteo.
    v_final_branch := v_branch_id;
    v_before       := v_branch_qty;
    v_after        := v_branch_qty;
    v_applied      := 0;
  END IF;

  -- UN movimiento sellado: cuenta, sucursal, autor y motivo (recortado).
  INSERT INTO public.stock_movements (
    user_id, account_id, product_id, product_name, type,
    quantity_delta, quantity_before, quantity_after,
    reason, notes, performed_by,
    reference_id, reference_type, branch_id
  ) VALUES (
    v_uid, v_account_id, p_product_id, v_product.name, p_type,
    v_applied, v_before, v_after,
    v_reason, p_notes, v_uid,
    p_reference_id,
    CASE WHEN p_reference_id IS NOT NULL THEN 'adjustment' ELSE NULL END,
    v_final_branch
  )
  RETURNING id INTO v_movement_id;

  RETURN jsonb_build_object(
    'movement_id',     v_movement_id,
    'product_id',      p_product_id,
    'product_name',    v_product.name,
    'branch_id',       v_final_branch,
    'quantity_before', v_before,
    'quantity_after',  v_after,
    'quantity_delta',  v_applied,
    'type',            p_type
  );
END;
$function$;

REVOKE ALL ON FUNCTION public._stock_manual_adjustment(uuid, uuid, text, numeric, numeric, text, text, text, uuid)
  FROM PUBLIC, anon, authenticated;


-- ── 4. Envoltorios públicos (misma firma, mismos defaults, misma respuesta) ─

-- 4.1 Ajuste manual del modal y del importador de /stock.
CREATE OR REPLACE FUNCTION public.rpc_stock_adjustment(p_product_id uuid, p_quantity_delta numeric DEFAULT NULL::numeric, p_type text DEFAULT 'adjustment'::text, p_reason text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_reference_id uuid DEFAULT NULL::uuid, p_target_quantity numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_r jsonb;
BEGIN
  -- Sucursal NULL = la default operativa; el objetivo sólo rige para el conteo
  -- físico (comportamiento previo) y es TOTAL del producto.
  v_r := public._stock_manual_adjustment(
    p_product_id, NULL, p_type, p_quantity_delta,
    CASE WHEN p_type = 'physical_count' THEN p_target_quantity ELSE NULL END,
    'total', p_reason, p_notes, p_reference_id);

  RETURN jsonb_build_object(
    'movement_id',     v_r->'movement_id',
    'product_id',      v_r->'product_id',
    'product_name',    v_r->'product_name',
    'quantity_before', v_r->'quantity_before',
    'quantity_after',  v_r->'quantity_after',
    'quantity_delta',  v_r->'quantity_delta',
    'type',            v_r->'type'
  );
END;
$function$;

-- 4.2 Ajuste por sucursal (inventario de /sucursales/[id]/stock): cantidad absoluta.
CREATE OR REPLACE FUNCTION public.rpc_adjust_branch_stock(p_product_id uuid, p_branch_id uuid, p_new_quantity numeric, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_r jsonb;
BEGIN
  IF p_new_quantity IS NULL OR p_new_quantity < 0 THEN
    RAISE EXCEPTION 'New quantity must be >= 0' USING ERRCODE = 'P0400';
  END IF;

  -- A diferencia del ajuste global, acá la sucursal es obligatoria (contrato previo).
  IF p_branch_id IS NULL THEN
    RAISE EXCEPTION 'branch_not_found or unauthorized' USING ERRCODE = 'P0404';
  END IF;

  v_r := public._stock_manual_adjustment(
    p_product_id, p_branch_id, 'adjustment', NULL, p_new_quantity, 'branch',
    p_reason, NULL, NULL);

  RETURN jsonb_build_object(
    'product_id',   p_product_id,
    'branch_id',    v_r->'branch_id',
    'old_quantity', v_r->'quantity_before',
    'new_quantity', v_r->'quantity_after'
  );
END;
$function$;

-- 4.3 Delta de stock (stock inicial del alta de producto, que llama el backend).
CREATE OR REPLACE FUNCTION public.rpc_apply_product_stock_delta(p_product_id uuid, p_delta numeric, p_branch_id uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text, p_log_movement boolean DEFAULT true, p_allow_negative boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_r jsonb;
BEGIN
  -- Los parámetros internos ya no son alcanzables desde authenticated:
  -- p_log_movement = false cambiaba el saldo SIN dejar movimiento y
  -- p_allow_negative = true saltaba el chequeo de negativos (el piso en cero de
  -- la reversa, que ahora vive en _stock_apply_delta).
  IF p_log_movement IS DISTINCT FROM TRUE OR p_allow_negative IS DISTINCT FROM FALSE THEN
    RAISE EXCEPTION 'stock_internal_flags_not_allowed: p_log_movement y p_allow_negative no son configurables desde la API'
      USING ERRCODE = 'P0400';
  END IF;

  v_r := public._stock_manual_adjustment(
    p_product_id, p_branch_id, 'adjustment', p_delta, NULL, 'branch',
    p_reason, NULL, NULL);

  RETURN jsonb_build_object(
    'product_id',      p_product_id,
    'branch_id',       v_r->'branch_id',
    'quantity_before', v_r->'quantity_before',
    'quantity_after',  v_r->'quantity_after',
    'quantity_delta',  v_r->'quantity_delta',
    'floored',         false
  );
END;
$function$;

-- ACL re-afirmada (CREATE OR REPLACE conserva la viva; esto lo declara en el archivo).
REVOKE ALL ON FUNCTION public.rpc_stock_adjustment(uuid, numeric, text, text, text, uuid, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_stock_adjustment(uuid, numeric, text, text, text, uuid, numeric) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.rpc_adjust_branch_stock(uuid, uuid, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_adjust_branch_stock(uuid, uuid, numeric, text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.rpc_apply_product_stock_delta(uuid, numeric, uuid, text, boolean, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_apply_product_stock_delta(uuid, numeric, uuid, text, boolean, boolean) TO authenticated, service_role;


-- ── 5. Reversa de stock (interna): usa el helper, no la RPC pública ─────────
-- Cuerpo = el vivo (md5 2885cd488052620a1a6309595348d54c) salvo el reemplazo del
-- bloque que llamaba a rpc_apply_product_stock_delta(…, NULL, FALSE, TRUE).
CREATE OR REPLACE FUNCTION public.rpc_reverse_stock_movement(p_reference_id uuid, p_reference_type text, p_reason text DEFAULT NULL::text)
 RETURNS SETOF jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid          uuid;
  v_account_id   uuid;
  v_movement     RECORD;
  v_new_type     text;
  v_new_ref_type text;
  v_delta_result jsonb;
  v_new_row      public.stock_movements;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  IF p_reference_type NOT IN ('purchase', 'sale') THEN
    RAISE EXCEPTION 'rpc_reverse_stock_movement: p_reference_type debe ser purchase o sale (recibido: %)', p_reference_type
      USING ERRCODE = 'P0400';
  END IF;

  v_new_type     := CASE p_reference_type WHEN 'purchase' THEN 'purchase_return' ELSE 'sale_return' END;
  v_new_ref_type := p_reference_type || '_reversal';

  -- Scope explícito por cuenta (defensa en profundidad — la RPC es SECURITY
  -- DEFINER, no depende de RLS, pero tampoco debe tocar movimientos de otra
  -- cuenta si p_reference_id colisionara).
  FOR v_movement IN
    SELECT *
    FROM public.stock_movements
    WHERE reference_id   = p_reference_id
      AND reference_type = p_reference_type
      AND account_id     = v_account_id
      AND product_id IS NOT NULL
      AND quantity_delta IS NOT NULL
  LOOP
    -- Reutiliza el helper INTERNO _stock_apply_delta para la aritmética de stock
    -- (lock de producto filtrado por cuenta, floor-a-cero trazable si ya se
    -- vendió, validación de sucursal). ESTA función es la dueña del movimiento
    -- que se registra (necesita su propio type/reference_type/metadata, no el
    -- genérico 'adjustment' del ajuste manual): el helper nunca lo escribe. Ya no
    -- pasa por la RPC pública rpc_apply_product_stock_delta, que exige rol y
    -- motivo y rechaza p_log_movement = false / p_allow_negative = true.
    v_delta_result := public._stock_apply_delta(
      v_account_id, v_movement.product_id, -v_movement.quantity_delta, v_movement.branch_id, TRUE
    );

    INSERT INTO public.stock_movements (
      user_id, account_id, product_id, product_name, type,
      quantity_delta, quantity_before, quantity_after,
      reference_id, reference_type, reason, notes, performed_by, branch_id, metadata
    ) VALUES (
      v_uid, v_account_id, v_movement.product_id, v_movement.product_name, v_new_type,
      (v_delta_result->>'quantity_delta')::numeric,
      (v_delta_result->>'quantity_before')::numeric,
      (v_delta_result->>'quantity_after')::numeric,
      p_reference_id, v_new_ref_type,
      COALESCE(p_reason, format('Reversa de %s', p_reference_type)),
      format('Contramovimiento de %s (movimiento original %s)', p_reference_type, v_movement.id),
      v_uid, v_movement.branch_id,
      jsonb_build_object('reverses_movement_id', v_movement.id)
    )
    RETURNING * INTO v_new_row;

    RETURN NEXT to_jsonb(v_new_row);
  END LOOP;

  RETURN;
END;
$function$;

-- La tanda A la dejó interna; se re-afirma (CREATE OR REPLACE conserva la ACL).
REVOKE EXECUTE ON FUNCTION public.rpc_reverse_stock_movement(uuid, text, text) FROM PUBLIC, anon, authenticated;


-- ── 6. Transferencia: el producto se valida contra la cuenta ────────────────
-- Cuerpo = el vivo (md5 3de807fb783c1efd52104ee110121b68); único cambio funcional:
-- `AND account_id = v_account_id` en la búsqueda del producto (P0404).
CREATE OR REPLACE FUNCTION public.rpc_transfer_stock(p_product_id uuid, p_from_branch_id uuid, p_to_branch_id uuid, p_quantity numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid            uuid;
  v_account_id     uuid;
  v_from           RECORD;
  v_to             RECORD;
  v_from_qty       numeric(15,4);
  v_to_qty         numeric(15,4);
  v_product_name   text;
  v_transfer_id    uuid;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized: only owner or admin can transfer stock'
      USING ERRCODE = 'P0401';
  END IF;

  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P0400';
  END IF;

  IF p_from_branch_id = p_to_branch_id THEN
    RAISE EXCEPTION 'same_branch_transfer_not_allowed' USING ERRCODE = 'P0400';
  END IF;

  -- Ambas branches de la cuenta, existentes y OPERATIVAS (C-26)
  SELECT id, status INTO v_from
  FROM   public.branches
  WHERE  id = p_from_branch_id AND account_id = v_account_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found: origin branch not found or not active'
      USING ERRCODE = 'P0404';
  END IF;
  IF v_from.status = 'closed' THEN
    RAISE EXCEPTION 'branch_closed: la sucursal de origen está cerrada' USING ERRCODE = 'P0422';
  END IF;

  SELECT id, status INTO v_to
  FROM   public.branches
  WHERE  id = p_to_branch_id AND account_id = v_account_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found: destination branch not found or not active'
      USING ERRCODE = 'P0404';
  END IF;
  IF v_to.status = 'closed' THEN
    RAISE EXCEPTION 'branch_closed: la sucursal de destino está cerrada' USING ERRCODE = 'P0422';
  END IF;

  SELECT name INTO v_product_name
  FROM   public.products
  WHERE  id = p_product_id AND account_id = v_account_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found: %', p_product_id USING ERRCODE = 'P0404';
  END IF;

  -- Lock de las filas de ledger (origen primero, destino si existe)
  SELECT quantity INTO v_from_qty
  FROM   public.branch_stock
  WHERE  product_id = p_product_id AND branch_id = p_from_branch_id
  FOR UPDATE;

  SELECT quantity INTO v_to_qty
  FROM   public.branch_stock
  WHERE  product_id = p_product_id AND branch_id = p_to_branch_id
  FOR UPDATE;

  v_from_qty := COALESCE(v_from_qty, 0);
  v_to_qty   := COALESCE(v_to_qty, 0);

  IF v_from_qty < p_quantity THEN
    RAISE EXCEPTION 'insufficient_branch_stock: origin has %, requested %',
      v_from_qty, p_quantity
      USING ERRCODE = 'P0409';
  END IF;

  -- C-26 (D3): la transferencia es una entidad con identidad propia
  INSERT INTO public.stock_transfers (
    account_id, product_id, from_branch_id, to_branch_id, quantity, status, created_by
  ) VALUES (
    v_account_id, p_product_id, p_from_branch_id, p_to_branch_id, p_quantity, 'completed', v_uid
  )
  RETURNING id INTO v_transfer_id;

  -- v3-document-status-history (RN-A2): la transferencia nace completed
  PERFORM public.record_status_transition(
    v_account_id, 'stock_transfer', v_transfer_id, NULL, 'completed', v_uid, NULL);

  INSERT INTO public.stock_movements (
    user_id, account_id, product_id, product_name, type,
    quantity_delta, quantity_before, quantity_after,
    reference_type, performed_by, branch_id, transfer_id
  ) VALUES (
    v_uid, v_account_id, p_product_id, v_product_name, 'transfer_out',
    -p_quantity, v_from_qty, v_from_qty - p_quantity,
    'transfer', v_uid, p_from_branch_id, v_transfer_id
  );

  INSERT INTO public.stock_movements (
    user_id, account_id, product_id, product_name, type,
    quantity_delta, quantity_before, quantity_after,
    reference_type, performed_by, branch_id, transfer_id
  ) VALUES (
    v_uid, v_account_id, p_product_id, v_product_name, 'transfer_in',
    p_quantity, v_to_qty, v_to_qty + p_quantity,
    'transfer', v_uid, p_to_branch_id, v_transfer_id
  );

  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity)
  VALUES (v_account_id, p_product_id, p_from_branch_id, GREATEST(0, v_from_qty - p_quantity))
  ON CONFLICT (product_id, branch_id)
    DO UPDATE SET quantity = public.branch_stock.quantity - p_quantity;

  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity)
  VALUES (v_account_id, p_product_id, p_to_branch_id, p_quantity)
  ON CONFLICT (product_id, branch_id)
    DO UPDATE SET quantity = public.branch_stock.quantity + p_quantity;

  -- v3-notifications-realtime (5.4): productor de TransferDispatched al outbox.
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id, 'TransferDispatched', 'StockTransfer', v_transfer_id,
    jsonb_build_object(
      'transfer_id',            v_transfer_id,
      'source_branch_id',       p_from_branch_id,
      'destination_branch_id',  p_to_branch_id
    ),
    now()
  );

  RETURN jsonb_build_object(
    'transfer_id',          v_transfer_id,
    'from_branch_id',       p_from_branch_id,
    'to_branch_id',         p_to_branch_id,
    'product_id',           p_product_id,
    'quantity_transferred', p_quantity
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_transfer_stock(uuid, uuid, uuid, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_transfer_stock(uuid, uuid, uuid, numeric) TO authenticated, service_role;


-- ── 7. CHECK de segunda capa: un tipo de ajuste manual exige motivo ─────────
-- NOT VALID y SIN VALIDATE (D6): las 18 filas históricas de prod sin motivo
-- (12 adjustment + 6 physical_count) hacen fallar un VALIDATE. Se aplica a toda
-- inserción y actualización futura; las filas viejas quedan como están.
ALTER TABLE public.stock_movements DROP CONSTRAINT IF EXISTS stock_movements_manual_needs_reason;
ALTER TABLE public.stock_movements
  ADD CONSTRAINT stock_movements_manual_needs_reason
  CHECK (
    type NOT IN ('adjustment', 'physical_count', 'loss', 'damage', 'expiry')
    OR (reason IS NOT NULL AND btrim(reason, E' 	
') <> '')
  ) NOT VALID;

COMMENT ON CONSTRAINT stock_movements_manual_needs_reason ON public.stock_movements IS
  'stock-ledger-solo-rpc (tanda B, 2026-10): todo movimiento de ajuste manual (adjustment, physical_count, loss, damage, expiry) exige un motivo no vacío, por cualquier camino y para cualquier escritor, incluso uno SECURITY DEFINER. Está NOT VALID A PROPÓSITO: las 18 filas históricas de prod sin motivo (12 adjustment + 6 physical_count, medido 2026-10-09) harían fallar un VALIDATE, y el ledger es append-only (rellenarlas con un motivo inventado sería reescribirlo con un dato falso). Un NOT VALID se aplica a toda inserción y actualización futura. NO ejecutar VALIDATE CONSTRAINT sin decidir antes qué hacer con esas 18 filas; el gate test_stock_ledger_solo_rpc.sql asserta convalidated = false como estado esperado.';


-- ── 8. Documentación en el catálogo ─────────────────────────────────────────
COMMENT ON FUNCTION public._stock_assert_can_adjust(uuid) IS
  'stock-ledger-solo-rpc (tanda B, D5): guard de rol del ajuste manual de stock. is_account_writer (P0401) y rol ACTIVO en {owner, admin, stock} (P0403 insufficient_role). Calco de _quote_assert_can_write. INTERNA: sin EXECUTE para anon/authenticated. El conjunto está atado por test a CAN_STOCK de backend/core/rbac.py y de frontend/lib/rbac-capabilities.ts.';

COMMENT ON FUNCTION public._stock_apply_delta(uuid, uuid, numeric, uuid, boolean) IS
  'stock-ledger-solo-rpc (tanda B, D4): aritmética del saldo por sucursal (lock del producto filtrado por cuenta, validación de sucursal, default operativa, piso en cero trazable o P0409, c21_apply_branch_stock_delta). Recibe la cuenta por parámetro. NUNCA escribe el movimiento principal: lo escribe quien la llama (el único movimiento que escribe es el ajuste de piso floor_on_purchase_delete). INTERNA, SECURITY INVOKER: sin EXECUTE para anon/authenticated; la invocan _stock_manual_adjustment y rpc_reverse_stock_movement.';

COMMENT ON FUNCTION public._stock_manual_adjustment(uuid, uuid, text, numeric, numeric, text, text, text, uuid) IS
  'stock-ledger-solo-rpc (tanda B, D4-D8): NÚCLEO ÚNICO del ajuste manual de stock. Tenencia por products.account_id (P0404), rol {owner,admin,stock} (P0401/P0403), motivo obligatorio (P0400), tipos adjustment/physical_count/loss/damage/expiry, RN-20, delta bajo lock (alcance branch|total), un movimiento sellado (cuenta, sucursal, autor, motivo) con antes/después a nivel sucursal. INTERNA, SECURITY INVOKER: la alcanzan sólo rpc_stock_adjustment, rpc_adjust_branch_stock y rpc_apply_product_stock_delta.';

COMMENT ON FUNCTION public.rpc_stock_adjustment(uuid, numeric, text, text, text, uuid, numeric) IS
  'stock-ledger-solo-rpc (tanda B): envoltorio público del núcleo de ajuste manual para el modal y el importador de /stock (sucursal default operativa, alcance total). Exige rol owner/admin/stock y motivo. No acepta transfer_in/transfer_out (usar rpc_transfer_stock).';

COMMENT ON FUNCTION public.rpc_adjust_branch_stock(uuid, uuid, numeric, text) IS
  'stock-ledger-solo-rpc (tanda B): envoltorio público del núcleo de ajuste manual por sucursal (cantidad absoluta). Exige rol owner/admin/stock y motivo (persistido en stock_movements.reason). Respuesta: product_id, branch_id, old_quantity, new_quantity.';

COMMENT ON FUNCTION public.rpc_apply_product_stock_delta(uuid, numeric, uuid, text, boolean, boolean) IS
  'stock-ledger-solo-rpc (tanda B): envoltorio público del núcleo de ajuste manual. Su único caller es POST /products con stock inicial (… ''Stock inicial'', TRUE, FALSE). Rechaza p_log_movement <> true y p_allow_negative <> false con P0400 stock_internal_flags_not_allowed: cambiar un saldo sin movimiento o saltarse el chequeo de negativos ya no es alcanzable desde authenticated. Exige rol owner/admin/stock y motivo.';

COMMENT ON FUNCTION public.rpc_reverse_stock_movement(uuid, text, text) IS
  'v31-tenancy-pool-rls (colisión #3, sign-off PO 2026-08-01): reversa de stock por eliminación de compra/venta SIN borrar del ledger — stock_movements tiene policies DELETE/UPDATE con qual=false (deny explícito, append-only por diseño). Inserta el contramovimiento (type purchase_return/sale_return, reference_type purchase_reversal/sale_reversal) con metadata.reverses_movement_id apuntando al original, que permanece. El historial no "olvida" el movimiento anulado: aparece el contramovimiento. stock-ledger-solo-rpc: tanda A (20261073000001) la hizo INTERNA (sin EXECUTE para anon/authenticated; sólo la invocan rpc_delete_sale_operation y rpc_delete_purchase_operation, SECURITY DEFINER); tanda B (20261074000001) hace que use el helper interno _stock_apply_delta en lugar de la RPC pública rpc_apply_product_stock_delta, que ahora exige rol y motivo y rechaza los parámetros internos.';

COMMENT ON FUNCTION public.rpc_transfer_stock(uuid, uuid, uuid, numeric) IS
  'C-26 + v3-document-status-history + v3-notifications-realtime: transferencia atómica entre sucursales (nace completed). Registra NULL→completed en document_status_history (RN-A2) y emite TransferDispatched al outbox (5.4). stock-ledger-solo-rpc (tanda B, D11): el producto se valida contra la cuenta del usuario (P0404); sigue con is_account_writer como guard de rol (OQ-3). Es el único camino para registrar movimientos transfer_out/transfer_in.';
