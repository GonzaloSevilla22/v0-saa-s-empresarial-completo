# soft-delete-policy

## Purpose

Política única de borrado por categoría de entidad (Modelo V3 §4). Define cómo se borra cada tipo de entidad del sistema — maestros, documentos confirmados, ledgers append-only, borradores y entidades de plataforma — y documenta qué categorías ya están resueltas por otros capabilities. La implementación concreta de la categoría **maestros** vive en este capability; el resto (documentos, ledgers, plataforma) se declara aquí como referencia y se implementa en `document-status-history`, `inventory-single-ledger`, `cash-movement`, `bank-movement`, `customer-account`, `supplier-account`.

## Requirements

### Requirement: Política única de borrado por categoría de entidad

El sistema SHALL clasificar cada entidad en una de cinco categorías de borrado y aplicar la política correspondiente (Modelo V3 §4): **maestros** → soft delete (`deleted_at` + `deleted_by`); **documentos confirmados** → nunca se borran, se anulan por transición de estado con motivo; **ledgers append-only** → nunca se borran ni se modifican, se corrigen con un contra-asiento; **borradores** (drafts sin confirmar) → hard delete permitido; **entidades de plataforma** → `Membership` se revoca por estado y `UserAccount` se anonimiza, nunca se borran físicamente si tienen documentos asociados. Este capability define la política; su implementación en este change cubre únicamente la categoría **maestros** (las demás ya están resueltas por otros capabilities: `document-status-history`, `inventory-single-ledger`, `cash-movement`, `bank-movement`, `customer-account`, `supplier-account`).

#### Scenario: Un maestro se borra con soft delete
- **WHEN** un usuario borra un maestro (cliente, producto, proveedor, centro de costo, caja, cuenta bancaria)
- **THEN** el sistema no elimina físicamente la fila; setea `deleted_at` y `deleted_by`, y la fila desaparece de las lecturas de la aplicación

#### Scenario: Un documento confirmado no se borra
- **WHEN** un usuario intenta borrar un documento en estado confirmado (venta, compra, sesión de caja, documento fiscal)
- **THEN** el sistema rechaza el borrado; la única forma de invalidarlo es una transición de estado a un estado de anulación con motivo (gobernada por `document-status-history`)

#### Scenario: Un borrador se puede borrar físicamente
- **WHEN** un usuario borra un documento en estado `draft` (presupuesto/orden sin confirmar, carrito)
- **THEN** el hard delete está permitido porque un borrador sin confirmar no tiene valor probatorio

### Requirement: Soft delete de maestros registra autor y momento (RN-B1/RN-B2)

El sistema SHALL implementar el borrado de todo maestro como un soft delete que setea `deleted_at` (momento del borrado, `TIMESTAMPTZ`) y `deleted_by` (identidad del usuario que lo borró, para auditoría ERP — RN-B2). Toda lectura de listado o por id de un maestro SHALL excluir las filas con `deleted_at IS NOT NULL` de forma centralizada (RN-B1), no repitiendo el filtro en cada query. Los maestros alcanzados por este change son: `clients`, `products`, `suppliers`, `cost_centers`, `cashboxes`, `bank_accounts`.

#### Scenario: El soft delete registra deleted_at y deleted_by
- **WHEN** se soft-deletea un maestro
- **THEN** la fila queda con `deleted_at` = ahora y `deleted_by` = id del usuario que ejecutó la acción

#### Scenario: Un maestro borrado no aparece en las lecturas por defecto
- **WHEN** se lista o se consulta por id un maestro cuya fila tiene `deleted_at IS NOT NULL`
- **THEN** el resultado por defecto no incluye esa fila

#### Scenario: La fila borrada persiste para integridad referencial histórica
- **WHEN** un documento histórico (venta, compra, movimiento) referencia un maestro que luego fue soft-deleteado
- **THEN** la referencia sigue siendo válida y el dato del maestro sigue siendo legible por JOIN; no queda huérfana

### Requirement: Unicidad conviviendo con soft delete vía índices únicos parciales (RN-B3)

El sistema SHALL preservar las claves naturales de los maestros mediante índices únicos **parciales** que solo apliquen a las filas activas — condicionados a `WHERE deleted_at IS NULL` (además de las condiciones existentes de la clave). Esto SHALL permitir recrear un valor de clave natural (por ejemplo un SKU) que fue previamente soft-deleteado, sin colisión con la fila borrada.

#### Scenario: Se puede recrear un SKU previamente borrado
- **WHEN** un producto con SKU `X` es soft-deleteado y luego se crea un nuevo producto con el mismo SKU `X` en la misma cuenta
- **THEN** la creación tiene éxito porque el índice único parcial ignora la fila borrada (`deleted_at IS NOT NULL`)

#### Scenario: Dos maestros activos no pueden compartir la clave natural
- **WHEN** existe un maestro activo con clave natural `X` y se intenta crear otro activo con la misma clave en la misma cuenta
- **THEN** el índice único parcial rechaza la operación por violación de unicidad

### Requirement: No se borra un maestro con referencia activa (RN-B4)

El sistema SHALL rechazar el soft delete de un maestro que todavía tiene una referencia activa. Para `products`, referencia activa significa stock ≠ 0 o estar incluido en documentos en estado `draft`. El enforcement de esta invariante SHALL vivir a nivel de base de datos (función/trigger) para que sea imposible violarla desde cualquier capa, y SHALL exponerse como un error legible en la capa de servicio para dar feedback de UX.

#### Scenario: No se puede borrar un producto con stock distinto de cero
- **WHEN** se intenta soft-deletear un producto cuyo stock total es distinto de cero
- **THEN** la operación es rechazada y el usuario recibe un mensaje que indica que el producto tiene stock y no puede borrarse

#### Scenario: No se puede borrar un producto incluido en documentos borrador
- **WHEN** se intenta soft-deletear un producto que aparece como línea en un documento en estado `draft`
- **THEN** la operación es rechazada con un mensaje que indica la referencia activa

#### Scenario: Se puede borrar un maestro sin referencias activas
- **WHEN** se intenta soft-deletear un maestro sin stock ni referencias en documentos borrador
- **THEN** la operación tiene éxito y la fila queda con `deleted_at`/`deleted_by` seteados

### Requirement: Membership se revoca y UserAccount se anonimiza

El sistema SHALL tratar las entidades de plataforma con una política distinta a los maestros: una `Membership` (pertenencia de un usuario a una cuenta) se revoca cambiando su estado, no se borra físicamente; una `UserAccount` con documentos asociados se anonimiza (derecho de supresión), nunca se elimina físicamente. Este change NO modifica el comportamiento actual de estas entidades; las declara como parte de la política de referencia para que quede documentada la categoría.

#### Scenario: Una Membership con historial no se borra físicamente
- **WHEN** se da de baja la pertenencia de un usuario a una cuenta que tiene documentos generados por ese usuario
- **THEN** la pertenencia se marca como revocada (estado) y no se elimina la fila
