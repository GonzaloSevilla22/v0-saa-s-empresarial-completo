## Context

El Modelo V3 §4 define una política única de borrado. Hoy el borrado de maestros es inconsistente (H-riesgo del V2 §2.6.5, punto 5): "soft-delete inconsistente: `clients.deleted_at` y `products.deleted_at` existen; el resto no. Definir política única."

Estado real verificado contra `supabase/migrations/` (no asumido):

| Tabla | Scope | `deleted_at` | `deleted_by` | `is_active` | Clave natural / índice único |
|---|---|---|---|---|---|
| `products` | `account_id` | **SÍ** (migr `20260620000001`) | no | no | `idx_products_sku_user (user_id, sku) WHERE sku IS NOT NULL`; `idx_products_barcode_unique (user_id, barcode) WHERE barcode IS NOT NULL AND barcode <> ''` |
| `clients` | `account_id` | **no** | no | no | ninguno |
| `suppliers` | `account_id` (legacy `company_id` en transición) | no | no | no | ninguno |
| `cost_centers` | `account_id` | no | no | **SÍ** (def. true) | `cost_centers_account_name_lower_idx (account_id, lower(name))` (total) |
| `bank_accounts` | `account_id` | no | no | **SÍ** (def. true) | ninguno |
| `cashboxes` | `branch_id` → `account_id` (indirecto) | no | no | no | ninguno |
| `branches` | `account_id` | no | no | **SÍ** + `status`/`opened_at`/`closed_at` | `branches_account_name_unique (account_id, name)` |

Correcciones frente a lo que decía `CHANGES.md`:
- `CHANGES.md` afirma que "`clients`/`products` ya tienen `deleted_at`". **Solo `products` lo tiene**; `clients` NO. Este change agrega `deleted_at` a `clients`.
- `CHANGES.md` lista `categories` y `price_lists` entre los maestros a migrar. **Ninguna de las dos existe como tabla** en el schema (0 CREATE TABLE). Se excluyen del scope.

Backend (`backend/repositories/`): `BaseRepository` no tiene lógica de soft delete. `clients`/`products`/`expenses` hacen **hard delete** (`DELETE FROM ... WHERE id=$1 AND account_id=$2`, expuesto como `DELETE /{id}` 204). `cost_centers`/`points_of_sale` ya hacen soft delete vía `is_active=false` (`deactivate()`, expuesto como `PATCH /{id}/deactivate`). `bank_accounts` no expone borrado.

Frontend: `use-cost-centers.ts` y `use-bank-accounts.ts` leen `is_active` directo de la fila y lo mapean a `isActive`. Esto es una restricción dura: dropear `is_active` rompería el frontend.

Governance: **MEDIO** (cambia semántica de borrado de maestros; documentos y ledgers no se tocan). Implementación con checkpoints, decisiones no obvias a revisión.

## Goals / Non-Goals

**Goals:**
- Unificar el borrado de los maestros existentes (`clients`, `products`, `suppliers`, `cost_centers`, `cashboxes`, `bank_accounts`) al patrón `deleted_at` + `deleted_by`.
- RN-B1/RN-B2: filtro `deleted_at IS NULL` y `soft_delete()` centralizados en `BaseRepository` (una sola vez).
- RN-B3: índices únicos parciales `WHERE deleted_at IS NULL` para poder recrear una clave natural borrada.
- RN-B4: guard de no-referencia-activa a nivel DB para `products` (stock ≠ 0 o en documentos `draft`).
- Migración aditiva, sin drops, sin BREAKING; `is_active` se conserva.
- Documentar la política completa (5 categorías) como capability de referencia.

**Non-Goals:**
- **`branches` queda fuera**: V3 §4 dice explícitamente que Branch "se desactiva (`is_active = false`), no se borra — tiene movimientos referenciándola". Ya tiene una máquina de estados (`status`, `opened_at`, `closed_at`) y guards propios (no cerrar con stock, no cerrar la última sucursal). Meterla en el patrón soft-delete duplicaría semántica y arriesgaría el hot path de stock. Se mantiene en `is_active`.
- **`categories` y `price_lists`**: no existen. Si en el futuro se crean, nacerán ya con el patrón; no son parte de este change.
- **Paginación estándar y RFC 7807** en `BaseRepository`: son de `v3-api-standards`. Acá el `BaseRepository` se toca de forma **mínima y enfocada** solo en soft-delete.
- **RBAC de quién puede borrar**: la matriz rol × acción es de `v3-rbac-multirole`. Acá se preserva el `require_role` existente por endpoint.
- Anonimización efectiva de `UserAccount` y revocación de `Membership`: se declaran en la política pero su implementación no se toca en este change (ya son entidades de plataforma con su propio ciclo).
- Migrar `suppliers` de `company_id` a `account_id`: fuera de scope; el soft delete se agrega sobre el `account_id` ya presente.

## Decisions

### D1 — Conservar `is_active`, agregar `deleted_at`/`deleted_by` en paralelo (no dropear)

`cost_centers` y `bank_accounts` exponen `is_active` al frontend directamente. Además `is_active` y `deleted_at` no son lo mismo: `is_active=false` es una **baja lógica reversible** (desactivar temporalmente una cuenta bancaria) mientras que `deleted_at` es un **borrado** (RN-B4 con guard). Se conservan ambos.

- Regla de convivencia: `deleted_at IS NOT NULL` ⇒ la fila está fuera de toda lectura por defecto (borrada). `is_active=false` con `deleted_at IS NULL` ⇒ fila viva pero desactivada (aparece en pantallas de administración que piden inactivas, no en selectores operativos).
- El `deactivate()` actual de `cost_centers`/`points_of_sale` **se mantiene** como está (baja lógica). El borrado real pasa a `soft_delete()`.
- **Alternativa descartada**: `is_active` como columna `GENERATED ALWAYS AS (deleted_at IS NULL)`. Se descartó porque perdería la baja lógica reversible (no se puede tener `is_active=false` sin borrar) y porque una generated column no es escribible desde el frontend/servicio actual.

### D2 — Índices únicos parciales: agregar `AND deleted_at IS NULL`, mantener el scope existente

Se reemplaza cada índice único total (o parcial-por-otra-condición) por su versión con `AND deleted_at IS NULL`. Para `products` los índices actuales están scopeados por `user_id`, no por `account_id`:

- `idx_products_sku_user (user_id, sku) WHERE sku IS NOT NULL` → `WHERE sku IS NOT NULL AND deleted_at IS NULL`.
- `idx_products_barcode_unique (user_id, barcode) WHERE barcode IS NOT NULL AND barcode <> ''` → añadir `AND deleted_at IS NULL`.
- `cost_centers_account_name_lower_idx (account_id, lower(name))` → nuevo índice parcial `... WHERE deleted_at IS NULL`.
- `clients`: hoy no hay clave natural única. **No se agrega una nueva** en este change (el documento fiscal del cliente puede repetirse legítimamente entre cuentas y el modelo aún no lo declara único). Si `v3-catalog-masters`/fiscal lo pide, se agregará allí.
- `suppliers`, `bank_accounts`, `cashboxes`: hoy no tienen clave natural única declarada; **no se inventa una** en este change. RN-B3 solo aplica donde ya existe unicidad.

**Decisión sobre el scope de products (`user_id` vs `account_id`)**: se mantiene `user_id` para no cambiar la semántica de unicidad en la misma migración que introduce soft-delete (cambiar scope y añadir el predicado a la vez mezcla dos migraciones de riesgo distinto). El movimiento `user_id → account_id` es un cleanup aparte (candidato a `v3-api-standards` o a un change de tenancy). Se documenta como Open Question OQ1.

**Colisiones al crear el índice parcial**: como el índice pasa a ser *más* permisivo (excluye filas borradas), no puede introducir colisiones nuevas sobre datos existentes (hoy no hay filas borradas en estas tablas salvo `products`, cuyas filas borradas simplemente dejarán de ocupar la clave). Aun así, cada `CREATE UNIQUE INDEX` se hace con `IF NOT EXISTS` + un gate de comportamiento que verifica que no haya duplicados activos antes de crear (degrada con NOTICE en CI vacío, no aborta).

### D3 — RN-B4 en la DB (trigger) + error legible en el service

La invariante "no borrar un maestro con referencia activa" se implementa como **función + trigger `BEFORE UPDATE`** sobre `products` que dispara cuando `NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL`. Si el producto tiene stock ≠ 0 (sumado sobre `branch_stock`) o aparece en líneas de documentos `draft`, la función levanta una excepción con un `ERRCODE`/mensaje propio (ej. `P0B04`). Razón: es un invariante de datos; debe ser imposible violarlo desde cualquier ruta (backend, RPC, MCP, SQL directo). El service layer captura ese error y lo traduce a un `HTTPException` 409 con un mensaje de UX en español.

- **Solo `products`** tiene una definición concreta de "referencia activa" (stock/draft). Para el resto de maestros de este change (`clients`, `suppliers`, `cost_centers`, `cashboxes`, `bank_accounts`) no hay una regla dura de referencia activa en V3 §4; su borrado no se bloquea (sus referencias históricas se preservan por diseño del soft delete). Se documenta que la extensión del guard a otros maestros, si se necesita, es incremental.
- **Alternativa descartada**: guard solo en el service. Se descartó porque los RPCs `SECURITY DEFINER` y el SQL directo lo saltarían.

### D4 — `BaseRepository.soft_delete()` mínimo + filtro de lectura opt-out

`BaseRepository` gana:
- `soft_delete(table, row_id, account_id, deleted_by)`: emite el `UPDATE ... SET deleted_at=now(), deleted_by=$4 WHERE id=$1 AND account_id=$2 AND deleted_at IS NULL`, retorna bool (afectó fila). `table` se restringe a un allowlist de nombres de maestro para evitar inyección de identificador.
- Un helper para el predicado de lectura `deleted_at IS NULL` reutilizable por los repos de maestros, con opción explícita de incluir borrados (auditoría). No se introduce un query builder: se mantiene el estilo de SQL crudo existente; el helper es un fragmento de cláusula o un parámetro de método.
- Los repos concretos migran su `delete()` (hard) a `soft_delete()` y añaden el predicado a sus SELECT de maestro.

**No** se agrega paginación ni manejo de errores RFC 7807 (es `v3-api-standards`). Rule of Three: hoy hay 3+ repos de maestros con el mismo patrón de borrado, así que centralizar está justificado.

### D5 — Migración aditiva, sin BREAKING, patrón NOT VALID/gate

- `ALTER TABLE ... ADD COLUMN IF NOT EXISTS deleted_by uuid` en los 6 maestros (referencia lógica a `auth.users`; se usa `uuid` sin FK dura para no acoplar a `auth` y evitar bloqueos, consistente con otras columnas de autoría del proyecto).
- `ADD COLUMN IF NOT EXISTS deleted_at timestamptz` donde falta (`clients`, `suppliers`, `cost_centers`, `cashboxes`, `bank_accounts`; `products` ya lo tiene).
- Índices parciales con `IF NOT EXISTS`.
- Gates de comportamiento en la migración: (a) recrear un SKU borrado tiene éxito; (b) el guard RN-B4 rechaza el borrado con stock; (c) `deleted_at IS NULL` filtra en un SELECT de prueba. Degradan con NOTICE en CI (DB vacía), no abortan.
- Rollback: como todo es aditivo, revertir es `DROP COLUMN`/`DROP INDEX`/`DROP TRIGGER` — pero al ser producción con datos, el rollback real es dejar de usar las columnas, no dropearlas.

## Risks / Trade-offs

- **[`clients` no tenía `deleted_at`, el hard delete actual es destructivo]** → Al cambiar el `DELETE FROM clients` por soft delete, el comportamiento observado por el usuario cambia (el cliente "borrado" sigue en la DB). Mitigación: es exactamente el objetivo del change; se comunica en la política. Las lecturas por defecto lo ocultan, así que la UX no cambia.
- **[Índice de `products` scopeado por `user_id`, no `account_id`]** → En una cuenta multi-usuario dos usuarios podrían crear el mismo SKU. Es un bug preexistente, no lo introduce este change. Mitigación: se documenta como OQ1; no se corrige acá para no mezclar migraciones.
- **[Guard RN-B4 en trigger `BEFORE UPDATE`]** → Un trigger sobre `products` añade costo a cada UPDATE que toca `deleted_at`. Mitigación: la condición `NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL` corta temprano; el chequeo de stock/draft solo corre en el borrado, no en updates normales.
- **[`cashboxes` scopeado por `branch_id`]** → El `soft_delete(table, id, account_id, by)` asume columna `account_id`. `cashboxes` no la tiene directa. Mitigación: para `cashboxes` el filtro de cuenta va por JOIN a `branches`; el `soft_delete` de cashbox usa una variante que resuelve el scope vía `branch_id` (o se pasa el `branch_id`). Se decide en apply; documentado como OQ2.
- **[`is_active` y `deleted_at` coexistiendo]** → Riesgo de confusión sobre "cuál es la baja". Mitigación: regla clara en D1 (borrado = `deleted_at`; desactivación reversible = `is_active`); se documenta en `knowledge-base/05`.

## Migration Plan

1. Migración SQL aditiva: `deleted_by` en los 6 maestros; `deleted_at` donde falta; recrear índices únicos como parciales `WHERE deleted_at IS NULL`; función + trigger RN-B4 sobre `products`; gates de comportamiento.
2. `BaseRepository.soft_delete()` + helper de filtro (TDD).
3. Migrar repos/servicios/routers de maestros del hard delete al soft delete (TDD por repo). `clients`, `products`, `expenses` cambian de `DELETE` a `soft_delete`; `cost_centers`/`bank_accounts` ya usan is_active y se les enchufa el soft_delete real para el borrado.
4. Agregar RN-B1..RN-B4 a `knowledge-base/05_reglas_de_negocio.md`.
5. Verificación read-only en prod tras el merge (columnas + índices + trigger presentes; un soft delete de prueba se oculta y permite recrear la clave).
6. Rollback: aditivo; no dropear en prod, solo dejar de escribir.

## Open Questions

- **OQ1** — ¿Se aprovecha para mover la unicidad de `products` de `user_id` a `account_id`? Recomendación: no acá (mezcla dos riesgos); dejar para un change de tenancy/`v3-api-standards`. Requiere decisión PO.
- **OQ2** — Para `cashboxes` (scope indirecto por `branch_id`), ¿el `soft_delete` recibe `branch_id` o resuelve el `account_id` por JOIN? Decisión menor, se resuelve en apply.
- **OQ3** — ¿`expenses` es un maestro o un documento? Hoy tiene hard delete. Recomendación: tratarlo como documento operativo editable (no maestro) y **dejar su borrado como está** fuera del scope de este change, salvo indicación del PO. (El scope de CHANGES.md no lista `expenses`.)
- **OQ4** — RN-B4 para el resto de maestros (¿bloquear borrar un centro de costo con gastos imputados?). Hoy `cost_centers` preserva la referencia sin bloquear. Recomendación: mantener sin guard salvo pedido del PO.
