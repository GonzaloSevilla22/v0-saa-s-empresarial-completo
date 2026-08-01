## MODIFIED Requirements

### Requirement: Routers FastAPI por dominio con Pydantic v2 schemas
El sistema SHALL exponer un router FastAPI por dominio en `backend/routers/<domain>.py`. Cada router SHALL validar el payload de entrada con schemas Pydantic v2 definidos en `backend/schemas/<domain>.py` antes de llamar al service correspondiente. Los endpoints SHALL usar los prefijos: `/expenses`, `/clients`, `/products`, `/branches`, `/stock`, `/sales`, `/purchases`. Los endpoints están **activos sin condición de flag** — el feature flag `NEXT_PUBLIC_USE_PYTHON_API` fue eliminado en C-18; el frontend siempre llama a estos endpoints.

El prefijo `/organizations` fue retirado en `remove-organizations-dead-code`: su repositorio consultaba una tabla `organizations` que no existe en producción, por lo que `GET /organizations/{org_id}` y `PUT /organizations/{org_id}/settings` devolvían HTTP 500 desde su creación en C-16. No tenía consumidores.

#### Scenario: GET /expenses retorna lista de gastos de la org del usuario
- **WHEN** un usuario autenticado hace `GET /expenses` con Bearer token válido
- **THEN** retorna HTTP 200 con `{"items": [...], "total": N}` filtrado por la org del token; los ítems siguen el schema `ExpenseOut`

#### Scenario: POST /expenses con payload inválido retorna 422
- **WHEN** se hace `POST /expenses` con body `{"amount": "no-es-numero"}`
- **THEN** FastAPI retorna HTTP 422 con detalle de validación Pydantic antes de llamar al service

#### Scenario: GET /sales retorna ventas agrupadas por operation_id
- **WHEN** un usuario autenticado hace `GET /sales?date_from=2026-01-01&date_to=2026-06-30`
- **THEN** retorna HTTP 200 con ventas de esa org en el rango de fechas; ítems agrupados por `operation_id`

#### Scenario: POST /sales con idempotency_key duplicada retorna la operación previa
- **WHEN** se hace `POST /sales` con un `idempotency_key` que ya fue procesado por esta org
- **THEN** retorna HTTP 200 con la operación previa (no duplica) — el RPC subyacente es idempotente

#### Scenario: No se expone ningún endpoint bajo /organizations
- **WHEN** se hace `GET /organizations/{cualquier-id}` contra la app
- **THEN** responde HTTP 404 porque la ruta no está registrada (antes respondía HTTP 500 por tabla inexistente)
