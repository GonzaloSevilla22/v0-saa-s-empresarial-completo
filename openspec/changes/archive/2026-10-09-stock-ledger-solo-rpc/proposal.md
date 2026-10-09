## Why

> **Governance: ALTA.** El change escribe el ledger de stock y revoca privilegios de escritura sobre dos tablas con tráfico real. Hay un tramo cross-tenant (ocupación de saldos ajenos por `INSERT` directo, ver §"Qué está abierto"). Implementación con checkpoints 🛑 explícitos en cada tramo que toca privilegios o reescribe una RPC que mueve stock; nada se escribe contra prod fuera del `db push` del merge.

**Origen:** candidato `stock-ledger-solo-rpc` de `CHANGES.md` (diagnóstico 2026-10-03, sólo lectura, red team de `remitos-compra` y `remitos-venta`), **firmado por el PO el 2026-10-08** —*"firmo el candidato con las recomendaciones"*—. Las cinco decisiones de la ficha quedan cerradas con su recomendación y este propose **no las reabre**:

| # | Decisión firmada | Cómo la toma este change |
|---|---|---|
| 1 | Ajustan stock a mano **`owner`, `admin` y `stock`** (`CAN_STOCK`, ya definido en `backend/core/rbac.py:36` y sin uso) | Rol exigido **en la base** por un guard interno; el backend y la UI lo espejan |
| 2 | El **alta** de producto deja "Stock inicial" sola; la **edición** pide motivo o deriva al modal de ajuste | La edición **deriva al modal existente** (D9 del design): el formulario deja de mandar `stock` |
| 3 | **Tanda A = G1 sola** (PR chico, no toca callers); **Tanda B = G2 + G4 + resto de G5 + specs** | Dos migraciones, dos PRs de apply, un solo change |
| 4 | Backfill de los movimientos invisibles | **Ya hecho** por el fix ad-hoc #617 (`20261072000001`): no se repite |
| 5 | Importador de productos → ledger | **Non-Goal** explícito, candidato aparte |

### Qué está abierto hoy (leído de prod, 2026-10-03 y re-leído 2026-10-08)

1. **Las dos tablas del inventario se escriben por PostgREST.** `authenticated` conserva `INSERT`/`UPDATE`/`DELETE`/`TRUNCATE` a nivel tabla sobre `stock_movements` y `branch_stock` (`relacl`: `authenticated=arwdDxtm`). `stock_movements_account_insert` deja insertar a **cualquier miembro** de la cuenta, `viewer` incluido; `branch_stock_writer_insert`/`_update` dejan crear y pisar saldos a **7 de los 8 roles** (`is_account_writer`). Un `PATCH` de `branch_stock` no deja rastro en el ledger.
2. **Dos RPCs públicas mueven stock sin rol.** `rpc_apply_product_stock_delta` acepta `p_log_movement = false` (cambia el saldo **sin** movimiento) y `p_allow_negative`; `rpc_reverse_stock_movement` revierte lo que encuentre por `reference_id`, sin idempotencia. Encadenadas con (1) fabrican stock: control positivo **ejecutado** en el red team de `remitos-venta` (`openspec/changes/remitos-venta/evidence/logs/redteam.log` L79: fila forjada `reference_type='sale'` + reversa ⇒ stock 1 → 2).
3. **Tres RPCs de ajuste manual y ninguna exige rol + motivo.** El 97 % de los 1.829 ajustes manuales de prod entra por FastAPI (`POST`/`PUT /products` → `rpc_apply_product_stock_delta`) con un motivo fijo ("Stock inicial" / "Ajuste manual de stock") y **sin guard de rol de cuenta**; el modal de `/stock` (`rpc_stock_adjustment`) valida tenencia por `products.user_id` (legacy) y deja el motivo opcional; el ajuste por sucursal (`rpc_adjust_branch_stock`) exige `is_account_writer` y guarda el motivo en `notes`.
4. **Ocupación cruzada de saldos (por construcción, se ejecuta primero en el stack local).** `branch_stock_writer_insert` valida sólo `account_id`; con `UNIQUE (product_id, branch_id)` y FKs sin alcance de cuenta, un escritor de la cuenta A podría insertar `(A, producto de B, sucursal de B)` antes que B, y `c21_apply_branch_stock_delta` —que actualiza por producto y sucursal— acumularía ahí el stock de B, invisible para B. Es el único tramo cross-tenant y la razón de la governance ALTA.

**¿Algún cliente depende de la escritura directa? No.** Cero `insert`/`update`/`upsert`/`delete` sobre las dos tablas en `frontend/`, `backend/`, `supabase/functions/` y scripts; **0** escrituras directas y **0** llamadas directas a `rpc_apply_product_stock_delta`/`rpc_reverse_stock_movement`/`rpc_adjust_branch_stock`/`rpc_transfer_stock` en 14 días de logs de PostgREST (2026-09-20 → 10-03, con control positivo). Todo lo que escribe es `SECURITY DEFINER` o un helper `INVOKER` sin `EXECUTE` para `authenticated`. **⇒ la tanda A no rompe ningún camino de producción medido.**

**Exposición real: baja, y con fecha.** 41 cuentas, **0 multiusuario**, 17 con stock, 1 multi-sucursal; daño histórico **0** (0 saldos ni movimientos con cuenta cruzada, 0 filas forjadas). Se vuelve explotable con el **primer usuario invitado**: el change entra antes de eso.

## What Changes

### Tanda A — G1: cerrar la escritura directa (migración `20261073000001`, PR chico)

- `REVOKE INSERT, UPDATE, DELETE, TRUNCATE` sobre `public.stock_movements` y `public.branch_stock` a `anon` y `authenticated` (molde: `presupuestos-modulo` con `quotes`, R2 de `fiscal-riesgos-residuales` con `fiscal_documents`, RN-A3 con `document_status_history`).
- `DROP POLICY` de las tres policies de escritura: `stock_movements_account_insert`, `branch_stock_writer_insert`, `branch_stock_writer_update`. Quedan las de lectura (`stock_movements_account_select`, `branch_stock_member_select`) y las dos `qual = false` de `stock_movements` (`_no_update`/`_no_delete`), conservadas como defensa en profundidad (D2).
- `REVOKE EXECUTE` de `rpc_reverse_stock_movement(uuid, text, text)` a `PUBLIC`, `anon` y `authenticated`: sus únicos callers son `rpc_delete_sale_operation` y `rpc_delete_purchase_operation`, ambos `SECURITY DEFINER`.
- Gate nuevo `supabase/tests/test_stock_ledger_solo_rpc.sql` con **matriz de evasión** bajo `SET LOCAL ROLE authenticated` (`INSERT`, `UPDATE`, `UPDATE … RETURNING`, upsert `ON CONFLICT`, `DELETE`, `TRUNCATE` sobre las dos tablas, ocupación cross-tenant y la reversa pública ⇒ `42501` *permission denied*), control positivo de los caminos legítimos (ajuste, alta y borrado de venta/compra con reversa, borrado de producto con historial) y candados de ACL.
- Ajuste de gates existentes: bloque (f) de `test_remitos_venta.sql` y `test_remitos_compra.sql` (hoy **exigen** que la fila forjada se pueda insertar ⇒ se invierte a "rechazada con `42501` y la fila no existe"); `test_is_account_writer_pivot.sql` baja de 45/18 a **43/17**; `rpc_reverse_stock_movement` entra a la lista `v_internal_only_fns` de `test_function_acl_gate.sql`.
- **Declarado:** hasta la tanda B, el cambio de saldo **sin rol** por `rpc_apply_product_stock_delta` (incluido `p_log_movement = false`) **sigue abierto**. La tanda A cierra la forja y la reversa pública, no el ajuste sin rol.

### Tanda B — G2 + G4 + resto de G5 + specs (migración `20261074000001`)

- **G2 — un solo núcleo de ajuste manual**, interno (sin `EXECUTE` para `authenticated`), que:
  - resuelve la **tenencia por `products.account_id`** contra `current_account_ids()` (retira el guard legacy `products.user_id = auth.uid()`; `P0404` si el producto no es de la cuenta);
  - exige el **rol en la base**: `is_account_writer` (`P0401`) y rol activo ∩ `{owner, admin, stock}` (`P0403 insufficient_role`) — molde `_quote_assert_can_write`;
  - exige **motivo no vacío** (`P0400 stock_adjustment_reason_required`), con un `CHECK` de segunda capa sobre `stock_movements` para los tipos de ajuste manual (`NOT VALID`: hay 18 filas históricas sin motivo que no se reescriben — D6);
  - aplica RN-20 a **todos** los caminos (no ajusta un padre `variant_only`), deja **siempre** movimiento y sella **cuenta, sucursal y autor**.
- `rpc_stock_adjustment`, `rpc_adjust_branch_stock` y `rpc_apply_product_stock_delta` pasan a ser **envoltorios públicos del núcleo con su misma firma** (`CREATE OR REPLACE`: conserva las ACLs y no rompe al frontend ni al backend en el mismo paso). `p_log_movement = false` y `p_allow_negative = true` dejan de ser alcanzables desde `authenticated` (`P0400`); la aritmética de saldo sin movimiento sobrevive **sólo** en un helper interno que usa la reversa de venta/compra.
- `rpc_transfer_stock` y `rpc_adjust_branch_stock` validan el **producto contra la cuenta** (hoy lo buscan sólo por `id`).
- **Backend**: `POST /products` con stock inicial ≠ 0 exige `require_account_role(…, CAN_STOCK)` **antes** de escribir; `PUT /products/{id}` deja de ser un camino de ajuste (un cambio de stock responde `422 stock_adjust_required`; el mismo valor es no-op). Se retira `StockRepository.adjust_with_event` (código muerto, el único sitio del repo que pedía `p_log_movement = FALSE`).
- **G4 — superficie frontend** (existe; sin rutas ni entradas de menú nuevas): motivo obligatorio en el modal de `/stock` y columna "Motivo" obligatoria en su CSV; acciones de ajuste visibles sólo con `CAN_STOCK` (espejo nuevo en `lib/rbac-capabilities.ts`, atado por test a Python y a la migración); en el formulario de producto, el alta muestra "Stock inicial" sólo a quien puede ajustar y la edición lo reemplaza por "Stock actual" + **Ajustar stock** (abre el modal existente con el producto preseleccionado); errores de rol, motivo y tipo en castellano vía `operation-errors.ts`. Verificado en desktop y mobile, tema claro y oscuro.
- **G5 (resto)**: el gate de la tanda A crece con la matriz de rol × motivo × camino sobre los tres envoltorios y los candados de ACL de los helpers internos; se actualizan los gates que usan estas RPCs como fixture.

### Fuera de alcance, declarado

- **Importador de productos → ledger** (`rpc_bulk_upsert_products` fija la cantidad absoluta sin movimiento: 587 productos con stock y sin movimientos, 218 con suma ≠ saldo). Decisión firmada 5: candidato aparte.
- Tipos `initial` y `return` sin escritor vivo: no se tocan.
- `v_products_with_stock`: ya es `security_invoker = true`, sin cambios.
- Rol de las **transferencias** entre sucursales: siguen con `is_account_writer` (OQ-3 del design, con recomendación).
- Los 5 saldos con stock sobre padres `variant_only` y el `ON DELETE CASCADE` de `stock_movements.user_id`: hallazgos laterales registrados, no se corrigen acá.

## Capabilities

### New Capabilities

_(ninguna — el change endurece capacidades existentes)_

### Modified Capabilities

- `branch-stock`: el ajuste manual pasa de "owner y admin vía `rpc_adjust_branch_stock`" (que el código no cumplía: dejaba a 7 roles) a **un núcleo único** con rol `owner`/`admin`/`stock`, motivo obligatorio, tenencia por `products.account_id` y sello de cuenta/sucursal/autor, alcanzado por los tres envoltorios; nueva superficie de ajuste gateada por rol y con motivo obligatorio en `/stock`, `/sucursales/[id]/stock` y el formulario de producto.
- `inventory-single-ledger`: nuevo requirement de **escritura del ledger y del saldo sólo desde funciones `SECURITY DEFINER`** (grants revocados, sin policies de escritura); la reversa de venta/compra deja de usar la RPC pública de delta y pasa por el helper interno, y `rpc_reverse_stock_movement` deja de ser invocable por PostgREST.
- `stock-transfer`: la transferencia valida que el **producto** pertenezca a la cuenta (`P0404`), además de las sucursales, y pasa a ser el único camino que registra `transfer_in`/`transfer_out` (el ajuste manual deja de aceptarlos — OQ-1 del design, según su recomendación).

`ledger-movement-history` y `ledger-adjustment` **no cambian**: cubren caja y banco; el ajuste de stock toma de `ledger-adjustment` el molde (motivo en la base + `CHECK`), no su texto.

## Impact

- **Migraciones**: `20261073000001_stock_ledger_cierre_escritura_directa.sql` (tanda A) y `20261074000001_stock_ledger_nucleo_ajuste_manual.sql` (tanda B). Números a re-verificar contra `MAX(version)` de prod y de `origin/main` al aplicar: `remitos-venta` y `remitos-compra` siguen en curso y pueden tomar correlativos.
- **Funciones reescritas** (`CREATE OR REPLACE`, misma firma, desde el `pg_get_functiondef` **vivo**): `rpc_apply_product_stock_delta`, `rpc_stock_adjustment`, `rpc_adjust_branch_stock`, `rpc_transfer_stock`, `rpc_reverse_stock_movement`. **Nuevas internas**: `_stock_assert_can_adjust`, `_stock_apply_delta`, `_stock_manual_adjustment`.
- **Backend**: `backend/services/products.py`, `backend/routers/products.py`, `backend/repositories/product_repository.py`, `backend/repositories/stock_repository.py` (retiro de `adjust_with_event`), `backend/core/rbac.py` (comentario de `CAN_STOCK`), tests `backend/tests/test_c21_checkpoint2_single_write.py`, `backend/tests/outbox/test_producers.py` y los de productos.
- **Frontend**: `components/stock/stock-adjustment-modal.tsx`, `components/stock/stock-import-adjustment-dialog.tsx`, `lib/stock-import-parser.ts`, `app/(dashboard)/stock/page.tsx`, `components/branches/BranchStockTable.tsx`, `components/branches/AdjustStockModal.tsx`, `components/forms/product-form.tsx`, `hooks/data/use-products.ts`, `hooks/data/use-branch-stock.ts`, `lib/rbac-capabilities.ts`, `lib/operation-errors.ts`, y sus tests.
- **Gates SQL**: nuevo `test_stock_ledger_solo_rpc.sql` (cableado en `KPI_Validation.yml`); modificados `test_remitos_venta.sql`, `test_remitos_compra.sql`, `test_is_account_writer_pivot.sql`, `test_function_acl_gate.sql`, `test_stock_adjustment_account_branch.sql` y los que siembran stock con estas RPCs.
- **KB (al archivar, cuando sea cierto)**: RN-21 y RN-A5 en `knowledge-base/05_reglas_de_negocio.md`, fila `stock_movements | Solo via RPC` de `knowledge-base/03_actores_y_roles.md` (y `branch_stock`).
- **Comportamiento visible**: quien no tenga `owner`/`admin`/`stock` deja de ver las acciones de ajuste; todo ajuste pide motivo; el formulario de producto deja de editar el stock. Hoy no le quita nada a nadie (0 cuentas multiusuario).
- **Sin cambios** de rutas, menú, planes, billing, dinero, outbox ni Edge Functions.
