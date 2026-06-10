# Proposal: v20-fiscal-identity-clients (C-22)

## Why

Los clientes de Aliadata no tienen identidad fiscal: la tabla `clients` solo guarda `name`, `email` y `phone`. Sin CUIT/DNI, condición frente al IVA y razón social, es imposible emitir comprobantes válidos en Argentina — y C-27 (`v21-fiscal-profile`, facturación AFIP con CAE asíncrono, DEC-22) depende de que los clientes ya porten estos datos. Este change introduce el Value Object `FiscalIdentity` (DEC-18, Shared Kernel entre Customer y Supplier) del modelo de dominio V2 (`modelo-dominio-aliadata-v2.md` §5.5), como campos **opcionales** para no agregar fricción al alta de clientes del microemprendedor.

## What Changes

- Migración SQL: 3 columnas nullable en `clients` — `tax_id TEXT` (CUIT/DNI), `iva_condition TEXT` con CHECK (`'responsable_inscripto' | 'monotributista' | 'exento' | 'consumidor_final'`), `legal_name TEXT` (razón social).
- Backend FastAPI: `ClientCreate` / `ClientUpdate` / `ClientOut` (Pydantic v2) aceptan y devuelven los 3 campos opcionales; `iva_condition` validada como `Literal` de los 4 valores; `ClientRepository.create` inserta las columnas nuevas (el `update` genérico por dict ya las soporta).
- Frontend: utilidad `isValidCuit` — formato `^\d{2}-\d{8}-\d{1}$` + dígito verificador módulo 11 — en `lib/cuit-utils.ts`; sección "Datos fiscales" (colapsable/opcional) en `client-form.tsx` con CUIT/DNI, Condición IVA y Razón social; tipo `Client`, mapper y mutaciones de `use-clients.ts` extendidos.
- Sin cambios de RLS (las policies existentes por `account_id` cubren las columnas nuevas) y sin backfill (datos históricos quedan NULL = "consumidor final sin identificar").

No hay breaking changes: columnas nullable, campos opcionales en API y UI.

## Capabilities

### New Capabilities
- `client-fiscal-identity`: identidad fiscal opcional del cliente (CUIT/DNI, condición IVA, razón social) — persistencia, validación de CUIT con dígito verificador, exposición en API y captura en UI.

### Modified Capabilities
<!-- vacío — los specs existentes (data-api-endpoints, domain-react-query-hooks) describen los endpoints/hooks a nivel genérico; sus requirements no cambian -->

## Impact

- **DB**: `supabase/migrations/` — nueva migración aditiva sobre `clients` (proyecto `gxdhpxvdjjkmxhdkkwyb`, aplicar vía `npx supabase db push`, nunca el MCP).
- **Backend**: `backend/schemas/clients.py`, `backend/repositories/client_repository.py`, `backend/tests/test_clients.py`.
- **Frontend**: `frontend/lib/types.ts` (interface `Client`), `frontend/lib/cuit-utils.ts` (nuevo), `frontend/hooks/data/use-clients.ts`, `frontend/components/forms/client-form.tsx`, tests en `frontend/__tests__/`.
- **Governance**: BAJO (CRUD aditivo, sin dependencias, sin preguntas abiertas). Prerequisito de C-27 (CRÍTICO, AFIP).
