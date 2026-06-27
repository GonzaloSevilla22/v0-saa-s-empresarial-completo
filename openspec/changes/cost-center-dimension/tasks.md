## 0. Pre-flight (governance BAJO — sin gate bloqueante)

- [x] 0.1 Confirmar el nombre exacto del helper de rol para escritura de catálogo (`is_account_writer` vs helper owner/admin específico) leyendo una migración de C-28/C-30; usar el mismo en las policies y en el `require_role` del service.
- [x] 0.2 Confirmar la última migración (`ls supabase/migrations | sort | tail -1`) y datear la nueva estrictamente por encima (esperado `20260802000001`).
- [x] 0.3 Confirmar las columnas vigentes de `public.expenses` y `public.purchases` (que `account_id` y `branch_id` existen) y la firma actual de `rpc_create_purchase_operation`.

## 1. Migración DB (aditiva; archivos en supabase/migrations/, aplica CI)

- [x] 1.1 RED: test del schema `cost_centers` (columnas + `UNIQUE(account_id, lower(name))` + `is_active` default true) y de la RLS (SELECT por miembros de la cuenta; INSERT/UPDATE sólo owner/admin; aislamiento por `account_id`).
- [x] 1.2 GREEN: escribir la migración que crea `cost_centers` + índice por `account_id` + índice único funcional `(account_id, lower(name))` + RLS habilitada + policies SELECT (miembros) e INSERT/UPDATE (owner/admin vía el helper confirmado en 0.1). No aplicar a mano — CI corre `supabase db push`.
- [x] 1.3 RED: test de la columna `cost_center_id` nullable en `expenses` y `purchases` (FK a `cost_centers`, `ON DELETE SET NULL`, default NULL, sin backfill).
- [x] 1.4 GREEN: `ALTER TABLE ... ADD COLUMN IF NOT EXISTS cost_center_id uuid NULL REFERENCES cost_centers(id) ON DELETE SET NULL` en `expenses` y `purchases` (idempotente).
- [x] 1.5 RED: test de que `rpc_create_purchase_operation` acepta `p_cost_center_id` opcional, valida pertenencia a la cuenta y lo escribe en TODAS las filas de la operación; y de que el alta sin el parámetro persiste `NULL` (regresión).
- [x] 1.6 GREEN: actualizar `rpc_create_purchase_operation` (param opcional default NULL + validación espejo de `branch_id` + propagación a todas las líneas). NO agregar `operation_kind` nuevo → NO tocar el CHECK de `operation_idempotency`.
- [x] 1.7 TRIANGULATE: cuenta-aislada + nombre duplicado case-insensitive + member-rechazado + compra multi-línea con/ sin centro — verdes.

## 2. Backend — repository (acceso a datos, JWT-passthrough)

- [x] 2.0 SAFETY NET: baseline verde de los tests de repositories existentes; reportar cualquier rojo pre-existente sin tocarlo.
- [x] 2.1 RED: test del `CostCenterRepository` (list activos/todos por cuenta, create, update name/code, deactivate) contra asyncpg mockeado.
- [x] 2.2 GREEN: implementar `CostCenterRepository` (3 capas) + extender el repo de gasto/compra para aceptar/propagar `cost_center_id` opcional.
- [x] 2.3 TRIANGULATE: list excluye/incluye inactivos según flag; create idempotente ante choque de nombre; deactivate marca `is_active=false`.

## 3. Backend — service (lógica + guards)

- [x] 3.1 RED: test del `CostCenterService` con `require_role(owner/admin)` para create/update/deactivate (member → 403); list permitido a todos los miembros.
- [x] 3.2 GREEN: implementar el service con los guards (defensa en profundidad sobre la RLS) + normalización (trim) del nombre.
- [x] 3.3 TRIANGULATE: owner/admin OK, member 403 en escritura, member OK en lectura, nombre con espacios se normaliza.

## 4. Backend — router + schemas Pydantic v2

- [x] 4.1 RED: test de los endpoints CRUD `/cost-centers` (GET list, POST, PATCH, PATCH deactivate) con validación de payload Pydantic v2.
- [x] 4.2 GREEN: implementar el router (validación + DI) + schemas `CostCenterCreate/Update/Out`; exponer `cost_center_id` opcional en los schemas de alta de gasto y compra.
- [x] 4.3 TRIANGULATE: payload inválido → 422; create → 201 con `Out`; deactivate → `is_active=false` en la respuesta.

## 5. Frontend — catálogo + selector (Next.js, sin any)

- [x] 5.1 Hooks React Query del catálogo (`useCostCenters`, mutaciones create/update/deactivate) tipados (sin `any`; tipos en `lib/types.ts` si hace falta).
- [x] 5.2 Pantalla/sección de gestión del catálogo de centros de costo (listar, crear, editar, desactivar) — visible/gestionable sólo para owner/admin.
- [x] 5.3 Selector "Centro de costo (opcional)" en los formularios de alta de gasto y de compra (sólo centros activos); enviar `cost_center_id` al backend.
- [x] 5.4 Tests vitest de los componentes/hooks nuevos (RED→GREEN): render del selector, envío con/ sin centro, gating por rol del CRUD.

## 6. Validación + cierre

- [x] 6.1 Regresión completa del gate `pytest -m "not integration"` + `vitest` verde.
- [x] 6.2 `next build` + `tsc` limpios (sin `any`).
- [ ] 6.3 Rama + PR; mergear si todos los checks pasan (`gh pr checks`).
- [ ] 6.4 Tras merge: actualizar `CHANGES.md` (sección Post-roadmap V2.x: V2.5 abierta con este change) y archivar vía `/opsx:archive`.
- [ ] 6.5 Guardar el resultado en engram (`opsx/cost-center-dimension/apply`).
