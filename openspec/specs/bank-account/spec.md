# bank-account Specification

## Purpose
Cuenta bancaria a nivel organización (`BankAccount`): registro, edición, soft-deactivate y aislamiento RLS por tenencia directa (`account_id`). Entregado en `bank-account-ledger` (V2.5 #3, BankReconciliation C1/3, 2026-06-27). Capa HTTP/UI (endpoint `POST /bank-accounts`, formulario de alta desde conciliación y etiqueta de navegación "Bancos") agregada en `bank-account-crud`.
## Requirements
### Requirement: Cuenta bancaria (BankAccount) a nivel organización
El sistema SHALL permitir registrar una o más cuentas bancarias (`BankAccount`) por organización, cada una con `name`, `account_kind` (`'bank' | 'wallet'`, default `'bank'`), `bank_name`, `cbu` (opcional), `alias` (alias CBU/CVU, opcional), `currency` (default `'ARS'`), `opening_balance` (default `0`), `opening_date` (opcional) e `is_active` (default `true`). El aislamiento por cuenta (RLS) SHALL resolverse por tenencia **directa** vía `bank_accounts.account_id → accounts(id)` — NO scoped a sucursal (a diferencia de `cashboxes`), porque el banco pertenece a la organización, no a una sucursal. La RLS de SELECT SHALL ser `account_id IN (SELECT current_account_ids())`.

#### Scenario: Crear una cuenta bancaria
- **WHEN** un usuario con permiso de escritura (`owner`/`admin`) llama a `rpc_create_bank_account` con `name = "Cuenta corriente Galicia"`, `bank_name = "Banco Galicia"`, `cbu` de 22 dígitos y `opening_balance = 10000`
- **THEN** se inserta una fila en `bank_accounts` con `account_id` de la cuenta del usuario, `account_kind = 'bank'`, `is_active = true`, `currency = 'ARS'`, visible solo para miembros de esa organización

#### Scenario: Crear una billetera virtual
- **WHEN** un usuario con permiso de escritura llama a `rpc_create_bank_account` con `name = "Mercado Pago"`, `account_kind = 'wallet'` y `alias = "luzmin.mp"`
- **THEN** se inserta una fila en `bank_accounts` con `account_kind = 'wallet'`, `is_active = true` y `cbu = NULL`

#### Scenario: Un usuario de otra organización no ve la cuenta bancaria
- **WHEN** un miembro de la organización B consulta `bank_accounts` y existe una cuenta bancaria de la organización A
- **THEN** la RLS (`account_id IN (SELECT current_account_ids())`) no devuelve la fila de A

### Requirement: Solo escritores autorizados crean o editan cuentas bancarias
El sistema SHALL restringir la creación (`rpc_create_bank_account`) y edición (`rpc_update_bank_account`) de cuentas bancarias a usuarios con permiso de escritura (`is_account_writer`), retornando `P0401` en caso contrario. La escritura SHALL ocurrir ÚNICAMENTE vía estas RPCs SECURITY DEFINER; no SHALL existir política RLS de INSERT/UPDATE/DELETE directa sobre `bank_accounts`. Cuando la firma de estas RPCs cambie, la migración SHALL hacer `DROP` explícito de la firma anterior antes del `CREATE` —evitando la ambigüedad de overload `42725`— y SHALL restituir los privilegios en el mismo archivo: `GRANT EXECUTE` a `authenticated` y `REVOKE` explícito de `PUBLIC` y `anon`, porque `DROP`+`CREATE` resetea las ACLs.

#### Scenario: Un usuario sin permiso de escritura no puede crear una cuenta bancaria
- **WHEN** un usuario con rol de solo lectura (`member`) llama a `rpc_create_bank_account`
- **THEN** la RPC retorna `P0401` y no inserta ninguna fila

#### Scenario: INSERT directo de authenticated es bloqueado
- **WHEN** el rol `authenticated` intenta `INSERT INTO bank_accounts` directamente (sin pasar por la RPC)
- **THEN** la operación es rechazada por RLS (no existe policy de escritura directa)

#### Scenario: El cambio de firma no deja privilegios abiertos

- **WHEN** una migración reemplaza la firma de `rpc_create_bank_account` con `DROP` seguido de `CREATE`
- **THEN** al terminar la migración la función tiene `EXECUTE` para `authenticated` y no lo tiene para `PUBLIC` ni para `anon`

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

El sistema SHALL exponer un endpoint `POST /bank-accounts` en el backend FastAPI, implementado en 3 capas (router → service → repository), que cree una cuenta bancaria invocando la RPC `rpc_create_bank_account`. El request SHALL aceptar un campo opcional `account_kind` de dominio cerrado `'bank' | 'wallet'` con default `'bank'`, validado por el schema Pydantic v2 antes de tocar la base de datos y rechazado con HTTP 422 cuando está fuera del dominio; la RPC SHALL ser la autoridad final y su ERRCODE de tipo inválido SHALL mapearse también a HTTP 422. El repository SHALL usar JWT-passthrough (sin `service_role`) para que la RLS org-based permanezca activa y la RPC resuelva `account_id` vía `current_account_ids()`. El service SHALL aplicar el guard de rol (`require_role`) antes de tocar la base de datos; el router SHALL contener únicamente validación y dependency injection. La respuesta SHALL devolver la fila creada con el shape de `BankAccountOut`, incluyendo `account_kind`.

#### Scenario: Crear una cuenta bancaria vía POST

- **WHEN** un usuario con permiso de escritura hace `POST /bank-accounts` con `{ "name": "Cuenta corriente Galicia", "bank_name": "Banco Galicia", "cbu": "<22 dígitos>", "opening_balance": 10000 }`
- **THEN** el endpoint invoca `rpc_create_bank_account`, se inserta la fila en `bank_accounts` con `account_id` de la organización del usuario, `account_kind = 'bank'`, `is_active = true` y `currency = 'ARS'`, y responde con la cuenta creada

#### Scenario: Crear una billetera virtual vía POST

- **WHEN** un usuario con permiso de escritura hace `POST /bank-accounts` con `{ "name": "Ualá", "account_kind": "wallet", "alias": "mi.uala" }`
- **THEN** la fila se inserta con `account_kind = 'wallet'` y la respuesta incluye ese valor

#### Scenario: Un account_kind fuera del dominio retorna 422

- **WHEN** se hace `POST /bank-accounts` con `account_kind = "crypto"`
- **THEN** el endpoint responde con HTTP 422 (validación Pydantic o el ERRCODE de la RPC mapeado) y no se inserta ninguna fila

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

### Requirement: Alta de cuenta bancaria desde la pantalla de banco

El sistema SHALL permitir crear una cuenta bancaria desde la pantalla de banco (`/banco`, a la que la ruta previa `/finanzas/conciliacion` redirige) mediante un formulario (React Hook Form + Zod) presentado en un diálogo. El formulario SHALL ser accesible tanto desde el estado vacío (cuando no hay cuentas activas) como desde el encabezado de la tarjeta de selección de cuenta cuando ya existen cuentas, en ambos casos a través de las **dos entradas diferenciadas por tipo** ("+ Banco" y "+ Billetera virtual"). Al crear exitosamente una cuenta, el sistema SHALL invalidar las queries de cuentas bancarias (`queryKeys.bankAccounts`) para que la nueva cuenta aparezca en el selector sin recargar la página.

#### Scenario: Crear la primera cuenta desde el estado vacío

- **WHEN** un usuario abre `/banco` sin cuentas bancarias activas, elige una de las dos entradas de alta, completa el formulario con un `name` válido y confirma
- **THEN** se envía `POST /bank-accounts` con el `account_kind` correspondiente, la query de cuentas bancarias se invalida, y la nueva cuenta queda disponible en el selector

#### Scenario: Agregar otra cuenta desde el encabezado de la tarjeta

- **WHEN** un usuario con al menos una cuenta bancaria activa usa una de las entradas de alta ubicadas en el encabezado de la tarjeta de selección
- **THEN** se abre el mismo formulario en diálogo, parametrizado por el tipo elegido, y al confirmar la nueva cuenta se agrega al selector

#### Scenario: El formulario valida el CBU antes de enviar

- **WHEN** el usuario ingresa un `cbu` que no tiene 22 dígitos numéricos
- **THEN** el formulario muestra un error de validación (Zod) y no envía la petición

### Requirement: Etiqueta de navegación "Bancos"

El sistema SHALL mostrar el ítem de navegación que enlaza a `/finanzas/conciliacion` con la etiqueta "Bancos" en la barra lateral. El título interno de la página (`<h1>`) PUEDE seguir siendo "Conciliación bancaria".

#### Scenario: El sidebar muestra "Bancos"

- **WHEN** un usuario ve la barra lateral del panel
- **THEN** el ítem que enlaza a `/finanzas/conciliacion` se muestra con el texto "Bancos" (no "Conciliación bancaria")

### Requirement: Tipo de cuenta — banco o billetera virtual

El sistema SHALL clasificar cada cuenta bancaria con un atributo `account_kind` de dominio cerrado `'bank' | 'wallet'`, `NOT NULL` y con default `'bank'`, reforzado por un `CHECK` a nivel tabla (`account_kind IN ('bank','wallet')`). `'bank'` SHALL representar una cuenta en una entidad bancaria y `'wallet'` una billetera virtual (Mercado Pago, Ualá, Naranja X y equivalentes). El atributo SHALL ser **descriptivo**: no altera el tratamiento contable, los saldos, la conciliación ni el ruteo de asientos de ninguna cuenta, de modo que el `kind = 'wallet'` de `payment_methods` SHALL seguir imputando a `1110 Banco` sin cambios.

#### Scenario: El tipo persiste al crear una billetera virtual

- **WHEN** un usuario con permiso de escritura crea una cuenta con `account_kind = 'wallet'` y `name = "Mercado Pago"`
- **THEN** la fila queda persistida con `account_kind = 'wallet'` y el valor se devuelve en las lecturas posteriores de esa cuenta

#### Scenario: El default es banco cuando no se especifica el tipo

- **WHEN** se crea una cuenta bancaria sin indicar `account_kind`
- **THEN** la fila queda persistida con `account_kind = 'bank'`

#### Scenario: Un tipo fuera del dominio es rechazado

- **WHEN** se intenta persistir una cuenta con `account_kind = 'crypto'` (valor fuera del dominio cerrado)
- **THEN** la operación es rechazada por el `CHECK` de tabla y no se inserta ninguna fila

#### Scenario: El tratamiento contable no cambia según el tipo

- **WHEN** se registra un movimiento sobre una cuenta con `account_kind = 'wallet'` y otro equivalente sobre una con `account_kind = 'bank'`
- **THEN** ambos producen el mismo tratamiento contable y de saldo, porque `account_kind` no participa del ruteo de asientos

### Requirement: Clasificación inicial de las cuentas existentes

El sistema SHALL clasificar las cuentas ya existentes al aplicar la migración, mediante una heurística de nombre sobre `name` y `bank_name`, insensible a mayúsculas, contra una lista cerrada y documentada de marcas de billetera virtual: Mercado Pago (incluida la sigla `MP` como token completo), Ualá, Naranja X, Personal Pay, Brubank, Lemon, Belo, Prex, Cuenta DNI, MODO y BNA+. Las coincidencias SHALL marcarse `account_kind = 'wallet'`; **toda cuenta que no coincida SHALL permanecer en `'bank'`**, que es el default seguro. La heurística SHALL usar coincidencia por token completo para las siglas y palabras cortas ambiguas (`MP`, `MODO`, `Belo`, `Prex`, `Lemon`), de modo que un nombre de banco que las contenga como subcadena —por ejemplo "Banco Comodoro", que contiene `modo`— no sea clasificado como billetera. La migración SHALL ser idempotente: reaplicarla no SHALL alterar clasificaciones ya corregidas manualmente.

#### Scenario: Las billeteras de la cuenta real quedan clasificadas

- **WHEN** se aplica la migración sobre las cuentas existentes en producción (`MP`, `Mercado Pago`, `Naranja X`, `UALA`, más los duplicados de Mercado Pago ya soft-deleted)
- **THEN** todas quedan con `account_kind = 'wallet'`, incluidas las que tienen `deleted_at` no nulo

#### Scenario: Una sigla contenida en el nombre de un banco no lo convierte en billetera

- **WHEN** existe una cuenta llamada "Banco Comodoro" al aplicar la migración
- **THEN** conserva `account_kind = 'bank'`, porque `modo` solo coincide como token completo y no como subcadena

#### Scenario: Una cuenta ambigua permanece como banco

- **WHEN** existe una cuenta cuyo nombre no coincide con ninguna marca de la lista cerrada
- **THEN** conserva `account_kind = 'bank'` y no se infiere ningún otro tipo

#### Scenario: Reaplicar la migración no pisa una clasificación existente

- **WHEN** la migración se reaplica sobre una base donde ya existe la columna y las cuentas ya fueron clasificadas
- **THEN** la operación completa sin error y ninguna clasificación previa se sobrescribe

### Requirement: Alta diferenciada de banco y de billetera virtual en `/banco`

El sistema SHALL ofrecer en `/banco` **dos entradas de alta distintas** — "+ Banco" y "+ Billetera virtual" — tanto en el estado vacío (sin cuentas activas) como en el encabezado de la tarjeta de selección de cuenta. Ambas entradas SHALL abrir **el mismo diálogo de formulario parametrizado por tipo**, no formularios separados, y el tipo elegido SHALL viajar en el alta y quedar persistido. El diálogo SHALL titularse según el tipo ("Nueva cuenta bancaria" / "Nueva billetera virtual"). No SHALL crearse rutas nuevas: la superficie es la misma pantalla `/banco`.

#### Scenario: Crear una billetera virtual desde el estado vacío

- **WHEN** un usuario sin cuentas activas hace clic en "+ Billetera virtual", completa el nombre y confirma
- **THEN** se crea la cuenta con `account_kind = 'wallet'`, la query de cuentas se invalida y la billetera aparece en el selector

#### Scenario: Crear un banco desde el encabezado de la tarjeta

- **WHEN** un usuario con al menos una cuenta activa hace clic en "+ Banco" en el encabezado y confirma el formulario
- **THEN** se crea la cuenta con `account_kind = 'bank'` y se agrega al selector

#### Scenario: Las dos entradas comparten el mismo formulario

- **WHEN** se abre el alta por "+ Banco" y luego por "+ Billetera virtual"
- **THEN** ambas montan el mismo componente de diálogo, que se comporta según el tipo recibido por parámetro

### Requirement: Etiquetas del formulario de alta según el tipo de cuenta

El sistema SHALL adaptar las **etiquetas** del formulario de alta al tipo de cuenta, sin agregar, quitar ni ocultar campos: cuando `account_kind = 'wallet'`, el campo `bank_name` SHALL rotularse "Billetera" y el campo `cbu` SHALL rotularse "CVU"; cuando `account_kind = 'bank'`, SHALL rotularse "Banco" y "CBU" respectivamente. La **validación de formato SHALL permanecer idéntica para ambos tipos** (`^[0-9]{22}$`), porque el CVU tiene la misma longitud de 22 dígitos que el CBU; en consecuencia el `CHECK` de tabla sobre `cbu` y el `P0411` de la RPC SHALL permanecer sin cambios. Los textos de ejemplo (placeholders) SHALL corresponder al tipo.

#### Scenario: El formulario de billetera pide CVU

- **WHEN** un usuario abre el alta por "+ Billetera virtual"
- **THEN** ve los rótulos "Billetera" y "CVU" en lugar de "Banco" y "CBU"

#### Scenario: El CVU se valida con la misma regla de 22 dígitos

- **WHEN** un usuario ingresa un CVU que no tiene 22 dígitos numéricos en el alta de una billetera
- **THEN** el formulario muestra el error de validación y no envía la petición, con la misma regla que aplica al CBU de un banco

#### Scenario: Una billetera sin CVU es válida

- **WHEN** un usuario crea una billetera virtual indicando solo el nombre y el alias, sin CVU
- **THEN** la cuenta se crea correctamente con `cbu = NULL`

### Requirement: Distinción visual del tipo de cuenta en las superficies de listado

El sistema SHALL distinguir visualmente banco y billetera virtual mediante ícono y etiqueta en **todas** las superficies que listan o identifican una cuenta bancaria: el selector de cuenta de `/banco`, el encabezado del historial de movimientos, la pestaña de conciliación, y los selectores de cuenta-default de los métodos de pago. La resolución de etiqueta, ícono y variante de badge por tipo SHALL vivir en **un único módulo canónico** del frontend, y ningún consumidor SHALL redefinir ese mapeo por su cuenta — en particular, el ícono de cuenta hoy fijo en la gestión de métodos de pago SHALL pasar a resolverse por tipo. La distinción SHALL verificarse en **desktop y mobile** y en **tema claro y oscuro**, con los tokens semánticos del design system y sin colores literales que evadan el gate de contraste AA vigente.

#### Scenario: El selector de cuenta distingue billetera de banco

- **WHEN** un usuario abre el selector de cuenta en `/banco` con una billetera y un banco cargados
- **THEN** cada opción muestra el ícono correspondiente a su tipo, permitiendo distinguirlas sin leer el nombre

#### Scenario: La gestión de métodos de pago muestra el tipo de la cuenta asociada

- **WHEN** un método de pago tiene asociada una cuenta-default que es una billetera virtual
- **THEN** la fila muestra el ícono de billetera en lugar del ícono de banco fijo

#### Scenario: El mapeo de tipo a presentación es único

- **WHEN** se agrega una superficie nueva que necesita mostrar el tipo de una cuenta
- **THEN** obtiene etiqueta, ícono y variante de badge del módulo canónico, sin redefinir el mapeo localmente

