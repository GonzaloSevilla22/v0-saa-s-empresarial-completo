-- =============================================================================
-- MIGRATION: 20260517000002_fix_function_search_path.sql
-- DESCRIPTION:
--   SECTION 1 — function_search_path_mutable (11 functions)
--     Add SET search_path = public to prevent search_path injection attacks.
--     SECURITY DEFINER functions without a fixed search_path can be exploited
--     if an attacker creates a malicious object in a schema that appears earlier
--     in the search_path.
--
--   SECTION 2 — anon_security_definer_function_executable
--     REVOKE EXECUTE from anon for all functions not meant for unauthenticated
--     callers. These were callable via REST without any login.
--
--   SECTION 3 — REVOKE from authenticated for trigger-only functions
--     Trigger functions must never be callable via REST API by any user.
--     Triggers themselves continue working — they run under table-owner privileges.
--
-- Applied: 2026-05-17
-- =============================================================================


-- ── SECTION 1: Fix mutable search_path on 11 functions ───────────────────────

-- 1a. check_low_margin — SECURITY DEFINER trigger
CREATE OR REPLACE FUNCTION public.check_low_margin()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  prod_cost    numeric;
  prod_name    text;
  sale_margin  numeric;
  user_email   text;
BEGIN
  IF NEW.product_id IS NOT NULL AND NEW.amount > 0 THEN
    SELECT cost, name INTO prod_cost, prod_name
    FROM public.products WHERE id = NEW.product_id;

    IF prod_cost IS NOT NULL THEN
      sale_margin := ((NEW.amount - (prod_cost * NEW.quantity)) / NEW.amount) * 100;

      IF sale_margin < 15 THEN
        SELECT email INTO user_email FROM auth.users WHERE id = NEW.user_id;

        INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
        VALUES (
          NEW.user_id,
          'low_margin_alert',
          user_email,
          'Alerta de Margen Bajo: ' || prod_name,
          jsonb_build_object(
            'sale_id',            NEW.id,
            'product_name',       prod_name,
            'margin_percentage',  round(sale_margin, 2),
            'amount',             NEW.amount,
            'cost_basis',         prod_cost * NEW.quantity
          )
        );
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

-- 1b. handle_new_user — SECURITY DEFINER trigger
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  user_name text;
BEGIN
  INSERT INTO public.profiles (id, role) VALUES (new.id, 'user');

  user_name := COALESCE(new.raw_user_meta_data->>'name', 'Emprendedor');

  INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
  VALUES (
    new.id,
    'welcome',
    new.email,
    '¡Bienvenido a ALIADATA Emprendedores!',
    jsonb_build_object('name', user_name)
  );

  RETURN new;
END;
$function$;

-- 1c. is_admin() — SECURITY DEFINER (no-arg variant used in RLS policies)
--     Also wraps internal auth.uid() call with (SELECT ...) for consistency.
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = (SELECT auth.uid())
      AND role = 'admin'
  );
END;
$function$;

-- 1d. notify_meeting_created — SECURITY DEFINER trigger
CREATE OR REPLACE FUNCTION public.notify_meeting_created()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  INSERT INTO public.email_logs (event_type, recipient, subject, metadata)
  VALUES (
    'meeting_notice',
    'all_users',
    'Nueva Reunión: ' || NEW.title,
    jsonb_build_object(
      'meeting_id', NEW.id,
      'title',      NEW.title,
      'start_time', NEW.start_time,
      'url',        NEW.meeting_url
    )
  );
  RETURN NEW;
END;
$function$;

-- 1e. notify_pool_created — SECURITY DEFINER trigger
CREATE OR REPLACE FUNCTION public.notify_pool_created()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  INSERT INTO public.email_logs (event_type, recipient, subject, metadata)
  VALUES (
    'pool_notice',
    'all_users',
    'Pool de Compra Abierto: ' || NEW.title,
    jsonb_build_object(
      'pool_id',   NEW.id,
      'title',     NEW.title,
      'closes_at', NEW.closes_at
    )
  );
  RETURN NEW;
END;
$function$;

-- 1f. set_updated_at — plain trigger (not SECURITY DEFINER)
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $function$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$function$;

-- 1g. update_inventory_stock — plain trigger
CREATE OR REPLACE FUNCTION public.update_inventory_stock()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $function$
DECLARE
  qty_change INTEGER;
BEGIN
  IF    NEW.movement_type = 'sale'       THEN qty_change := -NEW.quantity;
  ELSIF NEW.movement_type = 'purchase'   THEN qty_change :=  NEW.quantity;
  ELSIF NEW.movement_type = 'adjustment' THEN qty_change :=  NEW.quantity;
  ELSIF NEW.movement_type = 'return'     THEN qty_change :=  NEW.quantity;
  ELSE                                        qty_change :=  NEW.quantity;
  END IF;

  INSERT INTO public.inventory_stock (variant_id, warehouse_id, quantity)
  VALUES (NEW.variant_id, NEW.warehouse_id, qty_change)
  ON CONFLICT (variant_id, warehouse_id)
  DO UPDATE SET quantity = inventory_stock.quantity + qty_change;

  RETURN NEW;
END;
$function$;

-- 1h. update_invoice_documents_updated_at — plain trigger
CREATE OR REPLACE FUNCTION public.update_invoice_documents_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $function$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$function$;

-- 1i. update_post_likes_count — SECURITY DEFINER trigger
CREATE OR REPLACE FUNCTION public.update_post_likes_count()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF (TG_OP = 'INSERT') THEN
    UPDATE public.posts SET likes_count = likes_count + 1 WHERE id = NEW.post_id;
  ELSIF (TG_OP = 'DELETE') THEN
    UPDATE public.posts SET likes_count = likes_count - 1 WHERE id = OLD.post_id;
  END IF;
  RETURN NULL;
END;
$function$;

-- 1j. update_post_replies_count — SECURITY DEFINER trigger
CREATE OR REPLACE FUNCTION public.update_post_replies_count()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF (TG_OP = 'INSERT') THEN
    UPDATE public.posts SET replies_count = replies_count + 1 WHERE id = NEW.post_id;
  ELSIF (TG_OP = 'DELETE') THEN
    UPDATE public.posts SET replies_count = replies_count - 1 WHERE id = OLD.post_id;
  END IF;
  RETURN NULL;
END;
$function$;

-- 1k. update_updated_at_column — plain trigger
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $function$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$function$;


-- ── SECTION 2: REVOKE EXECUTE from anon ──────────────────────────────────────
-- None of these should be reachable by unauthenticated REST callers.

REVOKE EXECUTE ON FUNCTION public.check_low_margin()                                                                     FROM anon;
REVOKE EXECUTE ON FUNCTION public.check_low_stock()                                                                      FROM anon;
REVOKE EXECUTE ON FUNCTION public.get_admin_activation_rate(timestamptz, timestamptz)                                    FROM anon;
REVOKE EXECUTE ON FUNCTION public.get_admin_community_interactions(timestamptz, timestamptz)                             FROM anon;
REVOKE EXECUTE ON FUNCTION public.get_admin_insights_breakdown(timestamptz, timestamptz)                                 FROM anon;
REVOKE EXECUTE ON FUNCTION public.get_admin_paid_conversion_rate()                                                       FROM anon;
REVOKE EXECUTE ON FUNCTION public.get_admin_umv_rate(timestamptz, timestamptz)                                           FROM anon;
REVOKE EXECUTE ON FUNCTION public.get_dashboard_critical_stock()                                                         FROM anon;
REVOKE EXECUTE ON FUNCTION public.get_dashboard_financials(timestamptz, timestamptz)                                     FROM anon;
REVOKE EXECUTE ON FUNCTION public.handle_new_user()                                                                      FROM anon;
REVOKE EXECUTE ON FUNCTION public.is_admin()                                                                             FROM anon;
REVOKE EXECUTE ON FUNCTION public.is_admin(uuid)                                                                         FROM anon;
REVOKE EXECUTE ON FUNCTION public.notify_meeting_created()                                                               FROM anon;
REVOKE EXECUTE ON FUNCTION public.notify_pool_created()                                                                  FROM anon;
REVOKE EXECUTE ON FUNCTION public.prevent_profile_privilege_escalation()                                                 FROM anon;
-- rls_auto_enable: created on live DB via MCP only — no committed migration.
-- Wrap in DO block so CI (fresh DB) skips gracefully; live DB REVOKE still lands.
DO $$ BEGIN
  REVOKE EXECUTE ON FUNCTION public.rls_auto_enable() FROM anon;
EXCEPTION WHEN undefined_function OR undefined_object THEN NULL;
END $$;
REVOKE EXECUTE ON FUNCTION public.rpc_admin_business_kpis(timestamptz, timestamptz)                                      FROM anon;
REVOKE EXECUTE ON FUNCTION public.rpc_admin_kpi_overview(timestamptz, timestamptz, text)                                 FROM anon;
REVOKE EXECUTE ON FUNCTION public.rpc_admin_module_stats(text, timestamptz, timestamptz)                                 FROM anon;
REVOKE EXECUTE ON FUNCTION public.rpc_admin_retention_30d(text, timestamptz, timestamptz)                               FROM anon;
REVOKE EXECUTE ON FUNCTION public.rpc_admin_weekly_usage_distribution(timestamptz, timestamptz)                          FROM anon;
-- 6/7-param RPC signatures added by stub migrations (not present in CI fresh DB).
DO $$ BEGIN
  REVOKE EXECUTE ON FUNCTION public.rpc_atomic_create_purchase(uuid, numeric, numeric, uuid, text, date) FROM anon;
EXCEPTION WHEN undefined_function OR undefined_object THEN NULL;
END $$;
DO $$ BEGIN
  REVOKE EXECUTE ON FUNCTION public.rpc_atomic_create_sale(uuid, uuid, numeric, numeric, uuid, text, date) FROM anon;
EXCEPTION WHEN undefined_function OR undefined_object THEN NULL;
END $$;
REVOKE EXECUTE ON FUNCTION public.rpc_atomic_log_ai_insight(text, text, text)                                            FROM anon;
REVOKE EXECUTE ON FUNCTION public.rpc_safe_delete_product(uuid)                                                          FROM anon;
REVOKE EXECUTE ON FUNCTION public.rpc_safe_delete_product(uuid, uuid)                                                    FROM anon;
REVOKE EXECUTE ON FUNCTION public.update_post_likes_count()                                                              FROM anon;
REVOKE EXECUTE ON FUNCTION public.update_post_replies_count()                                                            FROM anon;


-- ── SECTION 3: REVOKE from authenticated — trigger-only functions ─────────────
-- These are invoked exclusively by DB triggers, never by API callers.
-- Revoking EXECUTE does NOT break the triggers (triggers run as table owner).

REVOKE EXECUTE ON FUNCTION public.check_low_margin()                      FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.check_low_stock()                       FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.handle_new_user()                       FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.notify_meeting_created()                FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.notify_pool_created()                   FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.prevent_profile_privilege_escalation()  FROM authenticated;
DO $$ BEGIN
  REVOKE EXECUTE ON FUNCTION public.rls_auto_enable() FROM authenticated;
EXCEPTION WHEN undefined_function OR undefined_object THEN NULL;
END $$;
REVOKE EXECUTE ON FUNCTION public.update_post_likes_count()               FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.update_post_replies_count()             FROM authenticated;
