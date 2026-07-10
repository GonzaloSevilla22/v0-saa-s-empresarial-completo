## Why

El Modelo V3 (§7.1 y §7.3) exige dos ajustes menores al catálogo/maestros que hoy están a medias en la base real:

1. **Unidad de medida tipada.** La conversión entre unidades del mismo tipo (comprar por kg, vender por unidad) es capability V3.5, pero requiere que cada unidad ya cargue su `type`. Al inspeccionar prod (`gxdhpxvdjjkmxhdkkwyb`) se verificó que `units_of_measure.type` **ya existe** como `NOT NULL` con `CHECK (type IN ('unit','weight','volume','length','custom'))` y 10 unidades del sistema tipadas — es decir, el requisito físico del V3 §7.1 ya está cubierto por datos, pero **nunca se formalizó como contrato de capability** (no hay spec que fije la invariante "toda unidad porta su tipo" ni el modelo de catálogo global/per-tenant). Este change lo formaliza.
2. **Direcciones múltiples del cliente.** Hoy `clients` **no tiene ninguna columna de dirección** (verificado en prod: 16 columnas, ninguna de dirección). El V3 §7.3 pide `Customer.addresses: Address[]` operativas/editables con `alias` e `is_primary`, con la invariante "exactamente una primaria por cliente". La dirección **fiscal** sigue viviendo en `FiscalIdentity` (inmutable por snapshot) y queda fuera de alcance.

Governance del change: **BAJO** (maestros/catálogo, no toca auth/billing/dinero). Se elige el corte más chico y coherente: DB + API, UI diferida.

## What Changes

- **UoM (spec-only, sin migración):** se crea la capability `units-of-measure` que documenta el contrato ya vigente en prod: catálogo mixto global (`is_system=true`, visible a todo tenant por RLS) + per-tenant (`account_id`), unidad tipada (`type` obligatorio), factor de conversión relativo a la unidad base del mismo tipo, y la invariante de que la conversión V3.5 solo opera entre unidades del mismo `type`. **No hay DDL**: `type` ya está persistido y con CHECK. La alineación del enum a la nomenclatura canónica del V3 (`peso|volumen|contable`) se registra como **decisión diferida / pregunta al PO** (renombrar valores es BREAKING: toca CHECK + tipo del frontend + colapsa `length`/`custom`) — este change NO la ejecuta.
- **`client_addresses` (nueva tabla + API):**
  - Nueva tabla `public.client_addresses` con `account_id` (scope de tenancy directo), `client_id` (FK a `clients`), `alias`, campos de dirección operativa (`street`, `city`, `province`, `postal_code`, `notes`), `is_primary`, timestamps y soft-delete (`deleted_at`/`deleted_by`) para alinear con la política V3 §4.
  - **Invariante: exactamente una dirección primaria por cliente** entre las filas vivas — enforced con índice único parcial `UNIQUE (client_id) WHERE is_primary AND deleted_at IS NULL` + un RPC `rpc_set_primary_client_address` que hace el switch atómico (baja la anterior, sube la nueva) en una sola transacción.
  - RLS org-based siguiendo el patrón exacto de `clients` (SELECT por `current_account_ids()`, INSERT/UPDATE/DELETE por `is_account_writer(account_id)`), con las 4 policies (INSERT/UPDATE necesitan `WITH CHECK`).
  - Comportamiento ante **soft-delete del cliente padre**: las direcciones no se borran en cascada dura; quedan lógicamente inalcanzables porque las lecturas parten del cliente vivo (definido como requisito, ver design).
  - Endpoints FastAPI CRUD anidados bajo el cliente (`/clients/{client_id}/addresses`), arquitectura 3 capas (router → service → repository), Pydantic v2. El repositorio reutiliza `BaseRepository` (soft-delete centralizado).
- **Sin UI en este change.** El alta/edición de direcciones en el formulario de cliente se difiere; se deja anotado como próximo paso. Se agrega el tipo TS `ClientAddress` en `frontend/lib/types.ts` (sin `any`) para no dejar la API sin contrato de tipos, pero sin componentes.

## Capabilities

### New Capabilities
- `units-of-measure`: Catálogo de unidades de medida tipadas (peso/volumen/contable-equivalente), mixto global (`is_system`) + per-tenant, con factor de conversión relativo a la unidad base del mismo tipo. Formaliza el contrato ya vigente en la DB y habilita la conversión V3.5 sin migración futura.
- `client-addresses`: Direcciones operativas múltiples por cliente, con `alias`, invariante de exactamente una primaria por cliente, soft-delete y switch atómico de la primaria. Distinta de la dirección fiscal (que vive en la identidad fiscal, inmutable por snapshot).

### Modified Capabilities
<!-- Ninguna capability existente cambia sus REQUISITOS. `client-fiscal-identity` se
     referencia como frontera (la dirección fiscal NO se toca) pero su contrato no cambia. -->

## Impact

- **DB:** nueva migración `supabase/migrations/2026081300xxxx_v3_client_addresses.sql` (posterior a `20260812000001`) — nueva tabla + índices (FK, único parcial de primaria) + RLS (4 policies) + RPC de switch de primaria + gate de comportamiento auto-limpiante. **Idempotente / both-worlds-safe** (la integración GitHub de Supabase auto-aplica al mergear ANTES del `db push` de Actions). `units_of_measure`: **cero DDL**.
- **Backend (FastAPI):** `backend/schemas/client_addresses.py`, `backend/repositories/client_address_repository.py`, `backend/services/client_addresses.py`, endpoints anidados en `backend/routers/clients.py` (o router propio montado bajo el mismo prefijo). Tests pytest nuevos (TDD estricto; baseline suite 912 verde).
- **Frontend:** solo `frontend/lib/types.ts` (nuevo `ClientAddress`). Sin componentes (UI diferida).
- **Docs:** `knowledge-base/04_modelo_de_datos.md` (§clients / nueva §client_addresses y corrección de la ficha de `units_of_measure`, que hoy lista un enum de `type` desalineado con prod) y `CHANGES.md` (marcar el change).
- **Sin cambios** en auth, billing, pagos, IA, Realtime ni en la dirección fiscal.
