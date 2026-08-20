# cash-session Specification

> Updated from `pos-catalogo-pagos` — 2026-08-20 (explicita qué camino alimenta el arqueo)

## Purpose
TBD - created by archiving change v21-cash-session. Update Purpose after archive.
## Requirements

### Requirement: Sólo el camino del mostrador alimenta el arqueo

El sistema SHALL alimentar `cash_movements` de tipo `sale` **exclusivamente** desde el camino del mostrador —`quickSale()` y la confirmación de una orden de venta con forma de pago de `kind = 'cash'`—, y NO SHALL generarlos desde el alta ni la edición de una venta hecha por el formulario de venta, aunque esa venta esté imputada a una forma de pago de `kind = 'cash'`. La asimetría es deliberada y SHALL declararse al usuario en la superficie que ofrece el selector: `expected_balance = opening_balance + Σ(cash_movements)` es la base del arqueo y su `difference` es una señal antifraude (RN-95), de modo que inyectar en una sesión abierta el importe de una venta que nadie depositó en el cajón convertiría toda diferencia en ruido. A esto se suma que el formulario admite fechas anteriores, para las cuales no existe una sesión de caja a la que atribuir el movimiento.

#### Scenario: Venta en efectivo desde el formulario no altera el arqueo

- **GIVEN** una sesión de caja abierta con `opening_balance = 5000` y sin movimientos
- **WHEN** se registra desde el formulario de venta una venta de 2000 imputada a una forma de pago de `kind = 'cash'`
- **AND** se cierra la sesión declarando `counted_balance = 5000`
- **THEN** `expected_balance = 5000` y `difference = 0`

#### Scenario: Venta en efectivo desde el POS sí altera el arqueo

- **GIVEN** una sesión de caja abierta con `opening_balance = 5000` y sin movimientos
- **WHEN** se cobra desde el POS una venta de 2000 con una forma de pago de `kind = 'cash'`
- **AND** se cierra la sesión declarando `counted_balance = 7000`
- **THEN** `expected_balance = 7000` y `difference = 0`

#### Scenario: La superficie declara qué camino mueve la caja

- **WHEN** el usuario elige en el formulario de venta una forma de pago de `kind = 'cash'`
- **THEN** la pantalla explica que el movimiento de caja lo genera la venta desde el POS, que exige una sesión abierta

#### Scenario: Una venta a cuenta corriente no toca la caja

- **GIVEN** una sesión de caja abierta
- **WHEN** se cobra desde el POS con una forma de pago de `kind = 'credit'`
- **THEN** no se crea ningún `cash_movements` y el arqueo de esa sesión no se ve afectado
### Requirement: Caja (Cashbox) por sucursal
El sistema SHALL permitir definir una o más cajas (`Cashbox`) por sucursal, cada una con `name` y `currency` (default `'ARS'`), perteneciente a una `Branch` activa. El aislamiento por cuenta (RLS) SHALL resolverse vía `cashboxes.branch_id → branches.account_id`, sin usar `company_id` ni `user_id`.

#### Scenario: Crear una caja en una sucursal
- **GIVEN** una cuenta con una sucursal `status = 'active'`
- **WHEN** un usuario `owner`/`admin` crea una caja con nombre "Caja 1"
- **THEN** se inserta una fila en `cashboxes` con `branch_id` de esa sucursal y `currency = 'ARS'`, visible solo para miembros de la cuenta dueña de la sucursal

#### Scenario: Un usuario de otra cuenta no ve la caja
- **GIVEN** una caja perteneciente a la cuenta A
- **WHEN** un miembro de la cuenta B consulta `cashboxes`
- **THEN** la RLS (vía `branch_id → branches.account_id`) no devuelve la fila

### Requirement: Apertura de sesión de caja
El sistema SHALL permitir abrir una `CashSession` sobre una caja vía `rpc_open_cash_session(p_cashbox_id, p_opening_balance)`, fijando `status = 'open'`, `opening_balance`, `opened_by` y `opened_at = now()`. El comando SHALL estar restringido a `owner`/`admin`/roles con permiso de escritura (`is_account_writer`).

#### Scenario: Abrir una sesión con saldo inicial
- **GIVEN** una caja sin sesión abierta en una sucursal `status = 'active'`
- **WHEN** un usuario con permiso llama a `rpc_open_cash_session(cashbox, 5000)`
- **THEN** se crea una `cash_session` con `status = 'open'`, `opening_balance = 5000`, `opened_at = now()` y `opened_by` = el usuario

#### Scenario: Member sin permiso de escritura no puede abrir
- **GIVEN** un usuario con rol `member` (lectura) en la cuenta
- **WHEN** llama a `rpc_open_cash_session`
- **THEN** la RPC retorna error `P0401` y no crea ninguna sesión

### Requirement: Una sola sesión abierta por caja (invariante de doble apertura)
El sistema SHALL impedir abrir una segunda `CashSession` mientras exista una con `status = 'open'` en la misma `Cashbox`, mediante un índice UNIQUE parcial (`cashbox_id` WHERE `status = 'open'`) y un guard en la RPC que retorna `P0409 cashbox_session_open`.

#### Scenario: Doble apertura en la misma caja es rechazada
- **GIVEN** una caja que ya tiene una `cash_session` con `status = 'open'`
- **WHEN** un usuario intenta abrir otra sesión en esa misma caja
- **THEN** la RPC retorna `P0409 cashbox_session_open` y no se crea una segunda sesión

#### Scenario: Reabrir es posible tras cerrar
- **GIVEN** una caja cuya última sesión está `status = 'closed'`
- **WHEN** un usuario abre una nueva sesión
- **THEN** la apertura tiene éxito (el índice parcial solo restringe sesiones `open`)

### Requirement: Cierre de sesión con arqueo
El sistema SHALL cerrar una `CashSession` vía `rpc_close_cash_session(p_session_id, p_counted_balance)`, calculando `expected_balance = opening_balance + Σ(cash_movements.amount)` de la sesión, registrando `counted_balance`, `difference = counted_balance - expected_balance`, `closing_balance = counted_balance`, `status = 'closed'`, `closed_by` y `closed_at = now()`. La diferencia SHALL persistirse aunque sea distinta de cero (señal antifraude, RN-95).

#### Scenario: Cierre con arqueo exacto
- **GIVEN** una sesión con `opening_balance = 5000` y movimientos que suman `+3000`
- **WHEN** el usuario cierra declarando `counted_balance = 8000`
- **THEN** `expected_balance = 8000`, `difference = 0`, `status = 'closed'`, `closed_at = now()`

#### Scenario: Cierre con faltante (diferencia negativa)
- **GIVEN** una sesión con `expected_balance = 8000`
- **WHEN** el usuario cierra declarando `counted_balance = 7500`
- **THEN** `difference = -500` se persiste, `status = 'closed'`, y la diferencia queda visible en el historial

#### Scenario: No se puede cerrar una sesión ya cerrada
- **GIVEN** una sesión con `status = 'closed'`
- **WHEN** un usuario llama a `rpc_close_cash_session` sobre ella
- **THEN** la RPC retorna `P0409 session_not_open` y no modifica la fila

### Requirement: Operación de caja solo contra sucursales operativas
El sistema SHALL rechazar abrir una sesión o registrar un movimiento en una caja cuya sucursal tiene `status = 'closed'`, con error `P0422 branch_closed`.

#### Scenario: Abrir sesión en caja de sucursal cerrada falla
- **GIVEN** una caja cuya `branch.status = 'closed'`
- **WHEN** un usuario llama a `rpc_open_cash_session`
- **THEN** la RPC retorna `P0422 branch_closed` y no crea sesión

### Requirement: UI de caja por sucursal
El sistema SHALL exponer la ruta `/sucursales/:id/caja` para abrir sesión (saldo inicial), ver los movimientos de la sesión activa, cerrar con arqueo (input de efectivo contado → diferencia visible) y consultar el historial de sesiones cerradas con su diferencia.

#### Scenario: El cajero abre y opera la caja del día
- **GIVEN** un usuario con permiso navega a `/sucursales/:id/caja` sin sesión abierta
- **WHEN** ingresa el saldo inicial y confirma la apertura
- **THEN** la vista muestra la sesión `open`, el listado (vacío) de movimientos y el botón de cierre

#### Scenario: El cajero cierra con arqueo y ve la diferencia
- **GIVEN** una sesión `open` con movimientos registrados
- **WHEN** el usuario ingresa el efectivo contado y confirma el cierre
- **THEN** la vista muestra esperado, contado y diferencia, y la sesión pasa a `closed` en el historial

### Requirement: La sesión de caja registra sus transiciones de estado en el historial
El sistema SHALL registrar en `document_status_history` (con `document_type = 'cash_session'`) tanto la apertura de la sesión (`from_status = NULL`, `to_status = 'open'`) como su cierre (`open → closed`) durante `rpc_close_cash_session`, en la misma transacción del cierre. Cuando el arqueo registra una diferencia distinta de cero, el sistema SHALL exigir un `reason` no vacío para la transición de cierre (RN-A5).

#### Scenario: Abrir una sesión de caja registra su estado inicial
- **WHEN** se abre una sesión de caja en estado `open`
- **THEN** el sistema inserta una fila de historial con `document_type = 'cash_session'`, `from_status = NULL`, `to_status = 'open'`

#### Scenario: Cerrar una sesión sin diferencia registra la transición
- **WHEN** `rpc_close_cash_session` cierra una sesión cuyo arqueo no arroja diferencia
- **THEN** el sistema inserta una fila de historial con `from_status = 'open'`, `to_status = 'closed'` en la misma transacción

#### Scenario: Cerrar una sesión con diferencia exige motivo
- **WHEN** `rpc_close_cash_session` cierra una sesión cuyo arqueo arroja una diferencia distinta de cero y no se provee `reason`
- **THEN** el registro de la transición aborta la operación con un error de payload inválido y el cierre no se confirma

