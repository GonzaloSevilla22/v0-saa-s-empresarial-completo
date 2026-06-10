# Tasks: v20-fiscal-identity-clients (C-22)

> TDD estricto: cada grupo arranca por el test (RED) antes del código de producción (GREEN), con triangulación mínima de 2 casos por comportamiento.

## 1. DB — Migración

- [x] 1.1 Crear migración `supabase/migrations/<timestamp>_clients_fiscal_identity.sql`: `ALTER TABLE public.clients ADD COLUMN IF NOT EXISTS tax_id TEXT, legal_name TEXT, iva_condition TEXT` + CHECK constraint `iva_condition IN ('responsable_inscripto','monotributista','exento','consumidor_final')`
- [x] 1.2 Aplicar la migración al proyecto real (`gxdhpxvdjjkmxhdkkwyb`) vía `npx supabase db push` y verificar columnas con un SELECT de information_schema

## 2. Backend — Schemas y Repository (TDD)

- [x] 2.1 RED: tests en `backend/tests/test_clients.py` — crear cliente con campos fiscales completos devuelve 201 con los 3 campos; crear sin campos fiscales devuelve null en los 3; `iva_condition` inválida devuelve 422; PUT solo-fiscal actualiza sin tocar name/email/phone
- [x] 2.2 GREEN: `backend/schemas/clients.py` — agregar `tax_id: str | None`, `legal_name: str | None`, `iva_condition: IvaCondition | None` (Literal de 4 valores) a `ClientCreate`/`ClientUpdate`/`ClientOut`
- [x] 2.3 GREEN: `backend/repositories/client_repository.py` — `create()` inserta las 3 columnas nuevas (el `update()` genérico ya las soporta vía dict)
- [x] 2.4 Ejecutar suite backend completa (`pytest backend/tests`) — sin regresiones sobre baseline

## 3. Frontend — Validación CUIT (TDD)

- [x] 3.1 RED: test `frontend/__tests__/cuit-utils.test.ts` — CUIT válido (`30-71234567-1`, `20-12345678-6`) → true; dígito incorrecto (`20-12345678-9`) → false; DNI (`12345678`) → aceptado como tax_id sin verificación; formato basura → false como CUIT
- [x] 3.2 GREEN: crear `frontend/lib/cuit-utils.ts` — `isCuitFormat()`, `isValidCuit()` (módulo 11, pesos 5,4,3,2,7,6,5,4,3,2; 11→0, 10→9) y `isValidTaxId()` (CUIT válido O DNI 7-8 dígitos)

## 4. Frontend — Tipos, hook y formulario (TDD)

- [x] 4.1 `frontend/lib/types.ts` — extender `Client` con `taxId?: string`, `ivaCondition?: IvaCondition`, `legalName?: string` + exportar tipo `IvaCondition`
- [x] 4.2 RED: test del mapper/mutaciones en `frontend/__tests__/hooks/` — el GET mapea `tax_id → taxId` etc.; add/update envían los campos snake_case a la API
- [x] 4.3 GREEN: `frontend/hooks/data/use-clients.ts` — `ClientApiRow` + `mapClient` + payloads de `addClient`/`updateClient` con los 3 campos
- [x] 4.4 RED: test `frontend/__tests__/ClientForm.test.tsx` — la sección "Datos fiscales" renderiza los 3 campos; CUIT inválido bloquea submit con mensaje; submit con CUIT válido incluye los campos en la mutación
- [x] 4.5 GREEN: `frontend/components/forms/client-form.tsx` — sección "Datos fiscales" (CUIT/DNI con validación visual, Select de condición IVA con 4 opciones + "Sin especificar", Razón social); precarga en edición
- [x] 4.6 Ejecutar suite frontend completa — sin regresiones sobre baseline

## 5. Cierre

- [ ] 5.1 Commit + push en `feat/fiscal-identity-clients` + PR a main (conventional commit `feat(clientes): ...`)
- [ ] 5.2 Marcar C-22 `[x]` en CHANGES.md (post-merge, junto con el archive del change)
