-- =============================================================================
-- MIGRATION: drop_dead_rpc_overloads
-- Drops the four stale overloads of rpc_atomic_create_sale /
-- rpc_atomic_create_purchase that are no longer reachable:
--
--   • The 5-arg sale overload (uuid,uuid,numeric,integer,uuid): original v1,
--     superseded by the 7-arg overload.
--   • The 7-arg sale overload (uuid,uuid,numeric,numeric,uuid,text,date):
--     was the production path, now replaced by rpc_create_sale_operation.
--   • The 4-arg purchase overload (uuid,numeric,integer,uuid): original v1.
--   • The 6-arg purchase overload (uuid,numeric,numeric,uuid,text,date):
--     was the production path, now replaced by rpc_create_purchase_operation.
--
-- All callers (sale-form, purchase-form, InvoiceAIButton) have been migrated
-- to rpc_create_sale_operation / rpc_create_purchase_operation.
-- The edge functions create-sale / create-purchase have been removed from the
-- repository. Dropping these signatures closes overload-drift risk permanently.
-- =============================================================================

-- Sale overloads
DROP FUNCTION IF EXISTS public.rpc_atomic_create_sale(
  p_client_id  uuid,
  p_product_id uuid,
  p_amount     numeric,
  p_quantity   integer,
  p_user_id    uuid
);

DROP FUNCTION IF EXISTS public.rpc_atomic_create_sale(
  p_client_id  uuid,
  p_product_id uuid,
  p_amount     numeric,
  p_quantity   numeric,
  p_unit_id    uuid,
  p_currency   text,
  p_date       date
);

-- Purchase overloads
DROP FUNCTION IF EXISTS public.rpc_atomic_create_purchase(
  p_product_id uuid,
  p_amount     numeric,
  p_quantity   integer,
  p_user_id    uuid
);

DROP FUNCTION IF EXISTS public.rpc_atomic_create_purchase(
  p_product_id  uuid,
  p_amount      numeric,
  p_quantity    numeric,
  p_unit_id     uuid,
  p_description text,
  p_date        date
);
