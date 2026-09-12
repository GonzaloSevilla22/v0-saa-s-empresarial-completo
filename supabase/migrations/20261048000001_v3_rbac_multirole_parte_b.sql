-- =============================================================================
-- v3-rbac-multirole — PARTE B (enforcement, CRÍTICO). Grupos 7-13 de
-- tasks.md. Design ref: openspec/changes/v3-rbac-multirole/design.md (D8-D16).
--
-- Checkpoint de estado real (grupo 7, 2026-09-11, read-only, prod vía MCP):
--   MAX(version) prod = 20261047000001 (296 migraciones) -- Parte A YA
--   mergeada y aplicada a prod. Migración de esta parte: 20261048000001.
--   48 policies / 20 tablas invocan is_account_writer (idéntico al design).
--   document_status_transitions: 19 filas, allowed_role text, 0/19 pobladas.
--   md5(pg_get_functiondef, \r removido) IDÉNTICO prod=local para las 3
--   funciones reescritas acá (is_account_writer, custom_access_token_hook,
--   record_status_transition) -- verificado ANTES de escribir este archivo,
--   vía mcp__supabase__execute_sql (prod) y psql (local):
--     is_account_writer         = e5e962f75e60828f5d80516f61003a26
--     custom_access_token_hook  = 0850ba16db47b3e67fd13393fbf14090
--     record_status_transition  = d5c0630b47b4e6d6156a03a8be4e8432
--   11 llamadores VIVOS de record_status_transition (pg_get_functiondef,
--   filtrado a prokind IN ('f','p') -- el filtro ingenuo por ILIKE atrapa
--   además funciones agregadas como array_agg y explota, ver nota task
--   7.5): _c29_confirm_order_core, rpc_accept_quote, rpc_close_cash_session,
--   rpc_close_reconciliation_session, rpc_delete_sale_operation,
--   rpc_emit_pending_cae, rpc_open_cash_session, rpc_open_reconciliation_
--   session, rpc_quick_sale, rpc_record_fiscal_transition, rpc_transfer_
--   stock, trg_quote_record_creation (12, no 10 -- el design subestimó el
--   conteo real). Ronda 1 adversarial (minor 6, corregido -- este párrafo
--   afirmaba lo contrario del propio hallazgo de la task 7.5): NINGUNO de
--   los 12 pasa NULL literal -- todos pasan auth.uid(), una variable
--   derivada de él, o el UUID centinela `00000000-0000-0000-0000-
--   000000000000` de rpc_record_fiscal_transition (relay CAE, "sistema"
--   documentado en su propio comentario). El relay CAE queda cubierto por
--   la exención 2 de D14 (allowed_role NULL en las 3 filas de
--   fiscal_document), no por la exención 1 (p_performed_by NULL) -- que
--   queda defensiva, sin ningún caller real que la ejercite hoy. Con las
--   39 cuentas 100% owner, D14 no cambia el resultado de NINGUNA transición
--   real (task 7.5/11.7).
--   7.6: el navegador no escribe ninguna de las 20 tablas gateadas por
--   is_account_writer por PostgREST (medido en el design, reconfirmado por
--   grep -- sin cambios desde entonces).
--
-- Implementa:
--   D8  Claim nuevo `account_roles` (array de roles ACTIVOS) del hook,
--       DENTRO del bloque protegido EXCEPTION WHEN OTHERS existente.
--       account_role (singular, derivado por precedencia) se CONSERVA
--       igual. GRANT explícito a supabase_auth_admin sobre
--       member_active_roles (precedente D5 de v31-authz-token-hook).
--   D10 Guards del backend evalúan el CONJUNTO (backend/core/guards.py +
--       backend/core/rbac.py, fuera de este archivo SQL) -- este archivo
--       agrega el helper `rpc_my_active_account_roles()` SECURITY DEFINER
--       SIN PARÁMETRO (resuelve auth.uid() internamente) para el fallback
--       a DB del guard: expone member_active_roles() de forma seguionera
--       (nunca un member_id arbitrario por PostgREST) -- NO se le agrega
--       GRANT a member_active_roles/account_user_active_roles para
--       `authenticated` (Parte A: "si se expone, con su propio guard de
--       tenencia, nunca un GRANT desnudo"). DESVÍO respecto del texto
--       literal de D10 (que no menciona esta función): es la forma de
--       cumplir R6 sin abrir el pivot completo a RLS/GRANT de tabla.
--   D11 is_account_writer conserva firma (1 arg) y las 48 policies; sólo
--       cambia el CUERPO -- EXISTS(rol activo del actor en la cuenta cuyo
--       is_writer del catálogo sea true), reutilizando
--       account_user_active_roles() de la Parte A (NUNCA un segundo "rol
--       activo"). current_account_ids() NO se toca.
--   D13 document_status_transitions.allowed_role: text -> text[] (USING,
--       no-op sobre datos con 0/19 pobladas).
--   D14 record_status_transition valida el rol del actor con DOS
--       exenciones (p_performed_by NULL = sistema; allowed_role NULL = sin
--       restricción) -- P0403 (ya mapeado a 403).
--   D15 Matriz normativa: 14/19 pobladas, 5 NULL (fiscal_document x3,
--       quote->expired x2).
--   D16 Barrido diario pg_cron: audita `role.expired` en audit_logs por
--       cada asignación VENCIDA sin su entrada todavía -- NO borra la fila
--       del pivot, NO corta nada (el corte lo hace el predicado de D4 en
--       cada guard/RLS/claim, ya vigente desde D11/D8 de este mismo
--       archivo). Dedup por FILA del pivot (nunca un 2º role.expired para
--       la MISMA asignación, sea cual sea el día en que corra el barrido)
--       -- más fuerte que el dedup por día del molde de cobranzas-
--       vencimientos; `as_of` (día argentino, reporting_local_today())
--       viaja en el metadata sólo para observabilidad.
--
-- REGLA DE INTEGRIDAD DE FUNCIÓN (R9): is_account_writer,
-- custom_access_token_hook y record_status_transition PARTEN del cuerpo
-- VIVO de prod (ver md5 arriba). NINGUNA cambia de firma -- is_account_writer
-- y record_status_transition CREATE OR REPLACE puro; custom_access_token_hook
-- ídem. Sin DROP, sin riesgo de overload 42725. ACLs preservadas
-- automáticamente por CREATE OR REPLACE, reverificadas en el gate de
-- introspección al final de este archivo.
--
-- Sin superficie frontend propia (13.5, declarado): las ~40 pantallas que
-- ya leen accountRole/isWriter no cambian -- ningún archivo bajo frontend/
-- se toca en esta parte.
--
-- GOVERNANCE: CRÍTICO sin matices (D0 del design) -- sign-off del PO
--             2026-09-11 (D0), gobierna RLS y guards de ventas/compras/
--             gastos/cuentas corrientes/caja de 39 cuentas reales.
-- APPLY: npx supabase db push (NUNCA MCP apply_migration).
--
-- ROLLBACK (design §Migration Plan -- "revertir los cuerpos de función a su
-- definición previa devuelve el comportamiento exacto"):
--   -- 1. Restaurar los 3 cuerpos de función al capturado arriba (md5).
--   -- 2. UPDATE public.document_status_transitions SET allowed_role = NULL;
--   -- 3. SELECT cron.unschedule('v3-rbac-role-expiry-audit-sweep');
--   -- 4. DROP FUNCTION IF EXISTS public._produce_role_expiry_audit_sweep();
--   -- 5. DROP FUNCTION IF EXISTS public.rpc_my_active_account_roles();
--   -- (la matriz desactivada + los cuerpos restaurados basta: D16 nunca
--   --  "corta" nada por sí sola, así que su ausencia es inerte)
-- =============================================================================


-- =============================================================================
-- 1. is_account_writer (D11) — sólo el CUERPO, misma firma, mismas 48
--    policies. Reutiliza member_active_roles() de la Parte A (D4) -- NUNCA
--    un segundo "rol activo".
--
--    Ronda 1 adversarial (minor 2, medido y corregido): la primera versión
--    de este cuerpo delegaba en account_user_active_roles(account_id,
--    user_id) -- que a su vez llama member_active_roles(member_id) -- para
--    resolver el member_id de (account_id, auth.uid()). Eso son DOS saltos
--    SECURITY DEFINER anidados por invocación, contra UNO solo del cuerpo
--    viejo de prod (EXISTS ... account_members WHERE role IN
--    ('owner','admin')). Medido en local (EXPLAIN ANALYZE, tabla temporal
--    de 5.000 filas, qual = is_account_writer(account_id) -- misma forma
--    que las 48 policies reales -- request.jwt.claims de un owner real, 2
--    corridas): cuerpo VIEJO ~93-95 ms / 5.000 filas (~0,019 ms/fila);
--    cuerpo de DOS saltos (primera versión de este archivo) ~2.320-2.436 ms
--    (~0,46-0,49 ms/fila, ~24-26× más lento). El cuerpo de ABAJO (UN solo
--    salto: resuelve account_members directo en la MISMA consulta, sin
--    pasar por account_user_active_roles) mide ~753-764 ms (~0,15 ms/fila,
--    ~8× más lento que el viejo -- recupera ~2/3 del overhead agregado sin
--    duplicar la definición de "rol activo": el predicado de vencimiento
--    (expires_at) sigue viviendo EXCLUSIVAMENTE en member_active_roles,
--    reutilizada acá sin reescribir su lógica). Detalle completo (bucle de
--    10.000 llamadas directas, ambos métodos, 2 corridas) en CHANGES.md y
--    design.md D11. Impacto real acotado (sin cambiar el análisis: la
--    mayoría de las escrituras van por RPCs SECURITY DEFINER como
--    postgres, donde la RLS no se evalúa) -- el peor caso medido sigue
--    siendo la recategorización en lote de productos
--    (product_repository.py, tope 500/tanda), ahora ~65 ms de overhead
--    agregado por tanda en vez de ~225 ms.
--
--    Ronda 2 adversarial (nit 3, re-verificado): una pasada intermedia de
--    esta ronda había reportado para el cuerpo MERGIDO ~79-84 ms/5.000
--    filas (~1,3× el viejo) y concluido que la cifra de arriba (~753-764
--    ms, ~8×) era pesimista. Re-medido ACÁ con el MISMO protocolo (EXPLAIN
--    ANALYZE, 5.000 filas, mismo owner ancla) pero en sesión aislada,
--    orden intercambiado (mergido ANTES de viejo/dos-saltos, para
--    descartar caché de sesión) y 5 corridas en vez de 2: viejo
--    ~69-73 ms (~0,014 ms/fila); dos-saltos (reconstruido)
--    ~1.221-1.251 ms (~0,245 ms/fila, ~17-18×); MERGIDO (llamado directo a
--    la función LIVE, no una reconstrucción) ~728-815 ms (~0,15 ms/fila,
--    ~11× el viejo) -- CONFIRMA el orden de magnitud ya documentado arriba
--    (~8-11×), no el ~1,3× de la pasada intermedia, que no reprodujo bajo
--    este protocolo. Segunda metodología (bucle de 10.000 llamadas
--    directas, sin tabla): viejo ~153 ms; dos-saltos ~2.556-2.697 ms
--    (~17×); mergido ~2.424-2.489 ms (~16×) -- misma conclusión por un
--    camino independiente. El número exacto depende del volumen de
--    account_members/account_member_roles de la base medida (acá: 14
--    miembros, 16 asignaciones) y puede variar entre entornos; el orden de
--    magnitud (~8-17× el viejo, muy por debajo del ~24-26× de dos saltos)
--    es la conclusión estable entre las tres mediciones independientes
--    (ronda 1, esta nota, y la pasada intermedia para OLD/dos-saltos).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.is_account_writer(p_account_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM   public.account_members am
    JOIN   LATERAL unnest(public.member_active_roles(am.id)) AS r(code) ON true
    JOIN   public.account_role_catalog arc ON arc.code = r.code
    WHERE  am.account_id = p_account_id
      AND  am.user_id    = (SELECT auth.uid())
      AND  arc.is_writer = true
  );
$function$;

COMMENT ON FUNCTION public.is_account_writer(uuid) IS
  'v3-rbac-multirole Parte B (D11): EXISTS(rol ACTIVO del actor en la cuenta '
  'cuyo is_writer del catálogo sea true) -- fail-closed: sin ninguna fila en '
  'el pivot para el member_id resuelto, false. Misma firma y las mismas 48 '
  'policies sobre 20 tablas de siempre (verificado en el gate de '
  'introspección de abajo) -- current_account_ids() NO se toca (resuelve '
  'tenencia, no rol). Ronda 1 adversarial (minor 2): resuelve '
  'account_members EN LA MISMA consulta (un solo salto SECURITY DEFINER, '
  'vía member_active_roles) en vez de delegar en account_user_active_roles '
  '-- sigue habiendo UNA sola definición canónica de "rol activo" '
  '(member_active_roles, D4), medido ~3x más rápido que la versión de dos '
  'saltos (ver CHANGES.md/design.md D11).';


-- =============================================================================
-- 2. rpc_my_active_account_roles() (soporte de D10/R6) — SIN parámetro:
--    resuelve auth.uid() internamente, nunca un member_id arbitrario. Único
--    consumidor: el fallback a DB de require_account_role del backend
--    (backend/core/guards.py). GRANT a authenticated CON guard de tenencia
--    por construcción (no hay parámetro que un tercero pueda falsificar) --
--    a diferencia de exponer member_active_roles/account_user_active_roles
--    directo (que Parte A dejó revocadas a propósito, D3 comentario:
--    "si se expone, con su propio guard, nunca un GRANT desnudo").
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_my_active_account_roles()
RETURNS text[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  -- Ronda 1 adversarial (nit 7): COALESCE a ARRAY vacío -- sin esto, un
  -- caller sin ninguna membresía (el LIMIT 1 sin filas) devuelve NULL, lo
  -- que contradecía el COMMENT ("array vacío, no NULL"). Mismo criterio que
  -- member_active_roles/account_user_active_roles de la Parte A -- las TRES
  -- funciones de la familia "roles activos" quedan con el mismo contrato:
  -- ARRAY vacío, nunca NULL.
  SELECT COALESCE(
    (SELECT public.member_active_roles(am.id)
     FROM   public.account_members am
     WHERE  am.user_id = (SELECT auth.uid())
     ORDER BY am.created_at, am.id
     LIMIT 1),
    ARRAY[]::text[]
  );
$function$;

COMMENT ON FUNCTION public.rpc_my_active_account_roles() IS
  'v3-rbac-multirole Parte B (D10, R6): roles ACTIVOS del CALLER en su '
  'membresía más antigua (mismo criterio determinístico que get_account_id '
  '/ el hook, D4 de v31-authz-token-hook) -- SIN parámetro, no hay ningún '
  'member_id que un tercero pueda pasar. Único consumidor: el fallback a DB '
  'de require_account_role (backend/core/guards.py) cuando ni el claim del '
  'conjunto ni el singular viajan en el JWT. Array vacío (no NULL) si el '
  'caller no es miembro de ninguna cuenta -- COALESCE explícito (ronda 1 '
  'adversarial, nit 7), mismo contrato que member_active_roles/'
  'account_user_active_roles de la Parte A.';

REVOKE ALL ON FUNCTION public.rpc_my_active_account_roles() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_my_active_account_roles() TO authenticated;


-- =============================================================================
-- 3. custom_access_token_hook (D8) — claim nuevo `account_roles` DENTRO del
--    bloque protegido EXCEPTION WHEN OTHERS existente. account_role
--    (singular) se conserva IDÉNTICO. GRANTs de lectura a supabase_auth_admin
--    (precedente D5 de v31-authz-token-hook: sin el grant, el hook DEGRADA
--    TODO el app_metadata -- verificado como supabase_auth_admin REAL en el
--    step dedicado de KPI_Validation.yml, ronda 1 adversarial minor 1).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_claims        jsonb := COALESCE(event -> 'claims', '{}'::jsonb);
  v_user_id       uuid  := (event ->> 'user_id')::uuid;
  v_role          text;
  v_account_id    uuid;
  v_member_id     uuid;
  v_account_role  text;
  v_account_roles text[];
  v_plan          text;
  v_app_metadata  jsonb;
BEGIN
  -- Rol de PLATAFORMA (D1) — sin cambio semántico respecto de 20260800000004.
  SELECT role INTO v_role
  FROM public.profiles
  WHERE id = v_user_id;

  -- Rol de TENANT (D1) + cuenta activa determinística (D4): la membresía más
  -- antigua, desempatada por PK — MISMO criterio que
  -- backend/core/deps.py::get_account_id tras este change.
  SELECT id, account_id, role INTO v_member_id, v_account_id, v_account_role
  FROM public.account_members
  WHERE user_id = v_user_id
  ORDER BY created_at, id
  LIMIT 1;

  -- v3-rbac-multirole Parte B (D8): el CONJUNTO de roles ACTIVOS del mismo
  -- member_id ya resuelto arriba — vencidos excluidos por member_active_roles
  -- (D4 de la Parte A, reutilizado, nunca un segundo "rol activo"). NULL
  -- (no [] fabricado) si no se resolvió ningún member_id — distinto de "sin
  -- roles activos" (member_id resuelto, array vacío real).
  IF v_member_id IS NOT NULL THEN
    v_account_roles := public.member_active_roles(v_member_id);
  END IF;

  -- Plan EFECTIVO (D3) — delegado a la definición normativa única. Sin cuenta
  -- activa no hay plan que emitir (no se inventa un default acá).
  IF v_account_id IS NOT NULL THEN
    v_plan := public.get_effective_plan(v_account_id);
  END IF;

  -- Merge aditivo sobre app_metadata existente: preserva otras claves que
  -- Supabase ya haya puesto (p.ej. provider), y cada claim nuevo se agrega
  -- SOLO si se resolvió — un valor NULL no pisa nada.
  v_app_metadata := COALESCE(v_claims -> 'app_metadata', '{}'::jsonb);

  IF v_role IS NOT NULL THEN
    v_app_metadata := v_app_metadata || jsonb_build_object('role', v_role);
  END IF;

  IF v_account_role IS NOT NULL THEN
    v_app_metadata := v_app_metadata || jsonb_build_object('account_role', v_account_role);
  END IF;

  IF v_account_roles IS NOT NULL THEN
    v_app_metadata := v_app_metadata || jsonb_build_object('account_roles', to_jsonb(v_account_roles));
  END IF;

  IF v_plan IS NOT NULL THEN
    v_app_metadata := v_app_metadata || jsonb_build_object('plan', v_plan);
  END IF;

  -- Solo tocar `claims.app_metadata` si hay algo nuevo que aportar o si YA
  -- existía (para no fabricar una clave `app_metadata: {}` en un evento que
  -- nunca la tuvo — un usuario sin profile ni membresía debe devolver los
  -- claims EXACTAMENTE como llegaron, sin ninguna clave nueva).
  IF v_app_metadata <> '{}'::jsonb OR v_claims ? 'app_metadata' THEN
    v_claims := jsonb_set(v_claims, '{app_metadata}', v_app_metadata, true);
  END IF;

  RETURN jsonb_build_object('claims', v_claims);
EXCEPTION
  WHEN OTHERS THEN
    -- Nunca romper la emisión del token: ante cualquier error (incluido un
    -- permiso faltante sobre member_active_roles, D8/D5), claims intactos.
    -- Deja rastro (D5 de v31-authz-token-hook): un permiso faltante o un
    -- cambio de esquema queda en los logs de Postgres, no como claims
    -- ausentes sin explicación.
    RAISE WARNING 'custom_access_token_hook degradado (SQLSTATE=%): %', SQLSTATE, SQLERRM;
    RETURN jsonb_build_object('claims', COALESCE(event -> 'claims', '{}'::jsonb));
END;
$function$;

COMMENT ON FUNCTION public.custom_access_token_hook(jsonb) IS
  'v3-rbac-multirole Parte B (D8): emite account_roles (CONJUNTO de roles '
  'ACTIVOS, vencidos excluidos) DENTRO del bloque protegido EXCEPTION WHEN '
  'OTHERS heredado de v31-authz-token-hook -- account_role (singular, '
  'derivado por precedencia) se conserva IDÉNTICO. Ante cualquier error, '
  'claims intactos + RAISE WARNING (nunca rompe el login).';

-- D8/precedente D5 de v31-authz-token-hook: supabase_auth_admin necesita
-- permiso explícito para invocar member_active_roles() desde DENTRO del
-- hook (STABLE, no SECURITY DEFINER -- corre con los privilegios del
-- INVOCADOR real, GoTrue). Sin este GRANT, TODO el hook degrada (bloque
-- EXCEPTION captura el "permission denied") -- ronda 1 adversarial (minor
-- 1): el bloque 5 LOCAL de test_custom_access_token_hook_account_roles.sql
-- nunca puede ejercitar esto de verdad (SIEMPRE degrada por límite de
-- entorno, `SET LOCAL ROLE` sin membresía) y ya NO cuenta como PASS cuando
-- degrada; la verificación REAL corre en el step dedicado de
-- KPI_Validation.yml ("Run v3-rbac-multirole hook D8 degrade probe (real
-- supabase_auth_admin role)"), conectado como supabase_auth_admin de
-- verdad.
GRANT EXECUTE ON FUNCTION public.member_active_roles(uuid) TO supabase_auth_admin;

-- Task 9.5 (literal): permisos de lectura de supabase_auth_admin también
-- sobre el pivot y el catálogo -- defensa en profundidad, aunque el camino
-- real de esta migración pasa por member_active_roles (SECURITY DEFINER,
-- ejecuta como postgres/superusuario, bypassea RLS+GRANT igual). RLS del
-- pivot sigue sin ninguna policy para supabase_auth_admin salvo ésta.
DROP POLICY IF EXISTS auth_admin_can_read_member_roles ON public.account_member_roles;
CREATE POLICY auth_admin_can_read_member_roles
  ON public.account_member_roles
  FOR SELECT
  TO supabase_auth_admin
  USING (true);

GRANT SELECT ON public.account_member_roles TO supabase_auth_admin;
GRANT SELECT ON public.account_role_catalog TO supabase_auth_admin;


-- =============================================================================
-- 4. document_status_transitions.allowed_role: text -> text[] (D13) + matriz
--    normativa de 19 filas (D15) -- 14 pobladas / 5 NULL.
-- =============================================================================
-- Idempotencia (13.2, reaplicable ×2): el ALTER sólo corre si la columna
-- TODAVÍA es `text` -- reaplicarlo sobre una columna YA `text[]` envolvería
-- cada array existente en un array anidado (ARRAY[allowed_role] con
-- allowed_role ya text[] no es un error, pero corrompe el dato: {a,b} ->
-- {{a,b}}), rompiendo el 14/19 poblado de la corrida anterior.
DO $$
BEGIN
  IF (
    SELECT data_type FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'document_status_transitions' AND column_name = 'allowed_role'
  ) = 'text' THEN
    ALTER TABLE public.document_status_transitions
      ALTER COLUMN allowed_role TYPE text[]
      USING (CASE WHEN allowed_role IS NULL THEN NULL ELSE ARRAY[allowed_role] END);
  END IF;
END $$;

COMMENT ON COLUMN public.document_status_transitions.allowed_role IS
  'v3-rbac-multirole Parte B (D13): CONJUNTO de códigos de account_role_'
  'catalog habilitados para ejecutar esta transición -- NULL = transición de '
  'SISTEMA (relay CAE, expiración por cron), sin restricción de rol '
  '(record_status_transition, D14 exención 2). Antes: text singular, 0/19 '
  'pobladas, inerte desde v3-document-status-history.';

-- D15: matriz normativa — 14 filas pobladas, 5 NULL a propósito (las 3 de
-- fiscal_document + las 2 quote->expired, todas transiciones de sistema).
UPDATE public.document_status_transitions SET allowed_role = ARRAY['seller','admin','owner']          WHERE document_type = 'quote'       AND from_status IS NULL     AND to_status = 'draft';
UPDATE public.document_status_transitions SET allowed_role = ARRAY['seller','admin','owner']          WHERE document_type = 'quote'       AND from_status = 'draft'   AND to_status = 'sent';
UPDATE public.document_status_transitions SET allowed_role = ARRAY['seller','admin','owner']          WHERE document_type = 'quote'       AND from_status = 'draft'   AND to_status = 'accepted';
UPDATE public.document_status_transitions SET allowed_role = ARRAY['seller','admin','owner']          WHERE document_type = 'quote'       AND from_status = 'sent'    AND to_status = 'accepted';
UPDATE public.document_status_transitions SET allowed_role = ARRAY['seller','admin','owner']          WHERE document_type = 'quote'       AND from_status = 'draft'   AND to_status = 'rejected';
UPDATE public.document_status_transitions SET allowed_role = ARRAY['seller','admin','owner']          WHERE document_type = 'quote'       AND from_status = 'sent'    AND to_status = 'rejected';
UPDATE public.document_status_transitions SET allowed_role = ARRAY['seller','cashier','admin','owner'] WHERE document_type = 'sales_order' AND from_status IS NULL     AND to_status = 'draft';
UPDATE public.document_status_transitions SET allowed_role = ARRAY['seller','cashier','admin','owner'] WHERE document_type = 'sales_order' AND from_status = 'draft'   AND to_status = 'confirmed';
UPDATE public.document_status_transitions SET allowed_role = ARRAY['admin','owner']                    WHERE document_type = 'sales_order' AND from_status = 'confirmed' AND to_status = 'canceled';
UPDATE public.document_status_transitions SET allowed_role = ARRAY['cashier','admin','owner']          WHERE document_type = 'cash_session' AND from_status IS NULL    AND to_status = 'open';
UPDATE public.document_status_transitions SET allowed_role = ARRAY['cashier','admin','owner']          WHERE document_type = 'cash_session' AND from_status = 'open'   AND to_status = 'closed';
UPDATE public.document_status_transitions SET allowed_role = ARRAY['accountant','admin','owner']       WHERE document_type = 'reconciliation_session' AND from_status IS NULL AND to_status = 'open';
UPDATE public.document_status_transitions SET allowed_role = ARRAY['accountant','admin','owner']       WHERE document_type = 'reconciliation_session' AND from_status = 'open' AND to_status = 'closed';
UPDATE public.document_status_transitions SET allowed_role = ARRAY['stock','admin','owner']             WHERE document_type = 'stock_transfer' AND from_status IS NULL AND to_status = 'completed';
-- Las 5 restantes quedan NULL a propósito (ya lo están tras el ALTER de
-- arriba, que preserva NULL -> NULL): fiscal_document (NULL->pending_cae,
-- pending_cae->authorized, pending_cae->rejected) y quote (draft->expired,
-- sent->expired) -- las 5 transiciones de SISTEMA de D15.


-- =============================================================================
-- 5. record_status_transition (D14) — verificación de rol del actor, con
--    las DOS exenciones explícitas. Misma firma (7 args), CREATE OR REPLACE
--    puro sobre el cuerpo vivo de prod.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.record_status_transition(p_account_id uuid, p_document_type text, p_document_id uuid, p_from_status text, p_to_status text, p_performed_by uuid, p_reason text DEFAULT NULL::text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_allowed_role text[];
  v_actor_roles  text[];
  v_row_found    boolean;
BEGIN
  -- RN-A4 estructural: transición (no creación) debe estar catalogada
  IF p_from_status IS NOT NULL
     AND NOT public.is_valid_transition(p_document_type, p_from_status, p_to_status) THEN
    RAISE EXCEPTION 'invalid_status_transition: % %→% no está catalogada',
      p_document_type, p_from_status, p_to_status
      USING ERRCODE = 'P0409';
  END IF;

  -- RN-A5: reason obligatorio cuando la policy lo pide para el estado destino
  IF public.transition_requires_reason(p_document_type, p_to_status)
     AND (p_reason IS NULL OR trim(p_reason) = '') THEN
    RAISE EXCEPTION 'reason_required: la transición %→% de % exige un motivo (RN-A5)',
      p_from_status, p_to_status, p_document_type
      USING ERRCODE = 'P0400';
  END IF;

  -- v3-rbac-multirole Parte B (D14): verificación de rol del actor, con dos
  -- exenciones explícitas:
  --   (1) p_performed_by IS NULL -> contexto de SISTEMA (relay CAE, cron de
  --       expiración), exento -- mismo principio que python-backend exime
  --       al contexto de servicio de los guards de usuario.
  --   (2) allowed_role IS NULL -> transición SIN restricción de rol (D13:
  --       las 5 filas de sistema). Mantiene inertes esas filas aunque el
  --       actor venga no nulo.
  -- En cualquier otro caso, los roles ACTIVOS del actor en p_account_id
  -- deben intersecar allowed_role, o P0403 (ya mapeado a 403).
  --
  -- Ronda 1 adversarial (minor 3): "no hay fila en la matriz" (v_row_found
  -- = false) y "la fila existe con allowed_role NULL" (exención 2) son DOS
  -- casos distintos que la versión anterior de este bloque confundía --
  -- ambos dejaban v_allowed_role NULL y caían en la MISMA rama sin
  -- distinguirse. Hoy "sin fila" sólo alcanza a transiciones de CREACIÓN
  -- no catalogadas (from_status IS NULL): para from_status NOT NULL,
  -- is_valid_transition (RN-A4, arriba) ya abortó con P0409 antes de
  -- llegar acá. Criterio CONSERVADOR de esta ronda (D17/11.7: con las 39
  -- cuentas 100% owner, ninguna transición real cambia de resultado): NO
  -- se rechaza -- se mantiene la misma exención de facto, pero ahora
  -- EXPLÍCITA y comentada en vez de accidental por un NULL sin marcar.
  -- Endurecer esto a P0409 (rechazar una creación no catalogada) queda
  -- como candidato de la Parte C o posterior (ver design.md/CHANGES.md).
  -- El gate de introspección de más abajo (test_document_status_
  -- transition_role_matrix.sql) tiene DOS bloques que se complementan, no
  -- uno que "atrapa una transición nueva" en abstracto: el bloque (5)
  -- enumera los pares (document_type, from_status, to_status) que
  -- producen los 12 llamadores vivos y asserta que TODOS están
  -- catalogados -- atrapa que la matriz PIERDA una fila que esos 12
  -- llamadores necesitan hoy. El bloque (5b, ronda 2 adversarial) asserta
  -- que el CONJUNTO de funciones que invocan record_status_transition
  -- sigue siendo exactamente esos 12 -- atrapa que aparezca un llamador
  -- NUEVO (o desaparezca uno) sin que alguien haya revisado y actualizado
  -- ambas listas. Juntos, un caso realista (caller nuevo o modificado que
  -- empieza a producir un par no catalogado) queda cubierto -- pero NO
  -- una transición nueva en el sentido más amplio: un llamador YA
  -- conocido que cambie el PAR que produce sigue sin gate si su nombre de
  -- función no cambia (blind spot documentado en (5b): trg_quote_record_
  -- creation pasa NEW.status dinámico como to_status, anotado como
  -- candidato en CHANGES.md, no cerrado en esta ronda).
  IF p_performed_by IS NOT NULL THEN
    SELECT allowed_role INTO v_allowed_role
    FROM public.document_status_transitions
    WHERE document_type = p_document_type
      AND from_status IS NOT DISTINCT FROM p_from_status
      AND to_status = p_to_status;
    v_row_found := FOUND;

    IF NOT v_row_found THEN
      -- Sin fila en la matriz: exención EXPLÍCITA y deliberada (ver nota
      -- arriba) -- no rechazamos, criterio conservador de esta ronda.
      NULL;
    ELSIF v_allowed_role IS NULL THEN
      -- Fila SÍ existe, pero declara SIN restricción de rol (D14
      -- exención 2 -- las 5 filas de sistema de D15).
      NULL;
    ELSE
      v_actor_roles := public.account_user_active_roles(p_account_id, p_performed_by);

      IF NOT (v_actor_roles && v_allowed_role) THEN
        RAISE EXCEPTION 'insufficient_role: % no tiene un rol habilitado para la transición %→% de % (requiere uno de: %)',
          p_performed_by, p_from_status, p_to_status, p_document_type, v_allowed_role
          USING ERRCODE = 'P0403';
      END IF;
    END IF;
  END IF;

  INSERT INTO public.document_status_history
    (account_id, document_type, document_id, from_status, to_status, performed_by, reason)
  VALUES
    (p_account_id, p_document_type, p_document_id, p_from_status, p_to_status,
     p_performed_by, NULLIF(trim(COALESCE(p_reason, '')), ''));
END;
$function$;

COMMENT ON FUNCTION public.record_status_transition(uuid, text, uuid, text, text, uuid, text) IS
  'v3-rbac-multirole Parte B (D14): valida la transición catalogada (RN-A4), '
  'el motivo si la policy lo exige (RN-A5), y desde esta parte el ROL del '
  'actor contra document_status_transitions.allowed_role (D15) -- P0403 si '
  'no interseca. Tres exenciones EXPLÍCITAS (ronda 1 adversarial, minor 3): '
  'p_performed_by NULL (sistema), sin fila en la matriz (v_row_found=false '
  '-- hoy sólo creaciones no catalogadas, conservador por D17/11.7, gate de '
  'cobertura en test_document_status_transition_role_matrix.sql), y '
  'allowed_role NULL con fila existente (transición sin restricción de '
  'rol).';


-- =============================================================================
-- 6. Barrido diario de vencimientos (D16) — audita, no borra ni corta.
-- =============================================================================
CREATE OR REPLACE FUNCTION public._produce_role_expiry_audit_sweep()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
/*
  v3-rbac-multirole Parte B (D16): el barrido AUDITA, no corta -- el corte lo
  hace el predicado de "rol activo" (D4) evaluado en cada guard/RLS/claim
  (ya vigente desde is_account_writer/custom_access_token_hook de esta misma
  migración). Si el cron se cae, nadie gana permisos de más; sólo se pierde
  el asiento de auditoría, que este barrido recupera solo la próxima vez que
  corra. Idempotente: dedup por FILA del pivot que ya venció y aún no tiene
  su entrada role.expired -- nunca un segundo registro para la MISMA
  asignación, sea cual sea el día en que se ejecute el barrido (más fuerte
  que el dedup por día del molde, _produce_receivables_overdue_digest,
  D8/D9 de cobranzas-vencimientos, porque un vencimiento de rol es un evento
  ÚNICO en el tiempo, no una deuda que se acumula día a día). `as_of` (día
  argentino, reporting_local_today()) viaja en el metadata sólo para
  observabilidad, mismo ancla que el resto del proyecto.

  Ronda 2 adversarial (nit 3, corregido): la versión anterior de este
  bloque escribía el COMPLEMENTO del predicado de "rol activo" a mano
  (`expires_at IS NOT NULL AND expires_at <= now()`), un segundo lugar con
  el límite de vencimiento pese a que la cabecera de la migración (sección
  1, D11) afirma que ese predicado vive EXCLUSIVAMENTE en
  member_active_roles. Corregido: el barrido ya NO evalúa `now()` por su
  cuenta -- deriva "esta fila venció" preguntándole a member_active_roles
  (la MISMA fuente canónica que is_account_writer/el hook/RLS) si el
  código de rol de la fila sigue entre los activos del member_id. Como
  `account_member_roles_member_role_uq UNIQUE (member_id, role)` garantiza
  que un member nunca tiene dos filas con el mismo código de rol, "el
  código de esta fila no está entre los activos" es exactamente "esta fila
  particular venció" -- ni más (no captura otra fila) ni menos (no se le
  escapa la propia). Mismo comportamiento observable (gate
  test_role_expiry_audit_sweep.sql sin cambios, verde x2), predicado de
  vencimiento en UN solo lugar.
*/
DECLARE
  v_today date := public.reporting_local_today();
  v_count integer := 0;
BEGIN
  WITH expired AS (
    SELECT amr.id, amr.account_id, amr.member_id, amr.role, amr.expires_at
    FROM   public.account_member_roles amr
    WHERE  amr.expires_at IS NOT NULL
      AND  NOT (amr.role = ANY (public.member_active_roles(amr.member_id)))
      AND  NOT EXISTS (
        SELECT 1 FROM public.audit_logs al
        WHERE al.entity_type = 'account_member_role'
          AND al.entity_id   = amr.id
          AND al.action      = 'role.expired'
      )
  ),
  ins AS (
    INSERT INTO public.audit_logs
      (account_id, user_id, action, entity_type, entity_id, metadata, created_at)
    SELECT account_id, NULL, 'role.expired', 'account_member_role', id,
           jsonb_build_object('member_id', member_id, 'role', role, 'expires_at', expires_at, 'as_of', v_today::text),
           now()
    FROM expired
    RETURNING 1
  )
  SELECT count(*) INTO v_count FROM ins;

  RETURN v_count;
END;
$fn$;

REVOKE ALL ON FUNCTION public._produce_role_expiry_audit_sweep() FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public._produce_role_expiry_audit_sweep() IS
  'v3-rbac-multirole Parte B (D16): barrido diario -- audita role.expired en '
  'audit_logs por cada asignación del pivot vencida sin su entrada todavía. '
  'NO borra la fila, NO cambia ningún permiso -- el corte ya lo produce el '
  'predicado de rol activo (D4) en is_account_writer/custom_access_token_'
  'hook/account_user_active_roles, con o sin este barrido corriendo. '
  '"Vencida" se deriva llamando a member_active_roles (ronda 2 nit 3) -- '
  'nunca reescribe la comparación contra now() por su cuenta.';

-- Scheduling — patrón v3-notifications-realtime §4.2 / cobranzas-vencimientos.
SELECT cron.unschedule('v3-rbac-role-expiry-audit-sweep')
FROM cron.job WHERE jobname = 'v3-rbac-role-expiry-audit-sweep';

SELECT cron.schedule(
    'v3-rbac-role-expiry-audit-sweep',
    '0 13 * * *',  -- diario a las 13:00 UTC (~10:00 Mendoza) -- después del
                   -- de cobranzas-vencimientos (12:00 UTC), sin superponer.
    $$ SELECT public._produce_role_expiry_audit_sweep(); $$
);


-- =============================================================================
-- 7. GATE DE INTROSPECCIÓN (corre SIEMPRE, también en prod) — mismo molde
--    que el resto de las migraciones grandes de este proyecto.
-- =============================================================================
DO $$
DECLARE
  v_cnt   int;
  v_fn    text;
  v_n_pol int;
  v_n_tab int;
BEGIN
  -- (a) una sola definición de cada función tocada (42725).
  FOR v_fn IN
    SELECT unnest(ARRAY[
      'is_account_writer', 'custom_access_token_hook', 'record_status_transition',
      'rpc_my_active_account_roles', '_produce_role_expiry_audit_sweep'])
  LOOP
    SELECT COUNT(*) INTO v_cnt FROM pg_proc
    WHERE pronamespace = 'public'::regnamespace AND proname = v_fn;
    IF v_cnt <> 1 THEN
      RAISE EXCEPTION 'GATE INTROSPECCION FAILED: % tiene % definiciones (esperaba 1).', v_fn, v_cnt;
    END IF;
  END LOOP;

  -- (b) is_account_writer: firma sin cambios (1 arg) + 48 policies/20 tablas.
  SELECT pronargs INTO v_cnt FROM pg_proc
  WHERE pronamespace = 'public'::regnamespace AND proname = 'is_account_writer';
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: is_account_writer cambió de aridad (%)', v_cnt;
  END IF;

  SELECT count(*), count(DISTINCT tablename) INTO v_n_pol, v_n_tab
  FROM pg_policies
  WHERE schemaname = 'public'
    AND (qual ILIKE '%is_account_writer%' OR with_check ILIKE '%is_account_writer%');
  IF v_n_pol <> 48 OR v_n_tab <> 20 THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: is_account_writer debía seguir invocada por 48 policies/20 tablas, hay %/%', v_n_pol, v_n_tab;
  END IF;

  -- (c) is_account_writer: ACL preservada IDÉNTICA a la baseline de prod
  --     (postgres, anon, authenticated, service_role -- anon YA tenía
  --     EXECUTE desde SIEMPRE, inerte porque auth.uid() da NULL para anon
  --     y el EXISTS() nunca matchea -- CREATE OR REPLACE preserva ACL, D11:
  --     "las ACLs se preservan automáticamente", no se agrega NADA nuevo).
  IF NOT (
    has_function_privilege('postgres', 'public.is_account_writer(uuid)', 'EXECUTE')
    AND has_function_privilege('anon', 'public.is_account_writer(uuid)', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.is_account_writer(uuid)', 'EXECUTE')
    AND has_function_privilege('service_role', 'public.is_account_writer(uuid)', 'EXECUTE')
  ) THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: is_account_writer cambió su ACL respecto de la baseline de prod (postgres/anon/authenticated/service_role).';
  END IF;
  IF has_function_privilege('anon', 'public.custom_access_token_hook(jsonb)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.custom_access_token_hook(jsonb)', 'EXECUTE')
  THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: custom_access_token_hook ejecutable por anon/authenticated.';
  END IF;
  IF has_function_privilege('anon', 'public.record_status_transition(uuid,text,uuid,text,text,uuid,text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.record_status_transition(uuid,text,uuid,text,text,uuid,text)', 'EXECUTE')
  THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: record_status_transition ejecutable por anon/authenticated (debe seguir postgres+service_role solamente).';
  END IF;
  IF has_function_privilege('anon', 'public.rpc_my_active_account_roles()', 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_my_active_account_roles ejecutable por anon.';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.rpc_my_active_account_roles()', 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_my_active_account_roles debía ser ejecutable por authenticated (fallback del guard).';
  END IF;
  IF has_function_privilege('anon', 'public._produce_role_expiry_audit_sweep()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._produce_role_expiry_audit_sweep()', 'EXECUTE')
  THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: _produce_role_expiry_audit_sweep ejecutable por anon/authenticated.';
  END IF;

  -- (d) supabase_auth_admin con EXECUTE sobre member_active_roles (D8).
  IF NOT has_function_privilege('supabase_auth_admin', 'public.member_active_roles(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: supabase_auth_admin sin EXECUTE sobre member_active_roles.';
  END IF;

  -- (e) matriz 14/5 exacta.
  SELECT count(*), count(allowed_role) INTO v_n_pol, v_n_tab
  FROM public.document_status_transitions;
  IF v_n_pol <> 19 OR v_n_tab <> 14 THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: se esperaban 19 filas / 14 pobladas en document_status_transitions, hay % / %', v_n_pol, v_n_tab;
  END IF;

  -- (f) cron activo.
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'v3-rbac-role-expiry-audit-sweep' AND active) THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: el cron v3-rbac-role-expiry-audit-sweep no está activo.';
  END IF;

  RAISE NOTICE 'GATE INTROSPECCION v3-rbac-multirole Parte B: OK.';
END $$;
