-- Huella del estado que toca la migración 20261074000001 (funciones, ACL, constraint, comentarios).
select 'fn|' || p.oid::regprocedure::text || '|' || md5(pg_get_functiondef(p.oid)) || '|' || coalesce(p.proacl::text,'NULL') || '|' || p.prosecdef || '|' || md5(coalesce(obj_description(p.oid,'pg_proc'),''))
  from pg_proc p where p.pronamespace='public'::regnamespace
   and p.proname in ('_stock_assert_can_adjust','_stock_apply_delta','_stock_manual_adjustment','rpc_stock_adjustment','rpc_adjust_branch_stock','rpc_apply_product_stock_delta','rpc_reverse_stock_movement','rpc_transfer_stock')
union all
select 'con|' || conname || '|' || pg_get_constraintdef(oid) || '|' || convalidated || '|' || md5(coalesce(obj_description(oid,'pg_constraint'),''))
  from pg_constraint where conrelid='public.stock_movements'::regclass and conname='stock_movements_manual_needs_reason'
order by 1;
