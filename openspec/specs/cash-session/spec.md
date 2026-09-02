# cash-session Specification

> Updated from `pos-catalogo-pagos` — 2026-08-20 (explicita qué camino alimenta el arqueo)

## Purpose
TBD - created by archiving change v21-cash-session. Update Purpose after archive.
## Requirements
### Requirement: Sólo el camino del mostrador alimenta el arqueo

El sistema SHALL alimentar `cash_movements` de tipo `sale` desde el camino del mostrador —`quickSale()` y la confirmación de una orden de venta con forma de pago de `kind = 'cash'`— **de forma automática**, y SHALL alimentar el arqueo desde **todos los demás caminos únicamente mediante un opt-in explícito del usuario**. Los caminos con opt-in son cuatro: el formulario de venta (`sale`), el gasto (`expense`), la compra (`purchase_payment`) y el cobro o pago de una cuenta corriente (`payment_received` / `payment_made`).

Para los caminos que registran un **documento con fecha y sucursal propias** —formulario de venta, gasto y compra— el servidor SHALL honrar el opt-in sólo si se cumplen simultáneamente las tres condiciones siguientes: la forma de pago imputada tiene `kind = 'cash'`, existe una sesión de caja `open` en la sucursal efectiva del documento, y la fecha del documento es el día de hoy en `America/Argentina/Mendoza`.

Para el **cobro y el pago de cuenta corriente** el servidor SHALL honrar el opt-in si se cumplen las dos condiciones aplicables: **la forma de pago imputada tiene `kind = 'cash'`**, y la sesión de caja informada está `open` y pertenece a la cuenta. La condición de fecha NO SHALL exigirse, y la de sucursal NO SHALL exigirse como coincidencia: un cobro no tiene fecha ni sucursal propias —se registra en el instante en que ocurre y su sucursal es, por construcción, la de la caja elegida—, de modo que ambas condiciones son verdaderas por diseño y especificarlas como guards sugeriría un caso retroactivo que el modelo no admite. La pertenencia de la sesión a la cuenta SHALL verificarse igual, y la aporta el punto de paso obligado del registro de movimientos de caja.

La condición de efectivo SHALL evaluarse, **en los cuatro caminos por igual**, sobre el `kind` derivado del catálogo de formas de pago a partir del identificador imputado al documento, y NO SHALL evaluarse sobre ninguna etiqueta de texto recibida del cliente ni sobre el valor de un control de selección de la interfaz. Esta uniformidad es normativa: el cobro y el pago de cuenta corriente eran los últimos caminos que resolvían la condición contra una taxonomía de texto propia, y mientras lo hicieran la misma pregunta —«¿esto es efectivo?»— tenía dos implementaciones distintas que podían divergir sin que nada lo detectara.

En ausencia del opt-in, ningún camino distinto del mostrador SHALL generar `cash_movements`, aunque la operación esté imputada a efectivo. Todas las condiciones SHALL verificarse en el servidor y NO SHALL delegarse en la interfaz: una solicitud que informe una sesión de caja sin cumplirlas SHALL fallar en vez de registrar el movimiento.

La asimetría entre automático y opt-in es deliberada y SHALL declararse al usuario en la superficie que ofrece el selector: `expected_balance = opening_balance + Σ(cash_movements)` es la base del arqueo y su `difference` es una señal antifraude (RN-95), de modo que inyectar en una sesión abierta un importe que nadie depositó en el cajón convertiría toda diferencia en ruido; el opt-in es la afirmación explícita del usuario de que ese efectivo sí entró o salió de esa caja, y el guard de fecha impide atribuir a una sesión abierta el efectivo de un documento retroactivo.

#### Scenario: Venta en efectivo desde el formulario sin opt-in no altera el arqueo

- **GIVEN** una sesión de caja abierta con `opening_balance = 5000` y sin movimientos
- **WHEN** se registra desde el formulario de venta una venta de 2000 imputada a una forma de pago de `kind = 'cash'` sin marcar el opt-in de caja
- **AND** se cierra la sesión declarando `counted_balance = 5000`
- **THEN** `expected_balance = 5000` y `difference = 0`

#### Scenario: Venta en efectivo desde el formulario con opt-in sí altera el arqueo

- **GIVEN** una sesión de caja abierta con `opening_balance = 5000` y sin movimientos en la sucursal de la venta
- **WHEN** se registra hoy desde el formulario una venta de 2000 imputada a `kind = 'cash'` marcando el opt-in de caja
- **THEN** se crea un `cash_movements` de tipo `sale` por 2000 contra esa sesión, con `reference_id` apuntando a la operación
- **AND** al cerrar la sesión declarando `counted_balance = 7000`, `expected_balance = 7000` y `difference = 0`

#### Scenario: Venta en efectivo desde el POS sí altera el arqueo

- **GIVEN** una sesión de caja abierta con `opening_balance = 5000` y sin movimientos
- **WHEN** se cobra desde el POS una venta de 2000 con una forma de pago de `kind = 'cash'`
- **AND** se cierra la sesión declarando `counted_balance = 7000`
- **THEN** `expected_balance = 7000` y `difference = 0`

#### Scenario: Compra en efectivo con opt-in resta del arqueo

- **GIVEN** una sesión de caja abierta con `opening_balance = 5000` y sin movimientos en la sucursal de la compra
- **WHEN** se registra hoy una compra de 2000 imputada a `kind = 'cash'` marcando el opt-in de caja
- **AND** se cierra la sesión declarando `counted_balance = 3000`
- **THEN** `expected_balance = 3000` y `difference = 0`

#### Scenario: Compra en efectivo sin opt-in no altera el arqueo

- **GIVEN** una sesión de caja abierta con `opening_balance = 5000` y sin movimientos
- **WHEN** se registra una compra de 2000 imputada a `kind = 'cash'` sin marcar el opt-in
- **AND** se cierra la sesión declarando `counted_balance = 5000`
- **THEN** `expected_balance = 5000` y `difference = 0`

#### Scenario: Cobro de cuenta corriente en efectivo con opt-in suma al arqueo

- **GIVEN** una sesión de caja abierta con `opening_balance = 5000` y sin movimientos
- **WHEN** se registra un cobro de 1200 imputado a una forma de pago de `kind = 'cash'` sobre la cuenta corriente de un cliente, confirmando el impacto en caja
- **AND** se cierra la sesión declarando `counted_balance = 6200`
- **THEN** `expected_balance = 6200` y `difference = 0`

#### Scenario: Pago a proveedor en efectivo con opt-in resta del arqueo

- **GIVEN** una sesión de caja abierta con `opening_balance = 5000` y sin movimientos
- **WHEN** se registra un pago de 1200 imputado a una forma de pago de `kind = 'cash'` a un proveedor, confirmando el impacto en caja
- **AND** se cierra la sesión declarando `counted_balance = 3800`
- **THEN** `expected_balance = 3800` y `difference = 0`

#### Scenario: El cobro en efectivo sin opt-in no altera el arqueo

- **GIVEN** una sesión de caja abierta con `opening_balance = 5000` y sin movimientos
- **WHEN** se registra un cobro de 1200 en efectivo sin confirmar el impacto en caja
- **AND** se cierra la sesión declarando `counted_balance = 5000`
- **THEN** `expected_balance = 5000` y `difference = 0`
- **AND** el saldo del cliente igual se redujo en 1200

#### Scenario: El cobro con forma de pago de efectivo renombrada suma igual al arqueo

- **GIVEN** una sesión de caja abierta y una forma de pago de `kind = 'cash'` que el usuario renombró a "Caja chica"
- **WHEN** se registra un cobro imputado a ella, confirmando el impacto en caja
- **THEN** el movimiento de caja se registra igual, porque la condición se evalúa sobre el `kind` derivado del catálogo y no sobre el nombre

#### Scenario: El cobro imputado a una forma de pago no efectiva no puede optar por caja

- **GIVEN** una sesión de caja abierta
- **WHEN** se registra un cobro imputado a una forma de pago de `kind` bancario informando esa sesión
- **THEN** la operación falla con `cash_optin_requires_cash_kind` y no se registra ni el cobro ni ningún movimiento

#### Scenario: El cobro no exige que la fecha sea hoy

- **GIVEN** una sesión de caja abierta
- **WHEN** se registra un cobro en efectivo confirmando el impacto en caja
- **THEN** el movimiento se registra sin ninguna verificación de fecha, porque el cobro se registra en el instante en que ocurre

#### Scenario: El cobro contra una sesión de otra cuenta es rechazado

- **GIVEN** una sesión de caja abierta perteneciente a otra cuenta
- **WHEN** se registra un cobro en efectivo informando esa sesión
- **THEN** la operación es rechazada, no se registra el cobro y la cantidad de movimientos de la sesión ajena queda sin cambios

#### Scenario: El opt-in con fecha anterior a hoy es rechazado

- **GIVEN** una sesión de caja abierta en la sucursal
- **WHEN** se registra desde el formulario una venta con fecha de ayer, imputada a `kind = 'cash'`, informando la sesión de caja
- **THEN** la operación falla con `cash_optin_requires_today` y no se crea ninguna venta ni movimiento de caja

#### Scenario: El opt-in sin sesión abierta es rechazado

- **GIVEN** una sucursal sin ninguna sesión de caja `open`
- **WHEN** se registra hoy desde el formulario una venta imputada a `kind = 'cash'` informando un identificador de sesión
- **THEN** la operación falla con `cash_optin_requires_open_session` y no se crea ninguna venta ni movimiento de caja

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
El sistema SHALL cerrar una `CashSession` vía `rpc_close_cash_session(p_session_id, p_counted_balance)`, calculando `expected_balance = opening_balance + Σ(cash_movements.amount)` de la sesión, registrando `counted_balance`, `difference = counted_balance - expected_balance`, `closing_balance = counted_balance`, `status = 'closed'`, `closed_by` y `closed_at = now()`. La diferencia SHALL persistirse aunque sea distinta de cero (señal antifraude, RN-95). El cierre SHALL además materializar `adjustments_total = Σ(cash_movements.amount) FILTER (movement_type = 'adjustment')` de la sesión y SHALL devolver `difference_before_adjustments = difference + adjustments_total`, sin alterar la definición de `expected_balance` ni la de `difference`, de modo que los ajustes manuales queden separables del arqueo en lugar de disolverse en él.

#### Scenario: Cierre con arqueo exacto
- **GIVEN** una sesión con `opening_balance = 5000` y movimientos que suman `+3000`
- **WHEN** el usuario cierra declarando `counted_balance = 8000`
- **THEN** `expected_balance = 8000`, `difference = 0`, `adjustments_total = 0`, `status = 'closed'`, `closed_at = now()`

#### Scenario: Cierre con faltante (diferencia negativa)
- **GIVEN** una sesión con `expected_balance = 8000`
- **WHEN** el usuario cierra declarando `counted_balance = 7500`
- **THEN** `difference = -500` se persiste, `status = 'closed'`, y la diferencia queda visible en el historial

#### Scenario: No se puede cerrar una sesión ya cerrada
- **GIVEN** una sesión con `status = 'closed'`
- **WHEN** un usuario llama a `rpc_close_cash_session` sobre ella
- **THEN** la RPC retorna `P0409 session_not_open` y no modifica la fila

#### Scenario: Cierre de una sesión con ajustes manuales
- **GIVEN** una sesión cuyo `opening_balance + Σ(movimientos no ajuste) = 900` y que tiene un ajuste de `+100`
- **WHEN** el usuario cierra declarando `counted_balance = 1000`
- **THEN** `expected_balance = 1000`, `difference = 0`, `adjustments_total = +100` y `difference_before_adjustments = +100`

#### Scenario: El total de ajustes queda en el registro de la transición de cierre
- **GIVEN** una sesión con al menos un movimiento de ajuste
- **WHEN** se cierra la sesión
- **THEN** el motivo de la transición `open → closed` menciona los ajustes aplicados, y el evento de cierre emitido lleva `adjustments_total` en su payload

### Requirement: Operación de caja solo contra sucursales operativas
El sistema SHALL rechazar abrir una sesión o registrar un movimiento en una caja cuya sucursal tiene `status = 'closed'`, con error `P0422 branch_closed`.

#### Scenario: Abrir sesión en caja de sucursal cerrada falla
- **GIVEN** una caja cuya `branch.status = 'closed'`
- **WHEN** un usuario llama a `rpc_open_cash_session`
- **THEN** la RPC retorna `P0422 branch_closed` y no crea sesión

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

### Requirement: La sesión de caja persiste el total de sus ajustes manuales
El sistema SHALL persistir en `cash_sessions` la columna aditiva `adjustments_total NUMERIC NULL`, materializada al cerrar la sesión como la suma firmada de los movimientos de tipo `adjustment` de esa sesión, y SHALL calcular esa misma cifra al vuelo para las sesiones que aún están abiertas, de modo que la señal esté disponible sin depender de que alguien cierre la sesión.

#### Scenario: Sesión cerrada con ajustes
- **WHEN** se cierra una sesión que contiene ajustes por `+100` y `-30`
- **THEN** la fila queda con `adjustments_total = +70`

#### Scenario: Sesión abierta con ajustes
- **GIVEN** una sesión `open` con un ajuste de `+100`
- **WHEN** se consulta el estado de la sesión
- **THEN** la lectura informa un total de ajustes de `+100` aunque `adjustments_total` todavía no esté materializado

#### Scenario: Sesiones históricas sin ajustes
- **GIVEN** sesiones cerradas antes de este cambio
- **WHEN** se consultan
- **THEN** su `adjustments_total` es nulo y se interpreta como cero, sin reescritura de datos históricos

