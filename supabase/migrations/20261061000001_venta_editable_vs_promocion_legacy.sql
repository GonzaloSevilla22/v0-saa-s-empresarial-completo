-- =============================================================================
-- venta-editable-vs-promocion-legacy — 20261061000001
--
-- Governance: CRÍTICO (dominio fiscal: toca la RPC de emisión y las dos RPCs que
-- anulan comprobantes) con tramos MEDIOS (superficie frontend). Pedido aprobado
-- por el PO el 2026-09-23.
--
-- Cierra JUNTOS los hallazgos enlazados de venta-editable-sin-cae (CHANGES.md
-- §venta-editable-sin-cae, N1/N2) y un tercero que encontró el estudio:
--   N2 — rpc_promote_legacy_sale_to_order abortaba con 42883 ("function
--        min(uuid) does not exist") en CADA llamada desde que nació
--        (20260804000001, PR #242): el "Facturar" de una venta cargada a mano
--        nunca funcionó (0/484 operaciones con comprobante en prod).
--   N1 — arreglar N2 reabría una carrera: la edición/borrado resolvían "¿hay
--        orden que anular?" SIN lock y la promoción creaba la orden en OTRA
--        transacción → comprobante pending_cae VIVO por los importes viejos
--        (4/4 interleavings en el red team de #582).
--   N3 — la edición re-apuntaba la orden al operation_id nuevo pero NO le
--        recalculaba total, cliente ni líneas: re-facturar (D5 de #582) o
--        facturar una venta POS editada emitía por el importe VIEJO.
--   H2 — la fórmula viva Σ COALESCE(si.subtotal, s.total) sobre LEFT JOIN
--        sale_items factura el DOBLE en las 2 operaciones de prod (23 filas)
--        con sale_items duplicados: el importe canónico es la cabecera.
--
-- Diseño: ancla de exclusión = las filas de public.sales de la operación
-- (FOR UPDATE, id ascendente), tomadas PRIMERO por promoción, edición y
-- borrado. Orden global único de locks:
--     sales (id asc) → sales_orders → fiscal_documents → resto
-- La emisión no toma sales (sólo lee), así que nunca espera un lock de nivel
-- inferior al que ya tiene: no hay ciclo posible.
--
-- Bloques:
--   (1) _sales_order_sync_from_operation — helper NUEVO, ÚNICA definición de
--       "la orden refleja su operación" (total, cliente, sucursal, líneas).
--   (2) rpc_promote_legacy_sale_to_order — reescrita.
--   (3) rpc_atomic_update_sale_operation — lock temprano + recálculo (N1, N3).
--   (4) rpc_delete_sale_operation — lock temprano (N1).
--   (5) rpc_emit_sale_invoice — guard fail-closed sales_order_out_of_sync (D6).
--   (6) Gate de introspección embebido.
--
-- Integridad de función: (2)-(5) parten del cuerpo VIVO de prod, verificado el
-- 2026-09-23 (md5(prosrc) sin CR):
--   rpc_promote_legacy_sale_to_order  8c94b2a1ee93e1c5694f591d396de825 (20261003000001)
--   rpc_atomic_update_sale_operation  a657c54b18ffadf82687487789d71d7f (20261060000001)
--   rpc_delete_sale_operation         c287c1b442b462085667503f5f41661e (20261060000001)
--   rpc_emit_sale_invoice             01862c3034e15eec2eab915777439851 (20261060000001)
-- Firmas IDÉNTICAS → CREATE OR REPLACE, sin DROP, sin overload (42725). Los
-- COMMENT vivos NO se re-emiten: CREATE OR REPLACE conserva el oid y su
-- comentario; supabase/tests/test_facturar_venta_manual.sql asserta su md5.
-- ACLs re-emitidas idénticas a las vivas. Ningún ERRCODE nuevo (P0400, P0404,
-- P0409, P0422 con tokens nuevos). Sin backfill: 0/124 órdenes confirmadas
-- desincronizadas en prod (medido 2026-09-23). Idempotente y segura en base
-- vacía (sólo CREATE OR REPLACE, REVOKE/GRANT, COMMENT y un DO de lectura).
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- (1) _sales_order_sync_from_operation — la orden refleja su operación
--
-- ÚNICA definición de "total, cliente, sucursal y líneas de una sales_order a
-- partir de las filas de sales de su operación". La usan la promoción (al crear
-- y en el replay) y la edición (al re-apuntar). Dos copias divergirían: es
-- exactamente cómo la edición terminó re-apuntando órdenes con el total viejo.
--
-- Contrato (el caller lo cumple; el helper lo re-verifica fail-closed):
--   · El caller YA tiene tomadas con FOR UPDATE las filas de sales de la
--     operación (orden global sales → sales_orders → fiscal_documents). Acá se
--     toma la orden (no-op si el caller ya la tiene).
--   · Tenencia en el choke point: la orden y TODAS las filas de la operación
--     tienen que ser de p_account_id → si no, P0404.
--   · Nunca recalcula una orden con comprobante VIVO: ALLOW-LIST cerrada (sin
--     comprobante, 'rejected' o 'voided'); cualquier otro estado, incluido uno
--     que no exista hoy o una FK colgada, → P0409 sales_order_has_live_invoice.
--   · Cliente y sucursal tienen que ser HOMOGÉNEOS entre las filas (NULL cuenta
--     como valor) → si no, P0422 operation_inconsistent. Nunca se agrega a
--     ciegas (el MIN(uuid) de la promoción, además de no existir, elegía un
--     cliente arbitrario de una operación mezclada).
--   · Importe canónico = la CABECERA: total = round(Σ sales.total, 2), una línea
--     por fila de sales. De sale_items sólo producto/unidad/snapshots, de UNA
--     fila — la del producto de la fila si existe (hay 23 filas legacy con un
--     sale_item del producto y otro sin producto ni snapshots).
--   · SECURITY INVOKER: sólo corre dentro de RPCs SECURITY DEFINER (rol dueño);
--     cerrado a anon/authenticated (chequeo (3) de test_function_acl_gate.sql).
--   · No escribe stock, caja, cuenta corriente, banco ni outbox.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._sales_order_sync_from_operation(
  p_sales_order_id uuid,
  p_operation_id   uuid,
  p_account_id     uuid
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'public'
AS $function$
DECLARE
  v_order  RECORD;
  v_fd_ok  boolean;
  v_hdr    RECORD;
BEGIN
  IF p_sales_order_id IS NULL OR p_operation_id IS NULL OR p_account_id IS NULL THEN
    RAISE EXCEPTION 'sales_order_sync_invalid_args: la orden, la operación y la cuenta son obligatorias'
      USING ERRCODE = 'P0400';
  END IF;

  SELECT so.id, so.account_id, so.fiscal_document_id
  INTO   v_order
  FROM   public.sales_orders so
  WHERE  so.id = p_sales_order_id
  FOR UPDATE;

  IF NOT FOUND OR v_order.account_id IS DISTINCT FROM p_account_id THEN
    RAISE EXCEPTION 'sales_order_not_found: la orden de venta % no pertenece a la cuenta', p_sales_order_id
      USING ERRCODE = 'P0404';
  END IF;

  IF v_order.fiscal_document_id IS NOT NULL THEN
    SELECT (fd.status IN ('rejected', 'voided'))
    INTO   v_fd_ok
    FROM   public.fiscal_documents fd
    WHERE  fd.id = v_order.fiscal_document_id;

    IF v_fd_ok IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'sales_order_has_live_invoice: la orden % tiene un comprobante vigente — no se recalcula', p_sales_order_id
        USING ERRCODE = 'P0409';
    END IF;
  END IF;

  SELECT count(*)                                                     AS n_rows,
         bool_and(s.account_id IS NOT DISTINCT FROM p_account_id)     AS all_mine,
         count(DISTINCT s.client_id)                                  AS n_clients,
         count(*) FILTER (WHERE s.client_id IS NULL)                  AS n_client_null,
         count(DISTINCT s.branch_id)                                  AS n_branches,
         count(*) FILTER (WHERE s.branch_id IS NULL)                  AS n_branch_null,
         (array_agg(s.client_id ORDER BY s.id))[1]                    AS client_id,
         (array_agg(s.branch_id ORDER BY s.id))[1]                    AS branch_id,
         round(COALESCE(sum(COALESCE(s.total, s.amount * s.quantity)), 0), 2) AS total
  INTO   v_hdr
  FROM   public.sales s
  WHERE  s.operation_id = p_operation_id;

  IF v_hdr.n_rows = 0 THEN
    RAISE EXCEPTION 'operation_empty: la operación % no tiene líneas — no hay nada que facturar', p_operation_id
      USING ERRCODE = 'P0400';
  END IF;

  IF v_hdr.all_mine IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'operation_not_found: operación % no encontrada o ajena', p_operation_id
      USING ERRCODE = 'P0404';
  END IF;

  IF v_hdr.n_clients > 1 OR (v_hdr.n_clients = 1 AND v_hdr.n_client_null > 0) THEN
    RAISE EXCEPTION 'operation_inconsistent: las líneas de la operación % tienen distinto cliente — editá la venta para unificarlo antes de facturar', p_operation_id
      USING ERRCODE = 'P0422';
  END IF;

  IF v_hdr.n_branches > 1 OR (v_hdr.n_branches = 1 AND v_hdr.n_branch_null > 0) THEN
    RAISE EXCEPTION 'operation_inconsistent: las líneas de la operación % tienen distinta sucursal — editá la venta para unificarla antes de facturar', p_operation_id
      USING ERRCODE = 'P0422';
  END IF;

  UPDATE public.sales_orders so
  SET    total     = v_hdr.total,
         client_id = v_hdr.client_id,
         branch_id = COALESCE(v_hdr.branch_id, so.branch_id)
  WHERE  so.id = p_sales_order_id;

  DELETE FROM public.sales_order_items WHERE sales_order_id = p_sales_order_id;

  INSERT INTO public.sales_order_items
    (sales_order_id, account_id, product_id, unit_id, quantity, price, subtotal,
     name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot, snapshot_backfilled)
  SELECT p_sales_order_id,
         p_account_id,
         COALESCE(si.product_id, s.product_id),
         COALESCE(si.unit_id, s.unit_id),
         s.quantity,
         s.amount,
         COALESCE(s.total, s.amount * s.quantity),
         si.name_snapshot,
         si.sku_snapshot,
         si.unit_cost_snapshot,
         si.iva_rate_snapshot,
         COALESCE(si.snapshot_backfilled, false)
  FROM   public.sales s
  LEFT JOIN LATERAL (
    SELECT x.product_id, x.unit_id, x.name_snapshot, x.sku_snapshot,
           x.unit_cost_snapshot, x.iva_rate_snapshot, x.snapshot_backfilled
    FROM   public.sale_items x
    WHERE  x.sale_id = s.id
    -- H2: en prod la fila duplicada trae un sale_item del producto (con
    -- snapshots) y OTRO sin producto ni snapshots. Se prefiere el que coincide
    -- con el producto de la fila; el id sólo desempata.
    ORDER  BY (x.product_id IS NOT DISTINCT FROM s.product_id) DESC,
              (x.product_id IS NULL),
              x.id
    LIMIT  1
  ) si ON true
  WHERE  s.operation_id = p_operation_id
  ORDER  BY s.id;

  RETURN v_hdr.total;
END;
$function$;

REVOKE ALL     ON FUNCTION public._sales_order_sync_from_operation(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._sales_order_sync_from_operation(uuid, uuid, uuid) TO postgres, service_role;

COMMENT ON FUNCTION public._sales_order_sync_from_operation(uuid, uuid, uuid) IS
  'venta-editable-vs-promocion-legacy: recalcula total (round(Σ sales.total, 2)), cliente, sucursal y líneas de una sales_order desde las filas de sales de su operación. Exige que el caller ya tenga esas filas FOR UPDATE (orden sales → sales_orders → fiscal_documents). Fail-closed: P0404 tenencia, P0409 si la orden tiene comprobante vivo, P0422 si las filas no son homogéneas. Helper interno SECURITY INVOKER: nunca expuesto a anon/authenticated.';

-- ─────────────────────────────────────────────────────────────────────────────
-- (2) rpc_promote_legacy_sale_to_order — N2 + N1
--
-- Parte del cuerpo vivo (20261003000001, md5 8c94b2a1…). Cambios:
--   · (1) lock de las filas de la operación ANTES de todo (N1); 0 filas del
--     caller = P0404 — y no se bloquean filas de otra cuenta (el JOIN a
--     account_members filtra antes del FOR UPDATE OF s).
--   · (2) cabecera = primera fila por id (determinístico), sin MIN(uuid) (N2).
--   · (3) idempotencia bajo el lock; en el replay, resync si la orden no tiene
--     comprobante vivo (allow-list: sin comprobante, rejected, voided) — es la
--     salida del usuario ante sales_order_out_of_sync.
--   · (3) la orden del replay es SÓLO la de la cuenta del caller: el índice
--     único de sale_operation_id es global, y con una fila propia inyectada
--     en la operación de otra cuenta el replay devolvía el sales_order_id
--     ajeno (red team 2026-09-24, D3b). Una orden de otra cuenta → P0404,
--     también en el handler de unique_violation.
--   · total, cliente, sucursal, homogeneidad y líneas: el helper único.
-- Intacto: firma, SECURITY DEFINER, search_path, retorno, P0401/P0422
-- no_branch_found, payment_method_id NULL, side-effect-free (D1), ACLs,
-- COMMENT.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_promote_legacy_sale_to_order(p_operation_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid              uuid;
  v_account_id       uuid;
  v_branch_id        uuid;
  v_client_id        uuid;
  v_sales_order_id   uuid;
  v_existing_id      uuid;
  v_existing_fd      uuid;
  v_existing_fd_st   text;
  v_locked           integer;
BEGIN
  -- ── Autenticación ───────────────────────────────────────────────────────────
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_operation_id IS NULL THEN
    RAISE EXCEPTION 'operation_not_found: operación no indicada'
      USING ERRCODE = 'P0404';
  END IF;

  -- ── (1) Exclusión (N1): las filas de sales de la operación, FOR UPDATE, en
  -- orden de id. Es el mismo ancla que toman la edición y el borrado ANTES de
  -- resolver la orden: o esta promoción espera a que ellos terminen (y ve las
  -- filas ya borradas → 0 → P0404), o ellos esperan a que esta termine (y ven
  -- la orden commiteada). Tenencia: sólo filas de cuentas del caller.
  SELECT count(*) INTO v_locked
  FROM (
    SELECT s.id
    FROM   public.sales s
    JOIN   public.account_members am
      ON   am.account_id = s.account_id
     AND   am.user_id    = v_uid
    WHERE  s.operation_id = p_operation_id
    ORDER  BY s.id
    FOR UPDATE OF s
  ) l;

  IF v_locked = 0 THEN
    -- La operación no existe o pertenece a otro usuario/cuenta
    RAISE EXCEPTION 'operation_not_found: operación % no encontrada o ajena', p_operation_id
      USING ERRCODE = 'P0404';
  END IF;

  -- ── (2) Cabecera (N2): primera fila por id. Reemplaza MIN(s.account_id),
  -- MIN(s.branch_id), MIN(s.client_id): min(uuid) no existe (42883) y, aunque
  -- existiera, elegiría un cliente arbitrario de una operación mezclada. La
  -- homogeneidad de TODAS las filas la valida el helper, fail-closed.
  SELECT s.account_id, s.branch_id, s.client_id
  INTO   v_account_id, v_branch_id, v_client_id
  FROM   public.sales s
  JOIN   public.account_members am
    ON   am.account_id = s.account_id
   AND   am.user_id    = v_uid
  WHERE  s.operation_id = p_operation_id
  ORDER  BY s.id
  LIMIT  1;

  -- ── Permiso de escritura ────────────────────────────────────────────────────
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized: sin permiso de escritura sobre la cuenta'
      USING ERRCODE = 'P0401';
  END IF;

  -- ── (3) Idempotencia (D2), ahora bajo el lock de las filas: una promoción
  -- concurrente de la MISMA operación espera arriba y, al pasar, ve acá la
  -- orden commiteada. Replay con resync si la orden no tiene comprobante vivo.
  -- Sólo la orden de ESTA cuenta (D3b): el índice único de sale_operation_id
  -- es global; una orden de otra cuenta para esta operación no se devuelve ni
  -- se toca — el INSERT de abajo choca con ella y el handler responde P0404.
  SELECT so.id, so.fiscal_document_id
  INTO   v_existing_id, v_existing_fd
  FROM   public.sales_orders so
  WHERE  so.sale_operation_id = p_operation_id
    AND  so.account_id        = v_account_id
  FOR UPDATE;

  IF v_existing_id IS NOT NULL THEN
    IF v_existing_fd IS NOT NULL THEN
      SELECT fd.status INTO v_existing_fd_st
      FROM   public.fiscal_documents fd
      WHERE  fd.id = v_existing_fd;
    END IF;

    IF v_existing_fd IS NULL OR v_existing_fd_st IN ('rejected', 'voided') THEN
      PERFORM public._sales_order_sync_from_operation(v_existing_id, p_operation_id, v_account_id);
    END IF;

    RETURN jsonb_build_object(
      'sales_order_id',    v_existing_id,
      'sale_operation_id', p_operation_id,
      'replayed',          true
    );
  END IF;

  -- ── Resolver branch efectiva (D4) ────────────────────────────────────────────
  -- Preferir branch de la venta legacy; sino, default de la cuenta (C-26).
  v_branch_id := COALESCE(v_branch_id, public.c26_default_branch(v_account_id));

  IF v_branch_id IS NULL THEN
    RAISE EXCEPTION 'no_branch_found: la cuenta no tiene sucursal activa'
      USING ERRCODE = 'P0422';
  END IF;

  -- ── INSERT sales_orders (status='confirmed', side-effect-free) ──────────────
  -- limpiezas-pagos-admin (D7): nace sin forma de pago imputada
  -- (payment_method_id NULL): la de una venta cargada a mano es desconocida.
  -- total provisorio 0: lo fija el helper, con las líneas, en esta misma
  -- transacción. El handler de unique_violation: con el lock de (1) una
  -- promoción concurrente de la MISMA cuenta nunca llega acá, pero si un
  -- camino futuro insertara sin el ancla sigue devolviendo la orden existente
  -- en vez de un 500. Lo que SÍ llega acá es la orden de OTRA cuenta para
  -- esta operación (índice único global, D3b): P0404, sin nombrarla.
  BEGIN
    INSERT INTO public.sales_orders
      (account_id, branch_id, client_id, status,
       sale_operation_id, total, fiscal_document_id, created_by)
    VALUES
      (v_account_id, v_branch_id, v_client_id, 'confirmed',
       p_operation_id, 0, NULL, v_uid)
    RETURNING id INTO v_sales_order_id;
  EXCEPTION WHEN unique_violation THEN
    SELECT id INTO v_existing_id
    FROM public.sales_orders
    WHERE sale_operation_id = p_operation_id
      AND account_id        = v_account_id;

    IF v_existing_id IS NULL THEN
      RAISE EXCEPTION 'operation_not_found: operación % no encontrada o ajena', p_operation_id
        USING ERRCODE = 'P0404';
    END IF;

    RETURN jsonb_build_object(
      'sales_order_id',    v_existing_id,
      'sale_operation_id', p_operation_id,
      'replayed',          true
    );
  END;

  -- ── Total, cliente, sucursal y líneas: la ÚNICA definición (helper) ─────────
  PERFORM public._sales_order_sync_from_operation(v_sales_order_id, p_operation_id, v_account_id);

  -- D1: la venta ya ocurrió. Nada de stock, caja, cuenta corriente, banco ni
  -- outbox, y no se invoca la confirmación del POS.

  RETURN jsonb_build_object(
    'sales_order_id',    v_sales_order_id,
    'sale_operation_id', p_operation_id,
    'replayed',          false
  );
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_promote_legacy_sale_to_order(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_promote_legacy_sale_to_order(uuid) TO postgres, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- (3) rpc_atomic_update_sale_operation — lock temprano (N1) + recálculo (N3)
--
-- Cuerpo VIVO de 20261060000001 (md5 a657c54b…) con TRES hunks y nada más:
-- E1 dos variables; E2 el lock ordenado de las filas + recuento, después de
-- los chequeos de existencia/propiedad y ANTES del guard de cliente y del
-- enumerador de órdenes; E3 el re-apuntado con RETURNING + el helper único.
-- Firma IDÉNTICA (anclada literal en el chequeo (5) de test_function_acl_gate).
-- OJO (gates que leen pg_get_functiondef con comentarios): nada antes del guard
-- de cliente puede contener los literales de borrado/inserción que usa
-- test_operacion_party_guard.sql (7-update-orden), y ningún comentario puede
-- nombrar la función de historial con paréntesis (matriz de roles, 5b).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_atomic_update_sale_operation(p_sale_ids uuid[], p_client_id uuid, p_date date, p_currency text, p_items jsonb, p_payment_method_id uuid DEFAULT NULL::uuid, p_payment_method_provided boolean DEFAULT false, p_branch_id uuid DEFAULT NULL::uuid, p_branch_provided boolean DEFAULT false, p_canal text DEFAULT NULL::text, p_canal_provided boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid            uuid;
  v_account_id     uuid;
  v_old_sale       RECORD;
  v_item           RECORD;
  v_product        RECORD;
  v_new_op_id      uuid;
  v_new_sale_id    uuid;
  v_stock_sum      numeric(15,4);
  v_result_items   jsonb := '[]'::jsonb;
  v_flag_on        boolean;
  v_old_snapshots  jsonb;
  v_prev_snap      jsonb;
  v_line_snap      jsonb;
  v_old_product_name text;
  v_reverse_unit_cost numeric;
  v_old_payment_method_id   uuid;  -- metodos-pago-operaciones (D5)
  v_final_payment_method_id uuid;  -- metodos-pago-operaciones (D5)
  -- edicion-preserva-contexto (F1):
  v_old_operation_id uuid;         -- §D9: para re-apuntar sales_orders
  v_old_branch_id    uuid;         -- §D1/§D3
  v_old_canal        text;         -- §D1/§D3
  v_final_branch_id  uuid;         -- §D3/§D8: sucursal EFECTIVA (reimputada o vieja)
  v_final_canal      text;         -- §D3
  v_canal_clean      text;
  v_branch           RECORD;
  -- asiento-venta-formulario (D7, override del PO): ajustar el rastro
  -- contable de la operación editada en vez de bloquear la edición.
  v_total_sum          numeric(15,2) := 0;
  v_kind_final          text;
  v_pending_event_id    uuid;
  v_pending_event_type  text;
  v_pending_payload     jsonb;
  v_has_posted_entry    boolean := false;
  -- venta-editable-sin-cae: la anulación del comprobante pendiente NO enviado.
  v_void_rec            RECORD;   -- (sales_order_id, operation_id) a anular
  v_voided_doc          jsonb;    -- descriptor del último comprobante anulado
  -- venta-editable-vs-promocion-legacy (20261061000001):
  v_locked              integer;  -- filas de la operación tomadas con FOR UPDATE
  v_resync_id           uuid;     -- orden re-apuntada que se recalcula (N3)
BEGIN
  -- Identity always comes from the JWT — never from caller input
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- ── Account scoping (C-05 D7) ────────────────────────────────────────────
  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede actualizar la operación'
      USING ERRCODE = 'P0403';
  END IF;

  IF array_length(p_sale_ids, 1) IS NULL OR array_length(p_sale_ids, 1) = 0 THEN
    RAISE EXCEPTION 'No sale IDs provided' USING ERRCODE = 'P0400';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.sales
    WHERE id = ANY(p_sale_ids) AND user_id != v_uid
  ) THEN
    RAISE EXCEPTION 'Permission denied: sale belongs to another user' USING ERRCODE = 'P0403';
  END IF;

  IF (SELECT COUNT(*) FROM public.sales WHERE id = ANY(p_sale_ids))
      != array_length(p_sale_ids, 1)
  THEN
    RAISE EXCEPTION 'One or more sale IDs not found' USING ERRCODE = 'P0404';
  END IF;

  -- venta-editable-vs-promocion-legacy (N1): EXCLUSIÓN contra la promoción.
  -- Las filas de sales de la operación son lo único que existe ANTES que la
  -- orden, así que son el ancla común: la promoción, la edición y el borrado
  -- las toman PRIMERO, con FOR UPDATE y en orden ascendente de id. Orden
  -- global de locks: sales → sales_orders → fiscal_documents → resto.
  -- Sin este lock, el enumerador de órdenes de más abajo leía SIN lock, no
  -- veía la orden que una promoción concurrente estaba creando, y la venta
  -- quedaba editada con un comprobante pendiente VIVO por importes viejos.
  -- Recuento bajo el lock: si otra edición o un borrado ganó y se llevó
  -- alguna fila mientras se esperaba, se aborta acá, antes de revertir stock
  -- o de tocar cualquier libro (doble "Guardar" incluido).
  SELECT count(*) INTO v_locked
  FROM (
    SELECT s.id
    FROM   public.sales s
    WHERE  s.id = ANY(p_sale_ids)
      AND  s.user_id = v_uid
    ORDER  BY s.id
    FOR UPDATE
  ) l;

  IF v_locked <> array_length(p_sale_ids, 1) THEN
    RAISE EXCEPTION 'One or more sale IDs not found' USING ERRCODE = 'P0404';
  END IF;

  -- operacion-party-guard (fix ad-hoc 2026-09-10, cierra OQ-4 de
  -- cuenta-corriente-party-guard): la edición también puede reasignar el
  -- client_id de la operación (p_client_id es obligatorio, sin contrato
  -- tri-estado _provided — el llamador siempre lo reenvía) y hoy lo
  -- escribe sin validar tenencia, igual que rpc_create_sale_operation_v2
  -- antes de este fix. Mismo predicado, mismo ERRCODE, ANTES de cualquier
  -- guard de inmutabilidad/reversa.
  IF p_client_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.clients
      WHERE id = p_client_id AND account_id = v_account_id
    ) THEN
      RAISE EXCEPTION 'client_not_found: %', p_client_id USING ERRCODE = 'P0404';
    END IF;
  END IF;

  -- edicion-preserva-contexto (F2, design §D5) + venta-editable-sin-cae (D2):
  -- guard fiscal — SHALL correr antes de cualquier reversa/eliminación/
  -- reaplicación, de modo que una operación bloqueada quede intacta si el
  -- guard dispara. Resuelto por JOIN (sales.operation_id →
  -- sales_orders.sale_operation_id → sales_orders.fiscal_document_id →
  -- fiscal_documents), nunca por una columna denormalizada de "facturado"
  -- (segunda fuente de verdad).
  --
  -- venta-editable-sin-cae: el predicado deja de ser "¿HAY comprobante?" y
  -- pasa a ser "¿el comprobante YA SALIÓ hacia ARCA?". Un pending_cae SIN
  -- marca de envío ya no bloquea: se ANULA (voided) en ESTA MISMA
  -- transacción, para que el relay no lo facture después con los importes
  -- viejos. authorized, marcado y congelado siguen bloqueando con P0423
  -- (tres tokens distintos — ver _fiscal_void_pending_for_sale_edit, que es
  -- la ÚNICA definición de esta regla y la comparte con el borrado).
  -- rejected y voided no bloquean ni se tocan.
  -- asiento-venta-formulario: el guard fiscal sigue siendo el PRIMERO.
  --
  -- Esta query NO filtra por `so.fiscal_document_id IS NOT NULL` (red team
  -- 2026-09-22, M1): ese filtro se evalúa SIN lock, así que con una emisión
  -- abierta en otra conexión devolvía cero filas, el helper no se llamaba
  -- NUNCA, y la venta se editaba dejando vivo el comprobante que la emisión
  -- estaba por commitear. Quién decide "hay comprobante" es el helper, con la
  -- fila de la orden BLOQUEADA. Acá sólo se enumeran las órdenes de la
  -- operación (a lo sumo una: sale_operation_id tiene índice único parcial).
  FOR v_void_rec IN
    SELECT DISTINCT so.id AS sales_order_id, s.operation_id AS operation_id
    FROM   public.sales s
    JOIN   public.sales_orders so ON so.sale_operation_id = s.operation_id
    WHERE  s.id = ANY(p_sale_ids)
  LOOP
    v_voided_doc := public._fiscal_void_pending_for_sale_edit(
      v_void_rec.sales_order_id, v_account_id, v_uid,
      format('Anulado por edición de la venta (operación %s)', v_void_rec.operation_id)
    );
  END LOOP;

  -- pagos-cableados-restantes (D6): inmutabilidad de operaciones con cargo
  -- de cuenta corriente o movimiento de caja posteado. Bloquea la operación
  -- ENTERA (no sólo monto/método — editar la fecha desplazaría la
  -- atribución temporal del movimiento). reference_id de ambas tablas puede
  -- apuntar a sales_orders.id (camino POS, vía _pay_register_party_charge /
  -- c28_register_cash_movement dentro de _c29_confirm_order_core, p_reference_id
  -- = p_sales_order_id) o directamente a sales.operation_id (camino
  -- formulario, rpc_create_sale_operation_v2) — se cubren ambos.
  -- asiento-venta-formulario: guards de cuenta corriente/caja/banco SIN CAMBIOS.
  IF EXISTS (
    SELECT 1
    FROM public.customer_account_movements cam
    WHERE cam.reference_id IN (
      SELECT s.operation_id FROM public.sales s WHERE s.id = ANY(p_sale_ids)
      UNION
      SELECT so.id FROM public.sales_orders so
      JOIN public.sales s ON s.operation_id = so.sale_operation_id
      WHERE s.id = ANY(p_sale_ids)
    )
  ) THEN
    RAISE EXCEPTION 'operation_has_account_charge_immutable: la operación tiene un cargo de cuenta corriente posteado y no puede editarse — emití una nota de crédito y registrá una venta nueva'
      USING ERRCODE = 'P0423';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.cash_movements cm
    WHERE cm.reference_id IN (
      SELECT s.operation_id FROM public.sales s WHERE s.id = ANY(p_sale_ids)
      UNION
      SELECT so.id FROM public.sales_orders so
      JOIN public.sales s ON s.operation_id = so.sale_operation_id
      WHERE s.id = ANY(p_sale_ids)
    )
  ) THEN
    RAISE EXCEPTION 'operation_has_cash_movement_immutable: la operación tiene un movimiento de caja posteado y no puede editarse — emití una nota de crédito y registrá una venta nueva'
      USING ERRCODE = 'P0423';
  END IF;

  -- pos-banco-movimientos (D8, task 6.1): tercer EXISTS — bank_movements
  -- entra al mismo bloqueo P0423, misma doble referencia. El ledger
  -- bancario es append-only (C1) y el movimiento puede estar ya `matched`
  -- dentro de una sesión de conciliación cerrada: editarlo destruiría una
  -- conciliación firmada.
  IF EXISTS (
    SELECT 1
    FROM public.bank_movements bm
    WHERE bm.source_doc_type = 'sale'
      AND bm.source_doc_ref IN (
        SELECT s.operation_id FROM public.sales s WHERE s.id = ANY(p_sale_ids)
        UNION
        SELECT so.id FROM public.sales_orders so
        JOIN public.sales s ON s.operation_id = so.sale_operation_id
        WHERE s.id = ANY(p_sale_ids)
      )
  ) THEN
    RAISE EXCEPTION 'operation_has_bank_movement_immutable: la operación tiene un movimiento bancario posteado y no puede editarse — registrá el ajuste en el ledger bancario y una venta nueva'
      USING ERRCODE = 'P0423';
  END IF;

  -- edicion-operaciones-lineas (D3): mismo flag_key y mismo patrón
  -- COALESCE-después-del-SELECT que rpc_create_sale_operation — ausencia de
  -- fila = v2 (escribe línea).
  SELECT enabled INTO v_flag_on
  FROM   public.account_feature_flags
  WHERE  account_id = v_account_id
    AND  flag_key   = 'sale_items_rpc_v2'
  LIMIT  1;
  v_flag_on := COALESCE(v_flag_on, true);

  -- edicion-operaciones-lineas (D2): acarreo de snapshot keyed por
  -- product_id, capturado ANTES del DELETE — el CASCADE se lleva puesto
  -- sale_items en STEP 2. DISTINCT ON (product_id) ORDER BY product_id, id:
  -- determinístico ante colisión (dos filas viejas de header con el mismo
  -- producto — la forma legacy 1-operación:N-filas, 23 ventas en prod).
  SELECT COALESCE(jsonb_object_agg(t.product_id::text, t.snap), '{}'::jsonb)
  INTO   v_old_snapshots
  FROM (
    SELECT DISTINCT ON (si.product_id)
           si.product_id,
           jsonb_build_object(
             'name_snapshot',       si.name_snapshot,
             'sku_snapshot',        si.sku_snapshot,
             'unit_cost_snapshot',  si.unit_cost_snapshot,
             'iva_rate_snapshot',   si.iva_rate_snapshot,
             'snapshot_backfilled', si.snapshot_backfilled
           ) AS snap
    FROM   public.sale_items si
    WHERE  si.sale_id = ANY(p_sale_ids)
      AND  si.product_id IS NOT NULL
    ORDER BY si.product_id, si.id
  ) t;

  -- metodos-pago-operaciones (D5): capturar el payment_method_id vigente de
  -- la operación ANTES del DELETE — mismo momento que v_old_snapshots. Por
  -- operación (D3): cualquier fila alcanza (todas comparten el valor).
  SELECT payment_method_id INTO v_old_payment_method_id
  FROM   public.sales
  WHERE  id = ANY(p_sale_ids)
  LIMIT  1;

  IF p_payment_method_provided THEN
    IF p_payment_method_id IS NOT NULL THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.payment_methods
        WHERE id = p_payment_method_id AND account_id = v_account_id
          AND is_active = TRUE AND deleted_at IS NULL
      ) THEN
        RAISE EXCEPTION 'payment_method_not_found or not active for this account'
          USING ERRCODE = 'P0404';
      END IF;
    END IF;
    v_final_payment_method_id := p_payment_method_id;
  ELSE
    v_final_payment_method_id := v_old_payment_method_id;
  END IF;

  -- edicion-preserva-contexto (F1, design §D1): capturar el contexto vigente
  -- del header ANTES del DELETE, junto al resto de lo que se acarrea.
  -- LIMIT 1 es correcto: branch_id/canal/operation_id son de la operación,
  -- no de la línea — todas las filas del mismo operation_id los comparten
  -- (misma justificación que payment_method_id, D3 de #419).
  SELECT operation_id, branch_id, canal
  INTO   v_old_operation_id, v_old_branch_id, v_old_canal
  FROM   public.sales
  WHERE  id = ANY(p_sale_ids)
  LIMIT  1;

  -- asiento-venta-formulario (D7, override del PO): resolver el rastro
  -- contable de v_old_operation_id ANTES del REVERSE/DELETE — no se
  -- rechaza la edición, se ajusta el rastro más abajo. Caso B: se toma el
  -- lock ACÁ, sobre el evento pendiente (SaleOperationCreated apuntando a
  -- esta operación, o SaleOperationAdjusted cuyo new_operation_id es esta
  -- operación), para no competir con el dispatcher a mitad de camino. Bajo
  -- READ COMMITTED, SELECT ... FOR UPDATE re-evalúa el WHERE contra la
  -- versión más reciente de la fila al tomar el lock: si el dispatcher ya
  -- la marcó processed_at mientras se esperaba el lock, Postgres la excluye
  -- automáticamente del resultado — no hace falta un re-chequeo manual.
  IF v_old_operation_id IS NOT NULL THEN
    SELECT id, event_type, payload
    INTO   v_pending_event_id, v_pending_event_type, v_pending_payload
    FROM   public.events
    WHERE  processed_at IS NULL
      AND  (
             (event_type = 'SaleOperationCreated' AND aggregate_id = v_old_operation_id)
          OR (event_type = 'SaleOperationAdjusted' AND (payload->>'new_operation_id')::uuid = v_old_operation_id)
           )
    ORDER BY occurred_at
    LIMIT 1
    FOR UPDATE;

    -- Caso C: sin evento pendiente reemplazable — ¿hay un asiento ya posteado?
    IF v_pending_event_id IS NULL THEN
      SELECT EXISTS (
        SELECT 1 FROM public.journal_entries
        WHERE source_doc_type = 'SaleOperation'
          AND source_doc_ref  = v_old_operation_id
          AND status = 'posted'
      ) INTO v_has_posted_entry;
    END IF;
  END IF;

  -- edicion-preserva-contexto (F1, design §D3): tri-estado para branch_id —
  -- espejo exacto del contrato de payment_method_id. provided=false →
  -- preservar; provided=true + NULL → desimputar; provided=true + valor →
  -- reimputar, previa validación de pertenencia a la cuenta y sucursal
  -- operativa (mismo guard que rpc_create_sale_operation_v2, C-26). La
  -- validación corre ACÁ, antes del REVERSE (gate 2.9: una reimputación
  -- inválida no debe revertir ni reaplicar stock).
  IF p_branch_provided THEN
    IF p_branch_id IS NOT NULL THEN
      SELECT id, status INTO v_branch
      FROM   public.branches
      WHERE  id = p_branch_id AND account_id = v_account_id AND is_active = TRUE;
      IF NOT FOUND OR v_branch.status = 'closed' THEN
        RAISE EXCEPTION 'branch_invalid: la sucursal no pertenece a la cuenta o no está operativa'
          USING ERRCODE = 'P0422';
      END IF;
    END IF;
    v_final_branch_id := p_branch_id;
  ELSE
    v_final_branch_id := v_old_branch_id;
  END IF;

  -- edicion-preserva-contexto (F1, design §D3): tri-estado para canal —
  -- mismo contrato. Sin conjunto cerrado en el schema (sales.canal es texto
  -- libre, sin CHECK) — se valida longitud igual que rpc_create_sale_operation_v2.
  IF p_canal_provided THEN
    v_canal_clean := NULLIF(trim(COALESCE(p_canal, '')), '');
    IF v_canal_clean IS NOT NULL AND length(v_canal_clean) > 40 THEN
      RAISE EXCEPTION 'canal too long (max 40 chars)' USING ERRCODE = 'P0400';
    END IF;
    v_final_canal := v_canal_clean;
  ELSE
    v_final_canal := v_old_canal;
  END IF;

  -- ── STEP 1: REVERSE ─────────────────────────────────────────────────────────
  -- stock-movements-edicion: id/operation_id agregados al SELECT — id vieja
  -- es el reference_id de la pata REVERSE, operation_id agrupa el movimiento
  -- bajo la operación a la que pertenecía la fila que se está reemplazando.
  -- La pata REVERSE sigue devolviendo a la sucursal VIEJA de cada fila
  -- (v_old_sale.branch_id) — no cambia con F1 (§D8: REVERSE = sucursal vieja).
  FOR v_old_sale IN
    SELECT id, product_id, quantity, branch_id, operation_id
    FROM public.sales
    WHERE id = ANY(p_sale_ids)
  LOOP
    IF v_old_sale.product_id IS NOT NULL THEN
      -- Nombre actual del producto para el movimiento (congelar el nombre no
      -- es el contrato de este movimiento — el name_snapshot vive en la
      -- línea, no acá — se usa el mismo patrón que la creación: products.name
      -- vigente al momento de la operación).
      SELECT name INTO v_old_product_name FROM public.products WHERE id = v_old_sale.product_id;

      -- design §D5 (stock-movements-edicion): la pata REVERSE copia el
      -- unit_cost_snapshot del movimiento ORIGINAL si existe; si no, NULL.
      SELECT unit_cost_snapshot INTO v_reverse_unit_cost
      FROM   public.stock_movements
      WHERE  reference_id = v_old_sale.id AND reference_type = 'sale'
      ORDER  BY created_at DESC
      LIMIT  1;

      -- C-21 checkpoint #2: devolver a la branch original de la venta (o default).
      -- stock-movements-edicion (D2/D3): op_stock_movement aplica el delta
      -- (misma aritmética que antes) Y emite el movimiento espejo REVERSE:
      -- type='sale_return', reference_id=id VIEJO, reference_type='sale_update'.
      PERFORM public.op_stock_movement(
        v_account_id, v_uid, v_old_sale.product_id, v_old_product_name,
        v_old_sale.branch_id, v_old_sale.quantity, 'sale_return',
        v_old_sale.id, 'sale_update', v_old_sale.operation_id,
        v_reverse_unit_cost, 'Reversa por edición de operación', NULL
      );
    END IF;
  END LOOP;

  -- ── STEP 2: DELETE ──────────────────────────────────────────────────────────
  -- sale_items.sale_id tiene FK ON DELETE CASCADE: este DELETE es lo que
  -- borraba la línea sin recrearla (el hallazgo de edicion-operaciones-lineas).
  -- El acarreo de arriba ya capturó lo necesario antes de perderlo.
  DELETE FROM public.sales WHERE id = ANY(p_sale_ids);

  -- ── STEP 3: APPLY NEW ITEMS ─────────────────────────────────────────────────
  v_new_op_id := gen_random_uuid();

  -- edicion-preserva-contexto (F3, design §D7): quantity pasa de integer a
  -- numeric — único eslabón entero de una cadena que ya es numeric(15,4) de
  -- punta a punta. unit_id se suma al recordset (igual forma que la
  -- creación) para escribirlo real en vez de NULL explícito (§D7 último
  -- párrafo).
  FOR v_item IN
    SELECT *
    FROM jsonb_to_recordset(p_items)
      AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)
  LOOP
    IF v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P0400';
    END IF;

    -- asiento-venta-formulario: acumular el total nuevo (mismo patrón que
    -- rpc_create_sale_operation_v2) para el ajuste contable de más abajo.
    v_total_sum := v_total_sum + (v_item.amount * v_item.quantity);

    IF v_item.product_id IS NOT NULL THEN
      -- C-21 checkpoint #2: FOR UPDATE = mutex por producto (sin leer stock).
      -- edicion-operaciones-lineas: se agrega name/sku/cost a la misma
      -- lectura para resolver el snapshot fresco sin una consulta extra.
      SELECT id, user_id, is_variant, name, sku, cost INTO v_product
      FROM public.products
      WHERE id = v_item.product_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P0404';
      END IF;

      IF v_product.user_id != v_uid THEN
        RAISE EXCEPTION 'Permission denied to product: %', v_item.product_id USING ERRCODE = 'P0403';
      END IF;

      IF NOT v_product.is_variant THEN
        IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
          RAISE EXCEPTION 'Este producto tiene variantes. Seleccioná una variante específica para registrar la venta.'
            USING ERRCODE = 'P0422';
        END IF;
      END IF;

      -- C-21 checkpoint #2: gate global de stock = Σ branch_stock
      SELECT COALESCE(SUM(quantity), 0) INTO v_stock_sum
      FROM   public.branch_stock
      WHERE  product_id = v_item.product_id;

      IF v_stock_sum < v_item.quantity THEN
        RAISE EXCEPTION 'Insufficient stock for product %', v_item.product_id USING ERRCODE = 'P0409';
      END IF;

      -- account_id sealed from caller's resolved account (C-05 D7).
      -- metodos-pago-operaciones: payment_method_id = v_final_payment_method_id (D5).
      -- edicion-preserva-contexto: branch_id/canal = v_final_* (F1 §D3),
      -- unit_id = v_item.unit_id (F1 §D7, viaja con la línea).
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity, unit_id, total, currency, date, operation_id, branch_id, canal, payment_method_id)
      VALUES
        (v_uid, v_account_id, p_client_id, v_item.product_id,
         v_item.amount, v_item.quantity, v_item.unit_id, v_item.amount * v_item.quantity,
         p_currency, p_date, v_new_op_id, v_final_branch_id, v_final_canal, v_final_payment_method_id)
      RETURNING id INTO v_new_sale_id;

      -- edicion-operaciones-lineas (D2/D4): la línea sigue al header.
      -- product_id presente en el mapa viejo → acarrea (una corrección de
      -- cantidad/precio no re-precifica); ausente → snapshot fresco
      -- (producto nuevo, ítem agregado, u operación que nunca tuvo línea).
      -- stock-movements-edicion: v_line_snap se calcula SIEMPRE (antes vivía
      -- adentro del IF v_flag_on) porque el movimiento de stock lo necesita
      -- exista o no la línea — el kill-switch apaga sale_items, no el ledger.
      v_prev_snap := v_old_snapshots -> v_item.product_id::text;
      v_line_snap := public.op_line_snapshot(v_prev_snap, v_product.name, v_product.sku, v_product.cost);

      IF v_flag_on THEN
        -- edicion-preserva-contexto: unit_id = v_item.unit_id en vez de NULL
        -- explícito (F1 §D7 último párrafo).
        INSERT INTO public.sale_items (
          sale_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
          name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot, snapshot_backfilled
        ) VALUES (
          v_new_sale_id, v_item.product_id, v_account_id, NULL,
          v_item.quantity, v_item.unit_id, v_item.amount, v_item.amount * v_item.quantity,
          v_line_snap->>'name_snapshot',
          v_line_snap->>'sku_snapshot',
          (v_line_snap->>'unit_cost_snapshot')::numeric,
          (v_line_snap->>'iva_rate_snapshot')::numeric,
          COALESCE((v_line_snap->>'snapshot_backfilled')::boolean, false)
        );
      END IF;

      -- C-21 checkpoint #2: single-write branch_stock.
      -- stock-movements-edicion (D2/D3/D5): pata APPLY — type='sale',
      -- reference_id=id NUEVO, reference_type='sale' (indistinguible de la
      -- creación — el contrato del que depende la reversa al eliminar).
      -- unit_cost_snapshot reusa v_line_snap, la misma decisión de acarreo
      -- que la línea (sin re-valuar al costo actual).
      -- edicion-preserva-contexto (F1 §D8): la sucursal pasa a ser
      -- v_final_branch_id (la efectiva) en vez de NULL — editar deja de
      -- mudar stock a la sucursal default.
      PERFORM public.op_stock_movement(
        v_account_id, v_uid, v_item.product_id, v_product.name,
        v_final_branch_id, -v_item.quantity, 'sale', v_new_sale_id, 'sale',
        v_new_op_id, (v_line_snap->>'unit_cost_snapshot')::numeric,
        'Aplicación por edición de operación', NULL
      );

    ELSE
      -- account_id sealed from caller's resolved account (C-05 D7).
      -- metodos-pago-operaciones: payment_method_id = v_final_payment_method_id (D5).
      -- edicion-preserva-contexto: branch_id/canal/unit_id preservados/reimputados igual.
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity, unit_id, total, currency, date, operation_id, branch_id, canal, payment_method_id)
      VALUES
        (v_uid, v_account_id, p_client_id, NULL,
         v_item.amount, v_item.quantity, v_item.unit_id, v_item.amount * v_item.quantity,
         p_currency, p_date, v_new_op_id, v_final_branch_id, v_final_canal, v_final_payment_method_id)
      RETURNING id INTO v_new_sale_id;
    END IF;

    v_result_items := v_result_items
      || jsonb_build_object('id', v_new_sale_id, 'product_id', v_item.product_id);
  END LOOP;

  -- edicion-preserva-contexto (F1, design §D9): la orden promovida SIN
  -- comprobante "real" se re-apunta al operation_id nuevo, en la misma
  -- transacción — cierra en su causa raíz la OQ-C de edicion-operaciones-
  -- lineas (3 órdenes colgadas en prod hoy, no reconstruibles
  -- retroactivamente: nada registró antes el mapeo operation_id viejo→nuevo
  -- de esas ediciones — ver design §D10).
  --
  -- "no tiene comprobante fiscal asociado" usa la MISMA definición que el
  -- guard F2 de arriba (§D5): fiscal_document_id NULL, o apuntando a un
  -- comprobante 'rejected' (nunca existió fiscalmente) — no solo NULL a
  -- secas. Sin este matiz, una orden cuyo único comprobante quedó rejected
  -- SÍ pasa el guard F2 (rejected no bloquea, D5) y SÍ se edita, pero
  -- fiscal_document_id sigue NOT NULL apuntando al doc rejected → un
  -- `WHERE fiscal_document_id IS NULL` a secas la deja huérfana (gate 2.8,
  -- descubierto en RED contra esta migración: no era redundante con F2, F2
  -- ya deja pasar exactamente este caso).
  --
  -- venta-editable-vs-promocion-legacy (N3): la orden re-apuntada SIGUE a la
  -- operación también en importes. Re-apuntar sólo sale_operation_id dejaba
  -- total, cliente y líneas VIEJOS: la re-facturación después de anular (D5
  -- de venta-editable-sin-cae) y el "Facturar" de una venta del POS editada
  -- emitían por el importe anterior. El recálculo vive en UN solo lugar,
  -- compartido con la promoción: _sales_order_sync_from_operation. El
  -- predicado del re-apuntado no cambia; el helper de anulación ya corrió
  -- arriba, así que acá sólo llegan órdenes sin comprobante o con uno
  -- rechazado/anulado (a lo sumo una: índice único parcial).
  UPDATE public.sales_orders so
  SET    sale_operation_id = v_new_op_id
  WHERE  so.sale_operation_id = v_old_operation_id
    AND  NOT EXISTS (
      SELECT 1 FROM public.fiscal_documents fd
      WHERE fd.id = so.fiscal_document_id
        AND fd.status IN ('pending_cae', 'authorized')
    )
  RETURNING so.id INTO v_resync_id;

  IF v_resync_id IS NOT NULL THEN
    PERFORM public._sales_order_sync_from_operation(v_resync_id, v_new_op_id, v_account_id);
  END IF;

  -- asiento-venta-formulario (D7, override del PO): ajustar el rastro
  -- contable AHORA que v_new_op_id/v_total_sum/v_final_payment_method_id
  -- son finales. v_pending_event_id / v_has_posted_entry ya fueron
  -- resueltos ANTES del REVERSE/DELETE (con el lock tomado en el momento
  -- correcto) — acá sólo se actúa sobre lo ya resuelto.
  IF v_final_payment_method_id IS NOT NULL THEN
    SELECT kind INTO v_kind_final
    FROM public.payment_methods
    WHERE id = v_final_payment_method_id;
  ELSE
    v_kind_final := NULL;
  END IF;

  IF v_pending_event_id IS NOT NULL THEN
    -- Caso B (D7): reemplazar el evento pendiente EN EL LUGAR — el
    -- dispatcher, cuando lo procese, genera un solo asiento final,
    -- correcto, referenciando v_new_op_id. No se emite un segundo evento.
    IF v_pending_event_type = 'SaleOperationCreated' THEN
      UPDATE public.events
      SET    aggregate_id = v_new_op_id,
             payload = jsonb_build_object(
               'account_id',     v_account_id,
               'operation_id',   v_new_op_id,
               'total',          v_total_sum,
               'payment_method', v_kind_final,
               'client_id',      p_client_id,
               'sale_date',      p_date,
               'occurred_at',    now()
             )
      WHERE  id = v_pending_event_id;
    ELSE
      -- 'SaleOperationAdjusted' todavía pendiente (edición encadenada antes
      -- de que el relay procese la anterior): se actualiza el destino
      -- (new_operation_id) y los valores nuevos, pero se PRESERVA
      -- old_operation_id — la referencia al asiento a revertir no cambia,
      -- sigue siendo el mismo asiento original, todavía no tocado. Esto
      -- colapsa N ediciones-antes-de-procesar en un solo evento final.
      UPDATE public.events
      SET    aggregate_id = v_new_op_id,
             payload = v_pending_payload
                        || jsonb_build_object(
                             'new_operation_id', v_new_op_id,
                             'total',            v_total_sum,
                             'payment_method',   v_kind_final,
                             'client_id',        p_client_id,
                             'sale_date',        p_date,
                             'occurred_at',      now()
                           )
      WHERE  id = v_pending_event_id;
    END IF;
  ELSIF v_has_posted_entry THEN
    -- Caso C (D7): el asiento ya fue posteado — emitir el evento de
    -- ajuste. INSERT plano, SIN bloque EXCEPTION (D6): swallowear el
    -- fallo reproduciría en silencio el bug que este change arregla.
    INSERT INTO public.events
      (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES (
      v_account_id, 'SaleOperationAdjusted', 'SaleOperation', v_new_op_id,
      jsonb_build_object(
        'old_operation_id', v_old_operation_id,
        'new_operation_id', v_new_op_id,
        'account_id',       v_account_id,
        'total',            v_total_sum,
        'payment_method',   v_kind_final,
        'client_id',        p_client_id,
        'sale_date',        p_date,
        'occurred_at',      now()
      ),
      now()
    );
  END IF;
  -- Caso A (D7): ni v_pending_event_id ni v_has_posted_entry — no-op contable
  -- (operación anterior al productor, o que nunca tuvo evento).

  -- venta-editable-sin-cae: el descriptor del comprobante anulado viaja en la
  -- respuesta para que el toast diga "se anuló el comprobante 0003-00000005"
  -- con lo que dice el SERVIDOR, nunca con lo que el cliente creía.
  RETURN jsonb_build_object('operation_id', v_new_op_id, 'items', v_result_items,
                            'voided_fiscal_document', v_voided_doc);
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean, uuid, boolean, text, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean, uuid, boolean, text, boolean) TO postgres, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- (4) rpc_delete_sale_operation — lock temprano (N1)
--
-- Cuerpo VIVO de 20261060000001 (md5 c287c1b4…) con UN hunk: D1, el lock
-- ordenado de las filas (que además recalcula el conjunto bajo el lock)
-- ANTES de resolver la sales_order. Firma y retorno boolean IDÉNTICOS.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_delete_sale_operation(
  p_sale_id      uuid DEFAULT NULL,
  p_operation_id uuid DEFAULT NULL,
  p_reason       text DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid                  uuid;
  v_account_id           uuid;
  v_operation_key        uuid;
  v_sale_ids             uuid[];
  v_sales_order_id       uuid;
  v_so_status             text;
  v_reference_ids        uuid[];
  v_row                  RECORD;
  v_customer_account_id  uuid;
  v_charge_amount        numeric(15,2);
  v_cash_session_id      uuid;
  v_cash_amount          numeric(12,2);
  v_cashbox_id           uuid;
  v_open_session_id      uuid;
  v_bank_row             RECORD;
  v_reversed_type        text;
  v_voided_doc           jsonb;   -- venta-editable-sin-cae
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  IF p_sale_id IS NULL AND p_operation_id IS NULL THEN
    RAISE EXCEPTION 'rpc_delete_sale_operation: se requiere p_sale_id o p_operation_id'
      USING ERRCODE = 'P0400';
  END IF;

  -- ── Resolver el conjunto de filas + la clave de operación (D2) ───────────
  IF p_operation_id IS NOT NULL THEN
    v_operation_key := p_operation_id;
    SELECT array_agg(id) INTO v_sale_ids
    FROM public.sales
    WHERE operation_id = p_operation_id AND account_id = v_account_id;
  ELSE
    SELECT operation_id INTO v_operation_key
    FROM public.sales
    WHERE id = p_sale_id AND account_id = v_account_id;

    IF NOT FOUND THEN
      RETURN false;
    END IF;

    IF v_operation_key IS NOT NULL THEN
      SELECT array_agg(id) INTO v_sale_ids
      FROM public.sales
      WHERE operation_id = v_operation_key AND account_id = v_account_id;
    ELSE
      -- Legacy: sin operation_id — la fila es su propia operación.
      v_operation_key := p_sale_id;
      v_sale_ids := ARRAY[p_sale_id];
    END IF;
  END IF;

  IF v_sale_ids IS NULL OR array_length(v_sale_ids, 1) IS NULL THEN
    RETURN false;
  END IF;

  -- venta-editable-vs-promocion-legacy (N1): EXCLUSIÓN contra la promoción,
  -- mismo ancla y mismo orden que la edición (sales → sales_orders →
  -- fiscal_documents). Las filas se toman ANTES de resolver la orden: si una
  -- promoción las tiene, se espera a que commitee y la orden que creó se ve
  -- (y se cancela) más abajo; si otra edición o borrado ganó, el conjunto
  -- se recalcula bajo el lock y, vacío, no hay nada que borrar.
  SELECT array_agg(l.id ORDER BY l.id) INTO v_sale_ids
  FROM (
    SELECT s.id
    FROM   public.sales s
    WHERE  s.id = ANY(v_sale_ids)
      AND  s.account_id = v_account_id
    ORDER  BY s.id
    FOR UPDATE
  ) l;

  IF v_sale_ids IS NULL OR array_length(v_sale_ids, 1) IS NULL THEN
    RETURN false;
  END IF;

  -- sales_order asociada (camino POS) — misma convención que el guard P0423.
  SELECT id, status INTO v_sales_order_id, v_so_status
  FROM public.sales_orders
  WHERE sale_operation_id = v_operation_key;

  v_reference_ids := ARRAY[v_operation_key];
  IF v_sales_order_id IS NOT NULL THEN
    v_reference_ids := v_reference_ids || v_sales_order_id;
  END IF;

  -- ── Guard fiscal (P0423) — MISMO helper que rpc_atomic_update_sale_operation ──
  -- venta-editable-sin-cae (D2): un comprobante pendiente que NO salió hacia
  -- ARCA se ANULA acá mismo (misma transacción que el borrado), para que el
  -- relay no lo facture después. authorized, marcado y congelado siguen
  -- bloqueando con P0423. Sigue siendo el PRIMER guard, antes de compensar
  -- cuenta corriente (P0425), caja (P0426), banco y de revertir stock — si
  -- levanta, no se tocó ningún libro.
  -- Una sola definición de la regla, compartida con la edición: dos copias
  -- divergirían y una de las dos terminaría anulando un comprobante enviado.
  v_voided_doc := public._fiscal_void_pending_for_sale_edit(
    v_sales_order_id, v_account_id, v_uid,
    format('Anulado por borrado de la venta (operación %s)', v_operation_key)
  );

  -- ── Cuenta corriente de cliente: reversión del cargo (credit_note, P0425 si negativo) ──
  SELECT customer_account_id, SUM(amount)
  INTO v_customer_account_id, v_charge_amount
  FROM public.customer_account_movements
  WHERE reference_id = ANY(v_reference_ids) AND movement_type = 'sale'
  GROUP BY customer_account_id;

  IF v_customer_account_id IS NOT NULL AND v_charge_amount > 0 THEN
    PERFORM public._pay_reverse_party_charge(
      v_account_id, 'customer', v_customer_account_id, v_charge_amount,
      v_operation_key, v_operation_key
    );
  END IF;

  -- ── Caja: contra-movimiento en la sesión abierta actual (P0426 si no hay) ─
  SELECT cs.cashbox_id, v_sum.total
  INTO v_cashbox_id, v_cash_amount
  FROM (
    SELECT session_id, SUM(amount) AS total
    FROM public.cash_movements
    WHERE reference_id = ANY(v_reference_ids) AND movement_type = 'sale'
    GROUP BY session_id
  ) v_sum
  JOIN public.cash_sessions cs ON cs.id = v_sum.session_id;

  IF v_cashbox_id IS NOT NULL AND v_cash_amount > 0 THEN
    SELECT id INTO v_open_session_id
    FROM public.cash_sessions
    WHERE cashbox_id = v_cashbox_id AND status = 'open'
    ORDER BY opened_at DESC
    LIMIT 1;

    IF v_open_session_id IS NULL THEN
      RAISE EXCEPTION 'no_open_session_for_reversal: abrí la caja para poder anular esta venta'
        USING ERRCODE = 'P0426';
    END IF;

    PERFORM public.c28_register_cash_movement(
      v_open_session_id, -v_cash_amount, 'sale_reversal', v_operation_key
    );
  END IF;

  -- ── Banco: espejo con dirección invertida, siempre unreconciled (D6) ─────
  FOR v_bank_row IN
    SELECT id, bank_account_id, amount, movement_type, branch_id
    FROM public.bank_movements
    WHERE source_doc_type = 'sale' AND source_doc_ref = ANY(v_reference_ids)
  LOOP
    v_reversed_type := CASE v_bank_row.movement_type
      WHEN 'transfer_in'  THEN 'transfer_out'
      WHEN 'transfer_out' THEN 'transfer_in'
      ELSE v_bank_row.movement_type
    END;

    PERFORM public._register_bank_movement(
      v_bank_row.bank_account_id, -v_bank_row.amount, v_reversed_type,
      'sale', v_operation_key, CURRENT_DATE, v_bank_row.branch_id,
      'Reversión por borrado de operación'
    );
  END LOOP;

  -- ── Reversa de stock (rpc_reverse_stock_movement, sin cambios — #417) ─────
  FOR v_row IN SELECT unnest(v_sale_ids) AS id LOOP
    PERFORM public.rpc_reverse_stock_movement(v_row.id, 'sale', COALESCE(p_reason, 'Venta eliminada'));
  END LOOP;

  -- ── Contable: emitir SaleOperationDeleted (async, vía outbox) ────────────
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id, 'SaleOperationDeleted', 'SaleOperation', v_operation_key,
    jsonb_build_object(
      'account_id',     v_account_id,
      'operation_id',   v_operation_key,
      'sales_order_id', v_sales_order_id,
      'occurred_at',    now()
    ),
    now()
  );

  -- ── POS: cancelar la sales_order en la misma transacción (D8) ────────────
  IF v_sales_order_id IS NOT NULL AND v_so_status = 'confirmed' THEN
    UPDATE public.sales_orders
    SET status = 'canceled', sale_operation_id = NULL
    WHERE id = v_sales_order_id;

    PERFORM public.record_status_transition(
      v_account_id, 'sales_order', v_sales_order_id, 'confirmed', 'canceled',
      v_uid, COALESCE(p_reason, 'Venta eliminada')
    );
  END IF;

  -- ── DELETE + limpieza de idempotencia ─────────────────────────────────────
  DELETE FROM public.sales WHERE id = ANY(v_sale_ids);

  DELETE FROM public.operation_idempotency WHERE operation_id = v_operation_key;

  RETURN true;
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_delete_sale_operation(uuid, uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_delete_sale_operation(uuid, uuid, text) TO postgres, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- (5) rpc_emit_sale_invoice — guard fail-closed D6
--
-- Cuerpo VIVO de 20261060000001 (md5 01862c30…) con TRES hunks: M1 tres
-- variables; M2 so.sale_operation_id en el SELECT de la orden (con lock, sin
-- cambio); M3 el bloque "1-bis" DESPUÉS de la allow-list de re-emisión (que
-- queda byte-idéntica) y ANTES de numerar/emitir. Firma IDÉNTICA.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_emit_sale_invoice(
  p_sales_order_id   uuid,
  p_point_of_sale_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid               uuid;
  v_account_id        uuid;
  v_order             RECORD;
  v_profile           RECORD;
  v_client            RECORD;
  v_comprobante_type  text;
  v_receptor_doc_tipo integer;
  v_receptor_doc_nro  text;
  v_emit_result       jsonb;
  v_existing_status   text;   -- venta-editable-sin-cae (D5)
  -- venta-editable-vs-promocion-legacy (D6): la orden tiene que reflejar su venta.
  v_ops_rows          integer;
  v_ops_total         numeric(15,2);
  v_ops_client_diff   integer;
BEGIN
  -- ── 0. Autenticación ──────────────────────────────────────────────────────
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  -- ── 1. Cargar la orden con lock (anti doble-emisión concurrente) ──────────
  SELECT so.id, so.account_id, so.status, so.fiscal_document_id,
         so.total, so.client_id, so.sale_operation_id
  INTO   v_order
  FROM   public.sales_orders so
  WHERE  so.id = p_sales_order_id
    AND  so.account_id = v_account_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'sales_order_not_found: orden de venta no encontrada o no pertenece a la cuenta'
      USING ERRCODE = 'P0404';
  END IF;

  -- Validar estado: solo confirmadas
  IF v_order.status != 'confirmed' THEN
    RAISE EXCEPTION 'order_not_confirmed: la orden debe estar en estado confirmed para facturar (estado actual: %)',
      v_order.status
      USING ERRCODE = 'P0400';
  END IF;

  -- Idempotencia: si ya tiene un comprobante que NO es terminal-inocuo → 409.
  -- venta-editable-sin-cae (D5): ALLOW-LIST deliberada, no deny-list. Sólo
  -- 'rejected' (nunca existió fiscalmente) y 'voided' (anulado por editar o
  -- borrar la venta, antes de salir hacia ARCA) habilitan volver a facturar.
  -- Cualquier otro valor —incluido uno que no exista hoy— BLOQUEA: un
  -- deny-list ("NOT IN (pending_cae, authorized)") convertiría un status
  -- futuro desconocido en una SEGUNDA factura real, que es el peor bug
  -- posible en este dominio (lección de #577/#580: guards cerrados por
  -- defecto). v_existing_status NULL (FK colgada, imposible hoy) bloquea igual.
  -- La orden ya está tomada con FOR UPDATE más arriba, y acá se toma también
  -- el comprobante, así que este chequeo y el UPDATE de más abajo son
  -- atómicos contra otra emisión Y contra la anulación de la edición.
  -- Efecto lateral DECLARADO y deseado: cierra el bug preexistente de que una
  -- orden cuyo único comprobante quedó 'rejected' no se podía volver a
  -- facturar NUNCA (el guard era incondicional al status).
  IF v_order.fiscal_document_id IS NOT NULL THEN
    SELECT fd.status INTO v_existing_status
    FROM   public.fiscal_documents fd
    WHERE  fd.id = v_order.fiscal_document_id
    FOR UPDATE;

    IF v_existing_status IS NULL OR v_existing_status NOT IN ('rejected', 'voided') THEN
      RAISE EXCEPTION 'already_invoiced: la orden ya tiene un comprobante fiscal asociado (fiscal_document_id=%, status=%)',
        v_order.fiscal_document_id, COALESCE(v_existing_status, 'desconocido')
        USING ERRCODE = 'P0409';
    END IF;
  END IF;

  -- ── 1-bis. La orden coincide con su venta (venta-editable-vs-promocion-legacy, D6)
  -- Guard FAIL-CLOSED en el punto donde el daño se vuelve real: un comprobante
  -- por un importe o un receptor que ya no son los de la venta. La orden la
  -- mantienen sincronizada la promoción y la edición (helper único
  -- _sales_order_sync_from_operation); si algún camino, hoy o futuro, la
  -- desincroniza, acá se RECHAZA en vez de facturar. sales se LEE sin lock a
  -- propósito: tomarla después de sales_orders invertiría el orden global de
  -- locks (sales → sales_orders → fiscal_documents) y abriría un deadlock
  -- contra la edición. No hace falta: con la orden tomada, ninguna edición ni
  -- borrado de esta operación puede commitear (los dos pasan por esta fila).
  -- Importes a 2 decimales de los dos lados (hay filas de sales con más).
  IF v_order.sale_operation_id IS NULL THEN
    RAISE EXCEPTION 'sales_order_out_of_sync: la orden % no está vinculada a ninguna venta — no se puede facturar', p_sales_order_id
      USING ERRCODE = 'P0409';
  END IF;

  SELECT count(*),
         round(COALESCE(sum(COALESCE(s.total, s.amount * s.quantity)), 0), 2),
         count(*) FILTER (WHERE s.client_id IS DISTINCT FROM v_order.client_id)
  INTO   v_ops_rows, v_ops_total, v_ops_client_diff
  FROM   public.sales s
  WHERE  s.operation_id = v_order.sale_operation_id
    AND  s.account_id   = v_account_id;

  IF v_ops_rows = 0
     OR v_ops_total IS DISTINCT FROM round(v_order.total, 2)
     OR v_ops_client_diff > 0 THEN
    RAISE EXCEPTION 'sales_order_out_of_sync: la orden % no coincide con su venta (orden %, venta %, líneas %) — volvé a preparar la venta para facturar',
      p_sales_order_id, round(v_order.total, 2), v_ops_total, v_ops_rows
      USING ERRCODE = 'P0409';
  END IF;

  -- ── 2. Leer perfil fiscal del emisor ──────────────────────────────────────
  SELECT id, iva_condition INTO v_profile
  FROM   public.fiscal_profiles
  WHERE  account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fiscal_profile_not_found: la cuenta no tiene perfil fiscal configurado'
      USING ERRCODE = 'P0404';
  END IF;

  -- OQ-1: bloquear si el emisor es RI (Factura A/B fuera de alcance MVP — D8)
  IF v_profile.iva_condition = 'responsable_inscripto' THEN
    RAISE EXCEPTION 'ri_not_supported: la facturación A/B para Responsables Inscriptos aún no está disponible. Completá la configuración cuando se habilite la función.'
      USING ERRCODE = 'P0401';
  END IF;

  -- ── 3. Resolver tipo de comprobante (D3) ─────────────────────────────────
  -- MVP: monotributista → factura_c (único caso soportado tras el guard OQ-1)
  v_comprobante_type := 'factura_c';

  -- ── 4. Derivar receptor desde clients (C-22) (D5) ────────────────────────
  -- Sin client_id o sin tax_id → NULL/NULL (el WSFEAdapter lo convierte a 99/0)
  v_receptor_doc_tipo := NULL;
  v_receptor_doc_nro  := NULL;

  IF v_order.client_id IS NOT NULL THEN
    SELECT iva_condition, tax_id INTO v_client
    FROM   public.clients
    WHERE  id = v_order.client_id
      AND  account_id = v_account_id;

    IF FOUND AND v_client.tax_id IS NOT NULL THEN
      -- Responsable Inscripto con CUIT → DocTipo 80
      IF v_client.iva_condition = 'responsable_inscripto' THEN
        v_receptor_doc_tipo := 80;
        v_receptor_doc_nro  := v_client.tax_id;
      -- Monotributista u otro con tax_id → tratar como DNI (DocTipo 96)
      ELSIF v_client.iva_condition IN ('monotributista', 'exento') THEN
        v_receptor_doc_tipo := 96;
        v_receptor_doc_nro  := v_client.tax_id;
      END IF;
      -- consumidor_final con tax_id → seguir como NULL (99/0)
    END IF;
  END IF;

  -- ── 5. Emitir comprobante vía pipeline existente ──────────────────────────
  -- Llama rpc_emit_pending_cae con neto/IVA en NULL (Factura C no discrimina)
  v_emit_result := public.rpc_emit_pending_cae(
    p_comprobante_type  => v_comprobante_type,
    p_total             => v_order.total,
    p_client_id         => v_order.client_id,
    p_point_of_sale_id  => p_point_of_sale_id,
    p_receptor_doc_tipo => v_receptor_doc_tipo,
    p_receptor_doc_nro  => v_receptor_doc_nro,
    p_neto              => NULL,
    p_iva_amount        => NULL,
    p_iva_alicuota_id   => NULL
  );

  -- ── 6. Vincular el comprobante a la orden (mismo commit) ─────────────────
  UPDATE public.sales_orders
  SET    fiscal_document_id = (v_emit_result->>'fiscal_document_id')::uuid
  WHERE  id = p_sales_order_id;

  -- Enriquecer la respuesta con el status de la orden (OQ-3)
  v_emit_result := v_emit_result || jsonb_build_object(
    'sales_order_id', p_sales_order_id,
    'status',         'pending_cae'
  );

  RETURN v_emit_result;
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_emit_sale_invoice(uuid, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_emit_sale_invoice(uuid, uuid) TO postgres, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- (6) Gate de introspección embebido — asserta lo que esta migración PROMETE.
-- El gate de comportamiento vive en supabase/tests/test_facturar_venta_manual.sql
-- (una conexión) y test_facturar_venta_manual_race.sh (dos conexiones). Sólo
-- lee el catálogo: no asserta datos (un drift de datos no debe romper un push).
-- Se compara sobre el cuerpo SIN comentarios y con espacios colapsados.
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_missing text[] := '{}';
  v_fn      text;
  v_def     text;
  v_count   int;
  v_pos_a   int;
  v_pos_b   int;
BEGIN
  -- (a) Helper nuevo: existe, INVOKER, cerrado a anon/authenticated.
  IF to_regprocedure('public._sales_order_sync_from_operation(uuid, uuid, uuid)') IS NULL THEN
    v_missing := v_missing || format('falta public._sales_order_sync_from_operation(uuid, uuid, uuid)');
  ELSE
    IF (SELECT prosecdef FROM pg_proc
        WHERE oid = to_regprocedure('public._sales_order_sync_from_operation(uuid, uuid, uuid)')) THEN
      v_missing := v_missing || format('_sales_order_sync_from_operation tiene que ser SECURITY INVOKER (sólo corre dentro de RPCs SECURITY DEFINER)');
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon')
       AND (   has_function_privilege('anon',          to_regprocedure('public._sales_order_sync_from_operation(uuid, uuid, uuid)'), 'EXECUTE')
            OR has_function_privilege('authenticated', to_regprocedure('public._sales_order_sync_from_operation(uuid, uuid, uuid)'), 'EXECUTE')) THEN
      v_missing := v_missing || format('_sales_order_sync_from_operation es ejecutable por anon/authenticated: sería la primitiva para reescribir por PostgREST el total de una orden ajena');
    END IF;
  END IF;

  -- (b) Una sola definición viva de cada función tocada (gotcha 42725).
  FOREACH v_fn IN ARRAY ARRAY['rpc_promote_legacy_sale_to_order', 'rpc_atomic_update_sale_operation',
                              'rpc_delete_sale_operation', 'rpc_emit_sale_invoice',
                              '_sales_order_sync_from_operation', '_fiscal_void_pending_for_sale_edit']
  LOOP
    SELECT count(*) INTO v_count
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = v_fn;
    IF v_count <> 1 THEN
      v_missing := v_missing || format('%s: %s definiciones vivas (esperaba 1)', v_fn, v_count);
    END IF;
  END LOOP;

  -- (c) Promoción: sin MIN(, con el lock ANTES de crear la orden, con el
  -- helper, y side-effect-free (D1).
  SELECT lower(regexp_replace(regexp_replace(prosrc, '--[^' || chr(10) || ']*', '', 'g'), '\s+', ' ', 'g'))
  INTO   v_def
  FROM   pg_proc WHERE oid = to_regprocedure('public.rpc_promote_legacy_sale_to_order(uuid)');
  IF v_def IS NULL THEN
    v_missing := v_missing || format('no se pudo leer rpc_promote_legacy_sale_to_order(uuid)');
  ELSE
    IF v_def ~ '\mmin\s*\(' THEN
      v_missing := v_missing || format('la promoción sigue agregando con MIN(): min(uuid) no existe y aborta con 42883 (N2)');
    END IF;
    v_pos_a := position('for update of s' in v_def);
    v_pos_b := position('insert into public.sales_orders' in v_def);
    IF v_pos_a = 0 OR v_pos_b = 0 OR v_pos_a > v_pos_b THEN
      v_missing := v_missing || format('la promoción no toma las filas de sales FOR UPDATE antes de crear la orden (N1)');
    END IF;
    IF position('_sales_order_sync_from_operation(' in v_def) = 0 THEN
      v_missing := v_missing || format('la promoción no usa el helper único de sincronización');
    END IF;
    IF v_def ~ '(branch_stock|cash_movement|_c29_confirm_order_core|insert into public\.events)' THEN
      v_missing := v_missing || format('la promoción dejó de ser side-effect-free (D1)');
    END IF;
  END IF;

  -- (d) Edición: el lock de las filas va ANTES del helper de anulación (N1) y
  -- la orden re-apuntada se recalcula (N3).
  SELECT lower(regexp_replace(regexp_replace(prosrc, '--[^' || chr(10) || ']*', '', 'g'), '\s+', ' ', 'g'))
  INTO   v_def
  FROM   pg_proc WHERE oid = to_regprocedure('public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean, uuid, boolean, text, boolean)');
  v_pos_a := position('where s.id = any(p_sale_ids) and s.user_id = v_uid order by s.id for update' in COALESCE(v_def, ''));
  v_pos_b := position('_fiscal_void_pending_for_sale_edit(' in COALESCE(v_def, ''));
  IF v_pos_a = 0 OR v_pos_b = 0 OR v_pos_a > v_pos_b THEN
    v_missing := v_missing || format('la edición no toma las filas de la operación FOR UPDATE ANTES de resolver su orden (N1)');
  END IF;
  IF position('_sales_order_sync_from_operation(' in COALESCE(v_def, '')) = 0 THEN
    v_missing := v_missing || format('la edición re-apunta la orden sin recalcularla: se volvería a facturar el importe viejo (N3)');
  END IF;

  -- (e) Borrado: el lock de las filas va ANTES del helper de anulación (N1).
  SELECT lower(regexp_replace(regexp_replace(prosrc, '--[^' || chr(10) || ']*', '', 'g'), '\s+', ' ', 'g'))
  INTO   v_def
  FROM   pg_proc WHERE oid = to_regprocedure('public.rpc_delete_sale_operation(uuid, uuid, text)');
  v_pos_a := position('where s.id = any(v_sale_ids) and s.account_id = v_account_id order by s.id for update' in COALESCE(v_def, ''));
  v_pos_b := position('_fiscal_void_pending_for_sale_edit(' in COALESCE(v_def, ''));
  IF v_pos_a = 0 OR v_pos_b = 0 OR v_pos_a > v_pos_b THEN
    v_missing := v_missing || format('el borrado no toma las filas de la operación FOR UPDATE ANTES de resolver su orden (N1)');
  END IF;

  -- (f) Emisión: guard D6 antes de emitir, allow-list intacta, y NUNCA un
  -- lock sobre sales (invertiría el orden global → deadlock con la edición).
  SELECT lower(regexp_replace(regexp_replace(prosrc, '--[^' || chr(10) || ']*', '', 'g'), '\s+', ' ', 'g'))
  INTO   v_def
  FROM   pg_proc WHERE oid = to_regprocedure('public.rpc_emit_sale_invoice(uuid, uuid)');
  v_pos_a := position('sales_order_out_of_sync' in COALESCE(v_def, ''));
  v_pos_b := position('rpc_emit_pending_cae(' in COALESCE(v_def, ''));
  IF v_pos_a = 0 OR v_pos_b = 0 OR v_pos_a > v_pos_b THEN
    v_missing := v_missing || format('la emisión no verifica que la orden coincida con su venta ANTES de emitir (D6)');
  END IF;
  IF position('not in (''rejected'', ''voided'')' in COALESCE(v_def, '')) = 0 THEN
    v_missing := v_missing || format('la emisión perdió la ALLOW-LIST de re-emisión de venta-editable-sin-cae');
  END IF;
  IF COALESCE(v_def, '') ~ 'from public\.sales s [^;]*for (update|share)' THEN
    v_missing := v_missing || format('la emisión toma locks sobre sales: invierte el orden global de locks y abre un deadlock contra la edición');
  END IF;

  -- (g) ACLs de las 4 RPCs: authenticated SÍ, anon NO, SECURITY DEFINER.
  FOREACH v_fn IN ARRAY ARRAY['public.rpc_promote_legacy_sale_to_order(uuid)',
                              'public.rpc_emit_sale_invoice(uuid, uuid)',
                              'public.rpc_delete_sale_operation(uuid, uuid, text)',
                              'public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean, uuid, boolean, text, boolean)']
  LOOP
    IF to_regprocedure(v_fn) IS NULL THEN
      v_missing := v_missing || format('%s no resuelve (¿cambió la firma? un CREATE OR REPLACE con otra firma deja un overload)', v_fn);
    ELSIF NOT (SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure(v_fn)) THEN
      v_missing := v_missing || format('%s dejó de ser SECURITY DEFINER', v_fn);
    ELSIF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon')
          AND (   has_function_privilege('anon', to_regprocedure(v_fn), 'EXECUTE')
               OR NOT has_function_privilege('authenticated', to_regprocedure(v_fn), 'EXECUTE')) THEN
      v_missing := v_missing || format('%s: ACL distinta de la viva (anon sin EXECUTE, authenticated con EXECUTE)', v_fn);
    END IF;
  END LOOP;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'GATE VENTA-EDITABLE-VS-PROMOCION-LEGACY FAILED:\n  %', array_to_string(v_missing, E'\n  ');
  END IF;

  RAISE NOTICE 'venta-editable-vs-promocion-legacy OK: helper de sincronización cerrado e INVOKER, promoción sin MIN() con lock previo y side-effect-free, edición y borrado toman las filas antes de resolver la orden, la edición recalcula la orden re-apuntada, la emisión rechaza una orden desincronizada sin tomar sales, una sola definición viva y ACLs intactas.';
END $$;
