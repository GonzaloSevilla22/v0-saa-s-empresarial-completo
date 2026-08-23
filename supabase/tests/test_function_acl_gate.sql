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
--       `authenticated` fuera de su propia allowlist.
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

  RAISE NOTICE 'ACL GATE OK: sin triggers SECURITY DEFINER expuestos; anon-executable dentro de la allowlist (% firmas permitidas); % helpers solo-DEFINER intactos; helpers internos authenticated-executable dentro de su allowlist (% firmas permitidas)', array_length(v_allowlist, 1), array_length(v_internal_only_fns, 1), array_length(v_internal_allowlist, 1);
END $$;
