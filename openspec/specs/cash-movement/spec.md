# cash-movement Specification

## Purpose
TBD - created by archiving change v21-cash-session. Update Purpose after archive.
## Requirements
### Requirement: Ledger append-only de movimientos de efectivo
El sistema SHALL registrar cada movimiento de efectivo como una fila append-only en `cash_movements` (`id`, `session_id` FK `cash_sessions`, `amount NUMERIC`, `movement_type`, `reference_id UUID NULL`, `description TEXT NULL`, `balance_after NUMERIC`, `created_by`, `created_at`), sin UPDATE ni DELETE sobre filas existentes. Cada fila SHALL llevar `balance_after = saldo previo + amount` (patrón ledger contable, RN-98, igual que `stock_movements`). El aislamiento por cuenta (RLS) SHALL resolverse vía `session_id → cash_sessions.cashbox_id → cashboxes.branch_id → branches.account_id`. La columna `description` SHALL contener el motivo del movimiento cuando lo tenga; es opcional para los movimientos originados en operaciones (que ya se explican por su `reference_id`) y obligatoria para los ajustes manuales.

#### Scenario: Registrar un movimiento calcula balance_after
- **GIVEN** una sesión `open` con `opening_balance = 5000` y sin movimientos
- **WHEN** se registra un movimiento `amount = +1200`, `movement_type = 'sale'`
- **THEN** se inserta una fila con `balance_after = 6200` y `created_at = now()`

#### Scenario: Movimientos son append-only
- **GIVEN** un `cash_movement` ya insertado
- **WHEN** se intenta modificarlo o borrarlo vía la API
- **THEN** la operación no está permitida (sin endpoint de UPDATE/DELETE; RLS sin políticas de escritura directa fuera del helper definer)

#### Scenario: Un movimiento de venta no necesita motivo
- **WHEN** el hot path de la venta registra un movimiento `sale` sin `description`
- **THEN** la fila se inserta normalmente con `description IS NULL`

### Requirement: Tipos de movimiento enumerados
El sistema SHALL aceptar únicamente `movement_type` dentro del conjunto `{'sale', 'purchase_payment', 'expense', 'advance', 'withdrawal', 'sale_reversal', 'expense_reversal', 'adjustment'}`, validado por CHECK en la columna. `sale`, `advance` y `expense_reversal` son ingresos (signo positivo esperado); `purchase_payment`, `expense`, `withdrawal` y `sale_reversal` son egresos (signo negativo esperado); `adjustment` admite ambos signos (positivo = sobrante, negativo = faltante). El signo SHALL viajar en `amount` (el llamador lo provee), y el CHECK del enum SHALL validar solo la pertenencia al conjunto. Adicionalmente, un CHECK SHALL exigir que todo movimiento de tipo `adjustment` lleve `description` no vacía, sin imponer esa exigencia a los demás tipos.

#### Scenario: Tipo inválido es rechazado
- **GIVEN** una sesión `open`
- **WHEN** se intenta registrar un movimiento con `movement_type = 'tip'`
- **THEN** la inserción falla por violación del CHECK del enum

#### Scenario: El enum incluye adjustment
- **WHEN** se inspecciona el CHECK de `cash_movements.movement_type`
- **THEN** incluye los 8 tipos `sale`, `purchase_payment`, `expense`, `advance`, `withdrawal`, `sale_reversal`, `expense_reversal`, `adjustment`

#### Scenario: El enum incluye expense_reversal como ingreso
- **WHEN** se valida un movimiento `expense_reversal` con importe negativo por el camino de la API
- **THEN** es rechazado, porque la reversión de un egreso es un ingreso y exige signo positivo

#### Scenario: Ajuste sin motivo es rechazado por el CHECK
- **GIVEN** una sesión `open`
- **WHEN** se intenta insertar un movimiento `movement_type = 'adjustment'` con `description` nula o en blanco
- **THEN** la inserción falla por violación del CHECK de motivo obligatorio

#### Scenario: Las filas históricas sin motivo siguen siendo válidas
- **GIVEN** movimientos preexistentes de tipos distintos de `adjustment` con `description IS NULL`
- **WHEN** se aplica el CHECK de motivo obligatorio
- **THEN** ninguna fila histórica es invalidada ni reescrita

#### Scenario: Los movimientos históricos siguen siendo válidos tras ampliar el enum
- **GIVEN** los movimientos de caja existentes al momento de la migración
- **WHEN** se amplía el CHECK con `expense_reversal`
- **THEN** ninguna fila existente es invalidada ni reescrita
- **AND** la ampliación es idempotente ante una reaplicación de la migración

### Requirement: Movimiento exige sesión abierta
El sistema SHALL rechazar el registro de un `CashMovement` cuya `cash_session` no esté `status = 'open'`, con error `P0409 no_open_session`. Todo movimiento de efectivo requiere una sesión abierta (RN-95).

#### Scenario: Registrar movimiento sin sesión abierta falla
- **GIVEN** una sesión con `status = 'closed'` (o un `session_id` inexistente)
- **WHEN** se llama a `rpc_register_cash_movement` sobre ella
- **THEN** la RPC retorna `P0409 no_open_session` y no inserta ninguna fila

### Requirement: Helper transaccional reutilizable para el hot path de venta
El sistema SHALL exponer un helper SQL `c28_register_cash_movement(p_session_id, p_amount, p_type, p_reference_id)` invocable desde **dentro de otra transacción** (p. ej. la RPC de confirmación de venta de C-29), que inserta el `cash_movement` con `balance_after` calculado y aplica las invariantes (sesión abierta, sucursal operativa) sin abrir una transacción propia. La RPC pública `rpc_register_cash_movement` SHALL ser un wrapper fino sobre este helper. Esto garantiza que una venta en efectivo pueda generar su movimiento de caja en la MISMA transacción que el descuento de stock (DEC-20), atómicamente.

#### Scenario: Venta en efectivo genera el movimiento en la misma transacción (contrato listo para C-29)
- **GIVEN** una sesión de caja `open` y una transacción de venta en curso que invoca `c28_register_cash_movement(session, total, 'sale', sale_id)`
- **WHEN** la transacción de venta hace COMMIT
- **THEN** `cash_movements` contiene exactamente una fila con `movement_type = 'sale'`, `reference_id = sale_id` y `amount = total`, persistida atómicamente con el resto de la venta

#### Scenario: Si la venta falla, el movimiento de caja se revierte (atomicidad)
- **GIVEN** una transacción de venta que registró un `cash_movement` vía el helper y luego falla (p. ej. stock insuficiente)
- **WHEN** la transacción hace ROLLBACK
- **THEN** no queda ninguna fila en `cash_movements` para esa venta (el helper no abre su propia transacción)

### Requirement: El helper transaccional de caja rechaza una sesión de otra cuenta

El sistema SHALL rechazar todo intento de registrar un movimiento de efectivo contra una sesión de caja que no pertenezca a alguna de las cuentas de las que el usuario en curso es miembro, sin insertar ninguna fila.

El helper intra-transacción es el **punto de paso obligado** de todo movimiento de caja del sistema: lo invocan el camino del mostrador, el del formulario de venta, el de compensación por borrado y la operación manual de ajuste. Hasta ahora sólo verificaba que la sesión estuviera abierta y que la sucursal estuviera operativa, sin mirar de quién era la caja; como todos sus llamadores tienen privilegio de definidor, las políticas de seguridad a nivel de fila no intervienen. Poner la verificación acá SHALL cubrir por construcción a **todo llamador presente y futuro**, incluido cualquiera que se agregue sin acordarse del invariante.

La cuenta SHALL resolverse recorriendo la cadena de claves foráneas que va de la sesión a la caja y de la caja a la sucursal, **sin agregar parámetros**: la firma del helper SHALL permanecer intacta, para no arrastrar una eliminación y recreación de función ni el riesgo de dejar dos definiciones convivientes. Esa misma resolución ya existe en el comando público de registro manual y SHALL reutilizarse en lugar de escribirse de nuevo.

La verificación SHALL ser de **pertenencia** a la cuenta y no de rol de escritura. El comando público de registro manual exige además rol de escritura, y esa exigencia SHALL permanecer donde está: elevarla al punto de paso obligado le quitaría al miembro sin rol de escritura la posibilidad de registrar una venta en efectivo, que hoy tiene — un endurecimiento de permisos encubierto dentro de un cambio de seguridad.

El error elegido SHALL ser el mismo que el comando público ya usa para el mismo predicado, y SHALL NOT ser el código genérico de excepción de procedimiento, porque existen verificaciones de comportamiento embebidas en migraciones históricas que atrapan ese código genérico y lo vuelven a lanzar: elegirlo abortaría la reconstrucción del esquema desde cero.

#### Scenario: Registrar un movimiento en la caja de otra cuenta es rechazado

- **GIVEN** una sesión de caja abierta perteneciente a la cuenta B
- **WHEN** un usuario que sólo es miembro de la cuenta A invoca el registro de un movimiento contra esa sesión, por cualquier camino
- **THEN** la operación es rechazada y la cantidad de movimientos de la sesión de B queda sin cambios

#### Scenario: El registro por el camino propio sigue funcionando

- **GIVEN** una sesión de caja abierta de la propia cuenta, con saldo de apertura conocido
- **WHEN** se registra un movimiento de venta
- **THEN** la fila se inserta con el saldo posterior calculado como saldo previo más importe, igual que antes del cambio

#### Scenario: La verificación no cambia la firma del helper

- **WHEN** se inspeccionan las funciones de registro de movimiento de caja tras la migración
- **THEN** existe exactamente una definición viva de cada una, con la misma lista de parámetros que antes del cambio

#### Scenario: Un miembro sin rol de escritura sigue pudiendo vender en efectivo

- **GIVEN** un usuario que es miembro de la cuenta pero no tiene rol de escritura
- **WHEN** registra una venta en efectivo por el camino del formulario contra una sesión abierta de su propia cuenta
- **THEN** el movimiento se registra, porque la verificación del punto de paso obligado es de pertenencia y no de rol

#### Scenario: La compensación por borrado sigue funcionando

- **GIVEN** una venta de la propia cuenta que registró un ingreso de caja y una sesión abierta en esa misma caja
- **WHEN** se borra la venta
- **THEN** el contra-movimiento se registra normalmente, porque la caja se deriva de la operación que ya fue verificada

#### Scenario: El saldo posterior sigue calculándose por suma de importes y no por máximo

- **GIVEN** una sesión con saldo de apertura conocido
- **WHEN** se registran, en orden, un ingreso, un egreso menor y otro ingreso
- **THEN** el saldo posterior de cada movimiento refleja la suma acumulada de los importes y no el máximo histórico alcanzado

### Requirement: Suma de movimientos alimenta el arqueo
El sistema SHALL exponer `Σ(cash_movements.amount)` de una sesión como base del `expected_balance` al cerrar (`expected = opening_balance + Σ amount`), consultable también para mostrar el saldo corriente de la sesión activa en la UI.

#### Scenario: El esperado al cierre refleja todos los movimientos
- **GIVEN** una sesión con `opening_balance = 5000` y movimientos `+1200` (sale), `-300` (expense), `+800` (sale)
- **WHEN** se calcula el esperado
- **THEN** `expected_balance = 6700` (5000 + 1200 − 300 + 800)

### Requirement: Contra-movimiento de caja por borrado de operación
El sistema SHALL registrar un movimiento de caja espejo de tipo `sale_reversal`, por el importe opuesto al movimiento original, cuando se borra una operación que tenía un movimiento de caja posteado.

#### Scenario: Venta con movimiento de caja
- **WHEN** se borra una venta que registró un ingreso de caja
- **THEN** se registra un movimiento `sale_reversal` por el importe opuesto
- **AND** el movimiento referencia la operación borrada
- **AND** el saldo de la caja vuelve exactamente al valor previo a la venta

#### Scenario: Operación sin movimiento de caja
- **WHEN** se borra una operación que nunca registró caja
- **THEN** no se registra ningún movimiento de caja

### Requirement: Destino del contra-movimiento respecto de sesiones cerradas
El sistema SHALL registrar el contra-movimiento en la sesión de caja abierta en ese momento para la misma caja, y SHALL NOT insertar, modificar ni anular movimientos dentro de una sesión ya cerrada, preservando la integridad del arqueo firmado.

#### Scenario: La sesión original ya cerró
- **WHEN** se borra una operación cuyo movimiento de caja pertenece a una sesión cerrada
- **AND** existe una sesión abierta en la misma caja
- **THEN** el contra-movimiento se registra en la sesión abierta
- **AND** la sesión cerrada y su arqueo quedan sin modificaciones

#### Scenario: No hay sesión abierta
- **WHEN** se borra una operación que requiere compensar caja
- **AND** no existe ninguna sesión abierta en esa caja
- **THEN** el sistema rechaza el borrado con el código de error `P0426`
- **AND** el mensaje indica que debe abrirse la caja para poder anular la operación

#### Scenario: La sesión original sigue abierta
- **WHEN** se borra una operación cuyo movimiento de caja pertenece a una sesión todavía abierta
- **THEN** el contra-movimiento se registra en esa misma sesión

### Requirement: Vocabulario de tipos de movimiento de caja
El catálogo de tipos de movimiento de caja SHALL admitir `sale_reversal` y `expense_reversal` como tipos propios, distinguibles de los retiros, de los egresos operativos y de los ajustes manuales en los reportes de caja. Cada contra-movimiento automático SHALL tener su tipo propio en lugar de reutilizar `adjustment`, que está reservado para la corrección manual y exige motivo.

La clasificación por **signo** y la clasificación por **familia de la superficie** SHALL tratarse como dos taxonomías distintas: los dos contra-movimientos automáticos comparten la familia de reversiones y tienen signos opuestos entre sí, porque revertir una venta saca dinero de la caja y revertir un gasto lo repone.

#### Scenario: Reporte de caja con una reversión
- **WHEN** se lista el detalle de una sesión que contiene un `sale_reversal`
- **THEN** el movimiento aparece identificado como reversión de venta
- **AND** no se contabiliza como retiro ni como gasto

#### Scenario: Reporte de caja con una reversión de gasto
- **WHEN** se lista el detalle de una sesión que contiene un `expense_reversal`
- **THEN** el movimiento aparece identificado como reversión de gasto
- **AND** su signo es el de un ingreso, no el de un ajuste ni el de una venta

#### Scenario: La superficie de caja nombra el tipo nuevo
- **WHEN** se muestra el historial de una caja que contiene una reversión de gasto
- **THEN** el movimiento tiene etiqueta e ícono propios y cae dentro del filtro de reversas, junto a la reversión de venta
- **AND** no cae dentro del filtro de ingresos, que agrupa las entradas operativas de dinero
- **AND** usa los tonos semánticos del design system

### Requirement: El gasto es un productor real de movimientos de egreso de caja

El sistema SHALL registrar, para un gasto en efectivo con impacto en caja confirmado, un movimiento de tipo `expense` con importe negativo y referencia al gasto, delegando en el helper intra-transaccional de caja que ya existe y sin agregar una segunda puerta de escritura.

El tipo `expense` está aceptado por el CHECK de la tabla desde la introducción de la sesión de caja y nunca tuvo un productor: este cambio lo activa. El endpoint de registro manual de movimiento de caja SHALL seguir existiendo tal cual está y SHALL NOT convertirse en el camino del gasto, porque un movimiento manual queda desvinculado del gasto que lo originó y no es atómico con él.

#### Scenario: El egreso del gasto queda vinculado a su gasto

- **WHEN** un gasto en efectivo registra su egreso de caja
- **THEN** el movimiento queda con tipo `expense`, importe negativo y referencia al identificador del gasto
- **AND** el saldo posterior de la sesión refleja la resta

#### Scenario: El registro manual sigue siendo un camino separado

- **WHEN** un usuario registra a mano un egreso de caja desde el módulo Caja
- **THEN** el movimiento se registra por el camino manual, sin referencia a ningún gasto
- **AND** ese camino conserva sus guards de rol actuales

### Requirement: Contra-movimiento de caja por borrado de un gasto

El sistema SHALL registrar un contra-movimiento de tipo `expense_reversal` con importe positivo al borrar un gasto que había descontado de la caja, dentro de la misma transacción del borrado, y SHALL NOT modificar ni eliminar el movimiento original, porque el ledger de caja es append-only.

El contra-movimiento SHALL registrarse contra la **sesión abierta actual de la misma caja**, con el mismo criterio que ya rige para el borrado de una venta en efectivo. Si no existe ninguna sesión abierta en esa caja, el borrado completo SHALL rechazarse con el código de error `P0426`, indicando que hay que abrir la caja para poder borrar el gasto.

La compensación SHALL dispararse por la **existencia** de un movimiento de caja del gasto y SHALL NOT depender del signo de ese movimiento: el importe del contra-movimiento es el opuesto exacto de lo posteado. Condicionar el disparo al signo esperado haría que un movimiento con el signo contrario —llegado por cualquier camino— se saltee la compensación entera sin levantar ningún error.

#### Scenario: Gasto con movimiento de caja y sesión abierta

- **GIVEN** un gasto que descontó de la caja y una sesión abierta en esa misma caja
- **WHEN** se borra el gasto
- **THEN** la sesión abierta registra un `expense_reversal` positivo por el mismo importe
- **AND** el movimiento original de la sesión anterior queda intacto
- **AND** el gasto queda borrado

#### Scenario: La sesión original ya cerró

- **GIVEN** un gasto cuyo egreso se registró en una sesión ya cerrada, y otra sesión abierta hoy en la misma caja
- **WHEN** se borra el gasto
- **THEN** el contra-movimiento va a la sesión abierta de hoy
- **AND** el arqueo de la sesión cerrada no se altera

#### Scenario: No hay ninguna sesión abierta

- **GIVEN** un gasto que descontó de la caja y ninguna sesión abierta en esa caja
- **WHEN** se intenta borrar el gasto
- **THEN** la operación es rechazada con `P0426`
- **AND** el gasto sigue existiendo y ningún libro se altera

#### Scenario: El disparo de la compensación no depende del signo

- **GIVEN** un gasto cuyo movimiento de caja quedó registrado con el signo contrario al esperado
- **WHEN** se borra el gasto
- **THEN** la caja recibe igual su contra-movimiento por el importe opuesto
- **AND** el borrado no procede sin compensar

#### Scenario: Gasto sin movimiento de caja

- **WHEN** se borra un gasto que nunca descontó de la caja
- **THEN** el borrado procede sin registrar ningún contra-movimiento
- **AND** no se exige ninguna sesión abierta

### Requirement: El motivo del ajuste viaja por la cadena de escritura de caja
El sistema SHALL propagar el motivo del movimiento desde la RPC de registro hasta la fila del ledger, agregando el parámetro de motivo tanto a `rpc_register_cash_movement` como al helper intra-transaccional que ésta delega, con valor por omisión nulo para que los llamadores existentes del hot path de venta no requieran cambios. La firma nueva SHALL revocar explícitamente `EXECUTE` de `PUBLIC`, `anon` y `authenticated` y volver a otorgarlo de forma selectiva en la misma migración, y SHALL quedar como única firma viva de cada función.

#### Scenario: El hot path de venta no cambia
- **WHEN** el camino de venta llama a la RPC de registro sin el parámetro de motivo
- **THEN** el movimiento se registra igual que antes, con `description IS NULL`

#### Scenario: El ajuste viaja con su motivo
- **WHEN** se llama a la RPC de registro con `movement_type = 'adjustment'` y un motivo
- **THEN** la fila insertada persiste ese motivo en `description`

#### Scenario: No quedan firmas duplicadas
- **WHEN** se inspeccionan las funciones de registro de movimiento de caja tras la migración
- **THEN** existe exactamente una firma viva de cada una, con los permisos re-otorgados explícitamente

