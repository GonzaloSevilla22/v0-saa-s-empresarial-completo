# Exploración: Facturar ventas cargadas a mano — promoción lazy legacy→SalesOrder

> **Tipo:** Exploración (modo thinking — sin implementación)
> **Fecha:** 2026-06-27
> **Proyecto:** EmprendeSmart (EIE) — Supabase project `gxdhpxvdjjkmxhdkkwyb`
> **Disparador:** El PO no entendía por qué existen `/ventas` (carga manual + libro mayor) y `POS — Venta Rápida` en paralelo, y si una reemplaza a la otra.
> **Scope:** Mapear los dos caminos de escritura de ventas, validar la asimetría de facturación, comparar opciones de cierre y dejar elegida la solución.
> **Decisión:** Opción C (promoción lazy). Ver §6.

---

## 1. El problema: dos caminos de venta, asimétricos

Hay **tres** pantallas de ventas, no dos:

| Pantalla | Ruta | Rol | Hook → Backend | Modelo |
|---|---|---|---|---|
| Ventas | `/ventas` | Libro mayor + alta manual | `use-sales` → `POST /sales` | `sales` / `sale_operation` (legacy) |
| POS — Venta Rápida | `/ventas/pos` | Caja de mostrador en vivo | `useQuickSale` → `POST /sales-orders/quick-sale` | `sales_orders` (V2.1) |
| Órdenes de Venta | `/ventas/ordenes` | Listado para facturar AFIP | `useSalesOrders` → `GET /sales-orders` | `sales_orders` (V2.1) |

Los dos caminos de **escritura** (manual vs POS) descuentan stock y son idempotentes. La diferencia que importa: **una venta cargada a mano NO se puede facturar a AFIP**, porque la facturación opera sobre `sales_orders` y la carga manual nunca crea esa fila.

---

## 2. Hallazgo central: el puente es de una sola dirección

**Evidencia (migración `20260702000001_c29_quote_salesorder.sql`, RPC `_c29_confirm_order_core`, líneas 514-548):** al confirmar una SalesOrder, el propio RPC hace `INSERT INTO public.sales` (legacy) con su `operation_id`, sus `stock_movements`, su `branch_id`. O sea, el POS **alimenta** el modelo viejo; no solo "convive" con él.

```
  POS → rpc_quick_sale → _c29_confirm_order_core
            ├─ crea sales_orders + sales_order_items
            ├─ descuenta branch_stock
            ├─ INSERT INTO sales (legacy)  ──────┐  PUENTE (baja)
            ├─ stock_movements                   │
            ├─ caja (si efectivo)                │
            └─ outbox SaleConfirmed              │
                                                 ▼
  sales_orders ─────────────────────────────► sales ✅ aparece en /ventas

  Manual → rpc_create_sale_operation
            ├─ INSERT INTO sales + sale_items  ──┐  escribe acá…
            └─ descuenta stock                   │
                                                 ▼
  sales ──────────X──────────────────────────► sales_orders ❌ no existe → no facturable
```

El POS es un **superconjunto** (escribe los dos modelos). La carga manual escribe solo el de abajo. Por eso "facturar una venta manual" no es un permiso que falta: es **un objeto (`sales_orders`) que no existe**.

---

## 3. Por qué unificar el write-path (Opción B) es más caro de lo que parece

Si la carga manual fuera a crear una SalesOrder (vía el hot path del POS), choca con cuatro cosas:

| # | Gap | Evidencia / por qué duele |
|---|-----|---------------------------|
| 1 | **Fecha / backdating** | `_c29_confirm_order_core` clava `CURRENT_DATE` (líneas 521/545). La carga manual tiene datepicker — cargás ventas pasadas. |
| 2 | **`sales_orders` sin columna `date`** | Solo tiene `created_at = now()`. La fecha de negocio vive hoy **únicamente** en las filas `sales`. Falta dónde guardar "la venta fue el 12/06". |
| 3 | **Editabilidad** | Legacy es **mutable** (`rpc_atomic_update_sale_operation` = reversa + reaplica). SalesOrder confirmada es **inmutable** (draft→confirmed, sin RPC de update). Choque de modelos: libro mayor editable vs transacción atómica. |
| 4 | **Sesión de caja** | El core exige `cash_session_id` si es efectivo. Una venta de hace 3 días no tiene caja abierta hoy. |

El #3 es el dilema de fondo y es de **diseño**, no de código.

---

## 4. Validación del caso de negocio (premisa cuestionada)

Se cuestionó la premisa "me molesta no poder facturar una venta manual": podría ser una *feature* (lo manual = informal que NO facturás) en vez de un *bug*.

**Veredicto del PO (2026-06-27):** el caso *"cargo a mano y después facturo"* **es real y vale la pena resolverlo**. Por lo tanto la asimetría es un agujero a cerrar, no una separación deseada.

---

## 5. Mapa de opciones

```
            esfuerzo   cierra gap   respeta      toca hot path
                       fiscal       RN-97        ventas (riesgo)
  ──────────────────────────────────────────────────────────────
  A status quo  cero     no          sí           no
  B unificar    ALTO     sí          sí (vía SO)  SÍ (caja/stock/fiscal)
  C promoción   MEDIO    sí          sí           no (no re-mueve stock)
    lazy
```

- **A** deja el dolor (manual no facturable) y dos modelos en paralelo.
- **B** es el *true north* del roadmap (un solo modelo) pero arrastra los 4 gaps de §3 y toca un hot path FISCAL=CRÍTICO.
- **C** cierra exactamente el dolor sin tocar cómo nace una venta.

---

## 6. Decisión: Opción C — promoción lazy legacy→SalesOrder

Botón "Facturar" en la lista de `/ventas` que **materializa una SalesOrder confirmada a partir de la venta legacy que ya existe**, y de ahí reusa el flujo `emit-invoice` (CAE C-27) tal cual.

```
  /ventas (lista legacy)  ──[Facturar]──►  rpc_promote_legacy_sale_to_order(operation_id)
      1. lee sales + sale_items de la operación
      2. branch = COALESCE(sales.branch_id, c26_default_branch)
      3. INSERT sales_orders (status='confirmed', sale_operation_id = operation_id)
      4. INSERT sales_order_items (reconstruidos desde sale_items)
      5. ❌ NO descuenta stock   (ya se descontó al crear la venta)
      6. ❌ NO registra caja      (no hubo caja; evita doble conteo)
      7. ❌ NO emite outbox SaleConfirmed (la venta ya ocurrió)
            └─► devuelve sales_order_id ──► emit-invoice (C-27, sin tocar) ──► CAE ✅
```

### Las dos decisiones que hacen a C seguro

1. **La promoción NO pasa por `_c29_confirm_order_core`.** Es una RPC propia **side-effect-free**. Si pasara por el core, descontaría stock dos veces y dispararía un segundo `SaleConfirmed` → el Consumer 3 del outbox (V2.5 journal-entry) generaría un asiento contable fantasma. La promoción es **materialización fiscal, no una venta nueva**.

2. **Idempotencia gratis vía `sale_operation_id`.** Índice único parcial `sales_orders(sale_operation_id) WHERE sale_operation_id IS NOT NULL`: doble clic en "Facturar" devuelve la orden existente en vez de duplicar. Bonus: protege también contra que POS y promoción pisen la misma operación.

### Caveat fiscal (decisión de negocio, no de código)

El comprobante AFIP lleva fecha de **emisión** (hoy), no la fecha de la venta original. AFIP limita la antigüedad facturable. Para el caso típico (cargás la venta de ayer/esta semana y facturás) es normal; solo hay que tenerlo presente al facturar ventas viejas.

### Alcance de C

| Capa | Cambio |
|------|--------|
| DB | RPC `rpc_promote_legacy_sale_to_order` + índice único parcial en `sales_orders(sale_operation_id)` |
| Backend | Endpoint `POST /sales/{operation_id}/promote-to-order` (o plegado en el emit) |
| Frontend | Botón "Facturar" en `SaleOperationsList` (`/ventas`), reusando `EmitInvoiceButton` + `FiscalDocumentBadge` |
| Reusa tal cual | Flujo `emit-invoice` / CAE de C-27 |
| NO toca | Hot path POS, `create` legacy, stock, caja, outbox |

### Edge cases a resolver en el design

- Reconstrucción de ítems: leer `sale_items`; fallback al header flat (`product_id/quantity/amount`) vía COALESCE para ventas pre-backfill.
- Líneas de servicio (`product_id NULL`): `sales_order_items.product_id` es nullable → promueven sin problema.
- Multi-línea: una operación = una orden con N ítems.
- Total: `sum(sale_items.subtotal)` (o header total) → `sales_orders.total`.
- Seguridad: SECURITY DEFINER + `is_account_writer` + validar tenencia de la operación.

---

## 7. Gobernanza y próximo paso

- **Gobernanza: FISCAL = CRÍTICO.** Diseño + review humano antes de escribir código.
- **RN-97:** respetada — la promoción *lee* `sales` pero no agrega lógica de negocio *a* esa tabla; la lógica nueva vive en `sales_orders`.
- **Relación con B:** C es un puente pragmático, no anula el *true north*. Si algún día se hace B, la promoción queda obsoleta sin deuda residual.
- **Próximo paso:** propuesta formal (`/opsx:propose`) con proposal + design + tasks. Esta exploración es la fuente del razonamiento.

---

## Memoria relacionada

- engram `ventas/promote-legacy-to-order` (decisión registrada 2026-06-27).
