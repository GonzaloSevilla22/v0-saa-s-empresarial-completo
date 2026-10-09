-- Huella del estado de privilegios/policies/comentarios que toca la migración 20261073000001.
select 'relacl|' || c.relname || '|' || coalesce(c.relacl::text,'NULL') from pg_class c where c.relnamespace='public'::regnamespace and c.relname in ('stock_movements','branch_stock')
union all
select 'policy|' || tablename || '|' || policyname || '|' || cmd || '|' || coalesce(qual,'') || '|' || coalesce(with_check,'') from pg_policies where schemaname='public' and tablename in ('stock_movements','branch_stock')
union all
select 'proacl|' || p.oid::regprocedure::text || '|' || coalesce(p.proacl::text,'NULL') from pg_proc p where p.proname='rpc_reverse_stock_movement' and p.pronamespace='public'::regnamespace
union all
select 'comment|' || c.relname || '|' || md5(coalesce(obj_description(c.oid),'')) from pg_class c where c.relnamespace='public'::regnamespace and c.relname in ('stock_movements','branch_stock')
order by 1;
