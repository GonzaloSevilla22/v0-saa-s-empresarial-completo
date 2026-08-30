## MODIFIED Requirements

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

## ADDED Requirements

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
