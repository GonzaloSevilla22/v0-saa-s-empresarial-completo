DO $$
DECLARE
  v_bad  text[] := '{}';
  v_sig  text;
  v_src  text;
  v_acl  text;
BEGIN
  -- Columna, FK NO ACTION e índice único parcial.
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'sales_orders'
                   AND column_name = 'source_delivery_note_id' AND data_type = 'uuid' AND is_nullable = 'YES') THEN
    v_bad := v_bad || 'sales_orders.source_delivery_note_id (uuid NULL)'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'sales_orders_source_delivery_note_id_fkey'
                   AND conrelid = 'public.sales_orders'::regclass AND contype = 'f'
                   AND confrelid = 'public.delivery_notes'::regclass AND confdeltype = 'a') THEN
    v_bad := v_bad || 'FK sales_orders_source_delivery_note_id_fkey ON DELETE NO ACTION'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_indexes
                 WHERE schemaname = 'public' AND indexname = 'sales_orders_source_delivery_note_id_uq'
                   AND indexdef LIKE 'CREATE UNIQUE INDEX%'
                   AND indexdef LIKE '%source_delivery_note_id IS NOT NULL%'
                   AND indexdef LIKE '%<> ''canceled''%') THEN
    v_bad := v_bad || 'índice único parcial sales_orders_source_delivery_note_id_uq'::text;
  END IF;

  -- Catálogo: las dos filas de esta tanda, por presencia y atributos (la
  -- introspección de la tanda A valida las suyas del mismo modo).
  IF NOT EXISTS (SELECT 1 FROM public.document_status_transitions
                 WHERE document_type = 'delivery_note_sale' AND from_status = 'issued' AND to_status = 'converted'
                   AND NOT is_terminal_to AND NOT requires_reason
                   AND allowed_role @> ARRAY['seller', 'cashier', 'admin', 'owner']
                   AND allowed_role <@ ARRAY['seller', 'cashier', 'admin', 'owner']) THEN
    v_bad := v_bad || 'catálogo delivery_note_sale issued->converted {seller,cashier,admin,owner}'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.document_status_transitions
                 WHERE document_type = 'delivery_note_sale' AND from_status = 'converted' AND to_status = 'issued'
                   AND allowed_role IS NULL AND NOT is_terminal_to AND NOT requires_reason) THEN
    v_bad := v_bad || 'catálogo delivery_note_sale converted->issued (sistema, sin rol)'::text;
  END IF;

  -- Una sola definición de cada función reescrita o nueva.
  FOREACH v_sig IN ARRAY ARRAY['_c29_confirm_order_core', 'rpc_delete_sale_operation',
                               'rpc_atomic_update_sale_operation', 'rpc_convert_delivery_note_to_sale',
                               '_delivery_note_payload'] LOOP
    IF (SELECT count(*) FROM pg_proc WHERE proname = v_sig AND pronamespace = 'public'::regnamespace) <> 1 THEN
      v_bad := v_bad || format('una sola definición de %s', v_sig);
    END IF;
  END LOOP;

  -- ACL idéntica a la previa en las tres reescritas (checkpoint 6.1), la de la
  -- RPC nueva (authenticated sí, anon/PUBLIC no) y el payload interno.
  FOR v_sig, v_acl IN
    SELECT * FROM (VALUES
      ('public._c29_confirm_order_core(text,uuid,text,uuid,text,uuid,text,uuid,uuid)', 'authenticated,postgres,service_role'),
      ('public.rpc_delete_sale_operation(uuid,uuid,text)', 'authenticated,postgres,service_role'),
      ('public.rpc_atomic_update_sale_operation(uuid[],uuid,date,text,jsonb,uuid,boolean,uuid,boolean,text,boolean)', 'authenticated,postgres,service_role'),
      ('public.rpc_convert_delivery_note_to_sale(text,uuid,integer,uuid,uuid,uuid,text)', 'authenticated,postgres,service_role'),
      ('public._delivery_note_payload(uuid)', 'postgres,service_role')
    ) AS t(sig, acl)
  LOOP
    IF (SELECT string_agg(r.rolname, ',' ORDER BY r.rolname)
        FROM pg_proc p
        CROSS JOIN LATERAL aclexplode(p.proacl) a
        JOIN pg_roles r ON r.oid = a.grantee
        WHERE p.oid = v_sig::regprocedure AND a.privilege_type = 'EXECUTE') IS DISTINCT FROM v_acl
       OR EXISTS (SELECT 1 FROM pg_proc p CROSS JOIN LATERAL aclexplode(p.proacl) a
                  WHERE p.oid = v_sig::regprocedure AND a.grantee = 0) THEN
      v_bad := v_bad || format('ACL de %s (se esperaba EXECUTE para %s, sin PUBLIC)', v_sig, v_acl);
    END IF;
  END LOOP;

  -- Cuerpos: la rama del núcleo, el salto y el guard del borrado, el P0423 de
  -- la edición y el orden de la conversión.
  SELECT replace(prosrc, E'\r', '') INTO v_src FROM pg_proc
  WHERE oid = 'public._c29_confirm_order_core(text,uuid,text,uuid,text,uuid,text,uuid,uuid)'::regprocedure;
  IF position('v_order.source_delivery_note_id IS NOT NULL' IN v_src) = 0
     OR position('delivery_note_order_mismatch' IN v_src) = 0
     OR position('IF v_from_delivery_note THEN' IN v_src) = 0
     OR position('IF v_from_delivery_note THEN' IN v_src) > position('FROM public.products' IN v_src)
     OR position('v_item.iva_rate_snapshot' IN v_src) = 0 THEN
    v_bad := v_bad || '_c29_confirm_order_core sin la rama v_from_delivery_note'::text;
  END IF;

  SELECT replace(prosrc, E'\r', '') INTO v_src FROM pg_proc
  WHERE oid = 'public.rpc_delete_sale_operation(uuid,uuid,text)'::regprocedure;
  IF position('delivery_note_branch_inactive' IN v_src) = 0
     OR position('delivery_note_branch_inactive' IN v_src) > position('public._fiscal_void_pending_for_sale_edit(' IN v_src)
     OR position('IF v_source_dn IS NULL THEN' IN v_src) = 0
     OR position('IF v_source_dn IS NULL THEN' IN v_src) > position('PERFORM public.rpc_reverse_stock_movement' IN v_src)
     OR position('''converted'', ''issued''' IN v_src) = 0 THEN
    v_bad := v_bad || 'rpc_delete_sale_operation sin el guard de sucursal, el salto de la reversa o la reapertura'::text;
  END IF;

  SELECT replace(prosrc, E'\r', '') INTO v_src FROM pg_proc
  WHERE oid = 'public.rpc_atomic_update_sale_operation(uuid[],uuid,date,text,jsonb,uuid,boolean,uuid,boolean,text,boolean)'::regprocedure;
  IF position('delivery_note_sale_locked' IN v_src) = 0
     OR position('delivery_note_sale_locked' IN v_src) > position('public._fiscal_void_pending_for_sale_edit(' IN v_src) THEN
    v_bad := v_bad || 'rpc_atomic_update_sale_operation sin el P0423 delivery_note_sale_locked antes del bloque fiscal'::text;
  END IF;

  SELECT replace(prosrc, E'\r', '') INTO v_src FROM pg_proc
  WHERE oid = 'public.rpc_convert_delivery_note_to_sale(text,uuid,integer,uuid,uuid,uuid,text)'::regprocedure;
  IF NOT (position('FOR UPDATE' IN v_src) > 0
          AND position('FOR UPDATE' IN v_src) < position('FROM public.operation_idempotency' IN v_src)
          AND position('FROM public.operation_idempotency' IN v_src) < position('public._c29_confirm_order_core(' IN v_src)
          AND position('public._c29_confirm_order_core(' IN v_src) < position('''issued'', ''converted''' IN v_src))
     OR position('FROM public.products' IN v_src) > 0 THEN
    v_bad := v_bad || 'rpc_convert_delivery_note_to_sale fuera del orden lock -> idempotencia -> núcleo -> transición, o bloquea productos'::text;
  END IF;

  SELECT replace(prosrc, E'\r', '') INTO v_src FROM pg_proc
  WHERE oid = 'public._delivery_note_payload(uuid)'::regprocedure;
  IF position('so.source_delivery_note_id = dn.id' IN v_src) = 0 THEN
    v_bad := v_bad || '_delivery_note_payload no deriva la venta generada'::text;
  END IF;

  -- Los COMMENT vivos de las tres reescritas siguen siendo los mismos.
  IF md5(COALESCE(obj_description('public._c29_confirm_order_core(text,uuid,text,uuid,text,uuid,text,uuid,uuid)'::regprocedure, 'pg_proc'), '')) <> 'dac0f029b9ce6f0dad97549f1f6de9d3'
     OR md5(COALESCE(obj_description('public.rpc_delete_sale_operation(uuid,uuid,text)'::regprocedure, 'pg_proc'), '')) <> 'b3bafc6d5c0a20bbd42b006af8769513'
     OR md5(COALESCE(obj_description('public.rpc_atomic_update_sale_operation(uuid[],uuid,date,text,jsonb,uuid,boolean,uuid,boolean,text,boolean)'::regprocedure, 'pg_proc'), '')) <> '1675d3824b79fccd3efba3b256adf89e' THEN
    v_bad := v_bad || 'el COMMENT vivo de una función reescrita cambió'::text;
  END IF;

  IF COALESCE(array_length(v_bad, 1), 0) > 0 THEN
    RAISE EXCEPTION 'remitos-venta tanda B (introspección) FAILED: %', array_to_string(v_bad, ' | ');
  END IF;
  RAISE NOTICE 'remitos-venta tanda B (introspección): OK — columna/FK/índice, catálogo (issued->converted, converted->issued), una definición y ACL previa de las tres reescritas, rama del núcleo, guard y salto del borrado, P0423 de la edición, orden de la conversión, payload y COMMENT vivos.';
END $$;
