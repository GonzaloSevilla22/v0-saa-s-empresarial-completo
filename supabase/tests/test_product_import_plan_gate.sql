-- =============================================================================
-- GATE: test_product_import_plan_gate.sql
-- CHANGE: importador-gate-plan (cierra OQ-1 / task 4.7 de
--         importador-productos-fastapi, sign-off del PO 2026-09-11)
--
-- `rpc_import_products` gana el límite de productos del plan, evaluado
-- SIEMPRE sobre el estado RESULTANTE (después de invocar
-- rpc_bulk_upsert_products, nunca a priori — D5 del design archivado).
-- Regla EXACTA del PO: "las cuentas que hoy superan el máximo de su plan
-- conservan sus productos, pero no pueden agregar más; si quieren agregar,
-- tienen que eliminar productos hasta no exceder el máximo de su plan".
--
-- Qué ejercita, con 6 tenants sintéticos (uno por escenario, salvo b/c que
-- comparten cuenta porque (c) depende del estado que (b) deja):
--
--   (a) EXACTO en el tope (gratis, 100) + 1 nuevo → BLOQUEADO, cero
--       escrituras, plan.exceeded=true con los 4 conteos.
--   (b) POR ENCIMA del tope (105) + import que SÓLO actualiza SKUs
--       existentes → PASA (no agrega, nunca se bloquea aunque ya esté
--       excedida).
--   (c) la MISMA cuenta de (b), ahora + 1 fila NUEVA → BLOQUEADO.
--   (d) 98 + 2 nuevos → PASA, llega EXACTO a 100 (no es > 100).
--   (e) 98 (cuenta DISTINTA de (d)) + 3 nuevos → BLOQUEADO (101 > 100).
--   (f) DRY RUN del mismo archivo de (a) → mismo veredicto, cero escrituras
--       (ya lo eran por ser (a) un lote rechazado; se re-verifica explícito
--       en modo simulación).
--   (g) 95 vivos + 10 soft-deleted (105 si el predicado los contara) + 3
--       nuevos → PASA (98 vivos reales, nunca ve el 105) — control negativo
--       del predicado de "vivo" (deleted_at IS NULL, D1 del CHANGES.md).
--   (h) plan PRO (tope 5.000) con 200 productos + 50 nuevos → PASA (250 muy
--       por debajo de 5.000, aunque ya esté por encima del tope de gratis).
--   (i) ACL de rpc_import_products intacta + una sola definición viva (esta
--       migración modifica su CUERPO, no su firma ni sus permisos).
--   (j) Corrección de revisión (ronda 1 adversarial, nit): repite (a) bajo
--       `SET LOCAL ROLE authenticated` — el camino REAL de prod desde
--       v31-tenancy-pool-rls Paso 2 (el resto de este gate corre como
--       `postgres`, que nunca necesita GRANT). Confirma que el veredicto de
--       plan no depende de un GRANT faltante sobre get_effective_plan/
--       plan_limits (SECURITY DEFINER owner postgres, no requiere EXECUTE).
--   (k) Corrección de revisión (ronda 1 adversarial, nit): el gate SOLO
--       bloquea si `v_limit IS NOT NULL` — si un plan del CHECK de
--       billing_plan/trial_plan quedara sin fila en plan_limits, el gate se
--       apagaría en silencio (fail-open) para ese plan. Assertea que los 4
--       valores del CHECK tienen fila en plan_limits.
--
-- ⚠️ REGLA DE ESTE GATE: se asserta el EFECTO (conteos reales antes/después,
-- el objeto 'plan' completo del veredicto), nunca "no hubo error".
--
-- Corrección de revisión (ronda 1 adversarial, MAJOR — TOCTOU): el finding
-- que motivó el advisory lock en la migración (dos lotes concurrentes sobre
-- la MISMA cuenta pasaban ambos el gate bajo READ COMMITTED, dejando la
-- cuenta por encima del tope) se reprodujo y verificó por FUERA de este
-- gate — con dos sesiones psql reales solapadas, no es reproducible dentro
-- de un único script — así que este archivo no lo ejercita directamente.
--
-- Degrade-don't-fail: si un anchor sintético no resuelve auth.uid() bajo
-- request.jwt.claims local, el bloque emite NOTICE y no aborta (mismo
-- criterio que test_product_import_batch.sql).
--
-- Contador de bloques ejecutados (patrón del repo, ver
-- test_operacion_party_guard.sql): degrade-don't-fail no puede reportarse
-- verde a mitad de camino sin que nada lo note. Cada escenario que llega a
-- su PASS deja constancia en `gate_pipg_progress`; el bloque final assertea
-- que los 11 (a-k) quedaron ejercitados de verdad, no sólo "sin error".
-- =============================================================================

CREATE TEMP TABLE IF NOT EXISTS gate_pipg_progress (block text PRIMARY KEY);
-- (j) corre bajo `SET LOCAL ROLE authenticated` — sin este GRANT (acotado a
-- esta tabla TEMP de la sesión del gate, nunca a una tabla real) el INSERT
-- de su propio PASS falla con "permission denied for table
-- gate_pipg_progress" antes de poder registrar el bloque.
GRANT INSERT, SELECT ON gate_pipg_progress TO authenticated;


-- ═══════════════════════ (setup) fixtures — 6 tenants ═══════════════════════
DO $$
DECLARE
  v_email_a  text := 'product-import-plan-gate-a@test.local';
  v_email_bc text := 'product-import-plan-gate-bc@test.local';
  v_email_d  text := 'product-import-plan-gate-d@test.local';
  v_email_e  text := 'product-import-plan-gate-e@test.local';
  v_email_g  text := 'product-import-plan-gate-g@test.local';
  v_email_h  text := 'product-import-plan-gate-h@test.local';
  v_user_a   uuid := gen_random_uuid();
  v_user_bc  uuid := gen_random_uuid();
  v_user_d   uuid := gen_random_uuid();
  v_user_e   uuid := gen_random_uuid();
  v_user_g   uuid := gen_random_uuid();
  v_user_h   uuid := gen_random_uuid();
  v_account_a  uuid;
  v_account_bc uuid;
  v_account_d  uuid;
  v_account_e  uuid;
  v_account_g  uuid;
  v_account_h  uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES
    (v_user_a,  'authenticated', 'authenticated', v_email_a,  now(), now(), jsonb_build_object('name', 'Gate Plan Import A')),
    (v_user_bc, 'authenticated', 'authenticated', v_email_bc, now(), now(), jsonb_build_object('name', 'Gate Plan Import BC')),
    (v_user_d,  'authenticated', 'authenticated', v_email_d,  now(), now(), jsonb_build_object('name', 'Gate Plan Import D')),
    (v_user_e,  'authenticated', 'authenticated', v_email_e,  now(), now(), jsonb_build_object('name', 'Gate Plan Import E')),
    (v_user_g,  'authenticated', 'authenticated', v_email_g,  now(), now(), jsonb_build_object('name', 'Gate Plan Import G')),
    (v_user_h,  'authenticated', 'authenticated', v_email_h,  now(), now(), jsonb_build_object('name', 'Gate Plan Import H'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a  FROM public.account_members WHERE user_id = v_user_a  ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_bc FROM public.account_members WHERE user_id = v_user_bc ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_d  FROM public.account_members WHERE user_id = v_user_d  ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_e  FROM public.account_members WHERE user_id = v_user_e  ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_g  FROM public.account_members WHERE user_id = v_user_g  ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_h  FROM public.account_members WHERE user_id = v_user_h  ORDER BY created_at LIMIT 1;

  IF v_account_a IS NULL OR v_account_bc IS NULL OR v_account_d IS NULL
     OR v_account_e IS NULL OR v_account_g IS NULL OR v_account_h IS NULL THEN
    RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN (setup): no se pudieron provisionar los 6 tenants — degradando sin abortar.';
    RETURN;
  END IF;

  -- (a)/(bc)/(d)/(e)/(g): plan GRATIS explícito (tope 100) — el trigger de
  -- alta ya deja trial_plan='pro' por 30 días (billing-pro-trial); sin
  -- anularlo, get_effective_plan resolvería 'pro' (tope 5000) y ningún
  -- escenario de bloqueo reproduciría.
  UPDATE public.accounts
     SET billing_plan = 'gratis', trial_plan = NULL, trial_expires_at = NULL
   WHERE id IN (v_account_a, v_account_bc, v_account_d, v_account_e, v_account_g);

  -- (h): plan PRO explícito (tope 5000) — no se depende del trial por
  -- defecto (30 días) para no acoplar este gate a esa ventana.
  UPDATE public.accounts
     SET billing_plan = 'pro', billing_status = 'active', trial_plan = NULL, trial_expires_at = NULL
   WHERE id = v_account_h;

  -- Baseline (a): EXACTO en el tope de gratis (100 vivos).
  INSERT INTO public.products (user_id, account_id, name, price)
  SELECT v_user_a, v_account_a, '__gate_pipg_seed_a_' || g || '__', 10
  FROM generate_series(1, 100) g;

  -- Baseline (b)/(c): POR ENCIMA del tope (105 vivos), CON sku — (b)
  -- necesita SKUs existentes para poder actualizar sin agregar.
  INSERT INTO public.products (user_id, account_id, name, price, sku)
  SELECT v_user_bc, v_account_bc, '__gate_pipg_seed_bc_' || g || '__', 10, 'GATE-PIPG-BC-' || g
  FROM generate_series(1, 105) g;

  -- Baseline (d): 98 vivos, cuenta propia (queda en 100 tras el escenario).
  INSERT INTO public.products (user_id, account_id, name, price)
  SELECT v_user_d, v_account_d, '__gate_pipg_seed_d_' || g || '__', 10
  FROM generate_series(1, 98) g;

  -- Baseline (e): 98 vivos, cuenta DISTINTA de (d) — (d) pasa a 100 y (e)
  -- tiene que seguir en 98 para poder probar el bloqueo con 3 nuevos.
  INSERT INTO public.products (user_id, account_id, name, price)
  SELECT v_user_e, v_account_e, '__gate_pipg_seed_e_' || g || '__', 10
  FROM generate_series(1, 98) g;

  -- Baseline (g): 95 VIVOS + 10 SOFT-DELETED — si el predicado contara los
  -- borrados, "antes" mediría 105 (ya excedido); con el predicado correcto
  -- (deleted_at IS NULL) mide 95.
  INSERT INTO public.products (user_id, account_id, name, price)
  SELECT v_user_g, v_account_g, '__gate_pipg_seed_g_live_' || g || '__', 10
  FROM generate_series(1, 95) g;

  INSERT INTO public.products (user_id, account_id, name, price, deleted_at, deleted_by)
  SELECT v_user_g, v_account_g, '__gate_pipg_seed_g_deleted_' || g || '__', 10, now(), v_user_g
  FROM generate_series(1, 10) g;

  -- Baseline (h): 200 vivos en cuenta PRO — ya por encima del tope de
  -- gratis (100) pero muy por debajo del de pro (5000).
  INSERT INTO public.products (user_id, account_id, name, price)
  SELECT v_user_h, v_account_h, '__gate_pipg_seed_h_' || g || '__', 10
  FROM generate_series(1, 200) g;

  RAISE NOTICE 'SETUP OK: 6 tenants (a=100 exacto, bc=105 con sku, d=98, e=98, g=95vivos+10borrados, h=200 pro).';
END $$;


-- ═══ (a) EXACTO en el tope (gratis, 100) + 1 nuevo → BLOQUEADO ═════════════
DO $$
DECLARE
  v_user_a uuid; v_account_a uuid;
  v_result jsonb; v_rows jsonb; v_plan jsonb;
  v_before_products integer; v_after_products integer;
  v_before_imports integer; v_after_imports integer;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'product-import-plan-gate-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN (a): sin anchor — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN (a): setup incompleto — degradando.'; RETURN; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN (a): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  SELECT COUNT(*) INTO v_before_products FROM public.products WHERE account_id = v_account_a AND deleted_at IS NULL;
  SELECT COUNT(*) INTO v_before_imports  FROM public.product_imports WHERE account_id = v_account_a;
  IF v_before_products <> 100 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (a): baseline tiene % productos vivos y esperaba EXACTO 100.', v_before_products;
  END IF;

  v_rows := jsonb_build_array(jsonb_build_object('row_no', 1, 'name', '__gate_pipg_a_nuevo__', 'price', 50));
  v_result := public.rpc_import_products(
    'gate-pipg-a-' || gen_random_uuid()::text, v_rows,
    'gate-pipg-a.csv', 'gate-pipg-a-hash-' || gen_random_uuid()::text
  );

  IF (v_result->>'committed')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (a): committed=% y esperaba false (100/100 + 1 nuevo excede el tope). Resultado: %', v_result->>'committed', v_result;
  END IF;

  v_plan := v_result->'plan';
  IF v_plan IS NULL OR jsonb_typeof(v_plan) <> 'object' THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (a): el veredicto no trae el objeto "plan". Resultado: %', v_result;
  END IF;
  IF (v_plan->>'exceeded')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (a): plan.exceeded=% y esperaba true. plan: %', v_plan->>'exceeded', v_plan;
  END IF;
  IF v_plan->>'plan' <> 'gratis' THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (a): plan.plan="%" y esperaba "gratis". plan: %', v_plan->>'plan', v_plan;
  END IF;
  IF (v_plan->>'limit')::int <> 100 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (a): plan.limit=% y esperaba 100. plan: %', v_plan->>'limit', v_plan;
  END IF;
  IF (v_plan->>'before')::int <> 100 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (a): plan.before=% y esperaba 100. plan: %', v_plan->>'before', v_plan;
  END IF;
  IF (v_plan->>'after')::int <> 101 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (a): plan.after=% y esperaba 101. plan: %', v_plan->>'after', v_plan;
  END IF;
  IF (v_plan->>'added')::int <> 1 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (a): plan.added=% y esperaba 1. plan: %', v_plan->>'added', v_plan;
  END IF;

  SELECT COUNT(*) INTO v_after_products FROM public.products WHERE account_id = v_account_a AND deleted_at IS NULL;
  SELECT COUNT(*) INTO v_after_imports  FROM public.product_imports WHERE account_id = v_account_a;
  IF v_after_products <> v_before_products THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (a): products vivos pasó de % a % — un lote bloqueado por plan NO puede escribir NADA (regla del PO: "conservan sus productos").', v_before_products, v_after_products;
  END IF;
  IF v_after_imports <> v_before_imports THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (a): product_imports pasó de % a % — un lote bloqueado no deja fila de importación.', v_before_imports, v_after_imports;
  END IF;

  INSERT INTO gate_pipg_progress VALUES ('a') ON CONFLICT DO NOTHING;
  RAISE NOTICE 'PASS (a): cuenta EXACTO en el tope (100/100, gratis) + 1 nuevo → BLOQUEADO, cero escrituras, veredicto completo (before=100, after=101, limit=100, added=1, exceeded=true).';
END $$;


-- ═══ (f) DRY RUN del mismo archivo de (a) → mismo veredicto, cero escrituras
DO $$
DECLARE
  v_user_a uuid; v_account_a uuid;
  v_result jsonb; v_rows jsonb; v_plan jsonb;
  v_before_products integer; v_after_products integer;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'product-import-plan-gate-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN (f): sin anchor — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN (f): setup incompleto — degradando.'; RETURN; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN (f): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  -- (a) dejó la cuenta EXACTO en 100 (bloqueada, cero escrituras) — la
  -- vista previa (dry_run) del MISMO archivo tiene que ver el mismo estado
  -- y anunciar el mismo veredicto, sin escribir tampoco.
  SELECT COUNT(*) INTO v_before_products FROM public.products WHERE account_id = v_account_a AND deleted_at IS NULL;
  IF v_before_products <> 100 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (f): la cuenta de (a) tiene % productos vivos y esperaba 100 (el escenario (a) no debería haber escrito nada).', v_before_products;
  END IF;

  v_rows := jsonb_build_array(jsonb_build_object('row_no', 1, 'name', '__gate_pipg_f_nuevo__', 'price', 50));
  v_result := public.rpc_import_products(
    'gate-pipg-f-' || gen_random_uuid()::text, v_rows,
    'gate-pipg-f.csv', 'gate-pipg-f-hash-' || gen_random_uuid()::text,
    true -- p_dry_run
  );

  IF (v_result->>'committed')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (f): committed=% en modo simulación y esperaba false. Resultado: %', v_result->>'committed', v_result;
  END IF;
  IF (v_result->>'dry_run')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (f): dry_run=% y esperaba true.', v_result->>'dry_run';
  END IF;

  v_plan := v_result->'plan';
  IF (v_plan->>'exceeded')::boolean IS DISTINCT FROM true
     OR (v_plan->>'before')::int <> 100 OR (v_plan->>'after')::int <> 101
     OR (v_plan->>'added')::int <> 1 OR (v_plan->>'limit')::int <> 100 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (f): el veredicto de plan en dry_run no coincide con el de (a). plan: %', v_plan;
  END IF;

  SELECT COUNT(*) INTO v_after_products FROM public.products WHERE account_id = v_account_a AND deleted_at IS NULL;
  IF v_after_products <> v_before_products THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (f): products vivos pasó de % a % — la simulación no puede escribir NADA.', v_before_products, v_after_products;
  END IF;

  INSERT INTO gate_pipg_progress VALUES ('f') ON CONFLICT DO NOTHING;
  RAISE NOTICE 'PASS (f): dry_run del mismo archivo de (a) informa el MISMO veredicto de plan (before=100, after=101, exceeded=true), cero escrituras.';
END $$;


-- ═══ (b) POR ENCIMA del tope (105) + SÓLO actualizaciones → PASA ═══════════
DO $$
DECLARE
  v_user_bc uuid; v_account_bc uuid;
  v_result jsonb; v_rows jsonb; v_plan jsonb;
  v_before_products integer; v_after_products integer;
  v_updated_price numeric;
BEGIN
  SELECT id INTO v_user_bc FROM auth.users WHERE email = 'product-import-plan-gate-bc@test.local';
  IF v_user_bc IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN (b): sin anchor — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_bc FROM public.account_members WHERE user_id = v_user_bc ORDER BY created_at LIMIT 1;
  IF v_account_bc IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN (b): setup incompleto — degradando.'; RETURN; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_bc::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_bc THEN RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN (b): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  SELECT COUNT(*) INTO v_before_products FROM public.products WHERE account_id = v_account_bc AND deleted_at IS NULL;
  IF v_before_products <> 105 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (b): baseline tiene % productos vivos y esperaba EXACTO 105 (ya excedida).', v_before_products;
  END IF;

  -- 3 filas, las 3 con SKU YA EXISTENTE (actualización pura) — ninguna fila
  -- nueva, aunque la cuenta ya esté 5 por encima del tope de 100.
  v_rows := jsonb_build_array(
    jsonb_build_object('row_no', 1, 'sku', 'GATE-PIPG-BC-1', 'name', '__gate_pipg_seed_bc_1__', 'price', 999),
    jsonb_build_object('row_no', 2, 'sku', 'GATE-PIPG-BC-2', 'name', '__gate_pipg_seed_bc_2__', 'price', 999),
    jsonb_build_object('row_no', 3, 'sku', 'GATE-PIPG-BC-3', 'name', '__gate_pipg_seed_bc_3__', 'price', 999)
  );
  v_result := public.rpc_import_products(
    'gate-pipg-b-' || gen_random_uuid()::text, v_rows,
    'gate-pipg-b.csv', 'gate-pipg-b-hash-' || gen_random_uuid()::text
  );

  IF (v_result->>'committed')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (b): committed=% y esperaba true — una importación que SÓLO actualiza NUNCA se bloquea, aunque la cuenta ya esté excedida. Resultado: %', v_result->>'committed', v_result;
  END IF;
  IF (v_result->>'inserted')::int <> 0 OR (v_result->>'updated')::int <> 3 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (b): inserted=%/updated=% y esperaba 0/3 (sólo actualizaciones). Resultado: %', v_result->>'inserted', v_result->>'updated', v_result;
  END IF;

  v_plan := v_result->'plan';
  IF (v_plan->>'exceeded')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (b): plan.exceeded=% y esperaba false. plan: %', v_plan->>'exceeded', v_plan;
  END IF;
  IF (v_plan->>'before')::int <> 105 OR (v_plan->>'after')::int <> 105 OR (v_plan->>'added')::int <> 0 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (b): plan no refleja "sin crecimiento" (before/after/added). plan: %', v_plan;
  END IF;

  SELECT COUNT(*) INTO v_after_products FROM public.products WHERE account_id = v_account_bc AND deleted_at IS NULL;
  IF v_after_products <> 105 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (b): products vivos pasó de 105 a % — una importación de SÓLO actualizaciones no puede cambiar el conteo.', v_after_products;
  END IF;

  SELECT price INTO v_updated_price FROM public.products WHERE account_id = v_account_bc AND sku = 'GATE-PIPG-BC-1';
  IF v_updated_price IS DISTINCT FROM 999 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (b): el producto con sku GATE-PIPG-BC-1 no se actualizó (price=%) — el lote SÍ tiene que aplicarse de verdad, no sólo "pasar" el gate.', v_updated_price;
  END IF;

  INSERT INTO gate_pipg_progress VALUES ('b') ON CONFLICT DO NOTHING;
  RAISE NOTICE 'PASS (b): cuenta 105/100 (ya excedida) + import de SÓLO actualizaciones → PASA sin crecer (before=after=105, added=0), y las 3 filas se aplicaron de verdad.';
END $$;


-- ═══ (c) la MISMA cuenta de (b), + 1 fila NUEVA → BLOQUEADO ════════════════
DO $$
DECLARE
  v_user_bc uuid; v_account_bc uuid;
  v_result jsonb; v_rows jsonb; v_plan jsonb;
  v_before_products integer; v_after_products integer;
BEGIN
  SELECT id INTO v_user_bc FROM auth.users WHERE email = 'product-import-plan-gate-bc@test.local';
  IF v_user_bc IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN (c): sin anchor — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_bc FROM public.account_members WHERE user_id = v_user_bc ORDER BY created_at LIMIT 1;
  IF v_account_bc IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN (c): setup incompleto — degradando.'; RETURN; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_bc::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_bc THEN RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN (c): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  SELECT COUNT(*) INTO v_before_products FROM public.products WHERE account_id = v_account_bc AND deleted_at IS NULL;
  IF v_before_products <> 105 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (c): la cuenta de (b) tiene % productos vivos y esperaba 105 ((b) no debería haber cambiado el conteo).', v_before_products;
  END IF;

  -- 1 fila SIN sku (o con uno inexistente) → agrega, y agregar sobre una
  -- cuenta ya excedida tiene que bloquear el LOTE ENTERO.
  v_rows := jsonb_build_array(jsonb_build_object('row_no', 1, 'name', '__gate_pipg_c_nuevo__', 'price', 20));
  v_result := public.rpc_import_products(
    'gate-pipg-c-' || gen_random_uuid()::text, v_rows,
    'gate-pipg-c.csv', 'gate-pipg-c-hash-' || gen_random_uuid()::text
  );

  IF (v_result->>'committed')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (c): committed=% y esperaba false (105 excedida + 1 nuevo agrega). Resultado: %', v_result->>'committed', v_result;
  END IF;

  v_plan := v_result->'plan';
  IF (v_plan->>'exceeded')::boolean IS DISTINCT FROM true
     OR (v_plan->>'before')::int <> 105 OR (v_plan->>'after')::int <> 106 OR (v_plan->>'added')::int <> 1 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (c): veredicto de plan inesperado. plan: %', v_plan;
  END IF;

  SELECT COUNT(*) INTO v_after_products FROM public.products WHERE account_id = v_account_bc AND deleted_at IS NULL;
  IF v_after_products <> 105 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (c): products vivos pasó de 105 a % — un lote bloqueado por plan no puede agregar NADA.', v_after_products;
  END IF;

  INSERT INTO gate_pipg_progress VALUES ('c') ON CONFLICT DO NOTHING;
  RAISE NOTICE 'PASS (c): la misma cuenta excedida (105/100) + 1 fila NUEVA → BLOQUEADO entero (before=105, after=106, added=1).';
END $$;


-- ═══ (d) 98 + 2 nuevos → PASA, llega EXACTO a 100 ══════════════════════════
DO $$
DECLARE
  v_user_d uuid; v_account_d uuid;
  v_result jsonb; v_rows jsonb; v_plan jsonb;
  v_before_products integer; v_after_products integer;
BEGIN
  SELECT id INTO v_user_d FROM auth.users WHERE email = 'product-import-plan-gate-d@test.local';
  IF v_user_d IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN (d): sin anchor — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_d FROM public.account_members WHERE user_id = v_user_d ORDER BY created_at LIMIT 1;
  IF v_account_d IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN (d): setup incompleto — degradando.'; RETURN; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_d::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_d THEN RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN (d): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  SELECT COUNT(*) INTO v_before_products FROM public.products WHERE account_id = v_account_d AND deleted_at IS NULL;
  IF v_before_products <> 98 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (d): baseline tiene % productos vivos y esperaba EXACTO 98.', v_before_products;
  END IF;

  v_rows := jsonb_build_array(
    jsonb_build_object('row_no', 1, 'name', '__gate_pipg_d_nuevo_1__', 'price', 20),
    jsonb_build_object('row_no', 2, 'name', '__gate_pipg_d_nuevo_2__', 'price', 20)
  );
  v_result := public.rpc_import_products(
    'gate-pipg-d-' || gen_random_uuid()::text, v_rows,
    'gate-pipg-d.csv', 'gate-pipg-d-hash-' || gen_random_uuid()::text
  );

  IF (v_result->>'committed')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (d): committed=% y esperaba true (98+2=100, EXACTO en el tope, no ES mayor). Resultado: %', v_result->>'committed', v_result;
  END IF;

  v_plan := v_result->'plan';
  IF (v_plan->>'exceeded')::boolean IS DISTINCT FROM false
     OR (v_plan->>'before')::int <> 98 OR (v_plan->>'after')::int <> 100 OR (v_plan->>'added')::int <> 2 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (d): veredicto de plan inesperado. plan: %', v_plan;
  END IF;

  SELECT COUNT(*) INTO v_after_products FROM public.products WHERE account_id = v_account_d AND deleted_at IS NULL;
  IF v_after_products <> 100 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (d): products vivos pasó de 98 a % y esperaba 100.', v_after_products;
  END IF;

  INSERT INTO gate_pipg_progress VALUES ('d') ON CONFLICT DO NOTHING;
  RAISE NOTICE 'PASS (d): 98 + 2 nuevos → PASA, llega EXACTO a 100 (limit no es ">=", es ">").';
END $$;


-- ═══ (e) 98 (cuenta DISTINTA de d) + 3 nuevos → BLOQUEADO ══════════════════
DO $$
DECLARE
  v_user_e uuid; v_account_e uuid;
  v_result jsonb; v_rows jsonb; v_plan jsonb;
  v_before_products integer; v_after_products integer;
BEGIN
  SELECT id INTO v_user_e FROM auth.users WHERE email = 'product-import-plan-gate-e@test.local';
  IF v_user_e IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN (e): sin anchor — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_e FROM public.account_members WHERE user_id = v_user_e ORDER BY created_at LIMIT 1;
  IF v_account_e IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN (e): setup incompleto — degradando.'; RETURN; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_e::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_e THEN RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN (e): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  SELECT COUNT(*) INTO v_before_products FROM public.products WHERE account_id = v_account_e AND deleted_at IS NULL;
  IF v_before_products <> 98 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (e): baseline tiene % productos vivos y esperaba EXACTO 98.', v_before_products;
  END IF;

  v_rows := jsonb_build_array(
    jsonb_build_object('row_no', 1, 'name', '__gate_pipg_e_nuevo_1__', 'price', 20),
    jsonb_build_object('row_no', 2, 'name', '__gate_pipg_e_nuevo_2__', 'price', 20),
    jsonb_build_object('row_no', 3, 'name', '__gate_pipg_e_nuevo_3__', 'price', 20)
  );
  v_result := public.rpc_import_products(
    'gate-pipg-e-' || gen_random_uuid()::text, v_rows,
    'gate-pipg-e.csv', 'gate-pipg-e-hash-' || gen_random_uuid()::text
  );

  IF (v_result->>'committed')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (e): committed=% y esperaba false (98+3=101 > 100). Resultado: %', v_result->>'committed', v_result;
  END IF;

  v_plan := v_result->'plan';
  IF (v_plan->>'exceeded')::boolean IS DISTINCT FROM true
     OR (v_plan->>'before')::int <> 98 OR (v_plan->>'after')::int <> 101 OR (v_plan->>'added')::int <> 3 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (e): veredicto de plan inesperado. plan: %', v_plan;
  END IF;

  SELECT COUNT(*) INTO v_after_products FROM public.products WHERE account_id = v_account_e AND deleted_at IS NULL;
  IF v_after_products <> 98 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (e): products vivos pasó de 98 a % — un lote bloqueado no puede agregar NADA.', v_after_products;
  END IF;

  INSERT INTO gate_pipg_progress VALUES ('e') ON CONFLICT DO NOTHING;
  RAISE NOTICE 'PASS (e): cuenta DISTINTA de (d), 98 + 3 nuevos → BLOQUEADO (101 > 100), cero escrituras — confirma que (d) pasar no fue casualidad de cuenta compartida.';
END $$;


-- ═══ (g) 95 vivos + 10 borrados + 3 nuevos → PASA (control del predicado) ══
DO $$
DECLARE
  v_user_g uuid; v_account_g uuid;
  v_result jsonb; v_rows jsonb; v_plan jsonb;
  v_before_live integer; v_before_total integer; v_after_live integer;
BEGIN
  SELECT id INTO v_user_g FROM auth.users WHERE email = 'product-import-plan-gate-g@test.local';
  IF v_user_g IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN (g): sin anchor — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_g FROM public.account_members WHERE user_id = v_user_g ORDER BY created_at LIMIT 1;
  IF v_account_g IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN (g): setup incompleto — degradando.'; RETURN; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_g::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_g THEN RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN (g): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  SELECT COUNT(*) INTO v_before_live  FROM public.products WHERE account_id = v_account_g AND deleted_at IS NULL;
  SELECT COUNT(*) INTO v_before_total FROM public.products WHERE account_id = v_account_g;
  IF v_before_live <> 95 OR v_before_total <> 105 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (g): baseline tiene %/vivos de %/total y esperaba 95/105 (95 vivos + 10 borrados).', v_before_live, v_before_total;
  END IF;

  v_rows := jsonb_build_array(
    jsonb_build_object('row_no', 1, 'name', '__gate_pipg_g_nuevo_1__', 'price', 20),
    jsonb_build_object('row_no', 2, 'name', '__gate_pipg_g_nuevo_2__', 'price', 20),
    jsonb_build_object('row_no', 3, 'name', '__gate_pipg_g_nuevo_3__', 'price', 20)
  );
  v_result := public.rpc_import_products(
    'gate-pipg-g-' || gen_random_uuid()::text, v_rows,
    'gate-pipg-g.csv', 'gate-pipg-g-hash-' || gen_random_uuid()::text
  );

  IF (v_result->>'committed')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (g): committed=% y esperaba true — los 10 productos BORRADOS no cuentan (95+3=98 <= 100). Si el predicado los contara (105+3=108), este lote se habría bloqueado. Resultado: %', v_result->>'committed', v_result;
  END IF;

  v_plan := v_result->'plan';
  IF (v_plan->>'exceeded')::boolean IS DISTINCT FROM false
     OR (v_plan->>'before')::int <> 95 OR (v_plan->>'after')::int <> 98 OR (v_plan->>'added')::int <> 3 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (g): veredicto de plan no excluyó los borrados (esperaba before=95, after=98). plan: %', v_plan;
  END IF;

  SELECT COUNT(*) INTO v_after_live FROM public.products WHERE account_id = v_account_g AND deleted_at IS NULL;
  IF v_after_live <> 98 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (g): products vivos pasó de 95 a % y esperaba 98.', v_after_live;
  END IF;

  INSERT INTO gate_pipg_progress VALUES ('g') ON CONFLICT DO NOTHING;
  RAISE NOTICE 'PASS (g): 95 vivos + 10 soft-deleted (105 si se contaran) + 3 nuevos → PASA con before=95/after=98 — el predicado de "vivo" (deleted_at IS NULL) es el mismo que ProductRepository.count_by_org.';
END $$;


-- ═══ (h) plan PRO (tope 5.000), 200 + 50 nuevos → PASA ═════════════════════
DO $$
DECLARE
  v_user_h uuid; v_account_h uuid;
  v_result jsonb; v_rows jsonb; v_plan jsonb;
  v_before_products integer; v_after_products integer;
BEGIN
  SELECT id INTO v_user_h FROM auth.users WHERE email = 'product-import-plan-gate-h@test.local';
  IF v_user_h IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN (h): sin anchor — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_h FROM public.account_members WHERE user_id = v_user_h ORDER BY created_at LIMIT 1;
  IF v_account_h IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN (h): setup incompleto — degradando.'; RETURN; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_h::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_h THEN RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN (h): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  SELECT COUNT(*) INTO v_before_products FROM public.products WHERE account_id = v_account_h AND deleted_at IS NULL;
  IF v_before_products <> 200 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (h): baseline tiene % productos vivos y esperaba EXACTO 200.', v_before_products;
  END IF;

  SELECT jsonb_agg(jsonb_build_object('row_no', g, 'name', '__gate_pipg_h_nuevo_' || g || '__', 'price', 20))
    INTO v_rows
  FROM generate_series(1, 50) g;

  v_result := public.rpc_import_products(
    'gate-pipg-h-' || gen_random_uuid()::text, v_rows,
    'gate-pipg-h.csv', 'gate-pipg-h-hash-' || gen_random_uuid()::text
  );

  IF (v_result->>'committed')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (h): committed=% y esperaba true — plan PRO (tope 5000), 200+50=250 muy por debajo. Resultado: %', v_result->>'committed', v_result;
  END IF;

  v_plan := v_result->'plan';
  IF v_plan->>'plan' <> 'pro' THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (h): plan.plan="%" y esperaba "pro". plan: %', v_plan->>'plan', v_plan;
  END IF;
  IF (v_plan->>'limit')::int <> 5000 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (h): plan.limit=% y esperaba 5000. plan: %', v_plan->>'limit', v_plan;
  END IF;
  IF (v_plan->>'exceeded')::boolean IS DISTINCT FROM false
     OR (v_plan->>'before')::int <> 200 OR (v_plan->>'after')::int <> 250 OR (v_plan->>'added')::int <> 50 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (h): veredicto de plan inesperado. plan: %', v_plan;
  END IF;

  SELECT COUNT(*) INTO v_after_products FROM public.products WHERE account_id = v_account_h AND deleted_at IS NULL;
  IF v_after_products <> 250 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (h): products vivos pasó de 200 a % y esperaba 250.', v_after_products;
  END IF;

  INSERT INTO gate_pipg_progress VALUES ('h') ON CONFLICT DO NOTHING;
  RAISE NOTICE 'PASS (h): cuenta PRO (tope 5000), 200 + 50 nuevos → PASA (250, muy por debajo) — aunque 250 ya superaría el tope de gratis, el plan efectivo correcto (pro) es el que se evalúa.';
END $$;


-- ═══ (i) ACL de rpc_import_products intacta + una sola definición viva ═════
-- Esta migración reescribe el CUERPO de rpc_import_products (misma firma,
-- CREATE OR REPLACE) — nunca su firma ni sus permisos. Redundante con el
-- bloque (12) de test_product_import_batch.sql, pero deliberado: este
-- archivo es el que un futuro cambio de rpc_import_products va a tocar
-- primero, y su propia regresión de ACL/overload debe fallar ACÁ, no sólo
-- en el gate hermano.
DO $$
DECLARE
  v_def_count integer;
  v_has_anon_execute boolean;
  v_has_authenticated_execute boolean;
BEGIN
  SELECT COUNT(*) INTO v_def_count
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_import_products';
  IF v_def_count <> 1 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (i): % definiciones vivas de rpc_import_products y esperaba EXACTO 1 (overload fantasma).', v_def_count;
  END IF;

  SELECT has_function_privilege('anon', 'public.rpc_import_products(text,jsonb,text,text,boolean)', 'EXECUTE')
    INTO v_has_anon_execute;
  IF v_has_anon_execute THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (i): anon TIENE EXECUTE sobre rpc_import_products.';
  END IF;

  SELECT has_function_privilege('authenticated', 'public.rpc_import_products(text,jsonb,text,text,boolean)', 'EXECUTE')
    INTO v_has_authenticated_execute;
  IF NOT v_has_authenticated_execute THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (i): authenticated NO tiene EXECUTE sobre rpc_import_products.';
  END IF;

  INSERT INTO gate_pipg_progress VALUES ('i') ON CONFLICT DO NOTHING;
  RAISE NOTICE 'PASS (i): una sola definición viva de rpc_import_products, ACL sin cambios (authenticated sí, anon no).';
END $$;


-- ═══ (j) SET LOCAL ROLE authenticated — ejercita el camino REAL de prod ═════
-- Corrección de revisión (ronda 1 adversarial, nit): los bloques (a)-(i)
-- corren como `postgres` (superusuario). En prod, v31-tenancy-pool-rls
-- Paso 2 adopta `SET LOCAL ROLE authenticated` por transacción, así que la
-- única afirmación del encabezado de la migración sin gate hasta ahora era
-- "get_effective_plan/plan_limits no necesitan GRANT porque
-- rpc_import_products es SECURITY DEFINER con owner postgres" — verificado
-- a mano en la revisión, ahora con gate real. Repite el escenario (a):
-- reusa la cuenta EXACTO en 100 que (a) dejó bloqueada (cero escrituras),
-- así que un nuevo intento con el mismo archivo sigue viendo 100/100.
BEGIN;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', (SELECT id::text FROM auth.users WHERE email = 'product-import-plan-gate-a@test.local'), 'role', 'authenticated')::text,
  true);
SET LOCAL ROLE authenticated;
DO $$
DECLARE
  v_user_a uuid; v_account_a uuid;
  v_result jsonb; v_rows jsonb; v_plan jsonb;
  v_current_role text;
BEGIN
  SELECT current_user INTO v_current_role;
  IF v_current_role <> 'authenticated' THEN
    RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN (j): current_user=% (no adoptó authenticated) — degradando.', v_current_role; RETURN;
  END IF;

  -- Bajo el rol `authenticated` NO se puede leer `auth.users` directamente
  -- (mismo motivo por el que `get_effective_plan` no tiene EXECUTE para este
  -- rol) — se resuelve exactamente como lo hace `rpc_import_products` por
  -- dentro: `auth.uid()` (lee el GUC de la sesión, no la tabla) y
  -- `current_account_ids()` (SECURITY DEFINER, con EXECUTE para
  -- authenticated).
  v_user_a := auth.uid();
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN (j): auth.uid() no resuelve — degradando.'; RETURN; END IF;
  SELECT cai INTO v_account_a FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_a IS NULL THEN RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN (j): setup incompleto — degradando.'; RETURN; END IF;

  v_rows := jsonb_build_array(jsonb_build_object('row_no', 1, 'name', '__gate_pipg_j_nuevo__', 'price', 50));
  v_result := public.rpc_import_products(
    'gate-pipg-j-' || gen_random_uuid()::text, v_rows,
    'gate-pipg-j.csv', 'gate-pipg-j-hash-' || gen_random_uuid()::text
  );

  IF (v_result->>'committed')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (j): bajo SET LOCAL ROLE authenticated, committed=% y esperaba false. Resultado: %', v_result->>'committed', v_result;
  END IF;

  v_plan := v_result->'plan';
  IF (v_plan->>'exceeded')::boolean IS DISTINCT FROM true OR v_plan->>'plan' <> 'gratis' OR (v_plan->>'limit')::int <> 100 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (j): bajo authenticated, veredicto de plan inesperado. plan: %', v_plan;
  END IF;

  INSERT INTO gate_pipg_progress VALUES ('j') ON CONFLICT DO NOTHING;
  RAISE NOTICE 'PASS (j): bajo SET LOCAL ROLE authenticated (camino real de prod, v31-tenancy-pool-rls Paso 2), rpc_import_products resuelve el mismo veredicto de plan sin GRANT extra sobre get_effective_plan/plan_limits.';
END $$;
COMMIT;


-- ═══ (k) plan_limits cubre TODO el dominio del CHECK de billing_plan/trial_plan
-- Corrección de revisión (ronda 1 adversarial, nit): `v_plan_exceeded` en la
-- migración exige `v_limit IS NOT NULL` — si get_effective_plan devolviera
-- un plan sin fila en plan_limits, el gate se apagaría EN SILENCIO para esa
-- cuenta (fail-open). Hoy es inalcanzable porque el CHECK de accounts sólo
-- permite 4 valores y los 4 tienen fila — este bloque lo assertea desde el
-- CHECK vivo (no una lista hardcodeada) para que un futuro ALTER TABLE que
-- agregue un plan nuevo sin su fila en plan_limits rompa ESTE gate.
DO $$
DECLARE
  v_billing_def text;
  v_trial_def   text;
  v_billing_values text[];
  v_trial_values    text[];
  v_missing_billing text[];
  v_missing_trial    text[];
BEGIN
  SELECT pg_get_constraintdef(oid) INTO v_billing_def
    FROM pg_constraint WHERE conrelid = 'public.accounts'::regclass AND conname = 'accounts_billing_plan_values';
  SELECT pg_get_constraintdef(oid) INTO v_trial_def
    FROM pg_constraint WHERE conrelid = 'public.accounts'::regclass AND conname = 'accounts_trial_plan_values';

  IF v_billing_def IS NULL OR v_trial_def IS NULL THEN
    RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN (k): no se encontró el CHECK esperado sobre accounts.billing_plan/trial_plan (nombre de constraint cambió) — degradando.';
    RETURN;
  END IF;

  SELECT array_agg(m[1]) INTO v_billing_values FROM regexp_matches(v_billing_def, '''([a-z]+)''::text', 'g') AS m;
  SELECT array_agg(m[1]) INTO v_trial_values    FROM regexp_matches(v_trial_def,    '''([a-z]+)''::text', 'g') AS m;

  IF v_billing_values IS NULL OR v_trial_values IS NULL THEN
    RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN (k): no se pudieron extraer los valores del CHECK (forma inesperada) — degradando.';
    RETURN;
  END IF;

  SELECT COALESCE(array_agg(v), ARRAY[]::text[]) INTO v_missing_billing
    FROM unnest(v_billing_values) v WHERE NOT EXISTS (SELECT 1 FROM public.plan_limits pl WHERE pl.plan = v);
  SELECT COALESCE(array_agg(v), ARRAY[]::text[]) INTO v_missing_trial
    FROM unnest(v_trial_values) v WHERE NOT EXISTS (SELECT 1 FROM public.plan_limits pl WHERE pl.plan = v);

  IF array_length(v_missing_billing, 1) IS NOT NULL OR array_length(v_missing_trial, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (k): hay valores del CHECK de billing_plan/trial_plan SIN fila en plan_limits (billing faltantes: %, trial faltantes: %) — el gate de plan se apagaría en silencio (fail-open) para ese plan.', v_missing_billing, v_missing_trial;
  END IF;

  INSERT INTO gate_pipg_progress VALUES ('k') ON CONFLICT DO NOTHING;
  RAISE NOTICE 'PASS (k): los % valores del CHECK de billing_plan/trial_plan (%) tienen fila en plan_limits — el gate de plan no puede apagarse en silencio por un plan sin límite configurado.', array_length(v_billing_values, 1), v_billing_values;
END $$;


-- ═══════════════════════════ (conteo) — degrade-don't-fail no reporta verde a medias
DO $$
DECLARE
  v_count   integer;
  v_missing text[];
BEGIN
  SELECT count(*) INTO v_count FROM gate_pipg_progress;
  SELECT COALESCE(array_agg(b ORDER BY b), ARRAY[]::text[]) INTO v_missing
    FROM unnest(ARRAY['a','b','c','d','e','f','g','h','i','j','k']) b
   WHERE NOT EXISTS (SELECT 1 FROM gate_pipg_progress p WHERE p.block = b);

  IF v_count <> 11 THEN
    RAISE EXCEPTION 'GATE PRODUCT-IMPORT-PLAN FAILED (conteo): se ejercitaron % de 11 bloques esperados (faltan: %) — el gate degradó a mitad de camino sin abortar y no puede reportarse verde.', v_count, v_missing;
  END IF;

  RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN: 11/11 bloques (a-k) ejercitados de verdad, ninguno degradado en silencio.';
END $$;


-- @@CLEANUP@@
DO $$
DECLARE
  v_emails   text[] := ARRAY[
    'product-import-plan-gate-a@test.local', 'product-import-plan-gate-bc@test.local',
    'product-import-plan-gate-d@test.local', 'product-import-plan-gate-e@test.local',
    'product-import-plan-gate-g@test.local', 'product-import-plan-gate-h@test.local'
  ];
  v_users    uuid[];
  v_accounts uuid[];
BEGIN
  SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) INTO v_users FROM auth.users WHERE email = ANY(v_emails);
  IF array_length(v_users, 1) IS NULL THEN
    RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN: cleanup sin anchors que limpiar.';
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
    DELETE FROM public.product_imports WHERE account_id = ANY(v_accounts);

    -- Corrección de revisión (ronda 1 adversarial, minor): el trigger de
    -- provisioning siembra product_categories/payment_methods/cost_centers
    -- por cuenta al alta del usuario — sin limpiarlos acá quedan huérfanos
    -- (sin fila en accounts) apenas más abajo se borra accounts en modo
    -- replica. MEDIDO antes de este fix: 42+42 filas huérfanas por corrida
    -- (7 de cada una por cada uno de los 6 tenants sintéticos), más ~6
    -- branches. Mismo defecto que CHANGES.md ya había cerrado para
    -- test_admin_kpis.sql (candidatos-tests-ci, PR #527) — este gate lo
    -- reintroducía en vez de nacer limpio.
    DELETE FROM public.product_categories WHERE account_id = ANY(v_accounts);
    DELETE FROM public.payment_methods    WHERE account_id = ANY(v_accounts);
    DELETE FROM public.cost_centers       WHERE account_id = ANY(v_accounts);

    -- branches: trg_guard_branch_decommission (sucursal-guard-vaciado-
    -- auditoria) rechaza el borrado físico con branch_delete_forbidden —
    -- igual que ya hace el DELETE de accounts más abajo, hay que envolverlo
    -- en session_replication_role=replica.
    SET session_replication_role = replica;
    DELETE FROM public.branches WHERE account_id = ANY(v_accounts);
    SET session_replication_role = DEFAULT;
  END IF;

  DELETE FROM public.operation_idempotency WHERE user_id = ANY(v_users);
  DELETE FROM public.account_members       WHERE user_id = ANY(v_users);
  SET session_replication_role = replica;
  DELETE FROM public.accounts              WHERE owner_user_id = ANY(v_users);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.profiles              WHERE id = ANY(v_users);
  DELETE FROM public.email_logs            WHERE user_id = ANY(v_users) OR recipient = ANY(v_emails);
  DELETE FROM auth.users                   WHERE id = ANY(v_users);

  RAISE NOTICE 'GATE PRODUCT-IMPORT-PLAN: cleanup completo (% anchors) — el gate vuelve a correr en verde sobre la misma base.', array_length(v_users, 1);
END $$;
