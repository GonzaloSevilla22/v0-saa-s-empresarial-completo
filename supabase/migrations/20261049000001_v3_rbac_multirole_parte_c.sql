-- =============================================================================
-- v3-rbac-multirole — PARTE C (superficie de administración, MEDIO). Grupos
-- 14-19 de tasks.md. Design ref: openspec/changes/v3-rbac-multirole/design.md
-- (D17, D18, D19, D20).
--
-- Checkpoint de estado real (grupo 14, 2026-09-11, read-only, prod vía MCP):
--   MAX(version) prod = 20261047000001 (296 migraciones) EN EL MOMENTO en
--   que se escribió esta migración -- Parte A YA mergeada y aplicada a
--   prod; Parte B (20261048000001) seguía "en vuelo" (PR #558 en CI,
--   todavía sin mergear), por eso el cuerpo VIVO de prod del que esta
--   migración PARTIÓ es el de la PARTE A (rpc_change_member_role,
--   rpc_remove_member, rpc_accept_invitation, rpc_invite_member[x2],
--   rpc_my_account_role, handle_new_user), NUNCA el de Parte B.
--
--   RE-VERIFICADO en la ronda 1 de revisión adversarial (2026-09-12, prod
--   vía MCP read-only): `MAX(version) = 20261048000001`, **297**
--   migraciones -- Parte B YA está mergeada y aplicada. Esto NO cambia
--   ninguna conclusión de arriba: Parte B nunca tocó estas 6 funciones (ver
--   14.2 debajo), así que el cuerpo vivo de prod del que esta migración
--   partió sigue siendo, byte a byte, el de la Parte A. Migración de esta
--   parte: 20261049000001.
--
--   14.2: cuerpo vivo capturado vía pg_get_functiondef, diff línea a línea
--   con \r removido -- IDÉNTICO entre prod (Parte A sola) y local (Parte A+B
--   ya aplicadas acá, porque Parte B NUNCA tocó estas 6 funciones):
--     rpc_change_member_role   -- ver sección 3 de esta migración
--     rpc_remove_member        -- NO tocada por esta parte (queda igual)
--     rpc_accept_invitation    -- ver sección 5
--     rpc_invite_member(text,uuid)       -- ver sección 4 (2-arg, TeamSection.tsx)
--     rpc_invite_member(text,uuid,text)  -- reemplazada por (text,uuid,text[])
--                                           en la sección 4 (3-arg, /organizacion/invitar)
--     rpc_my_account_role      -- NO tocada por esta parte
--
-- Implementa:
--   D17 Retira el gate comercial "admin requiere plan pro" de
--       rpc_change_member_role (sección 3) y de AMBOS overloads de
--       rpc_invite_member (sección 4) -- el 2-arg nunca lo tuvo, así que ahí
--       sólo se normalizan ERRCODEs. Efecto colateral corregido en el mismo
--       PR: knowledge-base/03_actores_y_roles.md (task 15.6, fuera de esta
--       migración SQL).
--   D18 max_users sigue contando MIEMBROS, no asignaciones -- ninguna query
--       de cupo cambia (siguen COUNT(*) FROM account_members). Normaliza los
--       P0001 de rpc_invite_member (ambos overloads) y rpc_accept_invitation
--       a P04xx CONSERVANDO EL TEXTO DEL MENSAJE (precedente: rpc_close_branch
--       P0409->P0428): P0402 (cupo, 403 -- código nuevo, verificado libre),
--       P0407 (invitación duplicada, 409 -- código nuevo, verificado libre),
--       P0403 (falta de autoridad -- reutilizado, ya existe desde D14 de la
--       Parte B con el MISMO significado "rol/permiso insuficiente"). El
--       design (D18) sólo enumera "cupo, invitación duplicada, falta de
--       autoridad" -- las otras dos condiciones de rpc_accept_invitation
--       ("Not authenticated", "token inválido/vencido", "ya es miembro")
--       quedaban P0001 en la redacción original, fuera de alcance
--       declarado. RONDA 1 ADVERSARIAL (finding NIT): "token inválido/
--       vencido" (P0404) y "ya es miembro" (P0409) son un 404/409 con
--       mapeo obvio a un ERRCODE del catálogo YA existente -- se mapean acá
--       mismo (regla dura del proyecto: nunca P0001). "Not authenticated"
--       SIGUE P0001 a propósito: mismo criterio que las DEMÁS RPCs de este
--       archivo (rpc_invite_member, ambos overloads) para esa MISMA
--       condición -- en la práctica es inalcanzable vía el backend/frontend
--       (get_current_user la corta antes), así que remapearla sólo ahí
--       rompería la simetría sin ganar nada real.
--   D19 Sin cambios de código acá -- resuelto en frontend (grupo 16).
--
--   HALLAZGO REAL (grupo 15, no anticipado por el design -- encontrado
--   ejercitando rpc_invite_member de VERDAD por primera vez, cosa que NINGÚN
--   gate SQL anterior hacía): las DOS overloads de rpc_invite_member llaman
--   `gen_random_bytes(32)` sin calificar de esquema, bajo `SET search_path TO
--   'public'`. `pgcrypto` vive en el esquema `extensions`, NO en `public` --
--   verificado IDÉNTICO en prod (`pg_extension.extnamespace` = 'extensions')
--   y en local. Con ese search_path, `gen_random_bytes` NO resuelve: CUALQUIER
--   invitación (por cualquiera de las dos overloads, incluida la de
--   TeamSection.tsx que NUNCA tocó este change) falla con
--   `function gen_random_bytes(integer) does not exist` -- un 500 genérico
--   para el usuario, sin relación aparente con RBAC. Coherente con la
--   medición del propio checkpoint de este design (7.2/context: "0
--   invitaciones pendientes vigentes" en las 39 cuentas reales) -- no hay
--   evidencia de que esta función haya funcionado NUNCA por esta vía.
--   Corregido en AMBAS overloads (secciones 4) calificando la llamada como
--   `extensions.gen_random_bytes(32)` -- explícito, no se amplía el
--   search_path de la función (ampliarlo sería la opción menos segura para
--   una SECURITY DEFINER). Ningún otro llamador de esta migración usa
--   `gen_random_bytes` (accept_invitation no genera tokens).
--   RPCs NUEVAS de asignación/revocación de rol (sección 1) y de lectura de
--       miembros+roles (sección 2), SECURITY DEFINER, search_path fijo,
--       REVOKE de anon/PUBLIC explícito, EXECUTE sólo a authenticated. La
--       autoridad sigue LITERALMENTE la spec de org-roles ("Cambio de rol
--       controlado por jerarquía"): el propietario gestiona cualquier rol;
--       el administrador gestiona roles operativos y NUNCA puede otorgar NI
--       retirar los roles de propietario o administrador (restricción sobre
--       el ROL pedido, no sobre la identidad del target -- ver nota en la
--       sección 1). El invariante de owner (P0405, Parte A) y el CHECK de
--       vencimiento de owner (P0406, Parte A) siguen vivos sin duplicarse:
--       se disparan solos vía los triggers ya existentes sobre el pivot.
--   Invitación con CONJUNTO de roles (D-account-membership-roles, task 15.5):
--       account_invitations gana la columna `roles text[]` (NULL = invitación
--       legacy de un solo rol, vía el overload 2-arg o una fila pre-migración);
--       rpc_invite_member(text,uuid,text[]) reemplaza al overload de 3 args
--       (DROP FUNCTION + CREATE, NO CREATE OR REPLACE con DEFAULT en el
--       tercer parámetro -- el overload de 2 args SIGUE VIVO y ACTIVO
--       [TeamSection.tsx, "quick invite" sin selector de rol], así que un
--       tercer parámetro con DEFAULT crearía la ambigüedad 42725 ya conocida
--       por este proyecto: una llamada con 2 argumentos nombrados
--       (p_email, p_account_id) calzaría en AMBOS overloads. p_roles queda
--       SIN DEFAULT -- el caller SIEMPRE debe pasarlo, aunque sea NULL o {}
--       explícito, lo que además resuelve la ambigüedad por ARIDAD, no sólo
--       por tipo). rpc_accept_invitation (sección 5) lee `roles` si está
--       poblada, si no deriva del `role` legacy (compatibilidad con
--       invitaciones creadas antes de esta migración o vía el 2-arg).
--
-- REGLA DE INTEGRIDAD DE FUNCIÓN (R9): rpc_change_member_role,
-- rpc_invite_member(text,uuid), rpc_accept_invitation PARTEN del cuerpo VIVO
-- de prod (= Parte A, ver 14.2 arriba) -- CREATE OR REPLACE puro, MISMA
-- firma, ACLs preservadas. rpc_invite_member(text,uuid,text) es la ÚNICA
-- excepción deliberada: cambia de firma (tercer parámetro text->text[]), por
-- lo que se DROPea y se recrea con firma nueva (nunca CREATE OR REPLACE
-- sobre una firma distinta -- eso falla con 42P13). Ninguna de las 4
-- funciones reescritas queda con overload fantasma (gate de introspección al
-- final de este archivo lo verifica).
--
-- Sin superficie frontend en ESTA migración SQL (declarado) -- la superficie
-- de /organizacion/roles y /organizacion/invitar vive en el frontend
-- (grupos 16-18), fuera de este archivo.
--
-- GOVERNANCE: MEDIO (D0 del design) -- sign-off del PO 2026-09-11.
-- APPLY: npx supabase db push (NUNCA MCP apply_migration).
--
-- ROLLBACK (design §Migration Plan -- "revert de frontend estándar; las
-- asignaciones múltiples ya hechas quedan en la tabla, inertes hasta
-- re-desplegar"):
--   -- 1. DROP FUNCTION IF EXISTS public.rpc_assign_member_role(uuid, uuid, text, timestamptz);
--   -- 2. DROP FUNCTION IF EXISTS public.rpc_revoke_member_role(uuid, uuid, text);
--   -- 3. DROP FUNCTION IF EXISTS public.rpc_list_account_members(uuid);
--   -- 4. Restaurar rpc_change_member_role / rpc_invite_member(text,uuid) /
--   --    rpc_accept_invitation al cuerpo capturado en 14.2 (con el gate de
--   --    plan y los ERRCODE P0001 originales).
--   -- 5. DROP FUNCTION public.rpc_invite_member(text, uuid, text[]); luego
--   --    recrear rpc_invite_member(text, uuid, text) con el cuerpo original.
--   -- 6. ALTER TABLE public.account_invitations DROP COLUMN IF EXISTS roles;
--      (sin pérdida real: ninguna fila viva depende de esa columna para nada
--      fuera de esta migración)
-- =============================================================================


-- =============================================================================
-- 1. RPCs nuevas de asignación / revocación de rol sobre el pivot.
--
--    Autoridad (org-roles, "Cambio de rol controlado por jerarquía" --
--    requirement MODIFICADO por este change, normativo): el propietario
--    gestiona CUALQUIER rol del catálogo; el administrador gestiona roles
--    OPERATIVOS y NUNCA puede otorgar NI retirar los roles de propietario o
--    administrador. La restricción es sobre el ROL PEDIDO (p_role), NO sobre
--    la identidad del target -- a diferencia de rpc_change_member_role /
--    rpc_remove_member (Parte A, sin tocar en esta migración), que restringen
--    por el ROL LEGACY ACTUAL del target ("admin sólo opera sobre targets
--    'member'"). Esa es la semántica de las dos RPCs LEGACY (cambiar el rol
--    único o expulsar a alguien por completo); ésta es la semántica de las
--    RPCs NUEVAS (agregar/quitar UN rol del conjunto), y el requirement de
--    org-roles que las gobierna está escrito en términos del rol, no del
--    target -- se sigue la letra de la spec, no una inferencia.
--
--    "Nadie se asigna owner": no hace falta código dedicado -- se deriva de
--    la propia jerarquía (sólo un owner pasa el primer IF; un admin es
--    rechazado por el segundo si p_role IN ('owner','admin'); un no-miembro
--    cae al ELSE). "Nadie quita al último owner": lo sigue haciendo el
--    invariante DEFERRABLE de la Parte A (P0405), disparado automáticamente
--    por el DELETE de la sección de revocación -- no se duplica acá.
--    "Owner sin expires_at": el trigger BEFORE INSERT/UPDATE de la Parte A
--    (fn_guard_account_member_role_no_owner_expiry, P0406) se dispara solo
--    sobre el INSERT/UPDATE de más abajo -- tampoco se duplica.
--
--    RONDA 1 ADVERSARIAL (finding MINOR): la restricción "sobre el ROL
--    PEDIDO, no la identidad del target" de arriba dejaba un hueco -- un
--    ADMIN podía modificar el conjunto COMPLETO de un OWNER (o de otro
--    ADMIN) con tal de pedir un rol operativo (`rpc_assign_member_role(acc,
--    <owner>, 'viewer', NULL)` se aceptaba; lo mismo para revocar). No
--    escala privilegios (el owner sigue siendo owner por el espejo legacy
--    y por `is_account_writer`), pero es un principal de MENOR autoridad
--    editando los permisos de uno MAYOR -- el mismo criterio que ya
--    protege a las RPCs LEGACY (`rpc_change_member_role`/`rpc_remove_member`:
--    "admin sólo opera sobre targets 'member'"), aplicado acá sobre el
--    CONJUNTO ACTIVO del target en vez del rol legacy singular. Guard
--    nuevo, paso "2.5" en AMBAS funciones (después de resolver
--    `v_target_member_id` en la tenencia, antes del catálogo): si el
--    caller no es `owner` y el conjunto activo del TARGET contiene `owner`
--    o `admin`, se rechaza con P0403 -- sin importar qué `p_role` se haya
--    pedido. Reutiliza `member_active_roles(v_target_member_id)` (ya usada
--    por `is_account_writer` en la Parte B), sin una segunda RPC.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_assign_member_role(
  p_account_id      uuid,
  p_target_user_id  uuid,
  p_role            text,
  p_expires_at      timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id         uuid;
  v_caller_roles      text[];
  v_target_member_id  uuid;
BEGIN
  v_caller_id := (SELECT auth.uid());

  -- 1. Autoridad: roles ACTIVOS del caller en ESTA cuenta.
  v_caller_roles := public.account_user_active_roles(p_account_id, v_caller_id);

  IF 'owner' = ANY(v_caller_roles) THEN
    NULL; -- autoridad total
  ELSIF 'admin' = ANY(v_caller_roles) THEN
    IF p_role IN ('owner', 'admin') THEN
      RAISE EXCEPTION 'El administrador no puede otorgar el rol de propietario ni de administrador'
        USING ERRCODE = 'P0403';
    END IF;
  ELSE
    RAISE EXCEPTION 'Sin autoridad para asignar roles en esta cuenta'
      USING ERRCODE = 'P0403';
  END IF;

  -- 2. Tenencia: el target debe ser miembro de ESTA cuenta (P0404 -- mismo
  --    código que el resto de los guards de parte de este proyecto).
  SELECT id INTO v_target_member_id
  FROM   public.account_members
  WHERE  account_id = p_account_id AND user_id = p_target_user_id;

  IF v_target_member_id IS NULL THEN
    RAISE EXCEPTION 'El usuario no es miembro de esta cuenta'
      USING ERRCODE = 'P0404';
  END IF;

  -- 2.5. RONDA 1 ADVERSARIAL (finding MINOR, ver cabecera de la sección 1):
  --      un admin no puede modificar NINGÚN rol de un target que hoy tiene
  --      owner/admin activo, sin importar el rol PEDIDO -- antes de este
  --      guard, asignarle un rol operativo (p.ej. 'viewer') a un
  --      propietario se aceptaba igual.
  IF NOT ('owner' = ANY(v_caller_roles))
     AND (public.member_active_roles(v_target_member_id) && ARRAY['owner', 'admin']::text[])
  THEN
    RAISE EXCEPTION 'Sin autoridad para modificar los roles de un propietario o administrador'
      USING ERRCODE = 'P0403';
  END IF;

  -- 3. Catálogo: el rol debe existir (P0400 -- validación de payload; el
  --    FK de account_member_roles.role ya lo garantiza a nivel de dato, pero
  --    sin este chequeo previo el error sería un 23503 genérico sin mensaje
  --    propio).
  IF NOT EXISTS (SELECT 1 FROM public.account_role_catalog WHERE code = p_role) THEN
    RAISE EXCEPTION 'Rol inválido: % no existe en el catálogo', p_role
      USING ERRCODE = 'P0400';
  END IF;

  -- 4. Apply -- idempotente (D-account-membership-roles, "El mismo rol no
  --    se asigna dos veces"): ON CONFLICT (member_id, role) DO UPDATE en vez
  --    de DO NOTHING, para que reasignar un rol YA vigente permita RENOVAR
  --    su vencimiento (un admin extendiendo un acceso temporal) sin crear
  --    una segunda fila -- la unicidad (member_id, role) sigue intacta, y
  --    el UPDATE dispara el MISMO trigger BEFORE INSERT/UPDATE (owner+expiry,
  --    P0406) y el mismo audit_logs (role.assigned en el INSERT original,
  --    role.updated si es el camino ON CONFLICT -- Parte A, ronda 3).
  INSERT INTO public.account_member_roles
    (account_id, member_id, role, assigned_by, assigned_at, expires_at)
  VALUES
    (p_account_id, v_target_member_id, p_role, v_caller_id, now(), p_expires_at)
  ON CONFLICT (member_id, role) DO UPDATE
    SET expires_at  = EXCLUDED.expires_at,
        assigned_by = EXCLUDED.assigned_by,
        assigned_at = now();

  RETURN jsonb_build_object(
    'account_id', p_account_id,
    'user_id',    p_target_user_id,
    'role',       p_role,
    'expires_at', p_expires_at
  );
END;
$function$;

COMMENT ON FUNCTION public.rpc_assign_member_role(uuid, uuid, text, timestamptz) IS
  'v3-rbac-multirole Parte C (grupo 14): asigna UN rol del catálogo a un '
  'miembro, con vencimiento opcional. Autoridad por JERARQUÍA sobre el ROL '
  'pedido (owner: cualquiera; admin: nunca owner/admin -- P0403), tenencia '
  '(P0404), catálogo (P0400). Ronda 1 adversarial: además, un admin no '
  'puede tocar NINGÚN rol de un target que hoy tenga owner/admin activo, '
  'sin importar el rol pedido (P0403). Idempotente vía ON CONFLICT DO '
  'UPDATE -- reasignar un rol vigente renueva su expires_at en vez de '
  'duplicar. El invariante de owner (P0405) y el CHECK de owner sin '
  'vencimiento (P0406) los disparan los triggers YA existentes sobre el '
  'pivot (Parte A) -- no se reimplementan acá.';

REVOKE ALL ON FUNCTION public.rpc_assign_member_role(uuid, uuid, text, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_assign_member_role(uuid, uuid, text, timestamptz) TO authenticated;


CREATE OR REPLACE FUNCTION public.rpc_revoke_member_role(
  p_account_id      uuid,
  p_target_user_id  uuid,
  p_role            text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id         uuid;
  v_caller_roles      text[];
  v_target_member_id  uuid;
BEGIN
  v_caller_id := (SELECT auth.uid());

  -- 1. Autoridad -- mismo criterio que rpc_assign_member_role (jerarquía
  --    sobre el ROL pedido, no sobre la identidad del target).
  v_caller_roles := public.account_user_active_roles(p_account_id, v_caller_id);

  IF 'owner' = ANY(v_caller_roles) THEN
    NULL;
  ELSIF 'admin' = ANY(v_caller_roles) THEN
    IF p_role IN ('owner', 'admin') THEN
      RAISE EXCEPTION 'El administrador no puede retirar el rol de propietario ni de administrador'
        USING ERRCODE = 'P0403';
    END IF;
  ELSE
    RAISE EXCEPTION 'Sin autoridad para revocar roles en esta cuenta'
      USING ERRCODE = 'P0403';
  END IF;

  -- 2. Tenencia.
  SELECT id INTO v_target_member_id
  FROM   public.account_members
  WHERE  account_id = p_account_id AND user_id = p_target_user_id;

  IF v_target_member_id IS NULL THEN
    RAISE EXCEPTION 'El usuario no es miembro de esta cuenta'
      USING ERRCODE = 'P0404';
  END IF;

  -- 2.5. RONDA 1 ADVERSARIAL (finding MINOR, ver cabecera de la sección 1 y
  --      el guard gemelo en rpc_assign_member_role): un admin no puede
  --      revocarle NINGÚN rol a un target que hoy tiene owner/admin
  --      activo, sin importar el rol PEDIDO -- disparado ANTES del DELETE
  --      idempotente de más abajo, para que no dependa de que la fila
  --      exista (revocar un rol operativo que el target NO tiene vigente
  --      debe rechazarse igual, no pasar como no-op silencioso).
  IF NOT ('owner' = ANY(v_caller_roles))
     AND (public.member_active_roles(v_target_member_id) && ARRAY['owner', 'admin']::text[])
  THEN
    RAISE EXCEPTION 'Sin autoridad para modificar los roles de un propietario o administrador'
      USING ERRCODE = 'P0403';
  END IF;

  -- 3. Catálogo (mismo criterio que assign -- un rol inexistente en el
  --    catálogo no puede estar asignado, pero un typo merece P0400 propio en
  --    vez de un DELETE silencioso de 0 filas sin ninguna señal).
  IF NOT EXISTS (SELECT 1 FROM public.account_role_catalog WHERE code = p_role) THEN
    RAISE EXCEPTION 'Rol inválido: % no existe en el catálogo', p_role
      USING ERRCODE = 'P0400';
  END IF;

  -- 3.5. RONDA 2 ADVERSARIAL (finding MAJOR, corregido): sin este chequeo,
  --      revocar el ÚNICO owner activo de la cuenta respondía 200 con
  --      cuerpo de éxito pese a que la escritura se revertía -- el
  --      invariante de propietario sólo lo aplicaba el CONSTRAINT TRIGGER
  --      DEFERRABLE INITIALLY DEFERRED de la Parte A
  --      (fn_guard_account_owner_invariant, sección 4.2), que se evalúa al
  --      COMMIT, no dentro de esta función. Bajo v31-tenancy-pool-rls
  --      (palanca `tenancy_tx_scope_enabled` ON), la transacción del
  --      request commitea en el TEARDOWN de la dependencia `get_db_conn`
  --      (backend/core/database.py) -- DESPUÉS de que FastAPI ya serializó
  --      y envió la respuesta -- así que el mapeo P0405->409 que
  --      backend/core/errors.py declara para esta condición era, por
  --      construcción, INALCANZABLE por esta vía: reproducido contra el
  --      stack local completo (DELETE /members/{owner}/roles/owner -> 200
  --      {role:"owner",...}, GET /members inmediato mostraba al owner
  --      INTACTO, y el backend logueaba `RuntimeError: Caught handled
  --      exception, but response already started` al fallar el commit
  --      diferido). Se replica acá, de forma SÍNCRONA, el MISMO predicado
  --      EXACTO que el trigger diferido ("¿queda otro owner ACTIVO en la
  --      cuenta si esta fila se borra?") y el MISMO texto/ERRCODE -- el
  --      RAISE EXCEPTION ocurre DENTRO del `await` que el caller ya espera,
  --      antes de que la respuesta HTTP se construya. El constraint trigger
  --      DEFERRABLE queda como backstop de segunda capa, SIN TOCARLO: la
  --      deferencia es justamente lo que permite un revoke+assign de
  --      transferencia de propiedad dentro de la MISMA transacción sin
  --      rechazar el estado intermedio sin dueño (Parte A, D6) -- para
  --      escrituras DIRECTAS al pivot (`account_member_roles`), no a través
  --      de esta RPC: acá el chequeo 3.5 es SÍNCRONO, así que sólo el orden
  --      assign→revoke funciona (asignar el owner nuevo antes de revocar al
  --      viejo); un revoke→assign en la misma transacción se rechaza en el
  --      revoke, sin llegar a ver el assign que lo compensaría. El
  --      predicado sólo mira OTROS miembros (`amr.member_id <>
  --      v_target_member_id`) -- el propio target puede o no tener la fila
  --      vigente, es indistinto: lo que importa es si alguien MÁS la tiene.
  IF p_role = 'owner' THEN
    IF NOT EXISTS (
      SELECT 1
      FROM   public.account_member_roles amr
      WHERE  amr.account_id  = p_account_id
        AND  amr.role        = 'owner'
        AND  amr.member_id  <> v_target_member_id
        AND  (amr.expires_at IS NULL OR amr.expires_at > now())
    ) THEN
      RAISE EXCEPTION 'La cuenta debe conservar al menos un propietario activo'
        USING ERRCODE = 'P0405';
    END IF;
  END IF;

  -- 4. Apply -- idempotente por construcción: revocar un rol que el miembro
  --    NO tiene vigente (o nunca tuvo) borra 0 filas, sin error (D-account-
  --    membership-roles no exige rechazar esto, y es el comportamiento
  --    esperado de un DELETE declarativo). El chequeo 3.5 de arriba ya deja
  --    sin alcanzar, por construcción, el único camino por el que este
  --    DELETE podría dejar a la cuenta sin NINGÚN owner activo -- el
  --    constraint trigger DEFERRABLE de la Parte A
  --    (fn_guard_account_owner_invariant) sigue vivo como backstop (P0405 al
  --    COMMIT), pero no debería dispararse nunca a través de esta RPC.
  DELETE FROM public.account_member_roles
  WHERE  member_id = v_target_member_id AND role = p_role;

  RETURN jsonb_build_object(
    'account_id', p_account_id,
    'user_id',    p_target_user_id,
    'role',       p_role
  );
END;
$function$;

COMMENT ON FUNCTION public.rpc_revoke_member_role(uuid, uuid, text) IS
  'v3-rbac-multirole Parte C (grupo 14): revoca UN rol del catálogo a un '
  'miembro. Autoridad por JERARQUÍA sobre el ROL pedido (owner: cualquiera; '
  'admin: nunca owner/admin -- P0403), tenencia (P0404), catálogo (P0400). '
  'Ronda 1 adversarial: además, un admin no puede tocar NINGÚN rol de un '
  'target que hoy tenga owner/admin activo, sin importar el rol pedido '
  '(P0403) -- disparado ANTES del DELETE, no depende de que la fila exista. '
  'Revocar un rol no vigente (de un target sin owner/admin) es un no-op '
  'idempotente (0 filas). Ronda 2 adversarial (finding MAJOR, corregido): el '
  'invariante de propietario (P0405) se verifica acá mismo, de forma '
  'SÍNCRONA, ANTES del DELETE, replicando el predicado de '
  'fn_guard_account_owner_invariant -- el constraint trigger DEFERRABLE de '
  'la Parte A queda como backstop (se evalúa al COMMIT, que bajo '
  'v31-tenancy-pool-rls ocurre DESPUÉS de que la respuesta HTTP ya se '
  'construyó, dejando ese camino inalcanzable por el backend sin este '
  'chequeo síncrono).';

REVOKE ALL ON FUNCTION public.rpc_revoke_member_role(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_revoke_member_role(uuid, uuid, text) TO authenticated;


-- =============================================================================
-- 2. rpc_list_account_members — lectura de miembros + su conjunto de roles
--    (para el endpoint FastAPI GET /members). account_member_roles sigue
--    CERRADA por completo a authenticated/anon (Parte A) -- este helper es
--    el ÚNICO camino de lectura para el backend, con guard de tenencia
--    propio (nunca un GRANT desnudo de tabla, D3 de la Parte A).
--
--    Lectura abierta a CUALQUIER miembro de la cuenta (account-membership-
--    roles, "La gestión de miembros y sus roles tiene superficie propia":
--    "quien no tiene autoridad no ve las acciones de gestión" implica que SÍ
--    ve el listado) -- el guard de autoridad para escribir vive en las RPCs
--    de la sección 1, no acá.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_list_account_members(p_account_id uuid)
RETURNS TABLE (
  member_id   uuid,
  user_id     uuid,
  legacy_role text,
  created_at  timestamptz,
  name        text,
  email       text,
  roles       jsonb
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  -- NOTA: public.profiles NO tiene columna `email` (verificado contra el
  -- schema vivo -- el mismo hallazgo, pre-existente y ajeno a este change,
  -- que use-team-members.ts arrastra en silencio: su SELECT "id, name,
  -- email" contra profiles degrada a email=null porque PostgREST rechaza la
  -- columna inexistente y el caller ignora `profilesError`). El email real
  -- vive en auth.users -- se resuelve de ahí, no de profiles.
  SELECT
    am.id,
    am.user_id,
    am.role,
    am.created_at,
    p.name,
    u.email,
    COALESCE(
      (SELECT jsonb_agg(
                jsonb_build_object(
                  'role',       amr.role,
                  'expires_at', amr.expires_at,
                  'is_active',  (amr.expires_at IS NULL OR amr.expires_at > now())
                )
                ORDER BY amr.role
              )
       FROM   public.account_member_roles amr
       WHERE  amr.member_id = am.id),
      '[]'::jsonb
    ) AS roles
  FROM   public.account_members am
  LEFT JOIN public.profiles  p ON p.id = am.user_id
  LEFT JOIN auth.users       u ON u.id = am.user_id
  WHERE  am.account_id = p_account_id
    -- Guard de tenencia (fail-closed): sin esto, cualquier authenticated
    -- podría pasar el account_id de OTRO tenant y leer su nómina completa.
    -- El predicado es constante por fila (no depende de am.*) a propósito:
    -- si el caller no es miembro de p_account_id, la cuenta entera devuelve
    -- CERO filas, nunca una fuga parcial.
    AND EXISTS (
      SELECT 1 FROM public.account_members caller
      WHERE  caller.account_id = p_account_id
        AND  caller.user_id    = (SELECT auth.uid())
    )
  ORDER BY am.created_at;
$function$;

COMMENT ON FUNCTION public.rpc_list_account_members(uuid) IS
  'v3-rbac-multirole Parte C (grupo 14): lista los miembros de una cuenta '
  'con su conjunto COMPLETO de asignaciones (vigentes Y vencidas, cada una '
  'con is_active derivado -- la pantalla distingue una vencida de una '
  'vigente, account-membership-roles) + su rol heredado singular. Guard de '
  'tenencia inline (fail-closed): sin membresía del caller en p_account_id, '
  'CERO filas. Único camino de lectura del backend hacia el pivot, que sigue '
  'cerrado por completo a authenticated/anon (Parte A).';

REVOKE ALL ON FUNCTION public.rpc_list_account_members(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_list_account_members(uuid) TO authenticated;


-- =============================================================================
-- 3. rpc_change_member_role (D17) — retira el gate "admin requiere plan pro"
--    (paso 3 del cuerpo original), conservando TODO lo demás byte a byte:
--    misma firma, mismo contrato {ok}|{error}, mismas validaciones 1/1.5/1.6/
--    2/4, mismo Apply a través del pivot (Parte A). CREATE OR REPLACE puro
--    sobre el cuerpo vivo de prod (14.2) -- ACLs preservadas.
--
--    RONDA 2 ADVERSARIAL (finding NIT, corregido): la primera versión de
--    esta sección reemplazó los comentarios extensos de los pasos 1/1.5/1.6
--    del cuerpo vivo de prod (sección 6.1 de 20261047000001_..._parte_a.sql)
--    por una línea corta cada uno -- no eran decorativos: documentaban el
--    agujero de tenencia `NULL NOT IN (...)` que la ronda 1 de la Parte A
--    encontró y cerró, por qué se rechaza un rol funcional, y por qué se
--    corta cuando el target no es miembro. Restituidos verbatim (con una
--    única línea añadida en 1.5 que ata el paso al rpc_assign_member_role
--    nuevo) -- el único delta REAL del cuerpo, ahora también en los
--    comentarios, es la eliminación del paso 3 y de v_plan.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_change_member_role(p_account_id uuid, p_target_user_id uuid, p_new_role text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id        uuid;
  v_caller_role      text;
  v_target_role      text;
  v_owner_count      int;
  v_target_member_id uuid;
  v_new_code         text;
BEGIN
  v_caller_id := (SELECT auth.uid());

  SELECT role INTO v_caller_role
  FROM   public.account_members
  WHERE  account_id = p_account_id AND user_id = v_caller_id;

  -- 1. Caller must be owner or admin.
  --    Ronda 1 de revisión adversarial (finding MAJOR, agujero PREEXISTENTE
  --    a esta parte, no introducido por ella — verificado contra el cuerpo
  --    vivo de prod y la definición original de 20260606010000_roles_
  --    internos.sql, idéntico): si el caller NO es miembro de la cuenta,
  --    v_caller_role queda NULL y `NULL NOT IN (...)` evalúa a NULL (no a
  --    TRUE) — el RETURN nunca se ejecutaba y un tercero ajeno a la cuenta
  --    podía promover/degradar a cualquiera. Cerrado con el mismo criterio
  --    de la familia operacion-party-guard/cuenta-corriente-party-guard.
  IF v_caller_role IS NULL OR v_caller_role NOT IN ('owner', 'admin') THEN
    RETURN jsonb_build_object('error', 'Sin permisos');
  END IF;

  -- 1.5. Ronda 1 (finding MAJOR, corregido): ningún rol funcional puede
  --      asignarse todavía — el catálogo (sección 1) ya tiene 8 códigos,
  --      pero esta Parte A sólo habilita el vocabulario legacy (D3,
  --      comentario de la tabla del pivot: "en la práctica sólo existen
  --      filas owner/admin/viewer mientras A esté sola en prod"). Antes de
  --      esta migración, un código fuera de {owner,admin,member} fallaba
  --      con 23514 (CHECK account_members_role_values); reproducido en
  --      local: sin este guard, `rpc_change_member_role(..., 'seller')`
  --      devolvía {ok:true} y sembraba un rol funcional inerte en el pivot
  --      que la Parte B habría vuelto a otorgar permisos reales sin que
  --      nadie lo autorizara en ese momento.
  --      Parte C (grupo 14): sigue restringida a la tríada owner/admin/
  --      member -- la asignación de roles FUNCIONALES vive en
  --      rpc_assign_member_role (sección 1 de esta migración), no acá.
  IF p_new_role NOT IN ('owner', 'admin', 'member') THEN
    RETURN jsonb_build_object('error', 'Rol inválido');
  END IF;

  SELECT id, role INTO v_target_member_id, v_target_role
  FROM   public.account_members
  WHERE  account_id = p_account_id AND user_id = p_target_user_id;

  -- 1.6. Ronda 1 (finding minor, corregido): con el paso 5 reescrito para
  --      escribir el pivot (que tiene member_id NOT NULL), un target que
  --      no es miembro de la cuenta dejaba v_target_member_id en NULL y el
  --      INSERT reventaba con 23502 (crash / 500) en vez del {error} JSON
  --      que el cuerpo viejo devolvía (un UPDATE que afecta 0 filas no
  --      lanza excepción). Se corta acá, antes de que ese NULL se propague
  --      a la validación 2 o al INSERT del paso 5.
  IF v_target_member_id IS NULL THEN
    RETURN jsonb_build_object('error', 'Sin permisos para cambiar este rol');
  END IF;

  -- 2. Admin can only operate on 'member' targets and only set 'member'
  IF v_caller_role = 'admin' AND (v_target_role != 'member' OR p_new_role != 'member') THEN
    RETURN jsonb_build_object('error', 'Sin permisos para cambiar este rol');
  END IF;

  -- v3-rbac-multirole Parte C (D17, sign-off PO 6.2): el gate "new_role=
  -- 'admin' requiere plan 'pro'" se RETIRA acá -- todos los roles están
  -- disponibles en todos los planes; el gating comercial es sólo por
  -- cantidad de usuarios (max_users, sin tocar). El paso 3 original
  -- (SELECT billing_plan ...; IF v_plan != 'pro' THEN RETURN {error}) queda
  -- eliminado por completo, no comentado -- la política que aplicaba ya no
  -- existe.

  -- 4. Cannot degrade the sole owner
  IF v_target_role = 'owner' AND p_new_role != 'owner' THEN
    SELECT COUNT(*) INTO v_owner_count
    FROM   public.account_members
    WHERE  account_id = p_account_id AND role = 'owner';

    IF v_owner_count <= 1 THEN
      RETURN jsonb_build_object('error', 'No se puede degradar al único owner');
    END IF;
  END IF;

  -- 5. Apply — a través del pivot (D3): reemplaza la asignación de la
  --    tríada legacy (owner/admin/viewer) por la nueva. account_members.role
  --    se actualiza solo, vía el espejo (trg_touch_account_member_role +
  --    trg_derive_account_member_role).
  v_new_code := CASE p_new_role WHEN 'member' THEN 'viewer' ELSE p_new_role END;

  DELETE FROM public.account_member_roles
  WHERE  member_id = v_target_member_id
    AND  role IN ('owner', 'admin', 'viewer');

  INSERT INTO public.account_member_roles (account_id, member_id, role, assigned_by, assigned_at)
  VALUES (p_account_id, v_target_member_id, v_new_code, v_caller_id, now())
  ON CONFLICT (member_id, role) DO NOTHING;

  RETURN jsonb_build_object('ok', true);
END;
$function$
;

COMMENT ON FUNCTION public.rpc_change_member_role(uuid, uuid, text) IS
  'v3-rbac-multirole Parte C (D17): idéntica a la Parte A salvo el paso 3 '
  '(gate "admin requiere plan pro"), RETIRADO por sign-off del PO 6.2 -- '
  'todos los roles disponibles en todos los planes, gating comercial sólo '
  'por max_users. Vocabulario legacy (owner/admin/member) sin cambios -- los '
  'roles funcionales van por rpc_assign_member_role.';


-- =============================================================================
-- 4. rpc_invite_member — DOS overloads.
--
--    (a) rpc_invite_member(text, uuid) — 2 args, SIN gate de plan (nunca lo
--        tuvo). Usada por TeamSection.tsx ("quick invite" sin selector de
--        rol, Configuración → Equipo) -- se mantiene la restricción "sólo el
--        owner" tal cual (D17 no la toca: no hay ningún selector de rol en
--        ese formulario, así que no hay gate de plan que retirar; la
--        jerarquía propietario/administrador para ESTE camino queda fuera
--        de alcance de este change, declarado). Sólo se normalizan sus
--        ERRCODEs P0001 (D18) -- CREATE OR REPLACE puro, misma firma.
--
--    (b) rpc_invite_member(text, uuid, text[]) — REEMPLAZA al overload de 3
--        args con tercer parámetro `text` (un solo rol) por uno con
--        `text[]` (conjunto). DROP + CREATE (nunca CREATE OR REPLACE sobre
--        una firma distinta -- 42P13); p_roles SIN DEFAULT a propósito (ver
--        cabecera del archivo: con DEFAULT colisionaría por aridad con el
--        overload de 2 args, activo). Retira el gate de plan (D17), invita
--        con CONJUNTO de roles (account-membership-roles), normaliza
--        ERRCODEs (D18).
-- =============================================================================

-- (a) 2-arg — CREATE OR REPLACE puro, misma firma, sólo ERRCODEs P0001->P04xx.
CREATE OR REPLACE FUNCTION public.rpc_invite_member(p_email text, p_account_id uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id  uuid;
  v_plan       text;
  v_max_users  int;
  v_cur_users  int;
  v_inv_id     uuid;
  v_token      text;
BEGIN
  -- 1. Identify the caller
  v_caller_id := (SELECT auth.uid());
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'P0001';
  END IF;

  -- 2. Confirm caller is owner of this account
  IF NOT EXISTS (
    SELECT 1
    FROM   public.account_members
    WHERE  account_id = p_account_id
      AND  user_id    = v_caller_id
      AND  role       = 'owner'
  ) THEN
    -- v3-rbac-multirole Parte C (D18): P0001 -> P0403 (falta de autoridad),
    -- TEXTO conservado -- el cliente lo sigue matcheando por el substring
    -- "P401:" (frontend/components/settings/TeamSection.tsx).
    RAISE EXCEPTION 'P401: caller is not the owner of account %', p_account_id
      USING ERRCODE = 'P0403';
  END IF;

  -- 3. Get plan + max_users for this account
  SELECT a.billing_plan
  INTO   v_plan
  FROM   public.accounts a
  WHERE  a.id = p_account_id;

  SELECT pl.max_users
  INTO   v_max_users
  FROM   public.plan_limits pl
  WHERE  pl.plan = v_plan;

  IF v_max_users IS NULL THEN
    v_max_users := 1; -- safe fallback for gratis
  END IF;

  -- 4. Count current active members (D18: cuenta MIEMBROS, sin cambios)
  SELECT COUNT(*)
  INTO   v_cur_users
  FROM   public.account_members
  WHERE  account_id = p_account_id;

  IF v_cur_users >= v_max_users THEN
    -- D18: P0001 -> P0402 (cupo), TEXTO conservado ("P403:" -- el cliente lo
    -- matchea por substring, no por sqlstate).
    RAISE EXCEPTION 'P403: member quota reached (% / %)', v_cur_users, v_max_users
      USING ERRCODE = 'P0402';
  END IF;

  -- 5. Check for an existing pending invitation for this email
  IF EXISTS (
    SELECT 1
    FROM   public.account_invitations
    WHERE  account_id = p_account_id
      AND  email      = lower(trim(p_email))
      AND  status     = 'pending'
      AND  expires_at > now()
  ) THEN
    -- D18: P0001 -> P0407 (invitación duplicada), TEXTO conservado.
    RAISE EXCEPTION 'P409: pending invitation already exists for %', p_email
      USING ERRCODE = 'P0407';
  END IF;

  -- 6. Generate a secure random token (64 hex chars = 32 bytes entropy)
  v_token  := encode(extensions.gen_random_bytes(32), 'hex');
  v_inv_id := gen_random_uuid();

  -- 7. Insert the invitation
  INSERT INTO public.account_invitations
    (id, account_id, email, token, status, invited_by, created_at, expires_at)
  VALUES
    (v_inv_id, p_account_id, lower(trim(p_email)), v_token,
     'pending', v_caller_id, now(), now() + INTERVAL '7 days');

  RETURN json_build_object(
    'id',         v_inv_id,
    'token',      v_token,
    'email',      lower(trim(p_email)),
    'expires_at', (now() + INTERVAL '7 days')
  );
END;
$function$
;

COMMENT ON FUNCTION public.rpc_invite_member(text, uuid) IS
  'v3-rbac-multirole Parte C (D18): idéntica a su cuerpo original salvo '
  'ERRCODEs (P0001 -> P0403/P0402/P0407, texto del mensaje preservado). Sin '
  'gate de plan (nunca lo tuvo). "Quick invite" sin selector de rol '
  '(TeamSection.tsx) -- crea la invitación sin `role`/`roles` explícitos, '
  'default de tabla (role=''member'') -- rpc_accept_invitation la resuelve a '
  '{viewer} (D2).';


-- (b) 3-arg -> conjunto de roles. DROP (la firma VIEJA, de un solo `text`) +
--     CREATE OR REPLACE (la firma NUEVA, `text[]`) -- el DROP sólo hace
--     falta la PRIMERA vez que corre esta migración (después es un no-op,
--     "does not exist, skipping"); una vez que la firma nueva existe, las
--     reaplicaciones siguientes son CREATE OR REPLACE puro sobre ELLA
--     MISMA, nunca un segundo DROP+CREATE que arriesgue perder ACLs.
DROP FUNCTION IF EXISTS public.rpc_invite_member(text, uuid, text);

CREATE OR REPLACE FUNCTION public.rpc_invite_member(p_email text, p_account_id uuid, p_roles text[])
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id   uuid;
  v_caller_role text;
  v_plan        text;
  v_max_users   int;
  v_cur_users   int;
  v_inv_id      uuid;
  v_token       text;
  v_roles       text[];
  v_role_legacy text;
BEGIN
  v_caller_id := (SELECT auth.uid());
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'P0001';
  END IF;

  -- Caller must be owner or admin
  SELECT role INTO v_caller_role
  FROM   public.account_members
  WHERE  account_id = p_account_id AND user_id = v_caller_id;

  IF v_caller_role IS NULL OR v_caller_role NOT IN ('owner', 'admin') THEN
    -- D18: P0001 -> P0403, texto conservado.
    RAISE EXCEPTION 'P401: caller is not owner or admin of account %', p_account_id
      USING ERRCODE = 'P0403';
  END IF;

  -- account-membership-roles ("Invitación diferenciada por rol que puede
  -- invitar"): normaliza el conjunto (NULL o vacío -> {viewer}, D-account-
  -- membership-roles "Una invitación sin roles declarados resuelve a solo
  -- lectura") y deduplica.
  IF p_roles IS NULL OR cardinality(p_roles) = 0 THEN
    v_roles := ARRAY['viewer'];
  ELSE
    SELECT ARRAY(SELECT DISTINCT unnest(p_roles)) INTO v_roles;
  END IF;

  -- Catálogo: cada rol del conjunto debe existir.
  IF EXISTS (
    SELECT 1 FROM unnest(v_roles) r(code)
    WHERE NOT EXISTS (SELECT 1 FROM public.account_role_catalog WHERE code = r.code)
  ) THEN
    RAISE EXCEPTION 'Rol inválido en el conjunto de la invitación'
      USING ERRCODE = 'P0400';
  END IF;

  -- Admin can only invite with operational roles -- NUNCA owner/admin en el
  -- conjunto. Mismo texto que el cuerpo original (un solo rol, "admins") --
  -- ahora cubre además 'owner' en el conjunto, D18 conserva el texto más
  -- cercano existente en vez de inventar uno nuevo.
  IF v_caller_role = 'admin' AND (v_roles && ARRAY['owner', 'admin']::text[]) THEN
    RAISE EXCEPTION 'Solo el owner puede invitar admins'
      USING ERRCODE = 'P0403';
  END IF;

  -- v3-rbac-multirole Parte C (D17, sign-off PO 6.2): el gate "'admin' IN
  -- p_roles requiere plan 'pro'" se RETIRA -- el paso "role='admin' requires
  -- plan='pro'" del cuerpo original queda eliminado por completo.

  SELECT billing_plan INTO v_plan FROM public.accounts WHERE id = p_account_id;
  SELECT pl.max_users INTO v_max_users FROM public.plan_limits pl WHERE pl.plan = v_plan;
  IF v_max_users IS NULL THEN v_max_users := 1; END IF;

  -- D18: cuenta MIEMBROS, no asignaciones (sin cambios de fondo).
  SELECT COUNT(*) INTO v_cur_users FROM public.account_members WHERE account_id = p_account_id;

  IF v_cur_users >= v_max_users THEN
    RAISE EXCEPTION 'P403: member quota reached (% / %)', v_cur_users, v_max_users
      USING ERRCODE = 'P0402';
  END IF;

  -- Duplicate pending invitation check
  IF EXISTS (
    SELECT 1 FROM public.account_invitations
    WHERE  account_id = p_account_id
      AND  email      = lower(trim(p_email))
      AND  status     = 'pending'
      AND  expires_at > now()
  ) THEN
    RAISE EXCEPTION 'P409: pending invitation already exists for %', p_email
      USING ERRCODE = 'P0407';
  END IF;

  v_token  := encode(extensions.gen_random_bytes(32), 'hex');
  v_inv_id := gen_random_uuid();

  -- Representante legacy por precedencia (D3: owner > admin > else 'member')
  -- -- satisface el CHECK de account_invitations.role, y es lo que
  -- consumiría un lector legacy que todavía no mira `roles`.
  v_role_legacy := CASE
    WHEN 'owner' = ANY(v_roles) THEN 'owner'
    WHEN 'admin' = ANY(v_roles) THEN 'admin'
    ELSE 'member'
  END;

  INSERT INTO public.account_invitations
    (id, account_id, email, token, role, roles, status, invited_by, created_at, expires_at)
  VALUES
    (v_inv_id, p_account_id, lower(trim(p_email)), v_token,
     v_role_legacy, v_roles, 'pending', v_caller_id, now(), now() + INTERVAL '7 days');

  RETURN json_build_object(
    'id',         v_inv_id,
    'token',      v_token,
    'email',      lower(trim(p_email)),
    'roles',      to_jsonb(v_roles),
    'expires_at', (now() + INTERVAL '7 days')
  );
END;
$function$
;

COMMENT ON FUNCTION public.rpc_invite_member(text, uuid, text[]) IS
  'v3-rbac-multirole Parte C (grupo 15): reemplaza al overload de 3 args de '
  'un solo rol (DROP+CREATE, cambio de firma text->text[]) -- invita con '
  'CONJUNTO de roles del catálogo. Sin roles declarados -> {viewer}. Sin '
  'gate de plan (D17). ERRCODEs P04xx con el texto del mensaje preservado '
  '(D18): P0403 autoridad, P0400 catálogo, P0402 cupo, P0407 duplicada. '
  'p_roles SIN DEFAULT -- evita colisionar por aridad con el overload de 2 '
  'args (TeamSection.tsx), que sigue vivo.';

REVOKE ALL ON FUNCTION public.rpc_invite_member(text, uuid, text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_invite_member(text, uuid, text[]) TO authenticated;


-- =============================================================================
-- 5. account_invitations.roles (conjunto) + rpc_accept_invitation reescrita
--    para leer el conjunto (con fallback al `role` legacy para invitaciones
--    creadas antes de esta migración o vía el overload de 2 args).
-- =============================================================================

ALTER TABLE public.account_invitations ADD COLUMN IF NOT EXISTS roles text[] NULL;

COMMENT ON COLUMN public.account_invitations.roles IS
  'v3-rbac-multirole Parte C (grupo 15): conjunto de códigos de '
  'account_role_catalog con el que se acepta la invitación. NULL = '
  'invitación legacy (overload de 2 args, o una fila creada antes de esta '
  'migración) -- rpc_accept_invitation deriva el conjunto equivalente desde '
  '`role` en ese caso (mismo mapeo D2: member->viewer, owner/admin '
  'idénticos).';

CREATE OR REPLACE FUNCTION public.rpc_accept_invitation(p_token text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id    uuid;
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

  SELECT *
  INTO   v_inv
  FROM   public.account_invitations
  WHERE  token     = p_token
    AND  status    = 'pending'
    AND  expires_at > now()
  LIMIT 1;

  IF NOT FOUND THEN
    -- Ronda 1 adversarial (finding NIT): P0001 -> P0404, texto conservado --
    -- mismo criterio D18 que el resto de esta migración (regla dura del
    -- proyecto: ERRCODEs P04xx del catálogo, nunca P0001, para un 404/409
    -- con mapeo obvio).
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

  SELECT a.billing_plan INTO v_plan FROM public.accounts a WHERE a.id = v_inv.account_id;
  SELECT pl.max_users   INTO v_max_users FROM public.plan_limits pl WHERE pl.plan = v_plan;
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
$function$
;

COMMENT ON FUNCTION public.rpc_accept_invitation(text) IS
  'v3-rbac-multirole Parte C (grupo 15): acepta CUALQUIER conjunto de roles '
  '-- lee account_invitations.roles si está poblada (overload de 3 args), '
  'si no deriva del `role` legacy (overload de 2 args / fila pre-migración, '
  'mismo mapeo D2). Escribe TODAS las asignaciones equivalentes a través '
  'del pivot en un FOREACH -- el espejo (account_members.role) converge '
  'sólo tras el ÚLTIMO insert del loop, vía trg_touch_account_member_role + '
  'trg_derive_account_member_role (Parte A) -- el valor legacy que se pasa '
  'en el INSERT inicial de account_members es irrelevante por construcción, '
  'el BEFORE trigger lo sobreescribe de inmediato porque el pivot todavía '
  'está vacío en ese instante. D18: cupo P0001->P0402 (mismo código que '
  'rpc_invite_member). Ronda 1 adversarial (finding NIT): "invalid or '
  'expired invitation token" P0001->P0404 y "already a member" '
  'P0001->P0409, texto conservado. "Not authenticated" SIGUE P0001 -- '
  'mismo criterio que el resto de las RPCs de este archivo para esa MISMA '
  'condición, en la práctica inalcanzable vía el backend (get_current_user '
  'la corta antes).';


-- =============================================================================
-- 6. GATE DE INTROSPECCIÓN (corre SIEMPRE, también en prod) — mismo molde
--    que Parte A / Parte B.
-- =============================================================================
DO $$
DECLARE
  v_cnt     int;
  v_fn      text;
  v_pol_sel int;
BEGIN
  -- (a) una sola definición de cada función tocada (42725) — las 7 tocadas
  --     por esta parte: 5 en el loop (2 nuevas + change_member_role +
  --     accept_invitation + list_account_members) + rpc_invite_member
  --     (2 overloads) verificado por ARIDAD en (b), NO por conteo total de
  --     proname en este loop (tiene 2 overloads a propósito).
  FOR v_fn IN
    SELECT unnest(ARRAY[
      'rpc_assign_member_role', 'rpc_revoke_member_role', 'rpc_list_account_members',
      'rpc_change_member_role', 'rpc_accept_invitation'])
  LOOP
    SELECT COUNT(*) INTO v_cnt FROM pg_proc
    WHERE pronamespace = 'public'::regnamespace AND proname = v_fn;
    IF v_cnt <> 1 THEN
      RAISE EXCEPTION 'GATE INTROSPECCION FAILED: % tiene % definiciones (esperaba 1).', v_fn, v_cnt;
    END IF;
  END LOOP;

  -- (b) rpc_invite_member: EXACTAMENTE 2 overloads, uno de 2 args y uno de
  --     3 args (nunca 3 -- eso significaría que el DROP de la sección 4 no
  --     corrió, dejando el (text,uuid,text) viejo vivo junto al nuevo
  --     (text,uuid,text[])).
  SELECT COUNT(*) INTO v_cnt FROM pg_proc
  WHERE pronamespace = 'public'::regnamespace AND proname = 'rpc_invite_member';
  IF v_cnt <> 2 THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_invite_member debía tener EXACTAMENTE 2 overloads (2-arg + 3-arg conjunto), hay %.', v_cnt;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc
    WHERE pronamespace = 'public'::regnamespace AND proname = 'rpc_invite_member' AND pronargs = 2
  ) THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: falta el overload de 2 args de rpc_invite_member (TeamSection.tsx).';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc
    WHERE pronamespace = 'public'::regnamespace AND proname = 'rpc_invite_member' AND pronargs = 3
      AND pg_get_function_identity_arguments(oid) = 'p_email text, p_account_id uuid, p_roles text[]'
  ) THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: el overload de 3 args de rpc_invite_member no tiene la firma nueva (text,uuid,text[]).';
  END IF;

  -- (c) las 2 RPCs nuevas de rol + el listado: SIN EXECUTE para anon/PUBLIC,
  --     CON EXECUTE para authenticated.
  IF has_function_privilege('anon', 'public.rpc_assign_member_role(uuid,uuid,text,timestamptz)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.rpc_revoke_member_role(uuid,uuid,text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.rpc_list_account_members(uuid)', 'EXECUTE')
  THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: una RPC nueva de la Parte C es ejecutable por anon.';
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.rpc_assign_member_role(uuid,uuid,text,timestamptz)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.rpc_revoke_member_role(uuid,uuid,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.rpc_list_account_members(uuid)', 'EXECUTE')
  THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: una RPC nueva de la Parte C NO es ejecutable por authenticated.';
  END IF;

  -- (d) rpc_invite_member(text,uuid,text[]) sin EXECUTE para anon.
  IF has_function_privilege('anon', 'public.rpc_invite_member(text,uuid,text[])', 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_invite_member(text,uuid,text[]) ejecutable por anon.';
  END IF;

  -- (e) account_invitations.roles existe.
  SELECT COUNT(*) INTO v_cnt
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'account_invitations' AND column_name = 'roles';
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: account_invitations.roles no existe.';
  END IF;

  -- (f) account_member_roles / account_role_catalog: RLS + ACLs de la Parte
  --     A no se tocaron por esta migración (defensa en profundidad -- las
  --     RPCs nuevas son SECURITY DEFINER, dueño postgres, no dependen de
  --     ningún GRANT de tabla para leer/escribir el pivot).
  IF has_table_privilege('authenticated', 'public.account_member_roles', 'SELECT')
     OR has_table_privilege('anon', 'public.account_member_roles', 'SELECT')
  THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: account_member_roles ganó un SELECT de tabla para authenticated/anon -- debía seguir cerrada (Parte A).';
  END IF;

  RAISE NOTICE 'GATE INTROSPECCION v3-rbac-multirole Parte C: OK.';
END $$;
