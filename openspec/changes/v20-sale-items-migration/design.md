# Design — v20-sale-items-migration (C-20)

> Governance ALTO. Propuesta para revisión del PO antes de implementar. El DROP de columnas del header es un checkpoint separado con su propia aprobación (espejo de C-19).

## Context

**Estado actual (auditado en prod `gxdhpxvdjjkmxhdkkwyb`, 2026-06-10):**

- `sales` (135 filas, 133 con `product_id`) y `purchases` (184, 181 con `product_id`) guardan la línea **en el header**. Cada fila ES un ítem; `operation_id` agrupa el carrito (69 ops de venta sobre 117 filas agrupadas + 18 sueltas). Columnas flat: `product_id`, `amount` (precio unitario), `quantity` (`numeric(15,4)`), `total`, `unit_id`.
- Las tablas `sale_items`/`purchase_items` **ya existen** pero con un esquema del importador de variantes que **no sirve** como fuente de verdad del modelo flat:
  - `sale_items(id, sale_id NOT NULL FK→sales.id, variant_id NOT NULL FK→product_variants.id, quantity INTEGER, price numeric, subtotal numeric)` — 23 filas.
  - `purchase_items(id, purchase_id NOT NULL FK→purchases.id, variant_id NOT NULL FK→product_variants.id, quantity INTEGER, price, subtotal)` — 18 filas.
  - **Bloqueos**: `variant_id` es `NOT NULL` (PA-20 exige `NULL`); FK a `product_variants` (el flat usa `product_id`→`products`); `quantity` es `integer` (hay 2 ventas fraccionales; pierde datos); faltan `account_id`, `unit_id`, `amount`.
- RPC vigente: `rpc_create_sale_operation(text, uuid, date, text, jsonb, uuid p_branch_id, text p_canal)` (migración `20260612000000_sales_channel.sql`), `SECURITY DEFINER`, resuelve `account_id` vía `current_account_ids()`, idempotencia 3-col `(user_id, operation_kind, idempotency_key)`. **Inserta en `sales`, no en `sale_items`.** Símil para `rpc_create_purchase_operation(text, date, text, jsonb)`.
- Lecturas que tocan campos planos:
  - `backend/repositories/sales_repository.py::list_paginated_by_operation` — `SELECT s.id, s.product_id, s.quantity, s.amount, s.total ...`.
  - `backend/repositories/purchase_repository.py` — análogo + `delete_by_id`/`delete_by_operation` que leen `product_id` para revertir stock.
  - `frontend/hooks/data/use-sales.ts::mapSale` y `use-purchases.ts` — leen `product_id`/`amount`/`quantity` del row del API.
  - EFs `ai-insights/index.ts` (líneas 98–142) y `ai-precio/index.ts` (198–248) — `supabase.from('sales').select('amount, quantity, ... product_id')`.

**Constraints:** RN-97 (nada nuevo sobre tablas en retirada). DEC-06 (idempotencia). DEC-07 (ledger `stock_movements` inmutable — NO se toca; sigue ligado al header por `reference_id`). Migraciones solo vía `npx supabase db push`. Vistas con `security_invoker = true` (si no, bypassan RLS — crítico).

## Goals / Non-Goals

**Goals:**
- `sale_items`/`purchase_items` se vuelven la **fuente de verdad** de la línea, con esquema compatible con el modelo flat (`product_id`, `variant_id NULL`, `quantity numeric`, `unit_id`, `account_id`, `price`/`subtotal`).
- Backfill idempotente 1:1 de las filas flat → ítems, sin pérdida (incluye cantidades fraccionales).
- RPC versionado: nueva versión escribe header + ítem atómicamente; legacy disponible como fallback por feature flag, con cutover/rollback claros.
- Lecturas (repos, hooks, EFs) migradas a leer del ítem o de la vista de compat.
- Header flat retirado (DROP) como último paso, en checkpoint con aprobación PO.

**Non-Goals:**
- NO se reestructura el modelo header/operation: cada `sales` row sigue siendo una "venta" con su `operation_id`; el ítem es 1:1 con esa row (`sale_id = sales.id`). Consolidar N ítems bajo un único header por `operation_id` es trabajo futuro (C-29 quote/salesorder), fuera de scope.
- NO se introducen variantes default ni se materializan variantes para los productos flat (PA-20: `variant_id = NULL`).
- NO se toca el ledger `stock_movements` ni la lógica de stock/branch_stock (DEC-07; eso es C-21).
- NO se migra IA/OCR de lugar (DEC-15).
- Las 23+18 filas de ítems preexistentes del importador **no se migran ni borran**: conviven; el backfill solo cubre filas flat que aún no tienen ítem.

## Decisions

### D1 — Estrategia de backfill e idempotencia (DEC-06)

**Decisión:** Backfill 1:1 dentro de una migración SQL transaccional. Por cada `sales` con `product_id NOT NULL` que **no** tenga ya una fila en `sale_items`, insertar una fila: `sale_id = s.id`, `account_id = s.account_id`, `product_id = s.product_id`, `variant_id = NULL`, `quantity = s.quantity`, `unit_id = s.unit_id`, `price = s.amount`, `subtotal = COALESCE(s.total, s.amount * s.quantity)`.

**Idempotencia:** la inserción se hace con `INSERT ... SELECT ... WHERE NOT EXISTS (SELECT 1 FROM sale_items si WHERE si.sale_id = s.id AND si.product_id = s.product_id)`. Re-ejecutar la migración no duplica. Para hacerlo a prueba de re-run total, se añade un índice único parcial `UNIQUE (sale_id, product_id) WHERE product_id IS NOT NULL` (no choca con las 23 filas de variantes, que tienen `product_id IS NULL`).

**Alternativa descartada:** backfill desde el backend Python en un script de migración de datos — más control pero fuera de la transacción del schema y sin la red de RLS; una migración SQL `SECURITY` corre con privilegios de migración y es atómica con los `ALTER TABLE`.

**Validación post-backfill:** `SELECT count(*) FROM sales WHERE product_id IS NOT NULL` == `count(*) FROM sale_items si JOIN sales s ON si.sale_id = s.id WHERE si.product_id IS NOT NULL`. Espejo para compras.

### D2 — Mecánica del RPC versionado (coexistencia, flag, cutover, rollback)

**Decisión:** Crear `rpc_create_sale_operation_v2(...)` (mismo set de parámetros que la firma vigente de 7 args) que, además de insertar el header en `sales`, inserta la fila `sale_items` en la **misma transacción**, y deja de escribir las columnas flat que vamos a dropear (o las escribe en paralelo durante la ventana de transición — ver Migration Plan). La versión vigente (`rpc_create_sale_operation`) **no se borra**: queda como fallback legacy.

**Ubicación del feature flag — decisión: setting de DB**, no env del backend ni del frontend. Un wrapper `rpc_create_sale_operation` (la firma pública que ya llaman backend y PostgREST) lee un flag y despacha a v2 o al cuerpo legacy:

```sql
-- Flag: app.sale_items_rpc_v2 (current_setting con fallback)
IF current_setting('app.sale_items_rpc_v2', true) = 'on' THEN
   RETURN rpc_create_sale_operation_v2(...);
ELSE
   <cuerpo legacy>
END IF;
```

El flag se setea por `ALTER DATABASE postgres SET app.sale_items_rpc_v2 = 'on'` (o vía tabla `app_settings` leída por la función, si se prefiere granularidad por cuenta). **Por qué DB y no backend/frontend:** (a) el cambio de destino es atómico con la transacción del RPC, sin esperar redeploy de Render ni de Vercel; (b) backend y PostgREST llaman la **misma** firma pública — un solo punto de control; (c) rollback inmediato con un `ALTER ... SET ... = 'off'`. Consistente con el espíritu de la spec `strangler-fig-feature-flag` (que ya retiró los flags `NEXT_PUBLIC_USE_PYTHON_API` del frontend — no reintroducir flags de cliente).

**Cutover:** flag `off` por default al deploy de la migración → el sistema sigue 100% legacy, pero el wrapper, v2, las columnas nuevas y la vista ya existen y el backfill ya corrió. Validar en prod (crear una venta con flag `on` para una cuenta de prueba, verificar fila en `sale_items`). Luego `on` global. **Rollback:** `off` global; las ventas creadas con v2 ya tienen su fila `sale_items` Y (durante la ventana de transición) sus columnas flat, así que el camino legacy las sigue leyendo sin pérdida.

**Alternativa descartada:** dos RPCs con nombres distintos y el backend eligiendo cuál llamar por env var. Rechazada: mueve el control al deploy del backend (Render cold start, dos destinos), reintroduce lógica de flag en código y rompe la llamada por nombre de PostgREST.

### D3 — Vista de compatibilidad `v_sales_flat` / `v_purchases_flat`

**Decisión:** Crear `v_sales_flat` con `security_invoker = true` (Postgres 15+, crítico — sin esto la vista bypassa RLS y filtra datos cross-tenant). Expone las columnas flat **calculadas desde el ítem** para los consumidores que aún no migraron:

```sql
CREATE VIEW v_sales_flat WITH (security_invoker = true) AS
SELECT s.id, s.account_id, s.client_id, s.operation_id, s.date, s.currency, s.canal, s.branch_id,
       si.product_id, si.price AS amount, si.quantity, si.subtotal AS total, si.unit_id
FROM sales s
LEFT JOIN sale_items si ON si.sale_id = s.id;
```

**Consumidores durante la transición:** las Edge Functions `ai-insights` y `ai-precio` (que se reapuntan de `sales` a `v_sales_flat`), y cualquier query ad-hoc/legacy. Los repos del backend NO usan la vista: migran directamente al `JOIN sale_items` (más eficiente, controlado por nosotros). **Remoción planificada:** la vista se borra en el mismo change, después del DROP de columnas flat y una vez que ai-insights/ai-precio leen del JOIN o de la vista ya basada en ítems (la vista sobrevive al DROP porque se computa desde el ítem, no desde las columnas dropeadas — por eso es segura como puente). Si tras el DROP las EFs siguen contra `v_sales_flat`, la vista puede quedar permanentemente como capa de compat de lectura; el equipo decide en el checkpoint final si se retira o se conserva.

**Alternativa descartada:** columnas generadas (`GENERATED ALWAYS AS`) en el propio header — imposible, una columna generada no puede referenciar otra tabla.

### D4 — Orden de los DROP (checkpoint con aprobación PO)

**Decisión:** Los DROP de `sales.product_id/amount/quantity/total/unit_id` y equivalentes en `purchases` son el **último grupo de tasks**, en una **migración separada** que NO se incluye en el primer push. Espejo de cómo C-19 trató los DROP: se proponen, se valida en prod que (a) ningún consumidor lee las columnas del header, (b) la vista de compat está activa y correcta, (c) v2 está `on` global y estable por un período de observación. Recién entonces el PO aprueba ("dale") y se aplica la migración de DROP.

Subdecisión — `stock_movements.reference_id`: hoy apunta a `sales.id`/`purchases.id` (la row-ítem). Como mantenemos 1:1 (`sale_id = sales.id`), el ledger **no cambia**: sigue referenciando el header, que sigue existiendo. No hay que reescribir referencias. (DEC-07 intacto.)

**Pre-DROP guard:** un query de verificación (parte de las tasks) que falla si alguna columna a dropear todavía es leída por funciones/vistas (`pg_get_functiondef`, `pg_views`) fuera de la lista esperada.

### D5 — Ventas y compras: ¿un change o grupos secuenciados?

**Decisión:** **Un solo change**, con **grupos de tasks secuenciados**: primero el camino completo de ventas (schema → backfill → RPC v2 → repo → hook → EFs → validación), y una vez verde, el camino simétrico de compras (schema → backfill → RPC v2 → repo → hook → validación). Compras no tiene Edge Functions que la lean directo (las EFs solo leen `sales`), así que su grupo es más chico. Los DROP de ambas se hacen juntos en el checkpoint final. **Por qué un change:** comparten el mismo patrón, la misma vista-puente conceptual y el mismo checkpoint de DROP; separarlos duplicaría el overhead de propose/apply/archive sin reducir riesgo. **Por qué secuenciados y no en paralelo:** ventas es el camino crítico (C-29/C-30 dependen de ventas, no de compras) y concentra el riesgo (EFs, dashboard channel margin); estabilizar ventas primero da una plantilla validada para compras.

## Risks / Trade-offs

- **[Romper el hot path de ventas / dinero / stock]** → RPC versionado con flag de DB `off` por default; v2 escribe ítem **y** (durante la ventana) columnas flat, así que legacy sigue leyendo; rollback es un `ALTER DATABASE ... = 'off'`. TDD: tests pytest del RPC v2 y de los repos antes de tocar producción.
- **[Vista sin `security_invoker` filtra datos cross-tenant]** → la spec exige `WITH (security_invoker = true)` explícito; advisor de Supabase (`get_advisors`) corrido tras la migración; test que verifica que un usuario solo ve sus ventas vía la vista.
- **[Pérdida de cantidades fraccionales en el backfill]** → `quantity` se amplía a `numeric(15,4)` **antes** del backfill; test específico con las 2 ventas fraccionales conocidas.
- **[Colisión con las 23+18 filas del importador de variantes]** → esas filas tienen `product_id IS NULL` (son de `variant_id`); el índice único parcial y el `WHERE NOT EXISTS` las excluyen; no se tocan.
- **[`ai-insights`/`ai-precio` rompen al cambiar de `sales` a la vista]** → la vista expone exactamente los mismos nombres de columna (`product_id`, `amount`, `quantity`, `date`) que las EFs ya consumen; cambio mínimo de `.from('sales')` a `.from('v_sales_flat')`; se valida con una corrida de cada EF en preview.
- **[Drift de overloads del RPC]** (problema histórico documentado en `20260528162050`) → la nueva versión usa wrapper + función `_v2` con firmas explícitas y `DROP FUNCTION IF EXISTS` de firmas viejas; `REVOKE`/`GRANT` explícitos como en las migraciones previas.
- **[`reference_id` en `stock_movements` es `text` apuntando a la row-ítem]** → al mantener 1:1, no se rompe; pero si en el futuro se consolida a un header único (C-29), habrá que migrar referencias. Documentado como deuda diferida.

## Migration Plan

1. **Migración A (no destructiva, push 1):** `ALTER TABLE sale_items/purchase_items` (nullable `variant_id`, add `product_id`/`account_id`/`unit_id`, widen `quantity`, índice único parcial). Backfill idempotente. Crear `rpc_*_operation_v2` + wrapper con flag (`off` por default). Crear `v_sales_flat`/`v_purchases_flat` (`security_invoker`). RLS en las columnas/tablas nuevas. `get_advisors`.
2. **Migrar lecturas (push 1, mismo PR o siguiente):** repos backend → `JOIN sale_items`; hooks frontend → mapear desde el nuevo shape; EFs → `v_sales_flat`. Todo sigue funcionando con flag `off` porque v2 escribe columnas flat también.
3. **Cutover progresivo:** validar v2 en prod con cuenta de prueba (flag `on` scoped si se usa `app_settings`, o global tras smoke test) → `on` global → período de observación.
4. **Checkpoint PO (push 2, destructivo):** pre-DROP guard verde → aprobación explícita del PO → Migración B: DROP de columnas flat en `sales`/`purchases`; v2 deja de escribir flat; ajustar la vista si hace falta. `get_advisors`. Regenerar `database.types.ts`.
5. **CHANGES.md** marcar C-20 `[x]` post-archive.

**Rollback por etapa:** push 1 → flag `off` (instantáneo, sin redeploy). push 2 (DROP) → es destructivo; rollback = restaurar columnas desde la vista/ítems con un `ALTER ADD COLUMN` + backfill inverso (documentar el SQL inverso en la propia migración B, como hizo C-19).

## Resolved Decisions (PO — 2026-06-10)

- **OQ1 → POR CUENTA (resuelto por PO):** El flag se implementa **por cuenta** usando una tabla `account_feature_flags(account_id, flag_key, enabled)`. No se usa `current_setting('app.sale_items_rpc_v2')` ni `ALTER DATABASE`. La función v2 wrapper lee el flag con `SELECT enabled FROM account_feature_flags WHERE account_id = v_account_id AND flag_key = 'sale_items_rpc_v2'` (default `false` / off si no existe la fila). Esto permite cutover gradual cuenta por cuenta. Si la tabla no existe se crea en la migración (no existe en el schema actual).
- **OQ2 → DOBLE ESCRITURA (resuelto por PO):** Durante la ventana de transición, `rpc_create_sale_operation_v2` escribe `sale_items` **y** las columnas flat del header (`product_id`, `amount`, `quantity`, `total`, `unit_id`) en la misma transacción. Rollback = apagar el flag, cero pérdida de datos. Mismo comportamiento para compras.
- **OQ3 → CONSERVAR (resuelto por PO):** `v_sales_flat` y `v_purchases_flat` se conservan permanentemente post-DROP como capa de lectura para las EFs de IA (DEC-15). No se retiran en este change ni en el checkpoint B.
