-- =============================================================================
-- MIGRATION: 20261077000002_stock_movimientos_sucursal_origen.sql
-- CHANGE: stock-movimientos-sucursal-origen (2026-10-11) — governance ALTA:
--         modifica en masa datos de producción (stock_movements.branch_id), como
--         SEGUNDA y ÚLTIMA extensión de la excepción auditada a RN-21. La mergea
--         el PO. SOLO DATOS: sin DDL, sin funciones, sin ACLs. Va después de
--         20261077000001 (la reversa que ya no repone en una sucursal
--         desactivada): primero entra el fallback y después corre el backfill,
--         que puede dejar movimientos registrados en una sucursal desactivada.
--
-- DECISIÓN DEL PO (2026-10-11, «vamos con todo lo recomendado»):
--   OQ-A (a)  se completan los movimientos de cuando la cuenta no tenía sucursales
--             o tenía una sola, con su sucursal de ORIGEN real aunque hoy esté
--             desactivada;
--   OQ-B (a)  los de cuando había dos o más sucursales se reconstruyen SÓLO con
--             el estado registrado; el resto queda nulo;
--   OQ-C (a)  los movimientos sin venta viva NO se tocan;
--   OQ-D (a)  la reversa repone en la principal operativa (20261077000001).
--
-- QUÉ HACE (design D2-D5, D7). Completa stock_movements.branch_id de los
-- movimientos type 'sale', reference_type 'sale', branch_id IS NULL de una VENTA
-- VIVA con cuenta, con la sucursal de la que el sistema tomó el stock cuando se
-- registró el movimiento (T = stock_movements.created_at), reconstruida sólo con
-- lo que quedó registrado. Es el ORIGEN del movimiento, NO la sucursal asignada a
-- la venta (que decidió ventas-sucursal-por-defecto y no cambia): la venta puede
-- quedar en otra sucursal (se cuenta como discrepancia_venta). Sea S(T) el
-- conjunto de sucursales de la cuenta con created_at <= T:
--   pre_sucursal  S(T) vacío: la sucursal MÁS ANTIGUA de la cuenta, sin importar si
--                 hoy opera. Ese stock vivía en products.stock y C-21
--                 (20260620000001) lo materializó en la sucursal de menor
--                 created_at: es la misma convención que el sistema ya aplicó a
--                 todo el stock anterior a las sucursales.
--   unica         S(T) con una sola: esa, opere o no hoy. c26_default_branch la
--                 devuelve en cualquiera de las dos ramas de su COALESCE (y antes
--                 de C-26 era «la más antigua»): no pudo salir de otra.
--   reconstruida  S(T) con dos o más: la que c26_default_branch habría devuelto en
--                 T, es decir la primera de S(T) por created_at que OPERABA en T
--                 (is_active AND status = 'active'); si ninguna operaba, la más
--                 antigua de S(T). Sólo se escribe si el estado en T de TODAS las
--                 sucursales que la regla recorre hasta elegir es CONOCIDO (las
--                 anteriores a la elegida constan como no operativas y la elegida
--                 como operativa; o todas constan como no operativas).
-- «ANTE LA DUDA, NULO»: lo que no se puede demostrar queda nulo y se cuenta.
--
-- ESTADO DE UNA SUCURSAL EN T (design D3). Una constante del sistema,
-- X = 2026-08-26 00:00:00-03 (el fin del día en que se desplegó
-- 20261014000001, el disparador que registra TODO cambio de una sucursal en
-- audit_logs; confirmado contra producción el 2026-10-11: el primer evento de
-- ciclo de vida de toda producción es del 2026-09-01):
--   - REBOBINADO: se parte del estado actual de la sucursal y se deshacen los
--     eventos de ciclo de vida registrados DESPUÉS de T; el estado en T es el
--     estado previo del primer evento posterior a T. Sólo cuentan los eventos que
--     cambiaron is_active o status (una edición de nombre no interviene). Si dos
--     o más eventos de la sucursal comparten instante y dejan estados previos
--     distintos, o un evento comparte el instante con T (misma transacción), el
--     estado es DESCONOCIDO.
--   - T >= X: el rebobinado es exacto (desde X todo cambio quedó registrado).
--   - T < X: el rebobinado sólo es exacto si nada cambió sin registrarse entre T y
--     X, así que a su resultado se le aplica una inferencia conservadora, que sólo
--     afirma lo que no pudo cambiar sin dejar rastro: ACTIVA y ABIERTA y SIN
--     closed_at -> operaba en T (antes del registro no había camino de la
--     aplicación para reactivar una sucursal, y rpc_close_branch siempre escribe
--     closed_at sin que nada lo limpie); cualquier otro caso -> DESCONOCIDO (una
--     baja pudo ocurrir antes de que se registrara su fecha: la «Principal» del
--     22-08 nunca tuvo fecha).
--   - DESEMPATE: c26_default_branch ordena por created_at sin desempate. Si la
--     sucursal que la regla elegiría comparte created_at con otra de la cuenta, el
--     origen NO es demostrable y el movimiento queda nulo (no_fechable).
--
-- VETO por caja y banco (design D4). Para la operación de la venta
-- (COALESCE(operation_id, id) y la orden de venta que la referencia: las mismas
-- claves que usa rpc_delete_sale_operation para compensar) se miran los
-- movimientos de caja type 'sale' (la sucursal de la caja de su sesión) y los
-- bancarios (source_doc_type 'sale', branch_id). Por construcción registran la
-- sucursal que el alta resolvió. Si alguno registra una sucursal DISTINTA del
-- origen calculado, el movimiento NO se toca y se cuenta (contradiccion). La
-- evidencia sólo VETA, nunca decide: un supuesto equivocado sólo puede producir
-- nulos, nunca un valor falso.
--
-- EXCEPCIÓN A RN-21, con sus límites. stock_movements es append-only: toda
-- corrección es un movimiento nuevo. Completar el branch_id de movimientos
-- existentes es la ÚNICA excepción (la primera fue 20261075000002, OQ-5 (c) de
-- ventas-sucursal-por-defecto) y se acota así: sólo la columna branch_id; sólo
-- movimientos type 'sale', reference_type 'sale' con branch_id IS NULL de ventas
-- VIVAS con cuenta (stock_movements.account_id nulo o igual al de la venta), con
-- una sucursal de ESA cuenta; sólo si el origen es demostrable y la caja y el banco
-- no lo contradicen. NO se toca ninguna otra columna, ni movimientos con sucursal,
-- ni los de otros tipos, ni los sin venta viva (en producción, 73: ventas borradas
-- o editadas con su contramovimiento, y los huérfanos históricos que
-- stock-movements-edicion dejó por decisión del PO). Cada id queda en la
-- auditoría, agrupado por la regla que dio su origen. CON ESTA MIGRACIÓN LA
-- EXCEPCIÓN QUEDA AGOTADA: lo que quede nulo (no fechable, contradicción, sin
-- venta viva) queda así para siempre y toda corrección futura es un movimiento
-- nuevo.
--
-- LOCKS: las ventas referenciadas se toman con FOR UPDATE en orden ascendente de id
-- (regla dura del proyecto: sales por id → sales_orders → fiscal_documents →
-- resto), la misma que usan el borrado, la edición y la promoción, así que no puede
-- entrar en deadlock con ninguno de los tres: un borrado concurrente o espera al
-- backfill (y después ve el movimiento completado, con el fallback de la reversa) o
-- lo gana y la venta ya no está viva (el backfill no toca su movimiento). NO se usa
-- LOCK TABLE. stock_movements va después ("resto"); nadie actualiza sus filas
-- (append-only), así que no hay orden que respetar entre ellas.
--
-- SIN EFECTOS LATERALES: stock_movements no tiene disparadores, así que el UPDATE
-- no dispara margen, analytics, eventos, notificaciones ni Realtime. No se escribe
-- branch_stock, sales, sales_orders, caja, banco, cuentas corrientes ni asientos;
-- la única otra tabla que se escribe es audit_logs.
--
-- POR JOIN SOBRE TABLAS TEMPORALES con clave (lección de ventas-sucursal-por-defecto:
-- las subconsultas correlacionadas por fila tardaron 6 min contra 24 s): candidatos,
-- sucursales, eventos, intervalos de estado, pares movimiento-sucursal, resultado.
--
-- TRAZABILIDAD: una fila de audit_logs por cuenta con al menos un movimiento
-- completado (action = 'stock_movements_branch_backfill', entity_type = 'account',
-- user_id NULL = sistema) con los ids, los ids por regla y los contadores.
-- REVERSIÓN exacta por id (sólo con decisión explícita del PO; no está prevista):
--   UPDATE public.stock_movements SET branch_id = NULL
--   WHERE id IN (SELECT jsonb_array_elements_text(metadata->'movement_ids')::uuid
--                FROM public.audit_logs WHERE action = 'stock_movements_branch_backfill');
--   (o por regla: metadata->'movement_ids_por_regla'->'pre_sucursal', etc.).
--
-- IDEMPOTENCIA: el WHERE branch_id IS NULL hace que una segunda corrida sólo
-- encuentre los que quedaron nulos por diseño y no escriba nada; con cero
-- completados no hay fila de auditoría. La cadena de CI la reaplica sobre la base
-- recién reconvergida y exige ' 0 movimientos completados'.
-- Gate: supabase/tests/test_stock_movimientos_sucursal_origen.sql (parte B) la
-- ejecuta con \i dos veces sobre fixtures con la historia de sucursales armada a mano.
-- =============================================================================

DO $$
DECLARE
  -- X: el fin del día en que se desplegó el registro del ciclo de vida de las sucursales.
  v_x constant timestamptz := '2026-08-26 00:00:00-03';
  v_ids            uuid[];
  v_n_done         integer := 0;
  v_n_accounts     integer := 0;
  v_pre            integer := 0;
  v_unica          integer := 0;
  v_recon          integer := 0;
  v_no_fechable    integer := 0;
  v_contradiccion  integer := 0;
  v_sin_sucursal   integer := 0;
  v_sin_cuenta     integer := 0;
  v_disc           integer := 0;
  v_dest_desact    integer := 0;
  v_dest_cerr      integer := 0;
  v_sin_venta      integer := 0;
BEGIN
  -- Tablas temporales de trabajo: se borran al final; por si una corrida anterior de la
  -- misma sesión quedó a medias, se limpian acá sin ruido de NOTICE.
  IF to_regclass('pg_temp._sso_cand')   IS NOT NULL THEN DROP TABLE _sso_cand;   END IF;
  IF to_regclass('pg_temp._sso_br')     IS NOT NULL THEN DROP TABLE _sso_br;     END IF;
  IF to_regclass('pg_temp._sso_evg')    IS NOT NULL THEN DROP TABLE _sso_evg;    END IF;
  IF to_regclass('pg_temp._sso_iv')     IS NOT NULL THEN DROP TABLE _sso_iv;     END IF;
  IF to_regclass('pg_temp._sso_pair')   IS NOT NULL THEN DROP TABLE _sso_pair;   END IF;
  IF to_regclass('pg_temp._sso_pick')   IS NOT NULL THEN DROP TABLE _sso_pick;   END IF;
  IF to_regclass('pg_temp._sso_res')    IS NOT NULL THEN DROP TABLE _sso_res;    END IF;
  IF to_regclass('pg_temp._sso_keys')   IS NOT NULL THEN DROP TABLE _sso_keys;   END IF;
  IF to_regclass('pg_temp._sso_cashev') IS NOT NULL THEN DROP TABLE _sso_cashev; END IF;
  IF to_regclass('pg_temp._sso_bankev') IS NOT NULL THEN DROP TABLE _sso_bankev; END IF;
  IF to_regclass('pg_temp._sso_done')   IS NOT NULL THEN DROP TABLE _sso_done;   END IF;

  -- ─── 1. Ventas candidatas, bloqueadas en orden ascendente de id ─────────────
  SELECT COALESCE(array_agg(l.id ORDER BY l.id), '{}'::uuid[]) INTO v_ids
  FROM (
    SELECT s.id
    FROM   public.sales s
    WHERE  s.account_id IS NOT NULL
      AND  s.id IN (SELECT sm.reference_id FROM public.stock_movements sm
                    WHERE sm.type = 'sale' AND sm.reference_type = 'sale' AND sm.branch_id IS NULL)
    ORDER  BY s.id
    FOR UPDATE
  ) l;

  IF COALESCE(array_length(v_ids, 1), 0) > 0 THEN
    -- ─── 2. Movimientos candidatos (venta viva con cuenta; la cuenta del movimiento
    --        es nula o la misma que la de la venta) ─────────────────────────────
    CREATE TEMP TABLE _sso_cand (
      movement_id uuid PRIMARY KEY,
      sale_id     uuid NOT NULL,
      account_id  uuid NOT NULL,
      sale_branch uuid,
      t           timestamptz,
      op_key      uuid NOT NULL     -- COALESCE(operation_id, id): una fila legacy es su propia operación
    );
    INSERT INTO _sso_cand (movement_id, sale_id, account_id, sale_branch, t, op_key)
    SELECT sm.id, s.id, s.account_id, s.branch_id, sm.created_at, COALESCE(s.operation_id, s.id)
    FROM   public.stock_movements sm
    JOIN   public.sales s ON s.id = sm.reference_id AND s.id = ANY(v_ids)
    WHERE  sm.type = 'sale' AND sm.reference_type = 'sale' AND sm.branch_id IS NULL
      AND  (sm.account_id IS NULL OR sm.account_id = s.account_id);

    -- ─── 3. Sucursales de las cuentas involucradas ──────────────────────────────
    -- rnk: posición por (created_at, id); tied: otra sucursal de la cuenta comparte
    -- created_at (c26_default_branch no desempata).
    CREATE TEMP TABLE _sso_br (
      branch_id  uuid PRIMARY KEY,
      account_id uuid        NOT NULL,
      created_at timestamptz NOT NULL,
      is_active  boolean     NOT NULL,
      status     text        NOT NULL,
      closed_at  timestamptz,
      rnk        integer     NOT NULL,
      tied       boolean     NOT NULL
    );
    INSERT INTO _sso_br (branch_id, account_id, created_at, is_active, status, closed_at, rnk, tied)
    SELECT b.id, b.account_id, b.created_at, b.is_active, b.status, b.closed_at,
           row_number() OVER (PARTITION BY b.account_id ORDER BY b.created_at, b.id),
           (count(*) OVER (PARTITION BY b.account_id, b.created_at) > 1)
    FROM   public.branches b
    WHERE  b.account_id IN (SELECT DISTINCT c.account_id FROM _sso_cand c);
    CREATE INDEX ON _sso_br (account_id, rnk);

    -- ─── 4. Eventos de ciclo de vida que CAMBIARON el estado operativo ──────────
    -- Uno por (sucursal, instante). ab/sb = estado previo; NULL si los eventos de ese
    -- instante se contradicen (se compara el TEXTO: sin casts que puedan abortar).
    CREATE TEMP TABLE _sso_evg (
      branch_id uuid        NOT NULL,
      at        timestamptz NOT NULL,
      ab        boolean,
      sb        text,
      PRIMARY KEY (branch_id, at)
    );
    INSERT INTO _sso_evg (branch_id, at, ab, sb)
    SELECT g.branch_id, g.at,
           CASE WHEN g.ab_min = g.ab_max AND g.sb_min = g.sb_max THEN (g.ab_min = 'true') END,
           CASE WHEN g.ab_min = g.ab_max AND g.sb_min = g.sb_max THEN g.sb_min END
    FROM (
      SELECT e.entity_id AS branch_id, e.created_at AS at,
             MIN(e.metadata->>'is_active_before') AS ab_min, MAX(e.metadata->>'is_active_before') AS ab_max,
             MIN(e.metadata->>'status_before')    AS sb_min, MAX(e.metadata->>'status_before')    AS sb_max
      FROM   public.audit_logs e
      WHERE  e.entity_type = 'branch'
        AND  e.account_id IN (SELECT DISTINCT b.account_id FROM _sso_br b)
        AND  e.entity_id  IN (SELECT b.branch_id FROM _sso_br b)
        AND  (e.metadata->>'is_active_before') IN ('true', 'false')
        AND  (e.metadata->>'status_before') IS NOT NULL
        AND  ((e.metadata->>'is_active_before'), (e.metadata->>'status_before'))
             IS DISTINCT FROM ((e.metadata->>'is_active_after'), (e.metadata->>'status_after'))
      GROUP  BY e.entity_id, e.created_at
    ) g;

    -- ─── 5. Línea de tiempo de cada sucursal partida en intervalos abiertos ─────
    -- (lo, hi) con el estado vigente en el intervalo: antes del primer evento = estado
    -- previo del primer evento; entre el evento k y el k+1 = estado previo del k+1;
    -- después del último = el estado actual; sin eventos = el estado actual en toda la
    -- línea. Los instantes de los eventos NO pertenecen a ningún intervalo abierto.
    CREATE TEMP TABLE _sso_iv (
      branch_id uuid        NOT NULL,
      lo        timestamptz NOT NULL,
      hi        timestamptz NOT NULL,
      act       boolean,
      st        text
    );
    INSERT INTO _sso_iv (branch_id, lo, hi, act, st)
    WITH grp AS (
      SELECT g.branch_id, g.at, g.ab, g.sb,
             row_number() OVER (PARTITION BY g.branch_id ORDER BY g.at) AS rn,
             count(*)     OVER (PARTITION BY g.branch_id)               AS n
      FROM   _sso_evg g
    )
    SELECT g.branch_id, '-infinity'::timestamptz, g.at, g.ab, g.sb
    FROM   grp g WHERE g.rn = 1
    UNION ALL
    SELECT g.branch_id, p.at, g.at, g.ab, g.sb
    FROM   grp g JOIN grp p ON p.branch_id = g.branch_id AND p.rn = g.rn - 1
    UNION ALL
    SELECT g.branch_id, g.at, 'infinity'::timestamptz, b.is_active, b.status
    FROM   grp g JOIN _sso_br b ON b.branch_id = g.branch_id WHERE g.rn = g.n
    UNION ALL
    SELECT b.branch_id, '-infinity'::timestamptz, 'infinity'::timestamptz, b.is_active, b.status
    FROM   _sso_br b WHERE NOT EXISTS (SELECT 1 FROM _sso_evg g WHERE g.branch_id = b.branch_id);
    CREATE INDEX ON _sso_iv (branch_id);

    ANALYZE _sso_cand;
    ANALYZE _sso_br;
    ANALYZE _sso_evg;
    ANALYZE _sso_iv;

    -- ─── 6. Pares movimiento × sucursal de S(T), con el estado operativo en T ───
    -- op: TRUE operaba, FALSE no operaba, NULL desconocido.
    CREATE TEMP TABLE _sso_pair (
      movement_id uuid    NOT NULL,
      branch_id   uuid    NOT NULL,
      rnk         integer NOT NULL,
      tied        boolean NOT NULL,
      op          boolean,
      PRIMARY KEY (movement_id, rnk)
    );
    INSERT INTO _sso_pair (movement_id, branch_id, rnk, tied, op)
    SELECT c.movement_id, b.branch_id, b.rnk, b.tied,
           CASE
             -- un evento en el mismo instante que el movimiento, o eventos contradictorios: desconocido
             WHEN pt.branch_id IS NOT NULL OR iv.act IS NULL OR iv.st IS NULL THEN NULL
             -- T >= X: el rebobinado es exacto
             WHEN c.t >= v_x THEN (iv.act AND iv.st = 'active')
             -- T < X: sólo se afirma lo que no pudo cambiar sin dejar rastro
             WHEN iv.act AND iv.st = 'active' AND b.closed_at IS NULL THEN TRUE
             ELSE NULL
           END
    FROM   _sso_cand c
    JOIN   _sso_br b ON b.account_id = c.account_id AND b.created_at <= c.t
    LEFT   JOIN _sso_iv  iv ON iv.branch_id = b.branch_id AND c.t > iv.lo AND c.t < iv.hi
    LEFT   JOIN _sso_evg pt ON pt.branch_id = b.branch_id AND pt.at = c.t;
    ANALYZE _sso_pair;

    -- ─── 7. Resolución por movimiento ───────────────────────────────────────────
    CREATE TEMP TABLE _sso_res (
      movement_id uuid PRIMARY KEY,
      account_id  uuid NOT NULL,
      sale_id     uuid NOT NULL,
      op_key      uuid NOT NULL,
      sale_branch uuid,
      n           integer NOT NULL,   -- |S(T)|
      rule        text,               -- pre_sucursal | unica | reconstruida
      branch_id   uuid,               -- el origen
      reason      text                -- sin_sucursal | no_fechable | contradiccion
    );
    INSERT INTO _sso_res (movement_id, account_id, sale_id, op_key, sale_branch, n)
    SELECT c.movement_id, c.account_id, c.sale_id, c.op_key, c.sale_branch, COALESCE(p.n, 0)
    FROM   _sso_cand c
    LEFT   JOIN (SELECT pr.movement_id, COUNT(*)::integer AS n FROM _sso_pair pr GROUP BY pr.movement_id) p
           ON p.movement_id = c.movement_id;

    -- cuenta sin ninguna sucursal
    UPDATE _sso_res r SET reason = 'sin_sucursal'
    WHERE  NOT EXISTS (SELECT 1 FROM _sso_br b WHERE b.account_id = r.account_id);
    -- created_at nulo: no se puede fechar
    UPDATE _sso_res r SET reason = 'no_fechable'
    FROM   _sso_cand c
    WHERE  c.movement_id = r.movement_id AND c.t IS NULL AND r.reason IS NULL;

    -- pre_sucursal: S(T) vacío -> la más antigua de la cuenta (rnk = 1)
    UPDATE _sso_res r SET
           rule      = CASE WHEN NOT b.tied THEN 'pre_sucursal' END,
           branch_id = CASE WHEN NOT b.tied THEN b.branch_id END,
           reason    = CASE WHEN b.tied THEN 'no_fechable' END
    FROM   _sso_br b
    WHERE  b.account_id = r.account_id AND b.rnk = 1
      AND  r.n = 0 AND r.reason IS NULL;

    -- unica: S(T) con una sola -> esa (la más antigua: rnk = 1), opere o no hoy
    UPDATE _sso_res r SET rule = 'unica', branch_id = b.branch_id
    FROM   _sso_br b
    WHERE  b.account_id = r.account_id AND b.rnk = 1
      AND  r.n = 1 AND r.reason IS NULL;

    -- reconstruida: S(T) con dos o más -> la primera que operaba en T; si ninguna
    -- operaba (todas constan como no operativas), la más antigua. Sólo con el estado conocido.
    CREATE TEMP TABLE _sso_pick (
      movement_id uuid PRIMARY KEY,
      r_yes       integer,   -- primera posición que operaba en T
      r_unk       integer    -- primera posición de estado desconocido
    );
    INSERT INTO _sso_pick (movement_id, r_yes, r_unk)
    SELECT p.movement_id,
           MIN(p.rnk) FILTER (WHERE p.op IS TRUE),
           MIN(p.rnk) FILTER (WHERE p.op IS NULL)
    FROM   _sso_pair p
    GROUP  BY p.movement_id;

    UPDATE _sso_res r SET
           rule      = CASE WHEN NOT pp.tied THEN 'reconstruida' END,
           branch_id = CASE WHEN NOT pp.tied THEN pp.branch_id END,
           reason    = CASE WHEN pp.tied THEN 'no_fechable' END
    FROM   _sso_pick k
    JOIN   _sso_pair pp ON pp.movement_id = k.movement_id
                       AND pp.rnk = CASE
                                      WHEN k.r_yes IS NOT NULL AND (k.r_unk IS NULL OR k.r_unk > k.r_yes) THEN k.r_yes
                                      WHEN k.r_yes IS NULL AND k.r_unk IS NULL THEN 1
                                    END
    WHERE  r.movement_id = k.movement_id AND r.n >= 2 AND r.reason IS NULL AND r.rule IS NULL;
    -- lo que no se pudo resolver (estado desconocido antes de la primera operativa, o
    -- ninguna operativa conocida con alguna desconocida)
    UPDATE _sso_res r SET reason = 'no_fechable'
    WHERE  r.n >= 2 AND r.rule IS NULL AND r.reason IS NULL;

    -- ─── 8. Veto por caja y banco de la misma operación ─────────────────────────
    CREATE TEMP TABLE _sso_keys (movement_id uuid NOT NULL, ref uuid NOT NULL);
    INSERT INTO _sso_keys (movement_id, ref)
    SELECT r.movement_id, r.op_key FROM _sso_res r WHERE r.rule IS NOT NULL
    UNION
    SELECT r.movement_id, so.id
    FROM   _sso_res r
    JOIN   public.sales_orders so ON so.sale_operation_id = r.op_key AND so.account_id = r.account_id
    WHERE  r.rule IS NOT NULL;
    CREATE INDEX ON _sso_keys (ref);

    CREATE TEMP TABLE _sso_cashev (ref uuid NOT NULL, branch_id uuid NOT NULL);
    INSERT INTO _sso_cashev (ref, branch_id)
    SELECT DISTINCT cm.reference_id, cb.branch_id
    FROM   public.cash_movements cm
    JOIN   public.cash_sessions cs ON cs.id = cm.session_id
    JOIN   public.cashboxes cb ON cb.id = cs.cashbox_id
    WHERE  cm.movement_type = 'sale'
      AND  cm.reference_id IN (SELECT k.ref FROM _sso_keys k);
    CREATE INDEX ON _sso_cashev (ref);

    CREATE TEMP TABLE _sso_bankev (ref uuid NOT NULL, branch_id uuid NOT NULL);
    INSERT INTO _sso_bankev (ref, branch_id)
    SELECT DISTINCT bm.source_doc_ref, bm.branch_id
    FROM   public.bank_movements bm
    WHERE  bm.source_doc_type = 'sale' AND bm.branch_id IS NOT NULL
      AND  bm.source_doc_ref IN (SELECT k.ref FROM _sso_keys k);
    CREATE INDEX ON _sso_bankev (ref);

    ANALYZE _sso_keys;
    ANALYZE _sso_cashev;
    ANALYZE _sso_bankev;

    UPDATE _sso_res r SET reason = 'contradiccion', rule = NULL, branch_id = NULL
    WHERE  r.rule IS NOT NULL AND (
             EXISTS (SELECT 1 FROM _sso_keys k JOIN _sso_cashev e ON e.ref = k.ref
                     WHERE  k.movement_id = r.movement_id AND e.branch_id <> r.branch_id)
          OR EXISTS (SELECT 1 FROM _sso_keys k JOIN _sso_bankev e ON e.ref = k.ref
                     WHERE  k.movement_id = r.movement_id AND e.branch_id <> r.branch_id));

    -- ─── 9. Escritura (la ÚNICA sobre stock_movements) ──────────────────────────
    CREATE TEMP TABLE _sso_done (
      movement_id uuid PRIMARY KEY,
      account_id  uuid NOT NULL,
      rule        text NOT NULL,
      branch_id   uuid NOT NULL,
      sale_branch uuid
    );
    WITH upd AS (
      UPDATE public.stock_movements sm
      SET    branch_id = r.branch_id
      FROM   _sso_res r
      WHERE  sm.id = r.movement_id
        AND  sm.type = 'sale' AND sm.reference_type = 'sale' AND sm.branch_id IS NULL
        AND  r.rule IS NOT NULL
      RETURNING sm.id, r.account_id, r.rule, r.branch_id, r.sale_branch
    )
    INSERT INTO _sso_done (movement_id, account_id, rule, branch_id, sale_branch)
    SELECT id, account_id, rule, branch_id, sale_branch FROM upd;
    ANALYZE _sso_done;

    -- ─── 10. Auditoría: una fila por cuenta con movimientos completados ─────────
    INSERT INTO public.audit_logs (user_id, action, account_id, entity_type, entity_id, metadata)
    SELECT NULL, 'stock_movements_branch_backfill', g.account_id, 'account', g.account_id,
           jsonb_build_object(
             'change', 'stock-movimientos-sucursal-origen',
             'movement_ids', g.movement_ids,
             'movement_ids_por_regla', jsonb_build_object(
               'pre_sucursal', COALESCE(g.ids_pre,   '[]'::jsonb),
               'unica',        COALESCE(g.ids_unica, '[]'::jsonb),
               'reconstruida', COALESCE(g.ids_recon, '[]'::jsonb)),
             'no_fechable',         COALESCE(n.no_fechable, 0),
             'contradiccion',       COALESCE(n.contradiccion, 0),
             'discrepancia_venta',  g.n_disc,
             'destino_desactivado', g.n_desact,
             'destino_cerrado',     g.n_cerr,
             'branch_ids',          g.branch_ids)
    FROM (
      SELECT d.account_id,
             jsonb_agg(d.movement_id ORDER BY d.movement_id)                                         AS movement_ids,
             jsonb_agg(d.movement_id ORDER BY d.movement_id) FILTER (WHERE d.rule = 'pre_sucursal') AS ids_pre,
             jsonb_agg(d.movement_id ORDER BY d.movement_id) FILTER (WHERE d.rule = 'unica')        AS ids_unica,
             jsonb_agg(d.movement_id ORDER BY d.movement_id) FILTER (WHERE d.rule = 'reconstruida') AS ids_recon,
             jsonb_agg(DISTINCT d.branch_id)                                                         AS branch_ids,
             COUNT(*) FILTER (WHERE d.sale_branch IS NOT NULL AND d.sale_branch <> d.branch_id)     AS n_disc,
             COUNT(*) FILTER (WHERE NOT b.is_active)                                                 AS n_desact,
             COUNT(*) FILTER (WHERE b.is_active AND b.status = 'closed')                             AS n_cerr
      FROM   _sso_done d
      JOIN   _sso_br b ON b.branch_id = d.branch_id
      GROUP  BY d.account_id
    ) g
    LEFT JOIN (
      SELECT r.account_id,
             COUNT(*) FILTER (WHERE r.reason = 'no_fechable')   AS no_fechable,
             COUNT(*) FILTER (WHERE r.reason = 'contradiccion') AS contradiccion
      FROM   _sso_res r
      GROUP  BY r.account_id
    ) n ON n.account_id = g.account_id;

    -- ─── 11. Totales para el NOTICE ─────────────────────────────────────────────
    SELECT COUNT(*), COUNT(DISTINCT d.account_id),
           COUNT(*) FILTER (WHERE d.rule = 'pre_sucursal'),
           COUNT(*) FILTER (WHERE d.rule = 'unica'),
           COUNT(*) FILTER (WHERE d.rule = 'reconstruida'),
           COUNT(*) FILTER (WHERE d.sale_branch IS NOT NULL AND d.sale_branch <> d.branch_id),
           COUNT(*) FILTER (WHERE NOT b.is_active),
           COUNT(*) FILTER (WHERE b.is_active AND b.status = 'closed')
    INTO   v_n_done, v_n_accounts, v_pre, v_unica, v_recon, v_disc, v_dest_desact, v_dest_cerr
    FROM   _sso_done d
    JOIN   _sso_br b ON b.branch_id = d.branch_id;

    SELECT COUNT(*) FILTER (WHERE r.reason = 'no_fechable'),
           COUNT(*) FILTER (WHERE r.reason = 'contradiccion'),
           COUNT(*) FILTER (WHERE r.reason = 'sin_sucursal')
    INTO   v_no_fechable, v_contradiccion, v_sin_sucursal
    FROM   _sso_res r;

    DROP TABLE _sso_done;
    DROP TABLE _sso_bankev;
    DROP TABLE _sso_cashev;
    DROP TABLE _sso_keys;
    DROP TABLE _sso_pick;
    DROP TABLE _sso_res;
    DROP TABLE _sso_pair;
    DROP TABLE _sso_iv;
    DROP TABLE _sso_evg;
    DROP TABLE _sso_br;
    DROP TABLE _sso_cand;
  END IF;

  -- ─── 12. Residuo que no se toca (nunca aborta) ───────────────────────────────
  -- ventas sin cuenta, o movimiento que declara otra cuenta distinta de la de la venta
  SELECT COUNT(*) INTO v_sin_cuenta
  FROM   public.stock_movements sm
  JOIN   public.sales s ON s.id = sm.reference_id
  WHERE  sm.type = 'sale' AND sm.reference_type = 'sale' AND sm.branch_id IS NULL
    AND  (s.account_id IS NULL OR (sm.account_id IS NOT NULL AND sm.account_id <> s.account_id));
  -- movimientos 'sale' nulos SIN venta viva: no se tocan (OQ-C)
  SELECT COUNT(*) INTO v_sin_venta
  FROM   public.stock_movements sm
  WHERE  sm.type = 'sale' AND sm.reference_type = 'sale' AND sm.branch_id IS NULL
    AND  NOT EXISTS (SELECT 1 FROM public.sales s WHERE s.id = sm.reference_id);

  RAISE NOTICE 'stock-movimientos-sucursal-origen (backfill): % movimientos completados en % cuentas; por regla %',
    v_n_done, v_n_accounts,
    jsonb_build_object('pre_sucursal', v_pre, 'unica', v_unica, 'reconstruida', v_recon);
  RAISE NOTICE 'stock-movimientos-sucursal-origen (backfill): nulos que quedan por motivo: % no fechables, % contradichos por caja o banco, % de venta sin cuenta o de otra cuenta, % de cuentas sin sucursales',
    v_no_fechable, v_contradiccion, v_sin_cuenta, v_sin_sucursal;
  RAISE NOTICE 'stock-movimientos-sucursal-origen (backfill): % movimientos con la venta en otra sucursal (discrepancia); destinos hoy: % desactivados, % cerrados',
    v_disc, v_dest_desact, v_dest_cerr;
  RAISE NOTICE 'stock-movimientos-sucursal-origen (backfill): % movimientos sale nulos sin venta viva (no se tocan, OQ-C)', v_sin_venta;
END $$;
