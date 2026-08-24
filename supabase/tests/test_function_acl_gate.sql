-- ═══════════════════════════════════════════════════════════════════════════
-- Gate anti-regresión de ACLs — advisors 0028/0029
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Contexto: DROP FUNCTION + CREATE resetea el ACL al default (EXECUTE a
-- PUBLIC → anon/authenticated la heredan), mientras que CREATE OR REPLACE
-- conserva ACLs. Así regresaron check_low_margin() y handle_new_user() pese
-- al revoke de 20260517000002 (ver openspec/explore/2026-07-31-advisor-0028-
-- 0029-inventory.md §"Hallazgo sistémico").
--
-- Este gate corre en CI contra la DB resultante de TODAS las migraciones y
-- falla el PR si:
--   (1) una función trigger SECURITY DEFINER queda ejecutable por
--       anon/authenticated (invariante sin allowlist: las funciones trigger
--       nunca necesitan grants REST — Postgres no chequea EXECUTE al disparar
--       triggers), o
--   (2) una función SECURITY DEFINER queda ejecutable por `anon` fuera de la
--       allowlist explícita de abajo, o
--   (3) uno de los helpers "solo-DEFINER" de la lista `v_internal_only_fns`
--       queda ejecutable por `anon` O `authenticated` (sin excepciones — a
--       diferencia de (2) y de (4), acá no hay allowlist: estos helpers
--       reciben el tenant/la parte por parámetro y SOLO deben poder
--       invocarse desde otra función SECURITY DEFINER que ya validó al
--       usuario, nunca directo vía PostgREST), o
--   (4) una función SECURITY DEFINER **no-trigger de nombre interno** (prefijo
--       `_`, o prefijo de fase `c28_`/`c29_`/`c30_`) queda ejecutable por
--       `authenticated` fuera de su propia allowlist, o
--   (5) una función SECURITY DEFINER que **lee o actualiza el outbox**
--       (`FROM public.events` / `UPDATE public.events`) no está enumerada en
--       la lista curada `v_cross_tenant_event_fns`, o está enumerada como NO
--       expuesta y sin embargo es ejecutable por `anon` o `authenticated`.
--
-- (3) y (4) atacan el mismo punto ciego por dos caminos complementarios y
-- deliberadamente redundantes: (3) es una **lista cerrada y nominal** de los
-- helpers de dinero que ya se sabe que nunca deben estar expuestos —falla sin
-- excepción posible—, y (4) es un **barrido por convención de nombre** que
-- descubre helpers internos que nadie dio de alta en ninguna lista, incluidos
-- los que todavía no existen. Un helper que caiga en las dos redes hace
-- fallar los dos chequeos: eso es intencional, no duplicación a limpiar.
--
-- v_internal_only_fns (check 3) nace en el hotfix 2026-08-23 (PR #454):
-- PostgREST expone por default TODA función `public` a `authenticated` (y a
-- veces `anon`) salvo REVOKE explícito, y ese REVOKE se pierde en silencio
-- cuando una migración posterior hace CREATE OR REPLACE + un REVOKE/GRANT "de
-- plantilla" sin notar que ESE helper puntual no lleva GRANT — le pasó a
-- _pay_register_party_charge (GRANT desde su creación,
-- 20261001000001_pagos_cableados_restantes.sql L137) y a
-- _journal_post_from_event (bien revocado al nacer en 20260803000001 L517,
-- regrant reintroducido en 20261001000001 L1914 y 20261004000001 L1778) —
-- ambos quedaron invocables por `authenticated` en prod con el tenant/la
-- parte por parámetro: escritura cross-tenant real vía PostgREST. Ver
-- 20261010000001_revoke_internal_money_helpers.sql (el REVOKE) y
-- openspec/changes/cuenta-corriente-party-guard/ (donde se detectó, OQ-2).
-- Mantenimiento: esta lista SOLO crece (agregar cualquier helper interno
-- nuevo con este mismo contrato) — nunca se achica salvo que la función se
-- elimine.
--
-- Por qué ADEMÁS el chequeo (4) (cuenta-corriente-party-guard, 2026-08-23):
-- los chequeos (1) y (2) miran triggers y `anon`. Una función NO-trigger
-- ejecutable por `authenticated` no caía en ningún radar — punto ciego
-- estructural, no descuido puntual. Lo aprovechó _pay_register_party_charge,
-- que recibe el account_id COMO PARÁMETRO (no lo resuelve de la sesión ni
-- valida is_account_writer): con GRANT a authenticated era una primitiva de
-- escritura cross-tenant invocable desde PostgREST contra cualquier tenant.
-- MECANISMO que lo produjo: el "patrón uniforme" REVOKE+GRANT de
-- 20261001000001 (L137 y L1914) —pensado para el gotcha de ALTER DEFAULT
-- PRIVILEGES en DROP+CREATE— se aplicó en piloto automático a helpers
-- internos que nunca tuvieron GRANT. _journal_post_from_event nació con
-- REVOKE (20260803000001 L517) y así lo perdió. El chequeo (3) sostiene por
-- nombre a esos dos; el (4) es la red que impide que vuelva a pasar con
-- CUALQUIER helper interno.
--
-- Por convención de NOMBRE y no "todas las SECURITY DEFINER": hay ~76 `rpc_*`
-- que legítimamente necesitan EXECUTE para authenticated (son la API).
-- Gatearlas todas produciría una allowlist inmantenible que nadie leería — y
-- una allowlist que nadie lee es un gate apagado. El prefijo `_` ya es la
-- convención del proyecto para "helper intra-transacción" y `c28_`/`c29_`/
-- `c30_` la de los helpers de fase.
--
-- GOTCHA prod ≠ local (#432, post-merge de asiento-venta-formulario): el
-- proyecto hospedado concede EXECUTE a `anon`/`authenticated` **directo**, no
-- vía el pseudo-rol `PUBLIC`. Un `REVOKE ... FROM PUBLIC` que se ve limpio en
-- el stack local puede estar abierto en prod, y este gate corre contra local:
-- todo REVOKE de una migración debe nombrar la lista completa
-- `FROM PUBLIC, anon, authenticated`. Caso real medido el 2026-08-23:
-- c30_get_or_create_customer_account/supplier_account eran anon-executable EN
-- PROD y no lo eran en local.
--
-- Por qué ADEMÁS el chequeo (5) (tenancy-guard-caja-outbox h2, hotfix
-- 2026-08-24): los chequeos (3) y (4) sostienen helpers de nombre INTERNO. El
-- chequeo (4) excluye `rpc_*` **a propósito** (hay ~76 `rpc_*` SECURITY
-- DEFINER que legítimamente necesitan EXECUTE para authenticated: son la
-- API), y el hueco h2 vivía justamente en dos `rpc_*` — o sea que **el gate
-- vigente no lo habría atrapado**. rpc_process_outbox_batch(integer) y
-- rpc_mark_event_processed(uuid) son SECURITY DEFINER, recorren
-- `public.events` de TODOS los tenants sin filtro (es la razón de ser de un
-- relay) y tenían GRANT a authenticated desde
-- 20260718000001_c25_events_outbox_reconcile.sql (L172/L203): cualquier
-- usuario logueado leía por PostgREST el payload completo de los eventos
-- ajenos y podía marcarlos processed_at, con lo cual el despachador real
-- nunca posteaba su asiento contable. Las cerró
-- 20261012000001_revoke_outbox_cross_tenant.sql.
--
-- Por qué la lista es de LEER/ACTUALIZAR y no de INSERTAR: los productores que
-- sólo hacen `INSERT INTO public.events` son decenas
-- (rpc_create_sale_operation_v2, rpc_close_cash_session, …) y insertar un
-- evento propio no permite leer ni cerrar los de nadie más. Incluirlos
-- convertiría una lista de 4 entradas en una de decenas, que es la allowlist
-- inmantenible que este gate evita.
--
-- Por qué NO se intentó el chequeo tentador —"toda RPC SECURITY DEFINER que
-- lea una tabla con `account_id` sin filtrar por tenant"—: no es implementable
-- con honestidad por análisis de texto. Distinguir "menciona account_id" de
-- "FILTRA por account_id" exige analizar el árbol de la consulta, no el cuerpo
-- como string; un gate que busca la subcadena daría verde a una función que la
-- nombra en un INSERT y nunca la usa en un WHERE. Falsa cobertura es peor que
-- ninguna. El outbox sí es gateable así porque es la única tabla que un relay
-- tiene que recorrer entera cross-account por diseño, y eso hace que el
-- conjunto sea chico, estable y auditable a mano (hoy: exactamente 4, mismas 4
-- en prod y en local, medido el 2026-08-24).
--
-- Lo que el (5) NO puede hacer, dicho en voz alta: detecta que alguien expuso
-- una función que recorre el outbox; no detecta una consulta cross-tenant
-- nueva contra otra tabla. Para eso la red es la revisión y el requirement de
-- `account-tenancy`. Su detector es un análisis de TEXTO sobre `prosrc`
-- —obligado, porque plpgsql no registra dependencias resolubles por
-- pg_depend—, y su robustez está documentada paso a paso en el comentario del
-- propio chequeo (5a): comentarios fuera, productores restados, identificador
-- buscado como palabra completa sin anclar a la cláusula. Los cuatro vectores
-- de evasión que la primera versión dejaba pasar y el falso positivo que
-- producía están enumerados ahí, cada uno reproducido.
--
-- Mantenimiento de v_cross_tenant_event_fns: la lista SÓLO CRECE. Toda función
-- que lea o actualice `public.events` tiene que estar enumerada con su
-- veredicto; agregar una entrada exige justificar en el PR por qué. Una
-- entrada marcada como expuesta va además en v_cross_tenant_event_exposed_ok,
-- con la justificación al lado.
--
-- Mantenimiento de las allowlists: ACHICARLAS (por revokes de lotes futuros) es
-- siempre válido — la entrada sobrante no falla. AGREGAR una entrada requiere
-- justificar en el PR por qué esa función necesita EXECUTE para anon
-- (caso de uso pre-login real) o para authenticated (chequeo 4). El chequeo
-- (3) no tiene allowlist: no se le agregan excepciones, sólo entradas.
-- Estado post-lote-5a (20260826000001): en (2) quedan
-- SOLO los 4 helpers de RLS (5 firmas) — NUNCA revocar: las policies los
-- ejecutan como el rol consultante; revocarlos rompe todas las queries de las
-- tablas que los usan. Son la línea base aceptada por diseño del advisor 0028.

DO $$
DECLARE
  v_offenders text;
  v_allowlist CONSTANT text[] := ARRAY[
    -- Helpers de RLS — NUNCA revocar
    'public.current_account_ids()',
    'public.get_account_ids_for_user(p_user_id uuid)',
    'public.is_account_writer(p_account_id uuid)',
    'public.is_admin()',
    'public.is_admin(uid uuid)'
  ];
  v_internal_only_fns CONSTANT text[] := ARRAY[
    -- Helpers "solo-DEFINER" — NUNCA anon/authenticated (ver comentario de
    -- cabecera, hotfix 2026-08-23)
    'public._pay_register_party_charge(uuid, text, uuid, numeric, uuid, uuid)',
    'public._journal_post_from_event(events)',
    'public._pay_reverse_party_charge(uuid, text, uuid, numeric, uuid, uuid)'
  ];
  -- Allowlist del chequeo (4) — helpers internos que HOY siguen expuestos a
  -- `authenticated`. Cada entrada necesita su justificación.
  v_internal_allowlist CONSTANT text[] := ARRAY[
    -- _c29_confirm_order_core: expuesto. Lee el account_id de la propia
    -- sales_order (no lo recibe por parámetro) y aplica is_account_writer
    -- sobre ÉL, así que un authenticated de otro tenant no puede confirmar una
    -- orden ajena.
    -- CORRECCIÓN (2026-08-23): una versión previa de este comentario decía que
    -- "NO es una primitiva cross-tenant". SÍ LO ES, por otra puerta: acepta un
    -- p_cash_session_id de OTRO tenant y lo pasa tal cual a
    -- c28_register_cash_movement, que sólo valida status='open' y sucursal
    -- activa — no valida tenencia. Resultado: ingreso fantasma en el arqueo de
    -- la víctima (reproducido en local).
    -- Aun así la entrada en la allowlist SIGUE SIENDO LA DECISIÓN CORRECTA, por
    -- un motivo distinto del que decía antes: el hueco es alcanzable igual
    -- desde sus wrappers PÚBLICOS rpc_quick_sale y rpc_confirm_sales_order, que
    -- son rpc_* y por lo tanto quedan fuera del filtro de nombre de este
    -- chequeo. Revocar el helper no arregla nada y sí arriesga el POS. El fix
    -- real es el guard de tenencia sobre p_cash_session_id, registrado como
    -- candidato en cuenta-corriente-party-guard (design.md, Post-apply h1) para
    -- que el PO decida change propio o hotfix.
    -- (cuenta-corriente-party-guard OQ-3 — revoke en un change propio.)
    'public._c29_confirm_order_core(p_idempotency_key text, p_sales_order_id uuid, p_payment_method text, p_cash_session_id uuid, p_comprobante_type text, p_point_of_sale_id uuid, p_canal text, p_payment_method_id uuid, p_bank_account_id uuid)'
    -- NO agregar acá _pay_register_party_charge ni _journal_post_from_event:
    -- los revoca 20261010000001_revoke_internal_money_helpers.sql (hotfix
    -- #454) y además los sostiene el chequeo (3), que NO tiene allowlist. Si
    -- alguno reaparece tienen que fallar los DOS chequeos — es exactamente su
    -- razón de ser; una excepción acá sólo apagaría el (4) y dejaría gritando
    -- solo al (3).
    -- ORDEN EN CI: en KPI_Validation.yml los dos últimos eslabones de la
    -- cadena de reapply son, en este orden,
    -- 20261010000001_revoke_internal_money_helpers.sql (revoca esos dos
    -- helpers) y 20261011000001_cuenta_corriente_party_guard.sql (revoca los
    -- c30_get_or_create_* y VERIFICA que los dos de arriba sigan cerrados).
    -- Los dos van DESPUÉS de 20261001000001 y 20261004000001, que re-otorgan
    -- el GRANT a authenticated con su bloque REVOKE+GRANT "de plantilla": un
    -- eslabón mal ordenado hace fallar (3) y (4) en CI aunque las migraciones
    -- estén bien.
    -- c28_register_cash_movement NO entra: no es SECURITY DEFINER (verificado
    -- en prod y en local el 2026-08-23; el design.md lo daba por offender).
  ];
  -- ── Chequeo (5) — funciones que RECORREN el outbox ──────────────────────
  -- Enumeración COMPLETA de las funciones SECURITY DEFINER que leen
  -- (`FROM public.events`) o actualizan (`UPDATE public.events`) el outbox.
  -- Cada entrada lleva su veredicto. Lista cerrada que sólo crece: una función
  -- nueva que recorra el outbox y no esté acá FALLA el pipeline.
  v_cross_tenant_event_fns CONSTANT text[] := ARRAY[
    -- expuesta: NO — modelo correcto. Es el ÚNICO despachador: corre los 4
    -- consumers (AuditLog, EmailNotification, JournalEntry, Notification) y
    -- recién entonces marca processed_at. Lo invoca el pg_cron job
    -- `relay-process-outbox` como `postgres` (owner) y el disparador manual
    -- POST /outbox/process-pending por el camino de servicio con
    -- require_platform_admin. Nunca necesitó GRANT a authenticated.
    'public.rpc_process_outbox_dispatch(p_batch_limit integer)',
    -- expuesta: NO — la cerró 20261012000001_revoke_outbox_cross_tenant.sql.
    -- Devolvía el batch de eventos pendientes de TODOS los tenants con el
    -- payload completo, sin filtro y sin necesidad de conocer ningún UUID.
    'public.rpc_process_outbox_batch(p_batch_limit integer)',
    -- expuesta: NO — ídem. UPDATE events SET processed_at WHERE id = $1, sin
    -- filtro: cerrar un evento ajeno hace que su asiento no se postee nunca.
    'public.rpc_mark_event_processed(p_event_id uuid)',
    -- expuesta: SÍ, y es LEGÍTIMO (ver v_cross_tenant_event_exposed_ok).
    'public.rpc_atomic_update_sale_operation(p_sale_ids uuid[], p_client_id uuid, p_date date, p_currency text, p_items jsonb, p_payment_method_id uuid, p_payment_method_provided boolean, p_branch_id uuid, p_branch_provided boolean, p_canal text, p_canal_provided boolean)'
  ];
  -- Subconjunto del anterior que SÍ puede estar expuesto a `authenticated`.
  -- Una entrada acá es una excepción con nombre y apellido, no una categoría.
  v_cross_tenant_event_exposed_ok CONSTANT text[] := ARRAY[
    -- rpc_atomic_update_sale_operation: es la RPC de EDICIÓN de una venta, o
    -- sea API pública real. Toca `public.events` para hacer el reemplazo
    -- IN-PLACE del evento pendiente de esa misma operación (lo introdujo
    -- asiento-venta-formulario: editar antes de que el relay procese colapsa
    -- en el mismo evento en vez de emitir uno nuevo). Su acceso al outbox está
    -- acotado a los eventos de la operación que la propia RPC ya validó por
    -- tenant antes de tocar nada — no recorre el outbox completo ni acepta un
    -- event_id por parámetro, que es la diferencia con las dos de arriba.
    'public.rpc_atomic_update_sale_operation(p_sale_ids uuid[], p_client_id uuid, p_date date, p_currency text, p_items jsonb, p_payment_method_id uuid, p_payment_method_provided boolean, p_branch_id uuid, p_branch_provided boolean, p_canal text, p_canal_provided boolean)'
  ];
BEGIN
  -- Entorno sin roles de Supabase (p.ej. postgres pelado): no hay nada que gatear
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    RAISE NOTICE 'ACL GATE: rol anon no existe en este entorno — gate omitido';
    RETURN;
  END IF;

  -- ── (1) Funciones trigger SECURITY DEFINER expuestas — sin allowlist ──────
  SELECT string_agg(format('public.%s(%s)', p.proname,
                           pg_get_function_identity_arguments(p.oid)), E'\n  ')
  INTO v_offenders
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.prosecdef
    AND p.prorettype = 'pg_catalog.trigger'::regtype
    AND (   has_function_privilege('anon',          p.oid, 'EXECUTE')
         OR has_function_privilege('authenticated', p.oid, 'EXECUTE'));

  IF v_offenders IS NOT NULL THEN
    RAISE EXCEPTION E'ACL GATE (1) FAILED: funciones trigger SECURITY DEFINER ejecutables por anon/authenticated (¿DROP+CREATE sin re-aplicar REVOKE?):\n  %', v_offenders;
  END IF;

  -- ── (2) SECURITY DEFINER ejecutables por anon fuera de la allowlist ───────
  SELECT string_agg(sig, E'\n  ')
  INTO v_offenders
  FROM (
    SELECT format('public.%s(%s)', p.proname,
                  pg_get_function_identity_arguments(p.oid)) AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prosecdef
      AND has_function_privilege('anon', p.oid, 'EXECUTE')
  ) s
  WHERE s.sig <> ALL (v_allowlist);

  IF v_offenders IS NOT NULL THEN
    RAISE EXCEPTION E'ACL GATE (2) FAILED: funciones SECURITY DEFINER ejecutables por anon fuera de la allowlist (si es intencional, justificar y agregar a supabase/tests/test_function_acl_gate.sql; si no, REVOKE EXECUTE ... FROM PUBLIC, anon en la migración que la recrea):\n  %', v_offenders;
  END IF;

  -- ── (3) Helpers "solo-DEFINER" ejecutables por anon/authenticated — sin
  --       excepciones, sin allowlist (ver v_internal_only_fns arriba) ───────
  SELECT string_agg(sig, E'\n  ')
  INTO v_offenders
  FROM (
    SELECT s.sig, to_regprocedure(s.sig) AS oid
    FROM unnest(v_internal_only_fns) AS s(sig)
  ) f
  WHERE f.oid IS NOT NULL  -- drift-tolerante: la función no existe en este entorno
    AND (   has_function_privilege('anon',          f.oid, 'EXECUTE')
         OR has_function_privilege('authenticated', f.oid, 'EXECUTE'));

  IF v_offenders IS NOT NULL THEN
    RAISE EXCEPTION E'ACL GATE (3) FAILED: helpers "solo-DEFINER" ejecutables por anon/authenticated (¿perdieron su REVOKE en un CREATE OR REPLACE posterior? — REVOKE ALL ... FROM PUBLIC, anon, authenticated en la migración que los recrea):\n  %', v_offenders;
  END IF;

  -- ── (4) SECURITY DEFINER de nombre INTERNO ejecutables por authenticated ──
  -- Se excluyen las funciones trigger: ya las cubre (1) sin allowlist.
  SELECT string_agg(sig, E'\n  ')
  INTO v_offenders
  FROM (
    SELECT format('public.%s(%s)', p.proname,
                  pg_get_function_identity_arguments(p.oid)) AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prosecdef
      AND p.prorettype <> 'pg_catalog.trigger'::regtype
      AND (   p.proname LIKE '\_%'
           OR p.proname LIKE 'c28\_%'
           OR p.proname LIKE 'c29\_%'
           OR p.proname LIKE 'c30\_%')
      AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
  ) s
  WHERE s.sig <> ALL (v_internal_allowlist);

  IF v_offenders IS NOT NULL THEN
    RAISE EXCEPTION E'ACL GATE (4) FAILED: helpers internos SECURITY DEFINER ejecutables por authenticated fuera de la allowlist. Un helper que recibe el account_id POR PARÁMETRO y no valida is_account_writer es, expuesto así, una primitiva de escritura cross-tenant vía PostgREST. Si el GRANT vino del bloque REVOKE+GRANT del "patrón uniforme", sacalo: los helpers internos llevan `REVOKE ALL ... FROM PUBLIC, anon, authenticated` SIN GRANT. Si es intencional, justificar en el PR y agregar a v_internal_allowlist en supabase/tests/test_function_acl_gate.sql:\n  %', v_offenders;
  END IF;

  -- ── (5a) Funciones que recorren el outbox y NO están enumeradas ───────────
  -- El criterio es LEER o ACTUALIZAR, nunca INSERTAR (ver cabecera).
  --
  -- El detector NO ancla la referencia a una cláusula (`FROM`/`JOIN`/`UPDATE`).
  -- La primera versión de este chequeo sí lo hacía —
  -- `(FROM|JOIN)\s+(public\.)?events\M` / `UPDATE\s+(public\.)?events\M`— y era
  -- evadible: `FROM public.sales s, public.events e` (comma-join),
  -- `FROM public."events"` (identificador citado), `UPDATE ONLY public.events`
  -- y `EXECUTE format('UPDATE %I.events ...')` pasaban los CUATRO en verde
  -- siendo SECURITY DEFINER, con GRANT a authenticated y sin estar enumeradas
  -- (reproducido en local el 2026-08-24). Ahora, en tres pasos:
  --
  --   1. Se le quitan al cuerpo los COMENTARIOS (`--` de línea y bloques
  --      `/* */`). `prosrc` es el fuente CRUDO: una función que sólo nombra el
  --      outbox en un comentario hacía fallar el gate — falso positivo también
  --      reproducido, y el mismo gotcha que ya mordió al gate de table_refs.
  --   2. Se le quitan los `INSERT INTO [ONLY] [public.]events`: los productores
  --      son decenas y emitir un evento propio no permite leer ni cerrar los de
  --      nadie (ver cabecera). La resta es por OCURRENCIA, no por función, así
  --      que un `INSERT INTO events (...) SELECT ... FROM public.events` sigue
  --      cayendo en la red por su `FROM`. Un INSERT por SQL dinámico
  --      (`format('INSERT INTO %I.events ...')`) NO se resta y por lo tanto se
  --      reporta: es la dirección correcta del error — revisarlo a mano y
  --      enumerarlo cuesta una línea; no verlo cuesta el outbox.
  --   3. Sobre lo que queda se busca el identificador como PALABRA COMPLETA,
  --      sin exigir de qué cláusula cuelga. `\m`/`\M` (inicio/fin de palabra)
  --      son lo único que sobrevive del patrón viejo y siguen haciendo la misma
  --      falta: sin ellos `analytics_events` o `events_archive` matchearían por
  --      prefijo/sufijo. Con ellos matchean los seis: `events`,
  --      `public.events`, `"events"`, `"public"."events"`, `ONLY public.events`
  --      y el `%I.events` de un format() — en todos, el identificador aparece
  --      rodeado de caracteres que no son de palabra.
  --
  -- De los comentarios se quitan SOLO los de LINEA COMPLETA y los bloques que
  -- no cruzan un literal. La version anterior borraba `--` y `/*` en cualquier
  -- posicion del fuente crudo, sin saber que es un literal: un `--` DENTRO de
  -- una comilla simple se llevaba puesto el resto de la linea --la referencia
  -- al outbox incluida-- y reabria justamente la evasion que este chequeo
  -- existe para cerrar. Reproducido el 2026-08-24 con una sonda que escondia
  -- su `FROM public.events` detras de un literal con dos guiones.
  --
  -- Lo que a propósito NO se le quita al cuerpo son los LITERALES de texto: el
  -- `EXECUTE format('UPDATE %I.events ...')` es justamente uno de los vectores
  -- a atrapar y vive dentro de un literal. El costo es que una función que diga
  -- la palabra `events` en un RAISE entra en la lista; eso es una entrada de
  -- mantenimiento, no un agujero.
  --
  -- Por qué el análisis de texto NO se REEMPLAZA por las dependencias reales
  -- (pg_depend sobre 'public.events'::regclass), que sería lo canónico y a
  -- prueba de sintaxis: plpgsql es OPACO para el planner y no registra las
  -- tablas que consulta el cuerpo. Medido en local el 2026-08-24: esa query
  -- devuelve CERO filas habiendo cuatro funciones plpgsql que recorren el
  -- outbox. PERO la ceguera es MUTUA y cae en lugares distintos: un cuerpo SQL
  -- estándar (`BEGIN ATOMIC`, PG14+) no guarda texto en prosrc y es invisible
  -- para el regex, mientras pg_depend sí lo ve. Por eso el chequeo usa los DOS
  -- en OR (ramas (3) y (4)): ninguno de los dos alcanza solo.
  SELECT string_agg(sig, E'\n  ')
  INTO v_offenders
  FROM (
    SELECT format('public.%s(%s)', p.proname,
                  pg_get_function_identity_arguments(p.oid)) AS sig,
           -- (1) comentarios fuera → (2) productores fuera
           regexp_replace(
             regexp_replace(
               regexp_replace(p.prosrc, '/\*[^'']*?\*/', ' ', 'g'),
               '^[ \t]*--[^\n]*', ' ', 'gn'),
             '\mINSERT\s+INTO\s+(ONLY\s+)?("?public"?\s*\.\s*)?"?events"?\M', ' ', 'gi'
           ) AS body,
           p.oid AS oid
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prosecdef
  ) s
  WHERE (
          s.body ~* '\mevents\M'        -- (3) el identificador, como palabra
          -- (4) red complementaria para los cuerpos que NO son texto: una
          -- funcion `LANGUAGE sql ... BEGIN ATOMIC ... END` (PG14+) guarda
          -- su arbol en prosqlbody y deja prosrc VACIO, asi que el regex de
          -- (3) es ciego. Justo ahi pg_depend SI registra la dependencia.
          OR EXISTS (
               SELECT 1
               FROM   pg_depend d
               WHERE  d.classid    = 'pg_proc'::regclass
                 AND  d.objid      = s.oid
                 AND  d.refclassid = 'pg_class'::regclass
                 AND  d.refobjid   = 'public.events'::regclass
             )
        )
    AND s.sig  <> ALL (v_cross_tenant_event_fns);

  IF v_offenders IS NOT NULL THEN
    RAISE EXCEPTION E'ACL GATE (5a) FAILED: función(es) SECURITY DEFINER que leen o actualizan public.events sin estar enumeradas en v_cross_tenant_event_fns. El outbox es la única tabla que se recorre cross-account por diseño, así que toda función con ese privilegio se enumera A MANO con su veredicto (expuesta sí/no + justificación) en supabase/tests/test_function_acl_gate.sql. Si la función es un relay interno: REVOKE ALL ... FROM PUBLIC, anon, authenticated y agregala como "expuesta: NO". Si es API pública que toca el outbox de una operación ya validada por tenant, agregala TAMBIÉN a v_cross_tenant_event_exposed_ok con la justificación:\n  %', v_offenders;
  END IF;

  -- ── (5b) Enumeradas como NO expuestas pero ejecutables por anon/auth ──────
  -- Se resuelve el OID por pg_proc, NO por to_regprocedure: las firmas de esta
  -- lista llevan NOMBRES de parámetro (mismo formato que el chequeo (4), para
  -- que la lista se lea igual que el output del error) y to_regprocedure sólo
  -- acepta tipos. Buscar en pg_proc es además drift-tolerante por
  -- construcción: una función ausente en este entorno simplemente no aparece.
  SELECT string_agg(s.sig, E'\n  ')
  INTO v_offenders
  FROM (
    SELECT format('public.%s(%s)', p.proname,
                  pg_get_function_identity_arguments(p.oid)) AS sig,
           p.oid
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prosecdef
  ) s
  WHERE s.sig =  ANY (v_cross_tenant_event_fns)
    AND s.sig <> ALL (v_cross_tenant_event_exposed_ok)
    AND (   has_function_privilege('anon',          s.oid, 'EXECUTE')
         OR has_function_privilege('authenticated', s.oid, 'EXECUTE'));

  IF v_offenders IS NOT NULL THEN
    RAISE EXCEPTION E'ACL GATE (5b) FAILED: función(es) que recorren el outbox de TODOS los tenants y quedaron ejecutables vía PostgREST. Con EXECUTE para authenticated, cualquier usuario logueado lee el payload de los eventos ajenos y puede marcarlos processed_at — el despachador real nunca postea su asiento contable. Aplicar REVOKE ALL ... FROM PUBLIC, anon, authenticated (gotcha #432: nombrar los tres roles) en la migración que las recrea; ver 20261012000001_revoke_outbox_cross_tenant.sql:\n  %', v_offenders;
  END IF;

  RAISE NOTICE 'ACL GATE OK: sin triggers SECURITY DEFINER expuestos; anon-executable dentro de la allowlist (% firmas permitidas); % helpers solo-DEFINER intactos; helpers internos authenticated-executable dentro de su allowlist (% firmas permitidas); % funciones que recorren el outbox enumeradas, de las cuales % con exposición justificada', array_length(v_allowlist, 1), array_length(v_internal_only_fns, 1), array_length(v_internal_allowlist, 1), array_length(v_cross_tenant_event_fns, 1), array_length(v_cross_tenant_event_exposed_ok, 1);
END $$;
