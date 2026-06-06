## Context

El modelo de datos actual (tablas `sales`, `purchases`, `expenses`, `stock_movements`) no tiene noción de "sucursal". Todos los datos pertenecen a una cuenta (`account_id`, introducido en C-05). Este change añade una dimensión ortogonal: cada operación puede opcionalmente estar asociada a una sucursal dentro de la misma cuenta. El módulo es exclusivo del plan `pro` (0 sucursales para gratis/inicial/avanzado según RN-03; se prevé que en el futuro avanzado tenga hasta 1 sucursal pero esto no está en scope aquí).

## Goals / Non-Goals

**Goals:**
- Tabla `branches` con CRUD completo, soft-delete, y límite server-side de 3 por cuenta PRO.
- Campo `branch_id NULLABLE` retrocompatible en `sales`, `purchases`, `expenses`, `stock_movements`. `NULL` semánticamente = "sucursal principal".
- RLS que restringe lectura/escritura de branches a miembros de la misma cuenta; escritura solo para `owner` y `admin`.
- Page `/sucursales` (CRUD con gating de plan).
- Selector de sucursal en formularios de venta, compra y gasto (dropdown opcional).
- Filtro de sucursal en dashboard (URL query param `?branch=<id>`).
- Reporte por sucursal en `/reportes/sucursal`.

**Non-Goals:**
- Stock por sucursal (C-08 — depende de C-07).
- Transferencias de stock entre sucursales (C-08).
- Multi-sucursal para planes inferiores a PRO.
- Mapa o geolocalización de sucursales.

## Decisions

### D-01: `branch_id NULLABLE` (retrocompatibilidad vs. sucursal explícita)

**Decision**: `branch_id` es nullable en todas las tablas de operaciones; `NULL` = "global / sin sucursal".

**Alternativa descartada**: crear una sucursal "Principal" automáticamente y forzar un `branch_id` siempre. Requeriría backfill de todos los registros existentes y complica la migración.

**Rationale**: La retrocompatibilidad es prioridad (hay usuarios reales en producción). El filtro de dashboard puede tratar `NULL` como "todas las sucursales" o como "operaciones sin sucursal asignada" según el contexto del selector.

---

### D-02: Límite de sucursales via RPC server-side

**Decision**: La creación de sucursales se hace exclusivamente vía `rpc_create_branch(account_id, name, address)` con `SECURITY DEFINER`, que verifica el cupo antes del INSERT.

**Alternativa descartada**: Verificar solo en UI. Inaceptable porque cualquier cliente puede bypassear la UI.

**Rationale**: Consistente con el patrón establecido en C-05 para `rpc_accept_invitation`. Server-side enforcement es la única garantía real.

---

### D-03: Filtro de sucursal como URL query param

**Decision**: El filtro de sucursal activo se serializa en la URL: `/dashboard?branch=<uuid>` o `/dashboard` (sin param = todas). Persistencia corta en `sessionStorage` para mantener la selección entre navegaciones internas.

**Alternativa descartada**: Zustand global. No es SSR-friendly ni shareable, y complica el estado de Server Components.

**Rationale**: Next.js App Router funciona mejor con state en URL; los filtros son shareables y el back-button funciona correctamente.

---

### D-04: Soft-delete de sucursales

**Decision**: `branches.is_active = FALSE` en lugar de DELETE físico. Los registros históricos de `sales`, `purchases`, etc. mantienen el `branch_id` original. Las sucursales inactivas no aparecen en el selector pero sí en reportes históricos.

**Alternativa descartada**: Hard delete con SET NULL en FK. Pierde información histórica de dónde se registró cada venta.

---

### D-05: Gating UI — ocultar por plan, no solo deshabilitar

**Decision**: El menú de "Sucursales" y el selector de branch en formularios son completamente omitidos del DOM para planes no-PRO. No se renderiza un botón deshabilitado.

**Rationale**: Consistente con el patrón de C-06 y C-11. Mostrar features bloqueadas como disabled puede frustrar al usuario sin propósito claro si no hay CTA visible.

**Excepción**: El menú lateral puede mostrar un item bloqueado con lock icon + CTA de upgrade, según decisión de diseño en C-06.

---

### D-06: Nomenclatura de la tabla — `branches` con `account_id`

**Decision**: La tabla se llama `branches` y referencia `account_id` (no `org_id`). El C-05 implementó el modelo multi-tenant con `accounts`/`account_members` (no `organizations`/`organization_members`). El spec de multi-tenant usa `account_id` — seguimos esa convención.

## Risks / Trade-offs

- **Migración en producción con usuarios reales**: los ALTER TABLE en `sales`, `purchases`, `expenses` y `stock_movements` son retrocompatibles (ADD COLUMN NULLABLE + DEFAULT NULL). No se esperan locks prolongados. Riesgo: bajo.

- **Performance del filtro de dashboard**: filtrar todas las queries por `branch_id` puede requerir índices adicionales. Mitigación: crear índice `(account_id, branch_id)` en las 4 tablas al mismo tiempo que el ALTER TABLE.

- **Selector de sucursal inconsistente en formularios**: si el usuario cambia de sucursal en el header pero ya tiene abierto un formulario de venta, el selector del formulario podría quedar desfasado. Mitigación: el selector del formulario es independiente del header — el usuario elige explícitamente la sucursal por operación.

## Migration Plan

1. Aplicar migración SQL:
   - CREATE TABLE `branches`
   - ALTER TABLE `sales`, `purchases`, `expenses`, `stock_movements` ADD COLUMN `branch_id`
   - CREATE INDEX en las 4 tablas
   - Habilitar RLS en `branches`
   - CREATE FUNCTION `rpc_create_branch`

2. Deploy Next.js con feature flag por plan (page `/sucursales` y selector de branch ocultos si plan ≠ 'pro').

3. No hay rollback destructivo de datos: las columnas `branch_id` son nullable, la tabla `branches` puede borrarse si se revierte.

## Open Questions

- **OQ-01**: ¿El plan `avanzado` tendrá sucursales en el futuro (ej: 1 sucursal)? La KB actual dice 0 para avanzado. Implementamos 0 ahora; el límite en `plan_limits` lo controla sin cambiar código.
- **OQ-02**: ¿El selector de sucursal en formularios debe recordar la última selección? Por ahora, default a `NULL` (sin sucursal) en cada nuevo formulario.
