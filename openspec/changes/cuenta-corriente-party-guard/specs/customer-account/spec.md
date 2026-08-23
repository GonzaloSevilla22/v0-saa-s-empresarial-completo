## ADDED Requirements

### Requirement: La cuenta corriente de un cliente solo existe dentro del tenant del cliente

El sistema SHALL rechazar toda operación que resuelva, cree o mueva una `CustomerAccount` cuyo `client_id` no pertenezca al `account_id` de la operación, **antes** de insertar o modificar cualquier fila. La validación SHALL vivir en el punto de resolución/creación de la cuenta corriente —el lugar por donde pasan todos los caminos— y no únicamente en cada comando que la invoca, de modo que un camino de alta nuevo nazca cubierto sin acordarse de replicar el guard.

El rechazo SHALL usar el código de error de negocio `P0404`, el mismo que ya usa el camino explícito de creación de cuenta corriente, con un mensaje que nombre el cliente rechazado. La transacción SHALL revertirse entera: no SHALL quedar fila en `customer_accounts`, ni movimiento en `customer_account_movements`, ni cobro en `payments_received`, ni evento en el outbox, ni consumo de la clave de idempotencia.

El motivo no es la fuga de datos —la cuenta corriente del otro tenant queda intacta, porque la fila creada es una fila distinta bajo el `account_id` del atacante— sino la **corrupción del libro propio**: un saldo, sus movimientos y su asiento contable contra una entidad que el tenant nunca va a ver en sus listas de clientes, porque esas sí filtran por cuenta. Un saldo huérfano, imposible de conciliar desde la aplicación.

#### Scenario: Cobro contra un cliente de otro tenant

- **GIVEN** un usuario con permiso de escritura en el tenant A
- **AND** un cliente que pertenece al tenant B
- **WHEN** registra un cobro de 5000 informando el identificador de ese cliente ajeno
- **THEN** la operación falla con `P0404`
- **AND** no queda ninguna fila nueva en `customer_accounts`, `customer_account_movements` ni `payments_received`
- **AND** no se emite ningún evento de cobro

#### Scenario: La clave de idempotencia no se quema en el rechazo

- **GIVEN** un cobro rechazado por cliente ajeno con una clave de idempotencia determinada
- **WHEN** se reintenta la misma clave de idempotencia con un cliente válido del tenant
- **THEN** el cobro se registra normalmente, sin ser tratado como un reintento de la operación fallida

#### Scenario: El cliente propio sigue funcionando igual

- **GIVEN** un cliente del mismo tenant, sin cuenta corriente previa
- **WHEN** se registra una venta a cuenta corriente de 1000 para ese cliente
- **AND** después se registra un cobro de 400
- **THEN** la cuenta corriente se crea en el mismo commit del cargo, con su movimiento y su evento
- **AND** el cobro se registra con su movimiento, su fila de cobro y su evento, dejando el saldo en 600, exactamente como antes del guard

> El cobro no puede ser el primer movimiento de la cuenta: el invariante de
> saldo no negativo lo rechaza con `P0409` antes de llegar a nada de esto. El
> control positivo del camino propio es, necesariamente, cargo y después cobro.

#### Scenario: Las validaciones de payload preceden al guard de parte

- **GIVEN** un cobro cuyo cliente pertenece a otro tenant
- **WHEN** el mismo cobro además informa un importe inválido, o una cuenta bancaria que no existe
- **THEN** el error que llega al usuario es el de la validación de payload —importe inválido o cuenta bancaria no encontrada—, no el de parte no encontrada

> El guard de parte se ubica junto a las demás validaciones de payload y
> **después** de ellas, y **antes** de consumir la clave de idempotencia. El
> orden es observable —determina qué error ve el usuario cuando hay más de un
> problema— así que se especifica en vez de quedar sólo congelado por los
> tests. La regla general: primero se rechaza lo que está mal escrito en el
> pedido, después lo que no pertenece al tenant.

#### Scenario: Un cliente inexistente se rechaza igual que uno ajeno

- **WHEN** se registra un cobro informando un identificador de cliente que no existe en ninguna cuenta
- **THEN** la operación falla con `P0404` y el mensaje no revela si el identificador existe en otro tenant

#### Scenario: El rechazo llega al usuario como "no encontrado"

- **WHEN** el guard rechaza la operación
- **THEN** la API responde `404` con el cuerpo de error estándar de la plataforma, y no un error genérico de servidor

### Requirement: La venta a cuenta corriente exige que el cliente sea del tenant

El sistema SHALL aplicar la misma coherencia de tenencia al cargo automático que produce una venta imputada a una forma de pago de `kind = 'credit'`, por cualquiera de sus caminos —mostrador y formulario de venta—, y no solo al cobro manual. Una venta a crédito con un cliente ajeno SHALL fallar entera: sin venta registrada, sin cargo en la cuenta corriente, sin movimiento de stock y sin evento.

#### Scenario: Venta a crédito desde el formulario con cliente ajeno

- **GIVEN** un usuario del tenant A y un cliente del tenant B
- **WHEN** registra desde el formulario una venta a crédito de 12000 para ese cliente
- **THEN** la operación falla con `P0404`
- **AND** no queda fila en `sales`, ni movimiento en `customer_account_movements`, ni evento en el outbox

#### Scenario: Venta a crédito desde el mostrador con cliente ajeno

- **WHEN** el mismo caso se intenta desde el punto de venta
- **THEN** la operación falla con `P0404` y la orden de venta no queda confirmada

#### Scenario: Venta a crédito con cliente propio no cambia de comportamiento

- **WHEN** se registra una venta a crédito de 12000 para un cliente del propio tenant
- **THEN** el cargo se postea igual que antes: movimiento positivo por el total, cuenta corriente creada si no existía, y evento de cargo emitido

## MODIFIED Requirements

### Requirement: Agregado CustomerAccount con saldo materializado
El sistema SHALL proveer un agregado `CustomerAccount` (tabla `customer_accounts`) con `id`, `account_id` (tenancy, FK→`accounts`), `client_id` (FK→`clients`), `balance numeric(15,2) NOT NULL DEFAULT 0` (saldo materializado), `created_by`, `created_at`. SHALL existir a lo sumo **una** `CustomerAccount` por `(account_id, client_id)` (UNIQUE). Toda la escritura del agregado SHALL ocurrir vía RPC `SECURITY DEFINER` (sin INSERT/UPDATE directo del rol `authenticated`); la RLS de lectura SHALL ser `account_id IN (SELECT public.current_account_ids())`.

El par `(account_id, client_id)` SHALL ser **coherente**: el `client_id` SHALL pertenecer al `account_id` de la propia fila. La clave foránea a `clients` no expresa esa restricción por sí sola —referencia el cliente sin exigir que sea del mismo tenant—, así que la coherencia SHALL garantizarse en la resolución/creación de la cuenta corriente, que es el único camino de escritura del agregado. Una `CustomerAccount` cuyo cliente pertenece a otro tenant SHALL considerarse un defecto de datos, no una configuración válida.

#### Scenario: crear cuenta corriente de un cliente
- **WHEN** se crea una `CustomerAccount` para un cliente de la cuenta
- **THEN** existe una fila en `customer_accounts` con `balance = 0` y `(account_id, client_id)` único

#### Scenario: una sola cuenta por cliente
- **WHEN** se intenta crear una segunda `CustomerAccount` para el mismo `(account_id, client_id)`
- **THEN** la operación es idempotente (no crea una segunda fila) y devuelve la cuenta existente

#### Scenario: RLS por cuenta en lectura
- **WHEN** un usuario consulta `customer_accounts`
- **THEN** solo ve las cuentas cuyo `account_id` pertenece a su cuenta

#### Scenario: no existe cuenta corriente con cliente de otro tenant
- **WHEN** se recorre `customer_accounts` uniendo cada fila con su cliente
- **THEN** no existe ninguna fila cuyo `clients.account_id` difiera del `customer_accounts.account_id`
