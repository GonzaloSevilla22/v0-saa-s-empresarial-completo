CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
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

  -- 6) metodos-pago-operaciones (D11 Parte B) + limpiezas-pagos-admin (OQ-1):
  --    catálogo de 7 formas de pago (6 originales + Cheque). Mismo criterio
  --    degrade-don't-fail que el sub-bloque de arriba — aislado, propia
  --    EXCEPTION, jamás aborta el signup.
  BEGIN
    -- limpiezas-pagos-admin (OQ-1): 'Cheque' (kind=check) se agrega como 7º
    -- método sembrado — el vocabulario del CHECK ya lo admitía desde
    -- 20260928000001 pero el seed original solo traía 6/7. sort_order=7
    -- (al final, no reordena los 6 existentes). Riesgo cero: el usuario
    -- puede desactivarlo desde el manager de Configuración si no lo usa.
    INSERT INTO public.payment_methods (account_id, name, kind, sort_order)
    SELECT v_account_id, v.name, v.kind, v.sort_order
    FROM (VALUES
        ('Efectivo',               'cash',     1),
        ('Transferencia bancaria', 'transfer', 2),
        ('Tarjeta',                'card',     3),
        ('Billetera virtual',      'wallet',   4),
        ('Cuenta corriente',       'credit',   5),
        ('Otro',                   'other',    6),
        ('Cheque',                 'check',    7)
    ) AS v(name, kind, sort_order)
    WHERE NOT EXISTS (
      SELECT 1 FROM public.payment_methods pm
      WHERE pm.account_id = v_account_id
        AND pm.kind       = v.kind
        AND pm.deleted_at IS NULL
    );
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING 'metodos-pago-operaciones: no se pudo sembrar el catálogo de formas de pago para account_id=% (signup continúa). SQLERRM=%',
        v_account_id, SQLERRM;
  END;

  RETURN new;
END;
$function$;
