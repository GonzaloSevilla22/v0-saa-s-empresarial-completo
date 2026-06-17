-- =============================================================================
-- MIGRATION: 20260701000002_c28_cashboxes_insert_policy.sql
-- CHANGE:    C-28 v21-cash-session — FIX: policy INSERT faltante en cashboxes
--
-- La migración 20260701000001 habilitó RLS en cashboxes pero solo creó la
-- policy SELECT (cashboxes_select). El backend (CashboxRepository.create_cashbox)
-- hace un INSERT DIRECTO como rol `authenticated` (no vía RPC SECURITY DEFINER),
-- por lo que sin una policy INSERT la RLS lo DENIEGA y no se puede crear ninguna
-- caja → la feature queda inutilizable.
--
-- cash_sessions y cash_movements NO necesitan policy de escritura: sus inserts
-- van por RPCs SECURITY DEFINER (rpc_open/close_cash_session, rpc_register_cash_movement)
-- que corren como owner y bypassean RLS. Solo cashboxes se escribe directo.
--
-- Fix: policy INSERT con WITH CHECK = el usuario es escritor de la cuenta dueña
-- de la sucursal (mismo patrón is_account_writer del resto del API). Append-only
-- se mantiene en cash_movements (sin UPDATE/DELETE). No se agregan UPDATE/DELETE
-- a cashboxes (el repo solo lista y crea).
--
-- GOVERNANCE: MEDIO. APPLY: npx supabase db push (vía CI al mergear).
-- ROLLBACK: DROP POLICY IF EXISTS cashboxes_insert ON public.cashboxes;
-- =============================================================================

CREATE POLICY cashboxes_insert
  ON public.cashboxes
  FOR INSERT
  WITH CHECK (
    branch_id IN (
      SELECT b.id FROM public.branches b
      WHERE public.is_account_writer(b.account_id)
    )
  );
