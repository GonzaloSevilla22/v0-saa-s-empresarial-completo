# bank-account Specification

## Purpose
Cuenta bancaria a nivel organización (`BankAccount`): registro, edición, soft-deactivate y aislamiento RLS por tenencia directa (`account_id`). Entregado en `bank-account-ledger` (V2.5 #3, BankReconciliation C1/3, 2026-06-27). Capa HTTP/UI (endpoint `POST /bank-accounts`, formulario de alta desde conciliación y etiqueta de navegación "Bancos") agregada en `bank-account-crud`.
## Requirements
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

### Requirement: Alta de cuenta bancaria vía endpoint HTTP (POST /bank-accounts)

El sistema SHALL exponer un endpoint `POST /bank-accounts` en el backend FastAPI, implementado en 3 capas (router → service → repository), que cree una cuenta bancaria invocando la RPC `rpc_create_bank_account`. El repository SHALL usar JWT-passthrough (sin `service_role`) para que la RLS org-based permanezca activa y la RPC resuelva `account_id` vía `current_account_ids()`. El service SHALL aplicar el guard de rol (`require_role`) antes de tocar la base de datos; el router SHALL contener únicamente validación y dependency injection. El request SHALL validarse con un schema Pydantic v2 `BankAccountCreate` antes de invocar la RPC, y la respuesta SHALL devolver la fila creada con el shape de `BankAccountOut`.

#### Scenario: Crear una cuenta bancaria vía POST

- **WHEN** un usuario con permiso de escritura hace `POST /bank-accounts` con `{ "name": "Cuenta corriente Galicia", "bank_name": "Banco Galicia", "cbu": "<22 dígitos>", "opening_balance": 10000 }`
- **THEN** el endpoint invoca `rpc_create_bank_account`, se inserta la fila en `bank_accounts` con `account_id` de la organización del usuario, `is_active = true` y `currency = 'ARS'`, y responde con la cuenta creada

#### Scenario: Un usuario sin permiso de escritura recibe 403

- **WHEN** un usuario con rol de solo lectura hace `POST /bank-accounts`
- **THEN** la RPC retorna `P0401` y el endpoint responde con HTTP 403 sin insertar ninguna fila

#### Scenario: name vacío es rechazado antes o en la RPC

- **WHEN** se hace `POST /bank-accounts` con `name` vacío o solo espacios
- **THEN** la operación es rechazada (validación Pydantic o `P0400` de la RPC) con HTTP 422 y no se inserta ninguna fila

### Requirement: Validación de formato de CBU en el endpoint POST

El sistema SHALL validar en el endpoint `POST /bank-accounts` que, cuando se provee, el `cbu` sea exactamente 22 dígitos numéricos (`^[0-9]{22}$`) mediante el schema Pydantic v2, y SHALL además mapear el `P0411` que la RPC retorna cuando el CBU es inválido a una respuesta HTTP 422. El `cbu` SHALL poder omitirse (cuenta sin CBU).

#### Scenario: CBU con cantidad de dígitos incorrecta retorna 422

- **WHEN** se hace `POST /bank-accounts` con `cbu = "12345"` (no 22 dígitos)
- **THEN** el endpoint responde con HTTP 422 (validación Pydantic o `P0411` mapeado) y no se inserta ninguna fila

#### Scenario: POST sin CBU crea la cuenta

- **WHEN** se hace `POST /bank-accounts` con `name` válido y sin campo `cbu`
- **THEN** la cuenta se crea correctamente con `cbu = NULL`

### Requirement: Alta de cuenta bancaria desde la pantalla de conciliación

El sistema SHALL permitir crear una cuenta bancaria desde la pantalla de conciliación (`/finanzas/conciliacion`) mediante un formulario (React Hook Form + Zod) presentado en un diálogo. El formulario SHALL ser accesible tanto desde el estado vacío (cuando no hay cuentas activas, con un botón primario "Nueva cuenta bancaria") como desde el encabezado de la tarjeta de selección de cuenta cuando ya existen cuentas (botón secundario). Al crear exitosamente una cuenta, el sistema SHALL invalidar las queries de cuentas bancarias (`queryKeys.bankAccounts`) para que la nueva cuenta aparezca en el selector sin recargar la página.

#### Scenario: Crear la primera cuenta desde el estado vacío

- **WHEN** un usuario abre `/finanzas/conciliacion` sin cuentas bancarias activas y hace clic en "Nueva cuenta bancaria", completa el formulario con un `name` válido y confirma
- **THEN** se envía `POST /bank-accounts`, la query de cuentas bancarias se invalida, y la nueva cuenta queda disponible en el selector de cuenta a conciliar

#### Scenario: Agregar otra cuenta desde el encabezado de la tarjeta

- **WHEN** un usuario con al menos una cuenta bancaria activa hace clic en el botón de nueva cuenta ubicado en el encabezado de la tarjeta de selección
- **THEN** se abre el mismo formulario en diálogo y, al confirmar, la nueva cuenta se agrega al selector

#### Scenario: El formulario valida el CBU antes de enviar

- **WHEN** el usuario ingresa un `cbu` que no tiene 22 dígitos numéricos
- **THEN** el formulario muestra un error de validación (Zod) y no envía la petición

### Requirement: Etiqueta de navegación "Bancos"

El sistema SHALL mostrar el ítem de navegación que enlaza a `/finanzas/conciliacion` con la etiqueta "Bancos" en la barra lateral. El título interno de la página (`<h1>`) PUEDE seguir siendo "Conciliación bancaria".

#### Scenario: El sidebar muestra "Bancos"

- **WHEN** un usuario ve la barra lateral del panel
- **THEN** el ítem que enlaza a `/finanzas/conciliacion` se muestra con el texto "Bancos" (no "Conciliación bancaria")
