-- Estado final de la BD local tras el humo (sólo lectura).
\echo '== Migraciones aplicadas'
select count(*) as migraciones, max(version) as ultima from supabase_migrations.schema_migrations;
\echo '== ACL de las RPC de stock (authenticated / anon / service_role)'
select p.proname, pg_get_function_identity_arguments(p.oid) as args,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated,
       has_function_privilege('anon', p.oid, 'EXECUTE') as anon,
       has_function_privilege('service_role', p.oid, 'EXECUTE') as service_role
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in ('rpc_stock_adjustment','rpc_apply_product_stock_delta','rpc_reverse_stock_movement','rpc_adjust_branch_stock','rpc_transfer_stock')
order by 1;
\echo '== Privilegios de tabla de authenticated sobre stock_movements / branch_stock'
select t.t as tabla, has_table_privilege('authenticated', t.t, 'SELECT') as sel, has_table_privilege('authenticated', t.t, 'INSERT') as ins,
       has_table_privilege('authenticated', t.t, 'UPDATE') as upd, has_table_privilege('authenticated', t.t, 'DELETE') as del
from (values ('public.stock_movements'), ('public.branch_stock')) t(t);
\echo '== CHECK del motivo en stock_movements'
select conname, convalidated from pg_constraint where conname = 'stock_movements_manual_needs_reason';
\echo '== Invariante: todo movimiento manual con motivo, cuenta, sucursal y autor (esperado 0 violaciones)'
select count(*) as violaciones from stock_movements
where type in ('adjustment','physical_count','loss','damage','expiry')
  and (reason is null or btrim(reason) = '' or account_id is null or branch_id is null or performed_by is null);
\echo '== Invariante: after = before + delta en todos los movimientos (esperado 0 violaciones)'
select count(*) as violaciones from stock_movements where quantity_before is not null and quantity_after is not null and quantity_after <> quantity_before + quantity_delta;
\echo '== Libro de movimientos completo del humo'
select movement_number as n, to_char(created_at, 'HH24:MI:SS') as hora, type, quantity_delta as delta, quantity_before as antes, quantity_after as despues,
       product_name as producto, (select b.name from branches b where b.id = m.branch_id) as sucursal, coalesce(reference_type, '-') as ref, coalesce(reason, '-') as motivo
from stock_movements m order by movement_number;
\echo '== Saldos finales por producto y sucursal'
select p.name as producto, b.name as sucursal, bs.quantity as saldo
from branch_stock bs join products p on p.id = bs.product_id join branches b on b.id = bs.branch_id order by 1, 2;
