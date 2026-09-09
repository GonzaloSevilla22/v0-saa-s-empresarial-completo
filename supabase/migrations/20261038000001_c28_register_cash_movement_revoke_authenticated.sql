-- ═══════════════════════════════════════════════════════════════════════════
-- c28_register_cash_movement_revoke_authenticated
-- Candidato S4 de CLAUDE.md §"Candidatos para el próximo /opsx:propose"
-- (heredado de tenancy-guard-caja-outbox, OQ-4 de su design.md — ver
-- openspec/changes/archive/2026-08-24-tenancy-guard-caja-outbox/design.md).
-- ═══════════════════════════════════════════════════════════════════════════
--
-- HALLAZGO: `c28_register_cash_movement` es el punto de paso obligado de TODA
-- escritura en caja (RN-98, ledger append-only) y es SECURITY INVOKER puro —
-- no exige `is_account_writer` ni ningún rol de escritura propio, sólo el
-- backstop de MEMBRESÍA que le puso `tenancy-guard-caja-outbox` (P0401,
-- 20261013000001). Esa es la autorización correcta para sus callers legítimos
-- (delegan la validación de rol de escritura en el caller, D1 iii: exigirla
-- acá endurecería en silencio el camino del formulario) pero es exactamente
-- la autorización EQUIVOCADA para un rol de aplicación que la invoque directo
-- por PostgREST: cualquier `authenticated` que sea SIMPLE MIEMBRO de su propia
-- cuenta (sin rol de escritura) podría escribir un movimiento de caja
-- arbitrario en la caja de su propia cuenta sin pasar por ninguna de las
-- validaciones de negocio (sesión abierta se revalida, pero NO cash_kind,
-- NO fecha de hoy, NO invariante de sucursal — esos viven en el caller).
-- Sigue con GRANT EXECUTE explícito a `authenticated` desde su creación
-- (20261006000001_banco_caja_historial_ajustes.sql L266-267, reafirmado por
-- 20261013000001_tenancy_guard_caja_sesion.sql L846-847) — nunca se revocó,
-- a diferencia de `_pay_register_party_charge` / `_journal_post_from_event`
-- (hotfix 20261010000001) y de `c30_get_or_create_*`
-- (20261011000001_cuenta_corriente_party_guard.sql), que sí son
-- SECURITY DEFINER y por eso entraron al chequeo (3)/(4) del gate de ACLs.
-- `c28_register_cash_movement` NO es SECURITY DEFINER (verificado en prod y
-- en local el 2026-08-23, y de nuevo hoy 2026-09-09 — ver abajo), así que
-- ningún chequeo de `test_function_acl_gate.sql` lo cubre: es el único hueco
-- de esa familia que sigue abierto.
--
-- VERIFICACIÓN DE INTEGRIDAD DE FUNCIÓN (regla dura del proyecto) — cuerpo
-- VIVO de prod (gxdhpxvdjjkmxhdkkwyb) medido hoy 2026-09-09:
--   firma:      (p_session_id uuid, p_amount numeric, p_type text,
--                p_reference_id uuid, p_description text)
--   prosecdef:  false (SECURITY INVOKER)
--   proacl:     {postgres=X/postgres, service_role=X/postgres,
--                authenticated=X/postgres}   -- SIN anon, CON authenticated
--   md5(pg_get_functiondef) sin \r (CRLF del checkout Windows — ver
--     `project_pg_functiondef_crlf_deno_gotchas.md`): 1b0692ad5ba614f267389b335e4d366a
--     (4413 bytes)
-- Reproducido byte-a-byte en esta base local reseteada desde los mismos
-- archivos de migración (última: 20261013000001_tenancy_guard_caja_sesion.sql
-- L730-830, sin ningún CREATE OR REPLACE posterior que la vuelva a tocar):
--   md5(replace(pg_get_functiondef(...), chr(13), '')) = 1b0692ad5ba614f267389b335e4d366a
--   length(...) = 4413
--   prosecdef = false
--   proacl = {postgres=X/postgres, service_role=X/postgres, authenticated=X/postgres}
-- Coincide exactamente con el hallazgo dado — esta migración NO toca el
-- cuerpo ni la firma, sólo el ACL. Sin `CREATE OR REPLACE`.
--
-- AUDITORÍA DE CALLERS (repetida hoy, 2026-09-09, sobre este worktree):
--   grep -rn "c28_register_cash_movement" frontend/app frontend/components \
--     frontend/hooks frontend/lib backend/ supabase/functions
--   → frontend/lib/database.types.ts:4968  (tipos generados, no una llamada)
--   → backend/tests/test_c28_cash_session.py:649,651,659,666 (comentarios de
--     test, ningún `.rpc(` real)
--   → supabase/functions: cero coincidencias
-- CERO callers reales vía PostgREST/supabase-js/httpx. Los dos callers SQL
-- vivos son SECURITY DEFINER, owned by `postgres`
-- (`_c29_confirm_order_core`, el core del POS, y `rpc_register_cash_movement`,
-- la API pública de caja): ninguno de los dos depende del EXECUTE de
-- `authenticated` sobre ESTE helper — dentro de una cadena SECURITY DEFINER
-- el llamado a una función SECURITY INVOKER corre con los privilegios del
-- DUEÑO de la función que la invoca (`postgres`), no con el rol externo que
-- originó la petición, y `postgres` conserva EXECUTE implícito por ser el
-- dueño de `c28_register_cash_movement` (no lo toca ningún REVOKE FROM
-- PUBLIC/anon/authenticated). Candados de no-regresión completos —incluido
-- el camino REAL de producción, con `SET LOCAL ROLE authenticated`— en la
-- sección 2.6 (2.6a-2.6e) de
-- supabase/tests/test_tenancy_guard_caja_outbox.sql.
--
-- DISEÑO: molde de 20261010000001_revoke_internal_money_helpers.sql
-- (`to_regprocedure` + REVOKE ALL FROM PUBLIC, anon, authenticated + gate
-- negativo/positivo inline). NO se toca `prosecdef` ni el cuerpo: sigue
-- siendo SECURITY INVOKER a propósito — no se convierte en DEFINER, porque
-- sus dos callers legítimos son DEFINER y ya le prestan su contexto; convertir
-- este helper en DEFINER lo volvería una primitiva cross-tenant nueva si
-- alguna vez alguien le agrega un caller SECURITY INVOKER. El backstop de
-- MEMBRESÍA que ya tiene adentro (P0401, 20261013000001) NO se toca ni se
-- duplica: esta migración es una capa ANTERIOR (ACL), no un reemplazo de esa
-- capa (autorización dentro del cuerpo) — las dos quedan probadas por
-- separado en el gate (2.5 sigue cubriendo la capa interna; 2.6 esta capa).
--
-- Alcance: SOLO revoca EXECUTE de `authenticated` (y reafirma que `anon`
-- tampoco lo tiene — ya no lo tenía). Sin DROP, sin cambio de cuerpo/firma/
-- owner/prosecdef.
--
-- Gate permanente: supabase/tests/test_tenancy_guard_caja_outbox.sql sección
-- 2.6 (extendida en el mismo PR que esta migración) — RED antes de esta
-- migración (el helper insertaba bajo `authenticated` contra la propia
-- sesión), GREEN después (42501 permission denied). El chequeo (3)/(4) de
-- test_function_acl_gate.sql NO cubre esta ACL: ambos filtran por
-- `p.prosecdef` y este helper no lo es — queda documentado ahí mismo
-- (L216-217) y en el candado de esta migración.
--
-- Idempotente: REVOKE sin objeto no falla; `to_regprocedure` es
-- drift-tolerante si la función no existe en el entorno (no debería ocurrir:
-- es DDL histórico, pero sigue el mismo patrón que el resto de los REVOKEs
-- de esta familia).
-- ═══════════════════════════════════════════════════════════════════════════

DO $$
DECLARE
  v_fn CONSTANT text := 'public.c28_register_cash_movement(uuid, numeric, text, uuid, text)';
  v_oid regprocedure;
BEGIN
  v_oid := to_regprocedure(v_fn);

  IF v_oid IS NULL THEN
    RAISE NOTICE 'c28_register_cash_movement_revoke_authenticated: % no existe en este entorno — nada que revocar (drift-tolerante).', v_fn;
    RETURN;
  END IF;

  -- Defensa contra endurecer por accidente una función que se haya convertido
  -- en DEFINER entretanto (cambiaría el análisis de "postgres conserva
  -- EXECUTE implícito" que justifica este REVOKE para sus dos callers).
  IF (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN
    RAISE EXCEPTION 'c28_register_cash_movement_revoke_authenticated: % es SECURITY DEFINER — no coincide con el hallazgo verificado (prosecdef=false). Abortando para no aplicar un REVOKE sobre una premisa que cambió.', v_fn;
  END IF;

  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', v_oid::text);

  -- ── GATE NEG: sin EXECUTE para anon ni authenticated ──────────────────────
  IF has_function_privilege('anon', v_oid, 'EXECUTE')
     OR has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE NEG FAILED: % sigue expuesta a un rol de aplicación tras el REVOKE.', v_fn;
  END IF;

  -- ── GATE POS: postgres y service_role conservan EXECUTE (dueño + cadena
  --    DEFINER de sus dos callers sigue viva) ───────────────────────────────
  IF NOT has_function_privilege('postgres', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE POS FAILED: postgres (dueño) quedó sin EXECUTE en % — esto rompería _c29_confirm_order_core y rpc_register_cash_movement.', v_fn;
  END IF;
  IF NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE POS FAILED: service_role quedó sin EXECUTE en %.', v_fn;
  END IF;

  RAISE NOTICE 'c28_register_cash_movement_revoke_authenticated OK: % ya no es invocable por anon/authenticated; postgres/service_role conservan EXECUTE.', v_fn;
END $$;
