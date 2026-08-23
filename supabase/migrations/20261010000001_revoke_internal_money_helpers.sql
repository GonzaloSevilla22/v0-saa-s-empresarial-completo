-- ═══════════════════════════════════════════════════════════════════════════
-- revoke-internal-money-helpers — HOTFIX CRÍTICO (orden PO 2026-08-23)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Hallazgo: _pay_register_party_charge y _journal_post_from_event son
-- SECURITY DEFINER (owner postgres), reciben el tenant/la parte por
-- PARÁMETRO, y quedaron ejecutables por `authenticated` en prod. Cualquier
-- usuario logueado puede invocarlos vía PostgREST con el account_id/
-- party_id/amount que quiera → escritura cross-tenant real (cargo de cuenta
-- corriente ajeno, o asiento contable contra otro tenant).
--
-- Verificado en prod (gxdhpxvdjjkmxhdkkwyb) 2026-08-23 antes de esta
-- migración:
--   _pay_register_party_charge(uuid,text,uuid,numeric,uuid,uuid)
--     security_definer=true, owner=postgres, anon=false, authenticated=TRUE
--   _journal_post_from_event(events)
--     security_definer=true, owner=postgres, anon=false, authenticated=TRUE
--
-- Ninguno de los dos necesita EXECUTE para `authenticated`: son helpers
-- internos, invocados SOLO desde otras funciones SECURITY DEFINER que ya
-- resolvieron y validaron al tenant. Los 5 callers vivos en prod (pg_proc.
-- prosrc + proowner, ninguno tocado por este hotfix) son SECURITY DEFINER
-- owned by postgres — la cadena DEFINER sigue ejecutando como el owner sin
-- importar qué rol invoca al wrapper, así que revocar authenticated de los
-- helpers internos no rompe ningún camino real:
--   _c29_confirm_order_core            (DEFINER, owner postgres)
--   rpc_create_purchase_operation      (DEFINER, owner postgres)
--   rpc_create_sale_operation          (DEFINER, owner postgres)
--   rpc_create_sale_operation_v2       (DEFINER, owner postgres)
--   rpc_process_outbox_dispatch        (DEFINER, owner postgres — cron-only,
--                                        pg_cron job "relay-process-outbox"
--                                        llama SELECT rpc_process_outbox_
--                                        dispatch(100), nunca el helper
--                                        directo)
-- El backend Python (asyncpg) tampoco los llama directo — solo referencia
-- sus nombres en comentarios/tests que leen el SQL de la migración, nunca
-- una query real (grep backend/repositories, backend/services 2026-08-23).
--
-- Cómo se rompió (para que no vuelva a pasar):
--   - _pay_register_party_charge: GRANT EXECUTE ... TO authenticated desde
--     su creación (20261001000001_pagos_cableados_restantes.sql L137) —
--     nunca debió llevarlo, es un helper interno nuevo, no una RPC pública.
--   - _journal_post_from_event: nació bien revocado (20260803000001 L515-
--     517: REVOKE ALL FROM PUBLIC + REVOKE EXECUTE FROM anon/authenticated),
--     pero DOS migraciones posteriores que la redefinen con CREATE OR
--     REPLACE reintrodujeron el grant al aplicar el patrón "REVOKE+GRANT"
--     uniforme de las RPCs públicas sin notar que ESTE helper no lleva GRANT:
--     20261001000001 L1914 y 20261004000001 L1778 (la migración más nueva
--     que la toca, 20261005000001_delete_guard_ledgers.sql, no reemite
--     REVOKE/GRANT — CREATE OR REPLACE conserva el ACL previo, así que el
--     grant de 20261004000001 sobrevivió hasta hoy).
--
-- Referencia del patrón correcto: _pay_reverse_party_charge
-- (20261005000001_delete_guard_ledgers.sql L186) quedó bien desde el día
-- uno — REVOKE ALL ... FROM PUBLIC, anon, authenticated en una sola línea.
-- Este hotfix iguala a los otros dos helpers a ese patrón.
--
-- Alcance: SOLO revoca EXECUTE. Sin DROP, sin cambio de cuerpo/firma/owner.
-- No implementa el change `cuenta-corriente-party-guard`
-- (openspec/changes/cuenta-corriente-party-guard/ — guards de pertenencia
-- en 3 RPCs de cuenta corriente + choke point c30_get_or_create_*), que
-- había detectado este mismo hallazgo y lo dejó como OQ-2 ("¿hotfix o
-- dentro del apply?") pendiente de decisión del PO. El PO ordenó
-- "arreglalo" el 2026-08-23: OQ-2 queda resuelta como HOTFIX (esta
-- migración), no como parte de ese apply — ver nota en design.md/tasks.md
-- de ese change.
--
-- Gate permanente: supabase/tests/test_function_acl_gate.sql check (3)
-- (v_internal_only_fns) sostiene authenticated=false/anon=false para estos
-- dos helpers y para _pay_reverse_party_charge de ahora en más — RED antes
-- de esta migración, GREEN después.
--
-- Idempotente (REVOKE sin objeto no falla; to_regprocedure es drift-
-- tolerante si la función no existe en el entorno) y con gate positivo/
-- negativo inline, mismo patrón que
-- 20260830000001_revoke_auth_internal_only_fns.sql.

DO $$
DECLARE
  v_sig text;
  v_fns CONSTANT text[] := ARRAY[
    'public._pay_register_party_charge(uuid, text, uuid, numeric, uuid, uuid)',
    'public._journal_post_from_event(events)'
  ];
BEGIN
  FOREACH v_sig IN ARRAY v_fns LOOP
    CONTINUE WHEN to_regprocedure(v_sig) IS NULL;  -- drift-tolerante
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated',
                   to_regprocedure(v_sig)::text);
  END LOOP;

  -- ── GATE NEG: sin EXECUTE para anon ni authenticated en los 2 helpers ─────
  FOREACH v_sig IN ARRAY v_fns LOOP
    CONTINUE WHEN to_regprocedure(v_sig) IS NULL;
    IF has_function_privilege('anon', to_regprocedure(v_sig), 'EXECUTE')
       OR has_function_privilege('authenticated', to_regprocedure(v_sig), 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE NEG FAILED: % sigue expuesta vía REST', v_sig;
    END IF;
  END LOOP;

  -- ── GATE POS: postgres conserva EXECUTE (la cadena DEFINER sigue viva) ────
  FOREACH v_sig IN ARRAY v_fns LOOP
    CONTINUE WHEN to_regprocedure(v_sig) IS NULL;
    IF NOT has_function_privilege('postgres', to_regprocedure(v_sig), 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE POS FAILED: postgres quedó sin EXECUTE en %', v_sig;
    END IF;
  END LOOP;
END $$;
