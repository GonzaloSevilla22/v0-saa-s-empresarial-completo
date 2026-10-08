-- Rollback de la migración 20261073000001 (el de su cabecera y del Migration Plan, Anexo B del design).
-- SOLO para el stack local: se usa para ver en ROJO los gates editados (4.1-4.4) contra el estado previo
-- y para validar que el rollback documentado restaura exactamente el estado original.
GRANT INSERT, UPDATE, DELETE, TRUNCATE ON public.stock_movements, public.branch_stock TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_reverse_stock_movement(uuid, text, text) TO authenticated;
CREATE POLICY stock_movements_account_insert ON public.stock_movements
  FOR INSERT TO authenticated
  WITH CHECK (account_id IN (SELECT current_account_ids() AS current_account_ids));
CREATE POLICY branch_stock_writer_insert ON public.branch_stock
  FOR INSERT TO authenticated WITH CHECK (is_account_writer(account_id));
CREATE POLICY branch_stock_writer_update ON public.branch_stock
  FOR UPDATE TO authenticated
  USING (is_account_writer(account_id)) WITH CHECK (is_account_writer(account_id));
