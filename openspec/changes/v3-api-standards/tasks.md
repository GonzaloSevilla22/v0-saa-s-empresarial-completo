# Tasks — v3-api-standards

> Strict TDD rige el apply: por cada task de código, RED → GREEN → TRIANGULATE → REFACTOR, con safety net sobre la suite (~960 verde). Ningún cambio de comportamiento de negocio. Migración por CI al mergear (nunca MCP).

## 1. Errores RFC 7807 (problem+json)

- [x] 1.1 Definir el shape 7807 (`type`, `title`, `status`, `detail`, extensiones `code`, `field`) como helper/constructor en `backend/core/errors.py`, con media type `application/problem+json`
- [x] 1.2 Reescribir `asyncpg_error_handler` para emitir 7807 sobre el mapeo `_BUSINESS_ERRCODE_STATUS` existente: `code = sqlstate`, `detail` = mensaje del RPC, preservando status y headers CORS (`cors_error_headers`)
- [x] 1.3 Agregar handler de `RequestValidationError` en `main.py`: 422 problem+json con `field` (= `loc[-1]`) por cada violación de Pydantic, `code = "validation_error"`
- [x] 1.4 Agregar handler de `HTTPException` en `main.py` para que los `raise HTTPException` dispersos salgan en 7807
- [x] 1.5 Migrar el catch-all `unhandled_exception_handler` a 7807 genérico (`code = "internal_error"`, sin filtrar internals)
- [x] 1.6 Tests: RPC error (P0409→409 con `code`), validación (422 con `field`), 500 genérico, y que CORS y `detail`-string se preservan

## 2. Paginación estándar (`?page&size → {items,total,page,pages}`)

- [x] 2.1 Definir `PageOut[T]` genérico Pydantic (`items: list[T]; total: int; page: int; pages: int`) en un módulo de schemas compartido
- [x] 2.2 Agregar `BaseRepository.paginate(select_sql, count_sql, *args, page, size)` que calcula `offset`, ejecuta SELECT+COUNT y arma el envelope (`pages = ceil(total/size)`, `pages=0` si `total=0`), sobre la conexión inyectada; compatible con `not_deleted_clause`
- [x] 2.3 Tests de `paginate`: envelope de una página, `total=0` sin división por cero, aislamiento/JWT-passthrough (misma conexión)
- [x] 2.4 Migrar `sales` (`SalesPageOut`→`PageOut`, `page/size`) y su repo/service al helper
- [x] 2.5 Migrar `purchases` (`PurchasesPageOut`→`PageOut`) al helper
- [x] 2.6 Migrar `payments` (`PaymentReceiptsPageOut`→`PageOut`, `page/size`) al helper
- [x] 2.7 Migrar `customer_accounts` de `limit/offset`+lista plana a `page/size`+`PageOut`
- [x] 2.8 Migrar `supplier_accounts` de `limit/offset`+lista plana a `page/size`+`PageOut`
- [x] 2.9 Migrar `journal_entries` de `limit/offset` a `page/size`+`PageOut`
- [x] 2.10 Tests por listado migrado: envelope correcto, página fuera de rango (200 + items vacío), `size` sobre el máximo (422)

## 3. Idempotency-Key por header

- [x] 3.1 Crear dependency `require_idempotency_key` (lee header `Idempotency-Key`; fallback al `idempotency_key` del body con precedencia del header; 422 `idempotency_key_required` si falta)
- [x] 3.2 Marcar `idempotency_key` como opcional+deprecado en los schemas de mutación (deja de ser required en el body) sin cambiar lo que recibe la RPC
- [x] 3.3 Cablear el dependency en las mutaciones existentes: crear venta (`sales`), crear compra (`purchases`), cobrar/pagar (`customer_accounts`, `supplier_accounts`), `sales_orders` (confirm/quick-sale), `bank_reconciliation` (import extracto/movimiento manual). **Desviación**: `fiscal` (emit-invoice/emit-pending-cae) NO se cableó — no tienen `idempotency_key` en el body hoy (usan `receipt_id`/`subscription_payment_id`/`fiscal_document_id` como clave natural, ya idempotentes); gobernanza CRÍTICA (AFIP), fuera de foco de este change de transporte. `payments` (webhook MercadoPago) tampoco aplica: no es una mutación de cliente con Idempotency-Key, usa `x-signature`/`x-request-id` de MP.
- [x] 3.4 Tests: reintento con misma clave no duplica; header tiene precedencia sobre body; mutación sin clave → 422 `idempotency_key_required`

## 4. Idempotencia de cerrar caja (migración gobernada — Lección C3)

- [x] 4.1 Escribir migración idempotente que recrea `operation_idempotency_operation_kind_check` con la UNIÓN vigente verificada en prod + `cash_session_close` (`DROP CONSTRAINT IF EXISTS` + `ADD CONSTRAINT`)
- [x] 4.2 Test de migración (patrón `tests/migrations/`): el CHECK admite `cash_session_close` y conserva los 8 kinds previos; idempotente al re-aplicar
- [x] 4.3 Registrar la idempotencia de cierre en el RPC/service de cerrar caja usando `operation_kind='cash_session_close'`, dentro de la transacción de cierre (sin tocar el arqueo)
- [x] 4.4 Cablear `require_idempotency_key` en `POST /cash/sessions/{id}/close`
- [x] 4.5 Tests: doble cierre con misma clave cierra una sola vez y devuelve el resultado del primero

## 5. DEC-24 (UoW = RPCs SECURITY DEFINER)

- [x] 5.1 Agregar DEC-24 a `knowledge-base/09_decisiones_y_supuestos.md`: el UoW de Aliadata es el RPC `SECURITY DEFINER` (transacción en Postgres, ningún service comitea, RN-C1 por diseño); complementa DEC-13 y DEC-20

## 6. Frontend

- [x] 6.1 Adaptar los hooks/servicios TS que leen `total_operations`/`total` al envelope `{items,total,page,pages}` — `use-sales.ts` y `use-purchases.ts` migrados a `total` (con `page?`/`pages?` opcionales en el tipo de respuesta; `buildPaginationMeta` sigue recalculando `pageCount` client-side)
- [x] 6.2 Adaptar los hooks/servicios de mutación que mandan `idempotency_key` en el body para enviar el header `Idempotency-Key` — `pythonClient.post` gana un 3er parámetro `extraHeaders` opcional; migrados `use-sales.ts`, `use-purchases.ts`, `use-customer-account.ts`, `use-supplier-account.ts`, `use-sales-orders.ts` (confirm + quick-sale) y `use-bank-reconciliation.ts` (import extracto + movimiento manual). El body ya NO manda `idempotency_key` desde el frontend (el fallback de body del backend queda para otros clientes/replay, no para este frontend)

## 7. Verificación

- [ ] 7.1 Suite backend completa verde (pytest + pytest-asyncio, ~960→) sin regresiones; sin `importlib.reload` de config en tests
- [ ] 7.2 `openspec validate --strict --change "v3-api-standards"` pasa
- [ ] 7.3 Smoke manual: un error de RPC, un 422 de validación, un listado paginado y un reintento idempotente devuelven los shapes esperados
