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
--       diferencia de (2), acá no hay allowlist: estos helpers reciben el
--       tenant/la parte por parámetro y SOLO deben poder invocarse desde otra
--       función SECURITY DEFINER que ya validó al usuario, nunca directo vía
--       PostgREST).
--
-- Mantenimiento de la allowlist: ACHICARLA (por revokes de lotes futuros) es
-- siempre válido — la entrada sobrante no falla. AGREGAR una entrada requiere
-- justificar en el PR por qué esa función necesita EXECUTE para anon
-- (caso de uso pre-login real). Estado post-lote-5a (20260826000001): quedan
-- SOLO los 4 helpers de RLS (5 firmas) — NUNCA revocar: las policies los
-- ejecutan como el rol consultante; revocarlos rompe todas las queries de las
-- tablas que los usan. Son la línea base aceptada por diseño del advisor 0028.
--
-- v_internal_only_fns (check 3) nace en el hotfix 2026-08-23: PostgREST
-- expone por default TODA función `public` a `authenticated` (y a veces
-- `anon`) salvo REVOKE explícito, y ese REVOKE se pierde en silencio cuando
-- una migración posterior hace CREATE OR REPLACE + un REVOKE/GRANT "de
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

  RAISE NOTICE 'ACL GATE OK: sin triggers SECURITY DEFINER expuestos; anon-executable dentro de la allowlist (% firmas permitidas); % helpers solo-DEFINER intactos', array_length(v_allowlist, 1), array_length(v_internal_only_fns, 1);
END $$;
