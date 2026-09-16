-- =============================================================================
-- auth-hardening-jwt-cookies — Parte A, grupo 8 (D14). Governance CRÍTICO
-- (auth): enfoque firmado por el PO el 2026-09-16.
--
-- Tres piezas independientes entre sí, ninguna con backfill, todas de la
-- Parte A. Van juntas porque partirlas multiplica el riesgo de renumerado
-- (ya ocurrió tres veces en cuenta-corriente-party-guard) sin ganar nada.
-- La tercera —un COMMENT— entró en la ronda adversarial de cierre (m3).
--
-- ─── (1) rpc_accept_invitation(text): binding de email + lock ───────────────
--
-- SÍNTOMA (hallazgo F13 de la auditoría del 2026-09-14, spec
-- account-membership-roles "La aceptación de una invitación exige la
-- identidad invitada"): la RPC validaba token + status='pending' +
-- expires_at y creaba la membresía para auth.uid() SIN comparar nunca la
-- columna `email` de la invitación. Cualquier sesión autenticada que
-- consiguiera un token —hoy la pantalla de invitar lo muestra en claro para
-- que el administrador lo comparta por WhatsApp— podía canjearlo y entrar a
-- la cuenta con los roles invitados. Y el `UPDATE ... status='accepted'` era
-- la ÚLTIMA sentencia, sin lock: dos aceptaciones concurrentes del mismo
-- token competían.
--
-- FIX:
--   (a) `SELECT ... FOR UPDATE` sobre la fila de la invitación ANTES de
--       validar su estado y su vigencia. La segunda transacción espera y,
--       cuando la primera commitea, su predicado `status = 'pending'` ya no
--       matchea: sale por el rechazo de token inválido, sin segunda
--       membresía.
--   (b) binding de email resuelto **contra auth.users, no contra el claim**:
--         v_caller_email := COALESCE(auth.jwt()->>'email',
--                                    (SELECT email FROM auth.users WHERE id = auth.uid()))
--       El backend propio NO empuja el payload del token a Postgres: empuja
--       una reconstrucción mínima, json.dumps({"sub": …, "role":
--       "authenticated"}) (backend/core/database.py:116, alcance
--       transaccional, y :174, sesión) — `email` nunca viaja. Como la
--       administración de miembros ya vive en FastAPI
--       (backend/routers/members.py), un guard keyeado en
--       auth.jwt()->>'email' rechazaría el 100% de las aceptaciones que
--       lleguen por ese camino. Este repo ya tiene una policy MUERTA por
--       exactamente este error (20260724000001_c31_wsaa_access_tickets.sql:
--       40-41, keyeada en auth.jwt()->>'account_id'). El COALESCE conserva
--       el camino PostgREST (donde el claim sí viaja) sin depender de él.
--       Fail-closed: si no se puede resolver ningún email, se rechaza.
--   (c) el rechazo usa el MISMO contrato que el token inexistente/vencido
--       (P0404 + 'P404: invalid or expired invitation token'), así que la
--       respuesta no confirma que el token sea válido para otra identidad y
--       el consumidor no necesita distinguir el caso.
--
-- `account_invitations.email` es NOT NULL en producción (verificado el
-- 2026-09-16 contra information_schema.columns, reconfirmado en el checkpoint
-- 1.7 y una tercera vez en la revisión del grupo 10), así que la fila
-- "invitación sin email" no puede existir hoy.
--
-- AUN ASÍ el guard la contempla, y no por prolijidad. La revisión adversarial
-- del grupo 10 MIDIÓ que, sin una comprobación explícita de NULL, el guard
-- degradaba **fail-OPEN**: con `email` NULL, `lower(v_inv.email) <>
-- lower(v_caller_email)` da NULL, la condición del IF queda NULL, la rama no
-- se toma y un desconocido entra. Se reprodujo en la base local aflojando el
-- NOT NULL: la RPC le devolvió `{"role":"member","roles":["viewer"]}` a un
-- usuario que no era el invitado. La versión anterior de este archivo
-- razonaba —correctamente— que el caso era imposible, y sacaba de ahí la
-- conclusión equivocada: que no hacía falta escribirlo. Lo que importaba no
-- era el caso sino la DIRECCIÓN de la degradación ante un cambio de schema
-- futuro. Un guard de auth falla cerrado.
--
-- INTEGRIDAD DE FUNCIÓN — el cuerpo de abajo parte del cuerpo VIVO DE PROD,
-- capturado por pg_get_functiondef el 2026-09-16 vía MCP (sólo lectura):
-- md5 02517dd9bcbbabd723a5bbb0f1c1a406, 4853 caracteres, prosecdef=true,
-- firma ÚNICA (1 overload), proacl {postgres,authenticated,service_role} —
-- idéntico a lo medido en el propose y en el checkpoint 1.3 (diff línea a
-- línea contra 20261050000001:316-435 con \r removido: cero diferencias).
-- Todo lo que no sea (a), (b) y (c) queda EXACTAMENTE como estaba,
-- comentarios incluidos.
--
-- DROP + CREATE (no CREATE OR REPLACE): la firma no cambia, pero el DROP es
-- deliberado para que el archivo re-emita las ACLs de forma explícita y
-- verificable, con el gate asserteando el resultado. Es PostgreSQL —no
-- Supabase— el que otorga EXECUTE a PUBLIC en toda función nueva, así que el
-- REVOKE va contra PUBLIC además de anon: revocar sólo `anon` dejaría el
-- permiso vivo por la vía de PUBLIC. El COMMENT también se pierde con el
-- DROP y se re-emite abajo.
--
-- ─── (2) fiscal_documents en la publicación de tiempo real ──────────────────
--
-- FiscalDocumentBadge (frontend/components/fiscal/FiscalDocumentBadge.tsx:
-- 76-96) se suscribe a postgres_changes UPDATE sobre public.fiscal_documents
-- desde que se escribió, y NUNCA recibió un evento: la publicación
-- supabase_realtime contiene una sola tabla, `notifications` (verificado en
-- prod el 2026-09-16 y reconfirmado en el checkpoint 1.4). La transición
-- pending_cae -> authorized|rejected ocurre en un proceso de background,
-- fuera del request que emitió el comprobante, así que sin la publicación el
-- badge se queda en "pendiente" hasta que el usuario recargue.
--
-- El alcance de la entrega lo impone la RLS por account_id que la tabla YA
-- tiene (spec afip-fiscal-document): el filtro del canal es optimización de
-- red, no el límite de seguridad. REPLICA IDENTITY se deja como está
-- (default/PK, idéntica a notifications — medido en prod y en local).
--
-- El ALTER va GUARDADO contra pg_publication_tables: reaplicarlo sobre un
-- entorno donde la tabla ya pertenece a la publicación no falla (Postgres
-- respondería 42710 sin el guard) y no la duplica.
--
-- ─── (3) COMMENT de rpc_my_active_account_roles: sus DOS consumidores ───────
--
-- Hallazgo m3 de la revisión adversarial del apply. El COMMENT que dejó
-- 20261048000001 (v3-rbac-multirole Parte B) afirma "Único consumidor: el
-- fallback a DB de require_account_role … CUANDO NI EL CLAIM DEL CONJUNTO NI
-- EL SINGULAR VIAJAN EN EL JWT". Desde D12 de ESTE change eso es falso: para
-- toda capacidad sensible (backend/core/rbac.py::SENSITIVE_CAPABILITIES, hoy
-- CAN_CONFIGURE = owner/admin) esa misma función es el camino PRIMARIO — se la
-- consulta con claim o sin claim, porque ahí el claim es un caché y la base es
-- la autoridad. Es la misma clase de defecto documental que D15 existe para
-- borrar, y justo sobre la función que D12 vuelve load-bearing. Una sentencia,
-- idempotente (COMMENT reescribe), sin tocar el cuerpo ni las ACLs.
--
-- CANDADOS: supabase/tests/test_accept_invitation_binding.sql (9 bloques:
-- conducta del binding en las dos formas de claims, mayúsculas, doble canje,
-- integridad del cuerpo vivo, overloads, ACLs, fail-closed con email NULL y el
-- COMMENT de (3) asserteado sobre el texto VIVO) y
-- supabase/tests/test_realtime_publication.sql (las dos tablas en la
-- publicación + idempotencia del ALTER probada dos veces), los dos cableados
-- a .github/workflows/KPI_Validation.yml.
--
-- SIN superficie frontend propia en este archivo (la Parte A entera lo
-- declara): el efecto visible es que el badge de CAE empieza a recibir
-- eventos, con el código del badge sin tocar.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- (1) rpc_accept_invitation(text)
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.rpc_accept_invitation(text);

CREATE FUNCTION public.rpc_accept_invitation(p_token text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id    uuid;
  v_caller_email text;
  v_inv          record;
  v_plan         text;
  v_max_users    int;
  v_cur_users    int;
  v_member_id    uuid;
  v_roles        text[];
  v_role         text;
  v_role_legacy  text;
BEGIN
  v_caller_id := (SELECT auth.uid());
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'P0001';
  END IF;

  -- auth-hardening-jwt-cookies (D14, F13): identidad del aceptante para el
  -- binding de email. Se resuelve contra auth.users y NO contra el claim: el
  -- backend propio empuja a Postgres sólo {"sub","role"}
  -- (backend/core/database.py:116 y :174), sin email, así que un guard
  -- keyeado en el claim rechazaría el 100% de las aceptaciones que lleguen
  -- por FastAPI. El claim se usa como atajo equivalente cuando está
  -- presente (camino PostgREST).
  v_caller_email := COALESCE(
    auth.jwt()->>'email',
    (SELECT u.email FROM auth.users u WHERE u.id = v_caller_id)
  );

  -- auth-hardening-jwt-cookies (D14): FOR UPDATE -- lock de la fila ANTES de
  -- validar estado y vigencia. Dos aceptaciones concurrentes del mismo token
  -- ya no pueden observar ambas el estado pendiente: la segunda espera acá y,
  -- al commitear la primera, su predicado status='pending' deja de matchear.
  SELECT *
  INTO   v_inv
  FROM   public.account_invitations
  WHERE  token     = p_token
    AND  status    = 'pending'
    AND  expires_at > now()
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    -- Ronda 1 adversarial (finding NIT): P0001 -> P0404, texto conservado --
    -- mismo criterio D18 que el resto de esta migración (regla dura del
    -- proyecto: ERRCODEs P04xx del catálogo, nunca P0001, para un 404/409
    -- con mapeo obvio).
    RAISE EXCEPTION 'P404: invalid or expired invitation token'
      USING ERRCODE = 'P0404';
  END IF;

  -- auth-hardening-jwt-cookies (D14, F13): la invitación es de quien la
  -- recibió. Comparación insensible a mayúsculas en ambos lados; MISMO
  -- ERRCODE y MISMO texto que el rechazo por token inexistente/vencido, para
  -- que la respuesta no confirme que el token es válido para otra identidad.
  --
  -- Fail-closed por los DOS lados, y el de la invitación NO es decorativo
  -- (revisión adversarial del grupo 10, hallazgo MEDIDO en la base local):
  -- sin `v_inv.email IS NULL` explícito, una invitación con email NULL hacía
  -- que `lower(v_inv.email) <> lower(v_caller_email)` evaluara a NULL —
  -- lógica de tres valores — la condición del IF quedara NULL, la rama NO se
  -- tomara, y **un desconocido entrara a la cuenta**. Reproducido: aflojando
  -- el NOT NULL en local, `rpc_accept_invitation` le devolvió membresía con
  -- rol a un usuario ajeno al email invitado.
  -- `account_invitations.email` es NOT NULL en prod (re-verificado hoy), así
  -- que hoy esa fila no puede existir y esta cláusula es inalcanzable. Se
  -- declara igual porque lo que estaba en juego no era el caso, era la
  -- DIRECCIÓN en que degrada el guard si ese constraint se cayera algún día:
  -- un guard de auth debe fallar cerrado, no abierto, y la cláusula cuesta
  -- una línea. Candado: bloque (8) de test_accept_invitation_binding.sql.
  IF v_caller_email IS NULL
     OR v_inv.email IS NULL
     OR lower(v_inv.email) <> lower(v_caller_email) THEN
    RAISE EXCEPTION 'P404: invalid or expired invitation token'
      USING ERRCODE = 'P0404';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.account_members
    WHERE  account_id = v_inv.account_id AND user_id = v_caller_id
  ) THEN
    -- Ronda 1 adversarial (finding NIT): P0001 -> P0409, texto conservado.
    RAISE EXCEPTION 'P409: caller is already a member of account %', v_inv.account_id
      USING ERRCODE = 'P0409';
  END IF;

  -- v3-rbac-multirole humo fix (bug 1, 2026-09-12): plan EFECTIVO de la
  -- cuenta de la invitación -- el cupo evaluado al ACEPTAR debe coincidir
  -- con el efectivo evaluado al invitar (rpc_invite_member), nunca con
  -- accounts.billing_plan crudo.
  v_plan := public.get_effective_plan(v_inv.account_id);
  SELECT pl.max_users INTO v_max_users FROM public.plan_limits pl WHERE pl.plan = v_plan;
  IF v_max_users IS NULL THEN v_max_users := 1; END IF;

  -- D18: cuenta MIEMBROS, no asignaciones (sin cambios de fondo).
  SELECT COUNT(*) INTO v_cur_users FROM public.account_members WHERE account_id = v_inv.account_id;

  IF v_cur_users >= v_max_users THEN
    -- D18: P0001 -> P0402 (cupo), MISMO código que rpc_invite_member --
    -- misma clase de error, texto conservado.
    RAISE EXCEPTION 'P403: member quota reached (% / %)', v_cur_users, v_max_users
      USING ERRCODE = 'P0402';
  END IF;

  v_member_id := gen_random_uuid();

  -- Conjunto a otorgar (grupo 15): `roles` si la invitación la trae
  -- (creada por el overload de 3 args, ya con conjunto); si no, deriva del
  -- `role` legacy (overload de 2 args, o una invitación pre-migración) --
  -- mismo mapeo D2 que el backfill/rpc_change_member_role: member->viewer,
  -- owner/admin idénticos.
  v_roles := COALESCE(
    v_inv.roles,
    ARRAY[CASE COALESCE(v_inv.role, 'member') WHEN 'member' THEN 'viewer' ELSE v_inv.role END]
  );

  -- account_members.role: cualquier valor válido del CHECK sirve acá -- el
  -- trigger BEFORE INSERT (fn_derive_account_member_role, Parte A) lo
  -- sobreescribe de inmediato a 'member' (el pivot todavía no tiene ninguna
  -- fila para v_member_id en este instante), y la re-derivación CORRECTA
  -- ocurre sola cuando el loop de abajo inserta en el pivot (cada INSERT
  -- dispara trg_touch_account_member_role -> vuelve a tocar account_members
  -- -> trg_derive_account_member_role recalcula ya con el pivot poblado).
  INSERT INTO public.account_members
    (id, account_id, user_id, role, created_at)
  VALUES
    (v_member_id, v_inv.account_id, v_caller_id, 'member', now());

  -- Escritura a través del pivot (D3) — TODAS las asignaciones equivalentes,
  -- no sólo una. assigned_by = quien invitó (invited_by), nunca el propio
  -- invitado (mismo criterio que la Parte A).
  FOREACH v_role IN ARRAY v_roles LOOP
    INSERT INTO public.account_member_roles
      (account_id, member_id, role, assigned_by, assigned_at)
    VALUES
      (v_inv.account_id, v_member_id, v_role, v_inv.invited_by, now())
    ON CONFLICT (member_id, role) DO NOTHING;
  END LOOP;

  UPDATE public.account_invitations SET status = 'accepted' WHERE id = v_inv.id;

  -- D19/R8 (el derivado singular sobrevive): `role` se lee de la columna
  -- espejo YA RE-DERIVADA por el loop de arriba (nunca recalculado a mano
  -- acá -- una segunda fórmula de precedencia divergiría en silencio de la
  -- única fuente real, D3) -- mantiene el contrato heredado del cuerpo de
  -- la Parte A (que el gate test_membership_rpcs_pivot_rewrite.sql sigue
  -- verificando) para quien todavía consuma `role`; `roles` es el conjunto
  -- COMPLETO, nuevo en esta parte.
  SELECT role INTO v_role_legacy FROM public.account_members WHERE id = v_member_id;

  RETURN json_build_object(
    'account_member_id', v_member_id,
    'account_id',        v_inv.account_id,
    'role',              v_role_legacy,
    'roles',             to_jsonb(v_roles)
  );
END;
$function$;

-- ACLs re-emitidas tras el DROP. El proacl vivo de prod antes de este archivo
-- era {postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}:
-- se reproduce exactamente. El REVOKE contra PUBLIC no es decorativo — es
-- PostgreSQL el que otorga EXECUTE a PUBLIC en toda función nueva, así que sin
-- esta línea `anon` seguiría pudiendo ejecutarla por esa vía aunque se le
-- revoque nominalmente.
REVOKE ALL ON FUNCTION public.rpc_accept_invitation(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_accept_invitation(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.rpc_accept_invitation(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_accept_invitation(text) TO service_role;

-- El COMMENT se pierde con el DROP: se re-emite el vigente + lo que agrega
-- este archivo.
COMMENT ON FUNCTION public.rpc_accept_invitation(text) IS
  'auth-hardening-jwt-cookies Parte A (D14, hallazgo F13 de la auditoría del '
  '2026-09-14): la aceptación exige que la identidad autenticada corresponda '
  'al email de la invitación (comparación con lower() en ambos lados), con el '
  'email del aceptante resuelto por COALESCE(auth.jwt()->>''email'', SELECT '
  'email FROM auth.users WHERE id = auth.uid()) -- contra auth.users y NO '
  'sólo contra el claim, porque el backend propio empuja a Postgres sólo '
  '{"sub","role"} (backend/core/database.py:116 y :174) y un guard keyeado en '
  'el claim rechazaría toda aceptación que llegue por FastAPI. El rechazo usa '
  'el MISMO contrato que el token inexistente/vencido (P0404 + "P404: invalid '
  'or expired invitation token") para no confirmar que el token es válido '
  'para otra identidad. El rechazo es fail-closed por los DOS lados (email '
  'del aceptante NULL y email de la invitación NULL): sin la comprobación '
  'explícita de NULL sobre la invitación, la lógica de tres valores dejaba la '
  'condición en NULL y el guard degradaba FAIL-OPEN -- medido en la base '
  'local, no hipotético. Y la fila de la invitación se toma con SELECT ... FOR '
  'UPDATE ANTES de validar estado y vigencia, así que dos aceptaciones '
  'concurrentes del mismo token no pueden observar ambas el estado pendiente. '
  'Candado: supabase/tests/test_accept_invitation_binding.sql. '
  '— membership-quota-effective-plan (humo v3-rbac-multirole, bug 1, '
  '2026-09-12): el cupo se evalúa contra el plan EFECTIVO de la cuenta de la '
  'invitación (public.get_effective_plan), no accounts.billing_plan crudo -- '
  'debe coincidir con el efectivo que ya evalúa rpc_invite_member al '
  'invitar. Acepta CUALQUIER conjunto de roles, lee account_invitations.roles '
  'si está poblada (overload de 3 args), si no deriva del `role` legacy '
  '(overload de 2 args / fila pre-migración, mismo mapeo D2). Escribe TODAS '
  'las asignaciones equivalentes a través del pivot en un FOREACH -- el '
  'espejo (account_members.role) converge sólo tras el ÚLTIMO insert del '
  'loop, vía trg_touch_account_member_role + trg_derive_account_member_role '
  '(Parte A). D18: cupo P0001->P0402 (mismo código que rpc_invite_member). '
  'Ronda 1 adversarial (finding NIT): "invalid or expired invitation token" '
  'P0001->P0404 y "already a member" P0001->P0409, texto conservado. "Not '
  'authenticated" SIGUE P0001.';


-- ─────────────────────────────────────────────────────────────────────────────
-- (2) public.fiscal_documents en la publicación supabase_realtime
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename  = 'fiscal_documents'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.fiscal_documents;
    RAISE NOTICE 'auth-hardening-jwt-cookies (D14): public.fiscal_documents agregada a supabase_realtime.';
  ELSE
    RAISE NOTICE 'auth-hardening-jwt-cookies (D14): public.fiscal_documents ya pertenecía a supabase_realtime -- no-op.';
  END IF;
END $$;


-- ─────────────────────────────────────────────────────────────────────────────
-- (3) COMMENT de rpc_my_active_account_roles — sus DOS consumidores (m3)
-- ─────────────────────────────────────────────────────────────────────────────
--
-- No se toca el cuerpo ni las ACLs de esa función: sólo su descripción, que
-- desde D12 describía la mitad de sus consumidores y mandaba a leer el lugar
-- equivocado. El gate lo assertea sobre el COMMENT VIVO (bloque 9), no sobre
-- este archivo: un COMMENT posterior lo reescribiría sin que el archivo se
-- enterara.

COMMENT ON FUNCTION public.rpc_my_active_account_roles() IS
  'v3-rbac-multirole Parte B (D10, R6): roles ACTIVOS del CALLER en su '
  'membresía más antigua (mismo criterio determinístico que get_account_id '
  '/ el hook, D4 de v31-authz-token-hook) -- SIN parámetro, no hay ningún '
  'member_id que un tercero pueda pasar. DOS consumidores, los dos en '
  'require_account_role (backend/core/guards.py): (1) el fallback a DB '
  'cuando ni el claim del conjunto ni el singular viajan en el JWT, y '
  '(2) desde auth-hardening-jwt-cookies D12, el camino PRIMARIO de toda '
  'capacidad sensible (rbac.py::SENSITIVE_CAPABILITIES, hoy CAN_CONFIGURE '
  '= owner/admin): ahí se la consulta AUNQUE el claim esté presente, porque '
  'para las acciones de configuración el claim es un caché y la base es la '
  'autoridad -- un rol revocado o vencido deja de autorizar sin esperar a '
  'la próxima emisión de token. Array vacío (no NULL) si el caller no es '
  'miembro de ninguna cuenta -- COALESCE explícito (ronda 1 adversarial, '
  'nit 7), mismo contrato que member_active_roles/'
  'account_user_active_roles de la Parte A.';


-- =============================================================================
-- VERIFICATION (post-merge, MCP read-only):
--   SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
--     AND p.proname = 'rpc_accept_invitation';               -- 1 (sin overload)
--
--   SELECT position('FOR UPDATE' in pg_get_functiondef('public.rpc_accept_invitation(text)'::regprocedure)) > 0,
--          position('auth.users' in pg_get_functiondef('public.rpc_accept_invitation(text)'::regprocedure)) > 0;
--   -- las dos true: el lock y la resolución del email contra auth.users viven
--   -- en el cuerpo VIVO (el gate lo assertea además con los comentarios
--   -- removidos y con el orden respecto del primer INSERT).
--
--   SELECT p.proacl FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
--     AND p.proname = 'rpc_accept_invitation';
--   -- {postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}
--   -- sin entrada de PUBLIC (un ítem sin grantee, "=X/postgres") ni de anon.
--
--   SELECT tablename FROM pg_publication_tables WHERE pubname = 'supabase_realtime';
--   -- notifications Y fiscal_documents.
-- =============================================================================
