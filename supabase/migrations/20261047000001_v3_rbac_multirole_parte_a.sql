-- =============================================================================
-- v3-rbac-multirole — PARTE A (modelo de datos, aditivo, sin cambio de
-- comportamiento observable). Grupos 1-6 de tasks.md.
-- Design ref: openspec/changes/v3-rbac-multirole/design.md (D1-D7)
--
-- Implementa:
--   D1  account_role_catalog: catálogo global de solo lectura (8 roles),
--       molde de document_status_transitions (20260807000001).
--   D2  Códigos en MINÚSCULA: owner, admin, seller, cashier, stock,
--       purchases, accountant, viewer. legacy 'member' → 'viewer'.
--   D3  account_member_roles (pivot) es la fuente de verdad desde HOY;
--       account_members.role sigue siendo el vocabulario heredado
--       (owner|admin|member — NUNCA 'viewer'), mantenido por trigger.
--       Un solo camino de escritura: los 4 RPCs de membresía escriben a
--       través del pivot (rpc_remove_member vía CASCADE de la FK).
--   D4  "Rol activo" = expires_at IS NULL OR expires_at > now(), resuelto
--       por función STABLE (member_active_roles/account_user_active_roles),
--       NUNCA por índice parcial con now() (no inmutable).
--   D5  owner no admite expires_at — CHECK de respaldo + trigger con
--       mensaje propio y ERRCODE P0406 (ver nota de errcodes abajo).
--   D6  Invariante "la cuenta con miembros nunca queda sin owner activo" —
--       CONSTRAINT TRIGGER DEFERRABLE INITIALLY DEFERRED sobre el pivot,
--       P0405. account_id se denormaliza en el pivot (ver nota) para que
--       el chequeo diferido pueda resolver la cuenta aun cuando el propio
--       member_id ya fue borrado en cascada dentro de la MISMA transacción
--       (vaciar una cuenta por completo).
--   D7  Auditoría en audit_logs (role.assigned / role.revoked), sin
--       notificaciones. Molde de trg_audit_branch_lifecycle (20261014000001).
--
-- NOTA DE DISEÑO — account_id en account_member_roles (desvío aditivo menor
-- respecto de la lista de columnas de D3, que menciona sólo member_id/role/
-- assigned_by/assigned_at/expires_at): un CONSTRAINT TRIGGER DEFERRABLE
-- INITIALLY DEFERRED se evalúa al COMMIT, dentro de la MISMA transacción que
-- ya aplicó todos los cambios — incluida la eventual desaparición del propio
-- account_members.id (ON DELETE CASCADE al borrar el último miembro de una
-- cuenta). Resolver account_id vía JOIN a account_members en ese momento
-- devuelve cero filas para el escenario "vaciar la cuenta por completo"
-- (4.3), exactamente el caso que D6 exige que PASE. Postgres SÍ conserva el
-- valor de una columna propia del pivot en el evento de trigger diferido
-- (OLD/NEW se capturan al momento de la operación, no se re-consultan al
-- disparar) — por eso account_id vive en la propia fila, no se deriva. No
-- cambia ningún requirement de la spec (que no fija el esquema exacto de la
-- tabla) y no agrega superficie: la columna no se expone a authenticated/anon
-- (RLS + REVOKE explícito, sección 3).
--
-- NOTA DE ERRCODES (task 1.6, verificado libres en prod y local 2026-09-11):
--   P0405 (409) — invariante de propietario único (D6, constraint trigger).
--   P0406 (422) — owner con expires_at (D5). Implementado como trigger BEFORE
--     con RAISE + mensaje propio en vez de dejar sólo el CHECK crudo (23514,
--     genérico) — mismo criterio "informar con mensaje propio, garantizar con
--     el constraint" que sucursal-guard-vaciado-auditoria (D5 de esa ficha).
--     El CHECK queda como red de segunda capa (nunca debería dispararse, ya
--     que el trigger corre antes).
--
-- REGLA DE INTEGRIDAD DE FUNCIÓN (R9): rpc_change_member_role,
-- rpc_remove_member, rpc_accept_invitation, rpc_my_account_role y (hallazgo
-- 6.3b, ver abajo) handle_new_user PARTEN, LITERALMENTE, del cuerpo vivo de
-- prod capturado el 2026-09-11 vía pg_get_functiondef (idéntico, línea a
-- línea sin \r, al cuerpo local — verificado antes de escribir este
-- archivo). Ninguna cambia de firma ⇒ CREATE OR REPLACE puro, sin DROP, sin
-- riesgo de overload 42725. Las ACLs (ninguna con EXECUTE para anon) se
-- preservan automáticamente por CREATE OR REPLACE y se reverifican en el
-- gate de la sección 6.
--
-- RONDA 1 DE REVISIÓN ADVERSARIAL — DESVÍO DELIBERADO de "parten
-- literalmente": rpc_change_member_role y rpc_remove_member ya NO son
-- byte-a-byte el cuerpo vivo de prod. Se les agregó (a) el guard
-- `v_caller_role IS NULL OR` en la validación 1 (cierra un agujero de
-- tenencia PREEXISTENTE — no introducido por esta parte, ver el comentario
-- en cada cuerpo) y, sólo en rpc_change_member_role, (b) el rechazo de
-- cualquier código fuera de {owner,admin,member} y (c) el corte temprano
-- cuando el target no es miembro (evita un 23502). Ninguno de los tres
-- cambia el contrato para un caller/target legítimos de las 39 cuentas
-- actuales — sólo endurece caminos que antes fallaban en silencio o
-- crasheaban. rpc_accept_invitation, rpc_my_account_role y handle_new_user
-- siguen sin este desvío (salvo el propio 6.3b de handle_new_user, ya
-- documentado más abajo).
--
-- HALLAZGO REAL (no anticipado por el design ni por el brief del apply, que
-- listaba sólo 5 funciones a capturar): handle_new_user — el trigger de
-- auth.users que aprovisiona la cuenta y la membresía del signup — inserta
-- directo en account_members con role='owner', SIN pasar por el pivot.
-- Verificado en la validación local de este mismo apply (sección 6.3b más
-- abajo, CORREGIDO en la ronda 1 de revisión adversarial: el mecanismo
-- descrito a continuación estaba mal explicado en la primera versión de
-- este comentario): sin la corrección, trg_derive_account_member_role
-- recalcularía ese 'owner' recién creado a 'member' EN SILENCIO — el
-- invariante de la sección 4.2 NO se dispara acá, porque el INSERT de
-- handle_new_user es la única escritura a account_members en el signup y
-- nunca toca account_member_roles (no hay ningún evento sobre el pivot que
-- active el constraint trigger). El signup se COMPLETA sin ningún error,
-- dejando al fundador con espejo='member', is_account_writer=false y claim
-- account_role='member' para toda cuenta nueva desde el día del merge — un
-- daño SILENCIOSO, no un abort ruidoso, y por eso peor. Se corrige en el
-- mismo choke point (sección 6.3b), agregando la escritura equivalente al
-- pivot inmediatamente después del INSERT existente, sin tocar ninguna otra
-- sección de la función. CONCLUSIÓN QUE IMPORTA (corregida): el invariante
-- de propietario NO es un punto de paso obligado de TODA escritura de
-- membresía — sólo protege los caminos que efectivamente escriben el pivot;
-- un camino futuro que repita este olvido no tendría ninguna señal (ver el
-- endurecimiento opcional documentado en la sección 6.3b).
--
-- Backfill (D3, idempotente): las 39 filas `owner` de account_members
-- → una asignación 'owner' en el pivot con assigned_at = created_at,
-- assigned_by = NULL (provisioning, no una acción humana — spec "El rol del
-- aprovisionamiento no atribuye autoría").
--
-- Sin superficie frontend en esta parte (regla PO 2026-08-02, declarado):
-- los datos existen, nada los lee todavía. account_member_roles queda
-- CERRADO por completo a authenticated/anon (RLS sin policies + REVOKE
-- explícito) — ni siquiera SELECT. account_role_catalog SÍ es legible por
-- authenticated (D1 lo exige: "legible por cualquier miembro autenticado"),
-- aunque nada lo consuma todavía desde la UI.
--
-- HALLAZGO DE ENTORNO (verificación local de este apply, no aplica a prod):
-- varios gates preexistentes limpian su fixture con `DELETE FROM
-- public.account_members` dentro de un bloque `session_replication_role =
-- replica` (desactiva TODOS los triggers, incluida la FK ON DELETE CASCADE
-- hacia `account_member_roles`, que se implementa como trigger). Antes de
-- esta migración eso era inofensivo (`account_members` no tenía tablas
-- hijas); desde ahora deja filas huérfanas en el pivot si algún gate
-- (presente o futuro) borra `account_members` DENTRO de ese bloque en vez de
-- ANTES de entrar en él (que es el patrón que los 4 gates nuevos de esta
-- parte ya siguen). Verificado en la base local compartida: 4 filas
-- huérfanas aparecieron por la limpieza de OTRO workflow concurrente
-- (ajeno a este apply), sin ningún efecto funcional (nunca se vuelven a
-- leer — ningún `member_id` vivo apunta a ellas) — se limpiaron a mano. En
-- prod `session_replication_role` sólo lo fija un rol superusuario y nunca
-- lo usa lógica de negocio, así que este hallazgo es exclusivo de
-- fixtures sintéticos de test/CI, no un riesgo de datos reales.
--
-- GOVERNANCE: HIGH (aditiva, pero vive en la tabla que termina gobernando
--             dinero real — sign-off del PO 2026-09-11, D0 del design).
-- APPLY: npx supabase db push (NUNCA MCP apply_migration).
--
-- ROLLBACK (aditivo — Parte A es reversible sin pérdida, design §Migration
-- Plan): dejar de escribir el pivot y que account_members.role vuelva a ser
-- la única verdad no requiere revertir nada (su valor ya es el correcto);
-- si hiciera falta desarmar la estructura:
--   DROP TRIGGER IF EXISTS trg_guard_account_owner_invariant ON public.account_member_roles;
--   DROP TRIGGER IF EXISTS trg_touch_account_member_role ON public.account_member_roles;
--   DROP TRIGGER IF EXISTS trg_audit_account_member_role ON public.account_member_roles;
--   DROP TRIGGER IF EXISTS trg_guard_account_member_role_no_owner_expiry ON public.account_member_roles;
--   DROP TRIGGER IF EXISTS trg_derive_account_member_role ON public.account_members;
--   -- handle_new_user: sin acción — su INSERT extra a account_member_roles
--   -- queda inerte sin los triggers de arriba (nadie lo lee); restaurar su
--   -- cuerpo original sólo si se quiere byte a byte, no es necesario para
--   -- que el signup vuelva a funcionar (ya funcionaba con el pivot inerte).
--   -- Restaurar los 4 RPCs de membresía al cuerpo capturado en
--   -- openspec/changes/v3-rbac-multirole/baseline/ (prod 2026-09-11).
--   DROP TABLE IF EXISTS public.account_member_roles;
--   DROP TABLE IF EXISTS public.account_role_catalog;
-- =============================================================================


-- =============================================================================
-- 1. account_role_catalog (D1, D2) — catálogo global de solo lectura.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.account_role_catalog (
  code        text    PRIMARY KEY,
  label       text    NOT NULL,
  description text    NOT NULL,
  sort_order  int     NOT NULL,
  is_writer   boolean NOT NULL DEFAULT true
);

COMMENT ON TABLE public.account_role_catalog IS
  'v3-rbac-multirole Parte A (D1): catálogo GLOBAL y CERRADO de roles de '
  'membresía — el mismo para todas las cuentas (Modelo V3 §5, sin RBAC '
  'dinámico por tenant). is_writer es un DATO: agregar un rol nuevo no '
  'obliga a reescribir is_account_writer (Parte B). Sólo una migración '
  'puede alterarlo — INSERT/UPDATE/DELETE revocados de authenticated/anon.';

ALTER TABLE public.account_role_catalog ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS account_role_catalog_select ON public.account_role_catalog;
CREATE POLICY account_role_catalog_select
  ON public.account_role_catalog
  FOR SELECT
  TO authenticated
  USING (true);

REVOKE INSERT, UPDATE, DELETE ON public.account_role_catalog FROM authenticated, anon;

-- Seed idempotente (D2 — códigos en minúscula; el auto-apply de Supabase
-- puede reejecutar esta migración).
INSERT INTO public.account_role_catalog (code, label, description, sort_order, is_writer)
VALUES
  ('owner',      'Propietario',   'Control total de la cuenta. No puede tener vencimiento ni quedar sin al menos un titular activo.', 1, true),
  ('admin',      'Administrador', 'Permiso total de escritura sobre ventas, compras, gastos, productos y clientes.',                    2, true),
  ('seller',     'Vendedor',      'Crea y gestiona presupuestos y ventas.',                                                              3, true),
  ('cashier',    'Cajero',        'Abre y cierra caja, cobra ventas en el mostrador.',                                                    4, true),
  ('stock',      'Depósito',      'Ajusta stock y transferencias entre sucursales.',                                                      5, true),
  ('purchases',  'Compras',       'Registra compras a proveedores.',                                                                      6, true),
  ('accountant', 'Contable',      'Concilia bancos y revisa los libros contables.',                                                       7, true),
  ('viewer',     'Observador',    'Sólo lectura: consulta la información de la cuenta sin poder modificarla.',                            8, false)
ON CONFLICT (code) DO UPDATE
  SET label       = EXCLUDED.label,
      description = EXCLUDED.description,
      sort_order  = EXCLUDED.sort_order,
      is_writer   = EXCLUDED.is_writer;


-- =============================================================================
-- 2. account_member_roles (D3, D4, D5) — el pivot, fuente de verdad.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.account_member_roles (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Denormalizado a propósito — ver "NOTA DE DISEÑO" en la cabecera del
  -- archivo: lo necesita el constraint trigger diferido de la sección 4.
  account_id  uuid        NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  member_id   uuid        NOT NULL REFERENCES public.account_members(id) ON DELETE CASCADE,
  role        text        NOT NULL REFERENCES public.account_role_catalog(code),
  assigned_by uuid        NULL,
  assigned_at timestamptz NOT NULL DEFAULT now(),
  expires_at  timestamptz NULL,

  CONSTRAINT account_member_roles_member_role_uq UNIQUE (member_id, role),
  -- D5, respaldo de segunda capa (ver trigger de la sección 4 para el
  -- mensaje propio + P0406; este CHECK es la garantía estructural última).
  CONSTRAINT account_member_roles_owner_no_expiry
    CHECK (role <> 'owner' OR expires_at IS NULL)
);

COMMENT ON TABLE public.account_member_roles IS
  'v3-rbac-multirole Parte A (D3): pivot multi-rol — FUENTE DE VERDAD de la '
  'membresía desde esta migración. account_members.role queda como espejo '
  'legacy (owner|admin|member, NUNCA "viewer") mantenido por trigger '
  '(trg_derive_account_member_role). expires_at NULL = permanente; una '
  'asignación vencida NUNCA se borra (constancia histórica) — la excluye '
  'member_active_roles(). Ningún rol funcional puede asignarse hasta que la '
  'Parte B migre is_account_writer al pivot (D3, restricción de orden) — '
  'esta Parte A no agrega ninguna superficie de asignación, así que en la '
  'práctica sólo existen filas owner/admin/viewer mientras A esté sola en '
  'prod.';

-- D4: índices B-tree comunes — ningún índice parcial con now() (no inmutable).
CREATE INDEX IF NOT EXISTS idx_account_member_roles_member_id
  ON public.account_member_roles (member_id);

CREATE INDEX IF NOT EXISTS idx_account_member_roles_account_id
  ON public.account_member_roles (account_id);

CREATE INDEX IF NOT EXISTS idx_account_member_roles_expires_at
  ON public.account_member_roles (expires_at)
  WHERE expires_at IS NOT NULL;

-- Sin superficie frontend en la Parte A (declarado): RLS habilitada SIN
-- ninguna policy = deny-by-default para authenticated/anon en las CUATRO
-- operaciones, más el REVOKE explícito de tabla como segunda capa (mismo
-- criterio "cinturón" que document_status_history con su historial
-- append-only). Los únicos lectores/escritores son las funciones
-- SECURITY DEFINER de este archivo (dueño postgres, con BYPASSRLS).
ALTER TABLE public.account_member_roles ENABLE ROW LEVEL SECURITY;

REVOKE SELECT, INSERT, UPDATE, DELETE ON public.account_member_roles FROM authenticated, anon;

-- RONDA 3 (finding NIT-2): TRUNCATE no estaba revocado explícitamente en
-- NINGUNA de las dos tablas de esta migración — un privilegio de tabla
-- aparte de DELETE, que el REVOKE de arriba no cubre. Sin esto, el
-- comentario de cabecera de este archivo ("account_member_roles queda
-- CERRADO por completo a authenticated/anon") no era literalmente cierto.
-- Idempotente (revocar un privilegio ya ausente es un no-op).
REVOKE TRUNCATE ON public.account_member_roles, public.account_role_catalog FROM authenticated, anon;

-- 2.1 RONDA 1 DE REVISIÓN ADVERSARIAL (finding minor/hardening, corregido):
--     `account_id` no tenía ninguna restricción que lo atara a la cuenta
--     REAL del `member_id` — sólo la FK simple a accounts(id). Eso permitía
--     una fila "fantasma" (member de la cuenta A con account_id de la
--     cuenta B), que es justo la columna que usan el invariante de
--     propietario (sección 4.2) y la auditoría (sección 4.3) para resolver
--     QUÉ cuenta verificar/estampar. Reproducido en local antes de
--     corregir. Se reemplaza la FK simple por una compuesta
--     (member_id, account_id) → account_members(id, account_id), que exige
--     coherencia real. `ADD CONSTRAINT IF NOT EXISTS` no existe en
--     Postgres para este tipo de constraint — guardado a mano para que la
--     migración siga siendo reaplicable.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.account_members'::regclass
      AND conname  = 'account_members_id_account_id_key'
  ) THEN
    ALTER TABLE public.account_members
      ADD CONSTRAINT account_members_id_account_id_key UNIQUE (id, account_id);
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.account_member_roles'::regclass
      AND conname  = 'account_member_roles_member_id_fkey'
  ) THEN
    ALTER TABLE public.account_member_roles
      DROP CONSTRAINT account_member_roles_member_id_fkey;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.account_member_roles'::regclass
      AND conname  = 'account_member_roles_member_account_fkey'
  ) THEN
    ALTER TABLE public.account_member_roles
      ADD CONSTRAINT account_member_roles_member_account_fkey
      FOREIGN KEY (member_id, account_id)
      REFERENCES public.account_members (id, account_id)
      ON DELETE CASCADE;
  END IF;
END $$;


-- =============================================================================
-- 3. member_active_roles / account_user_active_roles (D4) — "rol activo".
-- =============================================================================

CREATE OR REPLACE FUNCTION public.member_active_roles(p_member_id uuid)
RETURNS text[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(array_agg(role ORDER BY role), ARRAY[]::text[])
  FROM   public.account_member_roles
  WHERE  member_id = p_member_id
    AND  (expires_at IS NULL OR expires_at > now());
$$;

COMMENT ON FUNCTION public.member_active_roles(uuid) IS
  'v3-rbac-multirole Parte A (D4): roles ACTIVOS de una membresía — excluye '
  'vencidos por predicado, nunca por índice parcial con now() (no '
  'inmutable). STABLE para que el planner la cachee por sentencia.';

-- HALLAZGO del gate test_function_acl_gate.sql (advisor 0028/0029): un
-- REVOKE ALL ... FROM PUBLIC solo NO alcanza — Supabase otorga EXECUTE a
-- anon/authenticated por defecto en toda función public nueva, aparte del
-- grant a PUBLIC. Hace falta revocarlo de anon EXPLÍCITAMENTE (mismo gotcha
-- que sucursal-guard-vaciado-auditoria ya documentó para tablas).
--
-- RONDA 1 DE REVISIÓN ADVERSARIAL (finding MAJOR, corregido): la versión
-- original agregaba además `GRANT EXECUTE ... TO authenticated`, sin NINGÚN
-- predicado que ate el parámetro al caller — reproducido en local (SET
-- LOCAL ROLE authenticated real): un usuario ajeno a la cuenta obtenía los
-- roles activos de CUALQUIER member_id, anulando por la puerta de al lado
-- el cierre total del pivot que esta misma migración declara. Los únicos
-- consumidores reales son las funciones/triggers SECURITY DEFINER de este
-- archivo, que corren como el owner (postgres) y no necesitan el grant —
-- el dueño de una función SIEMPRE puede ejecutarla, con o sin GRANT
-- explícito (verificado: fn_derive_account_member_role, dueño postgres,
-- sigue pudiendo invocar member_active_roles tras retirar este GRANT). Sin
-- superficie frontend en la Parte A (declarado): nada en la UI necesita
-- este EXECUTE todavía. Queda REVOCADA para authenticated/anon hasta que
-- la Parte B tenga un consumidor real (D4) — si entonces se expone, debe
-- llevar su propio guard de tenencia, no un GRANT desnudo.
REVOKE ALL ON FUNCTION public.member_active_roles(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.account_user_active_roles(p_account_id uuid, p_user_id uuid)
RETURNS text[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT public.member_active_roles(am.id)
     FROM   public.account_members am
     WHERE  am.account_id = p_account_id
       AND  am.user_id    = p_user_id),
    ARRAY[]::text[]
  );
$$;

COMMENT ON FUNCTION public.account_user_active_roles(uuid, uuid) IS
  'v3-rbac-multirole Parte A (D4): roles ACTIVOS de un usuario en una cuenta '
  'dada, por (account_id, user_id) — conveniencia sobre member_active_roles '
  'para quien no tiene a mano el member_id. ARRAY vacío si no es miembro.';

-- Ronda 1 (finding MAJOR, mismo criterio que member_active_roles arriba):
-- sin GRANT EXECUTE para authenticated/anon hasta que la Parte B tenga un
-- consumidor real con su propio guard de tenencia.
REVOKE ALL ON FUNCTION public.account_user_active_roles(uuid, uuid) FROM PUBLIC, anon, authenticated;


-- =============================================================================
-- 4. Triggers sobre el pivot (D5, D6, D7) + espejo sobre account_members (D3).
-- =============================================================================

-- 4.1 D5 — owner no admite vencimiento. Mensaje propio + P0406 (422); el
--     CHECK de la sección 2 es la red de segunda capa.
CREATE OR REPLACE FUNCTION public.fn_guard_account_member_role_no_owner_expiry()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.role = 'owner' AND NEW.expires_at IS NOT NULL THEN
    RAISE EXCEPTION 'El rol de propietario no admite vencimiento'
      USING ERRCODE = 'P0406';
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.fn_guard_account_member_role_no_owner_expiry() IS
  'v3-rbac-multirole Parte A (D5): rechaza con P0406 asignar el rol '
  'propietario con fecha de vencimiento — un owner temporal dejaría la '
  'cuenta sin dueño por el mero paso del tiempo, sin acción humana que '
  'auditar. El CHECK account_member_roles_owner_no_expiry es la red de '
  'segunda capa (nunca debería dispararse: este trigger corre antes).';

REVOKE ALL ON FUNCTION public.fn_guard_account_member_role_no_owner_expiry() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_guard_account_member_role_no_owner_expiry ON public.account_member_roles;
CREATE TRIGGER trg_guard_account_member_role_no_owner_expiry
  BEFORE INSERT OR UPDATE ON public.account_member_roles
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_guard_account_member_role_no_owner_expiry();

-- 4.2 D6 — invariante "la cuenta con miembros nunca queda sin owner activo".
--     CONSTRAINT TRIGGER DEFERRABLE INITIALLY DEFERRED: se evalúa al COMMIT,
--     no por fila — así una transferencia de propiedad (quitar+dar en la
--     misma transacción) atraviesa un estado intermedio sin dueño sin ser
--     rechazada, y vaciar una cuenta por completo (0 miembros) satisface la
--     garantía de forma VACUA.
--
--     GOTCHA A REGISTRAR (design R9/D6, verificado en tasks 4.9):
--     `session_replication_role = replica` (41 wraps sobre 20 archivos de
--     gates de este proyecto) desactiva TODOS los triggers, constraint
--     triggers incluidos. El gate de este invariante (supabase/tests/
--     test_account_owner_invariant.sql) NO puede correr bajo `replica`
--     — se documenta también en la cabecera de ese archivo.
CREATE OR REPLACE FUNCTION public.fn_guard_account_owner_invariant()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_accounts     uuid[];
  v_account_id   uuid;
  v_member_count int;
  v_owner_count  int;
BEGIN
  -- RONDA 2 DE REVISIÓN ADVERSARIAL (finding MAJOR, corregido): un UPDATE
  -- que mueve la fila a OTRA cuenta (account_id cambia entre OLD y NEW) deja
  -- NEW.account_id y OLD.account_id apuntando a cuentas DISTINTAS.
  -- COALESCE(NEW.account_id, OLD.account_id) sólo miraba NEW — la cuenta de
  -- ORIGEN nunca se verificaba, así que un UPDATE que movía el único owner
  -- de A hacia B dejaba a A con miembros y CERO owners sin ningún error
  -- (reproducido en una transacción aislada y COMMITEADA). Ahora se
  -- verifican AMBAS cuentas cuando difieren — `unnest` + `WHERE x IS NOT
  -- NULL` cubre igual INSERT (OLD NULL) y DELETE (NEW NULL) sin cambiar su
  -- comportamiento previo.
  v_accounts := ARRAY(
    SELECT DISTINCT x FROM unnest(ARRAY[NEW.account_id, OLD.account_id]) x WHERE x IS NOT NULL
  );

  FOREACH v_account_id IN ARRAY v_accounts LOOP
    -- ¿La cuenta todavía tiene miembros? Si no, la garantía se satisface de
    -- forma VACUA (D6, spec "Vaciar una cuenta por completo es posible").
    SELECT COUNT(*) INTO v_member_count
    FROM   public.account_members
    WHERE  account_id = v_account_id;

    IF v_member_count = 0 THEN
      CONTINUE;
    END IF;

    SELECT COUNT(*) INTO v_owner_count
    FROM   public.account_member_roles amr
    JOIN   public.account_members am ON am.id = amr.member_id
    WHERE  am.account_id = v_account_id
      AND  amr.role      = 'owner'
      AND  (amr.expires_at IS NULL OR amr.expires_at > now());

    IF v_owner_count = 0 THEN
      RAISE EXCEPTION 'La cuenta debe conservar al menos un propietario activo'
        USING ERRCODE = 'P0405';
    END IF;
  END LOOP;

  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION public.fn_guard_account_owner_invariant() IS
  'v3-rbac-multirole Parte A (D6): invariante estructural — punto de paso '
  'obligado (cubre revocación, degradación, DELETE directo del pivot, el '
  'CASCADE de expulsar al último miembro y un UPDATE que mueve la fila a '
  'OTRA cuenta — ronda 2), no una validación dentro de un RPC en '
  'particular. Disparada por un CONSTRAINT TRIGGER DEFERRABLE INITIALLY '
  'DEFERRED — lee el estado YA APLICADO al final de la transacción, así '
  'que una transferencia de propiedad (revocar+asignar en la misma '
  'transacción) nunca ve el estado intermedio sin dueño. Verifica NEW.'
  'account_id Y OLD.account_id cuando difieren (ronda 2). P0405.';

REVOKE ALL ON FUNCTION public.fn_guard_account_owner_invariant() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_guard_account_owner_invariant ON public.account_member_roles;
CREATE CONSTRAINT TRIGGER trg_guard_account_owner_invariant
  AFTER INSERT OR UPDATE OR DELETE ON public.account_member_roles
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_guard_account_owner_invariant();

-- 4.3 D7 — auditoría de asignación/actualización/revocación (sin
--     notificaciones). Choke point único en el pivot: cubre la revocación
--     explícita (RPC), la baja por CASCADE al remover un miembro entero, y
--     (RONDA 3, finding MINOR-3) cualquier UPDATE de la fila — p.ej. tocar
--     expires_at, o mover member_id/account_id como en los bloques (11)/(12)
--     del gate de invariante.
CREATE OR REPLACE FUNCTION public.fn_audit_account_member_role()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.audit_logs
      (account_id, user_id, action, entity_type, entity_id, metadata, created_at)
    VALUES (
      NEW.account_id, NEW.assigned_by, 'role.assigned', 'account_member_role', NEW.id,
      jsonb_build_object('member_id', NEW.member_id, 'role', NEW.role, 'expires_at', NEW.expires_at),
      now()
    );
    RETURN NEW;
  ELSIF TG_OP = 'UPDATE' THEN
    -- RONDA 3 (finding MINOR-3): role.updated con el snapshot OLD/NEW
    -- completo (member_id, account_id, role, expires_at) anidado — a
    -- diferencia de INSERT/DELETE, acá ambos lados importan porque un
    -- UPDATE puede mover la fila de miembro/cuenta (4.2/4.5) además de sólo
    -- tocar expires_at.
    INSERT INTO public.audit_logs
      (account_id, user_id, action, entity_type, entity_id, metadata, created_at)
    VALUES (
      NEW.account_id, (SELECT auth.uid()), 'role.updated', 'account_member_role', NEW.id,
      jsonb_build_object(
        'old', jsonb_build_object('member_id', OLD.member_id, 'account_id', OLD.account_id, 'role', OLD.role, 'expires_at', OLD.expires_at),
        'new', jsonb_build_object('member_id', NEW.member_id, 'account_id', NEW.account_id, 'role', NEW.role, 'expires_at', NEW.expires_at)
      ),
      now()
    );
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    INSERT INTO public.audit_logs
      (account_id, user_id, action, entity_type, entity_id, metadata, created_at)
    VALUES (
      OLD.account_id, (SELECT auth.uid()), 'role.revoked', 'account_member_role', OLD.id,
      jsonb_build_object('member_id', OLD.member_id, 'role', OLD.role),
      now()
    );
    RETURN OLD;
  END IF;
  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION public.fn_audit_account_member_role() IS
  'v3-rbac-multirole Parte A (D7): registra role.assigned/role.updated/'
  'role.revoked en audit_logs, molde de fn_audit_branch_lifecycle '
  '(20261014000001). assigned_by NULL en el INSERT = aprovisionamiento, no '
  'una persona (spec: "El rol del aprovisionamiento no atribuye autoría"). '
  'role.updated (ronda 3, MINOR-3) lleva el snapshot OLD/NEW completo. Sin '
  'notificaciones — audit_logs no lo lee la interfaz.';

REVOKE ALL ON FUNCTION public.fn_audit_account_member_role() FROM PUBLIC, anon, authenticated;

-- RONDA 3 (finding MINOR-3): se agrega OR UPDATE al disparador — DROP +
-- CREATE conserva el patrón idempotente que ya usa este archivo para todos
-- sus triggers (en vez de CREATE OR REPLACE TRIGGER).
DROP TRIGGER IF EXISTS trg_audit_account_member_role ON public.account_member_roles;
CREATE TRIGGER trg_audit_account_member_role
  AFTER INSERT OR UPDATE OR DELETE ON public.account_member_roles
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_audit_account_member_role();

-- 4.4 D3 — espejo: account_members.role SIEMPRE se recalcula de las
--     asignaciones activas, con precedencia owner > admin > member (legacy).
--     Un ÚNICO punto de derivación (BEFORE INSERT OR UPDATE en
--     account_members) hace que tanto escribir el pivot (vía el "toque" de
--     abajo) como intentar escribir la columna directamente produzcan el
--     MISMO resultado — no hay forma de que la columna diverja.
CREATE OR REPLACE FUNCTION public.fn_derive_account_member_role()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_active text[];
BEGIN
  v_active := public.member_active_roles(NEW.id);

  IF 'owner' = ANY(v_active) THEN
    NEW.role := 'owner';
  ELSIF 'admin' = ANY(v_active) THEN
    NEW.role := 'admin';
  ELSE
    NEW.role := 'member';
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.fn_derive_account_member_role() IS
  'v3-rbac-multirole Parte A (D3): fuerza account_members.role a la '
  'precedencia derivada del pivot (owner > admin > member/legacy) en TODA '
  'escritura, propia o ajena — el espejo no puede quedar desincronizado ni '
  'ser sobrescrito a mano. Vocabulario heredado: nunca escribe "viewer".';

REVOKE ALL ON FUNCTION public.fn_derive_account_member_role() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_derive_account_member_role ON public.account_members;
CREATE TRIGGER trg_derive_account_member_role
  BEFORE INSERT OR UPDATE ON public.account_members
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_derive_account_member_role();

-- 4.5 "Toque" desde el pivot: cualquier cambio en account_member_roles debe
--     forzar la re-derivación de account_members.role — un UPDATE a la
--     MISMA columna alcanza, porque el BEFORE trigger de 4.4 la recalcula
--     igual, sin importar el valor que "parezca" estar escribiendo.
CREATE OR REPLACE FUNCTION public.fn_touch_account_member_role()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- RONDA 2 DE REVISIÓN ADVERSARIAL (finding MAJOR, corregido): un UPDATE
  -- que cambia `member_id` (mueve la fila del pivot a OTRA membresía) tenía
  -- COALESCE(NEW.member_id, OLD.member_id) — con ambos presentes, COALESCE
  -- devolvía SIEMPRE NEW y sólo se retocaba el miembro DESTINO; el miembro
  -- ORIGEN nunca se re-derivaba y su columna espejo quedaba con el rol
  -- viejo (desincronizada del pivot real). `= ANY` con NULLs es inocuo y
  -- conserva el comportamiento de INSERT (OLD NULL) y DELETE (NEW NULL).
  UPDATE public.account_members
     SET role = role
   WHERE id = ANY (ARRAY[NEW.member_id, OLD.member_id]);

  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION public.fn_touch_account_member_role() IS
  'v3-rbac-multirole Parte A (D3): "toca" la(s) membresía(s) dueña(s) de la '
  'fila del pivot que acaba de cambiar para que trg_derive_account_member_'
  'role recalcule su rol heredado — un UPDATE que mueve member_id retoca '
  'AMBAS membresías, origen y destino (ronda 2). No-op para el/los id(s) ya '
  'borrado(s) en la misma transacción (CASCADE al vaciar la cuenta) — no es '
  'un error.';

REVOKE ALL ON FUNCTION public.fn_touch_account_member_role() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_touch_account_member_role ON public.account_member_roles;
CREATE TRIGGER trg_touch_account_member_role
  AFTER INSERT OR UPDATE OR DELETE ON public.account_member_roles
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_touch_account_member_role();


-- =============================================================================
-- 5. Backfill (D3, idempotente) — traslada CADA membresía existente a su
--    asignación EQUIVALENTE (spec: "trasladar cada membresía preexistente a
--    una asignación equivalente"), no a 'owner' para todas.
--
--    RONDA 1 DE REVISIÓN ADVERSARIAL (finding BLOCKER, corregido): la
--    versión original de esta sentencia hardcodeaba el literal 'owner' sin
--    ningún WHERE ni mapeo — hoy es un no-op semántico porque las 39 filas
--    de prod son 39 owner (remedido antes de escribir esta migración), pero
--    la corrección era sólo del snapshot de datos, no de la sentencia: un
--    member/invitado con account_members.role='member' habría quedado
--    convertido en PROPIETARIO de la cuenta por este backfill. Reproducido
--    en local (transacción con ROLLBACK) antes de corregir. El mapeo de
--    abajo es el MISMO que usan rpc_change_member_role (sección 6.1) y
--    rpc_accept_invitation (sección 6.3): 'member' (legacy) → 'viewer'
--    (catálogo); 'owner'/'admin' quedan idénticos (D2).
--
--    RONDA 2 DE REVISIÓN ADVERSARIAL (finding nit, corregido): esta
--    sentencia no tenía guard de "ya migrado" — corría entera en CADA
--    reaplicación, derivando el rol a insertar del ESPEJO
--    (account_members.role). Hoy es inocuo (sólo existen owner/admin/viewer
--    y el mapeo siempre coincide con el espejo, verificado con 3
--    reaplicaciones consecutivas → 0 filas nuevas), pero es una trampa para
--    la Parte B: una membresía cuyos únicos roles activos sean funcionales
--    (p.ej. {seller}) tiene espejo 'member', así que una reaplicación
--    futura le insertaría una asignación 'viewer' que nadie otorgó. Se
--    acota a las membresías que TODAVÍA no tienen ninguna asignación —
--    resultado idéntico hoy, inerte ante ese estado futuro.
-- =============================================================================

INSERT INTO public.account_member_roles (account_id, member_id, role, assigned_by, assigned_at)
SELECT account_id, id,
       CASE role
         WHEN 'owner' THEN 'owner'
         WHEN 'admin' THEN 'admin'
         ELSE 'viewer'
       END,
       NULL, created_at
FROM   public.account_members am
WHERE  NOT EXISTS (
  SELECT 1 FROM public.account_member_roles amr WHERE amr.member_id = am.id
)
ON CONFLICT (member_id, role) DO NOTHING;


-- =============================================================================
-- 6. Reescritura de los 4 RPCs de membresía (D3) — desde el cuerpo VIVO de
--    prod (capturado 2026-09-11, idéntico línea a línea al local). MISMA
--    firma en los 4 ⇒ CREATE OR REPLACE puro, ACLs preservadas.
-- =============================================================================

-- 6.1 rpc_change_member_role — validaciones 1-4 INTACTAS (leen
--     account_members.role, que sigue siendo válido vía el espejo); sólo
--     cambia el paso 5 (Apply), que ahora escribe a través del pivot en vez
--     de UPDATE directo. Mapeo de vocabulario: 'member' (legacy) → 'viewer'
--     (catálogo); 'owner'/'admin' quedan idénticos (D2).
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
  v_plan             text;
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

  -- 3. new_role='admin' requires plan 'pro'
  IF p_new_role = 'admin' THEN
    SELECT billing_plan INTO v_plan FROM public.accounts WHERE id = p_account_id;
    IF v_plan != 'pro' THEN
      RETURN jsonb_build_object('error', 'El rol admin requiere plan pro');
    END IF;
  END IF;

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

-- 6.2 rpc_remove_member — la FK member_id → account_members(id) ON DELETE
--     CASCADE ya hace que borrar la membresía "escriba a través del pivot"
--     (borra sus filas de account_member_roles), disparando el invariante
--     de owner (D6) y la auditoría de revocación (D7) automáticamente —
--     sin que esta función necesite tocar account_member_roles
--     explícitamente. RONDA 1 DE REVISIÓN ADVERSARIAL: la validación 1
--     dejó de ser idéntica al cuerpo vivo de prod — se le agregó el guard
--     `v_caller_role IS NULL OR` (ver comentario en el cuerpo) para cerrar
--     el mismo agujero de tenencia preexistente que rpc_change_member_role;
--     el resto del cuerpo sigue intacto.
CREATE OR REPLACE FUNCTION public.rpc_remove_member(p_account_id uuid, p_target_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id   uuid;
  v_caller_role text;
  v_target_role text;
BEGIN
  v_caller_id := (SELECT auth.uid());

  SELECT role INTO v_caller_role
  FROM   public.account_members
  WHERE  account_id = p_account_id AND user_id = v_caller_id;

  -- 1. Caller must be owner or admin.
  --    Ronda 1 de revisión adversarial (finding MAJOR, agujero PREEXISTENTE
  --    a esta parte — mismo hallazgo y mismo fix que rpc_change_member_role
  --    arriba): v_caller_role NULL (caller no es miembro de la cuenta) hacía
  --    que `NOT IN` evaluara NULL en vez de TRUE, dejando pasar a un
  --    tercero ajeno. Reproducido en local: expulsaba miembros de una
  --    cuenta a la que no pertenecía.
  IF v_caller_role IS NULL OR v_caller_role NOT IN ('owner', 'admin') THEN
    RETURN jsonb_build_object('error', 'Sin permisos');
  END IF;

  SELECT role INTO v_target_role
  FROM   public.account_members
  WHERE  account_id = p_account_id AND user_id = p_target_user_id;

  -- 2. Cannot expel the owner
  IF v_target_role = 'owner' THEN
    RETURN jsonb_build_object('error', 'No se puede expulsar al owner');
  END IF;

  -- 3. Admin cannot expel another admin (or owner, already covered above)
  IF v_caller_role = 'admin' AND v_target_role IN ('owner', 'admin') THEN
    RETURN jsonb_build_object('error', 'Sin permisos para expulsar este miembro');
  END IF;

  DELETE FROM public.account_members
  WHERE  account_id = p_account_id
    AND  user_id    = p_target_user_id;

  RETURN jsonb_build_object('ok', true);
END;
$function$
;

-- 6.3 rpc_accept_invitation — validaciones INTACTAS; al crear la membresía
--     ahora TAMBIÉN inserta su asignación equivalente en el pivot (D3),
--     assigned_by = quien invitó (account_invitations.invited_by — es quien
--     eligió el rol al crear la invitación, no el propio invitado).
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
  v_role_legacy  text;
  v_role_code    text;
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
    RAISE EXCEPTION 'P404: invalid or expired invitation token'
      USING ERRCODE = 'P0001';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.account_members
    WHERE  account_id = v_inv.account_id AND user_id = v_caller_id
  ) THEN
    RAISE EXCEPTION 'P409: caller is already a member of account %', v_inv.account_id
      USING ERRCODE = 'P0001';
  END IF;

  SELECT a.billing_plan INTO v_plan FROM public.accounts a WHERE a.id = v_inv.account_id;
  SELECT pl.max_users   INTO v_max_users FROM public.plan_limits pl WHERE pl.plan = v_plan;
  IF v_max_users IS NULL THEN v_max_users := 1; END IF;

  SELECT COUNT(*) INTO v_cur_users FROM public.account_members WHERE account_id = v_inv.account_id;

  IF v_cur_users >= v_max_users THEN
    RAISE EXCEPTION 'P403: member quota reached (% / %)', v_cur_users, v_max_users
      USING ERRCODE = 'P0001';
  END IF;

  v_member_id   := gen_random_uuid();
  v_role_legacy := COALESCE(v_inv.role, 'member');
  v_role_code   := CASE v_role_legacy WHEN 'member' THEN 'viewer' ELSE v_role_legacy END;

  INSERT INTO public.account_members
    (id, account_id, user_id, role, created_at)
  VALUES
    (v_member_id, v_inv.account_id, v_caller_id, v_role_legacy, now());

  -- Escritura a través del pivot (D3) — la asignación equivalente.
  INSERT INTO public.account_member_roles
    (account_id, member_id, role, assigned_by, assigned_at)
  VALUES
    (v_inv.account_id, v_member_id, v_role_code, v_inv.invited_by, now());

  UPDATE public.account_invitations SET status = 'accepted' WHERE id = v_inv.id;

  RETURN json_build_object(
    'account_member_id', v_member_id,
    'account_id',        v_inv.account_id,
    'role',              v_role_legacy
  );
END;
$function$
;

-- 6.3b HALLAZGO REAL (verificación local de este mismo apply, no anticipado
--     por el design), CORREGIDO en la ronda 1 de revisión adversarial (la
--     redacción original de este comentario describía mal el mecanismo —
--     ver la nota "CONCLUSIÓN QUE IMPORTA" en la cabecera del archivo):
--     handle_new_user (el trigger de auth.users que aprovisiona
--     cuenta+membresía en el signup) inserta directo en account_members
--     con role='owner' — SIN pasar por el pivot. Con trg_derive_account_
--     member_role instalado (sección 4.4), esa columna se recalcula
--     SIEMPRE desde member_active_roles(); sin una fila equivalente en
--     account_member_roles, el flamante owner queda derivado a 'member'
--     EN SILENCIO — el invariante de la sección 4.2 NO aborta nada, porque
--     nunca hay un evento sobre account_member_roles que lo dispare
--     (handle_new_user no escribe ese pivot). El signup se COMPLETA sin
--     ningún error, dejando al fundador con espejo='member',
--     is_account_writer=false y claim account_role='member' — un daño
--     silencioso, no un abort, para toda cuenta nueva desde el día de este
--     merge. Se corrige acá, en el mismo choke point, agregando la
--     escritura a través del pivot inmediatamente después del INSERT
--     existente — CREATE OR REPLACE desde el cuerpo VIVO de prod
--     (capturado 2026-09-11, idéntico línea a línea al local), sin tocar
--     ninguna otra sección de la función. assigned_by NULL: es
--     aprovisionamiento, no una persona (mismo criterio que el backfill de
--     la sección 5).
--
--     ENDURECIMIENTO OPCIONAL, NO APLICADO en esta ronda (candidato, no
--     bloqueante — el hallazgo de arriba ya cierra la exposición conocida):
--     un segundo CONSTRAINT TRIGGER DEFERRABLE INITIALLY DEFERRED AFTER
--     INSERT sobre public.account_members que invoque la MISMA
--     fn_guard_account_owner_invariant haría que un olvido futuro similar
--     (un camino nuevo que inserte en account_members sin escribir el
--     pivot) falle RUIDOSAMENTE en vez de degradar en silencio.
CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  user_name          text;
  user_last_name     text;
  user_phone         text;
  user_locality      text;
  user_province      text;
  user_terms_version text;
  user_email_optin   boolean;
  v_terms_accepted_at timestamptz;
  v_account_id       uuid;
  v_branch_id        uuid;
  v_member_id        uuid;
BEGIN
  user_name          := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'name', '')), '');
  user_last_name     := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'last_name', '')), '');
  user_phone         := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'phone', '')), '');
  user_locality      := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'locality', '')), '');
  user_province      := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'province', '')), '');
  user_terms_version := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'terms_version', '')), '');
  user_email_optin   := COALESCE((new.raw_user_meta_data->>'email_notifications_opt_in')::boolean, false);
  v_terms_accepted_at := CASE WHEN user_terms_version IS NOT NULL THEN now() ELSE NULL END;

  -- 1) Perfil (sin cambios respecto a 20260801000003)
  INSERT INTO public.profiles (
    id, name, last_name, phone, locality, province, role,
    terms_accepted_at, terms_version, email_notifications_opt_in
  )
  VALUES (
    new.id, user_name, user_last_name, user_phone, user_locality, user_province, 'user',
    v_terms_accepted_at, user_terms_version, user_email_optin
  );

  -- 2) Tenant: cuenta propia + membresía como OWNER (sin cambios).
  INSERT INTO public.accounts (
    owner_user_id, billing_plan, billing_status,
    trial_plan, trial_started_at, trial_expires_at
  )
  SELECT new.id, p.billing_plan, p.billing_status,
         p.trial_plan, p.trial_started_at, p.trial_expires_at
  FROM   public.profiles p
  WHERE  p.id = new.id
  RETURNING id INTO v_account_id;

  INSERT INTO public.account_members (account_id, user_id, role)
  VALUES (v_account_id, new.id, 'owner')
  ON CONFLICT (account_id, user_id) DO NOTHING
  RETURNING id INTO v_member_id;

  -- v3-rbac-multirole Parte A (D3, hallazgo 6.3b): escritura a través del
  -- pivot — sin esto, trg_derive_account_member_role degradaría EN SILENCIO
  -- al fundador a 'member' (el invariante de la sección 4.2 NO se dispara
  -- acá: el signup nunca escribe el pivot). Ver el bloque 6.3b arriba.
  -- v_member_id es NULL sólo si el ON CONFLICT disparó (no debería ocurrir
  -- en un alta nueva) — el IS NOT NULL lo hace inerte en ese caso
  -- hipotético, en vez de fallar el signup completo por esto.
  IF v_member_id IS NOT NULL THEN
    INSERT INTO public.account_member_roles (account_id, member_id, role, assigned_by)
    VALUES (v_account_id, v_member_id, 'owner', NULL)
    ON CONFLICT (member_id, role) DO NOTHING;
  END IF;

  -- 3) Mail de bienvenida (sin cambios)
  INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
  VALUES (
    new.id,
    'welcome',
    new.email,
    '¡Bienvenido a ALIADATA Emprendedores!',
    jsonb_build_object('name', COALESCE(user_name, 'Emprendedor'))
  );

  -- 4) Aviso al administrador (sin cambios)
  INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
  VALUES (
    new.id,
    'new_user_admin_notice',
    'danielsevilla@alia-data.com',
    'Nuevo registro en ALIADATA',
    jsonb_build_object(
      'name',      COALESCE(user_name, 'Sin nombre'),
      'last_name', COALESCE(user_last_name, '-'),
      'full_name', NULLIF(TRIM(COALESCE(user_name, '') || ' ' || COALESCE(user_last_name, '')), ''),
      'email',     new.email,
      'phone',     COALESCE(user_phone, '-'),
      'locality',  COALESCE(user_locality, '-'),
      'province',  COALESCE(user_province, '-')
    )
  );

  -- 5) v3-provisioning-seed: sucursal default + caja default (EAGER).
  --    Aislado en su propio sub-bloque: un fallo acá degrada a WARNING y
  --    JAMÁS aborta el signup. El core de arriba (profile/account/membership/
  --    emails) queda fuera de este bloque a propósito — si eso falla, el
  --    signup DEBE fallar (comportamiento preexistente, correcto).
  BEGIN
    INSERT INTO public.branches (account_id, name, is_active, status, opened_at)
    VALUES (v_account_id, 'Casa Central', TRUE, 'active', now())
    ON CONFLICT (account_id, name) DO NOTHING;

    v_branch_id := public.c26_default_branch(v_account_id);

    IF v_branch_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.cashboxes cb WHERE cb.branch_id = v_branch_id
    ) THEN
      INSERT INTO public.cashboxes (branch_id, name, currency)
      VALUES (v_branch_id, 'Caja Principal', 'ARS');
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING 'v3-provisioning-seed: no se pudo sembrar branch/cashbox default para account_id=% (signup continúa; el lazy-create de c21_apply_branch_stock_delta sigue como red de seguridad). SQLERRM=%',
        v_account_id, SQLERRM;
  END;

  -- 6) metodos-pago-operaciones (D11 Parte B) + limpiezas-pagos-admin (OQ-1):
  --    catálogo de 7 formas de pago (6 originales + Cheque). Mismo criterio
  --    degrade-don't-fail que el sub-bloque de arriba — aislado, propia
  --    EXCEPTION, jamás aborta el signup.
  BEGIN
    -- limpiezas-pagos-admin (OQ-1): 'Cheque' (kind=check) se agrega como 7º
    -- método sembrado — el vocabulario del CHECK ya lo admitía desde
    -- 20260928000001 pero el seed original solo traía 6/7. sort_order=7
    -- (al final, no reordena los 6 existentes). Riesgo cero: el usuario
    -- puede desactivarlo desde el manager de Configuración si no lo usa.
    INSERT INTO public.payment_methods (account_id, name, kind, sort_order)
    SELECT v_account_id, v.name, v.kind, v.sort_order
    FROM (VALUES
        ('Efectivo',               'cash',     1),
        ('Transferencia bancaria', 'transfer', 2),
        ('Tarjeta',                'card',     3),
        ('Billetera virtual',      'wallet',   4),
        ('Cuenta corriente',       'credit',   5),
        ('Otro',                   'other',    6),
        ('Cheque',                 'check',    7)
    ) AS v(name, kind, sort_order)
    WHERE NOT EXISTS (
      SELECT 1 FROM public.payment_methods pm
      WHERE pm.account_id = v_account_id
        AND pm.kind       = v.kind
        AND pm.deleted_at IS NULL
    );
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING 'metodos-pago-operaciones: no se pudo sembrar el catálogo de formas de pago para account_id=% (signup continúa). SQLERRM=%',
        v_account_id, SQLERRM;
  END;

  -- 7) productos-categorias-sku (D13): las 7 categorías de producto legacy,
  --    sort_order 1..7 con "Otros" al final. Mismo molde degrade-don't-fail
  --    que 5) y 6). Predicado por AUSENCIA TOTAL de catálogo (no por nombre):
  --    el nombre es editable por el usuario y no debe re-sembrarse si lo
  --    renombró — en el signup la cuenta es nueva, así que siembra siempre.
  BEGIN
    INSERT INTO public.product_categories (account_id, name, sort_order)
    SELECT v_account_id, v.name, v.sort_order
    FROM (VALUES
        ('Electrónica', 1),
        ('Ropa',        2),
        ('Alimentos',   3),
        ('Hogar',       4),
        ('Salud',       5),
        ('Accesorios',  6),
        ('Otros',       7)
    ) AS v(name, sort_order)
    WHERE NOT EXISTS (
      SELECT 1 FROM public.product_categories pc
      WHERE pc.account_id = v_account_id
    );
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING 'productos-categorias-sku: no se pudo sembrar el catálogo de categorías de producto para account_id=% (signup continúa). SQLERRM=%',
        v_account_id, SQLERRM;
  END;

  RETURN new;
END;
$function$
;

-- 6.4 rpc_my_account_role — deriva del pivot (member_active_roles) en vez de
--     leer la columna espejo directamente; mismo vocabulario heredado, misma
--     firma, mismo comportamiento observable para las 39 cuentas actuales
--     (100% owner).
CREATE OR REPLACE FUNCTION public.rpc_my_account_role(p_account_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT
    CASE
      WHEN 'owner' = ANY(public.member_active_roles(am.id)) THEN 'owner'
      WHEN 'admin' = ANY(public.member_active_roles(am.id)) THEN 'admin'
      ELSE 'member'
    END
  FROM   public.account_members am
  WHERE  am.account_id = p_account_id
    AND  am.user_id    = (SELECT auth.uid())
$function$
;
