## ADDED Requirements

### Requirement: Cuenta bancaria (BankAccount) a nivel organización
El sistema SHALL permitir registrar una o más cuentas bancarias (`BankAccount`) por organización, cada una con `name`, `bank_name`, `cbu` (opcional), `alias` (alias CBU, opcional), `currency` (default `'ARS'`), `opening_balance` (default `0`), `opening_date` (opcional) e `is_active` (default `true`). El aislamiento por cuenta (RLS) SHALL resolverse por tenencia **directa** vía `bank_accounts.account_id → accounts(id)` — NO scoped a sucursal (a diferencia de `cashboxes`), porque el banco pertenece a la organización, no a una sucursal. La RLS de SELECT SHALL ser `account_id IN (SELECT current_account_ids())`.

#### Scenario: Crear una cuenta bancaria
- **WHEN** un usuario con permiso de escritura (`owner`/`admin`) llama a `rpc_create_bank_account` con `name = "Cuenta corriente Galicia"`, `bank_name = "Banco Galicia"`, `cbu` de 22 dígitos y `opening_balance = 10000`
- **THEN** se inserta una fila en `bank_accounts` con `account_id` de la cuenta del usuario, `is_active = true`, `currency = 'ARS'`, visible solo para miembros de esa organización

#### Scenario: Un usuario de otra organización no ve la cuenta bancaria
- **WHEN** un miembro de la organización B consulta `bank_accounts` y existe una cuenta bancaria de la organización A
- **THEN** la RLS (`account_id IN (SELECT current_account_ids())`) no devuelve la fila de A

### Requirement: Solo escritores autorizados crean o editan cuentas bancarias
El sistema SHALL restringir la creación (`rpc_create_bank_account`) y edición (`rpc_update_bank_account`) de cuentas bancarias a usuarios con permiso de escritura (`is_account_writer`), retornando `P0401` en caso contrario. La escritura SHALL ocurrir ÚNICAMENTE vía estas RPCs SECURITY DEFINER; no SHALL existir política RLS de INSERT/UPDATE/DELETE directa sobre `bank_accounts`.

#### Scenario: Un usuario sin permiso de escritura no puede crear una cuenta bancaria
- **WHEN** un usuario con rol de solo lectura (`member`) llama a `rpc_create_bank_account`
- **THEN** la RPC retorna `P0401` y no inserta ninguna fila

#### Scenario: INSERT directo de authenticated es bloqueado
- **WHEN** el rol `authenticated` intenta `INSERT INTO bank_accounts` directamente (sin pasar por la RPC)
- **THEN** la operación es rechazada por RLS (no existe policy de escritura directa)

### Requirement: Validación de formato de CBU
El sistema SHALL validar que, cuando se provee, el `cbu` sea exactamente 22 dígitos numéricos (`^[0-9]{22}$`), retornando `P0411` desde la RPC si el formato es inválido, y reforzado por un `CHECK` a nivel tabla (`cbu IS NULL OR cbu ~ '^[0-9]{22}$'`). El `cbu` SHALL poder ser `NULL` (cuenta registrada sin CBU). La validación del dígito verificador del CBU está fuera de alcance de este change.

#### Scenario: CBU con cantidad de dígitos incorrecta es rechazado
- **WHEN** un usuario con permiso llama a `rpc_create_bank_account` con `cbu = "12345"` (no 22 dígitos)
- **THEN** la RPC retorna `P0411` y no inserta ninguna fila

#### Scenario: Cuenta bancaria sin CBU es válida
- **WHEN** un usuario con permiso crea una cuenta bancaria con `cbu = NULL`
- **THEN** la cuenta se crea correctamente

### Requirement: Activar/desactivar una cuenta bancaria
El sistema SHALL permitir editar `name`, `bank_name`, `alias` e `is_active` de una cuenta bancaria vía `rpc_update_bank_account`, guardado por `is_account_writer`. Desactivar (`is_active = false`) SHALL ser un soft-deactivate (la cuenta y sus movimientos permanecen, pero no se pueden registrar nuevos movimientos sobre una cuenta inactiva).

#### Scenario: Desactivar una cuenta bancaria
- **WHEN** un usuario con permiso llama a `rpc_update_bank_account` con `is_active = false` sobre una cuenta existente
- **THEN** la fila se actualiza con `is_active = false` y la cuenta deja de aceptar nuevos movimientos
