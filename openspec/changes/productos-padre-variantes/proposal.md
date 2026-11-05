## Why

El PO pidió (2026-11-05) poder corregir la unidad de medida de un producto padre y que la corrección llegue a sus variantes, y diferenciar el alta de un producto padre de la de un producto individual: hoy un único formulario pide en el padre stock inicial, stock mínimo, código de barras, código de balanza, SKU, precio y costo, datos que un padre no usa. La medición de prod confirma el problema: el guard de unidad (D-C) traba el cambio en **472 de 494** padres con hijos (algún hijo tiene historia), el formulario no puede crear un padre `variant_only` (los 644 nacieron del importador y hay 233 "padres" `tracked` armados a mano), 17 padres tienen precio/costo cargado que nadie lee, y no existe forma de cambiar precios de muchos productos a la vez. En la revisión 2 el PO descartó la herencia de precio/costo ("confunde a los usuarios") y sumó un modificador de precios en lote y una sugerencia de precio (costo × 1,5). Exploración completa: `openspec/explore/2026-11-05-productos-padre-variantes.md`.

## What Changes

- **Alta y edición diferenciadas** (A): el diálogo de `/productos` arranca con "¿Qué querés crear?" (producto simple / producto con variantes). El formulario del padre pide sólo nombre, categoría y unidad de la familia; la variante hereda categoría y unidad y tiene stock, SKU, código de barras, PLU, precio y costo propios. "Nueva variante" desde la fila del padre. La edición espeja el modo del producto.
- **El padre no lleva precio, costo, stock, stock mínimo, SKU, código de barras ni PLU — y lo hace cumplir el servidor** (A/B): `POST`/`PUT /products` responden `422` tipado (`parent_field_not_allowed`) si un padre `variant_only` recibe alguno de esos datos con un valor distinto del vigente; el cambio de `stock_control_type` hacia o desde `variant_only` por la API se rechaza (`stock_control_type_locked`). Los 71 padres con código de barras legado lo conservan.
- **Padre sin precio/costo en la base** (B): backfill de los 17 padres (`price = 0`, `cost = NULL`) y CHECK `products_variant_only_no_price_cost`. **Sin herencia de precio/costo** (decisión del PO).
- **Unidad editable en el padre con cascada (relabel A2)** (C): `rpc_relabel_product_unit` (`SECURITY DEFINER`, guard de tenencia, sólo dueño/administrador) cambia la unidad base del padre **sin convertir cantidades**, deja a todas las variantes heredándola, audita, rechaza con `unit_relabel_conflict` si alguna línea del grupo se grabó con otra unidad explícita y admite vista previa (`p_dry_run`). El bloqueo `base_unit_locked` sigue vigente para el camino ordinario: el relabel es la excepción explícita, confirmada y auditada. **Formaliza la decisión D-C** (deja de ser provisoria).
- **Modificador de precios en lote** (D): acción "Modificar precios" junto a "Recategorizar" en `/productos`, con la misma selección; aumento o baja por porcentaje (−90 a +1000) o por importe fijo (piso 0), vista previa obligatoria, redondeo a pesos enteros con UNA definición compartida SQL/TS, sólo precio, padres expandidos a sus variantes y excluidos ellos mismos, dueño/administrador, auditado por lote. `rpc_bulk_adjust_prices` (`SECURITY DEFINER`).
- **Sugerencia de precio = costo × 1,5** (E) al escribir el costo en producto simple y variante, sin pisar nunca un precio escrito por el usuario. El importador no sugiere.
- Endpoints nuevos: `POST /products/{id}/relabel-unit` y `PATCH /products/bulk-price`.
- **BREAKING (contrato de API)**: un escritor que hoy manda precio/costo/stock/SKU/código de barras a un padre `variant_only` recibe `422` en vez de escribirlo. Único escritor conocido: el formulario actual, que manda los valores vigentes (compatibles con la regla "distinto del vigente").

## Capabilities

### New Capabilities

- `product-variants`: contrato del producto padre `variant_only` y de sus variantes — alta diferenciada, campos que el padre no admite (rechazo en servidor), padre sin precio/costo con CHECK, herencia de categoría y unidad en la variante, edición que espeja el modo, padres `tracked` legados mostrados como padre sin conversión.
- `product-bulk-pricing`: modificación de precios en lote desde `/productos` (porcentaje o importe, vista previa, redondeo compartido, expansión padre→variantes, rol, auditoría) y la sugerencia de precio costo × 1,5 en el formulario, que comparte la misma definición de redondeo.

### Modified Capabilities

- `units-of-measure`: el requirement del bloqueo de la unidad base efectiva deja de ser provisorio (D-C firmado) y gana la excepción formal del relabel; requirement nuevo del relabel de la familia con cascada, conflicto por línea en otra unidad, rol, auditoría y carrera.
- `product-sku`: el SKU opcional no se pide ni se admite en un padre `variant_only`.
- `product-category`: la variante hereda la categoría del padre también en la edición y el formulario la muestra como sólo lectura; el padre se crea con categoría.

## Impact

- **DB**: migración `20261093000001_productos_padre_variantes.sql` (backfill de 17 filas en 2 cuentas, CHECK, helper de redondeo, dos RPCs `SECURITY DEFINER` nuevas, `fn_product_base_unit_guard` re-derivado del cuerpo vivo con la salida del relabel por GUC local). Gates SQL nuevos cableados en `KPI_Validation.yml` vía `run_gate_strict.py`, test de carrera del relabel, re-ejecución de los gates que introspectan el guard de unidad.
- **Backend**: `backend/schemas/products.py`, `backend/services/products.py`, `backend/repositories/product_repository.py`, `backend/routers/products.py`; tests unitarios y del tier de integración.
- **Frontend**: `/productos` (`app/(dashboard)/productos/page.tsx`), `components/forms/product-form.tsx` (partido por modo), `components/products/product-catalog.tsx` (acción y diálogo "Modificar precios", rango "desde $X" en el padre, diálogo del relabel), `lib/product-pricing.ts` (nuevo), `lib/product-bulk-category.ts` (troceo generalizado), `hooks/data/use-products.ts`. Superficie: ruta `/productos`, entrada de menú existente "Productos" (Catálogo); sin entrada nueva. Verificación en desktop y móvil, tema claro y oscuro.
- **Governance**: MEDIO (maestro de producto, sin caja/banco/cuenta corriente), con un tramo ALTO acotado al relabel de unidad (reinterpreta cantidades ya grabadas).
- **KB**: RN-25 y la regla de unidades (inciso g) en `knowledge-base/05_reglas_de_negocio.md` se actualizan en el apply.
