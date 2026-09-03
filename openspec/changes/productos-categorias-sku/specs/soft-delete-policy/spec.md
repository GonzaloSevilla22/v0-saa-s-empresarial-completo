## MODIFIED Requirements

### Requirement: Soft delete de maestros registra autor y momento (RN-B1/RN-B2)

El sistema SHALL implementar el borrado de todo maestro como un soft delete que setea `deleted_at` (momento del borrado, `TIMESTAMPTZ`) y `deleted_by` (identidad del usuario que lo borró, para auditoría ERP — RN-B2). Toda lectura de listado o por id de un maestro SHALL excluir las filas con `deleted_at IS NOT NULL` de forma centralizada (RN-B1), no repitiendo el filtro en cada query. Los maestros alcanzados son: `clients`, `products`, `suppliers`, `cost_centers`, `cashboxes`, `bank_accounts` y `product_categories`.

`product_categories` (catálogo de categorías de producto por cuenta, capability `product-category`) se incorpora a la enumeración con la misma política que el resto de los maestros de catálogo: la baja es desactivación o soft delete, nunca borrado físico de una fila referenciada por productos.

#### Scenario: El soft delete registra deleted_at y deleted_by
- **WHEN** se soft-deletea un maestro
- **THEN** la fila queda con `deleted_at` = ahora y `deleted_by` = id del usuario que ejecutó la acción

#### Scenario: Un maestro borrado no aparece en las lecturas por defecto
- **WHEN** se lista o se consulta por id un maestro cuya fila tiene `deleted_at IS NOT NULL`
- **THEN** el resultado por defecto no incluye esa fila

#### Scenario: La fila borrada persiste para integridad referencial histórica
- **WHEN** un documento histórico (venta, compra, movimiento) referencia un maestro que luego fue soft-deleteado
- **THEN** la referencia sigue siendo válida y el dato del maestro sigue siendo legible por JOIN; no queda huérfana

#### Scenario: Una categoría de producto se da de baja como maestro
- **WHEN** un `owner`/`admin` da de baja una categoría de producto
- **THEN** la fila queda con `deleted_at` y `deleted_by`, deja de ofrecerse en los selectores de altas nuevas
- **AND** los productos que la referencian conservan su imputación y su nombre de categoría sigue siendo legible
