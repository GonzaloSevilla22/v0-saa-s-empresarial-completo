-- =============================================================================
-- MIGRATION: 20260812000001_v3_provisioning_seed.sql
-- CHANGE:    v3-provisioning-seed
--
-- QUÉ HACE (aditivo, sin BREAKING, sin DDL de schema):
--   Modelo V3 §7.5 exige que un tenant nuevo pueda vender en <5 minutos sin
--   configuración manual. Hoy `handle_new_user` NO crea sucursal ni caja: la
--   sucursal "Casa Central" nace perezosamente recién en el primer movimiento
--   de stock (c21_apply_branch_stock_delta), y `cashboxes` no tiene ninguna
--   auto-creación. Un tenant que nunca movió stock queda bloqueado para abrir
--   caja/POS.
--
--   PARTE A — Backfill idempotente de las ~29 cuentas existentes:
--     A.1 branch "Casa Central" para cuentas con CERO branches.
--     A.2 cashbox "Caja Principal" para cuentas cuya branch default no tenga
--         ninguna cashbox.
--   PARTE B — CREATE OR REPLACE FUNCTION public.handle_new_user(): base EXACTA
--     20260801000003 (última deployada — verificado que ninguna migración
--     posterior la redefine, y que coincide byte-a-byte con la definición
--     vigente en prod). Único agregado: sub-bloque de seed (branch + cashbox)
--     envuelto en BEGIN...EXCEPTION WHEN OTHERS THEN RAISE WARNING...END, de
--     forma que un fallo del seed NUNCA aborte el signup. El core (profile /
--     account / membership / emails) permanece intacto y fail-fast.
--   PARTE C — Behavior gate auto-limpiante (DO-block): anchor sintético en
--     auth.users dispara el trigger REAL, resuelve la account vía
--     account_members (nunca inserta accounts a mano), asserta branch+cashbox,
--     re-corre el seed para probar idempotencia, simula "branch sin cashbox" y
--     re-corre el backfill A.2, limpia hijo→padre por email del anchor.
--     Degrada con RAISE NOTICE si el contexto no lo permite (prod real).
--
-- Fuera de alcance (ver design.md): price_lists (tabla no existe), formas de
--   pago (solo CHECK 'cash'|'other' en sales_orders, no hay catálogo), plan de
--   cuentas (diferido a V2.6, test lo prohíbe), unidades de medida (ya
--   seedeadas globalmente vía is_system=true + RLS uom_account_select).
--
-- GOVERNANCE: MEDIO — toca el trigger de signup (handle_new_user), pero el
--   seed nuevo degrada en vez de abortar; el core de provisioning no cambia.
--
-- IDEMPOTENCIA / BOTH-WORLDS-SAFE: la integración GitHub de Supabase auto-
--   aplica migraciones al mergear a main ANTES del `db push` de Actions
--   (confirmado 2x el 2026-07-06) → esta migración puede correr más de una
--   vez. CREATE OR REPLACE para la función; ON CONFLICT DO NOTHING para el
--   branch (UNIQUE (account_id, name) existe, confirmado en prod); guard
--   NOT EXISTS para la cashbox (cashboxes NO tiene UNIQUE — no usar
--   ON CONFLICT ahí). Cero DDL de schema.
--
-- APPLY: vía CI al mergear a main (GitHub Actions: build + deploy + db push).
--   NUNCA aplicar con el MCP `apply_migration` (desincroniza el historial).
--
-- ROLLBACK: restaurar `handle_new_user` a la definición de
--   20260801000003_register_province_admin_email.sql (ese archivo ya la
--   contiene íntegra). El backfill de Parte A NO se revierte: las branches y
--   cashboxes creadas son datos legítimos e inocuos; borrarlas podría romper
--   FKs si ya tienen sesiones de caja o stock colgando.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- PARTE A — Backfill idempotente de cuentas existentes (~29 en prod)
-- Solo INSERTs aditivos, cero UPDATE/DELETE. Aislada y removible sin tocar B/C.
-- ─────────────────────────────────────────────────────────────────────────────

-- A.1 — Branch "Casa Central" para cuentas con CERO branches.
-- ON CONFLICT DO NOTHING es cinturón-y-tirantes: el NOT EXISTS ya filtra:
-- si dos ejecuciones concurrentes de esta migración corrieran a la vez, el
-- UNIQUE (account_id, name) evita el duplicado.
INSERT INTO public.branches (account_id, name, is_active, status, opened_at)
SELECT a.id, 'Casa Central', TRUE, 'active', now()
FROM   public.accounts a
WHERE  NOT EXISTS (
  SELECT 1 FROM public.branches b WHERE b.account_id = a.id
)
ON CONFLICT (account_id, name) DO NOTHING;

-- A.2 — Cashbox "Caja Principal" para cuentas cuya branch default (la más
-- antigua activa+abierta, vía c26_default_branch) no tenga ninguna cashbox.
-- cashboxes NO tiene UNIQUE → el guard NOT EXISTS es obligatorio, no cosmético.
INSERT INTO public.cashboxes (branch_id, name, currency)
SELECT public.c26_default_branch(a.id), 'Caja Principal', 'ARS'
FROM   public.accounts a
WHERE  public.c26_default_branch(a.id) IS NOT NULL
  AND  NOT EXISTS (
    SELECT 1
    FROM   public.cashboxes cb
    JOIN   public.branches  br ON br.id = cb.branch_id
    WHERE  br.account_id = a.id
  );


-- ─────────────────────────────────────────────────────────────────────────────
-- PARTE B — handle_new_user: agrega el seed eager de branch + cashbox
-- Base EXACTA: 20260801000003 (profile con province + account + membership
-- owner + 2 email_logs). ÚNICO cambio: sub-bloque de seed al final, antes del
-- RETURN, envuelto en BEGIN...EXCEPTION WHEN OTHERS THEN RAISE WARNING...END.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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
  ON CONFLICT (account_id, user_id) DO NOTHING;

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

  RETURN new;
END;
$function$;

COMMENT ON FUNCTION public.handle_new_user IS
  'v3-provisioning-seed: base 20260801000003 (profile+account+membership+emails) '
  '+ seed eager de branch "Casa Central" y cashbox "Caja Principal" (ARS) en '
  'sub-bloque EXCEPTION que degrada a WARNING sin abortar el signup. '
  'Backfill de cuentas preexistentes en Parte A de esta misma migración.';


-- ─────────────────────────────────────────────────────────────────────────────
-- PARTE C — Behavior gate auto-limpiante (RED antes de B, GREEN después).
-- Patrón establecido (20260808000001, 20260804000008, 20260809000001):
-- anchor sintético en auth.users dispara el trigger REAL; resolver la account
-- vía account_members (nunca insertar accounts a mano); limpiar hijo→padre
-- por email del anchor; accounts=0 al final. Degrada con NOTICE si el
-- contexto no lo permite (prod real sin permisos de insert en auth.users).
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_anchor_email      text := 'provisioning-seed@test.local';
  v_user_id           uuid := gen_random_uuid();
  v_account_id        uuid;
  v_branch_count      integer;
  v_branch_id         uuid;
  v_cashbox_count     integer;
  v_branch_count_2    integer;
  v_cashbox_count_2   integer;
BEGIN
  -- Anchor sintético: dispara handle_new_user (AFTER INSERT ON auth.users),
  -- que auto-crea profile+account+membership+seed. Nunca insertamos accounts
  -- a mano (lección de gates previos: dejaría un accounts huérfano que
  -- impide el DELETE FROM auth.users final por la FK owner_user_id).
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_id, 'authenticated', 'authenticated', v_anchor_email, now(), now(),
          jsonb_build_object('name', 'Gate Provisioning', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_id
  FROM   public.account_members
  WHERE  user_id = v_user_id
  ORDER  BY created_at
  LIMIT  1;

  IF v_account_id IS NULL THEN
    -- Contexto no permite el gate (p.ej. prod real sin permisos de insert en
    -- auth.users, o el trigger no corrió por algún motivo externo) — degradar,
    -- nunca abortar la migración.
    RAISE NOTICE 'GATE PROVISIONING-SEED: no se pudo resolver una account para el anchor sintético (contexto no permite el gate) — degradando sin abortar.';
    RETURN;
  END IF;

  -- Assert 1: exactamente 1 branch "Casa Central" activa para la cuenta.
  SELECT count(*) INTO v_branch_count
  FROM   public.branches
  WHERE  account_id = v_account_id
    AND  name = 'Casa Central'
    AND  is_active = TRUE
    AND  status = 'active';

  IF v_branch_count <> 1 THEN
    RAISE EXCEPTION
      'GATE PROVISIONING-SEED FAILED: se esperaba exactamente 1 branch "Casa Central" activa para account_id=%, se encontraron %',
      v_account_id, v_branch_count;
  END IF;

  SELECT id INTO v_branch_id
  FROM   public.branches
  WHERE  account_id = v_account_id AND name = 'Casa Central'
  LIMIT  1;

  -- Assert 2: al menos 1 cashbox ARS colgada de esa branch.
  SELECT count(*) INTO v_cashbox_count
  FROM   public.cashboxes
  WHERE  branch_id = v_branch_id
    AND  currency = 'ARS';

  IF v_cashbox_count < 1 THEN
    RAISE EXCEPTION
      'GATE PROVISIONING-SEED FAILED: se esperaba >=1 cashbox ARS para branch_id=% (account_id=%), se encontraron %',
      v_branch_id, v_account_id, v_cashbox_count;
  END IF;

  -- TRIANGULATE (i): re-ejecutar el bloque de seed para la MISMA cuenta no
  -- debe duplicar ni branch ni cashbox (idempotencia del seed inline).
  BEGIN
    INSERT INTO public.branches (account_id, name, is_active, status, opened_at)
    VALUES (v_account_id, 'Casa Central', TRUE, 'active', now())
    ON CONFLICT (account_id, name) DO NOTHING;

    IF NOT EXISTS (SELECT 1 FROM public.cashboxes cb WHERE cb.branch_id = v_branch_id) THEN
      INSERT INTO public.cashboxes (branch_id, name, currency)
      VALUES (v_branch_id, 'Caja Principal', 'ARS');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'GATE PROVISIONING-SEED: re-ejecución del seed degradó con %, ok (comportamiento esperado del sub-bloque).', SQLERRM;
  END;

  SELECT count(*) INTO v_branch_count_2
  FROM   public.branches
  WHERE  account_id = v_account_id AND name = 'Casa Central';

  IF v_branch_count_2 <> 1 THEN
    RAISE EXCEPTION
      'GATE PROVISIONING-SEED FAILED: la re-ejecución del seed duplicó la branch "Casa Central" (count=%) para account_id=%',
      v_branch_count_2, v_account_id;
  END IF;

  -- TRIANGULATE (ii): simular cuenta "branch sin cashbox" — borrar la
  -- cashbox del anchor y re-correr el backfill A.2; debe recrearla (1 sola).
  DELETE FROM public.cashboxes WHERE branch_id = v_branch_id;

  INSERT INTO public.cashboxes (branch_id, name, currency)
  SELECT public.c26_default_branch(a.id), 'Caja Principal', 'ARS'
  FROM   public.accounts a
  WHERE  a.id = v_account_id
    AND  public.c26_default_branch(a.id) IS NOT NULL
    AND  NOT EXISTS (
      SELECT 1
      FROM   public.cashboxes cb
      JOIN   public.branches  br ON br.id = cb.branch_id
      WHERE  br.account_id = a.id
    );

  SELECT count(*) INTO v_cashbox_count_2
  FROM   public.cashboxes
  WHERE  branch_id = v_branch_id;

  SELECT count(*) INTO v_branch_count_2
  FROM   public.branches
  WHERE  account_id = v_account_id AND name = 'Casa Central';

  IF v_cashbox_count_2 <> 1 OR v_branch_count_2 <> 1 THEN
    RAISE EXCEPTION
      'GATE PROVISIONING-SEED FAILED: backfill A.2 tras simular "branch sin cashbox" dejó cashbox_count=% branch_count=% (esperado 1 y 1) para account_id=%',
      v_cashbox_count_2, v_branch_count_2, v_account_id;
  END IF;

  RAISE NOTICE 'GATE PROVISIONING-SEED PASSED: signup crea exactamente 1 branch "Casa Central" + >=1 cashbox ARS; seed idempotente; backfill A.2 recrea cashbox faltante sin duplicar branch.';

  -- Limpieza hijo→padre por email del anchor (accounts=0 al final).
  DELETE FROM public.cashboxes        WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
  DELETE FROM public.branches         WHERE account_id = v_account_id;
  DELETE FROM public.account_members  WHERE account_id = v_account_id;
  DELETE FROM public.accounts         WHERE id = v_account_id;
  DELETE FROM public.profiles         WHERE id = v_user_id;
  DELETE FROM public.email_logs       WHERE user_id = v_user_id;
  DELETE FROM public.operation_idempotency WHERE user_id = v_user_id;
  DELETE FROM auth.users              WHERE id = v_user_id;

EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE 'GATE PROVISIONING-SEED FAILED%' THEN
      RAISE;
    END IF;
    -- Best-effort cleanup si algo falló a mitad de camino (p.ej. contexto
    -- inesperado en prod). Nunca dejar basura colgada del anchor sintético.
    BEGIN
      IF v_account_id IS NOT NULL THEN
        DELETE FROM public.cashboxes        WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
        DELETE FROM public.branches         WHERE account_id = v_account_id;
        DELETE FROM public.account_members  WHERE account_id = v_account_id;
        DELETE FROM public.accounts         WHERE id = v_account_id;
      END IF;
      DELETE FROM public.profiles         WHERE id = v_user_id;
      DELETE FROM public.email_logs       WHERE user_id = v_user_id;
      DELETE FROM public.operation_idempotency WHERE user_id = v_user_id;
      DELETE FROM auth.users              WHERE id = v_user_id;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;

-- =============================================================================
-- END OF MIGRATION 20260812000001_v3_provisioning_seed.sql
-- =============================================================================
