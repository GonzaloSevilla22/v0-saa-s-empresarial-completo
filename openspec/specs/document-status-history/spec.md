# document-status-history

> Synced from change `v3-document-status-history` — 2026-07-03

## Purpose

FSM genérica e historial append-only de transiciones de estado para todos los tipos de documento del sistema (Modelo V3, Feature 2). Provee una tabla única `document_status_history` para auditoría inmutable de cambios de estado, un catálogo de transiciones válidas modelado como datos (`document_status_transitions`), y un helper de escritura (`record_status_transition`) invocado desde los RPCs de negocio de cada capability (`quote`, `sales-order`, `cash-session`, `afip-fiscal-document`, `bank-reconciliation`, etc.) en la misma transacción que la operación que causa la transición.

## Requirements

### Requirement: Historial de estados de documentos append-only

El sistema SHALL persistir cada cambio de estado de un documento en una tabla `document_status_history` con las columnas `id`, `account_id`, `document_type`, `document_id`, `from_status`, `to_status`, `performed_by`, `reason`, `occurred_at`. La tabla SHALL ser append-only: ninguna capa de la aplicación puede emitir `UPDATE` ni `DELETE` sobre ella. El enforcement SHALL ser estructural (grants + ausencia de policy de escritura), no por convención.

#### Scenario: Registrar una transición inserta una fila de historial
- **WHEN** un documento transiciona de un estado a otro dentro de la transacción de negocio
- **THEN** el sistema inserta una fila en `document_status_history` con `from_status`, `to_status`, `performed_by` y `occurred_at` en la misma transacción

#### Scenario: El historial no admite modificación ni borrado
- **WHEN** el rol `authenticated` intenta un `UPDATE` o `DELETE` sobre `document_status_history`
- **THEN** la operación es rechazada por RLS/grants (no existe policy de escritura y `UPDATE`/`DELETE` están revocados)

#### Scenario: Aislamiento por cuenta en la lectura
- **WHEN** un usuario consulta el historial de estados
- **THEN** solo ve filas cuyo `account_id` pertenece a `current_account_ids()`

### Requirement: Creación de documento registra la primera entrada con from_status NULL

El sistema SHALL registrar la creación de un documento como la primera entrada de su historial, con `from_status = NULL` y `to_status` igual al estado inicial del documento (RN-A2).

#### Scenario: Alta de un documento genera el registro inicial
- **WHEN** se crea un documento en su estado inicial (por ejemplo un presupuesto en `draft` o una sesión de caja en `open`)
- **THEN** el sistema inserta una fila de historial con `from_status = NULL` y `to_status` = estado inicial

### Requirement: Política de transiciones válidas modelada como datos

El sistema SHALL declarar las transiciones de estado válidas como datos en un catálogo `document_status_transitions` (clave `document_type`, `from_status`, `to_status`, más `is_terminal_to`, `requires_reason`, `allowed_role`), y NOT como condicionales dispersos en el código. El sistema SHALL exponer funciones `is_valid_transition(document_type, from, to)`, `is_terminal_status(document_type, status)` y `transition_requires_reason(document_type, to)` que consultan ese catálogo.

#### Scenario: Una transición catalogada es válida
- **WHEN** se consulta `is_valid_transition` para una transición presente en el catálogo (por ejemplo `sales_order` de `draft` a `confirmed`)
- **THEN** la función devuelve verdadero

#### Scenario: Una transición no catalogada es inválida
- **WHEN** se consulta `is_valid_transition` para una transición ausente del catálogo
- **THEN** la función devuelve falso

#### Scenario: Un estado terminal no admite transiciones salientes
- **WHEN** se consulta `is_terminal_status` para un estado marcado terminal (por ejemplo `stock_transfer` en `completed`)
- **THEN** la función devuelve verdadero y no existe ninguna transición saliente catalogada desde ese estado

### Requirement: Registro de transición valida y exige motivo cuando corresponde

El sistema SHALL exponer un helper de escritura (`record_status_transition`) que, en la misma transacción de la transición: valida la transición contra la política (salvo cuando `from_status` es NULL, que representa la creación), exige un `reason` no vacío cuando la política marca `requires_reason` para el estado destino (RN-A5), e inserta la fila de historial. El helper SHALL ser invocable solo desde funciones internas con privilegios elevados, NOT directamente por el rol `authenticated`.

#### Scenario: Transición inválida es rechazada
- **WHEN** un RPC intenta registrar una transición que no existe en el catálogo
- **THEN** el helper aborta la operación con un error de conflicto y la transacción no se confirma

#### Scenario: Motivo obligatorio ausente es rechazado
- **WHEN** se registra una transición cuyo estado destino tiene `requires_reason = true` y el `reason` provisto es nulo o vacío
- **THEN** el helper aborta la operación con un error de payload inválido

#### Scenario: Transición válida con motivo cuando se requiere
- **WHEN** se registra una transición cuyo destino requiere motivo y se provee un `reason` no vacío
- **THEN** el helper inserta la fila de historial con ese `reason`

### Requirement: Dimensión de rol estructurada para RBAC futuro

El catálogo `document_status_transitions` SHALL incluir una columna `allowed_role` que en este alcance queda permisiva (`NULL` = cualquier rol). El sistema NOT SHALL validar el rol del actor contra `allowed_role` en este change; la estructura SHALL quedar lista para que un change posterior (`v3-rbac-multirole`) pueble `allowed_role` y active el enforcement por rol (RN-A4) sin una migración disruptiva.

#### Scenario: allowed_role permisivo no bloquea transiciones
- **WHEN** se registra una transición cuya fila de catálogo tiene `allowed_role = NULL`
- **THEN** la transición se acepta sin verificar el rol del actor

#### Scenario: La estructura admite poblar allowed_role sin cambiar el esquema
- **WHEN** un change posterior asigna un rol concreto a una transición
- **THEN** basta un `UPDATE` de datos sobre `document_status_transitions` (sin `ALTER TABLE`) para restringir esa transición a ese rol

### Requirement: Seed del catálogo refleja las máquinas de estado vigentes

El sistema SHALL sembrar el catálogo con las transiciones que las tablas de documentos permiten actualmente: Quote (`draft→sent`, `draft|sent→accepted`, `draft|sent→expired`, `draft|sent→rejected`), SalesOrder (`draft→confirmed`), FiscalDocument (`pending_cae→authorized`, `pending_cae→rejected`), CashSession (`open→closed`), ReconciliationSession (`open→closed`), StockTransfer (terminal en `completed`), más la fila de creación (`from_status = NULL`) de cada tipo. El sistema NOT SHALL sembrar transiciones que ninguna operación vigente ejecuta.

#### Scenario: El seed cubre las transiciones ejecutadas por los RPCs actuales
- **WHEN** cualquier RPC de transición vigente registra su cambio de estado
- **THEN** la transición correspondiente existe en el catálogo y el registro tiene éxito

#### Scenario: Transiciones sin operación no se siembran
- **WHEN** una transición está definida en el CHECK de una tabla pero ningún RPC la ejecuta (por ejemplo `sales_order → canceled`)
- **THEN** esa transición no está en el seed inicial y se agregará cuando exista la operación que la aplique
