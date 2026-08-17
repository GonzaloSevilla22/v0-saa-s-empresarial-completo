## Why

El módulo de clientes hoy es una agenda de contactos: lista nombre, email, teléfono y un `status` que **nadie mantiene** (se escribe a mano y por defecto queda `activo`). El emprendedor no puede responder las dos preguntas que realmente le importan — *¿quién me compra seguido?* y *¿a quién dejé de verle el pelo?* — ni ver cuánto le compró un cliente sin ir a Ventas y filtrar a ojo.

Pedido textual del PO: *"identificar clientes más frecuentes y aquellos inactivos y también quiero que si le haces click le podés ver las compras que ha hecho y cuánto fue el total"*.

Hay además un hallazgo de reutilización que este change aprovecha: **C-30 construyó la página `/clientes/[id]/cuenta` (cuenta corriente) y ningún lugar de la app enlaza a ella** — es una superficie huérfana, exactamente el patrón que la regla PO 2026-08-02 quiere evitar. Este change le da por fin puerta de entrada al hacer clickeable la fila del cliente.

## What Changes

- **Señalización en la lista de clientes** (`/clientes`): badge de actividad por cliente — `Frecuente`, `Activo`, `Inactivo`, `Sin compras` — derivado de sus ventas reales, más filtro por estado de actividad y ordenamiento por última compra / total comprado / cantidad de compras.
- **La fila del cliente pasa a ser clickeable** → navega al detalle del cliente.
- **Detalle del cliente** en `/clientes/[id]`: cabecera con datos + resumen (cantidad de compras, total comprado, última compra y días transcurridos), y el listado de sus compras — una fila por **operación de venta**, con fecha, cantidad de ítems y monto — paginado.
- **Layout con pestañas** en `/clientes/[id]`: `Historial de compras` (nueva) y `Cuenta corriente` (la página de C-30, que deja de ser huérfana y se monta como pestaña hermana en `/clientes/[id]/cuenta`).
- **Backend**: dos endpoints nuevos de lectura en el router `clients` — `GET /clients/activity` (listado paginado con agregados y estado de actividad) y `GET /clients/{client_id}/purchases` (historial por operación, paginado). Ambos con envelope `{items,total,page,pages}` y errores RFC 7807.
- **La lista de clientes deja de leer Supabase en directo**: hoy `/clientes` usa `usePaginatedQuery({table:"clients"})` (PostgREST directo); pasa a consumir FastAPI, alineándose con el modelo híbrido (DEC-12..16). La búsqueda, el orden y la paginación se mueven al backend.
- **Estado de actividad calculado, no declarado**: el badge nuevo se deriva de `sales`; la columna `clients.status` escrita a mano queda como está (no se toca, no se migra) — conviven, y el proposal deja OQ-3 para que el PO decida si `status` se retira más adelante.
- Los umbrales (`≥3 compras en 90 días` = frecuente, `≥60 días sin comprar` = inactivo) viven como **constantes nombradas en una única capa canónica del backend**, calibradas contra la distribución real de producción (ver `design.md` §1).

**Sin cambios de comportamiento en**: `GET /clients` (lista plana) se conserva intacta — la consumen 6 pantallas como origen de datos de selectores (`ventas`, `pos`, `configuración`, `sale-form`, `client-form`, `client-import-dialog`). No es breaking.

## Capabilities

### New Capabilities
- `client-activity`: clasificación de actividad comercial del cliente (frecuente / activo / inactivo / sin compras) derivada de sus ventas, con umbrales canónicos, ventanas ancladas al día calendario argentino y agregados por cliente (cantidad de compras, total comprado, última compra).
- `client-purchase-history`: historial de compras de un cliente — una fila por operación de venta con su total canónico, agregación y paginación estándar, más la superficie de detalle del cliente que lo expone.

### Modified Capabilities
- `data-api-endpoints`: se agregan al contrato del router `clients` los endpoints de lectura `GET /clients/activity` y `GET /clients/{client_id}/purchases`, ambos con el envelope de paginación estándar.

## Impact

**Frontend**
- `frontend/app/(dashboard)/clientes/page.tsx` — badges, filtro por actividad, orden, fila clickeable, migración de `usePaginatedQuery` a hook propio contra FastAPI.
- `frontend/app/(dashboard)/clientes/[id]/layout.tsx` *(nuevo)* — cabecera del cliente + navegación por pestañas.
- `frontend/app/(dashboard)/clientes/[id]/page.tsx` *(nuevo)* — historial de compras + tarjetas de resumen.
- `frontend/app/(dashboard)/clientes/[id]/cuenta/page.tsx` — se le quita la cabecera propia (la absorbe el layout); el resto intacto.
- `frontend/hooks/data/use-client-activity.ts` *(nuevo)* — `useClientActivityList`, `useClientPurchases`.
- `frontend/components/clientes/ClientActivityBadge.tsx`, `ClientPurchaseHistory.tsx`, `ClientSummaryCards.tsx` *(nuevos)*.
- Se reutilizan sin tocar: `CustomerAccountBalance`, `CustomerAccountHistory`, `RegisterPaymentForm`, `PaginationBar`, `useCustomerAccount`.

**Backend**
- `backend/core/client_activity.py` *(nuevo)* — umbrales canónicos y clasificación.
- `backend/repositories/client_repository.py` — dos métodos de lectura nuevos.
- `backend/services/clients.py`, `backend/routers/clients.py`, `backend/schemas/clients.py` — servicio, endpoints y schemas.

**Datos**
- Sin cambios de esquema ni de datos. Una migración opcional de índice de soporte (`sales(account_id, client_id, date DESC)`) — justificación y umbral de necesidad en `design.md` §5.

**Fuera de alcance**
- No se tocan las ventas ni su alta. No se implementan notas de crédito (hoy `customer_account_movements` está vacía en producción — ver `design.md` §3). No se agrega segmentación RFM ni scoring; no se envían campañas ni notificaciones a clientes inactivos.
