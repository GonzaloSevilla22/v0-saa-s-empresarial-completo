-- ============================================================
-- v20-tenancy-cleanup — Task 2.5
-- Migración de companies a accounts
--
-- Estado antes de esta migration (relevado 2026-06-09):
--   companies: 6 filas (organizaciones reales, confirmadas por PO — PA-18)
--   company_users: 5 filas
--
--   Mapeo confirmado:
--     5 companies con user_id ya tienen account_id en account_members
--     1 company sin company_users (sin usuarios, sin datos ERP asociados)
--
-- Estrategia:
--   Para cada company_user sin account → crear account + account_members
--   La company sin usuarios se deja sin migrar (sin datos que preservar)
-- ============================================================

-- Crear cuentas para cualquier usuario de company_users sin account_members
-- (idempotente: ON CONFLICT DO NOTHING en account_members)
DO $$
DECLARE
    v_cu RECORD;
    v_new_account_id UUID;
    v_billing_plan TEXT;
BEGIN
    FOR v_cu IN
        SELECT DISTINCT cu.user_id
        FROM public.company_users cu
        WHERE cu.user_id IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM public.account_members am
              WHERE am.user_id = cu.user_id
          )
    LOOP
        -- Obtener el billing_plan actual del perfil del usuario
        SELECT COALESCE(p.billing_plan, 'free')
        INTO v_billing_plan
        FROM public.profiles p
        WHERE p.id = v_cu.user_id;

        -- Crear la cuenta
        INSERT INTO public.accounts (billing_plan, billing_status, owner_user_id)
        VALUES (v_billing_plan, 'active', v_cu.user_id)
        RETURNING id INTO v_new_account_id;

        -- Crear la membresía como owner
        INSERT INTO public.account_members (account_id, user_id, role)
        VALUES (v_new_account_id, v_cu.user_id, 'owner');

        RAISE NOTICE 'Cuenta creada para user_id %, account_id %', v_cu.user_id, v_new_account_id;
    END LOOP;
END $$;

-- Verificar que todos los company_users con user_id tienen account_members
DO $$
DECLARE
  v_orphans INT;
BEGIN
  SELECT COUNT(*) INTO v_orphans
  FROM public.company_users cu
  WHERE cu.user_id IS NOT NULL
    AND NOT EXISTS (
        SELECT 1 FROM public.account_members am WHERE am.user_id = cu.user_id
    );

  IF v_orphans > 0 THEN
    RAISE EXCEPTION '% usuarios de company_users sin account_members tras la migración', v_orphans;
  END IF;

  RAISE NOTICE 'Migración de companies completada: todos los usuarios tienen account_members';
END $$;
