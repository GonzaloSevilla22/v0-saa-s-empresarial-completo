## ADDED Requirements

### Requirement: Un cliente puede tener múltiples direcciones operativas

El sistema SHALL permitir asociar cero o más direcciones operativas a un cliente, cada una con un `alias`, campos de dirección editables y su propio ciclo de vida. Estas direcciones son operativas/editables y SHALL ser distintas de la dirección **fiscal**, que vive en la identidad fiscal del cliente y es inmutable por snapshot en los documentos.

#### Scenario: Alta de una dirección operativa

- **WHEN** un usuario con rol de escritura crea una dirección para un cliente vivo de su cuenta con un `alias` y los campos de dirección
- **THEN** el sistema persiste la dirección asociada a ese cliente y la retorna con su `id`

#### Scenario: Listado de las direcciones de un cliente

- **WHEN** un usuario lista las direcciones de un cliente de su cuenta
- **THEN** el sistema retorna solo las direcciones vivas (no borradas) de ese cliente

#### Scenario: Las direcciones operativas no alteran la dirección fiscal

- **WHEN** se crean o editan direcciones operativas de un cliente
- **THEN** la identidad fiscal del cliente y los snapshots fiscales de sus documentos no cambian

### Requirement: Exactamente una dirección primaria por cliente

El sistema SHALL garantizar que un cliente tenga **como máximo una** dirección primaria viva en todo momento, y SHALL marcar la primera dirección de un cliente como primaria automáticamente. La invariante a nivel de datos SHALL estar respaldada por un índice único parcial sobre `(client_id)` limitado a `is_primary AND deleted_at IS NULL`.

#### Scenario: La primera dirección se vuelve primaria

- **WHEN** se crea la primera dirección viva de un cliente
- **THEN** esa dirección queda marcada como primaria (`is_primary = true`)

#### Scenario: No pueden coexistir dos primarias vivas

- **WHEN** se intenta marcar como primaria una segunda dirección mediante un INSERT/UPDATE directo sin bajar la anterior
- **THEN** el índice único parcial rechaza la operación (violación de unicidad)

#### Scenario: Cambio atómico de la dirección primaria

- **WHEN** un usuario invoca el cambio de primaria hacia otra dirección del mismo cliente
- **THEN** el sistema baja `is_primary` de la primaria vigente y sube la nueva en una sola transacción, quedando exactamente una primaria

#### Scenario: Cambiar primaria a una dirección de otro cliente es rechazado

- **WHEN** se invoca el cambio de primaria con un `address_id` que no pertenece al `client_id` indicado o a la cuenta del usuario
- **THEN** el sistema rechaza la operación sin modificar ninguna dirección

### Requirement: Aislamiento por cuenta (tenancy)

El sistema SHALL restringir toda lectura y escritura de direcciones a la cuenta del usuario, mediante RLS org-based sobre `account_id`: lectura para cualquier miembro de la cuenta (`account_id IN current_account_ids()`) y escritura solo para roles de escritura (`is_account_writer(account_id)`), replicando el patrón de la tabla `clients`.

#### Scenario: Un usuario no ve direcciones de otra cuenta

- **WHEN** un usuario lista o accede a direcciones cuyo `account_id` no está entre las cuentas del usuario
- **THEN** el sistema no retorna ninguna de esas filas

#### Scenario: Un lector sin permiso de escritura no puede mutar direcciones

- **WHEN** un usuario sin rol de escritura intenta crear, editar o borrar una dirección
- **THEN** la operación es rechazada por RLS o por el guard de rol del servicio

### Requirement: Borrado soft de direcciones y del cliente padre

El sistema SHALL borrar direcciones de forma **soft** (`deleted_at` + `deleted_by`), excluyéndolas de las lecturas por defecto, alineado con la política de soft delete de maestros (V3 §4). El soft delete de un cliente padre NO SHALL propagarse en cascada dura a sus direcciones; las direcciones de un cliente borrado quedan inalcanzables porque las lecturas parten del cliente vivo, y vuelven a ser alcanzables si el cliente se reactiva.

#### Scenario: Borrado soft de una dirección

- **WHEN** un usuario con permiso borra una dirección
- **THEN** la fila persiste con `deleted_at` y `deleted_by`, y deja de aparecer en los listados por defecto

#### Scenario: El cliente borrado oculta sus direcciones sin borrarlas

- **WHEN** un cliente se soft-deletea
- **THEN** sus direcciones no reciben `deleted_at` pero quedan inalcanzables por las lecturas (que exigen un cliente vivo), y siguen disponibles si el cliente se reactiva
