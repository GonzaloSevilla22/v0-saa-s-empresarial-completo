-- =============================================================================
-- sucursal-guard-vaciado-auditoria — G1 (guard de vaciado) + G2 (autoría)
-- =============================================================================
--
-- EL INCIDENTE (22→24-08-2026). Una usuaria owner creó dos sucursales y
-- desactivó la sucursal original desde la papelera de /sucursales. Tenía 518
-- productos / 585 unidades adentro. El sistema aceptó la baja sin verificar
-- nada. La sucursal por defecto de la cuenta se resuelve como "la más antigua
-- ACTIVA y ABIERTA" (c26_default_branch): al quedar la original inactiva,
-- TODAS las ventas empezaron a resolver contra una sucursal nueva con 13
-- productos, y el resto del inventario quedó existente pero inalcanzable —
-- invendible durante DOS DÍAS, mientras /stock seguía mostrando el total del
-- catálogo (agregado, no por sucursal). Reparado a mano el 24-08.
--
-- CUATRO CAMINOS DE BAJA, UN SOLO GUARD MAL UBICADO (verificado en prod al
-- proponer): rpc_deactivate_branch (el que usó la usuaria — SIN guard),
-- rpc_close_branch (CON guard, pero nadie lo usó), BranchRepository.update
-- (actualización directa del backend — SIN guard, hoy no llega a is_active
-- porque el schema de entrada sólo admite `name`, pero la query es genérica),
-- y la escritura directa desde el navegador vía RLS (branches_writer_update /
-- branches_writer_delete — SIN guard, UPDATE y DELETE habilitados para
-- owner/admin). Sólo uno de los cuatro verificaba algo, y no era el que se
-- usó. Por eso el guard va en un DISPARADOR sobre la tabla (D1): es el único
-- punto que atraviesan los cuatro, presentes y futuros — mismo patrón que el
-- guard de tenencia de cuenta corriente (choke point + defensa en profundidad
-- en los comandos) y el guard de borrado de productos de soft-delete
-- (fn_guard_product_soft_delete, disparador SECURITY DEFINER sobre products,
-- 20260811000001).
--
-- EL BORRADO FÍSICO SE PROHÍBE SIEMPRE (D4, incondicional — OQ-2 resuelta por
-- la recomendación). Las FKs de branches se reparten en CASCADE (branch_stock,
-- cashboxes, ambos extremos de stock_transfers — se borrarían sin dejar
-- rastro), ANULACIÓN (sales/purchases/expenses/stock_movements — pierden la
-- imputación) y SIN ACCIÓN (sales_orders, bank_movements — revientan con un
-- error de integridad ilegible). La política de borrado ya adoptada
-- (v3-soft-delete-policy, D6 de su design) YA excluye a branches del soft
-- delete de maestros — "se desactiva, no se borra" — pero hasta hoy era una
-- frase sin cumplimiento. Este archivo se lo da.
--
-- LAS 7 OQs DEL DESIGN — resueltas TODAS por su recomendación (PO firmó el
-- alcance G1/G2/G3, viene aprobando las recomendadas; sign-off registrado en
-- CHANGES.md):
--   OQ-1 bloquear stock + caja abierta + transferencias en vuelo (D2) — SÍ,
--        las tres, mismo costo que sólo stock y evita dos clases de basura
--        reparable sólo por consola.
--   OQ-2 borrado físico prohibido siempre — SÍ (D4), aplica la política ya
--        adoptada.
--   OQ-3 "vaciar y desactivar" en un paso — NO en este change (producto
--        nuevo: elegir destino, resolver conflictos, confirmar en bloque).
--   OQ-4 autoría visible a TODOS los miembros de la cuenta (frontend, no
--        toca este archivo).
--   OQ-5 desglose por sucursal en /stock (candidato propio, CHANGES.md).
--   OQ-6 aviso al cambiar la sucursal por defecto (candidato propio,
--        CHANGES.md).
--   OQ-7 `anon` tiene DELETE/UPDATE a nivel TABLA sobre `branches` — mismo
--        hallazgo lateral que el h3 abierto de cuenta-corriente-party-guard.
--        Revalidado en el apply: RLS en `branches` exige membresía
--        (`branches_member_select`) y rol writer (`branches_writer_*`), y
--        `anon` no resuelve identidad ⇒ ninguna policy le da una fila. El
--        REVOKE es seguro: ningún camino legítimo depende de que `anon`
--        tenga privilegios de tabla (el frontend nunca opera sin sesión, y el
--        backend corre como `authenticated` desde el Paso 2 de tenencia,
--        encendido en prod desde el 24-08). Se REVOCA en la sección 8 de
--        este mismo archivo — INSERT/UPDATE/DELETE/TRUNCATE (se conserva
--        SELECT/REFERENCES/TRIGGER, que no exponen nada sin RLS-passing y
--        cuya revocación no está pedida ni auditada acá).
--
-- REVALIDACIÓN EN PROD AL APPLY (2026-08-25, sesión de este change — grupo 1
-- de tasks):
--   · MAX(version) = 20261013000001 / 262 filas — IDÉNTICO a lo verificado al
--     proponer. Sin sesiones paralelas del PO en el medio. Este archivo nace
--     como 20261014000001.
--   · Censo de ERRCODEs (repo completo + pg_proc.prosrc VIVO de las ~250
--     funciones public): P0428 sigue LIBRE en los dos frentes. Ocupados en
--     vivo confirmados: P0001-2, P0400-1, P0403-4, P0409-14, P0422-26,
--     P0431-34, P0450-51 (idéntico al censo del propose).
--   · Auditoría de daño histórico: 40 sucursales, 2 inactivas, 0 cerradas,
--     **0** inactivas/cerradas con existencias — IDÉNTICO al propose. No hay
--     reparación pendiente; el guard entra en un parque limpio.
--   · Permisos sobre `branches`: a nivel TABLA (no por columna) para
--     `anon`/`authenticated`/`postgres`/`service_role` — confirmado con
--     information_schema.role_table_grants. Las 3 columnas nuevas de la
--     sección 1 quedan cubiertas automáticamente por el grant de tabla; no
--     hace falta emitir nada por columna.
--   · Barrido de escritores de `public.branches` (grupo 2 de tasks, vía
--     pg_get_functiondef VIVO, no grep): sólo 6 funciones tocan la tabla —
--     rpc_deactivate_branch (UPDATE is_active), rpc_close_branch (UPDATE
--     status), rpc_open_branch (UPDATE status — NO es un camino de "baja",
--     no se toca), rpc_create_branch (INSERT), c21_apply_branch_stock_delta
--     (INSERT, alta perezosa) y handle_new_user (INSERT 'Casa Central', alta
--     perezosa del signup). Los dos INSERT de sistema NO los alcanza el
--     disparador (BEFORE UPDATE OR DELETE, no INSERT) — verificado, no
--     razonado. Ninguna otra función viva escribe sobre `branches`
--     (confirmado: `check_branch_low_stock`, `rpc_open_cash_session`,
--     `rpc_close_cash_session`, `c28_register_cash_movement`,
--     `rpc_soft_delete_cashbox` sólo la LEEN vía JOIN). El código de
--     aplicación: `BranchRepository.update` (genérico, hoy sólo admite
--     `name` desde el schema Pydantic, pero cruza igual el disparador si se
--     ampliara) y la escritura directa del navegador vía RLS — ambos cubiertos
--     por ser el disparador el choke point real.
--
-- BASELINE VIVO (gate de integridad de función — 6 antecedentes de reescribir
-- desde el archivo local y perder bloques). Capturado con pg_get_functiondef
-- VIVO de prod el 2026-08-25 en
-- openspec/changes/sucursal-guard-vaciado-auditoria/baseline/:
--   rpc_deactivate_branch(uuid), rpc_close_branch(uuid),
--   rpc_open_branch(uuid), rpc_create_branch(uuid,text,text),
--   c26_default_branch(uuid), c21_apply_branch_stock_delta(uuid,uuid,uuid,numeric).
-- rpc_open_branch y c26_default_branch/c21_apply_branch_stock_delta se
-- capturan por completitud del barrido pero NO se tocan en este archivo (no
-- son caminos de "baja"). Las tres funciones que SÍ se redefinen abajo
-- (rpc_deactivate_branch, rpc_close_branch, rpc_create_branch) parten
-- LITERALMENTE del cuerpo vivo capturado — la única diferencia contra el
-- baseline es el bloque de guard/autoría marcado en cada una.
--
-- DECISIONES DEL DESIGN aplicadas:
--   D1 — El guard vive en un disparador BEFORE UPDATE OR DELETE sobre
--        public.branches (autosuficiente: no delega en ningún chequeo
--        posterior). Los comandos conservan su propia verificación como
--        defensa en profundidad.
--   D2 — "Vacía" = existencias (branch_stock, predicado `<> 0`, NO `> 0` —
--        una cantidad negativa por anomalía DEBE bloquear) + sesión de caja
--        abierta + transferencias sin completar. Orden de evaluación: 1)
--        existencias, 2) caja, 3) transferencias.
--   D3 — Un solo código nuevo, P0428 → 409. El cierre conserva el token de
--        texto `branch_has_stock` que el cliente ya traduce por texto (no por
--        código): `translateRpcError` en frontend/hooks/data/use-branches.ts
--        sigue funcionando sin tocarla.
--   D4 — El DELETE se rechaza SIEMPRE, con o sin contenido.
--   D5 — Los comandos informan (mensaje más rico, se ejecuta antes que su
--        propia lógica de negocio adicional); el disparador garantiza (última
--        red, cubre lo que los comandos no cubren). El predicado de contenido
--        se escribe UNA vez (`_branch_blocking_content`) y lo consumen el
--        disparador y los dos comandos vía `_branch_assert_empty`, que
--        también centraliza el mensaje — así "mismo vocabulario" no depende
--        de mantener 3 redacciones sincronizadas a mano.
--   D6 — Columnas `created_by`/`deactivated_at`/`deactivated_by` sobre
--        `branches` (referencia lógica, SIN FK dura — mismo patrón que
--        `deleted_by` y `stock_transfers.created_by`). SIN `deleted_at`/
--        `deleted_by` (v3-soft-delete-policy excluye branches a propósito) ni
--        `updated_by` (una columna sólo retiene al último editor; "quién
--        cambió el nombre" lo contesta el log). SIN backfill: las 40
--        sucursales existentes quedan con autoría NULL, documentado en el
--        COMMENT y mostrado como "no registrado" en la interfaz (frontend).
--        El ciclo de vida completo (alta/edición/baja/reactivación/
--        cierre/apertura) queda en `audit_logs` vía un SEGUNDO disparador
--        AFTER INSERT OR UPDATE — es el único choke point que también cubre
--        la EDICIÓN (que hoy pasa por `BranchRepository.update`, un UPDATE
--        genérico sin RPC dedicada) sin duplicar lógica de detección de
--        acción en 3 lugares.
--
-- SIN CAMBIO DE FIRMA en ninguna de las 3 funciones redefinidas
-- (rpc_deactivate_branch(uuid), rpc_close_branch(uuid),
-- rpc_create_branch(uuid,text,text)) ⇒ CREATE OR REPLACE puro, sin DROP, sin
-- riesgo de overload 42725 (gate anti-overload en la sección 10).
--
-- CORRECCIÓN MEDIDA CONTRA LOCAL (verificación de este mismo apply, no
-- razonada): el propose asumía —por `has_function_privilege` = false en prod
-- para `fn_guard_product_soft_delete`/`c26_default_branch` sin REVOKE
-- explícito— que el schema no otorga EXECUTE por default a PUBLIC. FALSO: un
-- `supabase db reset` local mostró que las 4 funciones nuevas de este
-- archivo SÍ nacían ejecutables por `anon`/`authenticated` (PostgREST expone
-- por default toda función `public`, igual que documentan los advisors
-- 0028/0029 del proyecto). Las funciones viejas que hoy aparecen cerradas en
-- prod lo están por un REVOKE puntual posterior de algún change de
-- endurecimiento (varios migran por la cadena:
-- `20260818000001_revoke_guard_fn_execute.sql`,
-- `20260822000001_revoke_trigger_only_fn_execute.sql`, etc.), no por un
-- default del schema. Las 4 funciones nuevas (`_branch_blocking_content`,
-- `_branch_assert_empty`, `fn_guard_branch_decommission`,
-- `fn_audit_branch_lifecycle`) llevan su propio `REVOKE ALL … FROM PUBLIC,
-- anon, authenticated` explícito — los disparadores NO lo necesitan para
-- dispararse (Postgres no chequea EXECUTE al disparar un trigger), pero SÍ
-- para no quedar invocables directo como RPC fuera de su contexto (NEW/OLD/
-- TG_OP indefinidos). El gate de la sección 10, chequeo (e), lo verifica.
--
-- Idempotente: `ADD COLUMN IF NOT EXISTS`, `CREATE OR REPLACE`,
-- `DROP TRIGGER IF EXISTS` + `CREATE TRIGGER`, `REVOKE`/`GRANT`/`COMMENT`
-- absolutos. Verificado con triple aplicación en local (secciones 1-8 sin
-- error y sin cambio de fingerprint de cuerpos/ACLs/comments/trigger defs).
--
-- ORDEN EN CI: este archivo se suma como ÚLTIMO eslabón de la cadena de
-- reapply del step "Verify G1/G4 migrations are idempotent on reapply" de
-- .github/workflows/KPI_Validation.yml (mismo motivo que los eslabones
-- anteriores: verificar la propia idempotencia del archivo en CI, no sólo en
-- local). No comparte ninguna función con los eslabones previos de esa
-- cadena — `branches` no había sido tocada por ningún change anterior de la
-- cadena — así que el orden relativo a ellos no genera phantom regression;
-- se agrega al final por convención, no por precondición dura.
--
-- GOVERNANCE: MEDIO (design.md, gobernanza del propio change). Toca
-- inventario y ciclo de vida de sucursal; no toca dinero ni autorización.
--
-- APPLY: npx supabase db push  (NUNCA MCP apply_migration)
-- ROLLBACK (aditivo — en prod NO se revierte, se desactiva el disparador):
--   DROP TRIGGER IF EXISTS trg_guard_branch_decommission ON public.branches;
--   DROP TRIGGER IF EXISTS trg_audit_branch_lifecycle ON public.branches;
--   -- las columnas created_by/deactivated_at/deactivated_by quedan inertes;
--   -- rpc_deactivate_branch/rpc_close_branch/rpc_create_branch quedan con el
--   -- guard/autoría escritos pero inofensivos si el disparador no está.
-- =============================================================================


-- =============================================================================
-- 1. Columnas de autoría (D6). Sin backfill — declarado, no accidental.
-- =============================================================================

ALTER TABLE public.branches
  ADD COLUMN IF NOT EXISTS created_by     uuid NULL,
  ADD COLUMN IF NOT EXISTS deactivated_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS deactivated_by uuid NULL;

COMMENT ON COLUMN public.branches.created_by IS
  'sucursal-guard-vaciado-auditoria (G2, D6): quién dio de alta la sucursal. '
  'Referencia LÓGICA a auth.users.id — sin FK dura, mismo patrón que '
  'deleted_by y stock_transfers.created_by. NULL en dos casos DISTINTOS que '
  'no deben leerse igual: (1) sucursales creadas ANTES de este cambio — no '
  'hay backfill posible, no se puede inventar quién creó una fila de hace '
  'meses; (2) altas de CAMINO DE SISTEMA — la sucursal default perezosa que '
  'c21_apply_branch_stock_delta y handle_new_user crean automáticamente al '
  'primer movimiento de stock / signup de una cuenta nueva — deliberadamente '
  'NULL porque no hay una persona detrás. La interfaz muestra ambos casos '
  'como "no registrado".';

COMMENT ON COLUMN public.branches.deactivated_at IS
  'sucursal-guard-vaciado-auditoria (G2, D6): momento de la desactivación '
  '(is_active TRUE→FALSE). NULL en sucursales activas y en las inactivas '
  'preexistentes a este cambio (sin backfill). Vocabulario de la baja LÓGICA '
  '(is_active) — no confundir con closed_at, que es del ciclo OPERACIONAL '
  '(status). Esta sucursal NO tiene deleted_at: v3-soft-delete-policy excluye '
  'a branches del borrado lógico de maestros a propósito (se desactiva, no '
  'se borra) — deactivated_at/deactivated_by son el equivalente exacto '
  'dentro del vocabulario que la entidad ya usa.';

COMMENT ON COLUMN public.branches.deactivated_by IS
  'sucursal-guard-vaciado-auditoria (G2, D6): quién desactivó la sucursal. '
  'Referencia LÓGICA a auth.users.id — sin FK dura. NULL en sucursales '
  'activas y en las inactivas preexistentes (sin backfill, mismo criterio '
  'que created_by). Se completa siempre junto con deactivated_at, dentro de '
  'la misma transacción de rpc_deactivate_branch. NO existe un updated_by '
  'general: una columna sólo retiene al último editor y no dice QUÉ cambió — '
  '"quién le cambió el nombre" lo contesta audit_logs (sección 5 de este '
  'archivo), no una columna.';


-- =============================================================================
-- 2. _branch_blocking_content — lectura ÚNICA del contenido bloqueante
--    (D2, D5). Pura: no escribe nada, no recalcula stock, no toca products.
--    SECURITY DEFINER: debe poder leer branch_stock/cash_sessions/
--    stock_transfers aunque el caller no las vea por RLS (mismo racional que
--    fn_guard_product_soft_delete, 20260811000001).
-- =============================================================================

CREATE OR REPLACE FUNCTION public._branch_blocking_content(p_branch_id uuid)
RETURNS TABLE (
  total_qty              numeric,
  product_count          bigint,
  cash_session_open      boolean,
  pending_transfers      bigint,
  other_active_branches  integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account_id uuid;
BEGIN
  SELECT b.account_id INTO v_account_id
  FROM public.branches b
  WHERE b.id = p_branch_id;

  RETURN QUERY
  SELECT
    -- 1) Existencias — D2: predicado `<> 0`, NO `> 0`. Lee branch_stock TAL
    -- CUAL, el ledger único de stock desde la unificación de inventario
    -- (C-21) — cero recálculo.
    COALESCE((
      SELECT SUM(bs.quantity)
      FROM public.branch_stock bs
      WHERE bs.branch_id = p_branch_id AND bs.quantity <> 0
    ), 0)::numeric,
    COALESCE((
      SELECT COUNT(*)
      FROM public.branch_stock bs
      WHERE bs.branch_id = p_branch_id AND bs.quantity <> 0
    ), 0)::bigint,
    -- 2) Sesión de caja abierta en CUALQUIER caja de la sucursal.
    EXISTS (
      SELECT 1
      FROM public.cash_sessions cs
      JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
      WHERE cb.branch_id = p_branch_id AND cs.status = 'open'
    ),
    -- 3) Transferencias sin completar con la sucursal como origen o destino.
    -- HOY stock_transfers.status tiene un CHECK que sólo admite 'completed'
    -- (20260625000001: "status nace con un solo valor... el enum habilita
    -- in-transit en el futuro sin migrar") — este predicado es DELIBERADAMENTE
    -- forward-looking: 0 filas posibles hoy, listo para cuando el enum se
    -- amplíe, sin tocar este archivo de nuevo.
    COALESCE((
      SELECT COUNT(*)
      FROM public.stock_transfers st
      WHERE (st.from_branch_id = p_branch_id OR st.to_branch_id = p_branch_id)
        AND st.status <> 'completed'
    ), 0)::bigint,
    -- Cuántas OTRAS sucursales activas tiene la cuenta — decide si el mensaje
    -- de stock ofrece "transferí" o "creá otra sucursal primero" (D2 non-goal
    -- / spec "La única sucursal de la cuenta recibe un mensaje distinto").
    COALESCE((
      SELECT COUNT(*)::integer
      FROM public.branches b2
      WHERE b2.account_id = v_account_id
        AND b2.is_active = TRUE
        AND b2.id <> p_branch_id
    ), 0);
END;
$$;

REVOKE ALL ON FUNCTION public._branch_blocking_content(uuid) FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public._branch_blocking_content(uuid) IS
  'sucursal-guard-vaciado-auditoria (G1, D2/D5): lectura ÚNICA del contenido '
  'operativo bloqueante de una sucursal — unidades y productos con '
  'quantity <> 0 en branch_stock, si hay una sesión de caja abierta en '
  'alguna de sus cajas, transferencias de stock sin completar (hoy '
  'estructuralmente imposible por el CHECK de stock_transfers.status, ver '
  'sección 2), y cuántas otras sucursales activas tiene la cuenta. Pura — no '
  'escribe nada. La usan _branch_assert_empty (sección 3), el disparador '
  '(sección 4) y los comandos rpc_deactivate_branch/rpc_close_branch '
  '(secciones 6-7): UNA sola definición del predicado, para que no existan '
  'dos redacciones susceptibles de divergir. Solo-DEFINER: sin EXECUTE para '
  'anon/authenticated.';


-- =============================================================================
-- 3. _branch_assert_empty — decide y RAISE (D2, D3, D5). Único punto que
--    construye el mensaje P0428: el disparador y los dos comandos lo llaman
--    igual, así que "mismo vocabulario de error" no depende de mantener 3
--    redacciones sincronizadas a mano.
-- =============================================================================

CREATE OR REPLACE FUNCTION public._branch_assert_empty(p_branch_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_content RECORD;
BEGIN
  SELECT * INTO v_content
  FROM public._branch_blocking_content(p_branch_id);

  -- Orden de evaluación D2: 1) existencias, 2) caja abierta, 3) transferencias.
  IF v_content.total_qty <> 0 THEN
    IF v_content.other_active_branches = 0 THEN
      -- La única sucursal activa de la cuenta: no hay a dónde transferir.
      RAISE EXCEPTION
        'branch_has_stock: la sucursal tiene % unidades en % producto(s) y es la única sucursal activa de la cuenta — creá otra sucursal para poder transferirle el stock antes de darla de baja',
        v_content.total_qty, v_content.product_count
        USING ERRCODE = 'P0428';
    ELSE
      RAISE EXCEPTION
        'branch_has_stock: la sucursal tiene % unidades en % producto(s) — transferí el stock a otra sucursal antes de darla de baja',
        v_content.total_qty, v_content.product_count
        USING ERRCODE = 'P0428';
    END IF;
  END IF;

  IF v_content.cash_session_open THEN
    RAISE EXCEPTION
      'branch_has_open_cash_session: la sucursal tiene una sesión de caja abierta — cerrala antes de darla de baja'
      USING ERRCODE = 'P0428';
  END IF;

  IF v_content.pending_transfers > 0 THEN
    RAISE EXCEPTION
      'branch_has_pending_transfers: la sucursal tiene % transferencia(s) de stock sin completar — esperá a que terminen antes de darla de baja',
      v_content.pending_transfers
      USING ERRCODE = 'P0428';
  END IF;

  -- Nada bloquea: la baja puede proceder.
END;
$$;

REVOKE ALL ON FUNCTION public._branch_assert_empty(uuid) FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public._branch_assert_empty(uuid) IS
  'sucursal-guard-vaciado-auditoria (G1, D2/D3/D5): evalúa '
  '_branch_blocking_content y RAISE P0428 (409) si hay contenido bloqueante, '
  'en el orden existencias → caja abierta → transferencias. El mensaje de '
  'existencias distingue si la cuenta tiene otra sucursal activa a la que '
  'transferir. Conserva el token de texto `branch_has_stock` que '
  'frontend/hooks/data/use-branches.ts ya traduce por TEXTO (no por código) '
  'desde que rpc_close_branch lo introdujo con P0409 — la traducción sigue '
  'funcionando sin tocarla. Llamada por el disparador (sección 4, garantiza) '
  'y por rpc_deactivate_branch/rpc_close_branch (secciones 6-7, informan '
  'antes de su propia lógica adicional) — MISMO mensaje sin importar el '
  'camino, por construcción. Solo-DEFINER: sin EXECUTE para anon/authenticated.';


-- =============================================================================
-- 4. fn_guard_branch_decommission — el disparador, choke point real (D1).
--    BEFORE UPDATE OR DELETE ON public.branches. Autosuficiente: no depende
--    de que rpc_deactivate_branch/rpc_close_branch hayan corrido antes.
--    Evalúa la TRANSICIÓN, no el estado — renombrar/reabrir/reactivar con
--    stock sigue funcionando (spec "branches" §"La verificación vive en el
--    punto de paso obligado…").
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_guard_branch_decommission()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    -- D4: incondicional. Con o sin contenido, el borrado físico está
    -- prohibido — cascada sobre branch_stock/cashboxes/stock_transfers,
    -- anulación de imputación en sales/purchases/expenses/stock_movements, y
    -- error de integridad ilegible contra sales_orders/bank_movements.
    RAISE EXCEPTION
      'branch_delete_forbidden: el borrado físico de una sucursal está prohibido — desactivala en su lugar'
      USING ERRCODE = 'P0428';
  END IF;

  -- TG_OP = 'UPDATE': sólo la TRANSICIÓN hacia la baja dispara el guard.
  IF (NEW.is_active = FALSE AND OLD.is_active = TRUE)
     OR (NEW.status = 'closed' AND OLD.status IS DISTINCT FROM 'closed') THEN
    PERFORM public._branch_assert_empty(OLD.id);
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.fn_guard_branch_decommission() IS
  'sucursal-guard-vaciado-auditoria (G1, D1): disparador BEFORE UPDATE OR '
  'DELETE sobre public.branches — el punto de paso obligado que atraviesan '
  'los 4 caminos de baja (rpc_deactivate_branch, rpc_close_branch, '
  'BranchRepository.update del backend, y la escritura directa del navegador '
  'vía RLS branches_writer_update/delete). DELETE rechaza SIEMPRE (D4, '
  'incondicional). UPDATE sólo evalúa la transición is_active TRUE→FALSE o '
  'status →closed — renombrar, cambiar dirección o reactivar con stock NO '
  'se ven afectados. Autosuficiente: llama a _branch_assert_empty '
  '(sección 3) directamente, sin depender de que el llamador haya validado '
  'nada antes. Postgres no chequea EXECUTE al DISPARAR el trigger — pero '
  'PostgREST expone por default toda función public a anon/authenticated '
  '(advisor 0028/0029; verificado empíricamente en local: una función recién '
  'creada nace con EXECUTE a PUBLIC salvo REVOKE explícito), así que se '
  'revoca abajo para que nadie pueda invocarla directo como RPC fuera de su '
  'contexto de trigger (NEW/OLD/TG_OP indefinidos).';

REVOKE ALL ON FUNCTION public.fn_guard_branch_decommission() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_guard_branch_decommission ON public.branches;
CREATE TRIGGER trg_guard_branch_decommission
  BEFORE UPDATE OR DELETE ON public.branches
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_guard_branch_decommission();


-- =============================================================================
-- 5. fn_audit_branch_lifecycle — G2: ciclo de vida completo en audit_logs
--    (D6). AFTER INSERT OR UPDATE: cubre alta, edición (incl. la que hace
--    BranchRepository.update, que no pasa por ninguna RPC dedicada),
--    desactivación, reactivación, cierre y apertura — desde UN solo choke
--    point, sin duplicar detección de "qué cambió" en cada comando. Corre
--    DESPUÉS del guard BEFORE (sección 4): si el guard rechazó, este AFTER
--    nunca se dispara — no hay auditoría de una escritura que no ocurrió.
--    Verificado: audit_logs hoy es sumidero del dispatcher del outbox con
--    entity_type NULL: la interfaz NO lo lee (las notificaciones salen de
--    `notifications`, tabla aparte) — escribir acá no genera ruido al
--    usuario ni notificaciones.
--
--    DRIFT DESCUBIERTO EN LA VERIFICACIÓN LOCAL de este mismo apply (`supabase
--    db reset`, no razonado): `entity_type`, `entity_id` y `metadata` SÍ
--    existen en `audit_logs` en prod (confirmado por SELECT directo al
--    revalidar en la sección 1), pero NINGUNA migración del historial las
--    CREA — son columnas heredadas de un esquema pre-V2 anterior al inicio
--    del tracking de migraciones (mismo patrón de drift ya documentado en
--    `20260804000006_fix_audit_logs_notnull.sql`, que asume su EXISTENCIA
--    para poder sacarles el NOT NULL). Un `supabase db reset` desde cero
--    —exactamente lo que hace CI— reconstruye `audit_logs` sólo con lo que
--    `20260517000000_ci_compat_stubs.sql` define (id/company_id/user_id/
--    action/created_at) + `account_id` de `20260718000001`, así que
--    `entity_type`/`entity_id`/`metadata` NO EXISTEN ahí — el INSERT de
--    `fn_audit_branch_lifecycle` de más abajo fallaría en CI con "column
--    does not exist" aunque funcione contra prod tal cual. Se agregan acá
--    con `ADD COLUMN IF NOT EXISTS` — no-op en prod (ya existen), las crea
--    en CI/local. Mismo criterio drift-tolerant que 20260804000006.
-- =============================================================================

ALTER TABLE public.audit_logs
  ADD COLUMN IF NOT EXISTS entity_type text,
  ADD COLUMN IF NOT EXISTS entity_id   uuid,
  ADD COLUMN IF NOT EXISTS metadata    jsonb;

CREATE OR REPLACE FUNCTION public.fn_audit_branch_lifecycle()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_action   text;
  v_metadata jsonb;
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.audit_logs
      (account_id, user_id, action, entity_type, entity_id, metadata, created_at)
    VALUES (
      NEW.account_id, NEW.created_by, 'branch.created', 'branch', NEW.id,
      jsonb_build_object('name', NEW.name, 'address', NEW.address),
      now()
    );
    RETURN NEW;
  END IF;

  -- TG_OP = 'UPDATE'. Clasificación por prioridad — is_active manda sobre
  -- status (una desactivación puede llegar acompañada de otros cambios; el
  -- caso mixto es hipotético hoy, ningún comando lo produce, pero la
  -- prioridad queda explícita para no adivinar).
  IF NEW.is_active = FALSE AND OLD.is_active = TRUE THEN
    v_action := 'branch.deactivated';
  ELSIF NEW.is_active = TRUE AND OLD.is_active = FALSE THEN
    v_action := 'branch.reactivated';
  ELSIF NEW.status = 'closed' AND OLD.status IS DISTINCT FROM 'closed' THEN
    v_action := 'branch.closed';
  ELSIF NEW.status = 'active' AND OLD.status IS DISTINCT FROM 'active' THEN
    v_action := 'branch.opened';
  ELSE
    v_action := 'branch.updated';
  END IF;

  v_metadata := jsonb_build_object(
    'name_before',      OLD.name,      'name_after',      NEW.name,
    'address_before',   OLD.address,   'address_after',   NEW.address,
    'is_active_before', OLD.is_active, 'is_active_after', NEW.is_active,
    'status_before',    OLD.status,    'status_after',    NEW.status
  );

  INSERT INTO public.audit_logs
    (account_id, user_id, action, entity_type, entity_id, metadata, created_at)
  VALUES (
    NEW.account_id, auth.uid(), v_action, 'branch', NEW.id, v_metadata, now()
  );

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.fn_audit_branch_lifecycle() IS
  'sucursal-guard-vaciado-auditoria (G2, D6): disparador AFTER INSERT OR '
  'UPDATE sobre public.branches que registra el ciclo de vida completo '
  '(alta/edición/desactivación/reactivación/cierre/apertura) en audit_logs '
  'con entity_type=''branch'', entity_id y un jsonb con el diff. Corre '
  'DESPUÉS del guard BEFORE (fn_guard_branch_decommission): una escritura '
  'rechazada nunca llega acá. NO genera notificaciones — audit_logs no lo '
  'lee la interfaz. Único choke point que también cubre la EDICIÓN de '
  'nombre/dirección hecha por BranchRepository.update (backend), que no '
  'pasa por ninguna RPC dedicada. Postgres no chequea EXECUTE al DISPARAR el '
  'trigger — pero PostgREST expone por default toda función public a '
  'anon/authenticated (advisor 0028/0029; verificado empíricamente en '
  'local), así que se revoca abajo.';

REVOKE ALL ON FUNCTION public.fn_audit_branch_lifecycle() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_audit_branch_lifecycle ON public.branches;
CREATE TRIGGER trg_audit_branch_lifecycle
  AFTER INSERT OR UPDATE ON public.branches
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_audit_branch_lifecycle();


-- =============================================================================
-- 6. rpc_deactivate_branch — CREATE OR REPLACE desde el baseline VIVO
--    (idéntico al del propose). Firma intacta: rpc_deactivate_branch(uuid).
--    Único cambio contra el baseline: el bloque de guard (llamada a
--    _branch_assert_empty) y la escritura de deactivated_at/deactivated_by.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_deactivate_branch(p_branch_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id UUID;
BEGIN
  SELECT account_id INTO v_account_id
  FROM public.branches
  WHERE id = p_branch_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found'
      USING ERRCODE = 'P0404';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized: only owner or admin can deactivate branches'
      USING ERRCODE = 'P0401';
  END IF;

  -- ╔═══ sucursal-guard-vaciado-auditoria (G1, D5) — EL COMANDO INFORMA ═════╗
  -- Mismo predicado y mismo mensaje que el disparador (sección 4): llama a
  -- _branch_assert_empty ANTES de escribir. El disparador es la garantía real
  -- (autosuficiente); esto es la capa que responde rápido con un mensaje rico
  -- sin depender de que el UPDATE de abajo falle para enterarse.
  PERFORM public._branch_assert_empty(p_branch_id);
  -- ╚══════════════════════════════════════════════════════════════════════╝

  -- sucursal-guard-vaciado-auditoria (G2, D6): autoría y momento de la baja.
  UPDATE public.branches
  SET is_active      = FALSE,
      deactivated_at = now(),
      deactivated_by = auth.uid()
  WHERE id = p_branch_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_deactivate_branch(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_deactivate_branch(uuid) TO authenticated;

COMMENT ON FUNCTION public.rpc_deactivate_branch(uuid) IS
  'C-07 (sucursales-module-pro), redefinida por sucursal-guard-vaciado-'
  'auditoria (G1/G2): desactiva una sucursal (is_active=FALSE) sólo si está '
  'vacía de contenido operativo (_branch_assert_empty, P0428 si no) y '
  'registra deactivated_at/deactivated_by. Firma sin cambios. Candado: '
  'supabase/tests/test_sucursal_guard_vaciado.sql.';


-- =============================================================================
-- 7. rpc_close_branch — CREATE OR REPLACE desde el baseline VIVO. Firma
--    intacta: rpc_close_branch(uuid). Único cambio contra el baseline: el
--    chequeo inline `IF v_stock > 0` (P0409, texto branch_has_stock) se
--    REEMPLAZA por la llamada a _branch_assert_empty (P0428, MISMO token de
--    texto branch_has_stock conservado — D3). El guard de "última sucursal
--    operativa" (v_other_active, P0409 last_active_branch) se CONSERVA TAL
--    CUAL, sin tocar — es una regla estructural distinta de "vaciado", ajena
--    al alcance de este change (task 4.8).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_close_branch(p_branch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid          uuid;
  v_account_id   uuid;
  v_branch       RECORD;
  v_other_active integer;
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
    RAISE EXCEPTION 'unauthorized: only owner or admin can close a branch'
      USING ERRCODE = 'P0401';
  END IF;

  SELECT id, status INTO v_branch
  FROM   public.branches
  WHERE  id = p_branch_id AND account_id = v_account_id AND is_active = TRUE
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found' USING ERRCODE = 'P0404';
  END IF;

  IF v_branch.status = 'closed' THEN
    RETURN jsonb_build_object('branch_id', p_branch_id, 'status', 'closed', 'changed', false);
  END IF;

  -- ╔═══ sucursal-guard-vaciado-auditoria (G1, D3/D5) — unificado a P0428 ═══╗
  -- Reemplaza el chequeo inline `IF v_stock > 0 THEN RAISE … P0409` del
  -- baseline. MISMO token de texto `branch_has_stock` (D3): la traducción
  -- existente del cliente (que matchea por texto, no por código) sigue
  -- funcionando sin tocarla. Además ahora cubre caja abierta y transferencias
  -- en vuelo, que el chequeo inline anterior no contemplaba.
  PERFORM public._branch_assert_empty(p_branch_id);
  -- ╚══════════════════════════════════════════════════════════════════════╝

  -- D6 (SIN TOCAR — task 4.8): debe quedar al menos una sucursal operativa.
  SELECT count(*) INTO v_other_active
  FROM   public.branches
  WHERE  account_id = v_account_id AND is_active = TRUE
    AND  status = 'active' AND id <> p_branch_id;

  IF v_other_active = 0 THEN
    RAISE EXCEPTION 'last_active_branch: no se puede cerrar la única sucursal operativa de la cuenta'
      USING ERRCODE = 'P0409';
  END IF;

  UPDATE public.branches
  SET    status = 'closed', closed_at = now()
  WHERE  id = p_branch_id;

  RETURN jsonb_build_object('branch_id', p_branch_id, 'status', 'closed', 'changed', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_close_branch(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_close_branch(uuid) TO authenticated;

COMMENT ON FUNCTION public.rpc_close_branch(uuid) IS
  'C-26 (branch-as-root), redefinida por sucursal-guard-vaciado-auditoria '
  '(G1): cierra operacionalmente una sucursal (status=closed) sólo si está '
  'vacía de contenido operativo (_branch_assert_empty, P0428 — token de '
  'texto branch_has_stock conservado, antes P0409) y si no es la única '
  'sucursal operativa de la cuenta (last_active_branch, P0409, SIN CAMBIOS). '
  'Firma sin cambios. Candado: '
  'supabase/tests/test_sucursal_guard_vaciado.sql.';


-- =============================================================================
-- 8. rpc_create_branch — CREATE OR REPLACE desde el baseline VIVO. Firma
--    intacta: rpc_create_branch(uuid, text, text). Único cambio: `created_by`
--    en el INSERT (D6 — "el comando de alta lo toma de la identidad en
--    curso").
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_create_branch(p_account_id uuid, p_name text, p_address text DEFAULT NULL::text)
 RETURNS branches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_plan            TEXT;
  v_max_branches    INTEGER;
  v_has_module      BOOLEAN;
  v_active_count    INTEGER;
  v_new_branch      public.branches;
BEGIN
  -- Verify caller belongs to this account
  IF NOT EXISTS (
    SELECT 1 FROM public.account_members
    WHERE account_id = p_account_id
      AND user_id    = auth.uid()
  ) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  -- Verify caller is writer (owner or admin)
  IF NOT public.is_account_writer(p_account_id) THEN
    RAISE EXCEPTION 'unauthorized: only owner or admin can create branches'
      USING ERRCODE = 'P0401';
  END IF;

  -- Get plan limits
  SELECT
    pl.max_branches,
    pl.has_branches_module
  INTO v_max_branches, v_has_module
  FROM public.accounts a
  JOIN public.plan_limits pl ON pl.plan = a.billing_plan
  WHERE a.id = p_account_id;

  IF NOT FOUND OR NOT v_has_module THEN
    RAISE EXCEPTION 'branch_limit_exceeded: branches module requires pro plan'
      USING ERRCODE = 'P0403';
  END IF;

  -- Count active branches
  SELECT COUNT(*) INTO v_active_count
  FROM public.branches
  WHERE account_id = p_account_id
    AND is_active  = TRUE;

  IF v_active_count >= v_max_branches THEN
    RAISE EXCEPTION 'branch_limit_exceeded: plan allows % branches, account has %',
      v_max_branches, v_active_count
      USING ERRCODE = 'P0403';
  END IF;

  -- Insert (UNIQUE constraint handles duplicate names)
  -- sucursal-guard-vaciado-auditoria (G2, D6): created_by = identidad en curso.
  BEGIN
    INSERT INTO public.branches (account_id, name, address, created_by)
    VALUES (p_account_id, p_name, p_address, auth.uid())
    RETURNING * INTO v_new_branch;
  EXCEPTION
    WHEN unique_violation THEN
      RAISE EXCEPTION 'branch_name_duplicate: a branch named % already exists in this account', p_name
        USING ERRCODE = 'P0409';
  END;

  RETURN v_new_branch;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_create_branch(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_branch(uuid, text, text) TO authenticated;

COMMENT ON FUNCTION public.rpc_create_branch(uuid, text, text) IS
  'C-07 (sucursales-module-pro), redefinida por sucursal-guard-vaciado-'
  'auditoria (G2): crea una sucursal para la cuenta, dentro de los límites '
  'del plan, y ahora completa created_by con la identidad en curso. Firma '
  'sin cambios. Candado: supabase/tests/test_sucursal_guard_vaciado.sql.';


-- =============================================================================
-- 9. OQ-7 — REVOKE de los privilegios de escritura a nivel TABLA que `anon`
--    tenía sobre `branches` (INSERT/UPDATE/DELETE/TRUNCATE). Verificado en
--    el apply: RLS exige membresía (branches_member_select) y rol writer
--    (branches_writer_insert/update/delete) — anon no resuelve identidad, así
--    que ninguna policy le entrega ni le acepta una fila hoy. El REVOKE no
--    rompe ningún camino legítimo: el frontend siempre opera con sesión, y el
--    backend corre como `authenticated` desde el Paso 2 de tenencia
--    (encendido en prod desde el 24-08). SELECT/REFERENCES/TRIGGER de `anon`
--    NO se tocan (no exponen nada sin RLS-passing y no están auditados en
--    este change — mismo criterio que dejó abierto el hallazgo h3 análogo de
--    cuenta-corriente-party-guard para otras tablas).
-- =============================================================================

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.branches FROM anon;


-- =============================================================================
-- 10. Gates de la propia migración.
-- =============================================================================

DO $$
DECLARE
  v_count integer;
  v_bad   text;
  v_def   text;
BEGIN
  -- (a) ANTI-OVERLOAD 42725: ninguna de las 3 funciones redefinidas cambió de
  --     firma, y las 4 nuevas nacen por primera vez — todas deben tener
  --     exactamente una definición.
  SELECT count(*) INTO v_count
  FROM pg_proc
  WHERE pronamespace = 'public'::regnamespace
    AND proname IN (
      'rpc_deactivate_branch', 'rpc_close_branch', 'rpc_create_branch',
      '_branch_blocking_content', '_branch_assert_empty',
      'fn_guard_branch_decommission', 'fn_audit_branch_lifecycle'
    );

  IF v_count <> 7 THEN
    RAISE EXCEPTION 'sucursal-guard-vaciado-auditoria ANTI-OVERLOAD: esperaba exactamente 7 definiciones (una por función), hay %. Revisar overloads fantasma con: SELECT proname, pg_get_function_identity_arguments(oid) FROM pg_proc WHERE pronamespace = ''public''::regnamespace AND proname IN (''rpc_deactivate_branch'',''rpc_close_branch'',''rpc_create_branch'',''_branch_blocking_content'',''_branch_assert_empty'',''fn_guard_branch_decommission'',''fn_audit_branch_lifecycle'');', v_count;
  END IF;

  -- (b) El disparador de guard existe sobre branches y apunta a la función
  --     correcta.
  SELECT count(*) INTO v_count
  FROM pg_trigger t
  JOIN pg_proc p ON p.oid = t.tgfoid
  WHERE t.tgrelid = 'public.branches'::regclass
    AND t.tgname = 'trg_guard_branch_decommission'
    AND NOT t.tgisinternal
    AND p.proname = 'fn_guard_branch_decommission';

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'sucursal-guard-vaciado-auditoria TRIGGER: trg_guard_branch_decommission no existe sobre public.branches o no apunta a fn_guard_branch_decommission.';
  END IF;

  SELECT count(*) INTO v_count
  FROM pg_trigger t
  JOIN pg_proc p ON p.oid = t.tgfoid
  WHERE t.tgrelid = 'public.branches'::regclass
    AND t.tgname = 'trg_audit_branch_lifecycle'
    AND NOT t.tgisinternal
    AND p.proname = 'fn_audit_branch_lifecycle';

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'sucursal-guard-vaciado-auditoria TRIGGER: trg_audit_branch_lifecycle no existe sobre public.branches o no apunta a fn_audit_branch_lifecycle.';
  END IF;

  -- (c) El cuerpo vivo de las 3 RPCs redefinidas contiene el guard (candado
  --     de texto, mismo patrón que otros gates del proyecto).
  FOR v_def IN
    SELECT pg_get_functiondef(p.oid)
    FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace
      AND p.proname IN ('rpc_deactivate_branch', 'rpc_close_branch')
  LOOP
    IF position('_branch_assert_empty' in v_def) = 0 THEN
      RAISE EXCEPTION 'sucursal-guard-vaciado-auditoria GUARD: una de rpc_deactivate_branch/rpc_close_branch no llama a _branch_assert_empty en su cuerpo vivo.';
    END IF;
  END LOOP;

  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'rpc_create_branch';
  IF position('created_by' in v_def) = 0 THEN
    RAISE EXCEPTION 'sucursal-guard-vaciado-auditoria GUARD: rpc_create_branch no completa created_by en su cuerpo vivo.';
  END IF;

  -- Entorno sin roles de Supabase (p.ej. postgres pelado): no hay ACL que verificar.
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    RAISE NOTICE 'sucursal-guard-vaciado-auditoria: roles de Supabase ausentes — se omite la verificación de ACLs.';
    RAISE NOTICE 'sucursal-guard-vaciado-auditoria OK (sin verificación de ACLs): 7 funciones con una sola definición, 2 disparadores presentes, guard y autoría escritos en el cuerpo vivo.';
    RETURN;
  END IF;

  -- (d) Las 3 RPCs públicas conservan EXECUTE para authenticated y NO lo
  --     tienen para anon.
  SELECT string_agg(sig, ', ') INTO v_bad
  FROM (
    SELECT unnest(ARRAY[
      'public.rpc_deactivate_branch(uuid)',
      'public.rpc_close_branch(uuid)',
      'public.rpc_create_branch(uuid,text,text)'
    ]) AS sig
  ) s
  WHERE NOT has_function_privilege('authenticated', s.sig::regprocedure, 'EXECUTE')
     OR      has_function_privilege('anon',         s.sig::regprocedure, 'EXECUTE');

  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'sucursal-guard-vaciado-auditoria ACL: las 3 RPCs redefinidas deben conservar EXECUTE para authenticated y NO tenerlo para anon, están mal: %', v_bad;
  END IF;

  -- (e) Los 4 helpers/disparadores nuevos NO deben ser ejecutables por
  --     anon NI authenticated (chequeos 1/3/4 del gate de ACLs — sin
  --     allowlist necesaria porque no están expuestos).
  SELECT string_agg(sig, ', ') INTO v_bad
  FROM (
    SELECT unnest(ARRAY[
      'public._branch_blocking_content(uuid)',
      'public._branch_assert_empty(uuid)',
      'public.fn_guard_branch_decommission()',
      'public.fn_audit_branch_lifecycle()'
    ]) AS sig
  ) s
  WHERE has_function_privilege('anon',          s.sig::regprocedure, 'EXECUTE')
     OR has_function_privilege('authenticated', s.sig::regprocedure, 'EXECUTE');

  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'sucursal-guard-vaciado-auditoria ACL: los helpers/disparadores internos deben seguir sin EXECUTE para anon/authenticated (no expuestos por diseño): %', v_bad;
  END IF;

  -- (f) OQ-7: anon perdió INSERT/UPDATE/DELETE/TRUNCATE a nivel tabla sobre
  --     branches (conserva SELECT/REFERENCES/TRIGGER, sin tocar).
  SELECT string_agg(priv, ', ') INTO v_bad
  FROM (
    SELECT unnest(ARRAY['INSERT','UPDATE','DELETE','TRUNCATE']) AS priv
  ) s
  WHERE has_table_privilege('anon', 'public.branches', s.priv);

  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'sucursal-guard-vaciado-auditoria ACL (OQ-7): anon todavía tiene privilegios de tabla sobre branches que deberían estar revocados: %', v_bad;
  END IF;

  RAISE NOTICE 'sucursal-guard-vaciado-auditoria OK: 7 funciones con una sola definición, 2 disparadores presentes y verificados, guard/autoría en el cuerpo vivo, ACLs de las 3 RPCs y los 4 internos correctas, y anon sin privilegios de escritura de tabla sobre branches (OQ-7).';
END $$;
