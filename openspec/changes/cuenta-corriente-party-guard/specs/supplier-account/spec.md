## ADDED Requirements

### Requirement: La cuenta corriente de un proveedor solo existe dentro del tenant del proveedor

El sistema SHALL rechazar toda operación que resuelva, cree o mueva una `SupplierAccount` cuyo `supplier_id` no pertenezca al `account_id` de la operación, **antes** de insertar o modificar cualquier fila. Espejo exacto del guard del lado cliente: la validación SHALL vivir en el punto de resolución/creación de la cuenta corriente, de modo que cubra por igual el pago manual, el cargo manual y el cargo automático de una compra a crédito, presentes y futuros.

El rechazo SHALL usar el código de error de negocio `P0404`, el mismo del camino explícito de creación de cuenta corriente de proveedor, con un mensaje que nombre el proveedor rechazado. La transacción SHALL revertirse entera: no SHALL quedar fila en `supplier_accounts`, ni movimiento en `supplier_account_movements`, ni pago en `payments_made`, ni evento en el outbox, ni consumo de la clave de idempotencia.

#### Scenario: Pago a un proveedor de otro tenant

- **GIVEN** un usuario con permiso de escritura en el tenant A
- **AND** un proveedor que pertenece al tenant B
- **WHEN** registra un pago de 8000 informando el identificador de ese proveedor ajeno
- **THEN** la operación falla con `P0404`
- **AND** no queda ninguna fila nueva en `supplier_accounts`, `supplier_account_movements` ni `payments_made`
- **AND** no se emite ningún evento de pago

#### Scenario: Cargo manual contra un proveedor de otro tenant

- **WHEN** se registra un cargo manual de 8000 contra un proveedor ajeno
- **THEN** la operación falla con `P0404` y no se crea ni la cuenta corriente ni el movimiento ni el evento de cargo

#### Scenario: El proveedor propio sigue funcionando igual

- **GIVEN** un proveedor del mismo tenant, sin cuenta corriente previa
- **WHEN** se registra un cargo manual de 8000
- **THEN** la cuenta corriente se crea en el mismo commit, el movimiento queda con `balance_after = 8000` y el evento de cargo se emite, exactamente como antes del guard

#### Scenario: Las validaciones de payload preceden al guard de parte

- **GIVEN** un pago o un cargo manual cuyo proveedor pertenece a otro tenant
- **WHEN** la misma operación además informa un importe inválido, o una cuenta bancaria que no existe
- **THEN** el error que llega al usuario es el de la validación de payload, no el de parte no encontrada

> Espejo exacto del lado cliente: el guard de parte va después del resto de
> las validaciones de payload y antes de consumir la clave de idempotencia.
> El orden es observable, así que se especifica.

#### Scenario: Un proveedor inexistente se rechaza igual que uno ajeno

- **WHEN** se registra un pago informando un identificador de proveedor que no existe en ninguna cuenta
- **THEN** la operación falla con `P0404` y el mensaje no revela si el identificador existe en otro tenant

#### Scenario: El rechazo llega al usuario como "no encontrado"

- **WHEN** el guard rechaza la operación
- **THEN** la API responde `404` con el cuerpo de error estándar de la plataforma, y no un error genérico de servidor

## MODIFIED Requirements

### Requirement: Agregado SupplierAccount con saldo materializado
El sistema SHALL proveer un agregado `SupplierAccount` (tabla `supplier_accounts`) con `id`, `account_id` (tenancy, FK→`accounts`), `supplier_id` (FK→`suppliers`), `balance numeric(15,2) NOT NULL DEFAULT 0` (saldo materializado: lo que se le debe al proveedor), `created_by`, `created_at`. SHALL existir a lo sumo **una** `SupplierAccount` por `(account_id, supplier_id)` (UNIQUE). Toda la escritura del agregado SHALL ocurrir vía RPC `SECURITY DEFINER`; la RLS de lectura SHALL ser `account_id IN (SELECT public.current_account_ids())`.

El par `(account_id, supplier_id)` SHALL ser **coherente**: el `supplier_id` SHALL pertenecer al `account_id` de la propia fila. La clave foránea a `suppliers` no expresa esa restricción por sí sola, así que la coherencia SHALL garantizarse en la resolución/creación de la cuenta corriente, que es el único camino de escritura del agregado. Una `SupplierAccount` cuyo proveedor pertenece a otro tenant SHALL considerarse un defecto de datos, no una configuración válida.

#### Scenario: crear cuenta corriente de un proveedor
- **WHEN** se crea una `SupplierAccount` para un proveedor de la cuenta
- **THEN** existe una fila en `supplier_accounts` con `balance = 0` y `(account_id, supplier_id)` único

#### Scenario: una sola cuenta por proveedor
- **WHEN** se intenta crear una segunda `SupplierAccount` para el mismo `(account_id, supplier_id)`
- **THEN** la operación es idempotente y devuelve la cuenta existente

#### Scenario: RLS por cuenta en lectura
- **WHEN** un usuario consulta `supplier_accounts`
- **THEN** solo ve las cuentas cuyo `account_id` pertenece a su cuenta

#### Scenario: no existe cuenta corriente con proveedor de otro tenant
- **WHEN** se recorre `supplier_accounts` uniendo cada fila con su proveedor
- **THEN** no existe ninguna fila cuyo `suppliers.account_id` difiera del `supplier_accounts.account_id`
