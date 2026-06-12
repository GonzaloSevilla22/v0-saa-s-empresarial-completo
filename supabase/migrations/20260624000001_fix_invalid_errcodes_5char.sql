-- =============================================================================
-- MIGRATION: 20260624000001_fix_invalid_errcodes_5char.sql
-- SCOPE:     Normalizar ERRCODEs custom inválidos de 4 caracteres → 5 (P04xx)
--
-- PROBLEMA:
--   Varios RPCs usan `USING ERRCODE = 'P400'|'P403'|'P404'|'P409'|'P422'`.
--   Un SQLSTATE custom debe tener EXACTAMENTE 5 caracteres: al ejecutarse esos
--   RAISE, Postgres lanza `42704 unrecognized exception condition` y el mensaje
--   original (ej. "Insufficient stock for product …") se pierde. La operación
--   aborta igual (atomicidad intacta), pero el cliente recibe un error confuso
--   y los handlers del frontend que matchean por mensaje nunca ven el texto.
--
-- FIX:
--   Reemplazo mecánico en las funciones afectadas (13 al momento de escribir):
--     'P400' → 'P0400'   'P403' → 'P0403'   'P404' → 'P0404'
--     'P409' → 'P0409'   'P422' → 'P0422'
--   Mapeo consistente con la convención ya vigente en el proyecto: branches e
--   invitaciones usan 'P0401'/'P0403'/'P0404'/'P0409' (5 chars, válidos).
--
-- MÉTODO:
--   Reescritura DINÁMICA: por cada función de public/community cuyo prosrc
--   contenga un código inválido, se toma `pg_get_functiondef()` (fuente de
--   verdad en prod), se aplica el regexp_replace y se re-ejecuta el CREATE OR
--   REPLACE. Esto evita copiar ~50k caracteres de definiciones a mano (riesgo
--   de desincronización) y es idempotente. CREATE OR REPLACE preserva ACLs,
--   owner y atributos (SECURITY DEFINER, search_path).
--   Verificación final: la migración ABORTA si queda algún código inválido.
--
-- NOTA: el handler del backend (backend/core/errors.py) se actualiza en el
--   mismo PR para mapear P04xx/P0401 → HTTP status con el mensaje original
--   (antes devolvía 500 "Error interno" genérico para estos casos).
--
-- GOVERNANCE: MEDIUM — cambio mecánico de códigos de error, sin lógica nueva.
-- APPLY: npx supabase db push  (NUNCA MCP apply_migration)
-- ROLLBACK: re-ejecutar el mismo DO block con el replace inverso
--   (P04xx → P4xx) — no recomendado: restauraría el bug.
-- =============================================================================

DO $$
DECLARE
  r         RECORD;
  v_def     text;
  v_count   integer := 0;
  v_residue integer;
BEGIN
  FOR r IN
    SELECT p.oid, p.proname
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname IN ('public', 'community')
      AND p.prosrc ~ 'ERRCODE\s*=\s*''P(400|403|404|409|422)'''
  LOOP
    v_def := pg_get_functiondef(r.oid);
    v_def := regexp_replace(
      v_def,
      '(ERRCODE\s*=\s*'')P(400|403|404|409|422)('')',
      '\1P0\2\3',
      'g'
    );
    EXECUTE v_def;
    v_count := v_count + 1;
    RAISE NOTICE 'ERRCODE fix aplicado: %', r.proname;
  END LOOP;

  RAISE NOTICE 'Funciones reescritas: %', v_count;

  -- Gate: no debe quedar ningún código inválido de 4 caracteres
  SELECT count(*) INTO v_residue
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname IN ('public', 'community')
    AND p.prosrc ~ 'ERRCODE\s*=\s*''P(400|403|404|409|422)''';

  IF v_residue <> 0 THEN
    RAISE EXCEPTION 'ERRCODE fix INCOMPLETO: % funciones aún contienen códigos de 4 caracteres', v_residue;
  END IF;
END $$;

-- =============================================================================
-- VERIFICATION (post-push):
--   SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--   WHERE n.nspname IN ('public','community')
--     AND p.prosrc ~ 'ERRCODE\s*=\s*''P(400|403|404|409|422)''';  -- → 0 filas
--   -- Smoke: una venta con stock insuficiente debe fallar con SQLSTATE 'P0409'
--   -- y mensaje 'Insufficient stock for product …' (antes: 42704 sin mensaje).
-- =============================================================================
