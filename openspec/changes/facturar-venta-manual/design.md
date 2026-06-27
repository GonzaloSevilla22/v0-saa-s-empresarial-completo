## Context

EIE tiene **tres** pantallas de ventas (ver `openspec/explore/2026-06-27-promote-legacy-sale-to-order.md` §1):

| Pantalla | Ruta | Modelo de escritura |
|---|---|---|
| Ventas | `/ventas` | `sales` / `sale_operation` (legacy) — alta manual con datepicker |
| POS — Venta Rápida | `/ventas/pos` | `sales_orders` (V2.1) vía `rpc_quick_sale` |
| Órdenes de Venta | `/ventas/ordenes` | `sales_orders` (V2.1) |

El puente entre modelos es **de una sola dirección**: `_c29_confirm_order_core` (migración `20260702000001`, líneas 514-548) hace `INSERT INTO public.sales` legacy al confirmar — el POS **alimenta** el modelo viejo, pero la carga manual NO sube a `sales_orders`. Como la facturación AFIP (C-27) opera sobre `sales_orders`, **una venta manual no es facturable**: el problema no es un permiso que falta, es un objeto (`sales_orders`) que no existe.

Estado actual del frontend (`frontend/components/ventas/sale-operations-list.tsx`): hay un botón **"Enviar al ARCA"** que llama `useEmitComprobante` → `POST /fiscal/documents/emit`. Ese endpoint crea un `fiscal_documents` **huérfano**: no está asociado a ninguna `sales_order`, no setea `sales_orders.fiscal_document_id`, no deriva el receptor de la identidad fiscal del cliente de una orden y no reconcilia contra el modelo canónico V2.1. Es un parche fiscal, no la materialización correcta.

El PO eligió la **Opción C — promoción lazy** (explore doc §6): un botón "Facturar" en `/ventas` que materializa una `SalesOrder` confirmada desde la venta legacy existente y reusa el flujo `emit-invoice` de C-27. Se descartó la Opción B (que el alta manual cree `SalesOrder` directamente) por sus 4 gaps de §3 del explore: backdating (`_c29_confirm_order_core` clava `CURRENT_DATE`), `sales_orders` sin columna `date`, editabilidad (legacy mutable vs SalesOrder inmutable), y sesión de caja para ventas pasadas.

**Gobernanza: FISCAL = CRÍTICO.** Este diseño se entrega para **aprobación humana del PO antes de cualquier apply**. No se debe escribir código hasta la firma.

## Goals / Non-Goals

**Goals:**
- Cerrar la asimetría: que una venta cargada a mano en `/ventas` se pueda facturar a AFIP.
- Hacerlo **materializando el objeto fiscal canónico** (`SalesOrder` confirmada) y reusando `emit-invoice` (C-27) tal cual, para que el comprobante quede reconciliado a una orden.
- Idempotencia: doble clic en "Facturar" no duplica la orden.
- Cero efectos colaterales sobre stock/caja/outbox (la venta ya ocurrió).
- Respetar RN-97: ninguna lógica de negocio nueva sobre `sales` (tabla en retirada); la lógica nueva vive en `sales_orders`.

**Non-Goals:**
- NO unificar el write-path de la carga manual (Opción B) — eso es el *true north* del roadmap pero queda fuera de este change.
- NO tocar el hot path POS (`rpc_quick_sale`), `rpc_create_sale_operation` (alta legacy), el descuento de stock, la caja, ni el outbox.
- NO modificar el flujo `emit-invoice` / la maquinaria CAE de C-27 (se reusa sin cambios).
- NO agregar columna `date` a `sales_orders` ni resolver backdating fiscal (el comprobante lleva fecha de emisión — ver Risks).
- NO migrar IA/OCR ni introducir dependencias nuevas.

## Decisions

### D1 — La promoción es una RPC propia, side-effect-free; NO pasa por `_c29_confirm_order_core`

`rpc_promote_legacy_sale_to_order(p_operation_id uuid)` (`SECURITY DEFINER`, `SET search_path = public`) materializa la `SalesOrder` y sus ítems, pero **no descuenta `branch_stock`, no registra `cash_movement`, no inserta `SaleConfirmed` en `events`**.

**Por qué (no negociable):** la venta legacy **ya descontó stock** al crearse (`rpc_create_sale_operation`). Si la promoción pasara por el core:
- doble-contaría stock (lo descontaría una segunda vez), y
- el `INSERT INTO events('SaleConfirmed')` del core (líneas 573-592) dispararía el **Consumer 3 del outbox (journal-entry V2.5)**, generando un **asiento contable fantasma** por una venta que ya está contabilizada.

La promoción es **materialización fiscal, no una venta nueva**. Por eso es una función nueva y aislada, no un wrapper del core.

**Alternativa considerada:** reutilizar `_c29_confirm_order_core` con flags para saltear stock/caja/outbox. Descartada: contamina el hot path FISCAL=CRÍTICO con ramas condicionales y multiplica la superficie de test del camino más sensible del sistema.

### D2 — Idempotencia vía índice único parcial sobre `sale_operation_id`

```sql
CREATE UNIQUE INDEX IF NOT EXISTS sales_orders_sale_operation_id_uq
  ON public.sales_orders (sale_operation_id)
  WHERE sale_operation_id IS NOT NULL;
```

La columna `sales_orders.sale_operation_id` ya existe (migración C-29, línea 180) como puente de retrocompat, pero **hoy no tiene índice de unicidad**. La RPC, antes de insertar, hace `SELECT id FROM sales_orders WHERE sale_operation_id = p_operation_id`; si existe, devuelve esa orden (`replayed = true`) sin crear otra. El índice es la red de seguridad a nivel DB que además impide que el POS (que también escribe `sale_operation_id` al confirmar) y la promoción colisionen sobre la misma operación.

**Alternativa considerada:** idempotencia vía `operation_idempotency` (como el core). Descartada: `operation_idempotency` se llavea por `idempotency_key` del cliente, que la promoción no tiene; la unicidad natural acá es la operación legacy misma.

### D3 — Reconstrucción de ítems: `sale_items` con fallback al header plano

La RPC reconstruye `sales_order_items` leyendo `sale_items` de la operación. Para ventas **pre-backfill** (cargadas antes de que C-29 escribiera `sale_items`), cae al header plano de `sales` vía `COALESCE`, espejando el patrón ya probado en `SalesRepository.list_paginated_by_operation` (`backend/repositories/sales_repository.py`, líneas 50-64):

```
COALESCE(si.product_id, s.product_id), COALESCE(si.quantity, s.quantity),
COALESCE(si.price, s.amount), COALESCE(si.subtotal, s.total)
```

Las líneas de servicio (`product_id IS NULL`) se promueven sin problema porque `sales_order_items.product_id` es nullable (migración C-29, línea 214). `total = Σ subtotales` reconstruidos.

### D4 — Branch efectiva = `COALESCE(sales.branch_id, c26_default_branch(account_id))`

`sales_orders.branch_id` es `NOT NULL` (DEC-19, migración C-29 línea 172). Se resuelve igual que `rpc_accept_quote` (líneas 290-298): preferir la branch de la venta legacy, sino el default de la cuenta (`c26_default_branch`). Si no hay branch resoluble → `P0422`.

### D5 — Seguridad: SECURITY DEFINER + guards + tenencia

Espeja `rpc_accept_quote`: valida `auth.uid()` (sino `insufficient_privilege`), valida tenencia de la operación (existe `sales` con ese `operation_id` en una cuenta del usuario, sino `P0404`), valida `is_account_writer(account_id)` (sino `P0401`). `REVOKE ALL FROM PUBLIC, anon` + `GRANT EXECUTE TO authenticated`. Los ERRCODEs siguen la convención C-29: `P0401`/`P0404`/`P0409`/`P0422`.

### D6 — Endpoint en el router legacy `/sales`, capa service nueva

`POST /sales/{operation_id}/promote-to-order` vive en `backend/routers/sales.py` (cohesión: opera sobre una operación legacy identificada por `operation_id`). Sigue las 3 capas: router (validación + DI) → `backend/services/sales.py` nuevo `promote_to_order` (guard `require_role(["user","admin"])` + mapeo de errores) → `SalesRepository.promote_to_order` (llama la RPC). El mapeo Postgres→HTTP espeja `_map_postgres_error` de `services/sales_orders.py` (P0401→403, P0400→400, P0404→404, P0409/P0422→409). Response Pydantic v2 con `sales_order_id`, `sale_operation_id`, `promoted`/`replayed`.

**Alternativa considerada:** plegar la promoción dentro del propio `emit-invoice` (promote-then-emit en un endpoint). Descartada para esta iteración: mantener promote y emit como dos pasos explícitos preserva el flujo `emit-invoice` de C-27 intacto y deja la promoción testeable de forma aislada. El frontend los encadena (D7).

### D7 — Frontend: "Facturar" encadena promote → emit; reemplaza "Enviar al ARCA" para ventas manuales

En `SaleOperationsList`, el botón "Facturar" (reemplazando/junto al actual "Enviar al ARCA" para cerrar la huérfana): (1) llama un hook nuevo `usePromoteToOrder(operationId)` → `POST /sales/{operation_id}/promote-to-order`, obtiene el `sales_order_id`; (2) renderiza `EmitInvoiceButton` (ya existente, `frontend/components/fiscal/EmitInvoiceButton.tsx`) sobre esa orden, que dispara `emit-invoice` y muestra `FiscalDocumentBadge` (Realtime). El componente `EmitInvoiceButton` ya gatea por `status='confirmed'` + `fiscal_document_id IS NULL` y bloquea a RI (OQ-1) — se reusa sin cambios. Como la promoción es idempotente, reintentar es seguro.

**Decisión de UX (RESUELTA — PO 2026-06-27):** el botón "Enviar al ARCA" se **retira de inmediato** para ventas manuales; "Facturar" pasa a ser el único camino fiscal en `/ventas`. Además, "Facturar" se **oculta/deshabilita con aviso** cuando la operación ya tiene un `fiscal_documents` asociado (huérfano del camino viejo o emisión ya realizada), para evitar la doble facturación cruzada. La emisión huérfana (`/fiscal/documents/emit`) sigue existiendo a nivel API para otros usos; solo se quita su botón de `/ventas`.

## Risks / Trade-offs

- **[Caveat fiscal — fecha de emisión]** El comprobante AFIP lleva fecha de **emisión** (hoy), no la de la venta original; AFIP limita la antigüedad facturable. → *Mitigación:* documentado como caveat de negocio (no de código); para el caso típico (facturar la venta de ayer/esta semana) es normal. Sin cambio de schema. El frontend puede advertir al facturar ventas con fecha antigua (mejora opcional).
- **[Comprobante huérfano preexistente]** Las ventas ya "Enviadas al ARCA" por el camino viejo tienen un `fiscal_documents` sin `sales_order`. → *Mitigación:* fuera de alcance de este change; no se migran retroactivamente. El nuevo camino solo aplica a ventas aún no facturadas. **RESUELTO (PO 2026-06-27): el botón viejo no se usó en producción → no hay huérfanos preexistentes; riesgo residual nulo.**
- **[Doble facturación cruzada]** Una venta podría facturarse por el camino huérfano viejo Y luego promoverse. → *Mitigación:* el índice único de D2 impide doble `sales_order`, pero NO detecta el `fiscal_documents` huérfano previo. RESUELTO (PO 2026-06-27): el frontend oculta/deshabilita "Facturar" cuando ya hay un `fiscal_documents` para esa operación, y el botón viejo "Enviar al ARCA" se retira — eliminando el camino que generaba huérfanos nuevos. La emisión sobre la orden sí es idempotente (409 si `fiscal_document_id` ya seteado).
- **[Concurrencia POS vs promoción]** Si la misma operación legacy nace de un POS y alguien intenta promoverla, el índice único serializa: la promoción encuentra la orden existente y la devuelve. → *Mitigación:* cubierto por D2 + handler explícito `EXCEPTION WHEN unique_violation` en la RPC que re-SELECTea y devuelve la orden existente como replay (no 500). Implementado en la migración `20260804000001`.
- **[Stock ya revertido]** Si la venta legacy fue borrada/editada (`SalesRepository.delete_by_operation` revierte stock), promoverla materializaría una orden sobre datos inconsistentes. → *Mitigación:* la RPC valida tenencia/existencia de `sales` al momento de promover; una operación borrada ya no existe (P0404). Editar la venta tras promover es un edge no cubierto (la orden queda con el snapshot al promover) — aceptable: la orden confirmada es inmutable por diseño.

## Migration Plan

1. **Aprobación humana del PO** (FISCAL = CRÍTICO) antes de escribir código. **Gate duro.**
2. Migración SQL nueva (`supabase/migrations/<ts>_promote_legacy_sale_to_order.sql`): índice único parcial (D2) + RPC (D1, D3-D5) + gates SQL RED→GREEN con ROLLBACK total (patrón C-29 §3.4). **Aplicar con `npx supabase db push`** (NUNCA el MCP `apply_migration` — desincroniza el history).
3. Backend (D6) con TDD pytest+pytest-asyncio: repository → service → router. RED→GREEN→TRIANGULATE por capa.
4. Frontend (D7): hook `usePromoteToOrder` + cableado en `SaleOperationsList`.
5. **Rollback:** `DROP FUNCTION IF EXISTS public.rpc_promote_legacy_sale_to_order(uuid); DROP INDEX IF EXISTS public.sales_orders_sale_operation_id_uq;`. Sin pérdida de datos (la RPC no borra; el índice solo restringe). Las `sales_orders` ya materializadas quedan válidas. Revertir el endpoint y el botón es independiente.

## Open Questions

- **[RESUELTA — PO 2026-06-27] UX del botón viejo "Enviar al ARCA":** se **retira de inmediato** para ventas manuales (no conviven). "Facturar" es el único camino fiscal en `/ventas`.
- **[RESUELTA — PO 2026-06-27] ¿Ocultar "Facturar" si la operación ya tiene un `fiscal_documents`?** **Sí** — se oculta/deshabilita con aviso cuando la operación ya tiene comprobante (huérfano previo o emisión hecha). Cuesta una lectura adicional por operación en el listado; aceptado para evitar la doble facturación.
- **[Diferible a apply] ¿El endpoint debería plegar promote+emit en un solo paso (D6 alternativa)?** Mantener dos pasos es más testeable; un solo paso es menos round-trips. Decisión técnica, no de producto — se resuelve en implementación.
