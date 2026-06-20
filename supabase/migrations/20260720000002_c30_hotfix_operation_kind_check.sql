-- =============================================================================
-- MIGRATION: 20260720000002_c30_hotfix_operation_kind_check.sql
-- CHANGE:    C-30 hotfix — extender operation_idempotency_operation_kind_check
--            con los operation_kind nuevos de C-30 (OQ-5).
--
-- ROOT CAUSE (atrapado por el SMOKE transaccional en prod, NO por pytest que
-- mockea asyncpg): public.operation_idempotency tenía un CHECK que limitaba
-- operation_kind a ('sale','purchase'). Los RPCs nuevos de C-30
-- (rpc_register_payment_received / rpc_register_payment_made /
-- rpc_register_supplier_charge) usan kinds nuevos → el INSERT a
-- operation_idempotency violaba el CHECK (23514).
-- Las ventas a crédito NO se ven afectadas (reusan operation_kind='sale').
--
-- FIX: DROP + ADD del CHECK incluyendo los 3 kinds nuevos. Idempotente y
-- no destructivo (las filas existentes son 'sale'/'purchase', siguen válidas).
--
-- GOVERNANCE: MEDIO. APPLY: npx supabase db push (NUNCA MCP apply_migration).
--
-- ROLLBACK:
--   ALTER TABLE public.operation_idempotency
--     DROP CONSTRAINT IF EXISTS operation_idempotency_operation_kind_check;
--   ALTER TABLE public.operation_idempotency
--     ADD CONSTRAINT operation_idempotency_operation_kind_check
--     CHECK (operation_kind = ANY (ARRAY['sale','purchase']));
-- =============================================================================

ALTER TABLE public.operation_idempotency
  DROP CONSTRAINT IF EXISTS operation_idempotency_operation_kind_check;

ALTER TABLE public.operation_idempotency
  ADD CONSTRAINT operation_idempotency_operation_kind_check
  CHECK (operation_kind = ANY (ARRAY[
    'sale',
    'purchase',
    'payment_received',
    'payment_made',
    'supplier_charge'
  ]));

COMMENT ON CONSTRAINT operation_idempotency_operation_kind_check ON public.operation_idempotency IS
  'C-30: operation_kind permitidos. C-29 usa sale/purchase; C-30 (OQ-5) agrega '
  'payment_received, payment_made, supplier_charge para la idempotencia de '
  'cobros/pagos/cargos de cuentas corrientes.';
