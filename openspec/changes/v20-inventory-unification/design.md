# Design — v20-inventory-unification (C-21)

> Governance CRÍTICO. Propuesta para revisión del PO **antes de implementar o aplicar cualquier migración**. Los DROP (columna `products.stock`; tablas del Sistema B) son checkpoints separados, cada uno con su propia aprobación explícita (espejo de C-19/C-20).

## Context

**Estado actual (auditado en prod `gxdhpxvdjjkmxhdkkwyb`, 2026-06-12):**

Existen **tres** representaciones de stock conviviendo:

1. **Sistema A — activo, fuente de verdad de facto:**
   - `branch_stock(id, account_id NOT NULL, product_id NOT NULL, branch_id NOT NULL, quantity numeric DEFAULT 0, min_stock integer DEFAULT 0)` — **2.246 filas**. UNIQUE `(product_id, branch_id)`. FKs a `accounts`, `branches`, `products` (todas `ON DELETE CASCADE`). **No tiene `variant_id` ni `unit_id`.** 0 filas huérfanas.
   - `stock_movements` — 492 filas; ledger inmutable con `quantity_before/after`, `movement_number` (bigint seq), `operation_group_id`, ya tiene `account_id` y `branch_id` (nullable). **No se toca** (DEC-07 / DEC-20).
   - `branches(id, account_id NOT NULL, name, address, is_active DEFAULT true, created_at)` — **12 filas**, una por cada una de 12 cuentas, todas llamadas **"Principal"** (onboarding V2, 2026-06-07). **No existe columna `is_default`.**
2. **`products.stock numeric DEFAULT 0`** — columna mutable en `products` (4.673 filas). El schema documenta el hack (H4): solo se actualiza cuando la operación **no** tiene `branch_id`. **`products.stock ≠ Σ branch_stock` en 636 productos** (612 tienen `products.stock > 0` y **cero** filas en `branch_stock`; el resto, divergencias por el dual-ledger).
3. **Sistema B — muerto, duplicado stale:**
   - `inventory_stock(variant_id NOT NULL, warehouse_id NOT NULL, quantity integer)` — **19 filas**, sin `account_id`. En **2 warehouses** (15+4). Cada `variant_id` → `product_variants.product_id` → `products.account_id` resuelve **limpio** (19/19). **Las 19 ya existen en `branch_stock`** para el mismo `(product_id, branch_id)`: 12 quantities coinciden, **7 difieren** (la data del Sistema B está stale respecto al activo).
   - `inventory_movements(id, company_id, variant_id, warehouse_id, movement_type, quantity integer, …)` — 22 filas. Usa `company_id` (tenancy legacy), no `account_id`.
   - `warehouses(id, company_id, name, created_at)` — **6 filas**, todas "Main Warehouse", creadas 2026-03-11 (auto-generadas por el viejo sistema de companies). PA-19 resuelta: descartar.
   - Afectación en código activo: **solo `database.types.ts`** (tipos generados). Sin consumidores en la app.

**Cuentas sin branch:** 14 de 26 no tienen ninguna branch; **0 de ellas tienen productos**. Las 2 cuentas con stock del Sistema B (`3834e5d7…`, `c4145451…`) **ya tienen** su branch "Principal" y sus 19 productos **ya están** en `branch_stock`.

**Reescritura del scope original (CHANGES.md §C-21):** el scope asumía "migrar 19 filas de `inventory_stock` + 22 de `inventory_movements` a `branch_stock`/`stock_movements`". La auditoría muestra que esos datos **ya están en `branch_stock`** (insertarlos violaría el UNIQUE `(product_id, branch_id)` o corrompería stock activo con valores stale). El trabajo real es: (a) crear branch por defecto donde falte, (b) **reconciliar `products.stock` → `branch_stock`** para los 636 divergentes (este es el riesgo, no el Sistema B), (c) verificar-y-descartar el Sistema B, (d) cortar lecturas, (e) DROP.

**Lecturas que tocan `products.stock`:**
- `backend/repositories/stock_repository.py` — `SELECT stock FROM products WHERE id = $1 AND user_id = $2` (doble deuda: columna legacy + tenancy `user_id`).
- 14 archivos frontend que leen `row.stock`/`product.stock` (ver proposal §Impact). El hook `use-products.ts` es el punto de entrada (`stock: Number(p.stock)`); el resto consume del hook o lee la columna en queries/imports.

**Constraints:** RN-97 (nada nuevo sobre tablas en retirada). DEC-07 (`stock_movements` inmutable, NO se toca). DEC-19 (branch root; `products.stock` se retira; total = Σ). DEC-20 (consistencia transaccional venta+stock — fuera de scope de C-21, lo construye C-26). Migraciones solo vía `npx supabase db push`. Vistas con `security_invoker = true` (sin esto bypassan RLS — crítico, datos cross-tenant).

## Goals / Non-Goals

**Goals:**
- `branch_stock` queda como **única fuente de verdad** del stock; `Σ branch_stock` reproduce el stock visible **antes** de cualquier corte de lectura (sin cambios silenciosos de inventario).
- Toda cuenta tiene **una branch por defecto** (invariante de DEC-19 / prerequisito de C-26).
- Reconciliación idempotente `products.stock` → `branch_stock` para los 636 productos divergentes.
- Verificación reproducible de que el Sistema B es descartable; tablas del Sistema B eliminadas.
- Lecturas (backend `StockRepository`, 14 archivos frontend, importador CSV) migradas a `branch_stock`/`v_products_with_stock`.
- `products.stock` retirado (DROP) como checkpoint final controlado.

**Non-Goals:**
- NO se promueve `Branch` a Aggregate Root con `open()/close()` ni se crea `StockTransfer` como entidad — eso es **C-26** (`v21-branch-as-root`).
- NO se introduce consistencia transaccional venta+stock (DEC-20) — eso es C-26; C-21 solo unifica el ledger de lectura.
- NO se toca `stock_movements` (DEC-07) ni la lógica de RPCs de venta/compra (C-20 ya cerró eso).
- NO se agrega `variant_id`/`reserved`/`unit_id` a `branch_stock` (el modelo V2 los prevé, pero hoy `branch_stock` es por `product_id`; ampliarlo es trabajo de C-26).
- NO se refactoriza la tenancy `user_id`→`account_id` global (C-19 lo cerró; aquí solo se corrige la query de `stock_repository.py`).
- NO se migra IA/OCR de lugar (DEC-15).
- Las 19 filas del Sistema B **no se insertan** en `branch_stock` (ya están). Las 7 divergentes se resuelven por reconciliación de `products.stock`, no copiando del Sistema B (ver OQ-B).

## Decisions

### D1 — Branch por defecto: reusar "Principal", crear donde falte (no agregar `is_default`)

**Decisión:** La "Branch Casa Central" del scope = la branch por defecto de la cuenta. Para las 12 cuentas que ya tienen "Principal", **esa** es la branch por defecto (no se crea otra). Para las cuentas sin branch, `INSERT INTO branches (account_id, name) VALUES (<acc>, 'Casa Central')` idempotente (`WHERE NOT EXISTS (SELECT 1 FROM branches WHERE account_id = <acc>)`).

**`is_default`:** `branches` no tiene esa columna. La regla "una sola branch por cuenta hoy → es la default" se resuelve por **convención** (la única branch de la cuenta), sin agregar columna en C-21. Agregar `is_default` correctamente (UNIQUE parcial `WHERE is_default`, default en onboarding, semántica de cambio de default) es responsabilidad de **C-26** donde Branch se vuelve root. **OQ-A** lo eleva al PO por si prefiere agregarla ya.

**Alternativa descartada:** crear una nueva "Casa Central" para las 12 cuentas que ya tienen "Principal" — duplicaría branches y partiría el stock existente en dos. Rechazada.

### D2 — Reconciliación `products.stock` → `branch_stock` (el corazón del change, no el Sistema B)

**Decisión:** Antes de cualquier corte de lectura, una migración de datos idempotente garantiza que `Σ branch_stock.quantity == products.stock` (el valor visible hoy) para todo producto no borrado. Para cada producto con `products.stock <> COALESCE(Σ branch_stock, 0)`:
- Si **no** hay fila `branch_stock` para `(product, default_branch)`: `INSERT` con `quantity = products.stock` (vía upsert sobre el UNIQUE `(product_id, branch_id)`), `account_id` y `branch_id` = branch por defecto de la cuenta del producto.
- Si **ya** hay fila(s) y la suma difiere: **OQ-B** — la política de reconciliación (¿`branch_stock` gana? ¿`products.stock` gana? ¿ajuste a la default branch para cuadrar?) la decide el PO. Por defecto propuesto: **ajustar la fila de la default branch** para que `Σ branch_stock == products.stock` (preserva el stock que el usuario ve hoy; trata `branch_stock` como reparto y `products.stock` como total autoritativo durante la transición).

**Idempotencia:** upsert con `ON CONFLICT (product_id, branch_id) DO UPDATE` solo sobre la default branch + recomputar contra el estado actual; re-ejecutar converge al mismo resultado.

**Validación (gate):** post-reconciliación, `SELECT count(*) FROM products p WHERE p.deleted_at IS NULL AND p.stock <> COALESCE((SELECT SUM(quantity) FROM branch_stock bs WHERE bs.product_id = p.id),0)` **debe ser 0**. Sin esto verde, no se avanza al corte de lectura.

**Por qué esto y no migrar el Sistema B:** el Sistema B (19 filas) ya está en `branch_stock`; el stock que **realmente** se perdería al cortar la lectura son los 612 productos con `products.stock > 0` y sin `branch_stock`. Ese es el dato a preservar.

**Alternativa descartada:** confiar en que la vista `Σ branch_stock` "ya es correcta" y cortar la lectura directo. Rechazada: cambiaría a 0 (o a un valor distinto) el stock visible de 636 productos en producción con usuarios reales.

### D3 — Verificación y descarte del Sistema B (no migración)

**Decisión:** Una query de auditoría **reproducible** (incluida en las tasks y en la migración como comentario/assertion) verifica antes del DROP que: (a) las 19 filas de `inventory_stock` resuelven a un `(product_id, branch_id)` que existe en `branch_stock`; (b) los 6 `warehouses` son "Main Warehouse" auto-generados sin uso activo; (c) ninguna función/vista del schema referencia `inventory_stock`/`inventory_movements`/`warehouses` (`pg_get_functiondef`, `pg_views`). Verde → DROP de las 3 tablas en una migración destructiva (checkpoint con aprobación PO). Los 7 productos con quantity divergente quedan cubiertos por la reconciliación de D2 (la verdad es `products.stock`, no el Sistema B stale).

**Alternativa descartada:** `INSERT ... SELECT` de `inventory_stock` a `branch_stock`. Rechazada: viola el UNIQUE `(product_id, branch_id)` (las filas ya existen) y, si se forzara con `ON CONFLICT DO UPDATE`, sobreescribiría stock activo con valores stale (7 casos).

### D4 — Vista de compatibilidad `v_products_with_stock` (`security_invoker = true`)

**Decisión:** `CREATE VIEW v_products_with_stock WITH (security_invoker = true) AS SELECT p.*, COALESCE((SELECT SUM(bs.quantity) FROM branch_stock bs WHERE bs.product_id = p.id), 0) AS stock_total FROM products p`. Crítico el `security_invoker` (sin él la vista bypassa RLS → fuga cross-tenant; advisor de Supabase lo marca). Expone el total para los consumidores que aún leen el formato plano. Se **conserva** post-DROP como capa de lectura (no hay columna `stock` que reemplazar tras el DROP; la vista la reconstruye).

**Detalle de naming:** la vista expone el total como `stock_total` (o `stock` si se prefiere que el reemplazo sea drop-in para los consumidores — **OQ-C**). Si se llama `stock`, los 15 consumidores cambian solo el `.from('products')` por `.from('v_products_with_stock')` sin tocar el nombre de campo.

**Alternativa descartada:** columna generada `GENERATED ALWAYS AS` en `products` — imposible, no puede referenciar otra tabla. Materialized view — innecesaria al volumen actual y agrega refresh/staleness.

### D5 — Migrar lecturas: backend, frontend, importador

**Decisión:**
- **Backend** `stock_repository.py`: la query pasa de `SELECT stock FROM products WHERE id=$1 AND user_id=$2` a `SELECT COALESCE(SUM(bs.quantity),0) FROM branch_stock bs WHERE bs.product_id = $1 AND bs.account_id = $2` (corrige de paso la tenancy `user_id`→`account_id`, alineado con C-19). `StockOut`/schema Pydantic ajusta el origen del campo sin cambiar el contrato del API.
- **Frontend**: el punto de entrada es `use-products.ts` (`stock: Number(p.stock)`). Reapuntar el source del hook a `v_products_with_stock` (campo `stock`/`stock_total` según OQ-C). Los 13 archivos restantes consumen del hook → idealmente **cero cambios** si el shape del hook se mantiene. Los que leen la columna en queries directas (`importer.ts`, `validator.ts`, `buildBusinessSnapshot.ts`, `aiCopilotService.ts`) se reapuntan a la vista.
- **Importador CSV** (`importer.ts`): hoy **escribe** `products.stock`. Debe pasar a escribir en `branch_stock` contra la branch por defecto de la cuenta (upsert). Este es el único consumidor de **escritura**; el resto son lecturas. (Mientras `products.stock` exista, puede escribir ambos durante la transición — ver Migration Plan.)

**Alternativa descartada:** que cada uno de los 15 archivos calcule `Σ branch_stock` por su cuenta. Rechazada: duplica la lógica; la vista la centraliza.

### D6 — Orden de los DROP (dos checkpoints destructivos separados)

**Decisión:** Dos migraciones destructivas, cada una su propio checkpoint con aprobación PO, **no** incluidas en el primer push:
1. **DROP tablas Sistema B** (`inventory_stock`, `inventory_movements`, `warehouses`) — tras D3 verde. Bajo riesgo (sin consumidores activos).
2. **DROP `products.stock`** — tras D2 verde + lecturas migradas + período de observación con la vista en uso. Riesgo real; pre-DROP guard que falla si alguna función/vista (fuera de la lista esperada) referencia `products.stock`. Incluir en la migración el SQL inverso (ADD COLUMN + backfill `UPDATE products SET stock = Σ branch_stock`) como hizo C-19.

Pueden ir en orden 1→2 o juntas; se proponen **separadas** porque el riesgo es asimétrico (Sistema B es seguro; `products.stock` necesita observación).

## Risks / Trade-offs

- **[Cambiar la fuente de lectura a `Σ branch_stock` altera el stock visible de 636 productos]** → backfill/reconciliación D2 **antes** del corte + gate de validación `count(divergentes)=0` + vista de compat. Tests que comparan stock pre/post por producto. **Riesgo dominante del change.**
- **[Vista sin `security_invoker` filtra datos cross-tenant]** → `WITH (security_invoker = true)` explícito; `get_advisors` tras la migración; test de que un usuario solo ve su stock vía la vista.
- **[DROP `products.stock` rompe un consumidor no detectado]** → pre-DROP guard sobre `pg_get_functiondef`/`pg_views` + auditoría de los 15 archivos + observación con la vista activa antes del DROP; SQL inverso documentado para rollback.
- **[Reconciliar con `branch_stock` ganando borraría el stock real de 612 productos]** → la política por defecto de D2 es `products.stock` autoritativo (preserva lo visible); `branch_stock` gana solo si el PO lo decide (OQ-B).
- **[`inventory_movements`/`warehouses` usan `company_id`, no `account_id`]** → no se migran (se descartan); ninguna lógica activa los lee.
- **[Importador escribía `products.stock`]** → reapuntar a `branch_stock` (upsert contra default branch); test del importador escribiendo en `branch_stock`. Único punto de escritura a migrar.
- **[CI de `main` corre `supabase db push --include-all`]** → migraciones completas en el repo (nunca stubs); las destructivas se mergean recién tras aprobación del PO, no antes.
- **[Branch "Casa Central" vs "Principal" — naming inconsistente]** → reusar "Principal" donde existe; "Casa Central" solo para las nuevas. La UI oculta el selector si hay una sola branch (DEC-19). Unificar el naming es cosmético y opcional (OQ-A).

## Migration Plan

1. **Migración A (no destructiva, push 1):**
   - Crear branch por defecto ("Casa Central") para las 14 cuentas sin branch (idempotente).
   - Reconciliación D2: upsert `products.stock` → `branch_stock` (default branch) para los 636 divergentes. Gate de validación verde.
   - `CREATE VIEW v_products_with_stock WITH (security_invoker = true)`. RLS verificada. `get_advisors`.
2. **Migrar lecturas (push 1, mismo PR o siguiente):** `stock_repository.py` → suma sobre `branch_stock` por `account_id`; `use-products.ts` y los archivos de query directa → la vista; `importer.ts` → escribe `branch_stock` (y `products.stock` en paralelo mientras la columna exista). Todo sigue consistente porque `Σ branch_stock == products.stock` tras la reconciliación.
3. **Período de observación:** la vista en uso, stock visible idéntico al previo (validación por muestreo en prod, read-only).
4. **Checkpoint PO #1 (push 2, destructivo):** D3 verde → aprobación → DROP `inventory_stock`/`inventory_movements`/`warehouses`. `get_advisors`. Regenerar `database.types.ts`.
5. **Checkpoint PO #2 (push 3, destructivo):** pre-DROP guard de `products.stock` verde + aprobación → DROP `products.stock`; importador deja de escribir la columna; ajustar la vista si hace falta (sobrevive: se computa de `branch_stock`). SQL inverso en la migración. `get_advisors`. Regenerar `database.types.ts`.
6. **CHANGES.md** marcar C-21 `[x]` post-archive.

**Rollback por etapa:** push 1 → revertir lecturas a `products.stock` (sigue viva y reconciliada). push 2 (DROP Sistema B) → restaurar desde backup si fuese necesario (sin consumidores, improbable). push 3 (DROP `products.stock`) → SQL inverso: `ALTER TABLE products ADD COLUMN stock numeric DEFAULT 0; UPDATE products SET stock = COALESCE(Σ branch_stock,0)`.

## Open Questions

> **Resueltas por el PO (2026-06-12)** — las cuatro con la opción propuesta por el design:

- **OQ-A — RESUELTA:** Reusar la "Principal" existente como branch por defecto; crear "Casa Central" solo para las cuentas sin branch. La columna `is_default` se difiere a C-26 (branch-as-root); la default se resuelve por convención (única branch de la cuenta).
- **OQ-B — RESUELTA:** `products.stock` es autoritativo — se ajusta la fila de la default branch para que `Σ branch_stock == products.stock` (preserva el stock visible hoy). Aplica a los 7 productos divergentes.
- **OQ-C — RESUELTA:** La vista expone el total como campo `stock` (drop-in: los 15 consumidores solo cambian la tabla, no el nombre del campo).
- **OQ-D — RESUELTA:** Dos checkpoints destructivos separados — DROP Sistema B primero, DROP `products.stock` después con período de observación. Cada uno requiere aprobación explícita del PO.
