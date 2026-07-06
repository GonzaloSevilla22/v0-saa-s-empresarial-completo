## Why

Hoy el borrado de maestros es inconsistente (H-riesgo del V2 §2.6.5): `clients` y `products` tienen `deleted_at` legacy, mientras `cost_centers`, `bank_accounts`, `branches` usan `is_active` y otros maestros no tienen nada. No existe `deleted_by` en ningún lado, no hay índices únicos parciales (borrar un producto "quema" su SKU) ni una regla que impida borrar un maestro todavía referenciado. El modelo de dominio V3 §4 define una política única de borrado por categoría de entidad; este change la aplica sobre los maestros existentes.

## What Changes

- **Política única de borrado por categoría (V3 §4)**, formalizada como capability nueva: maestros → soft delete (`deleted_at` + `deleted_by`); documentos confirmados → nunca se borran, se anulan por transición con motivo (ya cubierto por `document-status-history`); ledgers → contra-asiento (ya append-only); drafts → hard delete permitido; Membership se revoca y UserAccount se anonimiza. Este change implementa **solo la parte de maestros**; el resto ya está resuelto por otros changes y se documenta como política de referencia.
- **`deleted_by UUID` en todos los maestros** que hacen soft delete, y `deleted_at TIMESTAMPTZ` donde falta (`suppliers`, `categories`, `price_lists`, `cost_centers`, `cashboxes`, `bank_accounts`). `clients` y `products` ya tienen `deleted_at`: solo se agrega `deleted_by`.
- **`is_active` se conserva** en los maestros que hoy lo tienen (`cost_centers`, `bank_accounts`) — el frontend lo lee directamente. No se dropea; se agrega `deleted_at`/`deleted_by` en paralelo. `deleted_at IS NOT NULL` implica inactivo, pero `is_active` sigue siendo la bandera de baja lógica reversible. No es un **BREAKING**.
- **Índices únicos parciales (RN-B3)**: `UNIQUE (account_id, <clave natural>) WHERE deleted_at IS NULL` por maestro (SKU de productos, documento de clientes/proveedores, código/nombre de catálogos), para poder recrear un valor borrado. Se recrean reemplazando los índices únicos totales existentes.
- **Guard de no-referencia-activa (RN-B4)**: un maestro no se soft-deletea si tiene referencia activa (producto con stock ≠ 0 o incluido en documentos DRAFT). Enforcement a nivel DB (función/trigger, invariante duro) + error legible en el service layer (UX).
- **Filtro `deleted_at IS NULL` en el `BaseRepository` del backend (RN-B1)**: una sola vez, no por query. Método `soft_delete()` centralizado (RN-B2, setea `deleted_at` + `deleted_by`). Alcance mínimo enfocado en soft-delete: **no** incluye paginación ni RFC 7807 (eso es `v3-api-standards`).
- **`branches` queda FUERA de scope**: V3 §4 explícita que Branch "se desactiva (`is_active = false`), no se borra — tiene movimientos referenciándola". Se mantiene en `is_active`; no se le agrega el patrón soft-delete en este change.

## Capabilities

### New Capabilities
- `soft-delete-policy`: Política única de borrado por categoría de entidad (maestros / documentos / ledgers / drafts / plataforma) y sus reglas de implementación para maestros: soft delete con `deleted_at` + `deleted_by` (RN-B1/RN-B2), unicidad conviviendo con soft delete vía índices únicos parciales (RN-B3), y verificación de no-referencia-activa antes de borrar (RN-B4).

### Modified Capabilities
- `base-repositories`: `BaseRepository` gana un filtro implícito `deleted_at IS NULL` para las lecturas de maestros y un método `soft_delete()` que setea `deleted_at` + `deleted_by` en una sola definición.

## Impact

- **DB (Supabase/Postgres)**: nueva migración aditiva — `ALTER TABLE ... ADD COLUMN deleted_by`, `ADD COLUMN deleted_at` donde falta; reemplazo de índices únicos totales por parciales `WHERE deleted_at IS NULL` (patrón NOT VALID/creación concurrente-segura); función guard RN-B4 + trigger `BEFORE UPDATE` que dispara al setear `deleted_at`. Sin drops de columnas. RLS existente por `account_id` intacta.
- **Backend (FastAPI/asyncpg)**: `backend/repositories/base.py` (`BaseRepository`) — filtro de soft-delete y `soft_delete()`; repositorios de maestros (`product_repository`, `client_repository`, `supplier_repository`, `bank_account_repository`, `cost_center_repository`, etc.) migran su borrado/baja al patrón único.
- **Frontend**: sin cambios obligatorios — `is_active` se conserva; las pantallas de maestros siguen leyendo lo que ya leen. Ajustes de UI solo si una pantalla expone hoy un borrado cuya semántica cambia.
- **Reglas de negocio**: se agregan RN-B1..RN-B4 a `knowledge-base/05_reglas_de_negocio.md`.
- **Tests**: pytest + pytest-asyncio para `BaseRepository.soft_delete()`, el filtro de lectura y el guard RN-B4; gates de comportamiento en la migración (índice parcial permite recrear SKU; guard rechaza borrado con referencia activa).
