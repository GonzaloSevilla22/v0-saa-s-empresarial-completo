-- =============================================================================
-- MIGRATION: 20261075000002_ventas_sucursal_por_defecto_backfill.sql
-- CHANGE: ventas-sucursal-por-defecto (2026-10-09) — governance ALTA: modifica en
--         masa datos de producción (sales.branch_id y, con la excepción a RN-21
--         de abajo, stock_movements.branch_id). La mergea el PO. SOLO DATOS: sin
--         DDL, sin funciones, sin ACLs. Va después de 20261075000001 (las tres
--         funciones que ya guardan la sucursal resuelta): primero entran los
--         cuerpos nuevos y después corre el backfill.
--
-- DECISIÓN DEL PO (2026-10-01): «sí, que las ventas sin sucursal queden con la
-- principal». SIGN-OFF DE LAS REGLAS (2026-10-09, «vamos con todo lo
-- recomendado»): OQ-4 (a) las reglas de D6, OQ-5 (c) los movimientos de stock
-- nulos se completan sólo donde el origen es demostrable (excepción única y
-- auditada a RN-21), OQ-6 (a) manda la orden si hay comprobante vigente y, si no,
-- el movimiento.
--
-- QUÉ HACE (design D6/D7). Resuelve la sucursal POR OPERACIÓN
-- (COALESCE(operation_id, id)): todas las filas NULL de una operación toman la
-- misma sucursal. Resolver fila por fila podría dejar una operación mixta (una
-- línea de servicio no tiene movimiento de stock) y
-- _sales_order_sync_from_operation rechaza con P0422 operation_inconsistent una
-- operación que mezcla NULL y no NULL. Candidatas: filas vivas de sales con
-- branch_id IS NULL y account_id IS NOT NULL. Gana la primera regla que dé una
-- sucursal:
--   1. OPERACIÓN MIXTA: las filas no nulas de la misma operación tienen
--      EXACTAMENTE una sucursal. (Con dos o más no se elige ninguna.)
--   2. ORDEN CON COMPROBANTE VIGENTE (OQ-6): la operación tiene una sales_orders
--      de la misma cuenta cuyo comprobante está authorized, o pending_cae con
--      marca de envío (cae_submit_started_at o cae_submit_unconfirmed_at). Esa
--      venta es inmutable (P0423) y la orden nunca se vuelve a sincronizar: la
--      venta queda junto a su factura y a sus notas de crédito.
--   3. MOVIMIENTO DE STOCK PROPIO (OQ-6): los movimientos type 'sale',
--      reference_type 'sale' de las filas NULL registran EXACTAMENTE una
--      sucursal: ahí salió el stock y ahí repone el borrado.
--   4. ORDEN SIN COMPROBANTE VIGENTE: la operación tiene una sales_orders sin
--      comprobante o con uno rejected, voided o pending_cae sin marca.
--   5. RESTO: c26_default_branch(account_id) vigente al aplicar la migración.
-- Filtro de sucursal operativa (is_active AND status = 'active') SÓLO en las
-- reglas 3, 4 y 5: asignar una sucursal cerrada o desactivada dejaría la venta
-- sin poder editarse desde el formulario. Las reglas 1 y 2 NO pasan por el filtro
-- (la operación ya vive ahí o la venta ya es inmutable); esas asignaciones se
-- cuentan aparte (mixta_no_operativa, orden_facturada_no_operativa).
--
-- RESIDUO (queda NULL, se informa con NOTICE y NUNCA aborta): filas sin
-- account_id; cuenta sin sucursales; cuenta sin sucursal operativa.
--
-- POR QUÉ NO HACE FALTA MEDIR ANTES (D6, D7): la decisión ya está tomada y ningún
-- número cambia cuál regla es la correcta; la migración se autoinforma (NOTICE +
-- una fila de audit_logs por cuenta afectada) y la verificación posterior es de
-- sólo lectura (tarea 12).
--
-- EXCEPCIÓN A RN-21 (OQ-5 (c)), con sus límites. stock_movements es append-only:
-- toda corrección es un movimiento nuevo. Completar el branch_id de movimientos
-- existentes es la ÚNICA excepción y se acota así: sólo la columna branch_id;
-- sólo movimientos type 'sale', reference_type 'sale' con branch_id IS NULL; sólo
-- de las ventas asignadas EN ESTA CORRIDA; y sólo si su ORIGEN ES DEMOSTRABLE:
-- cuando se escribió el movimiento (stock_movements.created_at) la sucursal
-- asignada ya existía y era la ÚNICA de la cuenta (ninguna otra sucursal de la
-- cuenta tiene created_at menor o igual al del movimiento): c26_default_branch no
-- pudo devolver otra, así que de ahí salió el stock. El resto queda NULL y se
-- cuenta (movimiento_origen_incierto): completarlo falsearía el ledger y su
-- reconstrucción por (producto, sucursal). Cada id queda en la auditoría.
--
-- LOCKS: las candidatas se toman con FOR UPDATE en orden ascendente de id (regla
-- dura del proyecto: sales por id → sales_orders → fiscal_documents → resto), la
-- misma que usan la edición, el borrado y la promoción, así que no puede entrar en
-- deadlock con ninguno de los tres. NO se usa LOCK TABLE. stock_movements va
-- después ("resto"); nadie actualiza sus filas (append-only), así que no hay
-- orden que respetar entre ellas.
--
-- SIN EFECTOS LATERALES: sales sólo tiene disparadores AFTER INSERT (margen bajo,
-- analytics), así que el UPDATE no dispara margen, analytics, eventos,
-- notificaciones ni Realtime. No se toca ningún movimiento de caja, de banco, de
-- cuenta corriente ni asiento contable, ni sales_orders, sale_items, branch_stock.
--
-- TRAZABILIDAD: una fila de audit_logs por cuenta afectada (action =
-- 'sales_branch_backfill', entity_type = 'account', user_id NULL = sistema) con
-- los ids asignados, los contadores por regla y las discrepancias.
-- REVERSIÓN exacta por id (sólo con decisión explícita del PO; no está prevista):
--   UPDATE sales SET branch_id = NULL
--   WHERE id IN (SELECT jsonb_array_elements_text(metadata->'sale_ids')::uuid
--                FROM audit_logs WHERE action = 'sales_branch_backfill');
--   (lo mismo con metadata->'movement_ids' sobre stock_movements).
--
-- IDEMPOTENCIA: el WHERE branch_id IS NULL hace que una segunda corrida no
-- encuentre filas asignables; con cero filas asignadas no se escribe auditoría.
-- Contadores por FILA de venta (salvo los movimientos, que se cuentan por
-- movimiento).
-- Gate: supabase/tests/test_ventas_sucursal_por_defecto.sql (parte B) lo ejecuta
-- con \i dos veces sobre fixtures reales.
-- =============================================================================

DO $$
DECLARE
  v_ids            uuid[];
  v_n_assigned     integer := 0;
  v_n_movs         integer := 0;
  v_n_accounts     integer := 0;
  v_por_regla      jsonb   := '{"operacion":0,"orden_facturada":0,"movimiento":0,"orden":0,"principal":0}'::jsonb;
  v_mixta_no_op    integer := 0;
  v_ord_fact_no_op integer := 0;
  v_salteadas      integer := 0;
  v_disc_mov       integer := 0;
  v_disc_ord       integer := 0;
  v_incierto       integer := 0;
  v_evidencia      integer := 0;
  v_res_sin_cuenta integer := 0;
  v_res_sin_suc    integer := 0;
  v_res_sin_op     integer := 0;
BEGIN
  -- Tablas temporales de trabajo: se borran al final; por si una corrida anterior de la
  -- misma sesión quedó a medias, se limpian acá sin ruido de NOTICE.
  IF to_regclass('pg_temp._vsb_cand')     IS NOT NULL THEN DROP TABLE _vsb_cand;     END IF;
  IF to_regclass('pg_temp._vsb_op')       IS NOT NULL THEN DROP TABLE _vsb_op;       END IF;
  IF to_regclass('pg_temp._vsb_ok')       IS NOT NULL THEN DROP TABLE _vsb_ok;       END IF;
  IF to_regclass('pg_temp._vsb_assigned') IS NOT NULL THEN DROP TABLE _vsb_assigned; END IF;
  IF to_regclass('pg_temp._vsb_mov')      IS NOT NULL THEN DROP TABLE _vsb_mov;      END IF;

  -- ─── 1. Candidatas, bloqueadas en orden ascendente de id ───────────────────
  SELECT COALESCE(array_agg(l.id ORDER BY l.id), '{}'::uuid[]) INTO v_ids
  FROM (
    SELECT s.id
    FROM   public.sales s
    WHERE  s.branch_id IS NULL AND s.account_id IS NOT NULL
    ORDER  BY s.id
    FOR UPDATE
  ) l;

  IF COALESCE(array_length(v_ids, 1), 0) > 0 THEN
    -- ─── 2. Resolución por operación (todo por JOIN, nunca subconsulta por fila) ─
    CREATE TEMP TABLE _vsb_cand (
      sale_id      uuid PRIMARY KEY,
      account_id   uuid NOT NULL,
      op_key       uuid NOT NULL,   -- COALESCE(operation_id, id): una fila legacy es su propia operación
      operation_id uuid
    );
    INSERT INTO _vsb_cand (sale_id, account_id, op_key, operation_id)
    SELECT s.id, s.account_id, COALESCE(s.operation_id, s.id), s.operation_id
    FROM   public.sales s
    WHERE  s.id = ANY(v_ids);

    CREATE TEMP TABLE _vsb_op (
      account_id   uuid NOT NULL,
      op_key       uuid NOT NULL,
      operation_id uuid,
      b1 uuid, b2 uuid, b3 uuid, b4 uuid, b5 uuid,
      op3 boolean NOT NULL DEFAULT FALSE,
      op4 boolean NOT NULL DEFAULT FALSE,
      op5 boolean NOT NULL DEFAULT FALSE,
      rule         text,
      branch_id    uuid,
      skipped      boolean NOT NULL DEFAULT FALSE,
      PRIMARY KEY (account_id, op_key)
    );
    INSERT INTO _vsb_op (account_id, op_key, operation_id)
    SELECT DISTINCT c.account_id, c.op_key, c.operation_id FROM _vsb_cand c;

    -- Sucursales operativas (is_active AND status = 'active'): una sola lectura.
    CREATE TEMP TABLE _vsb_ok (branch_id uuid PRIMARY KEY);
    INSERT INTO _vsb_ok (branch_id)
    SELECT b.id FROM public.branches b WHERE b.is_active AND b.status = 'active';

    ANALYZE _vsb_cand;
    ANALYZE _vsb_op;
    ANALYZE _vsb_ok;

    -- Regla 1: las filas NO nulas de la operación tienen EXACTAMENTE una sucursal.
    UPDATE _vsb_op o SET b1 = x.branch_id
    FROM (SELECT o2.account_id, o2.op_key, (array_agg(DISTINCT s2.branch_id))[1] AS branch_id
          FROM   _vsb_op o2
          JOIN   public.sales s2
            ON   s2.operation_id = o2.operation_id AND s2.account_id = o2.account_id AND s2.branch_id IS NOT NULL
          WHERE  o2.operation_id IS NOT NULL
          GROUP  BY o2.account_id, o2.op_key
          HAVING COUNT(DISTINCT s2.branch_id) = 1) x
    WHERE o.account_id = x.account_id AND o.op_key = x.op_key;

    -- Regla 2: orden con comprobante VIGENTE (authorized, o pending_cae con marca de envío).
    UPDATE _vsb_op o SET b2 = x.branch_id
    FROM (SELECT DISTINCT ON (o2.account_id, o2.op_key) o2.account_id, o2.op_key, so.branch_id
          FROM   _vsb_op o2
          JOIN   public.sales_orders so
            ON   so.sale_operation_id = o2.operation_id AND so.account_id = o2.account_id
          JOIN   public.fiscal_documents fd ON fd.id = so.fiscal_document_id
          WHERE  o2.operation_id IS NOT NULL
            AND  (fd.status = 'authorized'
                  OR (fd.status = 'pending_cae'
                      AND (fd.cae_submit_started_at IS NOT NULL OR fd.cae_submit_unconfirmed_at IS NOT NULL)))
          ORDER  BY o2.account_id, o2.op_key) x
    WHERE o.account_id = x.account_id AND o.op_key = x.op_key;

    -- Regla 3: el movimiento 'sale' propio registra EXACTAMENTE una sucursal.
    UPDATE _vsb_op o SET b3 = x.branch_id
    FROM (SELECT c.account_id, c.op_key, (array_agg(DISTINCT sm.branch_id))[1] AS branch_id
          FROM   _vsb_cand c
          JOIN   public.stock_movements sm
            ON   sm.reference_id = c.sale_id AND sm.type = 'sale' AND sm.reference_type = 'sale'
           AND   sm.branch_id IS NOT NULL
          GROUP  BY c.account_id, c.op_key
          HAVING COUNT(DISTINCT sm.branch_id) = 1) x
    WHERE o.account_id = x.account_id AND o.op_key = x.op_key;

    -- Regla 4: orden SIN comprobante vigente (sin comprobante, rejected, voided o pending_cae sin marca).
    UPDATE _vsb_op o SET b4 = x.branch_id
    FROM (SELECT DISTINCT ON (o2.account_id, o2.op_key) o2.account_id, o2.op_key, so.branch_id
          FROM   _vsb_op o2
          JOIN   public.sales_orders so
            ON   so.sale_operation_id = o2.operation_id AND so.account_id = o2.account_id
          LEFT   JOIN public.fiscal_documents fd ON fd.id = so.fiscal_document_id
          WHERE  o2.operation_id IS NOT NULL
            AND  NOT COALESCE((fd.status = 'authorized'
                               OR (fd.status = 'pending_cae'
                                   AND (fd.cae_submit_started_at IS NOT NULL OR fd.cae_submit_unconfirmed_at IS NOT NULL))), FALSE)
          ORDER  BY o2.account_id, o2.op_key) x
    WHERE o.account_id = x.account_id AND o.op_key = x.op_key;

    -- Regla 5: la principal vigente de la cuenta (una llamada por cuenta, no por operación).
    UPDATE _vsb_op o SET b5 = a.principal
    FROM (SELECT d.account_id, public.c26_default_branch(d.account_id) AS principal
          FROM   (SELECT DISTINCT account_id FROM _vsb_op) d) a
    WHERE o.account_id = a.account_id;

    -- Filtro de sucursal operativa: sólo para las reglas 3, 4 y 5.
    UPDATE _vsb_op o SET
      op3 = EXISTS (SELECT 1 FROM _vsb_ok k WHERE k.branch_id = o.b3),
      op4 = EXISTS (SELECT 1 FROM _vsb_ok k WHERE k.branch_id = o.b4),
      op5 = EXISTS (SELECT 1 FROM _vsb_ok k WHERE k.branch_id = o.b5);

    -- Primera regla que da una sucursal. Las reglas 1 y 2 NO pasan por el filtro.
    UPDATE _vsb_op o SET
      rule = CASE
               WHEN o.b1 IS NOT NULL THEN 'operacion'
               WHEN o.b2 IS NOT NULL THEN 'orden_facturada'
               WHEN o.op3 THEN 'movimiento'
               WHEN o.op4 THEN 'orden'
               WHEN o.op5 THEN 'principal'
             END,
      branch_id = CASE
               WHEN o.b1 IS NOT NULL THEN o.b1
               WHEN o.b2 IS NOT NULL THEN o.b2
               WHEN o.op3 THEN o.b3
               WHEN o.op4 THEN o.b4
               WHEN o.op5 THEN o.b5
             END,
      -- reglas 3 y 4 evaluadas y salteadas por sucursal no operativa
      skipped = (o.b1 IS NULL AND o.b2 IS NULL
                 AND ((o.b3 IS NOT NULL AND NOT o.op3)
                      OR (NOT o.op3 AND o.b4 IS NOT NULL AND NOT o.op4)));

    ANALYZE _vsb_op;

    -- ─── 3. Asignación (la ÚNICA escritura sobre sales) ──────────────────────
    CREATE TEMP TABLE _vsb_assigned (
      sale_id    uuid PRIMARY KEY,
      account_id uuid    NOT NULL,
      op_key     uuid    NOT NULL,
      branch_id  uuid    NOT NULL,
      rule       text    NOT NULL,
      skipped    boolean NOT NULL,
      branch_ok  boolean NOT NULL DEFAULT FALSE,
      disc_mov   boolean NOT NULL DEFAULT FALSE,
      disc_ord   boolean NOT NULL DEFAULT FALSE,
      evidencia  boolean NOT NULL DEFAULT FALSE
    );

    WITH upd AS (
      UPDATE public.sales s
      SET    branch_id = o.branch_id
      FROM   _vsb_cand c
      JOIN   _vsb_op   o ON o.account_id = c.account_id AND o.op_key = c.op_key
      WHERE  s.id = c.sale_id
        AND  s.branch_id IS NULL
        AND  o.rule IS NOT NULL
      RETURNING s.id, s.account_id, c.op_key, s.branch_id, o.rule, o.skipped
    )
    INSERT INTO _vsb_assigned (sale_id, account_id, op_key, branch_id, rule, skipped)
    SELECT id, account_id, op_key, branch_id, rule, skipped FROM upd;

    UPDATE _vsb_assigned a
    SET    branch_ok = EXISTS (SELECT 1 FROM _vsb_ok k WHERE k.branch_id = a.branch_id);

    ANALYZE _vsb_assigned;

    -- ─── 4. Movimientos de stock: SOLO los de origen demostrable (OQ-5 (c)) ──
    -- Excepción única y auditada a RN-21: sólo branch_id, sólo movimientos 'sale'
    -- de las ventas asignadas en esta corrida, y sólo si la sucursal asignada
    -- existía y era la única de la cuenta cuando se escribió el movimiento.
    CREATE TEMP TABLE _vsb_mov (movement_id uuid PRIMARY KEY, account_id uuid NOT NULL);

    WITH upd AS (
      UPDATE public.stock_movements sm
      SET    branch_id = a.branch_id
      FROM   _vsb_assigned a
      WHERE  sm.reference_id   = a.sale_id
        AND  sm.type           = 'sale'
        AND  sm.reference_type = 'sale'
        AND  sm.branch_id IS NULL
        AND  (sm.account_id IS NULL OR sm.account_id = a.account_id)
        AND  EXISTS (SELECT 1 FROM public.branches b
                     WHERE b.id = a.branch_id AND b.created_at <= sm.created_at)
        AND  NOT EXISTS (SELECT 1 FROM public.branches b2
                         WHERE b2.account_id = a.account_id AND b2.id <> a.branch_id
                           AND b2.created_at <= sm.created_at)
      RETURNING sm.id, a.account_id
    )
    INSERT INTO _vsb_mov (movement_id, account_id)
    SELECT id, account_id FROM upd;

    -- ─── 5. Discrepancias y evidencia (informativas: no escriben nada de negocio) ─
    -- venta ≠ movimiento: el movimiento 'sale' ya registraba OTRA sucursal.
    UPDATE _vsb_assigned a SET disc_mov = TRUE
    WHERE EXISTS (SELECT 1 FROM public.stock_movements sm
                  WHERE sm.reference_id = a.sale_id AND sm.type = 'sale' AND sm.reference_type = 'sale'
                    AND sm.branch_id IS NOT NULL AND sm.branch_id <> a.branch_id);

    -- venta ≠ orden: orden SIN comprobante vigente en otra sucursal (se re-sincroniza en la próxima edición).
    UPDATE _vsb_assigned a SET disc_ord = TRUE
    WHERE EXISTS (SELECT 1
                  FROM   public.sales_orders so
                  LEFT   JOIN public.fiscal_documents fd ON fd.id = so.fiscal_document_id
                  WHERE  so.sale_operation_id = a.op_key AND so.account_id = a.account_id
                    AND  so.branch_id <> a.branch_id
                    AND  NOT COALESCE((fd.status = 'authorized'
                                       OR (fd.status = 'pending_cae'
                                           AND (fd.cae_submit_started_at IS NOT NULL OR fd.cae_submit_unconfirmed_at IS NOT NULL))), FALSE));

    -- OQ-4: el cobro en caja o en banco registró OTRA sucursal (un solo EXISTS por UPDATE: semi-join, no subplan por fila).
    UPDATE _vsb_assigned a SET evidencia = TRUE
    WHERE EXISTS (SELECT 1
                  FROM   public.cash_movements cm
                  JOIN   public.cash_sessions cs ON cs.id = cm.session_id
                  JOIN   public.cashboxes cb ON cb.id = cs.cashbox_id
                  WHERE  cm.reference_id = a.op_key AND cb.branch_id <> a.branch_id);
    UPDATE _vsb_assigned a SET evidencia = TRUE
    WHERE NOT a.evidencia
      AND EXISTS (SELECT 1 FROM public.bank_movements bm
                  WHERE bm.source_doc_type = 'sale' AND bm.source_doc_ref = a.op_key
                    AND bm.branch_id IS NOT NULL AND bm.branch_id <> a.branch_id);

    -- ─── 6. Auditoría: una fila por cuenta afectada ──────────────────────────
    INSERT INTO public.audit_logs (user_id, action, account_id, entity_type, entity_id, metadata)
    SELECT NULL, 'sales_branch_backfill', g.account_id, 'account', g.account_id,
           jsonb_build_object(
             'change', 'ventas-sucursal-por-defecto',
             'sale_ids', g.sale_ids,
             'movement_ids', COALESCE(m.movement_ids, '[]'::jsonb),
             'por_regla', jsonb_build_object(
               'operacion', g.n_operacion, 'orden_facturada', g.n_orden_facturada,
               'movimiento', g.n_movimiento, 'orden', g.n_orden, 'principal', g.n_principal),
             'mixta_no_operativa', g.n_mixta_no_op,
             'orden_facturada_no_operativa', g.n_ordfact_no_op,
             'salteadas_no_operativa', g.n_salteadas,
             'discrepancia_movimiento', g.n_disc_mov,
             'discrepancia_orden', g.n_disc_ord,
             'movimiento_origen_incierto', COALESCE(i.n_incierto, 0),
             'evidencia_otra_sucursal', g.n_evidencia,
             'branch_ids', g.branch_ids)
    FROM (
      SELECT a.account_id,
             jsonb_agg(a.sale_id ORDER BY a.sale_id)                                    AS sale_ids,
             jsonb_agg(DISTINCT a.branch_id)                                            AS branch_ids,
             COUNT(*) FILTER (WHERE a.rule = 'operacion')                               AS n_operacion,
             COUNT(*) FILTER (WHERE a.rule = 'orden_facturada')                         AS n_orden_facturada,
             COUNT(*) FILTER (WHERE a.rule = 'movimiento')                              AS n_movimiento,
             COUNT(*) FILTER (WHERE a.rule = 'orden')                                   AS n_orden,
             COUNT(*) FILTER (WHERE a.rule = 'principal')                               AS n_principal,
             COUNT(*) FILTER (WHERE a.rule = 'operacion' AND NOT a.branch_ok)           AS n_mixta_no_op,
             COUNT(*) FILTER (WHERE a.rule = 'orden_facturada' AND NOT a.branch_ok)     AS n_ordfact_no_op,
             COUNT(*) FILTER (WHERE a.skipped)                                          AS n_salteadas,
             COUNT(*) FILTER (WHERE a.disc_mov)                                         AS n_disc_mov,
             COUNT(*) FILTER (WHERE a.disc_ord)                                         AS n_disc_ord,
             COUNT(*) FILTER (WHERE a.evidencia)                                        AS n_evidencia
      FROM   _vsb_assigned a
      GROUP  BY a.account_id
    ) g
    LEFT JOIN (
      SELECT mv.account_id, jsonb_agg(mv.movement_id ORDER BY mv.movement_id) AS movement_ids
      FROM   _vsb_mov mv GROUP BY mv.account_id
    ) m ON m.account_id = g.account_id
    LEFT JOIN (
      -- movimientos de las ventas asignadas que siguen sin sucursal (origen no demostrable)
      SELECT a.account_id, COUNT(*) AS n_incierto
      FROM   _vsb_assigned a
      JOIN   public.stock_movements sm ON sm.reference_id = a.sale_id
      WHERE  sm.type = 'sale' AND sm.reference_type = 'sale' AND sm.branch_id IS NULL
      GROUP  BY a.account_id
    ) i ON i.account_id = g.account_id;

    -- ─── 7. Totales para el NOTICE ───────────────────────────────────────────
    SELECT COUNT(*), COUNT(DISTINCT a.account_id),
           jsonb_build_object(
             'operacion',       COUNT(*) FILTER (WHERE a.rule = 'operacion'),
             'orden_facturada', COUNT(*) FILTER (WHERE a.rule = 'orden_facturada'),
             'movimiento',      COUNT(*) FILTER (WHERE a.rule = 'movimiento'),
             'orden',           COUNT(*) FILTER (WHERE a.rule = 'orden'),
             'principal',       COUNT(*) FILTER (WHERE a.rule = 'principal')),
           COUNT(*) FILTER (WHERE a.rule = 'operacion' AND NOT a.branch_ok),
           COUNT(*) FILTER (WHERE a.rule = 'orden_facturada' AND NOT a.branch_ok),
           COUNT(*) FILTER (WHERE a.skipped),
           COUNT(*) FILTER (WHERE a.disc_mov),
           COUNT(*) FILTER (WHERE a.disc_ord),
           COUNT(*) FILTER (WHERE a.evidencia)
    INTO   v_n_assigned, v_n_accounts, v_por_regla, v_mixta_no_op, v_ord_fact_no_op, v_salteadas,
           v_disc_mov, v_disc_ord, v_evidencia
    FROM   _vsb_assigned a;

    SELECT COUNT(*) INTO v_n_movs FROM _vsb_mov;

    SELECT COUNT(*) INTO v_incierto
    FROM   _vsb_assigned a
    JOIN   public.stock_movements sm ON sm.reference_id = a.sale_id
    WHERE  sm.type = 'sale' AND sm.reference_type = 'sale' AND sm.branch_id IS NULL;

    DROP TABLE _vsb_mov;
    DROP TABLE _vsb_assigned;
    DROP TABLE _vsb_ok;
    DROP TABLE _vsb_op;
    DROP TABLE _vsb_cand;
  END IF;

  -- ─── 8. Residuo (queda NULL, nunca aborta) ───────────────────────────────────
  SELECT COUNT(*) INTO v_res_sin_cuenta FROM public.sales WHERE branch_id IS NULL AND account_id IS NULL;
  SELECT COUNT(*) INTO v_res_sin_suc
  FROM   public.sales s
  WHERE  s.branch_id IS NULL AND s.account_id IS NOT NULL
    AND  NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.account_id = s.account_id);
  SELECT COUNT(*) INTO v_res_sin_op
  FROM   public.sales s
  WHERE  s.branch_id IS NULL AND s.account_id IS NOT NULL
    AND  EXISTS (SELECT 1 FROM public.branches b WHERE b.account_id = s.account_id)
    AND  NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.account_id = s.account_id AND b.is_active AND b.status = 'active');

  RAISE NOTICE 'ventas-sucursal-por-defecto (backfill): % ventas asignadas en % cuentas; por regla %; % movimientos de stock completados (origen demostrable)',
    v_n_assigned, v_n_accounts, v_por_regla, v_n_movs;
  RAISE NOTICE 'ventas-sucursal-por-defecto (backfill): asignaciones a una sucursal no operativa: % por operación mixta, % por orden facturada; % reglas salteadas por sucursal no operativa',
    v_mixta_no_op, v_ord_fact_no_op, v_salteadas;
  RAISE NOTICE 'ventas-sucursal-por-defecto (backfill): discrepancias: % ventas con su movimiento de stock en otra sucursal, % con su orden sin comprobante en otra sucursal; % movimientos NULL de origen incierto sin completar',
    v_disc_mov, v_disc_ord, v_incierto;
  RAISE NOTICE 'ventas-sucursal-por-defecto (backfill): % ventas cuyo cobro en caja o banco registró otra sucursal (OQ-4)', v_evidencia;
  RAISE NOTICE 'ventas-sucursal-por-defecto (backfill): residuo sin asignar: % sin cuenta, % de cuenta sin sucursales, % de cuenta sin sucursal operativa',
    v_res_sin_cuenta, v_res_sin_suc, v_res_sin_op;
END $$;
