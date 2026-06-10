## Why

El esquema actual tiene una triple clave de tenancy (`user_id`, `company_id`, `account_id`) coexistiendo en las tablas ERP. Las políticas RLS ya migraron a `account_id` (C-05), pero los campos legacy persisten, `suppliers` todavía usa `company_id` sin `account_id`, y el backend Python (118 ocurrencias en 7 repositorios) + 11 Edge Functions siguen filtrando por `user_id`. Sin resolver esto primero, cualquier change de V2.0 escribe sobre un modelo inconsistente.

## What Changes

- **DB — Backfill `account_id`**: completar NULLs en todas las tablas ERP que ya tienen la columna (`sales`, `purchases`, `products`, `expenses`, `clients`, `stock_movements`)
- **DB — Suppliers**: agregar columna `account_id`, backfill via `company_id → accounts` join, actualizar RLS para usar `current_account_ids()`
- **DB — Migración de `companies`**: las 6 filas de `companies` (organizaciones reales) se mapean a `accounts` existentes o nuevas antes del drop
- **DB — Drop de columnas legacy** (último paso, zero-downtime): `company_id` de tablas ERP, `user_id` de tablas ERP donde no sea FK a `auth.users`
- **BREAKING — Backend Python**: reemplazar `user_id` por `account_id` como filtro de tenancy en los 7 repositorios (118 ocurrencias) + `core/auth.py` / `core/deps.py`
- **Edge Functions (11)**: actualizar filtro primario de `user_id` a `account_id` en `ai-insights`, `ai-resumen`, `ai-comparativo`, `ai-simulador`, `ai-prediccion`, `ai-precio`, `ai-rentabilidad`, `fair-advisor`, `invoice-ocr`, `generate-export`, `ai-quota`
- **Frontend hooks (4)**: actualizar query keys de `user_id` a `account_id` en `use-products`, `use-posts`, `use-clients`, `use-expenses-query`
- **Estrategia**: patrón Strangler Fig + zero-downtime. No hay ventana de mantenimiento.

## Capabilities

### New Capabilities
- `account-tenancy`: define el contrato canónico de tenancy única por `account_id` que fluye desde JWT claims → `core/deps.py` → repositorios Python → RLS Postgres. Es el invariante que todos los changes V2 heredan.

### Modified Capabilities
- `multi-tenant`: los requisitos del scoping por cuenta se amplían — `suppliers` pasa a ser scopeado por `account_id`, las columnas `company_id` y `user_id` se eliminan como mecanismos de tenancy, y los registros de `companies` (organizaciones históricas) se migran a `accounts` antes del drop.
- `domain-repositories`: los repositorios concretos del backend Python pasan a filtrar por `account_id` (ya expuesto como `org_id` en sus firmas); las queries SQL internas que hoy usan `WHERE user_id = $1` se actualizan a `WHERE account_id = $1`.

## Impact

- **Supabase DB** (`gxdhpxvdjjkmxhdkkwyb`): migrations SQL para backfill + add column + drop columns (Strangler Fig, pasos ordenados). Sin downtime.
- **`backend/repositories/`** (7 archivos): cambio masivo de `user_id` → `account_id` en todas las queries.
- **`backend/core/auth.py` y `core/deps.py`**: JWT passthrough extrae `account_id` del claim correcto en lugar de `user_id`.
- **`supabase/functions/`** (11 Edge Functions): actualizar filtro de tenancy.
- **`frontend/hooks/data/`** (4 hooks): actualizar query keys.
- **Tests del backend** (`backend/tests/`): actualizar fixtures y mocks que inyectan `user_id` como filtro.
- **No hay cambios en la UI visible al usuario**: el cambio es interno de infra; el comportamiento de la app no cambia.
- **Governance: CRÍTICO** — drop de columnas en producción con usuarios reales; coordinar con PO antes del paso final de drop.
