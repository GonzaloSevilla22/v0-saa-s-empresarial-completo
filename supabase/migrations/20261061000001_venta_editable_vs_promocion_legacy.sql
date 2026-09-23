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
  SELECT so.id, so.fiscal_document_id
  INTO   v_existing_id, v_existing_fd
  FROM   public.sales_orders so
  WHERE  so.sale_operation_id = p_operation_id;

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
  -- transacción. El handler de unique_violation queda como red: con el lock de
  -- (1) es inalcanzable, pero si un camino futuro insertara sin el ancla sigue
  -- devolviendo la orden existente en vez de un 500.
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
    WHERE sale_operation_id = p_operation_id;

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
