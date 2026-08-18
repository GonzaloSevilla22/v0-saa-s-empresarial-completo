## Why

Agosto dejó cinco deudas menores acumuladas de changes ya cerrados: un feature flag de cutover que nunca se completó (26 de 35 cuentas), un campo legacy que la UI sigue pidiendo aunque nadie lo persiste, un orden por defecto que quedó como pregunta abierta, basura histórica en la telemetría, y código muerto en el cliente de analytics admin. Ninguna es grave por separado; juntas producen datos incompletos (ventas sin líneas ⇒ sin snapshot de costo ⇒ rentabilidad histórica infiel), UI que miente (un "Estado" manual que no hace nada) y ruido que hace más caro cada change siguiente.

El PO firmó las cinco decisiones el 2026-08-18. Este change las ejecuta como una sola pasada de limpieza, sin abrir frentes nuevos.

## What Changes

### G1 — `sale_items_rpc_v2` activo para todas las cuentas

- **Mecanismo real** (verificado): tabla `public.account_feature_flags (account_id, flag_key, enabled)`; los wrappers `rpc_create_sale_operation` y `rpc_create_purchase_operation` leen `flag_key = 'sale_items_rpc_v2'` y despachan a `_v2` (escribe `sale_items` / `purchase_items` con snapshots) o al cuerpo legacy (sólo header plano). **Un solo flag gobierna ventas y compras.**
- **Estado en prod**: 26 filas, todas `enabled = true`, creadas el 2026-06-10; **35 cuentas** en total ⇒ **9 cuentas sin fila = camino legacy**. Las 58 ventas de agosto sin líneas se reparten entre esas cuentas y el hueco de edición (ver OQ-1).
- **Cambio**: el flag pasa de *opt-in* a *opt-out*. Ausencia de fila deja de significar "legacy" y pasa a significar "v2"; además se materializa una fila `enabled = true` por cada cuenta existente, para que el rollback siga siendo un `UPDATE` de una línea. **BREAKING (de comportamiento, no de contrato)**: cuentas hoy en legacy empiezan a escribir líneas.

### G2 — `clients.status` legacy deprecado y oculto

- La UI deja de mostrar y de enviar el campo manual `status` (`Estado`: activo/inactivo/perdido). El único estado visible en clientes pasa a ser el **calculado** (`frecuente`/`activo`/`inactivo`/`sin_compras`, spec `client-activity`).
- La columna `clients.status` **NO se dropea** y ningún dato se toca.

### G3 — Orden por defecto de `/clientes`: última compra primero

- El default pasa de `name ASC` a `last_purchase DESC NULLS LAST`, resuelto **en el repository/endpoint** (los agregados ya existen en el `LEFT JOIN LATERAL` de `ClientRepository`), no en el cliente. Cierra la OQ-4 de `clientes-frecuentes-historial`.

### G4 — Limpieza de datos históricos de `analytics_events`

- **(a)** Borrado idempotente de los `operation_created` **huérfanos** (clave de entidad sin fila en `sales`/`purchases`/`expenses`) y de los duplicados por clave de entidad del emisor legacy retirado. Re-derivación en la propia migración: **nada de ids hardcodeados ni de conteos asumidos**, con `RAISE NOTICE` de lo efectivamente borrado.
- **(b)** Backfill determinístico de `account_id` en las líneas legacy que lo tienen nulo, desde su venta/compra padre. **NO se agrega `NOT NULL`** (fuera de alcance).

### G5 — Código muerto en `frontend/lib/adminAnalytics.ts`

- Se remueven los 4 wrappers sin ningún consumidor (`fetchActivationRate`, `fetchUmvRate`, `fetchPaidConversionRate`, `fetchInsightsBreakdown`) y el tipo que sólo ellos usan. **Las RPCs `get_admin_*` en la base NO se tocan** — dropearlas es otro riesgo y queda anotado como deuda aparte. Cierra la OQ-6 de `admin-kpi-refresh`.

## Capabilities

### New Capabilities

Ninguna.

### Modified Capabilities

- `sale-line-items`: el gate de escritura de líneas deja de ser un opt-in por cuenta — la escritura de `sale_items`/`purchase_items` pasa a ser el comportamiento por defecto de toda cuenta, presente y futura, y el flag queda como kill-switch explícito. Además, `sale_items.account_id` / `purchase_items.account_id` deben quedar poblados en toda fila histórica.
- `client-activity`: el estado del cliente que la UI expone es exclusivamente el calculado (el campo manual deja de tener superficie de lectura o edición), y el orden por defecto de la lista pasa a ser última compra descendente con los clientes sin compras al final.
- `product-analytics-events`: se agrega la invariante de integridad referencial lógica — todo `operation_created` referencia una operación existente, y no hay dos eventos para la misma operación.

## Impact

**Base de datos (prod, gxdhpxvdjjkmxhdkkwyb)** — dos migraciones idempotentes nuevas (`MAX(version)` real verificado: `20260923000001`):

- `rpc_create_sale_operation`, `rpc_create_purchase_operation` (`CREATE OR REPLACE`, cambia sólo el default del flag)
- `public.account_feature_flags` (UPSERT de una fila por cuenta)
- `public.analytics_events` (DELETE acotado y re-derivado)
- `public.sale_items`, `public.purchase_items` (UPDATE de `account_id` nulo — 23 y 18 filas al momento de escribir)

**Backend Python**: `backend/repositories/client_repository.py`, `backend/routers/clients.py` (defaults de `sort`/`sort_dir`).

**Frontend**: `frontend/components/forms/client-form.tsx`, `frontend/app/(dashboard)/clientes/page.tsx`, `frontend/hooks/data/use-clients.ts`, `frontend/hooks/data/use-client-activity.ts`, `frontend/lib/types.ts`, `frontend/lib/adminAnalytics.ts`.

**Superficie frontend**: G2 y G3 modifican una pantalla existente (`/clientes`) — se quita un control del formulario de cliente y cambia el orden por defecto de la lista. No hay pantalla ni ruta nueva. G1, G4 y G5 **no tienen superficie frontend** (G5 sólo remueve código sin render).

**Riesgo**: concentrado en G1 (toca la ruta de escritura de ventas y compras en producción). Governance MEDIUM con sign-off explícito del PO y rollback de una línea.
