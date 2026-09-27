## Why

El PO pidió: *"quiero que en la venta se pueda elegir el punto de venta o al facturar, por si tienen más de 1"*. Hoy la app **no deja elegir** el punto de venta (PV) en ningún camino de facturación de ventas, y el comportamiento depende de por dónde se factura:

- **`/ventas` (venta cargada a mano → "Facturar" → "Emitir comprobante")**: `sale-operations-list.tsx:163` le pasa a `EmitInvoiceButton` `pointsOfSale?.[0]?.id` — el PV de **menor número**, sin preguntar. Y como `GET /fiscal/points-of-sale` lista **activos e inactivos** (`point_of_sale_repository.list_by_account`), si el PV de menor número está desactivado la emisión falla con `P0404 point_of_sale_not_found_or_inactive`. Así se emitió la primera factura real de Sumar (2026-09-25, PV 3, número 501): salió por el 3 porque es el menor, no porque alguien lo eligiera.
- **`/ventas/ordenes` (donde se facturan las ventas del POS — el POS no emite inline, su banner "Facturar esta venta →" lleva ahí)**: la página sólo manda un PV si hay **uno** activo; con dos o más manda `null` y la RPC de emisión (`rpc_emit_pending_cae`, D11 de C-27) rechaza con **`P0422 ambiguous_point_of_sale`**. **Medido en prod hoy: 2 de 2 cuentas con puntos de venta tienen dos activos** (3 y 9999, las dos). O sea: **el 100% de las cuentas que facturan no puede facturar una venta del POS**, y el mensaje amigable que ya existe ("Seleccioná cuál usar") no tiene dónde seleccionar.
- **`EmitirComprobanteDialog.tsx`** tiene el selector de PV hecho (auto-elige si hay uno, exige elegir si hay varios) y **no lo usa nadie**: es código muerto desde v22. `EmitirSuscripcionDialog` (`/admin/pagos`) tiene una **segunda copia** del mismo selector.

Sumar tiene los PV 3 y 9999 activos y el PO quiere conservar los dos, así que "desactivá uno" no es la respuesta.

## What Changes

- **Selector de PV al facturar, con cero fricción cuando no hace falta.** `EmitInvoiceButton` pasa a resolver el PV **por sí mismo** (deja de depender de que cada pantalla calcule uno): con **un** PV activo emite directo como hoy; con **dos o más** abre `EmitirComprobanteDialog` — el diálogo que ya existe, revivido y ajustado, no uno nuevo — con el PV **preseleccionado** (el último usado en la sesión, o el predeterminado de la cuenta) para confirmar con un clic. Se cablea en los **dos** caminos reales de facturación de ventas: `/ventas` y `/ventas/ordenes` (que es por donde se facturan las ventas del POS). El POS en sí no cambia: sigue sin emitir inline (requisito vigente de `sales-order`).
- **Punto de venta predeterminado por cuenta** (opción recomendada en el diseño, D2): columna nueva `points_of_sale.is_default` con **una sola predeterminada por cuenta** (índice único parcial) y sólo sobre PVs activos (CHECK). Se marca y desmarca desde **Configuración → Datos fiscales → Puntos de venta** (badge "Predeterminado" + acción "Usar como predeterminado"). Desactivar el PV predeterminado le quita la marca en la misma sentencia.
- **La RPC de emisión de ventas usa el predeterminado cuando no se especifica PV.** `rpc_emit_pending_cae`: con dos o más PV activos y sin `point_of_sale_id`, usa el predeterminado de la cuenta si existe; si no existe, sigue rechazando con `P0422 ambiguous_point_of_sale` (sin cambio). Un PV explícito sigue ganando siempre. **`rpc_emit_subscription_payment_cae` (facturación de suscripciones de la plataforma) NO se toca** — su único caller ya exige elegir; un gate lo fija.
- **Recordar la última elección por sesión** (sessionStorage, por cuenta): si el usuario factura tres ventas seguidas por el 9999, la cuarta ya viene con el 9999 marcado.
- **Endpoints nuevos**: `POST /fiscal/points-of-sale/{id}/default` (marcar) y `DELETE /fiscal/points-of-sale/default` (quitar la marca), guard owner/admin en el service. `PointOfSaleOut` expone `is_default`.
- **Un solo selector de PV**: el bloque de selección que hoy está duplicado entre `EmitirComprobanteDialog` y `EmitirSuscripcionDialog` se extrae a un componente `PointOfSaleSelect` + helpers puros en `lib/` (tercer uso → Regla de Tres alcanzada). `/admin/pagos` gana, gratis, la preselección del predeterminado (sólo frontend).
- **Arreglos laterales que caen dentro del alcance**: `/ventas` deja de ofrecer un PV inactivo; el diálogo revivido pasa a tokens semánticos (hoy tiene `amber-*` literales) y a verificarse en desktop + mobile y claro + oscuro.

No hay cambio **BREAKING**: el contrato de `POST /sales-orders/{id}/emit-invoice` y de `rpc_emit_pending_cae` (firma y códigos de error) se conserva; lo único que cambia es que un caso que hoy falla con `P0422` pasa a emitir cuando la cuenta tiene predeterminado.

## Capabilities

### New Capabilities
- `point-of-sale-selection`: cómo la UI elige el punto de venta al facturar una venta — resolución (explícito > último de la sesión > predeterminado > único), diálogo sólo cuando hay más de un PV activo, memoria por sesión, cobertura de `/ventas` y `/ventas/ordenes`, selector compartido con `/admin/pagos`.

### Modified Capabilities
- `fiscal-profile`:
  - "Puntos de venta de la organización (multi-PV)" — columna `is_default`, una por cuenta, sólo activa; desactivar limpia la marca.
  - "Selección del punto de venta en la emisión" — con varios PV activos y sin PV explícito, se usa el predeterminado; `P0422` queda sólo para "varios activos y ninguno predeterminado".
  - "API de puntos de venta" — endpoints para marcar/quitar el predeterminado; `is_default` en la respuesta.
  - "UI de configuración fiscal" — badge "Predeterminado" y acción para marcarlo/quitarlo.

## Impact

- **DB**: una migración (`20261063000001_punto_venta_predeterminado.sql`, renumerar si otro PR toma el número): `ALTER TABLE points_of_sale ADD COLUMN is_default`, índice único parcial, CHECK, y reescritura de `rpc_emit_pending_cae` **partiendo del `pg_get_functiondef` vivo** (misma firma de 9 parámetros → `CREATE OR REPLACE` sin `42725`; conserva `COMMENT` y ACLs). Sin backfill: ninguna cuenta queda con predeterminado hasta que el dueño lo marque. Gate SQL nuevo que **ejecuta** la RPC en los cuatro casos de resolución.
- **Backend**: `PointOfSaleRepository` (set/clear default, deactivate limpia la marca), `fiscal_profile_service` (guards), `routers/fiscal.py` (2 endpoints), `schemas` (`is_default`). Sin cambios en `sales_orders` ni en el relay del CAE.
- **Frontend**: `EmitInvoiceButton`, `EmitirComprobanteDialog`, `EmitirSuscripcionDialog`, `components/ventas/sale-operations-list.tsx`, `app/(dashboard)/ventas/ordenes/page.tsx`, `components/settings/FiscalSettings.tsx`, `hooks/data/use-points-of-sale.ts`, componente nuevo `components/fiscal/PointOfSaleSelect.tsx`, helpers nuevos en `lib/fiscal-point-of-sale.ts`.
- **Governance: MEDIA** — dominio fiscal, pero el change sólo elige un dato (el PV) que la RPC ya valida contra la cuenta y contra `is_active`; no toca numeración, CAE, relay ni ARCA. La reescritura de `rpc_emit_pending_cae` es el tramo más sensible (RPC que emite comprobantes reales) y lleva gate que la ejecuta.
- **Superficie frontend**: diálogo al facturar en `/ventas` (menú Ventas) y `/ventas/ordenes` (enlazado desde el POS), pestaña Datos fiscales en `/configuracion` y `/configuracion/fiscal`, selector en `/admin/pagos`. Verificación en desktop y mobile, tema claro y oscuro.
- **Fuera de alcance** (ver design): elegir el PV en el formulario de la venta (el PV es del comprobante, no de la venta); PV por sucursal vía `points_of_sale.branch_id`; imprimir la factura con CAE/QR (candidato aparte `comprobante-fiscal-visible`); reactivar un PV inactivo desde la UI.
