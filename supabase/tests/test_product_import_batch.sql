-- =============================================================================
-- GATE: test_product_import_batch.sql
-- CHANGE: importador-productos-fastapi
--
-- El importador de productos deja de trocear en el cliente y pasa a ser UNA
-- SOLA transacción de servidor (`rpc_import_products`, DEC-24) — todo o
-- nada, con reporte de errores fila por fila. INVOCA `rpc_bulk_upsert_
-- products` UNA VEZ con el archivo entero — no reimplementa ninguna de sus
-- reglas (D1 del design). `rpc_bulk_upsert_products` recibe la ÚNICA
-- modificación quirúrgica de D2 (el error de fila lleva su `row`) y queda
-- REVOCADA de `authenticated` (D4/OQ-7): el backend es el único camino.
--
-- Qué ejercita, con dos tenants sintéticos y sesión vía request.jwt.claims
-- (mismo molde que test_expense_import_batch.sql / test_gastos_forma_pago.sql):
--
--   (1.x) ESQUEMA — product_imports (columnas, PK, UNIQUE, RLS, policy),
--         CHECK de operation_idempotency.
--   (2.x) TODO O NADA — una fila inválida (sku_parent inexistente) no deja
--         escrita ninguna de las válidas, en las SEIS tablas involucradas.
--   (3.x) CAMINO FELIZ — padre + variante + producto simple con categoría
--         nueva: 3 productos, jerarquía resuelta, branch_stock, categoría
--         creada, import_id poblado, committed=true.
--   (4.x) TOPE DE CATEGORÍAS sobre el ARCHIVO — más de 50 categorías nuevas
--         distintas cuya PRIMERA MITAD por sí sola no supera el tope →
--         P0400 propagado (no un error de fila), CERO categorías de la
--         primera mitad creadas.
--   (5.x) ERROR ESTRUCTURAL — un valor que no castea (no de dominio)
--         también aborta el lote entero, con su SQLSTATE y su fila.
--   (6.x) EQUIVALENCIA con la llamada directa (verifica la llamada anidada
--         SECURITY DEFINER: auth.uid()/current_account_ids() no cambian).
--   (7.x) SIMULACIÓN (p_dry_run) — CERO escrituras en las seis tablas.
--   (8.x) TENENCIA — sku_parent de OTRA cuenta → error de fila, nada
--         escrito en ninguna cuenta.
--   (9.x) ROL DE ESCRITURA — un miembro de sólo lectura no puede importar.
--   (10.x) TOPE DE FILAS — 2501 filas → P0427; lote vacío → P0427 (tope
--          bajado de 5.000 a 2.500 post-review, OQ-2).
--   (11.x) IDEMPOTENCIA y DEDUPE — misma clave → replay; mismo file_hash con
--          otra clave → replay; un lote rechazado NO quema la clave.
--   (12.x) ACLs — anon sin EXECUTE en rpc_import_products; authenticated con
--          EXECUTE en rpc_import_products y SIN INSERT en product_imports;
--          rpc_bulk_upsert_products SIN EXECUTE para authenticated/anon,
--          service_role lo conserva.
--   (13.x) CUENTA AMBIGUA (corrección ronda 3, F1) — un usuario miembro de
--          DOS cuentas → P0403, cero escrituras en NINGUNA de las dos; un
--          usuario de una sola cuenta (bloques 2/3/etc.) sigue funcionando
--          igual, sin regresión.
--   (14.x) CATEGORÍAS NUEVAS case-insensitive (corrección ronda 3, F2) — un
--          archivo con la misma categoría en 3 capitalizaciones distintas
--          se anuncia como UNA sola categoría nueva, coincidiendo con lo
--          que el upsert realmente crea.
--
-- ⚠️ REGLA DE ESTE GATE: se asserta el EFECTO (filas nuevas o su ausencia,
-- SQLSTATE exacto), nunca "no hubo error".
--
-- Degrade-don't-fail: si el anchor sintético no resuelve auth.uid() bajo
-- request.jwt.claims local, el gate emite NOTICE y no aborta.
-- =============================================================================


-- ═══════════════════════ (1) ESQUEMA ═══════════════════════════════════════
DO $$
DECLARE
  v_count  integer;
  v_condef text;
BEGIN
  -- (1.1) product_imports: columnas + PK + UNIQUE(account_id, file_hash)
  SELECT COUNT(*) INTO v_count
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'product_imports'
    AND column_name IN ('id','account_id','user_id','file_name','file_hash','rows_total','inserted','updated','created_at');
  IF v_count <> 9 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (1.1): public.product_imports tiene % de las 9 columnas esperadas.', v_count;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM pg_indexes
  WHERE schemaname = 'public' AND tablename = 'product_imports'
    AND indexdef LIKE '%UNIQUE%' AND indexdef LIKE '%account_id%' AND indexdef LIKE '%file_hash%';
  IF v_count = 0 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (1.1): falta el UNIQUE (account_id, file_hash) — el dedupe de dominio (D8) depende de él.';
  END IF;

  -- (1.2) RLS habilitada + policy de SELECT por current_account_ids()
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.product_imports'::regclass) THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (1.2): product_imports no tiene RLS habilitada.';
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM pg_policy WHERE polrelid = 'public.product_imports'::regclass AND polname = 'product_imports_select';
  IF v_count = 0 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (1.2): falta la policy product_imports_select.';
  END IF;

  -- (1.3) CHECK de operation_idempotency.operation_kind suma product_import,
  -- sin perder ninguno de los kinds previos.
  SELECT pg_get_constraintdef(c.oid) INTO v_condef
  FROM pg_constraint c
  WHERE c.conrelid = 'public.operation_idempotency'::regclass
    AND c.conname = 'operation_idempotency_operation_kind_check';
  IF position('product_import' in v_condef) = 0 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (1.3): el CHECK de operation_kind no acepta product_import. Definición viva: %', v_condef;
  END IF;
  IF position('expense_import' in v_condef) = 0 OR position('bank_statement_import' in v_condef) = 0
     OR position('credit_note' in v_condef) = 0 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (1.3): la ampliación del CHECK perdió algún kind previo. Definición viva: %', v_condef;
  END IF;

  RAISE NOTICE 'PASS (1): product_imports con su forma + RLS + policy, CHECK ampliado.';
END $$;


-- ═══════════════════════ (setup) fixtures — 2 tenants ═══════════════════════
DO $$
DECLARE
  v_email_a       text := 'product-import-batch-a@test.local';
  v_email_b       text := 'product-import-batch-b@test.local';
  v_email_reader  text := 'product-import-batch-reader@test.local';
  v_email_multi   text := 'product-import-batch-multi@test.local';
  v_user_a        uuid := gen_random_uuid();
  v_user_b        uuid := gen_random_uuid();
  v_user_reader   uuid := gen_random_uuid();
  v_user_multi    uuid := gen_random_uuid();
  v_account_a     uuid;
  v_account_b     uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', v_email_a, now(), now(), jsonb_build_object('name', 'Gate Product Import A'))
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_b, 'authenticated', 'authenticated', v_email_b, now(), now(), jsonb_build_object('name', 'Gate Product Import B'))
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_reader, 'authenticated', 'authenticated', v_email_reader, now(), now(), jsonb_build_object('name', 'Gate Product Import Reader'))
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_multi, 'authenticated', 'authenticated', v_email_multi, now(), now(), jsonb_build_object('name', 'Gate Product Import Multi'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;

  IF v_account_a IS NULL OR v_account_b IS NULL OR v_account_a = v_account_b THEN
    RAISE NOTICE 'GATE PRODUCT-IMPORT (setup): no se pudieron provisionar 2 tenants independientes — degradando sin abortar.';
    RETURN;
  END IF;

  -- Miembro de SÓLO LECTURA de la cuenta A — sostiene (9.x). El alta de
  -- auth.users auto-provisiona una cuenta PROPIA con el usuario como
  -- 'owner' (trigger de la app) — current_account_ids() no tiene ORDER BY,
  -- así que dejarla viva haría que el LIMIT 1 de la RPC pudiera resolver
  -- esa cuenta propia (donde SÍ es owner) en vez de la cuenta A. Se retira
  -- esa membresía/cuenta propia para que la ÚNICA cuenta del reader sea A,
  -- con rol 'member'.
  DELETE FROM public.account_members WHERE user_id = v_user_reader AND role = 'owner';
  SET session_replication_role = replica;
  DELETE FROM public.accounts WHERE owner_user_id = v_user_reader;
  SET session_replication_role = DEFAULT;

  INSERT INTO public.account_members (account_id, user_id, role)
  VALUES (v_account_a, v_user_reader, 'member')
  ON CONFLICT DO NOTHING;

  -- Miembro de DOS cuentas (su propia cuenta auto-provisionada, donde es
  -- 'owner' + la cuenta A, donde se lo agrega como 'owner' también) —
  -- sostiene (13.x), la corrección de revisión ronda 3 (F1): a diferencia
  -- del reader, ACÁ la cuenta propia se conserva a propósito, porque el
  -- caso a probar es justo la ambigüedad de más de una membresía.
  INSERT INTO public.account_members (account_id, user_id, role)
  VALUES (v_account_a, v_user_multi, 'owner')
  ON CONFLICT DO NOTHING;

  RAISE NOTICE 'SETUP OK: 2 tenants (A opera, B ajena) + 1 miembro de sólo lectura en A + 1 miembro de DOS cuentas.';
END $$;


-- ═══════════════ (2) TODO O NADA — una fila inválida no deja nada ══════════
DO $$
DECLARE
  v_user_a uuid; v_account_a uuid;
  v_result jsonb;
  v_before_products integer; v_before_categories integer; v_before_stock integer;
  v_before_attrs integer; v_before_imports integer; v_before_idem integer;
  v_after_products  integer; v_after_categories  integer; v_after_stock  integer;
  v_after_attrs  integer; v_after_imports   integer; v_after_idem  integer;
  v_rows jsonb;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'product-import-batch-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (2): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (2): setup incompleto — degradando.'; RETURN; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN
    RAISE NOTICE 'GATE PRODUCT-IMPORT (2): auth.uid() no resuelve — degradando.'; RETURN;
  END IF;

  SELECT COUNT(*) INTO v_before_products FROM public.products WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_before_categories FROM public.product_categories WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_before_stock FROM public.branch_stock bs JOIN public.branches b ON b.id = bs.branch_id WHERE b.account_id = v_account_a;
  SELECT COUNT(*) INTO v_before_attrs FROM public.product_attributes pa JOIN public.products p ON p.id = pa.product_id WHERE p.account_id = v_account_a;
  SELECT COUNT(*) INTO v_before_imports FROM public.product_imports WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_before_idem FROM public.operation_idempotency WHERE user_id = v_user_a;

  v_rows := jsonb_build_array(
    jsonb_build_object('row_no', 1, 'name', 'Gate 2 producto válido 1', 'price', 100, 'stock', 5),
    jsonb_build_object('row_no', 2, 'name', 'Gate 2 variante huérfana', 'sku_parent', '__gate_pib_sku_inexistente__', 'is_variant', true, 'price', 50),
    jsonb_build_object('row_no', 3, 'name', 'Gate 2 producto válido 2', 'price', 200, 'stock', 3)
  );

  v_result := public.rpc_import_products(
    'gate-pib-2-' || gen_random_uuid()::text, v_rows,
    'gate-pib-2.csv', 'gate-pib-2-hash-' || gen_random_uuid()::text
  );

  IF (v_result->>'committed')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (2): committed=% y esperaba false — un lote con una fila inválida NO puede aplicarse. Resultado: %', v_result->>'committed', v_result;
  END IF;
  IF jsonb_array_length(v_result->'errors') <> 1 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (2): errors tiene % elementos y esperaba 1. Resultado: %', jsonb_array_length(v_result->'errors'), v_result;
  END IF;
  IF (v_result->'errors'->0->>'row')::int <> 2 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (2): el error reportado es de la fila % y esperaba la 2. Resultado: %', v_result->'errors'->0->>'row', v_result;
  END IF;

  SELECT COUNT(*) INTO v_after_products FROM public.products WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_after_categories FROM public.product_categories WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_after_stock FROM public.branch_stock bs JOIN public.branches b ON b.id = bs.branch_id WHERE b.account_id = v_account_a;
  SELECT COUNT(*) INTO v_after_attrs FROM public.product_attributes pa JOIN public.products p ON p.id = pa.product_id WHERE p.account_id = v_account_a;
  SELECT COUNT(*) INTO v_after_imports FROM public.product_imports WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_after_idem FROM public.operation_idempotency WHERE user_id = v_user_a;

  IF v_after_products <> v_before_products THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (2): products pasó de % a % — un lote rechazado NO puede dejar NINGÚN producto nuevo.', v_before_products, v_after_products;
  END IF;
  IF v_after_categories <> v_before_categories THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (2): product_categories pasó de % a %.', v_before_categories, v_after_categories;
  END IF;
  IF v_after_stock <> v_before_stock THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (2): branch_stock pasó de % a %.', v_before_stock, v_after_stock;
  END IF;
  IF v_after_attrs <> v_before_attrs THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (2): product_attributes pasó de % a %.', v_before_attrs, v_after_attrs;
  END IF;
  IF v_after_imports <> v_before_imports THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (2): product_imports pasó de % a % — un lote rechazado no deja fila de importación.', v_before_imports, v_after_imports;
  END IF;
  IF v_after_idem <> v_before_idem THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (2): operation_idempotency pasó de % a % — un lote rechazado NO puede quemar la clave.', v_before_idem, v_after_idem;
  END IF;

  RAISE NOTICE 'PASS (2): lote de 3 filas con la 2ª inválida no dejó NADA escrito en las 6 tablas.';
END $$;


-- ═══ (3) CAMINO FELIZ — padre + variante + simple, categoría nueva ══════════
DO $$
DECLARE
  v_user_a uuid; v_account_a uuid;
  v_result jsonb; v_rows jsonb;
  v_import_id uuid;
  v_count integer;
  v_variant_parent_id uuid;
  v_parent_id uuid; v_variant_id uuid; v_simple_id uuid;
  v_cat_name text := '__gate_pib_categoria_nueva__';
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'product-import-batch-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (3): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (3): setup incompleto — degradando.'; RETURN; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (3): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  v_rows := jsonb_build_array(
    jsonb_build_object('row_no', 1, 'name', '__gate_pib_padre__', 'sku', '__gate_pib_sku_padre__', 'is_variant', false),
    jsonb_build_object('row_no', 2, 'name', '__gate_pib_variante__', 'sku_parent', '__gate_pib_sku_padre__', 'is_variant', true, 'price', 999, 'stock', 7, 'category', v_cat_name),
    jsonb_build_object('row_no', 3, 'name', '__gate_pib_simple__', 'price', 111, 'stock', 4)
  );

  v_result := public.rpc_import_products(
    'gate-pib-3-' || gen_random_uuid()::text, v_rows,
    'gate-pib-3.csv', 'gate-pib-3-hash-' || gen_random_uuid()::text
  );

  IF (v_result->>'committed')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (3): committed=% y esperaba true. Resultado: %', v_result->>'committed', v_result;
  END IF;
  IF (v_result->>'inserted')::int <> 3 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (3): inserted=% y esperaba 3. Resultado: %', v_result->>'inserted', v_result;
  END IF;

  v_import_id := (v_result->>'import_id')::uuid;
  IF v_import_id IS NULL THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (3): import_id vino NULL en un lote committed.';
  END IF;

  SELECT id INTO v_parent_id FROM public.products WHERE account_id = v_account_a AND name = '__gate_pib_padre__';
  SELECT id INTO v_variant_id FROM public.products WHERE account_id = v_account_a AND name = '__gate_pib_variante__';
  SELECT id INTO v_simple_id FROM public.products WHERE account_id = v_account_a AND name = '__gate_pib_simple__';

  IF v_parent_id IS NULL OR v_variant_id IS NULL OR v_simple_id IS NULL THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (3): no se encontraron los 3 productos esperados.';
  END IF;

  SELECT parent_id INTO v_variant_parent_id FROM public.products WHERE id = v_variant_id;
  IF v_variant_parent_id IS DISTINCT FROM v_parent_id THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (3): la variante no quedó vinculada al padre resuelto por sku_parent DENTRO del mismo lote.';
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.branch_stock WHERE product_id = v_variant_id AND quantity = 7;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (3): branch_stock de la variante no tiene la cantidad esperada (7).';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.product_categories WHERE account_id = v_account_a AND lower(name) = lower(v_cat_name)) THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (3): la categoría nueva no se creó.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_result->'new_categories') c
    WHERE lower(c->>'name') = lower(v_cat_name) AND (c->>'rows')::int = 1
  ) THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (3): new_categories del veredicto no anuncia "%%" con 1 fila. Resultado: %', v_result;
  END IF;

  RAISE NOTICE 'PASS (3): lote padre+variante+simple commitea entero — jerarquía resuelta, branch_stock, categoría creada y anunciada, import_id poblado.';
END $$;


-- ═══ (4) TOPE DE CATEGORÍAS sobre el ARCHIVO — P0400, no error de fila ══════
DO $$
DECLARE
  v_user_a uuid; v_account_a uuid;
  v_result jsonb; v_rows jsonb;
  v_before_categories integer; v_after_categories integer;
  v_raised boolean := false;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'product-import-batch-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (4): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (4): setup incompleto — degradando.'; RETURN; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (4): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  SELECT COUNT(*) INTO v_before_categories
  FROM public.product_categories
  WHERE account_id = v_account_a AND name LIKE '__gate_pib_cat4_%';

  -- 60 categorías nuevas distintas — la PRIMERA MITAD (30) por sí sola NO
  -- supera el tope de 50: si el tope se evaluara por sub-lote, entraría.
  SELECT jsonb_agg(jsonb_build_object(
    'row_no', g, 'name', '__gate_pib_cat4_prod_' || g || '__',
    'category', '__gate_pib_cat4_' || g || '__', 'price', 10
  )) INTO v_rows FROM generate_series(1, 60) g;

  BEGIN
    PERFORM public.rpc_import_products(
      'gate-pib-4-' || gen_random_uuid()::text, v_rows,
      'gate-pib-4.csv', 'gate-pib-4-hash-' || gen_random_uuid()::text
    );
  EXCEPTION WHEN SQLSTATE 'P0400' THEN
    v_raised := true;
  END;

  IF NOT v_raised THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (4): 60 categorías nuevas NO levantó P0400 — el tope tiene que evaluarse sobre el ARCHIVO entero.';
  END IF;

  SELECT COUNT(*) INTO v_after_categories
  FROM public.product_categories
  WHERE account_id = v_account_a AND name LIKE '__gate_pib_cat4_%';

  IF v_after_categories <> v_before_categories THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (4): product_categories pasó de % a % — CERO categorías de la "primera mitad" pueden quedar creadas.', v_before_categories, v_after_categories;
  END IF;

  RAISE NOTICE 'PASS (4): 60 categorías nuevas (con una primera mitad de 30, bajo el tope) rechazadas con P0400 sobre el ARCHIVO completo — cero creadas.';
END $$;


-- ═══ (5) ERROR ESTRUCTURAL — también aborta el lote entero ══════════════════
DO $$
DECLARE
  v_user_a uuid; v_account_a uuid;
  v_result jsonb; v_rows jsonb;
  v_before_products integer; v_after_products integer;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'product-import-batch-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (5): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (5): setup incompleto — degradando.'; RETURN; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (5): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  SELECT COUNT(*) INTO v_before_products FROM public.products WHERE account_id = v_account_a;

  -- `price` con un valor que no castea a numeric — error ESTRUCTURAL
  -- (22P02), no una regla de negocio del upsert.
  v_rows := jsonb_build_array(
    jsonb_build_object('row_no', 1, 'name', '__gate_pib_estructural_valido__', 'price', 100),
    jsonb_build_object('row_no', 2, 'name', '__gate_pib_estructural_malo__', 'price', 'no-es-un-numero')
  );

  v_result := public.rpc_import_products(
    'gate-pib-5-' || gen_random_uuid()::text, v_rows,
    'gate-pib-5.csv', 'gate-pib-5-hash-' || gen_random_uuid()::text
  );

  IF (v_result->>'committed')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (5): un error ESTRUCTURAL (price no numérico) no rechazó el lote. Resultado: %', v_result;
  END IF;
  IF jsonb_array_length(v_result->'errors') <> 1 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (5): errors tiene % elementos y esperaba 1. Resultado: %', jsonb_array_length(v_result->'errors'), v_result;
  END IF;
  IF (v_result->'errors'->0->>'row')::int <> 2 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (5): el error estructural no trae la fila 2. Resultado: %', v_result;
  END IF;

  SELECT COUNT(*) INTO v_after_products FROM public.products WHERE account_id = v_account_a;
  IF v_after_products <> v_before_products THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (5): products pasó de % a % — un error estructural TAMBIÉN tiene que dejar el lote sin ninguna escritura parcial.', v_before_products, v_after_products;
  END IF;

  RAISE NOTICE 'PASS (5): un error estructural (no de dominio) también aborta el lote entero, con su fila, sin escritura parcial.';
END $$;


-- ═══ (6) EQUIVALENCIA con la llamada directa (llamada anidada SECURITY DEFINER) ═
DO $$
DECLARE
  v_user_a uuid; v_account_a uuid;
  v_direct jsonb; v_result jsonb; v_rows_direct jsonb; v_rows_batch jsonb;
  v_direct_id uuid; v_batch_id uuid;
  v_row_direct RECORD; v_row_batch RECORD;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'product-import-batch-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (6): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (6): setup incompleto — degradando.'; RETURN; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (6): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  v_rows_direct := jsonb_build_array(jsonb_build_object('name', '__gate_pib_equiv_directo__', 'price', 4321, 'stock', 6));
  v_direct := public.rpc_bulk_upsert_products(v_rows_direct, v_user_a);
  SELECT id INTO v_direct_id FROM public.products WHERE account_id = v_account_a AND name = '__gate_pib_equiv_directo__';

  v_rows_batch := jsonb_build_array(jsonb_build_object('row_no', 1, 'name', '__gate_pib_equiv_lote__', 'price', 4321, 'stock', 6));
  v_result := public.rpc_import_products(
    'gate-pib-6-' || gen_random_uuid()::text, v_rows_batch,
    'gate-pib-6.csv', 'gate-pib-6-hash-' || gen_random_uuid()::text
  );
  SELECT id INTO v_batch_id FROM public.products WHERE account_id = v_account_a AND name = '__gate_pib_equiv_lote__';

  IF v_direct_id IS NULL OR v_batch_id IS NULL THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (6): no se crearon los dos productos de comparación.';
  END IF;

  SELECT account_id, price, is_variant INTO v_row_direct FROM public.products WHERE id = v_direct_id;
  SELECT account_id, price, is_variant INTO v_row_batch  FROM public.products WHERE id = v_batch_id;

  IF v_row_direct.account_id IS DISTINCT FROM v_row_batch.account_id
     OR v_row_direct.price IS DISTINCT FROM v_row_batch.price
     OR v_row_direct.is_variant IS DISTINCT FROM v_row_batch.is_variant THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (6): el producto directo y el del lote DIVERGEN — directo=% lote=% — la llamada anidada SECURITY DEFINER cambió la resolución.', v_row_direct, v_row_batch;
  END IF;

  IF (SELECT COUNT(*) FROM public.branch_stock WHERE product_id = v_direct_id)
     <> (SELECT COUNT(*) FROM public.branch_stock WHERE product_id = v_batch_id) THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (6): el conteo de filas de branch_stock difiere entre el directo y el del lote.';
  END IF;

  RAISE NOTICE 'PASS (6): el producto creado por el lote es equivalente al creado directo — auth.uid()/current_account_ids() resuelven igual anidados.';
END $$;


-- ═══════════════ (7) SIMULACIÓN (p_dry_run) — cero escrituras ══════════════
DO $$
DECLARE
  v_user_a uuid; v_account_a uuid;
  v_before_products integer; v_before_categories integer; v_before_stock integer;
  v_before_imports integer; v_before_idem integer;
  v_after_products integer; v_after_categories integer; v_after_stock integer;
  v_after_imports integer; v_after_idem integer;
  v_result jsonb; v_rows jsonb;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'product-import-batch-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (7): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (7): setup incompleto — degradando.'; RETURN; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (7): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  SELECT COUNT(*) INTO v_before_products FROM public.products WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_before_categories FROM public.product_categories WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_before_stock FROM public.branch_stock bs JOIN public.branches b ON b.id = bs.branch_id WHERE b.account_id = v_account_a;
  SELECT COUNT(*) INTO v_before_imports FROM public.product_imports WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_before_idem FROM public.operation_idempotency WHERE user_id = v_user_a;

  v_rows := jsonb_build_array(
    jsonb_build_object('row_no', 1, 'name', '__gate_pib_simulado__', 'price', 999, 'stock', 2, 'category', '__gate_pib_cat_simulada__')
  );
  v_result := public.rpc_import_products(
    'gate-pib-7-' || gen_random_uuid()::text, v_rows,
    'gate-pib-7.csv', 'gate-pib-7-hash-' || gen_random_uuid()::text,
    true -- p_dry_run
  );

  IF (v_result->>'committed')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (7): committed=% en modo simulación y esperaba false. Resultado: %', v_result->>'committed', v_result;
  END IF;
  IF (v_result->>'dry_run')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (7): dry_run=% y esperaba true.', v_result->>'dry_run';
  END IF;
  IF (v_result->>'inserted')::int <> 1 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (7): inserted=% y esperaba 1 (lo que SE HABRÍA importado). Resultado: %', v_result->>'inserted', v_result;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_result->'new_categories') c WHERE c->>'name' = '__gate_pib_cat_simulada__') THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (7): new_categories no anuncia la categoría que la simulación crearía. Resultado: %', v_result;
  END IF;

  SELECT COUNT(*) INTO v_after_products FROM public.products WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_after_categories FROM public.product_categories WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_after_stock FROM public.branch_stock bs JOIN public.branches b ON b.id = bs.branch_id WHERE b.account_id = v_account_a;
  SELECT COUNT(*) INTO v_after_imports FROM public.product_imports WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_after_idem FROM public.operation_idempotency WHERE user_id = v_user_a;

  IF v_after_products <> v_before_products OR v_after_categories <> v_before_categories
     OR v_after_stock <> v_before_stock OR v_after_imports <> v_before_imports
     OR v_after_idem <> v_before_idem THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (7): la simulación dejó escrituras — products %→%, categories %→%, stock %→%, imports %→%, idem %→%.',
      v_before_products, v_after_products, v_before_categories, v_after_categories,
      v_before_stock, v_after_stock, v_before_imports, v_after_imports, v_before_idem, v_after_idem;
  END IF;

  RAISE NOTICE 'PASS (7): p_dry_run ejecuta el mismo camino (incl. anuncio de categorías) y no deja NINGUNA escritura, ni siquiera el slot de idempotencia.';
END $$;


-- ═══════════════ (8) TENENCIA — sku_parent de OTRA cuenta ══════════════════
DO $$
DECLARE
  v_user_a uuid; v_account_a uuid; v_account_b uuid; v_user_b uuid;
  v_result jsonb; v_rows jsonb;
  v_before_products_a integer; v_after_products_a integer;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'product-import-batch-a@test.local';
  SELECT id INTO v_user_b FROM auth.users WHERE email = 'product-import-batch-b@test.local';
  IF v_user_a IS NULL OR v_user_b IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (8): sin anchors — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL OR v_account_b IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (8): setup incompleto — degradando.'; RETURN; END IF;

  -- Producto padre en B, con SKU — B es completamente ajena a A.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_b::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_b THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (8): auth.uid() de B no resuelve — degradando.'; RETURN; END IF;
  PERFORM public.rpc_bulk_upsert_products(
    jsonb_build_array(jsonb_build_object('name', '__gate_pib_padre_de_b__', 'sku', '__gate_pib_sku_de_b__')),
    v_user_b
  );

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (8): auth.uid() de A no resuelve — degradando.'; RETURN; END IF;

  SELECT COUNT(*) INTO v_before_products_a FROM public.products WHERE account_id = v_account_a;

  v_rows := jsonb_build_array(
    jsonb_build_object('row_no', 1, 'name', '__gate_pib_variante_cross_tenant__', 'sku_parent', '__gate_pib_sku_de_b__', 'is_variant', true)
  );
  v_result := public.rpc_import_products(
    'gate-pib-8-' || gen_random_uuid()::text, v_rows,
    'gate-pib-8.csv', 'gate-pib-8-hash-' || gen_random_uuid()::text
  );

  IF (v_result->>'committed')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (8): referenciar un SKU padre de OTRA cuenta NO rechazó el lote. Resultado: %', v_result;
  END IF;

  SELECT COUNT(*) INTO v_after_products_a FROM public.products WHERE account_id = v_account_a;
  IF v_after_products_a <> v_before_products_a THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (8): products de A pasó de % a % — la tenencia cruzada no puede escribir.', v_before_products_a, v_after_products_a;
  END IF;
  IF EXISTS (SELECT 1 FROM public.products WHERE account_id = v_account_b AND name = '__gate_pib_variante_cross_tenant__') THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (8): se escribió algo en la cuenta B ajena.';
  END IF;

  RAISE NOTICE 'PASS (8): un sku_parent de OTRA cuenta es error de fila, lote rechazado, nada escrito en ninguna cuenta.';
END $$;


-- ═══════════════ (9) ROL DE ESCRITURA — miembro de sólo lectura ════════════
DO $$
DECLARE
  v_user_reader uuid; v_account_a uuid;
  v_result jsonb; v_rows jsonb;
  v_before_products integer; v_after_products integer;
  v_raised boolean := false;
BEGIN
  SELECT id INTO v_user_reader FROM auth.users WHERE email = 'product-import-batch-reader@test.local';
  IF v_user_reader IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (9): sin anchor reader — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_reader AND role = 'member' LIMIT 1;
  IF v_account_a IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (9): setup incompleto (sin membresía de sólo lectura) — degradando.'; RETURN; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_reader::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_reader THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (9): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  SELECT COUNT(*) INTO v_before_products FROM public.products WHERE account_id = v_account_a;

  v_rows := jsonb_build_array(jsonb_build_object('row_no', 1, 'name', '__gate_pib_reader_intento__', 'price', 10));

  BEGIN
    v_result := public.rpc_import_products(
      'gate-pib-9-' || gen_random_uuid()::text, v_rows,
      'gate-pib-9.csv', 'gate-pib-9-hash-' || gen_random_uuid()::text
    );
  EXCEPTION WHEN SQLSTATE 'P0401' THEN
    v_raised := true;
  END;

  IF NOT v_raised THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (9): un miembro de SÓLO LECTURA pudo invocar rpc_import_products sin P0401.';
  END IF;

  SELECT COUNT(*) INTO v_after_products FROM public.products WHERE account_id = v_account_a;
  IF v_after_products <> v_before_products THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (9): products pasó de % a % — el guard de rol tiene que cortar ANTES de escribir.', v_before_products, v_after_products;
  END IF;

  RAISE NOTICE 'PASS (9): un miembro de sólo lectura no puede importar (P0401), cero escrituras.';
END $$;


-- ═══════════════ (10) TOPE DE FILAS — 2501 filas y lote vacío ══════════════
DO $$
DECLARE
  v_user_a uuid; v_account_a uuid;
  v_result jsonb; v_rows jsonb;
  v_before_products integer; v_after_products integer;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'product-import-batch-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (10): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (10): setup incompleto — degradando.'; RETURN; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (10): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  SELECT COUNT(*) INTO v_before_products FROM public.products WHERE account_id = v_account_a;

  SELECT jsonb_agg(jsonb_build_object('row_no', g, 'name', 'gate 10 fila ' || g, 'price', 1)) INTO v_rows
  FROM generate_series(1, 2501) g;

  BEGIN
    v_result := public.rpc_import_products(
      'gate-pib-10a-' || gen_random_uuid()::text, v_rows, 'gate-pib-10a.csv', 'gate-pib-10a-hash-' || gen_random_uuid()::text
    );
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (10.1): 2501 filas NO levantó excepción — el tope de 2500 tiene que rechazarse ANTES de escribir.';
  EXCEPTION WHEN SQLSTATE 'P0427' THEN
    RAISE NOTICE 'PASS (10.1): 2501 filas rechazadas con P0427, tal como se esperaba.';
  END;

  BEGIN
    v_result := public.rpc_import_products(
      'gate-pib-10b-' || gen_random_uuid()::text, '[]'::jsonb, 'gate-pib-10b.csv', 'gate-pib-10b-hash-' || gen_random_uuid()::text
    );
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (10.2): un lote vacío NO levantó excepción.';
  EXCEPTION WHEN SQLSTATE 'P0427' THEN
    RAISE NOTICE 'PASS (10.2): lote vacío rechazado con P0427.';
  END;

  SELECT COUNT(*) INTO v_after_products FROM public.products WHERE account_id = v_account_a;
  IF v_after_products <> v_before_products THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (10): products pasó de % a % — el tope se evalúa ANTES de cualquier escritura.', v_before_products, v_after_products;
  END IF;

  RAISE NOTICE 'PASS (10): tope de 2500 (bajado de 5000, OQ-2) y lote vacío, los dos con P0427 y cero escrituras.';
END $$;


-- ═══════════════ (11) IDEMPOTENCIA y DEDUPE ════════════════════════════════
DO $$
DECLARE
  v_user_a uuid; v_account_a uuid;
  v_key text := 'gate-pib-11-' || gen_random_uuid()::text;
  v_hash text := 'gate-pib-11-hash-' || gen_random_uuid()::text;
  v_rows jsonb; v_result1 jsonb; v_result2 jsonb; v_result3 jsonb;
  v_count_after_1 integer; v_count_after_2 integer;
  v_rejected_key text := 'gate-pib-11r-' || gen_random_uuid()::text;
  v_rejected_hash text := 'gate-pib-11r-hash-' || gen_random_uuid()::text;
  v_result_rej jsonb; v_result_retry jsonb;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'product-import-batch-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (11): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (11): setup incompleto — degradando.'; RETURN; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (11): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  v_rows := jsonb_build_array(jsonb_build_object('row_no', 1, 'name', '__gate_pib_idem__', 'price', 300));

  -- (11.1) misma clave dos veces → replay, sin duplicar
  v_result1 := public.rpc_import_products(v_key, v_rows, 'gate-pib-11.csv', v_hash);
  SELECT COUNT(*) INTO v_count_after_1 FROM public.products WHERE account_id = v_account_a AND name = '__gate_pib_idem__';
  IF (v_result1->>'committed')::boolean IS DISTINCT FROM true OR v_count_after_1 <> 1 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (11.1): el primer lote no commiteó como se esperaba. Resultado: %, count=%', v_result1, v_count_after_1;
  END IF;

  v_result2 := public.rpc_import_products(v_key, v_rows, 'gate-pib-11.csv', v_hash);
  IF (v_result2->>'replayed')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (11.1): reintentar con la MISMA clave no vino con replayed=true. Resultado: %', v_result2;
  END IF;
  SELECT COUNT(*) INTO v_count_after_2 FROM public.products WHERE account_id = v_account_a AND name = '__gate_pib_idem__';
  IF v_count_after_2 <> 1 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (11.1): el reintento con la misma clave DUPLICÓ el producto (count=%).', v_count_after_2;
  END IF;

  -- (11.1b) la MISMA clave, ahora en modo SIMULACIÓN → replay=true, y el
  -- veredicto tiene que decir dry_run=true (nunca false): si no, el paso 2
  -- del diálogo muestra un veredicto normal para un archivo que YA fue
  -- importado, y el usuario no se entera hasta después de confirmar.
  v_result2 := public.rpc_import_products(v_key, v_rows, 'gate-pib-11.csv', v_hash, true);
  IF (v_result2->>'replayed')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (11.1b): replay por CLAVE en modo simulación no vino con replayed=true. Resultado: %', v_result2;
  END IF;
  IF (v_result2->>'dry_run')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (11.1b): replay por CLAVE con p_dry_run=true devolvió dry_run=% (esperaba true) — el paso 2 del diálogo mostraría un veredicto normal para un archivo ya importado.', v_result2->>'dry_run';
  END IF;

  -- (11.2) mismo file_hash, OTRA clave → replay por dedupe de archivo
  v_result3 := public.rpc_import_products(
    'gate-pib-11-otra-clave-' || gen_random_uuid()::text, v_rows, 'gate-pib-11-otro-nombre.csv', v_hash
  );
  IF (v_result3->>'replayed')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (11.2): mismo file_hash con OTRA clave no vino con replayed=true (dedupe de archivo). Resultado: %', v_result3;
  END IF;

  -- (11.2b) mismo file_hash, OTRA clave, en modo SIMULACIÓN → mismo
  -- requisito que (11.1b) para la rama de dedupe por archivo (la otra mitad
  -- del hallazgo: L546-556 Y L582-592 del archivo de migración hardcodeaban
  -- 'dry_run', false).
  v_result3 := public.rpc_import_products(
    'gate-pib-11-otra-clave-dry-' || gen_random_uuid()::text, v_rows, 'gate-pib-11-otro-nombre-dry.csv', v_hash, true
  );
  IF (v_result3->>'replayed')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (11.2b): dedupe por HASH en modo simulación no vino con replayed=true. Resultado: %', v_result3;
  END IF;
  IF (v_result3->>'dry_run')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (11.2b): dedupe por HASH con p_dry_run=true devolvió dry_run=% (esperaba true).', v_result3->>'dry_run';
  END IF;

  -- (11.3) un lote RECHAZADO no quema la clave ni el hash — corregir y
  -- reintentar tiene que funcionar.
  v_result_rej := public.rpc_import_products(
    v_rejected_key,
    jsonb_build_array(
      jsonb_build_object('row_no', 1, 'name', '__gate_pib_11r_ok__', 'price', 50),
      jsonb_build_object('row_no', 2, 'name', '__gate_pib_11r_malo__', 'sku_parent', '__gate_pib_11r_padre_inexistente__', 'is_variant', true)
    ),
    'gate-pib-11r.csv', v_rejected_hash
  );
  IF (v_result_rej->>'committed')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (11.3): el lote de setup no se rechazó como se esperaba. Resultado: %', v_result_rej;
  END IF;

  -- Reintentar con la MISMA clave y hash, ahora con el archivo corregido —
  -- tiene que APLICARSE (no ser tratado como replay ni bloquearse).
  v_result_retry := public.rpc_import_products(
    v_rejected_key,
    jsonb_build_array(jsonb_build_object('row_no', 1, 'name', '__gate_pib_11r_ok__', 'price', 50)),
    'gate-pib-11r.csv', v_rejected_hash
  );
  IF (v_result_retry->>'committed')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (11.3): corregir el archivo y reintentar con la MISMA clave/hash no se aplicó. Resultado: %', v_result_retry;
  END IF;
  IF (v_result_retry->>'replayed')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (11.3): el reintento post-rechazo se marcó como replayed — tiene que ser un lote NUEVO.';
  END IF;

  RAISE NOTICE 'PASS (11): idempotencia por clave, dedupe por archivo, y un lote rechazado no quema ni la clave ni el hash.';
END $$;


-- ═══════════════ (12) ACLs ══════════════════════════════════════════════════
DO $$
DECLARE
  v_has_anon_execute_import boolean;
  v_has_authenticated_execute_import boolean;
  v_has_authenticated_insert boolean;
  v_has_authenticated_execute_bulk boolean;
  v_has_anon_execute_bulk boolean;
  v_has_service_execute_bulk boolean;
BEGIN
  SELECT has_function_privilege('anon', 'public.rpc_import_products(text,jsonb,text,text,boolean)', 'EXECUTE')
    INTO v_has_anon_execute_import;
  IF v_has_anon_execute_import THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (12): anon TIENE EXECUTE sobre rpc_import_products.';
  END IF;

  SELECT has_function_privilege('authenticated', 'public.rpc_import_products(text,jsonb,text,text,boolean)', 'EXECUTE')
    INTO v_has_authenticated_execute_import;
  IF NOT v_has_authenticated_execute_import THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (12): authenticated NO tiene EXECUTE sobre rpc_import_products.';
  END IF;

  SELECT has_table_privilege('authenticated', 'public.product_imports', 'INSERT') INTO v_has_authenticated_insert;
  IF v_has_authenticated_insert THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (12): authenticated TIENE INSERT sobre product_imports — la escritura debe ser exclusiva de la RPC SECURITY DEFINER.';
  END IF;

  SELECT has_function_privilege('authenticated', 'public.rpc_bulk_upsert_products(jsonb,uuid)', 'EXECUTE')
    INTO v_has_authenticated_execute_bulk;
  IF v_has_authenticated_execute_bulk THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (12): authenticated TODAVÍA TIENE EXECUTE sobre rpc_bulk_upsert_products — D4/OQ-7 exige el REVOKE.';
  END IF;

  SELECT has_function_privilege('anon', 'public.rpc_bulk_upsert_products(jsonb,uuid)', 'EXECUTE')
    INTO v_has_anon_execute_bulk;
  IF v_has_anon_execute_bulk THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (12): anon TIENE EXECUTE sobre rpc_bulk_upsert_products.';
  END IF;

  SELECT has_function_privilege('service_role', 'public.rpc_bulk_upsert_products(jsonb,uuid)', 'EXECUTE')
    INTO v_has_service_execute_bulk;
  IF NOT v_has_service_execute_bulk THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (12): service_role PERDIÓ EXECUTE sobre rpc_bulk_upsert_products — los jobs administrativos no deben verse afectados.';
  END IF;

  RAISE NOTICE 'PASS (12): ACLs correctas — rpc_import_products (authenticated sí, anon no), product_imports sin INSERT para authenticated, rpc_bulk_upsert_products revocada de authenticated/anon con service_role intacto.';
END $$;


-- ═══════════════ (13) CUENTA AMBIGUA — usuario de DOS cuentas (F1, ronda 3) ═
-- Corrección de revisión: `ORDER BY cai` sumado SÓLO al guard (y no también
-- a la resolución de rpc_bulk_upsert_products) hacía que las dos
-- resoluciones DIVERGIERAN para un usuario multi-cuenta — regresión real
-- (P0401 sobre un owner legítimo), no el candidato documentado que se creyó.
-- Fix: la resolución vuelve a ser la MISMA consulta sin ORDER BY, MÁS un
-- rechazo explícito de la ambigüedad (P0403) cuando el usuario pertenece a
-- más de una cuenta — la importación en lote no tiene selector de cuenta.
DO $$
DECLARE
  v_user_multi     uuid;
  v_account_a      uuid;
  v_account_own    uuid;
  v_result         jsonb; v_rows jsonb;
  v_before_a       integer; v_after_a       integer;
  v_before_own     integer; v_after_own     integer;
  v_raised         boolean := false;
BEGIN
  SELECT id INTO v_user_multi FROM auth.users WHERE email = 'product-import-batch-multi@test.local';
  IF v_user_multi IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (13): sin anchor multi — degradando.'; RETURN; END IF;

  -- La cuenta A es la del anchor A (mismo criterio que el resto del gate);
  -- el setup agregó a v_user_multi ahí como segunda membresía.
  SELECT am_a.account_id INTO v_account_a
  FROM auth.users u_a
  JOIN public.account_members am_a ON am_a.user_id = u_a.id
  WHERE u_a.email = 'product-import-batch-a@test.local'
  ORDER BY am_a.created_at
  LIMIT 1;

  SELECT account_id INTO v_account_own FROM public.account_members
   WHERE user_id = v_user_multi AND account_id IS DISTINCT FROM v_account_a
   LIMIT 1;

  IF v_account_a IS NULL OR v_account_own IS NULL THEN
    RAISE NOTICE 'GATE PRODUCT-IMPORT (13): setup incompleto (usuario no tiene dos membresías) — degradando.'; RETURN;
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_multi::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_multi THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (13): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  SELECT COUNT(*) INTO v_before_a   FROM public.products WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_before_own FROM public.products WHERE account_id = v_account_own;

  v_rows := jsonb_build_array(jsonb_build_object('row_no', 1, 'name', '__gate_pib_multi_intento__', 'price', 10));

  BEGIN
    v_result := public.rpc_import_products(
      'gate-pib-13-' || gen_random_uuid()::text, v_rows,
      'gate-pib-13.csv', 'gate-pib-13-hash-' || gen_random_uuid()::text
    );
  EXCEPTION WHEN SQLSTATE 'P0403' THEN
    v_raised := true;
  END;

  IF NOT v_raised THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (13): un usuario miembro de DOS cuentas pudo invocar rpc_import_products sin P0403 (cuenta ambigua).';
  END IF;

  SELECT COUNT(*) INTO v_after_a   FROM public.products WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_after_own FROM public.products WHERE account_id = v_account_own;

  IF v_after_a <> v_before_a THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (13): products de la cuenta A pasó de % a % — el guard de ambigüedad tiene que cortar ANTES de escribir en NINGUNA cuenta.', v_before_a, v_after_a;
  END IF;
  IF v_after_own <> v_before_own THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (13): products de la cuenta propia pasó de % a % — mismo motivo.', v_before_own, v_after_own;
  END IF;

  RAISE NOTICE 'PASS (13): un usuario de DOS cuentas no puede importar (P0403, cuenta ambigua), cero escrituras en ninguna de las dos.';
END $$;


-- ═══════════════ (13b) CUENTA ÚNICA sigue funcionando — control positivo ════
DO $$
DECLARE
  v_user_a uuid; v_account_a uuid;
  v_result jsonb; v_rows jsonb;
  v_before integer; v_after integer;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'product-import-batch-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (13b): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (13b): setup incompleto — degradando.'; RETURN; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (13b): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  SELECT COUNT(*) INTO v_before FROM public.products WHERE account_id = v_account_a;

  v_rows := jsonb_build_array(jsonb_build_object('row_no', 1, 'name', '__gate_pib_13b_unica__', 'price', 10, 'stock', 1));

  v_result := public.rpc_import_products(
    'gate-pib-13b-' || gen_random_uuid()::text, v_rows,
    'gate-pib-13b.csv', 'gate-pib-13b-hash-' || gen_random_uuid()::text
  );

  IF (v_result->>'committed')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (13b): un usuario de UNA sola cuenta no pudo importar. Resultado: %', v_result;
  END IF;

  SELECT COUNT(*) INTO v_after FROM public.products WHERE account_id = v_account_a;
  IF v_after <> v_before + 1 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (13b): products pasó de % a % y esperaba +1.', v_before, v_after;
  END IF;

  RAISE NOTICE 'PASS (13b): un usuario de UNA sola cuenta sigue importando sin problema (control positivo, sin regresión).';
END $$;


-- ═══ (14) CATEGORÍAS NUEVAS case-insensitive en el anuncio (F2, ronda 3) ════
-- El anuncio de new_categories agrupaba por el nombre normalizado SIN bajar
-- a minúsculas: "Zapatillas"/"zapatillas"/"ZAPATILLAS" en el mismo archivo
-- se anunciaban como 3 categorías nuevas cuando el upsert (case-insensitive,
-- igual que este gate lo verifica) crea 1 sola. Corregido a agrupar por
-- lower(...), con nombre canónico min(...) y suma de filas.
DO $$
DECLARE
  v_user_a uuid; v_account_a uuid;
  v_result jsonb; v_rows jsonb;
  v_new_categories jsonb;
  v_real_count integer;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'product-import-batch-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (14): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (14): setup incompleto — degradando.'; RETURN; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN RAISE NOTICE 'GATE PRODUCT-IMPORT (14): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  v_rows := jsonb_build_array(
    jsonb_build_object('row_no', 1, 'name', '__gate_pib_14_a__', 'price', 10, 'category', '__gate_pib_14_Zapatillas__'),
    jsonb_build_object('row_no', 2, 'name', '__gate_pib_14_b__', 'price', 20, 'category', '__gate_pib_14_zapatillas__'),
    jsonb_build_object('row_no', 3, 'name', '__gate_pib_14_c__', 'price', 30, 'category', '__gate_pib_14_ZAPATILLAS__')
  );

  v_result := public.rpc_import_products(
    'gate-pib-14-' || gen_random_uuid()::text, v_rows,
    'gate-pib-14.csv', 'gate-pib-14-hash-' || gen_random_uuid()::text
  );

  IF (v_result->>'committed')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (14): committed=% y esperaba true. Resultado: %', v_result->>'committed', v_result;
  END IF;

  v_new_categories := v_result->'new_categories';
  IF jsonb_array_length(v_new_categories) <> 1 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (14): new_categories anunció % categorías y esperaba 1 (3 variantes de capitalización de la MISMA categoría). Resultado: %', jsonb_array_length(v_new_categories), v_new_categories;
  END IF;
  IF (v_new_categories->0->>'rows')::int <> 3 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (14): la categoría anunciada trae % filas y esperaba 3 (suma de las 3 variantes). Resultado: %', v_new_categories->0->>'rows', v_new_categories;
  END IF;

  SELECT COUNT(*) INTO v_real_count
  FROM public.product_categories
  WHERE account_id = v_account_a
    AND lower(name) = lower('__gate_pib_14_zapatillas__')
    AND deleted_at IS NULL;

  IF v_real_count <> 1 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT FAILED (14): el upsert creó % categorías reales con ese nombre (case-insensitive) y esperaba 1 — el anuncio y la realidad tienen que COINCIDIR.', v_real_count;
  END IF;

  RAISE NOTICE 'PASS (14): 3 variantes de capitalización de la misma categoría se anuncian como 1 sola (rows=3), coincidiendo con las % categorías reales que crea el upsert.', v_real_count;
END $$;


-- @@CLEANUP@@
DO $$
DECLARE
  v_emails   text[] := ARRAY[
    'product-import-batch-a@test.local', 'product-import-batch-b@test.local',
    'product-import-batch-reader@test.local', 'product-import-batch-multi@test.local'
  ];
  v_users    uuid[];
  v_accounts uuid[];
BEGIN
  SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) INTO v_users FROM auth.users WHERE email = ANY(v_emails);
  IF array_length(v_users, 1) IS NULL THEN
    RAISE NOTICE 'GATE PRODUCT-IMPORT: cleanup sin anchors que limpiar.';
    RETURN;
  END IF;

  SELECT COALESCE(array_agg(DISTINCT a), ARRAY[]::uuid[]) INTO v_accounts
  FROM (
    SELECT account_id AS a FROM public.account_members WHERE user_id = ANY(v_users)
    UNION
    SELECT id         AS a FROM public.accounts        WHERE owner_user_id = ANY(v_users)
  ) x;

  IF array_length(v_accounts, 1) IS NOT NULL THEN
    DELETE FROM public.product_attributes pa USING public.products p
      WHERE pa.product_id = p.id AND p.account_id = ANY(v_accounts);
    DELETE FROM public.branch_stock bs USING public.products p
      WHERE bs.product_id = p.id AND p.account_id = ANY(v_accounts);
    DELETE FROM public.products WHERE account_id = ANY(v_accounts);
    DELETE FROM public.product_categories WHERE account_id = ANY(v_accounts) AND name LIKE '__gate_pib_%';
    DELETE FROM public.product_imports WHERE account_id = ANY(v_accounts);
  END IF;

  DELETE FROM public.operation_idempotency WHERE user_id = ANY(v_users);
  DELETE FROM public.account_members       WHERE user_id = ANY(v_users);
  SET session_replication_role = replica;
  DELETE FROM public.accounts              WHERE owner_user_id = ANY(v_users);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.profiles              WHERE id = ANY(v_users);
  DELETE FROM public.email_logs            WHERE user_id = ANY(v_users) OR recipient = ANY(v_emails);
  DELETE FROM auth.users                   WHERE id = ANY(v_users);

  RAISE NOTICE 'GATE PRODUCT-IMPORT: cleanup completo (% anchors) — el gate vuelve a correr en verde sobre la misma base.', array_length(v_users, 1);
END $$;
