-- ============================================================================
-- importador-productos-fastapi (2026-09-10)
--
-- El importador de productos deja de hablar directo con Supabase desde el
-- navegador (frontend/lib/import/importer.ts + resolver.ts) y pasa a ser una
-- transacción única de servidor (DEC-24), calcada del molde de
-- `rpc_import_expenses` (importador-gastos-transaccional) y
-- `rpc_import_bank_statement` (C3): todo o nada, idempotencia por clave,
-- dedupe por (account_id, file_hash), simulación (`p_dry_run`).
--
-- `rpc_import_products` INVOCA `rpc_bulk_upsert_products` UNA SOLA VEZ con el
-- archivo completo — no reimplementa ni una regla del upsert (resolución de
-- SKU, jerarquía padre→variante, categorías, branch_stock, atributos). Una
-- sola llamada (no una por fila) es la que hace que el tope de 50 categorías
-- nuevas del upsert pase a evaluarse sobre el ARCHIVO, no sobre un fragmento
-- (D1 del design).
--
-- Integridad de función — verificado contra el cuerpo VIVO de la base local
-- el 2026-09-10 (checkpoint 1.1-1.7 de tasks.md; md5 sin \r del checkout
-- Windows — comparar por líneas, no por md5 crudo, contra el registrado en
-- otro entorno):
--   rpc_bulk_upsert_products(jsonb,uuid)
--     = cc3d92a38432492b11fbca4bd47288fd (12163 bytes, MEDIDO LOCAL post
--       productos-costo-nullable — difiere del md5 de prod anotado en el
--       brief del apply, 8963a42e… /12087b; la diferencia es autoría de
--       entorno, NO de contenido: el cuerpo ya no tiene COALESCE(v_cost,0)
--       en el INSERT, confirmado por inspección línea por línea). Este
--       archivo reescribe DESDE ESTE CUERPO, con la única adición de D2.
--   rpc_import_bank_statement(text,uuid,text,text,jsonb)
--     = 75f0200bc61d05fad1d981caaec76747 — molde, NO SE TOCA.
--   rpc_import_expenses(text,jsonb,text,text,uuid,uuid,uuid,uuid,boolean)
--     = confirmado existente y registrado (20261041000001) — molde de
--       veredicto de lote + p_dry_run, NO SE TOCA.
--   get_effective_plan(uuid) / is_account_writer(uuid) — NO SE TOCAN
--     (sólo se referencian; el gate de plan de D5/OQ-1 NO se escribe en
--     este change — ver nota "OQ-1" más abajo).
--
-- ERRCODEs (barrido de P0[0-9]{3} sobre supabase/migrations, backend/,
-- frontend/lib — 2026-09-10; P0427/P0429 ya fijados por
-- importador-gastos-transaccional, se REUTILIZAN con la misma semántica;
-- P0430 quedó libre y se documenta reservado — no se emite en este change):
--   P0403 → sin cuenta activa (guard de sesión, ya existente) O el usuario
--           pertenece a MÁS de una cuenta (cuenta ambigua — el import de
--           lote no tiene selector de cuenta; corrección post-review ronda
--           3, F1, ver más abajo).
--   P0401 → sin rol de escritura (is_account_writer) — hueco que este
--           change cierra (D4): el upsert nunca lo tuvo.
--   P0427 → payload del lote malformado (no es array, fuera de 1..2500,
--           file_name/file_hash faltante) — 422, ya mapeado en errors.py.
--   P0429 → señal INTERNA de rollback del lote (error de fila o
--           simulación) — NUNCA sale de la función, se captura en su
--           propio EXCEPTION (D3). No requiere mapeo en errors.py.
--   P0430 → RESERVADO para el rechazo por límite de plan (D5/OQ-1). NO SE
--           EMITE en este change: la task 4.7 queda sin escribir porque
--           OQ-1 no tiene sign-off del PO (ver design.md §OQ-1 y
--           tasks.md). Un archivo futuro que sume el gate de plan no
--           necesita un ERRCODE nuevo — éste ya está reservado.
--   (P0400 del propio rpc_bulk_upsert_products — tope de 50 categorías
--    nuevas — sigue propagándose tal cual, sin capturarse acá: es un
--    rechazo de FORMA/CUOTA, no de fila, mismo tratamiento que el resto de
--    los topes de este change.)
--
-- OQ-1 (gate de plan al importar): el design lo recomienda pero el PO NO
-- dio sign-off explícito. Por instrucción del orquestador del apply, la
-- task 4.7 (y el código que le correspondería en esta función) NO SE
-- ESCRIBE. El resto del change es independiente y completo sin ella.
--
-- Idempotente: reaplicable sin duplicar nada (IF NOT EXISTS / DROP+CREATE /
-- CREATE OR REPLACE en todo el archivo).
--
-- Correcciones post-review (misma fecha, antes de mergear):
--
--   1) Las DOS ramas de replay de rpc_import_products (dedupe por
--      file_hash y por clave de idempotencia) devolvían `'dry_run', false`
--      HARDCODEADO, sin mirar `p_dry_run`. En modo simulación, un archivo
--      ya importado mostraba en el paso 2 del diálogo un veredicto normal
--      ("N productos entrarían") en vez de avisar que el archivo YA estaba
--      importado — el usuario no se enteraba hasta después de confirmar.
--      Corregido a `'dry_run', p_dry_run` en las dos ramas; gate nuevo
--      (11.1b/11.2b) fija el contrato.
--
--   2) Tope de filas bajado de 5.000 a **2.500** (D6/OQ-2): el design dejó
--      la baja a 2.500 como criterio EXPLÍCITO si la task 6.9 (medición del
--      tope real, que había quedado sin ejecutar) mostraba degradación.
--      Medido en la base local post-apply: 5.000 filas = 33,1s de
--      simulación + 34,2s de confirmación, con escalado SUPERLINEAL
--      (200→804ms, 1000→4189ms, 2000→9999ms, 5000→33101ms; 4,0→6,6
--      ms/fila). Sin timeout declarado en `pythonClient` ni en el backend,
--      y corriendo en Render free tier en prod (más lento que este Docker
--      local) — 2.500 sigue cubriendo el mayor lote real medido (1.393) y
--      el catálogo más grande (2.372) con margen, y baja el riesgo de
--      timeout de plataforma sin reintroducir el troceo que D6 prohíbe.
--      ⚠️ La RE-medición independiente de esta corrección, sobre la base
--      reconciliada de este worktree, NO reprodujo la degradación: 5.000
--      filas invocando `rpc_bulk_upsert_products` directo tardó 752ms
--      (~0,15 ms/fila), escalado ~LINEAL en 200/1000/2000/2500. La causa de
--      la discrepancia no se determinó. El tope se deja en 2.500 IGUAL —
--      no depende de esa medición en disputa para justificarse (D6 ya lo
--      hacía por cobertura de uso real) — pero el riesgo de timeout de
--      plataforma que motivó la baja no está confirmado. Detalle de ambas
--      mediciones en `design.md` §D6 y `CHANGES.md`.
--
--   3) `current_account_ids() ... LIMIT 1` en el guard de rol de escritura
--      de `rpc_import_products` no tenía `ORDER BY` — no determinístico,
--      podía no coincidir con la resolución (también sin ORDER BY, fuera
--      de alcance de D2) que hace `rpc_bulk_upsert_products` para el MISMO
--      usuario. Se agregó `ORDER BY cai` a ESTA resolución (determinística
--      de por sí); el caso multi-cuenta por usuario queda documentado como
--      candidato, no reproducido hoy.
--
-- Correcciones post-review — ronda 3 (misma fecha, revisión adversarial
-- posterior a la de arriba):
--
--   4) [MAJOR, F1] La corrección (3) de arriba era EL BUG, no el fix: agregar
--      `ORDER BY cai` a UNA sola de las dos resoluciones (guard acá,
--      escritura en `rpc_bulk_upsert_products`) las hizo DIVERGIR para un
--      usuario con más de una cuenta, en vez de coincidir. Probado: 6/8
--      usuarios multi-cuenta sintéticos con el guard evaluando
--      `is_account_writer` sobre una cuenta AJENA al destino real —
--      REGRESIÓN respecto de `main`, un owner legítimo era rechazado con
--      P0401. Revertido a la consulta LITERAL sin `ORDER BY` (coinciden 8/8
--      con el upsert) y sumada una comprobación explícita: si
--      `current_account_ids()` devuelve más de una fila, `rpc_import_products`
--      rechaza con `P0403` en vez de resolver una cualquiera — la
--      importación en lote no tiene selector de cuenta. Medido en prod
--      2026-09-10: 0 usuarios pertenecen hoy a más de una cuenta, así que
--      no reproduce ningún caso real (decisión de la ronda 3, ver
--      design.md D4). Gate nuevo (13.x) con un usuario de dos membresías
--      (P0403) y uno de una sola (OK).
--
--   5) [MINOR, F2] El anuncio de categorías nuevas de `rpc_import_products`
--      agrupaba por `product_category_normalize_name(...)` SIN bajar a
--      minúsculas — "Zapatillas"/"zapatillas"/"ZAPATILLAS" en el mismo
--      archivo se anunciaban como 3 categorías nuevas cuando el servidor
--      creaba 1 (el upsert sí agrupa case-insensitive). Corregido a agrupar
--      por `lower(...)`, con un nombre canónico (`min(...)`) y la suma de
--      filas de cada variante. Gate nuevo (14.x) con las tres variantes de
--      capitalización.
-- ============================================================================

-- ── 1) Tabla product_imports — espejo mínimo de expense_imports/
--       bank_statement_imports ──────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.product_imports (
  id          uuid        NOT NULL DEFAULT gen_random_uuid(),
  account_id  uuid        NOT NULL REFERENCES public.accounts(id),
  user_id     uuid        NOT NULL,
  file_name   text        NOT NULL,
  file_hash   text        NOT NULL,
  rows_total  integer     NOT NULL,
  inserted    integer     NOT NULL DEFAULT 0,
  updated     integer     NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT product_imports_pkey PRIMARY KEY (id),
  CONSTRAINT product_imports_rows_total_check CHECK (rows_total > 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS product_imports_account_hash_uq
  ON public.product_imports (account_id, file_hash);

ALTER TABLE public.product_imports ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS product_imports_select ON public.product_imports;
CREATE POLICY product_imports_select
  ON public.product_imports
  FOR SELECT
  USING (account_id IN (SELECT public.current_account_ids()));

-- Sin INSERT/UPDATE/DELETE para ningún rol de aplicación: la escritura es
-- exclusiva de rpc_import_products (SECURITY DEFINER). Nada para `anon`,
-- alineado con 20261035000001_revoke_anon_table_writes.sql.
--
-- ⚠️ Mismo gotcha que expense_imports (20261041000001): ALTER DEFAULT
-- PRIVILEGES ya le da a `authenticated` INSERT/UPDATE/DELETE/TRUNCATE en
-- cuanto la tabla nace — el REVOKE explícito de los cuatro es obligatorio,
-- GRANT SELECT solo no alcanza.
REVOKE ALL ON public.product_imports FROM PUBLIC;
REVOKE ALL ON public.product_imports FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.product_imports FROM authenticated;
GRANT SELECT ON public.product_imports TO authenticated;

COMMENT ON TABLE public.product_imports IS
  'importador-productos-fastapi: una fila por lote de importación de productos aplicado. '
  'Escritura exclusiva de rpc_import_products (SECURITY DEFINER). Espejo reducido de expense_imports.';

-- ── 2) operation_idempotency.operation_kind — sumar 'product_import' ───────
-- Lista copiada de la definición VIVA (pg_get_constraintdef), NO del último
-- archivo de migración que la tocó (checkpoint 1.4).

ALTER TABLE public.operation_idempotency
  DROP CONSTRAINT IF EXISTS operation_idempotency_operation_kind_check;
ALTER TABLE public.operation_idempotency
  ADD CONSTRAINT operation_idempotency_operation_kind_check
  CHECK (operation_kind = ANY (ARRAY[
    'sale', 'purchase', 'payment_received', 'payment_made', 'supplier_charge',
    'bank_movement', 'event_consumer', 'bank_statement_import',
    'cash_session_close', 'subscription_webhook', 'credit_note',
    'expense_import', 'product_import'
  ]::text[]));

COMMENT ON CONSTRAINT operation_idempotency_operation_kind_check ON public.operation_idempotency IS
  'importador-productos-fastapi: suma product_import al vocabulario cerrado de operation_kind.';

-- ── 3) rpc_bulk_upsert_products — ÚNICA modificación: el error lleva su
--       número de fila (D2) ────────────────────────────────────────────────
-- CREATE OR REPLACE con LA MISMA FIRMA, partiendo del cuerpo VIVO local (ver
-- integridad de función arriba). Ni un guard, ni una resolución, ni el
-- RETURN cambian — el único diff es 'row' en el jsonb_build_object del error
-- de fila. `row_no` es OPCIONAL en el payload: si no viene, 'row' sale NULL
-- y el comportamiento previo se conserva exactamente (compatibilidad con
-- cualquier caller viejo, incluidos los gates SQL que la llaman directo).

CREATE OR REPLACE FUNCTION public.rpc_bulk_upsert_products(p_rows jsonb, p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_row            jsonb;
  v_product_id     uuid;
  v_existing_id    uuid;
  v_resolved_pid   uuid;
  v_attr           jsonb;
  v_inserted       int := 0;
  v_updated        int := 0;
  v_errors         jsonb := '[]'::jsonb;
  v_error_detail   jsonb;
  v_account_id     uuid;
  v_default_branch uuid;
  v_stock_qty      numeric;
  -- productos-categorias-sku (D6): categoría por fila + default de la cuenta + tope.
  v_cat_name         text;
  v_category_id      uuid;
  v_default_category uuid;
  v_new_categories   int;
  c_max_new_categories CONSTANT int := 50;  -- OQ-1, sign-off PO 2026-09-03
BEGIN
  IF p_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Unauthorized: caller does not own user_id';
  END IF;

  -- C-21 checkpoint #2 (residuo task_29345f9d): la cuenta se resuelve vía
  -- current_account_ids() — funciona para dueños Y miembros. El método anterior
  -- (accounts.user_id) devolvía NULL para miembros no-dueños y generaba
  -- products huérfanos. Guard duro: sin cuenta no se importa.
  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede importar productos'
      USING ERRCODE = 'P0403';
  END IF;

  -- Default branch de la cuenta (la más antigua); lazy-create si no existe.
  SELECT b.id INTO v_default_branch
    FROM branches b
   WHERE b.account_id = v_account_id
   ORDER BY b.created_at ASC
   LIMIT 1;

  IF v_default_branch IS NULL THEN
    INSERT INTO public.branches (account_id, name, is_active)
    VALUES (v_account_id, 'Casa Central', TRUE)
    ON CONFLICT (account_id, name) DO NOTHING;

    SELECT b.id INTO v_default_branch
      FROM branches b
     WHERE b.account_id = v_account_id
     ORDER BY b.created_at ASC
     LIMIT 1;
  END IF;

  -- categoria-default-configurable: primero el default EXPLÍCITO de la
  -- cuenta (accounts.default_product_category_id), sólo si sigue vivo y
  -- activo — una categoría desactivada o soft-deleteada nunca es un default
  -- válido, aunque el puntero siga seteado. Si no hay default configurado o
  -- quedó inactivo/borrado, cae en la heurística de siempre (D6, sin tocar):
  -- "Otros" si sigue viva y activa; si el usuario la renombró o desactivó,
  -- la última activa por sort_order. Sin catálogo activo → NULL (la fila
  -- conserva el TEXT legacy, nunca falla por esto).
  SELECT pc.id INTO v_default_category
    FROM public.accounts a
    JOIN public.product_categories pc
      ON pc.id = a.default_product_category_id
     AND pc.account_id = a.id
     AND pc.deleted_at IS NULL
     AND pc.is_active
   WHERE a.id = v_account_id;

  IF v_default_category IS NULL THEN
    SELECT pc.id INTO v_default_category
      FROM public.product_categories pc
     WHERE pc.account_id = v_account_id
       AND pc.deleted_at IS NULL
       AND pc.is_active
     ORDER BY (lower(pc.name) = 'otros') DESC, pc.sort_order DESC, pc.created_at ASC
     LIMIT 1;
  END IF;

  -- productos-categorias-sku (D6, tope OQ-1): contar las categorías NUEVAS
  -- distintas que trae la llamada ANTES de tocar nada. Superar el tope
  -- aborta toda la llamada (una sola transacción → nada creado): lo más
  -- probable es una columna mal mapeada, no un catálogo legítimo.
  --
  -- importador-productos-fastapi: con rpc_import_products invocando esta
  -- función UNA SOLA VEZ con el archivo entero (D1), este tope pasa a
  -- evaluarse sobre el ARCHIVO — antes, con el troceo de 200 filas del
  -- cliente, era un tope por sub-lote.
  SELECT COUNT(*) INTO v_new_categories
    FROM (
      SELECT DISTINCT lower(public.product_category_normalize_name(r->>'category')) AS n
        FROM jsonb_array_elements(p_rows) AS r
       WHERE public.product_category_normalize_name(r->>'category') IS NOT NULL
    ) d
   WHERE NOT EXISTS (
      SELECT 1 FROM public.product_categories pc
       WHERE pc.account_id = v_account_id
         AND pc.deleted_at IS NULL
         AND lower(pc.name) = d.n
   );

  IF v_new_categories > c_max_new_categories THEN
    RAISE EXCEPTION 'La importación introduce % categorías nuevas y el tope es %. Revisá que la columna "Categoría" del archivo esté bien mapeada (¿no será un código, una descripción o un precio?).',
      v_new_categories, c_max_new_categories
      USING ERRCODE = 'P0400';
  END IF;

  FOR v_row IN SELECT * FROM jsonb_array_elements(p_rows)
  LOOP
    BEGIN
      v_existing_id := NULL;
      IF v_row->>'sku' IS NOT NULL AND v_row->>'sku' <> '' THEN
        -- productos-categorias-sku (D4, eje a): alcance de CUENTA, case-insensitive,
        -- filas vivas — el mismo alcance exacto que idx_products_sku_account_lower.
        SELECT id INTO v_existing_id
          FROM public.products
         WHERE account_id = v_account_id
           AND lower(sku) = lower(v_row->>'sku')
           AND deleted_at IS NULL
         LIMIT 1;
      END IF;

      v_resolved_pid := NULL;

      IF v_row->>'parent_id' IS NOT NULL AND v_row->>'parent_id' <> '' THEN
        v_resolved_pid := (v_row->>'parent_id')::uuid;

      ELSIF v_row->>'sku_parent' IS NOT NULL AND v_row->>'sku_parent' <> '' THEN
        -- productos-categorias-sku (D4, eje a): idem, por cuenta.
        SELECT id INTO v_resolved_pid
          FROM public.products
         WHERE account_id = v_account_id
           AND lower(sku) = lower(v_row->>'sku_parent')
           AND deleted_at IS NULL
         LIMIT 1;
        IF v_resolved_pid IS NULL THEN
          RAISE EXCEPTION 'SKU Padre "%" no encontrado para la variante "%"',
            v_row->>'sku_parent', v_row->>'name';
        END IF;

      ELSIF v_row->>'parent_name' IS NOT NULL AND v_row->>'parent_name' <> '' THEN
        -- productos-categorias-sku (D4, eje a): idem, por cuenta.
        SELECT id INTO v_resolved_pid
          FROM public.products
         WHERE account_id = v_account_id
           AND name = v_row->>'parent_name'
           AND (is_variant = false OR is_variant IS NULL)
           AND parent_id IS NULL
           AND deleted_at IS NULL
         ORDER BY created_at DESC
         LIMIT 1;
        IF v_resolved_pid IS NULL THEN
          RAISE EXCEPTION 'Producto Padre "%" no encontrado para la variante "%"',
            v_row->>'parent_name', v_row->>'name';
        END IF;
      END IF;

      -- productos-categorias-sku (D6, eje b): resolver la categoría contra el
      -- catálogo de la cuenta (case-insensitive, tolerante a espacios) y
      -- crearla si falta. Va DESPUÉS de la resolución del padre (que puede
      -- fallar) y DENTRO del sub-bloque de la fila: si el INSERT/UPDATE del
      -- producto falla, la creación se revierte con la fila.
      v_category_id := NULL;
      v_cat_name    := public.product_category_normalize_name(v_row->>'category');
      IF v_cat_name IS NOT NULL THEN
        SELECT pc.id INTO v_category_id
          FROM public.product_categories pc
         WHERE pc.account_id = v_account_id
           AND pc.deleted_at IS NULL
           AND lower(pc.name) = lower(v_cat_name)
         LIMIT 1;

        IF v_category_id IS NULL THEN
          INSERT INTO public.product_categories (account_id, name, sort_order)
          VALUES (
            v_account_id,
            v_cat_name,
            COALESCE((SELECT MAX(sort_order) + 1
                        FROM public.product_categories
                       WHERE account_id = v_account_id AND deleted_at IS NULL), 1)
          )
          RETURNING id INTO v_category_id;
        END IF;
      END IF;

      v_stock_qty := COALESCE((v_row->>'stock')::numeric, 0);

      IF v_existing_id IS NOT NULL THEN
        -- C-21 checkpoint #2: products.stock no existe — el stock va solo a branch_stock.
        -- productos-categoria-text-retiro: la columna TEXT de categoría ya no
        -- existe — el nombre lo deriva la vista desde category_id (D1).
        UPDATE public.products SET
          name               = COALESCE(NULLIF(v_row->>'name',''),       name),
          category_id        = COALESCE(v_category_id,                   category_id),
          price              = COALESCE((v_row->>'price')::numeric,      price),
          -- productos-costo-nullable (D10): celda vacía en la EDICIÓN
          -- conserva el costo que el producto tenía — no lo borra. Es la
          -- misma convención tri-estado-por-ausencia que sku/category_id.
          cost               = COALESCE((v_row->>'cost')::numeric,       cost),
          min_stock          = COALESCE((v_row->>'min_stock')::integer,  min_stock),
          barcode            = COALESCE(NULLIF(v_row->>'barcode',''),    barcode),
          parent_id          = COALESCE(v_resolved_pid,                  parent_id),
          is_variant         = COALESCE((v_row->>'is_variant')::boolean, is_variant),
          stock_control_type = COALESCE(NULLIF(v_row->>'stock_control_type',''), stock_control_type),
          account_id         = COALESCE(account_id, v_account_id)
        WHERE id = v_existing_id AND account_id = v_account_id;

        v_product_id := v_existing_id;
        v_updated    := v_updated + 1;

      ELSE
        -- productos-categoria-text-retiro: la columna de categoría se retiró
        -- del INSERT — no existe más la columna física ni el trigger que la pisaba.
        INSERT INTO public.products (
          user_id, account_id, name, category_id, price, cost, min_stock,
          barcode, sku, parent_id, is_variant, stock_control_type
        ) VALUES (
          p_user_id,
          v_account_id,
          v_row->>'name',
          COALESCE(v_category_id, v_default_category),
          COALESCE((v_row->>'price')::numeric,    0),
          -- productos-costo-nullable (D10): celda vacía en el ALTA queda
          -- NULL (sin costo), no 0. Un padre variant_only (rama "Padre" del
          -- importador) manda cost NULL desde el frontend — acá no se
          -- distingue el caso, simplemente se propaga lo que llegó.
          (v_row->>'cost')::numeric,
          COALESCE((v_row->>'min_stock')::integer, 0),
          NULLIF(v_row->>'barcode', ''),
          NULLIF(v_row->>'sku',     ''),
          v_resolved_pid,
          COALESCE((v_row->>'is_variant')::boolean, false),
          COALESCE(NULLIF(v_row->>'stock_control_type',''), 'tracked')
        )
        RETURNING id INTO v_product_id;

        v_inserted := v_inserted + 1;
      END IF;

      -- Stock del CSV → branch_stock (default branch), set absoluto.
      -- Sólo para filas no-Padre (stock > 0 o stock explícito en el CSV).
      IF v_default_branch IS NOT NULL
         AND v_product_id IS NOT NULL
         AND (v_row->>'stock' IS NOT NULL OR v_stock_qty > 0)
      THEN
        INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity, min_stock)
        VALUES (
          v_account_id,
          v_product_id,
          v_default_branch,
          v_stock_qty,
          COALESCE((v_row->>'min_stock')::integer, 0)
        )
        ON CONFLICT (product_id, branch_id)
          DO UPDATE SET
            quantity  = EXCLUDED.quantity,
            min_stock = EXCLUDED.min_stock;
      END IF;

      IF v_row->'attributes' IS NOT NULL AND jsonb_array_length(v_row->'attributes') > 0 THEN
        FOR v_attr IN SELECT * FROM jsonb_array_elements(v_row->'attributes')
        LOOP
          INSERT INTO public.product_attributes (product_id, user_id, key, value, sort_order)
          VALUES (
            v_product_id,
            p_user_id,
            v_attr->>'key',
            v_attr->>'value',
            COALESCE((v_attr->>'sort_order')::integer, 0)
          )
          ON CONFLICT (product_id, key) DO UPDATE
            SET value      = EXCLUDED.value,
                sort_order = EXCLUDED.sort_order;
        END LOOP;
      END IF;

    EXCEPTION WHEN OTHERS THEN
      v_error_detail := jsonb_build_object(
        'row',     (v_row->>'row_no')::int,   -- ← importador-productos-fastapi (D2): ÚNICA adición
        'sku',     v_row->>'sku',
        'name',    v_row->>'name',
        'message', SQLERRM
      );
      v_errors := v_errors || jsonb_build_array(v_error_detail);
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'inserted', v_inserted,
    'updated',  v_updated,
    'errors',   v_errors
  );
END;
$function$;

-- importador-productos-fastapi (D4): REVOKE de authenticated se aplica MÁS
-- ABAJO (paso 5), DESPUÉS de que rpc_import_products exista — nunca antes,
-- para no dejar una ventana sin ningún camino de importación funcionando.

-- ── 4) rpc_import_products — la unidad de trabajo del lote ─────────────────
--
-- Todo o nada (D3): un bloque BEGIN...EXCEPTION de PL/pgSQL es una
-- SUBTRANSACCIÓN — cuando su excepción se captura, TODO el estado de base de
-- datos escrito dentro del bloque se deshace y la transacción exterior queda
-- SANA (no abortada). Las VARIABLES LOCALES de PL/pgSQL, en cambio, NO se
-- deshacen con ese rollback — es la única razón por la que v_errors/
-- v_inserted/v_updated sobreviven al RAISE deliberado y pueden volver por el
-- RETURN normal. Esto importa porque con tenancy_tx_scope_enabled ON el
-- request de FastAPI corre DENTRO de una transacción explícita: si la
-- excepción escapara de esta función, esa transacción quedaría abortada
-- (25P02) y el service no podría volver a tocar la base para construir la
-- respuesta.
--
-- D1: el corazón es UNA SOLA invocación de rpc_bulk_upsert_products con el
-- archivo COMPLETO — no una por fila. Cero reglas del upsert copiadas acá:
-- ni resolución de SKU, ni jerarquía, ni categorías, ni branch_stock.

CREATE OR REPLACE FUNCTION public.rpc_import_products(
  p_idempotency_key text,
  p_rows jsonb,
  p_file_name text,
  p_file_hash text,
  p_dry_run boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid              uuid;
  v_account_id       uuid;
  v_account_count    integer;
  v_row_count        integer;
  v_import_id        uuid;
  v_inserted_slot    integer;
  v_existing_op      uuid;
  v_existing_import  public.product_imports%ROWTYPE;
  v_committed        boolean := true;
  v_inserted         integer := 0;
  v_updated          integer := 0;
  v_errors           jsonb := '[]'::jsonb;
  v_new_categories   jsonb := '[]'::jsonb;
  v_res              jsonb;
BEGIN
  -- ── Guards de sesión / tenant / rol de escritura (D4) — el upsert NUNCA
  -- tuvo is_account_writer; este es el hueco (2) del proposal, cerrado en
  -- el único punto de paso ───────────────────────────────────────────────
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Corrección de revisión (ronda 3, F1) — REGRESIÓN real, no candidato: el
  -- `ORDER BY cai` que la ronda 1 sumó SÓLO acá hacía que esta resolución
  -- divergiera de la de `rpc_bulk_upsert_products` (línea ~215, sin ORDER
  -- BY e imposible de tocar sin salirse de D2) para un usuario con más de
  -- una cuenta: medido 6/8 divergencias sobre 8 usuarios multi-cuenta
  -- sintéticos, con el guard evaluando `is_account_writer` sobre una cuenta
  -- AJENA al destino real de la escritura y rechazando con P0401 a un owner
  -- legítimo. Fix: esta resolución vuelve a ser la MISMA consulta LITERAL
  -- que usa `rpc_bulk_upsert_products` (sin ORDER BY, coinciden 8/8 sin él)
  -- y, además, se rechaza explícitamente la ambigüedad: el import de lote
  -- no tiene selector de cuenta, así que un usuario con más de una
  -- membresía no tiene forma de decir "a cuál" — ambigüedad pasa a ser
  -- P0403 en vez de una resolución no determinística que dependa del plan
  -- de consulta. Medido en prod el 2026-09-10: 0 usuarios pertenecen hoy a
  -- más de una cuenta (y, por transitividad, 0 cuentas con más de un
  -- usuario tienen productos), así que este guard no reproduce en ningún
  -- caso real — cierra el hueco de raíz en vez de dejarlo como candidato
  -- (ver design.md D4, decisión de la ronda 3).
  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  SELECT count(*) INTO v_account_count FROM public.current_account_ids();
  IF v_account_count > 1 THEN
    RAISE EXCEPTION 'cuenta_ambigua: la importación en lote requiere que el usuario pertenezca a una única cuenta activa (tiene %)', v_account_count
      USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- ── Validación de FORMA del payload (P0427) — fuera del bloque de lote:
  -- un payload malformado no es un error de fila, es un error de protocolo
  -- (D6 del design: tope de 2.500, sin trocear — bajado del 5.000 original,
  -- ver nota post-review en el encabezado del archivo) ─────────────────────
  IF p_file_name IS NULL OR btrim(p_file_name) = ''
     OR p_file_hash IS NULL OR btrim(p_file_hash) = '' THEN
    RAISE EXCEPTION 'import_payload_invalido: file_name y file_hash son obligatorios'
      USING ERRCODE = 'P0427';
  END IF;

  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'import_payload_invalido: p_rows debe ser un array JSON de filas de producto'
      USING ERRCODE = 'P0427';
  END IF;

  v_row_count := jsonb_array_length(p_rows);
  IF v_row_count < 1 THEN
    RAISE EXCEPTION 'import_payload_invalido: el archivo no tiene filas de datos'
      USING ERRCODE = 'P0427';
  END IF;
  IF v_row_count > 2500 THEN
    RAISE EXCEPTION 'import_cap_excedido: máximo 2500 filas por lote (recibidas %) — no se trocea', v_row_count
      USING ERRCODE = 'P0427';
  END IF;

  -- ── Subtransacción del LOTE (D3) ─────────────────────────────────────────
  BEGIN
    -- Dedupe de dominio (D8): mismo archivo ya importado por esta cuenta →
    -- replay, sin escribir un segundo lote. Corre incluso en dry_run: no hay
    -- nada nuevo que deshacer si esta rama se toma (ningún INSERT precede).
    SELECT * INTO v_existing_import
    FROM public.product_imports
    WHERE account_id = v_account_id AND file_hash = p_file_hash;

    IF FOUND THEN
      RETURN jsonb_build_object(
        'committed',      true,
        'import_id',      v_existing_import.id,
        'inserted',       v_existing_import.inserted,
        'updated',        v_existing_import.updated,
        'errors',         '[]'::jsonb,
        'new_categories', '[]'::jsonb,
        'replayed',       true,
        'dry_run',        p_dry_run
      );
    END IF;

    -- Idempotencia técnica (D8): slot en operation_idempotency. Un reintento
    -- con la misma clave recupera el lote ya aplicado.
    v_import_id := gen_random_uuid();

    INSERT INTO public.operation_idempotency
      (user_id, idempotency_key, operation_kind, operation_id)
    VALUES
      (v_uid, p_idempotency_key, 'product_import', v_import_id)
    ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

    GET DIAGNOSTICS v_inserted_slot = ROW_COUNT;

    IF v_inserted_slot = 0 THEN
      SELECT operation_id INTO v_existing_op
      FROM public.operation_idempotency
      WHERE user_id = v_uid
        AND operation_kind = 'product_import'
        AND idempotency_key = p_idempotency_key;

      SELECT * INTO v_existing_import
      FROM public.product_imports
      WHERE id = v_existing_op;

      IF v_existing_import.id IS NOT NULL THEN
        RETURN jsonb_build_object(
          'committed',      true,
          'import_id',      v_existing_import.id,
          'inserted',       v_existing_import.inserted,
          'updated',        v_existing_import.updated,
          'errors',         '[]'::jsonb,
          'new_categories', '[]'::jsonb,
          'replayed',       true,
          'dry_run',        p_dry_run
        );
      END IF;
      -- v_existing_import.id IS NULL: la clave se usó para un lote que se
      -- RECHAZÓ (D3 — "un lote rechazado no quema la clave"). Como el
      -- INSERT de operation_idempotency de ESE intento anterior vivía
      -- dentro de SU propio bloque de lote, quedó deshecho junto con todo
      -- lo demás — así que acá nunca deberíamos entrar. Se deja la rama
      -- por defensa en profundidad: si de algún modo ocurriera, se sigue
      -- de largo con un v_import_id recién generado — nunca se retorna un
      -- resultado vacío en silencio (mismo criterio que rpc_import_expenses).
      v_import_id := gen_random_uuid();
      INSERT INTO public.operation_idempotency
        (user_id, idempotency_key, operation_kind, operation_id)
      VALUES
        (v_uid, p_idempotency_key || ':' || v_import_id::text, 'product_import', v_import_id)
      ON CONFLICT DO NOTHING;
    END IF;

    -- Categorías que ESTA llamada crearía (lectura informativa para el
    -- veredicto, D7): usa el MISMO helper de normalización que el upsert
    -- (product_category_normalize_name) — no es una segunda definición de
    -- la regla de categorías, sólo un resumen de lo que la llamada de abajo
    -- va a hacer. Se computa ANTES de invocar el upsert: después, las
    -- categorías ya existirían y el NOT EXISTS dejaría de detectarlas.
    --
    -- Corrección de revisión (ronda 3, F2): agrupar por el nombre normalizado
    -- TAL CUAL (sin lower()) trataba "Zapatillas"/"zapatillas"/"ZAPATILLAS"
    -- como TRES categorías nuevas distintas, cuando el upsert (bloque (f),
    -- resolución de categoría por fila: `lower(pc.name) = lower(v_cat_name)`
    -- más arriba en esta misma función) crea UNA sola — el anuncio no
    -- coincidía con lo que el servidor iba a hacer, justo lo que la spec de
    -- categorías de producto declara normativo para este veredicto. Se
    -- agrupa por `lower(...)` y se elige un nombre canónico con `min(...)`
    -- sobre las variantes de capitalización, sumando sus filas.
    SELECT COALESCE(jsonb_agg(jsonb_build_object('name', x.name, 'rows', x.cnt) ORDER BY x.name), '[]'::jsonb)
      INTO v_new_categories
    FROM (
      SELECT min(public.product_category_normalize_name(r->>'category')) AS name,
             COUNT(*) AS cnt
        FROM jsonb_array_elements(p_rows) AS r
       WHERE public.product_category_normalize_name(r->>'category') IS NOT NULL
         AND NOT EXISTS (
           SELECT 1 FROM public.product_categories pc
            WHERE pc.account_id = v_account_id
              AND pc.deleted_at IS NULL
              AND lower(pc.name) = lower(public.product_category_normalize_name(r->>'category'))
         )
       GROUP BY lower(public.product_category_normalize_name(r->>'category'))
    ) x;

    -- Fila de importación (D8) — nace con inserted=0/updated=0 y se corrige
    -- al final del lote si commitea.
    INSERT INTO public.product_imports
      (id, account_id, user_id, file_name, file_hash, rows_total, inserted, updated)
    VALUES
      (v_import_id, v_account_id, v_uid, btrim(p_file_name), p_file_hash, v_row_count, 0, 0);

    -- ── El corazón (D1): UNA sola invocación con el archivo COMPLETO ──────
    -- rpc_bulk_upsert_products resuelve la cuenta desde la SESIÓN
    -- (current_account_ids()) y valida p_user_id contra auth.uid() — los
    -- dos leen GUCs de la conexión del request, que SECURITY DEFINER no
    -- cambia (cambia el usuario de PRIVILEGIOS, no los GUCs de sesión). El
    -- guard de tenencia no se debilita por la llamada anidada.
    --
    -- Si el archivo introduce más de 50 categorías nuevas distintas, el
    -- upsert lanza P0400 ACÁ ADENTRO, sin capturarlo esta función: al no
    -- coincidir con el WHEN SQLSTATE 'P0429' de más abajo, la subtransacción
    -- del lote se deshace igual (ninguna categoría de la "primera mitad"
    -- queda creada) y P0400 se propaga tal cual al caller — mismo
    -- tratamiento que el tope de filas (P0427): un rechazo de FORMA/CUOTA,
    -- no un error de fila.
    v_res := public.rpc_bulk_upsert_products(p_rows, v_uid);

    v_inserted := COALESCE((v_res->>'inserted')::int, 0);
    v_updated  := COALESCE((v_res->>'updated')::int, 0);
    v_errors   := COALESCE(v_res->'errors', '[]'::jsonb);

    -- D3/D7: cualquier error de fila O modo simulación fuerza el rollback
    -- de TODO el bloque de lote (productos, categorías, branch_stock,
    -- atributos, product_imports, el slot de idempotencia — todo). Las
    -- variables locales (v_errors/v_inserted/v_updated/v_new_categories)
    -- sobreviven y viajan por el RETURN normal de más abajo.
    IF jsonb_array_length(v_errors) > 0 OR p_dry_run THEN
      RAISE EXCEPTION 'batch_rollback' USING ERRCODE = 'P0429';
    END IF;

    UPDATE public.product_imports
       SET inserted = v_inserted, updated = v_updated
     WHERE id = v_import_id;
  EXCEPTION WHEN SQLSTATE 'P0429' THEN
    v_committed := false;
  END;

  RETURN jsonb_build_object(
    'committed',      v_committed,
    'import_id',      CASE WHEN v_committed THEN v_import_id ELSE NULL END,
    'inserted',       v_inserted,
    'updated',        v_updated,
    'errors',         v_errors,
    'new_categories', v_new_categories,
    'replayed',       false,
    'dry_run',        p_dry_run
  );
END;
$function$;

-- ACLs explícitas EN EL MISMO ARCHIVO que la función (v3-api-standards):
-- función nueva → CREATE OR REPLACE alcanza, sin DROP previo, sin riesgo de
-- overload 42725.
REVOKE ALL ON FUNCTION public.rpc_import_products(
  text, jsonb, text, text, boolean
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_import_products(
  text, jsonb, text, text, boolean
) FROM anon;
GRANT EXECUTE ON FUNCTION public.rpc_import_products(
  text, jsonb, text, text, boolean
) TO authenticated;

COMMENT ON FUNCTION public.rpc_import_products(
  text, jsonb, text, text, boolean
) IS
  'importador-productos-fastapi: lote transaccional de importación de productos, todo o nada. '
  'Invoca rpc_bulk_upsert_products UNA VEZ con el archivo completo (no duplica sus reglas). '
  'Idempotente por clave y deduplicado por file_hash. '
  'p_dry_run=true ejecuta el mismo camino y siempre revierte (vista previa).';

-- ── 5) REVOKE de rpc_bulk_upsert_products de authenticated (D4/OQ-7) ───────
-- Se aplica AL FINAL, después de que rpc_import_products ya exista y tenga
-- su GRANT — el backend queda como único camino desde el primer instante en
-- que este archivo se aplica completo. Checkpoint 1.5: inventario de callers
-- cerrado — los gates SQL que invocan rpc_bulk_upsert_products directo
-- (test_bulk_upsert_products_categories.sql, test_productos_costo_nullable.sql,
-- test_products_barcode_account_scope.sql, test_product_category_derived.sql)
-- corren como `postgres` (DSN de KPI_Validation.yml), no como `authenticated`
-- — el REVOKE no los afecta. `service_role` conserva su EXECUTE (jobs
-- administrativos, sin cambios).
REVOKE EXECUTE ON FUNCTION public.rpc_bulk_upsert_products(jsonb, uuid) FROM authenticated;

COMMENT ON FUNCTION public.rpc_bulk_upsert_products(jsonb, uuid) IS
  'Alta masiva de productos. Invocable SOLO desde rpc_import_products (SECURITY DEFINER) y service_role — '
  'importador-productos-fastapi (D4) le retira EXECUTE a authenticated: el backend es el único camino de importación.';
