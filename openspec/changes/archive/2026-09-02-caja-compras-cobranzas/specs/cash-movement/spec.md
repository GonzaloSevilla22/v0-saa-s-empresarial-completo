## MODIFIED Requirements

### Requirement: Tipos de movimiento enumerados
El sistema SHALL aceptar únicamente `movement_type` dentro del conjunto `{'sale', 'purchase_payment', 'expense', 'advance', 'withdrawal', 'sale_reversal', 'expense_reversal', 'purchase_payment_reversal', 'payment_received', 'payment_made', 'adjustment'}`, validado por CHECK en la columna. `sale`, `advance`, `expense_reversal`, `purchase_payment_reversal` y `payment_received` son ingresos (signo positivo esperado); `purchase_payment`, `expense`, `withdrawal`, `sale_reversal` y `payment_made` son egresos (signo negativo esperado); `adjustment` admite ambos signos (positivo = sobrante, negativo = faltante). El signo SHALL viajar en `amount` (el llamador lo provee), y el CHECK del enum SHALL validar solo la pertenencia al conjunto. Adicionalmente, un CHECK SHALL exigir que todo movimiento de tipo `adjustment` lleve `description` no vacía, sin imponer esa exigencia a los demás tipos.

#### Scenario: Tipo inválido es rechazado
- **GIVEN** una sesión `open`
- **WHEN** se intenta registrar un movimiento con `movement_type = 'tip'`
- **THEN** la inserción falla por violación del CHECK del enum

#### Scenario: El enum incluye los once tipos
- **WHEN** se inspecciona el CHECK de `cash_movements.movement_type`
- **THEN** incluye los 11 tipos `sale`, `purchase_payment`, `expense`, `advance`, `withdrawal`, `sale_reversal`, `expense_reversal`, `purchase_payment_reversal`, `payment_received`, `payment_made`, `adjustment`

#### Scenario: El enum incluye expense_reversal como ingreso
- **WHEN** se valida un movimiento `expense_reversal` con importe negativo por el camino de la API
- **THEN** es rechazado, porque la reversión de un egreso es un ingreso y exige signo positivo

#### Scenario: La reversión de una compra en efectivo es un ingreso
- **WHEN** se valida un movimiento `purchase_payment_reversal` con importe negativo por el camino de la API
- **THEN** es rechazado, porque revertir el pago de una compra repone el efectivo en el cajón

#### Scenario: El cobro de una cuenta corriente es un ingreso y el pago a un proveedor un egreso
- **WHEN** se valida un movimiento `payment_received` con importe negativo, o un `payment_made` con importe positivo, por el camino de la API
- **THEN** ambos son rechazados por signo incoherente con su tipo

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
- **WHEN** se amplía el CHECK con `purchase_payment_reversal`, `payment_received` y `payment_made`
- **THEN** ninguna fila existente es invalidada ni reescrita
- **AND** la ampliación es idempotente ante una reaplicación de la migración

### Requirement: Vocabulario de tipos de movimiento de caja
El catálogo de tipos de movimiento de caja SHALL admitir `sale_reversal`, `expense_reversal` y `purchase_payment_reversal` como tipos propios, distinguibles de los retiros, de los egresos operativos y de los ajustes manuales en los reportes de caja, y SHALL distinguir además el pago de una compra al contado (`purchase_payment`) de la cancelación de una deuda de cuenta corriente con un proveedor (`payment_made`), y el cobro de una cuenta corriente (`payment_received`) de una venta del día (`sale`). Cada contra-movimiento automático SHALL tener su tipo propio en lugar de reutilizar `adjustment`, que está reservado para la corrección manual y exige motivo.

La clasificación por **signo** y la clasificación por **familia de la superficie** SHALL tratarse como dos taxonomías distintas: los tres contra-movimientos automáticos comparten la familia de reversiones y no comparten signo entre sí, porque revertir una venta saca dinero de la caja mientras que revertir un gasto o una compra lo repone.

La etiqueta de `purchase_payment` SHALL nombrar la **compra al contado** y SHALL NOT nombrar el pago a un proveedor, porque ese nombre pasa a designar al tipo `payment_made`: dos tipos con la misma etiqueta en el historial de caja serían indistinguibles justo cuando el usuario quiere saber en qué se le fue la plata. El cambio de etiqueta SHALL NOT reescribir ninguna fila.

Los dos hechos SHALL permanecer separados porque son económicamente distintos —uno adquiere mercadería, el otro cancela un pasivo ya registrado— y porque van a contrapartidas contables distintas cuando el asiento del libro diario incorpore estos caminos.

#### Scenario: Reporte de caja con una reversión
- **WHEN** se lista el detalle de una sesión que contiene un `sale_reversal`
- **THEN** el movimiento aparece identificado como reversión de venta
- **AND** no se contabiliza como retiro ni como gasto

#### Scenario: Reporte de caja con una reversión de gasto
- **WHEN** se lista el detalle de una sesión que contiene un `expense_reversal`
- **THEN** el movimiento aparece identificado como reversión de gasto
- **AND** su signo es el de un ingreso, no el de un ajuste ni el de una venta

#### Scenario: Reporte de caja con una reversión de compra
- **WHEN** se lista el detalle de una sesión que contiene un `purchase_payment_reversal`
- **THEN** el movimiento aparece identificado como reversión de compra
- **AND** su signo es el de un ingreso

#### Scenario: La compra al contado y el pago de deuda no comparten etiqueta
- **WHEN** se lista una sesión que contiene un `purchase_payment` y un `payment_made`
- **THEN** el primero se identifica como compra en efectivo y el segundo como pago a proveedor
- **AND** las dos etiquetas son distintas entre sí

#### Scenario: El cobro de cuenta corriente no se confunde con una venta
- **WHEN** se lista una sesión que contiene un `payment_received`
- **THEN** el movimiento se identifica como cobro de cliente y no como venta
- **AND** el total de ventas de la sesión no lo incluye

#### Scenario: La superficie de caja nombra los tipos nuevos
- **WHEN** se muestra el historial de una caja que contiene una reversión de compra, un cobro y un pago
- **THEN** cada movimiento tiene etiqueta e ícono propios
- **AND** la reversión de compra cae dentro del filtro de reversas, junto a la reversión de venta y a la de gasto
- **AND** el cobro cae dentro del filtro de ingresos y el pago dentro del de egresos
- **AND** todos usan los tonos semánticos del design system

#### Scenario: El cambio de etiqueta no reescribe filas
- **WHEN** se aplica el cambio de etiqueta de `purchase_payment`
- **THEN** ninguna fila de `cash_movements` es modificada

## ADDED Requirements

### Requirement: La compra en efectivo es un productor real de movimientos de egreso de caja

El sistema SHALL registrar, para una compra en efectivo con impacto en caja confirmado, un movimiento de tipo `purchase_payment` con importe negativo y referencia a la operación de compra, delegando en el helper intra-transaccional de caja que ya existe y sin agregar una segunda puerta de escritura.

El tipo `purchase_payment` está aceptado por el CHECK de la tabla desde la introducción de la sesión de caja y **nunca tuvo un productor**: este cambio lo activa. La ausencia de productor es verificable —ninguna función viva lo escribe y ninguna fila lo usa—, de modo que activarlo no altera ningún dato existente.

El registro manual de movimiento de caja SHALL seguir existiendo tal cual está y SHALL NOT convertirse en el camino de la compra, porque un movimiento manual queda desvinculado de la compra que lo originó y no es atómico con ella.

#### Scenario: El egreso de la compra queda vinculado a su compra

- **WHEN** una compra en efectivo registra su egreso de caja
- **THEN** el movimiento queda con tipo `purchase_payment`, importe negativo y referencia al identificador de la operación de compra
- **AND** el saldo posterior de la sesión refleja la resta

#### Scenario: El registro manual sigue siendo un camino separado

- **WHEN** un usuario registra a mano un egreso de caja desde el módulo Caja
- **THEN** el movimiento se registra por el camino manual, sin referencia a ninguna compra
- **AND** ese camino conserva sus guards de rol actuales

### Requirement: El cobro y el pago de cuenta corriente son productores reales de movimientos de caja

El sistema SHALL registrar, para un cobro de cuenta corriente de cliente en efectivo con impacto en caja confirmado, un movimiento de tipo `payment_received` con importe **positivo** y referencia al cobro; y para un pago a proveedor en efectivo con impacto confirmado, un movimiento de tipo `payment_made` con importe **negativo** y referencia al pago. Ambos SHALL delegar en el helper intra-transaccional de caja que ya existe.

El movimiento de caja SHALL registrarse en la **misma transacción** que el movimiento de cuenta corriente y la fila de cobro o pago, de modo que no exista un estado observable en el que el saldo de la parte haya cambiado y el cajón no, ni a la inversa.

El movimiento de caja SHALL quedar **dentro** del alcance de la clave de idempotencia del cobro o del pago: una repetición de la misma clave SHALL devolver el resultado original sin registrar un segundo movimiento de caja.

#### Scenario: El cobro en efectivo ingresa al cajón

- **GIVEN** un cliente con saldo deudor y una sesión de caja abierta
- **WHEN** se registra un cobro de 400 en efectivo confirmando el impacto en caja
- **THEN** se registra un movimiento `payment_received` de importe positivo 400 referenciando el cobro
- **AND** el saldo del cliente baja en 400 en el mismo commit

#### Scenario: El pago a proveedor en efectivo sale del cajón

- **GIVEN** un proveedor con saldo acreedor y una sesión de caja abierta
- **WHEN** se registra un pago de 400 en efectivo confirmando el impacto en caja
- **THEN** se registra un movimiento `payment_made` de importe negativo 400 referenciando el pago
- **AND** el saldo del proveedor baja en 400 en el mismo commit

#### Scenario: Un fallo posterior revierte también el movimiento de caja

- **GIVEN** un cobro en efectivo en curso cuyo movimiento de caja ya fue registrado
- **WHEN** un paso posterior de la misma transacción falla
- **THEN** no queda ni el cobro, ni el movimiento de cuenta corriente, ni el movimiento de caja

#### Scenario: La repetición de la clave de idempotencia no duplica el movimiento de caja

- **WHEN** se registra dos veces el mismo cobro en efectivo con la misma clave de idempotencia
- **THEN** existe un solo movimiento de caja
- **AND** la segunda llamada devuelve el resultado original marcado como repetición

### Requirement: Contra-movimiento de caja por borrado de una compra

El sistema SHALL registrar un contra-movimiento de tipo `purchase_payment_reversal` con importe positivo al borrar una compra que había descontado de la caja, dentro de la misma transacción del borrado, y SHALL NOT modificar ni eliminar el movimiento original, porque el ledger de caja es append-only.

El contra-movimiento SHALL registrarse contra la **sesión abierta actual de la misma caja**, con el mismo criterio que ya rige para el borrado de una venta en efectivo y para el de un gasto. Si no existe ninguna sesión abierta en esa caja, el borrado completo SHALL rechazarse con el código de error `P0426`, indicando que hay que abrir la caja para poder borrar la compra.

La compensación SHALL dispararse por la **existencia** de un movimiento de caja de la compra y SHALL NOT depender del signo de ese movimiento: el importe del contra-movimiento es el opuesto exacto de lo posteado. Condicionar el disparo al signo esperado haría que un movimiento con el signo contrario —llegado por cualquier camino— se saltee la compensación entera, no dispare el rechazo por falta de sesión abierta, y deje el borrado proceder igual.

La localización del movimiento original SHALL usar las mismas convenciones de referencia que el resto de la compensación de la operación, para que ninguna compra quede con su movimiento sin compensar por referenciar un identificador anterior.

#### Scenario: Compra con movimiento de caja y sesión abierta

- **GIVEN** una compra que descontó de la caja y una sesión abierta en esa misma caja
- **WHEN** se borra la compra
- **THEN** la sesión abierta registra un `purchase_payment_reversal` positivo por el mismo importe
- **AND** el movimiento original queda intacto
- **AND** la compra queda borrada

#### Scenario: La sesión original ya cerró

- **GIVEN** una compra cuyo egreso se registró en una sesión ya cerrada, y otra sesión abierta hoy en la misma caja
- **WHEN** se borra la compra
- **THEN** el contra-movimiento va a la sesión abierta de hoy
- **AND** el arqueo de la sesión cerrada no se altera

#### Scenario: No hay ninguna sesión abierta

- **GIVEN** una compra que descontó de la caja y ninguna sesión abierta en esa caja
- **WHEN** se intenta borrar la compra
- **THEN** la operación es rechazada con `P0426`
- **AND** la compra sigue existiendo, el stock no se revierte y ningún libro se altera

#### Scenario: El disparo de la compensación no depende del signo

- **GIVEN** una compra cuyo movimiento de caja quedó registrado con el signo contrario al esperado
- **WHEN** se borra la compra
- **THEN** la caja recibe igual su contra-movimiento por el importe opuesto
- **AND** el borrado no procede sin compensar

#### Scenario: Compra sin movimiento de caja

- **WHEN** se borra una compra que nunca descontó de la caja
- **THEN** el borrado procede sin registrar ningún contra-movimiento
- **AND** no se exige ninguna sesión abierta
