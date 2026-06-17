# data-api-endpoints

## ADDED Requirements

### Requirement: Endpoints REST de Quote
El backend FastAPI SHALL exponer endpoints para gestionar presupuestos siguiendo la arquitectura de 3 capas (routers→services→repositories), con guards de rol en el service (`require_role`), validación Pydantic v2 en el endpoint y acceso a datos vía JWT-passthrough (nunca `service_role`). Los endpoints SHALL cubrir: crear presupuesto, listar presupuestos de la cuenta, obtener un presupuesto con sus ítems, transicionar estado (`send`/`reject`/`expire`) y `accept` (que crea el `SalesOrder`).

#### Scenario: crear presupuesto devuelve 201
- **WHEN** un usuario writer hace `POST` al endpoint de presupuestos con ítems válidos
- **THEN** responde 201 con el presupuesto creado en estado `draft`

#### Scenario: accept devuelve la orden creada
- **WHEN** se hace `POST` al endpoint de `accept` de un presupuesto en `sent`
- **THEN** responde con el `sales_order_id` de la orden generada y el presupuesto queda en `accepted`

#### Scenario: rol insuficiente es rechazado
- **WHEN** un usuario sin rol writer intenta crear o aceptar un presupuesto
- **THEN** el service responde 403 (guard `require_role`)

### Requirement: Endpoints REST de SalesOrder y quickSale
El backend FastAPI SHALL exponer endpoints para órdenes de venta: crear orden (`draft`), confirmar orden (`confirm`), `quickSale` (crear+confirmar POS en un paso) y listar/obtener órdenes. La validación del payload (incluyendo `payment_method`, `cash_session_id` cuando es efectivo, y tipo de comprobante opcional) SHALL ocurrir con schemas Pydantic v2 antes de invocar el RPC. El service SHALL aplicar `require_role` y delegar la transacción al RPC `SECURITY DEFINER` vía el repository.

#### Scenario: quickSale devuelve la orden confirmada
- **WHEN** se hace `POST` al endpoint de `quickSale` con `idempotency_key`, ítems y `payment_method`
- **THEN** responde con el `sales_order_id` y el `operation_id`, y la orden queda `confirmed`

#### Scenario: confirm con stock insuficiente propaga el error de negocio
- **WHEN** el RPC lanza P0409 por stock insuficiente
- **THEN** el endpoint responde con un código de error de negocio (409) y un mensaje claro, sin efectos parciales

#### Scenario: payload inválido es rechazado por el schema
- **WHEN** se envía `payment_method = 'cash'` sin `cash_session_id`
- **THEN** la validación falla (422/400) antes de tocar la base de datos
