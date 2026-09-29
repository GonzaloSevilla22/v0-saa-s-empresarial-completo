## MODIFIED Requirements

### Requirement: Seed del catálogo refleja las máquinas de estado vigentes

El sistema SHALL sembrar el catálogo con las transiciones que las tablas de documentos permiten actualmente: Quote (`draft→sent`, `draft|sent→accepted`, `draft|sent→expired`, `draft|sent→rejected` y la reapertura por edición `expired|rejected→draft`), SalesOrder (`draft→confirmed`), FiscalDocument (`pending_cae→authorized`, `pending_cae→rejected`), CashSession (`open→closed`), ReconciliationSession (`open→closed`), StockTransfer (terminal en `completed`), más la fila de creación (`from_status = NULL`) de cada tipo. El sistema NOT SHALL sembrar transiciones que ninguna operación vigente ejecuta.

Un estado SHALL estar marcado como terminal (`is_terminal_to`) sólo si no tiene transiciones salientes catalogadas. Para Quote, el único estado terminal SHALL ser `accepted`: `expired` y `rejected` admiten la reapertura a `draft` al editar el presupuesto, y por eso NOT SHALL estar marcados como terminales.

#### Scenario: El seed cubre las transiciones ejecutadas por los RPCs actuales
- **WHEN** cualquier RPC de transición vigente registra su cambio de estado
- **THEN** la transición correspondiente existe en el catálogo y el registro tiene éxito

#### Scenario: Transiciones sin operación no se siembran
- **WHEN** una transición está definida en el CHECK de una tabla pero ningún RPC la ejecuta (por ejemplo `sales_order → canceled`)
- **THEN** esa transición no está en el seed inicial y se agregará cuando exista la operación que la aplique

#### Scenario: La reapertura del presupuesto está catalogada
- **WHEN** la edición de un presupuesto en `expired` o `rejected` registra su vuelta a `draft`
- **THEN** la transición existe en el catálogo, con los roles de vendedor, administrador y dueño, y el registro tiene éxito

#### Scenario: Sólo accepted es terminal para el presupuesto
- **WHEN** se consulta `is_terminal_status` para `quote` en `accepted`, `expired` y `rejected`
- **THEN** sólo `accepted` es terminal, y ninguna transición del catálogo sale de un estado marcado terminal
