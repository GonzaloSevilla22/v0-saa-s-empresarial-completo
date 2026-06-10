## Context

El sistema tiene tres mecanismos de tenancy activos simultáneamente en las tablas ERP:
- `account_id` — modelo activo; las RLS ya usan `current_account_ids()` sobre esta columna (implementado en C-05)
- `user_id` — modelo original (un usuario = un tenant); todavía presente en la mayoría de tablas ERP y como filtro exclusivo en el backend Python (118 ocurrencias) y 11 Edge Functions
- `company_id` — generación intermedia; todavía presente en `suppliers` (sin `account_id`), `inventory_movements`, y como columna residual en las tablas ERP

La tabla `suppliers` es el único punto del esquema sin `account_id`, lo que crea un agujero de seguridad: sus filas no están protegidas por las RLS basadas en `current_account_ids()`.

Hay 6 filas en `companies` + 5 en `company_users` que representan organizaciones reales de una versión anterior; necesitan mapearse a `accounts` antes del drop.

El backend Python (C-15/C-16) opera en producción filtrando por `user_id`. Si se droppean las columnas legacy sin refactorizar el backend primero, el backend se rompe en producción.

**Decisiones de diseño acordadas (PA-16/17/18):**
- PA-16: refactor backend Python y Edge Functions va **dentro de este mismo change** (scope atómico)
- PA-17: **zero-downtime estricto** — patrón Strangler Fig; no hay ventana de mantenimiento
- PA-18: las 6 filas de `companies` son **organizaciones reales** y se migran a `accounts`

## Goals / Non-Goals

**Goals:**
- Una sola columna de tenancy (`account_id`) en todas las tablas ERP, sin NULLs
- `suppliers` protegida por RLS usando `account_id`
- Backend Python filtrando por `account_id` en todos los repositorios
- 11 Edge Functions usando `account_id` como filtro primario
- 4 frontend hooks usando `account_id` en sus query keys
- Drop limpio de `company_id` y `user_id` (como mecanismo de tenancy) de las tablas ERP
- Organizaciones de `companies` migradas a `accounts` antes del drop
- Zero downtime en toda la operación

**Non-Goals:**
- Migración de ventas planas a `sale_items` (C-20)
- Unificación del ledger de inventario (C-21)
- Cambios en la UI visible al usuario
- Renaming conceptual de `account_id` → `organization_id` (DEC-24: pospuesto)
- Migración de IA/OCR a Python (DEC-15: bloqueado por presupuesto)

## Decisions

### DEC-1 — Strangler Fig con 7 pasos ordenados

El drop de columnas legacy solo ocurre **al final**, después de que todo el código que las consumía fue migrado y validado en producción.

**Orden de ejecución:**
1. **DB — Backfill**: completar NULLs de `account_id` en tablas que ya tienen la columna; agregar `account_id` a `suppliers`; backfill via `company_id → accounts` join; migrar 6 filas de `companies` a `accounts`
2. **DB — RLS suppliers**: agregar política RLS sobre `account_id` en `suppliers` (SELECT, INSERT, UPDATE, DELETE)
3. **Backend Python**: actualizar `core/auth.py` y `core/deps.py` para obtener `account_id` del request context; reemplazar `user_id = $1` → `account_id = $1` en los 7 repositorios; actualizar tests
4. **Edge Functions (11)**: reemplazar filtro `user_id` → `account_id`
5. **Frontend hooks (4)**: actualizar query keys
6. **Validación**: verificar 0 NULLs en `account_id` en producción; smoke test de backend y Edge Functions
7. **DB — Drop legacy** [CRÍTICO — requiere aprobación PO]: drop `company_id` y `user_id` (como tenancy) de tablas ERP; drop `company_id` de `suppliers` (ya no es el campo de tenancy)

**Alternativa descartada:** Drop primero con vistas de compatibilidad. Demasiado riesgo con 11 Edge Functions en Deno y el backend Python en Render que no pueden tener hot-reload coordinado.

### DEC-2 — Obtención de `account_id` en el backend Python

El JWT de Supabase tiene `sub = user_id`. El `account_id` no está en el JWT claim estándar. Estrategia:
- En `get_db_conn` (`core/deps.py`), después de configurar el JWT passthrough en la conexión asyncpg, ejecutar `SELECT account_id FROM account_members WHERE user_id = auth.uid() LIMIT 1` via la conexión ya autenticada
- Exponer como `account_id: UUID = Depends(get_account_id)` en los endpoints
- Los repositorios reciben `account_id` como parámetro (ya lo hacen como `org_id`; este change es renaming del origen, no de la firma)

**Alternativa descartada:** Custom JWT claim `x-account-id` via Supabase hook. Requiere configurar un hook en el Dashboard (no versionable) y modificar todos los JWT existentes. Más complejo de implementar y mantener.

### DEC-3 — Migración de `companies` a `accounts`

Para cada fila en `companies`:
1. Buscar si existe un `account_id` en `account_members` para los `user_id` asociados via `company_users`
2. Si existe: ese es el `account_id` correcto; no crear cuenta nueva
3. Si no existe: crear una nueva `accounts` row con los datos de la `company`; crear `account_members` como owner para el usuario asociado

**Alternativa descartada:** Ignorar las 6 filas (tratarlas como datos de prueba). El PO confirmó que son organizaciones reales (PA-18).

### DEC-4 — No agregar NOT NULL constraint a `suppliers.account_id` hasta el paso 6

Para zero-downtime: la columna empieza nullable, se backfilla, se verifica en paso 6, y solo entonces se agrega `NOT NULL`. El drop de `company_id` de `suppliers` va en el paso 7 junto con los demás drops.

## Risks / Trade-offs

| Riesgo | Mitigación |
|---|---|
| Backend Python en producción usa `user_id`; drop prematuro lo rompe | Pasos 3 y 4 (código) DEBEN completarse y validarse antes del paso 7 (drop). El paso 7 requiere aprobación PO explícita. |
| `suppliers` sin RLS durante el backfill | El paso 2 (agregar RLS) se hace ANTES que cualquier drop, tan pronto termine el backfill del paso 1. |
| Los 6 registros de `companies` pueden tener `user_id` sin `account_id` en `account_members` | El paso 1 incluye lógica de upsert: verifica existencia en `accounts` antes de crear; no duplica cuentas. |
| Drop de `user_id` podría romper queries de `auth.users` | Solo se dropean usos de `user_id` como filtro de tenancy, no los FK constraints a `auth.users`. Auditar tabla por tabla antes del paso 7. |
| Test suite del backend usa `user_id` hardcodeado en fixtures | El paso 3 incluye actualización de fixtures. CI verifica antes del merge. |

## Migration Plan

**Rollback strategy:** Los pasos 1-6 son todos aditivos o code-only — reversibles. El paso 7 (drop de columnas) es el único irreversible; solo se ejecuta después de validación en producción y con aprobación explícita del PO.

**Deploy order:**
1. PR de migrations SQL (pasos 1-2): aplicar via `npx supabase db push` al proyecto `gxdhpxvdjjkmxhdkkwyb`
2. PR de backend Python (paso 3): deploy en Render; verificar `/health` post-deploy
3. PR de Edge Functions (paso 4): deploy via `supabase functions deploy`
4. PR de frontend hooks (paso 5): deploy en Vercel; verificar en staging
5. Validación manual + automática (paso 6): queries de verificación en producción
6. PR de migrations SQL de cleanup (paso 7): aplicar solo con ✅ de PO

**Nota sobre los tests del backend:** antes de tocar cualquier repositorio, correr `pytest` para capturar el baseline; debe quedar verde en todos los repos. Cualquier falla pre-existente se reporta al PO antes de continuar.

## Open Questions

Ninguna — PA-16, PA-17 y PA-18 resueltas. Las preguntas PA-19 (6 filas en `warehouses`) y PA-20 (variantes en backfill de `sale_items`) se resolverán en C-21 y C-20 respectivamente.
