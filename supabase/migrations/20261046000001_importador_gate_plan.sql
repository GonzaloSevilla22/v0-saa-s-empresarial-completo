-- ============================================================================
-- importador-gate-plan (2026-09-11)
--
-- Cierra la OQ-1 de importador-productos-fastapi (task 4.7, NO implementada
-- en 20261044000001 por falta de sign-off) con el sign-off del PO del
-- 2026-09-11, regla literal: "las cuentas que hoy superan el máximo de su
-- plan conservan sus productos, pero no pueden agregar más; si quieren
-- agregar, tienen que eliminar productos hasta no exceder el máximo de su
-- plan". Ver design.md §D5 / §OQ-1 de ese change (archivado) para el
-- pseudocódigo original — este archivo lo implementa tal cual, dentro de la
-- subtransacción del lote, sobre el estado RESULTANTE (nunca a priori).
--
-- Integridad de función — verificado contra el cuerpo VIVO de PROD el
-- 2026-09-11 vía mcp__supabase__execute_sql (read-only):
--   rpc_import_products(text,jsonb,text,text,boolean)
--     = 6f9ec8331f0f8cb412f09280118a1b6c (11585 chars, SIN \r — el cuerpo
--       vivo de prod nunca tuvo CRLF). El cuerpo vivo LOCAL (checkout
--       Windows, migración 20261044000001 con CRLF) hashea DISTINTO en
--       crudo pero IDÉNTICO (mismo md5, mismo largo) una vez normalizado
--       \r\n → \n — es el mismo gotcha ya registrado en
--       project_pg_functiondef_crlf_deno_gotchas: CRLF del checkout
--       Windows, no divergencia de contenido. Confirmado línea por línea
--       antes de escribir este archivo. Este archivo reescribe DESDE ESE
--       CUERPO, con las adiciones de más abajo — nada más cambia.
--   rpc_bulk_upsert_products(jsonb,uuid) — NO SE TOCA (regla de la tarea:
--       ninguna otra función se reescribe).
--   get_effective_plan(uuid) / plan_limits — NO SE TOCAN (sólo se
--       referencian). get_effective_plan no tiene EXECUTE para
--       `authenticated` (sólo supabase_auth_admin/service_role), pero
--       rpc_import_products es SECURITY DEFINER con owner `postgres`
--       (superusuario) — la llamada interna no requiere GRANT, igual que
--       reporting_plan_window ya lo hace en rpc_sales_evolution.
--
-- Qué cambia, exactamente (nada más):
--   1) DECLARE: 7 variables nuevas (v_plan, v_limit, v_before, v_after,
--      v_added, v_plan_exceeded, v_plan_verdict).
--   2) Al ENTRAR a la subtransacción del lote, ANTES del dedupe por
--      file_hash: se computa el plan efectivo, su tope y el conteo de
--      productos VIVOS de la cuenta — de una sola vez, porque las DOS ramas
--      de replay (dedupe por archivo, replay por clave) también necesitan
--      poder informar el estado del plan sin re-evaluar nada (un replay no
--      escribe: "antes" y "después" son el mismo número).
--   3) Las DOS ramas de replay suman el campo 'plan' a su RETURN (antes no
--      lo tenían — no existía el campo).
--   4) Después de invocar rpc_bulk_upsert_products (el corazón, D1, sigue
--      siendo UNA sola llamada con el archivo completo): se cuenta
--      v_after, se deriva v_added y v_plan_exceeded, y se arma
--      v_plan_verdict. La condición de rollback del lote suma
--      `OR v_plan_exceeded` a la que ya tenía (errores de fila O dry_run).
--   5) El RETURN final (bloque no-replay, cubre tanto committed=true como
--      committed=false por errores/plan/dry_run) suma 'plan': v_plan_verdict.
--
-- Predicado de "producto VIVO" (decisión de esta tarea, con evidencia — ver
-- CHANGES.md): `deleted_at IS NULL`, EXACTAMENTE el mismo predicado que
-- `BaseRepository.not_deleted_clause()` / `ProductRepository.count_by_org`
-- YA usan (confirmado leyendo el código: count_by_org ya hace
-- `AND deleted_at IS NULL` desde v3-soft-delete-policy — el enunciado de la
-- tarea de que "cuenta COUNT(*) sin excluir deleted_at" está desactualizado,
-- la baja de producto es SIEMPRE soft-delete vía `ProductRepository.
-- soft_delete("products", ...)`, nunca DELETE físico). No hace falta tocar
-- Python: el mensaje del formulario ("Límite de productos alcanzado para el
-- plan {plan} ({limit} máx.). Borrá productos existentes o subí de plan.",
-- `backend/services/products.py`) y el conteo del importador usan, desde
-- hoy, el MISMO predicado canónico — el gate SQL (g) lo verifica.
--
-- ERRCODEs: NINGUNO nuevo. `P0430` sigue RESERVADO (backend/core/errors.py,
-- 403) pero NO se emite acá — el veredicto de plan viaja por el RETURN
-- normal (`committed: false` + `plan.exceeded: true`), exactamente como un
-- lote con errores de fila o en modo simulación. Es la semántica exacta que
-- pidió el PO: "conservan sus productos" (nada se toca) — un rechazo
-- silencioso con motivo, no una excepción de protocolo.
--
-- Idempotente: reaplicable sin duplicar nada (CREATE OR REPLACE, misma
-- firma, sin DROP).
-- ============================================================================

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
  -- importador-gate-plan (D5/OQ-1, sign-off PO 2026-09-11): límite de
  -- productos del plan, evaluado sobre el estado RESULTANTE.
  v_plan             text;
  v_limit            integer;
  v_before           integer;
  v_after            integer;
  v_added            integer;
  v_plan_exceeded    boolean := false;
  v_plan_verdict     jsonb;
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
    -- importador-gate-plan (D5/OQ-1): snapshot del plan efectivo, su tope y
    -- el conteo de productos VIVOS de la cuenta AL INICIO del lote — mismo
    -- predicado canónico que ProductRepository.count_by_org /
    -- BaseRepository.not_deleted_clause() (deleted_at IS NULL). Se computa
    -- ACÁ, antes del dedupe/idempotencia, porque las DOS ramas de replay de
    -- abajo también informan 'plan' en su RETURN sin re-evaluar nada: un
    -- replay no escribe, así que "antes" y "después" son el mismo número.
    -- Corrección de revisión (ronda 1 adversarial, MAJOR — TOCTOU): serializar
    -- el lote por CUENTA con un advisory lock de TRANSACCIÓN, ANTES de contar
    -- v_before. Bajo READ COMMITTED, dos lotes concurrentes sobre la MISMA
    -- cuenta no se ven entre sí (cada uno sólo ve las filas ya COMMITEADAS de
    -- la otra transacción), así que cada uno calcula su propio v_after
    -- ignorando lo que la otra está insertando — y las DOS pasan el gate.
    -- REPRODUCIDO en la base local: dos lotes de 60 filas simultáneos sobre una
    -- cuenta gratis (tope 100) vacía terminaron con 120 productos, ambos
    -- committed=true. El lock es de TRANSACCIÓN (pg_advisory_xact_lock, nunca
    -- pg_advisory_lock — no hace falta UNLOCK explícito): se libera al
    -- terminar la TRANSACCIÓN de tope (el sub-bloque de EXCEPTION de más
    -- abajo NO lo suelta ni al "commitear" (liberar el SAVEPOINT implícito)
    -- ni al abortarlo — un advisory xact lock vive atado a la transacción de
    -- nivel superior, no a un sub-bloque interno), que es exactamente la
    -- duración que el invariante necesita: cubre hasta el COMMIT real de las
    -- filas nuevas de este request. hashtextextended(..., 0) evita colisionar
    -- con cualquier otro advisory lock del proyecto que use un uuid distinto
    -- como semilla (no hay otro conocido hoy, pero el segundo argumento deja
    -- el espacio de claves separado por convención).
    PERFORM pg_advisory_xact_lock(hashtextextended(v_account_id::text, 0));

    v_plan := public.get_effective_plan(v_account_id);

    SELECT pl.max_products INTO v_limit
      FROM public.plan_limits pl
     WHERE pl.plan = v_plan;

    SELECT count(*) INTO v_before
      FROM public.products
     WHERE account_id = v_account_id AND deleted_at IS NULL;

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
        'plan',           jsonb_build_object(
          'plan', v_plan, 'limit', v_limit, 'before', v_before,
          'after', v_before, 'added', 0, 'exceeded', false
        ),
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
          'plan',           jsonb_build_object(
            'plan', v_plan, 'limit', v_limit, 'before', v_before,
            'after', v_before, 'added', 0, 'exceeded', false
          ),
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

    -- importador-gate-plan (D5/OQ-1, sign-off PO 2026-09-11): el límite de
    -- productos del plan se evalúa sobre el estado RESULTANTE, NUNCA a
    -- priori — evita duplicar el predicado de upsert (D1: "cero reglas del
    -- upsert copiadas"; calcular a priori exigiría repetir "¿existe un
    -- producto vivo con este SKU?"). Regla exacta del PO: "las cuentas que
    -- hoy superan el máximo de su plan conservan sus productos, pero no
    -- pueden agregar más; si quieren agregar, tienen que eliminar productos
    -- hasta no exceder el máximo de su plan" — por eso el gate SOLO dispara
    -- si esta llamada AGREGA productos (v_after > v_before) Y el resultado
    -- excede el tope; un archivo que sólo actualiza SKUs existentes nunca
    -- se bloquea, aunque la cuenta ya esté por encima del límite hoy.
    SELECT count(*) INTO v_after
      FROM public.products
     WHERE account_id = v_account_id AND deleted_at IS NULL;

    v_added         := v_after - v_before;
    v_plan_exceeded := (v_limit IS NOT NULL AND v_after > v_before AND v_after > v_limit);

    v_plan_verdict := jsonb_build_object(
      'plan',     v_plan,
      'limit',    v_limit,
      'before',   v_before,
      'after',    v_after,
      'added',    v_added,
      'exceeded', v_plan_exceeded
    );

    -- D3/D7: cualquier error de fila O plan excedido O modo simulación
    -- fuerza el rollback de TODO el bloque de lote (productos, categorías,
    -- branch_stock, atributos, product_imports, el slot de idempotencia —
    -- todo). Las variables locales (v_errors/v_inserted/v_updated/
    -- v_new_categories/v_plan_verdict) sobreviven y viajan por el RETURN
    -- normal de más abajo. El rechazo por plan NO es una excepción de
    -- protocolo (no se emite P0430 — sigue reservado): viaja como
    -- `committed: false` + `plan.exceeded: true`, igual que un error de
    -- fila — "conservan sus productos" es exactamente "no se escribe nada".
    IF jsonb_array_length(v_errors) > 0 OR v_plan_exceeded OR p_dry_run THEN
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
    'plan',           v_plan_verdict,
    'replayed',       false,
    'dry_run',        p_dry_run
  );
END;
$function$;

-- ACLs SIN CAMBIOS — CREATE OR REPLACE sobre la MISMA firma preserva las
-- existentes ({postgres, authenticated, service_role}, sin anon; verificado
-- en prod el 2026-09-11 antes de escribir este archivo). Se re-emiten
-- explícitas de todos modos (v3-api-standards: ACLs siempre explícitas en
-- el mismo archivo que la función), sin que esto cambie nada.
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
  'importador-productos-fastapi + importador-gate-plan: lote transaccional de importación de productos, todo o nada. '
  'Invoca rpc_bulk_upsert_products UNA VEZ con el archivo completo (no duplica sus reglas). '
  'Idempotente por clave y deduplicado por file_hash. '
  'p_dry_run=true ejecuta el mismo camino y siempre revierte (vista previa). '
  'El RETURN siempre trae `plan` (plan efectivo, tope, antes/después/agregados, excedido) — '
  'el gate de plan (OQ-1, sign-off PO 2026-09-11) bloquea el lote ENTERO cuando la importación '
  'AGREGA productos y el resultado excede el tope del plan; una importación que sólo actualiza '
  'SKUs existentes nunca se bloquea, aunque la cuenta ya esté por encima del límite.';
