-- C-24 v20-insights-unification
-- Unifica la tabla legacy `insights` (content/actionable) con la canónica
-- `ai_insights` (message/priority/account_id) en una única tabla `insights`.
--
-- Además corrige una regresión de producción: desde que C-19 puso la RLS
-- account-based en ai_insights (~2026-06-06), los 4 Edge Functions que
-- insertan directo SIN account_id (ai-insights, ai-precio, ai-rentabilidad,
-- ai-comparativo) fallan el WITH CHECK (account_id NULL) y tragan el error.
-- Un trigger BEFORE INSERT deriva account_id del membership del usuario.
--
-- Decisiones (design.md): backfill content→message, account_id por membership
-- (NULL tolerado p/usuarios sin membership), priority='media' p/filas migradas.
-- Idempotente. La limpieza (drop view + backup) va en una migración aparte (OQ3).

-- ── 1. Backfill + rename (solo si ai_insights sigue siendo TABLA, no la vista) ──
DO $mig$
DECLARE
  v_ai_is_table   boolean := EXISTS (
    SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname = 'ai_insights' AND c.relkind = 'r'
  );
  v_legacy_is_old boolean := EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'insights' AND column_name = 'content'
  );
  v_null_count    integer;
BEGIN
  IF v_ai_is_table THEN
    IF v_legacy_is_old THEN
      -- Migrar filas legacy a la canónica (idempotente por id)
      INSERT INTO public.ai_insights (id, user_id, account_id, type, message, priority, created_at)
      SELECT i.id,
             i.user_id,
             (SELECT am.account_id FROM public.account_members am
              WHERE am.user_id = i.user_id ORDER BY am.account_id LIMIT 1),
             i.type,
             i.content,
             'media',
             i.created_at
      FROM public.insights i
      ON CONFLICT (id) DO NOTHING;

      SELECT count(*) INTO v_null_count FROM public.ai_insights WHERE account_id IS NULL;
      RAISE NOTICE 'unify_insights: filas con account_id NULL tras backfill = %', v_null_count;

      -- Conservar la legacy como backup (libera el nombre `insights`)
      ALTER TABLE public.insights RENAME TO insights_legacy_backup;
    END IF;

    -- Promover la canónica al nombre definitivo (RLS policies + índices viajan con el rename)
    ALTER TABLE public.ai_insights RENAME TO insights;
  END IF;
END
$mig$;

-- Privilegios de tabla para el rol authenticated (la RLS sigue gateando por fila).
-- Explícito para no depender de que el RENAME preserve el ACL.
GRANT SELECT, INSERT, UPDATE, DELETE ON public.insights TO authenticated;

-- ── 2. Trigger: autorrellenar account_id en INSERT cuando viene NULL ────────────
-- Arregla los 4 EF rotos (insertan sin account_id) y cubre el RPC y futuros writers.
CREATE OR REPLACE FUNCTION public.set_insight_account_id()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  IF NEW.account_id IS NULL THEN
    NEW.account_id := (
      SELECT account_id FROM public.account_members
      WHERE user_id = NEW.user_id ORDER BY account_id LIMIT 1
    );
  END IF;
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_set_insight_account_id ON public.insights;
CREATE TRIGGER trg_set_insight_account_id
  BEFORE INSERT ON public.insights
  FOR EACH ROW EXECUTE FUNCTION public.set_insight_account_id();

-- ── 3. Rewrite del RPC: insertar en el esquema canónico ────────────────────────
-- Misma firma (p_type, p_content, p_source_function) y misma forma jsonb de retorno.
-- Preserva lock de profiles, contador insights_used, telemetría y detección de UMV.
CREATE OR REPLACE FUNCTION public.rpc_atomic_log_ai_insight(
  p_type            text,
  p_content         text,
  p_source_function text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid            uuid;
  v_profile        RECORD;
  v_insight_id     uuid;
  v_account_id     uuid;
  v_insight_record jsonb;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Lock del perfil para evitar carreras en el contador
  SELECT id, plan, insights_used INTO v_profile
  FROM profiles WHERE id = v_uid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Profile not found' USING ERRCODE = 'no_data_found';
  END IF;

  -- Límite de plan free
  IF v_profile.plan = 'free' AND v_profile.insights_used >= 5 THEN
    RAISE EXCEPTION 'AI Insights limit reached for free plan' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Cuenta del usuario (primera membership; NULL tolerado, lo cubre el trigger)
  SELECT account_id INTO v_account_id
  FROM account_members WHERE user_id = v_uid ORDER BY account_id LIMIT 1;

  -- Insert en la tabla canónica unificada
  INSERT INTO insights (user_id, account_id, type, message, priority)
  VALUES (v_uid, v_account_id, p_type, p_content, 'media')
  RETURNING id INTO v_insight_id;

  -- Contador de uso
  UPDATE profiles SET insights_used = insights_used + 1 WHERE id = v_uid;

  -- Telemetría
  INSERT INTO analytics_events (user_id, event_name, event_data)
  VALUES (v_uid, 'insight_generated',
    jsonb_build_object('type', p_type, 'source_function', p_source_function, 'insight_id', v_insight_id));

  -- Detección de UMV (primer insight + primera operación)
  IF EXISTS (SELECT 1 FROM analytics_events WHERE user_id = v_uid AND event_name = 'operation_created')
  AND NOT EXISTS (SELECT 1 FROM analytics_events WHERE user_id = v_uid AND event_name = 'umv_reached')
  THEN
    INSERT INTO analytics_events (user_id, event_name, event_data)
    VALUES (v_uid, 'umv_reached',
      jsonb_build_object('type', 'insight_generated', 'insight_id', v_insight_id));
  END IF;

  SELECT to_jsonb(i) INTO v_insight_record FROM insights i WHERE id = v_insight_id;
  RETURN v_insight_record;
END;
$$;

-- ── 4. Vista de compatibilidad transitoria ─────────────────────────────────────
-- Para código aún no redepleado que consulta ai_insights. security_invoker=true
-- para que la RLS de la tabla subyacente se aplique al usuario que consulta.
CREATE OR REPLACE VIEW public.ai_insights WITH (security_invoker = true) AS
  SELECT * FROM public.insights;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.ai_insights TO authenticated;
