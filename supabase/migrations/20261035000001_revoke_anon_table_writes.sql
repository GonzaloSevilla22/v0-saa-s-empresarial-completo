-- =============================================================================
-- revoke-anon-table-writes — S1, generalización de OQ-7 de
-- sucursal-guard-vaciado-auditoria (20261014000001, sección 9)
-- =============================================================================
--
-- EL HALLAZGO. Toda tabla de `public` nace en Supabase con INSERT/UPDATE/
-- DELETE/TRUNCATE otorgados a `anon` a nivel de TABLA (default privileges del
-- proyecto hospedado — verificado con pg_default_acl, sección 1 más abajo).
-- La única pared que existe hoy contra una escritura de `anon` es la RLS: si
-- una tabla llegara a nacer sin policy de escritura, o con una policy mal
-- escrita que evalúe a TRUE sin JWT, `anon` podría escribir directo por
-- PostgREST sin ninguna sesión. `branches` ya cerró este hueco para sí misma
-- en el change `sucursal-guard-vaciado-auditoria` (OQ-7, 20261014000001
-- sección 9) tras el incidente del 22→24-08; este archivo generaliza el
-- mismo REVOKE a TODAS las tablas base de `public`, y cierra además la puerta
-- de tablas FUTURAS (sección 3).
--
-- CENSO EN LOCAL (supabase db reset, MAX(version)=20261034000001, 283
-- migraciones — idéntico al medido por el orquestador contra prod hoy
-- 2026-09-09), verificado antes de este archivo:
--   · 72 tablas base en `public` (pg_class.relkind='r'; 4 vistas y 2
--     secuencias no son tablas y no se tocan).
--   · 3 YA con algo revocado, por trabajo previo — este archivo las vuelve a
--     recorrer igual (REVOKE repetido = no-op) para no necesitar una excepción
--     de código, y de paso les cierra el hueco que a cada una le faltaba:
--       - `branches`: INSERT/UPDATE/DELETE/TRUNCATE ya revocados de `anon`
--         (20261014000001 §9). Sin cambios de comportamiento.
--       - `events`: SELECT/INSERT revocados de `anon` y UPDATE/DELETE/
--         TRUNCATE revocados de PUBLIC+anon+authenticated
--         (20261012000001_revoke_outbox_cross_tenant.sql §2 — governance
--         CRÍTICO, outbox). Sin cambios de comportamiento (INSERT ya
--         revocado; este archivo no toca SELECT).
--       - `document_status_transitions`: INSERT/UPDATE/DELETE revocados de
--         `authenticated, anon` (20260807000001_v3_document_status_history.sql
--         L168) — pero NO TRUNCATE, que quedó afuera por descuido. Este
--         archivo lo cierra de yapa.
--   · Las 69 tablas restantes: `anon` tiene las 4 (INSERT/UPDATE/DELETE/
--     TRUNCATE) a nivel tabla — confirmado con has_table_privilege una por
--     una (no por muestreo).
--
-- EXTENSIÓN A `community` (F4, revisión adversarial de esta misma tanda,
-- 2026-09-09). `supabase/config.toml` L12 sirve `community` por la API de
-- datos exactamente igual que `public` (`schemas = ["public",
-- "graphql_public", "community"]`) — el hueco de default privileges es el
-- mismo, y quedar afuera del barrido original habría dejado sin cerrar la
-- superficie que este ítem existe para cerrar. Censo de `community` en la
-- misma base: 16 tablas base, las 16 con INSERT/UPDATE/DELETE/TRUNCATE
-- otorgados a `anon` a nivel tabla antes de este archivo (`pg_default_acl`
-- de `postgres` en `community` daba `anon=arwdDxtm`, igual que `public` antes
-- de la sección 1). Auditadas, con el MISMO criterio que la sección de abajo
-- (policy con `roles={public}` — que `anon` hereda — satisfacible SIN sesión
-- + caller real sin `Authorization`), las ~20 policies de escritura con
-- `roles={public}` sobre 12 de esas 16 tablas (`copilot_prompts`,
-- `course_enrollments`, `courses`, `fair_ai_tools`, `landing_sections`,
-- `lesson_progress`, `meetings`, `post_likes`, `posts`, `purchase_pools`,
-- `replies`, `seguros`): TODAS dependen de `auth.uid() = user_id` o de
-- `is_admin()` (que a su vez es `EXISTS (... WHERE id = auth.uid() AND
-- role = 'admin')` — `pg_get_functiondef` verificado). Con `auth.uid() IS
-- NULL` bajo `anon` puro, `auth.uid() = user_id` no evalúa a `true` (NULL =
-- valor → NULL, RLS lo trata como rechazo) e `is_admin()` da `false`
-- (ninguna fila de `profiles` tiene `id IS NULL`). Las 4 tablas restantes
-- (`course_lessons`, `course_modules`, `course_progress`,
-- `fair_recommendations`) sólo tienen policies de SELECT o de escritura con
-- `roles={authenticated}` (no `public`), así que ni siquiera entran en el
-- criterio. Caller real revisado: `frontend/app/actions/landing.ts` (Server
-- Action que escribe `landing_sections`) usa `createClient()` de
-- `@/lib/supabase/server` — cliente con cookies de sesión, nunca `anon`
-- puro sin `Authorization` — y aunque se invocara sin sesión, la RLS
-- (`is_admin()`) lo rechazaría antes de que importe el GRANT de tabla. El
-- tracking de clicks de `/seguros` (`seguros-perfil-asesor`) es una función
-- `SECURITY DEFINER` (`rpc_track_seguro_click` y familia) — no necesita
-- GRANT de tabla para `anon`. `fair-advisor` (Edge Function) inserta en
-- `fair_recommendations` con el JWT del usuario reenviado (`user.id`
-- resuelto de la sesión), nunca como `anon` puro. Conclusión: mismo
-- resultado que `public` — NINGÚN camino real escribe en `community` como
-- `anon` sin sesión. Allowlist de `community` también vacía, documentada acá
-- por el mismo motivo que la de `public`.
--
-- POR QUÉ LA ALLOWLIST QUEDA VACÍA EN `public` (diseño, no descuido; ver el
-- bloque "EXTENSIÓN A `community`" de arriba para el mismo análisis sobre
-- ese segundo schema). El criterio pedido
-- era: conservar el REVOKE de una tabla SOLO si hay una policy de escritura
-- con `roles` incluyendo `public` (que `anon` hereda) Y esa policy es
-- satisfacible SIN sesión (qual/with_check trivial, tipo `true`, o que no
-- dependa de ninguna función de identidad) Y existe un caller real que
-- escriba ahí sin Authorization. Se auditaron las 31 policies de escritura
-- con `roles={public}` sobre 16 tablas (pg_policies, cmd IN
-- ('INSERT','UPDATE','DELETE','ALL')) — la lista completa, con su
-- qual/with_check, quedó volcada en el propose de este ítem. LAS 31, sin
-- excepción, dependen de `auth.uid()`, `auth.jwt()`, `is_account_writer(...)`
-- o `current_account_ids()`. Verificado el comportamiento real de esas
-- cuatro funciones SIN JWT (auth.jwt() = NULL, auth.uid() = NULL,
-- is_account_writer(NULL) = false porque ninguna fila de account_members
-- tiene user_id NULL, current_account_ids() = conjunto vacío porque el WHERE
-- filtra por auth.uid() = NULL) — ninguna evalúa a TRUE para `anon`. Se buscó
-- además, por si alguna policy fuera trivialmente satisfacible sin depender
-- de identidad (`qual`/`with_check` = `true` o NULL con cmd distinto de
-- SELECT), en TODO `public` sin filtrar por rol: las únicas dos que
-- aparecieron (`email_logs_backend_insert` con `roles={authenticated}` y los
-- dos `stock_movements_no_*` con qual=`false`, ambas para `authenticated`)
-- son ajenas a `anon` por su propio `roles`. Conclusión: NINGUNA tabla de
-- `public` tiene hoy un camino de escritura real para `anon` — la allowlist
-- es `ARRAY[]::text[]`, documentada así para que quede explícito que se
-- decidió, no que se olvidó.
--
-- RIESGO VERIFICADO ANTES DE REVOCAR (mismo texto que pide el ítem):
--   · El alta de cuenta (`handle_new_user`, trigger sobre `auth.users`) corre
--     con privilegio de definidor (owner postgres) disparado por GoTrue, que
--     inserta en `auth.users` como el rol de servicio de Auth — nunca como
--     `anon` haciendo un INSERT directo por PostgREST. El REVOKE de este
--     archivo no lo alcanza (el trigger no necesita EXECUTE ni privilegio de
--     tabla para dispararse).
--   · Las Edge Functions (`ai-*`, `generate-export`, `send-email`, etc.)
--     usan `ANON_KEY` como credencial de transporte pero reenvían el
--     `Authorization` del usuario (passthrough del JWT) — actúan como
--     `authenticated` ante PostgREST/RLS, nunca como `anon` puro. Confirmado
--     por grep: las ~26 funciones bajo `supabase/functions/` que llaman
--     `.from(...)`/RPC pasan el header `Authorization` (mismo patrón
--     documentado en 20260824000001_revoke_anon_rest_legit_fns.sql L1-15,
--     que ya asumía esto para las 26 firmas REST-legítimas revocadas ahí).
--   · El backend Python (asyncpg/FastAPI) nunca usa el rol `anon` — corre
--     como `authenticated` por transacción desde `v31-tenancy-pool-rls`
--     (SET LOCAL ROLE) o como `postgres` en los contextos de servicio
--     (webhooks/admin) — ninguno de los dos es `anon`.
--   · El frontend (`frontend/lib/supabase/*`) siempre crea el cliente con
--     sesión (server: cookies; client: localStorage) salvo en las pantallas
--     públicas explícitamente sin login (`/`, `/planes` marketing,
--     `/seguros`), que sólo LEEN (`.select()`) — cero `.insert()`/
--     `.update()`/`.delete()` encontrados fuera de rutas `(dashboard)` o de
--     Server Actions que ya exigen `auth.getUser()` primero (grep
--     `frontend/app/api`, `frontend/app/landing`, `frontend/app/actions`:
--     los dos escritores de `frontend/app/api/billing/*` y el escritor de
--     `frontend/app/actions/landing.ts` verifican sesión / escriben en el
--     schema `community`, ajeno a este REVOKE que sólo toca `public`).
--
-- DISEÑO:
--   D1 — Barrido dinámico (no 72 líneas a mano) sobre TODAS las tablas base
--        de `public` vía `pg_class`/`pg_namespace`, excluyendo la allowlist
--        (vacía). `REVOKE ... FROM anon` sobre una tabla que ya no tiene el
--        privilegio es no-op — no hace falta excluir a `branches`/`events`/
--        `document_status_transitions` del barrido.
--   D2 — SELECT, REFERENCES y TRIGGER de `anon` NO se tocan: son lecturas/
--        vínculos legítimos y no forman parte del pedido (mismo criterio que
--        20261014000001 §9 para `branches`).
--   D3 — `authenticated`, `service_role` y `postgres` no se tocan.
--   D4 — Además del barrido sobre las tablas EXISTENTES, se revoca el
--        DEFAULT PRIVILEGE del rol `postgres` en el schema `public` para que
--        una tabla FUTURA (creada por una migración, que siempre corre como
--        `postgres`) no vuelva a nacer con el hueco — sin esto, el barrido de
--        hoy es una foto que una sola migración nueva desactualiza. Se
--        extiende a incluir TRUNCATE además de INSERT/UPDATE/DELETE (D5) para
--        que el "piso" de una tabla nueva sea exactamente el mismo que el
--        que este archivo deja en las 72 existentes — sin este agregado, una
--        tabla nueva nacería con TRUNCATE abierto para `anon` mientras las 72
--        de hoy no lo tienen, una asimetría sin motivo.
--   D5 — Ver D4. Deviation menor respecto del comando literal pedido
--        (que sólo nombraba INSERT/UPDATE/DELETE): se agrega TRUNCATE por
--        consistencia con la sección 2, nunca resta alcance.
--
-- Idempotente: REVOKE repetido no falla (no-op si el privilegio ya no
-- existe); ALTER DEFAULT PRIVILEGES ... REVOKE repetido tampoco falla.
-- Verificado con doble aplicación en local sin error y sin cambio de ACL
-- entre la primera y la segunda corrida.
--
-- Candado: supabase/tests/test_anon_table_writes_revoked.sql — sweep
-- completo + verificación de comportamiento REAL (no sólo metadata): una
-- tabla nueva creada por `postgres` nace sin los 4 privilegios, y un INSERT
-- real como `anon` contra tablas representativas falla con
-- "permission denied for table" (capa de GRANT) y NO con "new row violates
-- row-level security policy" (capa de RLS) — la distinción importa porque
-- Postgres usa el MISMO SQLSTATE 42501 para ambos casos; sólo el texto del
-- mensaje distingue la capa que realmente frenó la escritura.
--
-- Spec: openspec/specs/account-tenancy/spec.md — nuevo requirement "anon no
-- tiene privilegios de escritura a nivel tabla sobre las tablas de negocio".
--
-- Sin superficie frontend (declarado): este archivo no cambia ningún
-- comportamiento observable para un usuario con sesión — sólo cierra un
-- camino que ya estaba cerrado por RLS para quien no la tiene.
--
-- GOVERNANCE: CRÍTICO (orden del PO, tanda de candidatos de seguridad/
-- tenencia — el "OK" de gobernanza para este ítem ya está dado; ejecutado
-- con evidencia RED/GREEN completa antes y después).
--
-- APPLY: npx supabase db push  (NUNCA MCP apply_migration)
-- ROLLBACK (aditivo — en prod NO se revierte sin motivo; si hiciera falta,
-- re-otorgar puntualmente sólo la tabla y el privilegio que un caller nuevo
-- necesite, nunca en bloque):
--   GRANT INSERT, UPDATE, DELETE, TRUNCATE ON public.<tabla> TO anon;      -- o community.<tabla>
--   ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public            -- o community
--     GRANT INSERT, UPDATE, DELETE, TRUNCATE ON TABLES TO anon;
-- =============================================================================


-- =============================================================================
-- 1. Barrido: REVOKE INSERT/UPDATE/DELETE/TRUNCATE de `anon` sobre TODAS las
--    tablas base de `public` Y `community`, salvo la allowlist (D1). La
--    allowlist se califica por schema (`'schema.tabla'`) para no ambiguar si
--    algún día un nombre de tabla se repitiera entre los dos schemas.
--    Allowlist vacía en ambos schemas — documentada en el encabezado de este
--    archivo (F4), no un olvido.
-- =============================================================================

DO $$
DECLARE
  v_allowlist CONSTANT text[] := ARRAY[]::text[];
  r RECORD;
  v_count integer := 0;
BEGIN
  FOR r IN
    SELECT n.nspname AS schemaname, c.relname AS tablename
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname IN ('public', 'community')
      AND c.relkind = 'r'   -- tabla ordinaria (excluye vistas 'v', índices 'i', secuencias 'S')
  LOOP
    IF (r.schemaname || '.' || r.tablename) = ANY (v_allowlist) THEN
      CONTINUE;
    END IF;

    EXECUTE format('REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON %I.%I FROM anon', r.schemaname, r.tablename);
    v_count := v_count + 1;
  END LOOP;

  RAISE NOTICE 'revoke-anon-table-writes: barrido aplicado sobre % tablas de public+community (allowlist: % entradas).', v_count, coalesce(array_length(v_allowlist, 1), 0);
END $$;


-- =============================================================================
-- 2. Default privileges (D4/D5): una tabla FUTURA creada por `postgres` (toda
--    migración corre como `postgres`) nace SIN INSERT/UPDATE/DELETE/TRUNCATE
--    para `anon`, en `public` Y en `community` (F4). No afecta tablas creadas
--    por otro owner (p.ej. `supabase_admin`, que tiene su propia fila en
--    pg_default_acl, sin tocar — ver F5 más abajo) — las migraciones de este
--    proyecto siempre corren como `postgres` (regla dura: `npx supabase db
--    push`, nunca el MCP apply_migration).
-- =============================================================================

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLES FROM anon;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA community
  REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLES FROM anon;

-- F5 (revisión adversarial, MINOR): el REVOKE de arriba sólo cubre las
-- tablas que el ROL `postgres` cree en el futuro. `supabase_admin` tiene su
-- PROPIA fila en pg_default_acl (con `anon=arwdDxtm` intacto) y podría, en
-- teoría, crear una tabla en `public`/`community` desde fuera del camino de
-- migraciones (dashboard de Supabase, extensión gestionada) que nacería con
-- el hueco abierto. En prod, la migración corre como `postgres` — no
-- necesariamente el MISMO rol que posee `supabase_admin` sus propios
-- defaults — así que alterar los defaults de OTRO rol puede fallar por
-- `insufficient_privilege` según los permisos que Supabase le dé a
-- `postgres` sobre los objetos de `supabase_admin`. Se envuelve en un DO con
-- EXCEPTION que degrada a NOTICE en vez de abortar la migración completa por
-- un endurecimiento best-effort de un rol que este proyecto no administra.
DO $$
BEGIN
  EXECUTE 'ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLES FROM anon';
  RAISE NOTICE 'revoke-anon-table-writes (F5): default privilege de supabase_admin en public endurecido para anon.';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'revoke-anon-table-writes (F5): sin permiso para alterar los default privileges de supabase_admin en public — requirement de la spec acotado a las tablas creadas por el rol propietario de las migraciones (postgres); revisar manualmente en el chequeo post-merge de prod.';
END $$;

DO $$
BEGIN
  EXECUTE 'ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA community REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLES FROM anon';
  RAISE NOTICE 'revoke-anon-table-writes (F5): default privilege de supabase_admin en community endurecido para anon.';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'revoke-anon-table-writes (F5): sin permiso para alterar los default privileges de supabase_admin en community — mismo caso que public, ver arriba.';
END $$;


-- =============================================================================
-- 3. Gate de la propia migración.
-- =============================================================================

DO $$
DECLARE
  v_allowlist CONSTANT text[] := ARRAY[]::text[];
  v_bad       text := '';
  r           RECORD;
  v_acl       aclitem[];
  v_priv      text;
  v_schema    text;
BEGIN
  -- (a) Ninguna tabla de public/community fuera de la allowlist conserva
  --     INSERT/UPDATE/DELETE/TRUNCATE para anon.
  FOR r IN
    SELECT n.nspname AS schemaname, c.relname AS tablename
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname IN ('public', 'community')
      AND c.relkind = 'r'
  LOOP
    IF (r.schemaname || '.' || r.tablename) = ANY (v_allowlist) THEN
      CONTINUE;
    END IF;

    IF has_table_privilege('anon', format('%I.%I', r.schemaname, r.tablename), 'INSERT')
       OR has_table_privilege('anon', format('%I.%I', r.schemaname, r.tablename), 'UPDATE')
       OR has_table_privilege('anon', format('%I.%I', r.schemaname, r.tablename), 'DELETE')
       OR has_table_privilege('anon', format('%I.%I', r.schemaname, r.tablename), 'TRUNCATE')
    THEN
      v_bad := v_bad || r.schemaname || '.' || r.tablename || ' ';
    END IF;
  END LOOP;

  IF v_bad <> '' THEN
    RAISE EXCEPTION 'revoke-anon-table-writes GATE (a) FAILED: anon todavía tiene INSERT/UPDATE/DELETE/TRUNCATE a nivel tabla sobre: %', v_bad;
  END IF;

  -- (b) El default privilege de postgres/{public,community}/tablas ya no
  --     incluye a anon para esos 4 privilegios (tablas FUTURAS).
  FOREACH v_schema IN ARRAY ARRAY['public', 'community'] LOOP
    SELECT defaclacl INTO v_acl
    FROM pg_default_acl
    WHERE defaclrole = 'postgres'::regrole
      AND defaclnamespace = v_schema::regnamespace
      AND defaclobjtype = 'r';

    IF v_acl IS NOT NULL THEN
      FOREACH v_priv IN ARRAY ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE'] LOOP
        IF aclcontains(v_acl, makeaclitem('anon'::regrole, 'postgres'::regrole, v_priv, false)) THEN
          RAISE EXCEPTION 'revoke-anon-table-writes GATE (b) FAILED: el default privilege de postgres en % todavía otorga % a anon sobre tablas futuras: %', v_schema, v_priv, v_acl;
        END IF;
      END LOOP;
    END IF;
  END LOOP;

  RAISE NOTICE 'revoke-anon-table-writes OK: % tablas de public+community sin INSERT/UPDATE/DELETE/TRUNCATE para anon (allowlist vacía) y el default privilege de postgres ya no las reabre en tablas futuras.', (
    SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname IN ('public', 'community') AND c.relkind = 'r'
  );
END $$;
