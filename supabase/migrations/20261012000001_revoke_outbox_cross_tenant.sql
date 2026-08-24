-- ═══════════════════════════════════════════════════════════════════════════
-- revoke-outbox-cross-tenant — HOTFIX CRÍTICO (tramo h2 de
-- tenancy-guard-caja-outbox; el PO firmó OQ-1 = "h2 sale como hotfix ahora,
-- h1 después")
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Change de origen: openspec/changes/tenancy-guard-caja-outbox/
--   proposal.md §"2. h2 — El outbox deja de ser alcanzable desde el rol de
--   aplicación", design.md D3/D4/D6/D7, tasks.md grupos 4 y 5. El propio
--   tasks.md ya preveía este desenlace: "Si OQ-1 sale como hotfix, este grupo
--   entero se muda al PR del hotfix". El tramo h1 (guard de la sesión de caja
--   en _c29_confirm_order_core / c28_register_cash_movement) NO entra acá y
--   sigue en ese change — este archivo no toca ninguna de esas dos funciones.
--
-- ── El vector, concreto ─────────────────────────────────────────────────────
--
-- rpc_process_outbox_batch(integer) y rpc_mark_event_processed(uuid) nacen en
-- 20260718000001_c25_events_outbox_reconcile.sql (L172 y L203) con
-- REVOKE ... FROM PUBLIC + REVOKE ... FROM anon + **GRANT EXECUTE ... TO
-- authenticated**, y ninguna migración posterior las revoca. Las dos son
-- SECURITY DEFINER y recorren public.events **sin filtro de tenant**, por
-- diseño (leer cross-account es la razón de ser de un relay):
--
--   rpc_process_outbox_batch  → SELECT * FROM public.events
--                               WHERE processed_at IS NULL
--                               ORDER BY occurred_at LIMIT $1
--                               FOR UPDATE SKIP LOCKED
--   rpc_mark_event_processed  → UPDATE public.events
--                               SET processed_at = now() WHERE id = $1
--
-- Con GRANT a `authenticated`, cualquier usuario logueado las alcanza por
-- PostgREST y puede: (a) leer el payload completo de los eventos de TODOS los
-- tenants —account_id, amount, client_id— sin conocer ningún UUID de
-- antemano (el batch se los entrega), y (b) marcarlos processed_at, con lo
-- cual el despachador real nunca postea su asiento contable: supresión
-- silenciosa de la contabilidad de la víctima. Reproducido en local con
-- `SET LOCAL ROLE authenticated` y los claims de un usuario del tenant A: el
-- batch devuelve eventos del tenant B.
--
-- Daño histórico medido en prod (2026-08-23/24, sólo SELECT): **cero**
-- — 626 eventos, 0 pendientes, 464 elegibles para asiento y 465 asientos,
-- 0 eventos procesados sin su asiento. El endpoint nunca se usó en producción.
-- Seguía siendo un botón, sin llave, que borra la contabilidad de 10 tenants.
--
-- ── Por qué REVOKE y no un filtro por tenant (design.md D3) ─────────────────
--
-- Filtrar por current_account_ids() sería SEMÁNTICAMENTE INCORRECTO: el spec
-- vigente de `transactional-outbox` exige que el relay lea todos los eventos
-- pendientes cross-account; con filtro, bajo el Paso 2 del pool sólo
-- procesaría los del admin que aprieta el botón y el resto quedaría pendiente
-- para siempre — se cambiaría una fuga por una avería. Y no arreglaría nada:
-- un relay filtrado sigue marcando processed_at sin postear el asiento.
--
-- El REVOKE es posible porque estas dos funciones quedan **sin ningún caller
-- de aplicación**: el único caller legítimo pasa a ser el camino de servicio
-- del disparador manual (POST /outbox/process-pending), que en el mismo PR
-- deja de usarlas y delega en rpc_process_outbox_dispatch — el despachador
-- completo, el mismo que corre el pg_cron job `relay-process-outbox`. Ese
-- endpoint corre sobre `get_service_conn`, que por contrato de
-- v31-tenancy-pool-rls D5 NUNCA adopta el rol `authenticated` sin importar el
-- estado de ninguna de las dos palancas del pool (candado con test propio en
-- backend/tests/outbox/test_process_pending_endpoint.py, OQ-6). Por eso este
-- REVOKE sobrevive al Paso 2.
--
-- El REVOKE tampoco rompe al despachador: rpc_process_outbox_dispatch no
-- invoca a ninguna de las dos (tiene su propio FOR ... LOOP sobre events) y
-- lo llama el pg_cron como `postgres`, el owner.
--
-- ── La puerta de al lado: la TABLA public.events ───────────────────────────
--
-- Cerrar las dos RPCs no alcanza. Medido en prod el 2026-08-24 (sólo SELECT):
-- `anon` y `authenticated` tienen SELECT, INSERT, UPDATE, DELETE, TRUNCATE,
-- REFERENCES y TRIGGER **a nivel tabla** sobre `public.events`, concedidos
-- DIRECTO (ningún grantee `PUBLIC`, gotcha #432 otra vez). Lo único que hoy
-- impide cerrar un evento ajeno con un `PATCH /rest/v1/events?id=eq...` es que
-- la tabla tiene RLS activa con exactamente dos policies —`events_select`
-- (polcmd `r`, USING account_id IN current_account_ids()) y
-- `events_writer_insert` (polcmd `a`, authenticated, WITH CHECK del mismo
-- tenant)— y NINGUNA de UPDATE ni de DELETE. Un UPDATE sin policy no da error:
-- afecta 0 filas. O sea que la puerta la cierra la AUSENCIA de una policy, y
-- eso no lo afirmaba ningún gate: el día que alguien agregue una policy de
-- escritura sobre `events` —por el motivo que sea— el agujero de h2 vuelve
-- entero por la puerta de al lado, sin tocar ninguna función.
--
-- Por eso esta migración revoca también a nivel tabla:
--   · UPDATE, DELETE, TRUNCATE  → de PUBLIC, anon y authenticated. Son los
--     tres verbos con los que se cierra o se borra un evento ajeno; ninguna
--     ruta de la aplicación los usa (verificado por grep en backend/ y
--     frontend/ el 2026-08-24: cero `.from('events')`, cero `FROM
--     public.events`, cero Edge Function; `public.events` tampoco está en
--     ninguna publicación de Realtime).
--   · SELECT e INSERT           → de PUBLIC y `anon` solamente.
--
-- **`authenticated` CONSERVA SELECT e INSERT, y es deliberado.** INSERT lo
-- necesita `OutboxRepository.emit_event` (backend/repositories/
-- outbox_repository.py L62-75), el productor que usan purchase_repository.py
-- y stock_repository.py. SELECT lo necesita ESE MISMO INSERT: termina en
-- `RETURNING id`, y RETURNING exige privilegio de SELECT sobre la columna
-- devuelta. Hoy el pool corre como owner y no se nota; el día que se encienda
-- el Paso 2 (`SET LOCAL ROLE authenticated`, TENANCY_TX_SCOPE_ENABLED) un
-- `REVOKE SELECT` rompería toda emisión de eventos — el mismo tipo de rotura
-- silenciosa que este hotfix viene a evitar. Y no cuesta nada dejarlos: la
-- policy `events_select` ya acota la lectura al propio tenant, así que SELECT
-- para `authenticated` NO es superficie cross-tenant; UPDATE y DELETE sí lo
-- serían el día que aparezca su policy.
--
-- ── Alcance ────────────────────────────────────────────────────────────────
--
-- SOLO ACL (de función y de tabla) + COMMENT. **Ningún cuerpo se toca**: sin
-- CREATE OR REPLACE, sin DROP, sin cambio de firma ni de owner. Por eso no hay
-- baseline de pg_get_functiondef que capturar (el gate de integridad de
-- función aplica a las reescrituras, y acá no hay ninguna).
--
-- Enumerar los TRES roles en el REVOKE no es redundante (gotcha #432,
-- asiento-venta-formulario): el proyecto hospedado concede EXECUTE a
-- anon/authenticated **directo**, no vía el pseudo-rol PUBLIC, así que un
-- `REVOKE ... FROM PUBLIC` que se ve limpio en el stack local puede dejar
-- prod abierto. `service_role` NO se nombra: conserva su EXECUTE, igual que
-- en el hotfix #454.
--
-- ACLs vivas en prod verificadas antes de esta migración (2026-08-24):
--   rpc_process_outbox_batch(integer)     anon=f authenticated=TRUE  svc=t
--   rpc_mark_event_processed(uuid)        anon=f authenticated=TRUE  svc=t
--   rpc_process_outbox_dispatch(integer)  anon=f authenticated=f     svc=t  ← modelo correcto
--
-- ── Gate permanente ────────────────────────────────────────────────────────
--
-- supabase/tests/test_function_acl_gate.sql suma el chequeo (5)
-- (`v_cross_tenant_event_fns`): lista curada, cerrada y que sólo crece, de
-- toda función SECURITY DEFINER que LEA (FROM public.events) o ACTUALICE
-- (UPDATE public.events) el outbox, cada entrada con su veredicto. El
-- chequeo (4) vigente NO habría atrapado esto: su filtro de nombre excluye
-- `rpc_*` a propósito, y el hueco vivía justamente en dos `rpc_*`.
-- El comportamiento en runtime del único despachador —los invariantes que
-- cubrían los tests del relay Python retirado— pasa a
-- supabase/tests/test_outbox_single_dispatcher.sql.
--
-- Idempotente: REVOKE y COMMENT son operaciones absolutas, no incrementales;
-- reaplicar el archivo deja exactamente el mismo estado (verificado en local
-- con dos aplicaciones seguidas y fingerprint md5 de cuerpos + ACLs de función
-- + ACL de tabla + comments). Drift-tolerante de punta a punta: cada bloque
-- saltea lo que no existe en el entorno —`to_regprocedure` para las funciones
-- (incluido el bloque de COMMENT, que por eso NO usa `COMMENT ON FUNCTION`
-- suelto sino `EXECUTE format(...)` dentro del mismo LOOP), `to_regclass` para
-- la tabla y `pg_roles` para los roles de Supabase—. Sin BOM UTF-8. Sin
-- ERRCODEs nuevos.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. REVOKE — las dos RPCs del outbox salen de la superficie de PostgREST
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_sig text;
  v_fns CONSTANT text[] := ARRAY[
    'public.rpc_process_outbox_batch(integer)',
    'public.rpc_mark_event_processed(uuid)'
  ];
BEGIN
  FOREACH v_sig IN ARRAY v_fns LOOP
    CONTINUE WHEN to_regprocedure(v_sig) IS NULL;  -- drift-tolerante
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated',
                   to_regprocedure(v_sig)::text);
  END LOOP;
END $$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. REVOKE de TABLA — la puerta de al lado (ver cabecera §"La puerta de al
--    lado"): hoy la cierra la AUSENCIA de una policy de escritura, no un
--    privilegio. A partir de acá la cierran las dos cosas.
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
  IF to_regclass('public.events') IS NULL THEN
    RAISE NOTICE 'REVOKE-OUTBOX: public.events no existe en este entorno — REVOKE de tabla omitido';
    RETURN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon')
     OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    RAISE NOTICE 'REVOKE-OUTBOX: faltan los roles de Supabase en este entorno — REVOKE de tabla omitido';
    RETURN;
  END IF;

  -- Los tres verbos con los que se cierra o se borra un evento ajeno. Ninguna
  -- ruta de la aplicación los usa.
  REVOKE UPDATE, DELETE, TRUNCATE ON TABLE public.events FROM PUBLIC, anon, authenticated;

  -- `anon` no tiene nada que hacer en el outbox, ni leyendo ni emitiendo.
  -- `authenticated` NO entra en esta línea: conserva SELECT e INSERT porque
  -- los necesita emit_event (INSERT ... RETURNING id ⇒ hace falta SELECT), y
  -- su lectura ya está acotada al propio tenant por la policy events_select.
  REVOKE SELECT, INSERT ON TABLE public.events FROM PUBLIC, anon;
END $$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. COMMENT — el contrato, escrito donde lo va a leer el próximo que la toque
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Vía EXECUTE format(...) y no `COMMENT ON FUNCTION` suelto: un COMMENT sobre
-- una función ausente ABORTA el archivo, y esta migración se declara
-- drift-tolerante en su cabecera. El texto de cada comentario se pasa con %L,
-- así que va íntegro (incluidos el guion largo y el "SIN GRANT — NO AGREGAR
-- UNO" con el que abre).

DO $$
DECLARE
  v_i int;
  v_sigs CONSTANT text[] := ARRAY[
    'public.rpc_process_outbox_batch(integer)',
    'public.rpc_mark_event_processed(uuid)'
  ];
  v_comments CONSTANT text[] := ARRAY[
    'SIN GRANT — NO AGREGAR UNO. Recorre public.events de TODOS los tenants sin '
    'filtro de tenant (es la razón de ser de un relay, no un descuido): con '
    'EXECUTE para authenticated, cualquier usuario logueado lee por PostgREST el '
    'payload completo de los eventos ajenos sin conocer ningún UUID. Revocada de '
    'PUBLIC, anon y authenticated por 20261012000001 (tramo h2 de '
    'tenancy-guard-caja-outbox, OQ-1 firmada como hotfix). service_role conserva '
    'su EXECUTE. Único caller legítimo: el camino de servicio del disparador '
    'manual (POST /outbox/process-pending), que hoy NO la usa — delega en '
    'rpc_process_outbox_dispatch, el único despachador, el mismo que corre el '
    'pg_cron job relay-process-outbox. Sostenida por el chequeo (5) '
    '(v_cross_tenant_event_fns) de supabase/tests/test_function_acl_gate.sql.',

    'SIN GRANT — NO AGREGAR UNO. Hace UPDATE public.events SET processed_at '
    'WHERE id = $1, sin filtro de tenant: con EXECUTE para authenticated, '
    'cualquier usuario logueado cierra eventos ajenos y el despachador real '
    'nunca postea su asiento contable — supresión silenciosa de la contabilidad '
    'de otro tenant. Revocada de PUBLIC, anon y authenticated por '
    '20261012000001 (tramo h2 de tenancy-guard-caja-outbox, OQ-1 firmada como '
    'hotfix). service_role conserva su EXECUTE. Único caller legítimo: el camino '
    'de servicio del disparador manual, que hoy NO la usa — el marcado vive '
    'dentro de rpc_process_outbox_dispatch, después de sus cuatro consumers. '
    'Sostenida por el chequeo (5) de supabase/tests/test_function_acl_gate.sql.'
  ];
BEGIN
  FOR v_i IN 1 .. array_length(v_sigs, 1) LOOP
    CONTINUE WHEN to_regprocedure(v_sigs[v_i]) IS NULL;  -- drift-tolerante
    EXECUTE format('COMMENT ON FUNCTION %s IS %L',
                   to_regprocedure(v_sigs[v_i])::text, v_comments[v_i]);
  END LOOP;
END $$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. GATE — anti-overload, ACLs resultantes, y auditoría del estado heredado
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_sig   text;
  v_count int;
  v_fns CONSTANT text[] := ARRAY[
    'public.rpc_process_outbox_batch(integer)',
    'public.rpc_mark_event_processed(uuid)'
  ];
  -- Heredado del hotfix #454 (20261010000001_revoke_internal_money_helpers):
  -- estos dos helpers reciben el tenant POR PARÁMETRO y son SECURITY DEFINER.
  -- Se verifican acá porque esta migración es el ÚLTIMO eslabón de la cadena
  -- de reapply de CI, y varios eslabones previos re-otorgan GRANTs en silencio
  -- con su bloque REVOKE+GRANT "de plantilla" (20261001000001 L137/L1914,
  -- 20261004000001 L1778).
  v_helpers_454 CONSTANT text[] := ARRAY[
    'public._pay_register_party_charge(uuid, text, uuid, numeric, uuid, uuid)',
    'public._journal_post_from_event(events)'
  ];
BEGIN
  -- Entorno sin roles de Supabase (p.ej. postgres pelado): nada que verificar.
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    RAISE NOTICE 'GATE REVOKE-OUTBOX: rol anon no existe en este entorno — gate omitido';
    RETURN;
  END IF;

  -- ── (a) ANTI-OVERLOAD: una sola definición por nombre ─────────────────────
  -- Esta migración no crea ni reemplaza funciones, así que no puede generar
  -- overloads fantasma (mecanismo 42725); el chequeo está igual por higiene y
  -- porque un overload preexistente haría que el REVOKE de arriba cierre UNA
  -- firma y deje la otra abierta — falso verde peligroso.
  FOR v_sig IN SELECT unnest(ARRAY['rpc_process_outbox_batch',
                                   'rpc_mark_event_processed',
                                   'rpc_process_outbox_dispatch'])
  LOOP
    SELECT count(*) INTO v_count
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = v_sig;

    IF v_count > 1 THEN
      RAISE EXCEPTION
        'GATE REVOKE-OUTBOX FAILED (a, 42725): % tiene % definiciones — el REVOKE cerró una firma y dejó la otra abierta.',
        v_sig, v_count;
    END IF;
  END LOOP;

  -- ── (b) GATE NEG: las dos quedan sin EXECUTE para anon ni authenticated ───
  FOREACH v_sig IN ARRAY v_fns LOOP
    CONTINUE WHEN to_regprocedure(v_sig) IS NULL;
    IF has_function_privilege('anon', to_regprocedure(v_sig), 'EXECUTE')
       OR has_function_privilege('authenticated', to_regprocedure(v_sig), 'EXECUTE') THEN
      RAISE EXCEPTION
        'GATE REVOKE-OUTBOX FAILED (b): % sigue ejecutable vía PostgREST — recorre el outbox de todos los tenants sin filtro.',
        v_sig;
    END IF;
  END LOOP;

  -- ── (c) GATE POS: postgres (owner) conserva su EXECUTE ────────────────────
  -- Sin esto, un REVOKE demasiado amplio dejaría el gate "verde" habiendo roto
  -- la cadena DEFINER y el camino de servicio.
  --
  -- NO se afirma nada sobre `service_role`, y es a propósito: su privilegio
  -- DIFIERE entre entornos y este gate corre contra el stack local. Medido el
  -- 2026-08-24 — en prod service_role tiene EXECUTE sobre las tres RPCs del
  -- outbox (grant de plataforma del proyecto hospedado), en local NO lo tiene
  -- (nacieron con REVOKE ALL FROM PUBLIC + GRANT sólo a authenticated). Es el
  -- espejo del gotcha #432: allá el gate daría verde y acá rojo, por una
  -- diferencia de entorno que no dice nada sobre este hotfix. Lo único que
  -- importa acá es que NINGÚN REVOKE de este archivo nombra a service_role,
  -- así que su privilegio —el que sea en cada entorno— queda intacto.
  FOREACH v_sig IN ARRAY v_fns LOOP
    CONTINUE WHEN to_regprocedure(v_sig) IS NULL;
    IF NOT has_function_privilege('postgres', to_regprocedure(v_sig), 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE REVOKE-OUTBOX FAILED (c): postgres quedó sin EXECUTE en %', v_sig;
    END IF;
  END LOOP;

  -- ── (d) El despachador real queda EXACTAMENTE como estaba ─────────────────
  -- rpc_process_outbox_dispatch es el modelo correcto (anon=f, auth=f, svc=t)
  -- y el único camino que postea asientos. Si un REVOKE de más lo tocara, o si
  -- alguien lo expusiera, el hotfix habría cambiado una fuga por otra.
  IF to_regprocedure('public.rpc_process_outbox_dispatch(integer)') IS NOT NULL THEN
    IF has_function_privilege('anon', 'public.rpc_process_outbox_dispatch(integer)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.rpc_process_outbox_dispatch(integer)'::regprocedure, 'EXECUTE') THEN
      RAISE EXCEPTION
        'GATE REVOKE-OUTBOX FAILED (d): rpc_process_outbox_dispatch quedó expuesta a anon/authenticated — el despachador completo no es API pública.';
    END IF;
    IF NOT has_function_privilege('postgres', 'public.rpc_process_outbox_dispatch(integer)'::regprocedure, 'EXECUTE') THEN
      RAISE EXCEPTION
        'GATE REVOKE-OUTBOX FAILED (d): rpc_process_outbox_dispatch perdió EXECUTE para postgres — el pg_cron relay-process-outbox dejaría de despachar.';
    END IF;
  END IF;

  -- ── (e) Verificación heredada: los helpers de #454 SIGUEN cerrados ────────
  FOREACH v_sig IN ARRAY v_helpers_454 LOOP
    CONTINUE WHEN to_regprocedure(v_sig) IS NULL;
    IF has_function_privilege('anon', to_regprocedure(v_sig), 'EXECUTE')
       OR has_function_privilege('authenticated', to_regprocedure(v_sig), 'EXECUTE') THEN
      RAISE EXCEPTION
        'GATE REVOKE-OUTBOX FAILED (e): % volvió a quedar ejecutable por anon/authenticated. Lo cerró el hotfix #454 (20261010000001_revoke_internal_money_helpers.sql); si esto salta en CI, un eslabón de la cadena de reapply reintrodujo el GRANT del patrón uniforme REVOKE+GRANT y hay que reordenar la cadena, no agregar una excepción.',
        v_sig;
    END IF;
  END LOOP;

  -- ── (f) La TABLA public.events queda sin los verbos de escritura ──────────
  -- El complemento del (b): cerrar las funciones y dejar la tabla abierta sería
  -- mover el picaporte de lado. Se afirma sólo lo NEGATIVO (UPDATE/DELETE/
  -- TRUNCATE fuera) y no lo positivo (SELECT/INSERT de authenticated dentro),
  -- porque el privilegio positivo DIFIERE entre entornos —igual que en (c)—:
  -- medido el 2026-08-24, en prod anon/authenticated tienen los 7 privilegios
  -- y en local sólo REFERENCES/TRIGGER/TRUNCATE. Afirmar el positivo haría
  -- fallar este gate en local por una diferencia de entorno que no dice nada
  -- sobre este hotfix.
  IF to_regclass('public.events') IS NOT NULL THEN
    FOR v_sig IN SELECT unnest(ARRAY['anon', 'authenticated']) LOOP
      IF has_table_privilege(v_sig, 'public.events', 'UPDATE')
         OR has_table_privilege(v_sig, 'public.events', 'DELETE')
         OR has_table_privilege(v_sig, 'public.events', 'TRUNCATE') THEN
        RAISE EXCEPTION
          'GATE REVOKE-OUTBOX FAILED (f): el rol % conserva UPDATE/DELETE/TRUNCATE sobre la TABLA public.events. Hoy eso no se explota porque la tabla no tiene policy de UPDATE ni de DELETE (un UPDATE sin policy afecta 0 filas y no da error), pero eso hace que la puerta la cierre la AUSENCIA de una policy: el día que se agregue una de escritura, cerrar eventos ajenos vuelve a ser un PATCH por PostgREST. Ver 20261012000001_revoke_outbox_cross_tenant.sql §2.',
          v_sig;
      END IF;
    END LOOP;

    IF has_table_privilege('anon', 'public.events', 'SELECT')
       OR has_table_privilege('anon', 'public.events', 'INSERT') THEN
      RAISE EXCEPTION
        'GATE REVOKE-OUTBOX FAILED (f): anon conserva SELECT o INSERT sobre public.events. anon no emite eventos ni los lee — el único productor con rol de aplicación es OutboxRepository.emit_event, que corre como authenticated.';
    END IF;
  END IF;

  RAISE NOTICE 'GATE REVOKE-OUTBOX OK: rpc_process_outbox_batch y rpc_mark_event_processed sin EXECUTE para anon/authenticated (service_role y postgres intactos); rpc_process_outbox_dispatch sin cambios; helpers de #454 siguen cerrados; tabla public.events sin UPDATE/DELETE/TRUNCATE para anon/authenticated y sin SELECT/INSERT para anon.';
END $$;
