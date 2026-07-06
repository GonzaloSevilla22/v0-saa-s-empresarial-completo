## 1. Migración DB: columnas de soft delete (aditiva, sin drops)

- [x] 1.1 Crear migración `supabase/migrations/<ts>_v3_soft_delete_masters.sql`; `ALTER TABLE ... ADD COLUMN IF NOT EXISTS deleted_by uuid` en `clients`, `products`, `suppliers`, `cost_centers`, `cashboxes`, `bank_accounts`
- [x] 1.2 En la misma migración: `ADD COLUMN IF NOT EXISTS deleted_at timestamptz` en `clients`, `suppliers`, `cost_centers`, `cashboxes`, `bank_accounts` (NO en `products`: ya existe desde `20260620000001`)
- [x] 1.3 `COMMENT ON COLUMN` documentando la convivencia `is_active` (baja lógica reversible) vs `deleted_at` (borrado) en `cost_centers` y `bank_accounts`
- [x] 1.4 Gate de comportamiento: verificar que las 6 tablas quedan con `deleted_at` y `deleted_by` (degrada con NOTICE en CI vacío, no aborta)

## 2. Migración DB: índices únicos parciales (RN-B3)

- [x] 2.1 Antes de tocar índices, verificar con gate que no hay duplicados activos por clave natural en cada tabla afectada (NOTICE si los hay, no aborta)
- [x] 2.2 Recrear `idx_products_sku_user`: `CREATE UNIQUE INDEX ... ON products (user_id, sku) WHERE sku IS NOT NULL AND deleted_at IS NULL` (drop del total previo dentro de la migración, con `IF EXISTS`)
- [x] 2.3 Recrear `idx_products_barcode_unique`: añadir `AND deleted_at IS NULL` al `WHERE` existente
- [x] 2.4 Crear índice parcial para `cost_centers`: `... ON cost_centers (account_id, lower(name)) WHERE deleted_at IS NULL` (reemplaza `cost_centers_account_name_lower_idx`)
- [x] 2.5 Gate de comportamiento: soft-deletear un producto con SKU `X` y verificar que se puede crear otro producto activo con SKU `X` en la misma cuenta sin violación de unicidad

## 3. Migración DB: guard RN-B4 (no borrar producto con referencia activa)

- [x] 3.1 Escribir función `fn_guard_product_soft_delete()` (`SECURITY DEFINER`) que, en `BEFORE UPDATE` sobre `products` cuando `NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL`, levanta excepción con `ERRCODE` propio si el producto tiene stock ≠ 0 (sumado sobre `branch_stock`) o aparece en líneas de documentos `draft`
- [x] 3.2 Crear trigger `trg_guard_product_soft_delete BEFORE UPDATE ON products` que invoca la función
- [x] 3.3 Gate de comportamiento: intentar soft-deletear un producto con stock ≠ 0 y verificar que la operación es rechazada; soft-deletear un producto sin stock ni draft y verificar que tiene éxito
- [x] 3.4 Enumerar la unión vigente de estados `draft` reales en prod antes de referenciarlos en el guard (lección del proyecto: CI no atrapa valores faltantes)

## 4. BaseRepository: soft_delete() + filtro de lectura (TDD)

- [x] 4.1 RED: test `test_soft_delete_marks_row` — `soft_delete("clients", id, account_id, by)` emite `UPDATE ... SET deleted_at=now(), deleted_by=$ WHERE id=$ AND account_id=$ AND deleted_at IS NULL` (assert sobre `conn.execute.call_args` SQL) y reporta fila afectada
- [x] 4.2 GREEN: implementar `soft_delete()` en `backend/repositories/base.py` con allowlist de nombres de tabla de maestro (anti-inyección de identificador)
- [x] 4.3 TRIANGULATE: test `test_soft_delete_already_deleted_is_noop` (fila ya borrada → 0 filas afectadas) y `test_soft_delete_wrong_account_noop` (aislamiento por cuenta)
- [x] 4.4 RED/GREEN: helper de filtro de lectura `deleted_at IS NULL` reutilizable con opción explícita `include_deleted`; test de que por defecto excluye borrados y con la opción los incluye
- [x] 4.5 REFACTOR: limpiar duplicación; correr `pytest backend/tests/test_base_repository.py`

## 5. Migrar repos/servicios de maestros al soft delete (TDD por repo)

- [x] 5.1 RED/GREEN `ClientRepository`: cambiar `delete()` (hard `DELETE FROM clients`) por `soft_delete("clients", ...)`; SELECTs de listado/get filtran `deleted_at IS NULL` vía el helper; tests actualizados
- [x] 5.2 RED/GREEN `ProductRepository`: cambiar `delete()` por `soft_delete("products", ...)`; asegurar que las lecturas filtran `deleted_at IS NULL`; test de que el borrado con stock propaga el error del guard (409)
- [x] 5.3 RED/GREEN `SupplierRepository`: agregar `soft_delete("suppliers", ...)` + filtro de lectura (si hoy no expone borrado, se agrega alineado al patrón)
- [x] 5.4 RED/GREEN `BankAccountRepository`: agregar `soft_delete("bank_accounts", ...)` para el borrado real; `list_active()` sigue filtrando `is_active=true` y ahora también `deleted_at IS NULL`
- [x] 5.5 RED/GREEN `CostCenterRepository`: mantener `deactivate()` (is_active) y agregar `soft_delete("cost_centers", ...)` para el borrado; lecturas filtran `deleted_at IS NULL`
- [x] 5.6 Propagar el `deleted_by` desde el usuario autenticado (`auth`) en la capa de servicio de cada maestro; el service traduce el error del guard RN-B4 a `HTTPException` 409 con mensaje de UX en español
- [x] 5.7 Ajustar routers de maestros que hoy exponen `DELETE /{id}` para que el borrado sea soft (sin cambiar el contrato HTTP 204); correr `pytest backend/tests/` completo

## 6. Documentación de reglas de negocio

- [x] 6.1 Agregar RN-B1..RN-B4 a `knowledge-base/05_reglas_de_negocio.md` (filtro centralizado, `deleted_by`, índices parciales, no-referencia-activa), citando V3 §4
- [x] 6.2 Documentar la política de las 5 categorías (maestros/documentos/ledgers/drafts/plataforma) como referencia, con la aclaración de que `branches` se desactiva (no se soft-deletea) y que `categories`/`price_lists` no existen aún

## 7. Verificación

- [x] 7.1 Suite backend completa verde (`pytest backend/tests/`)
- [x] 7.2 Tras merge (CI aplica la migración): verificación read-only en prod — las 6 tablas tienen `deleted_at`/`deleted_by`, los índices parciales existen, el trigger de `products` existe; un soft delete de prueba se oculta de las lecturas y permite recrear la clave
- [x] 7.3 Confirmar que el frontend sigue leyendo `is_active` sin cambios (no hay regresión en `use-cost-centers.ts` / `use-bank-accounts.ts`)
