## MODIFIED Requirements

### Requirement: Tipos de movimiento enumerados
El sistema SHALL aceptar únicamente `movement_type` dentro del conjunto `{'sale', 'purchase_payment', 'expense', 'advance', 'withdrawal', 'sale_reversal', 'expense_reversal', 'purchase_payment_reversal', 'payment_received', 'payment_made', 'payment_received_reversal', 'payment_made_reversal', 'adjustment'}`, validado por CHECK en la columna. `sale`, `advance`, `expense_reversal`, `purchase_payment_reversal`, `payment_received` y `payment_made_reversal` son ingresos (signo positivo esperado); `purchase_payment`, `expense`, `withdrawal`, `sale_reversal`, `payment_made` y `payment_received_reversal` son egresos (signo negativo esperado); `adjustment` admite ambos signos (positivo = sobrante, negativo = faltante). El signo SHALL viajar en `amount` (el llamador lo provee), y el CHECK del enum SHALL validar solo la pertenencia al conjunto. Adicionalmente, un CHECK SHALL exigir que todo movimiento de tipo `adjustment` lleve `description` no vacía, sin imponer esa exigencia a los demás tipos.

#### Scenario: Tipo inválido es rechazado
- **GIVEN** una sesión `open`
- **WHEN** se intenta registrar un movimiento con `movement_type = 'tip'`
- **THEN** la inserción falla por violación del CHECK del enum

#### Scenario: El enum incluye los trece tipos
- **WHEN** se inspecciona el CHECK de `cash_movements.movement_type`
- **THEN** incluye los 13 tipos `sale`, `purchase_payment`, `expense`, `advance`, `withdrawal`, `sale_reversal`, `expense_reversal`, `purchase_payment_reversal`, `payment_received`, `payment_made`, `payment_received_reversal`, `payment_made_reversal`, `adjustment`

#### Scenario: El enum incluye expense_reversal como ingreso
- **WHEN** se valida un movimiento `expense_reversal` con importe negativo por el camino de la API
- **THEN** es rechazado, porque la reversión de un egreso es un ingreso y exige signo positivo

#### Scenario: La reversión de una compra en efectivo es un ingreso
- **WHEN** se valida un movimiento `purchase_payment_reversal` con importe negativo por el camino de la API
- **THEN** es rechazado, porque revertir el pago de una compra repone el efectivo en el cajón

#### Scenario: El cobro de una cuenta corriente es un ingreso y el pago a un proveedor un egreso
- **WHEN** se valida un movimiento `payment_received` con importe negativo, o un `payment_made` con importe positivo, por el camino de la API
- **THEN** ambos son rechazados por signo incoherente con su tipo

#### Scenario: Las dos reversas de pago tienen signos opuestos entre sí
- **WHEN** se valida un movimiento `payment_received_reversal` con importe positivo, o un `payment_made_reversal` con importe negativo, por el camino de la API
- **THEN** ambos son rechazados: anular un cobro saca dinero del cajón y anular un pago lo repone

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
- **WHEN** se amplía el CHECK con `payment_received_reversal` y `payment_made_reversal`
- **THEN** ninguna fila existente es invalidada ni reescrita
- **AND** la ampliación es idempotente ante una reaplicación de la migración

### Requirement: Vocabulario de tipos de movimiento de caja
El catálogo de tipos de movimiento de caja SHALL admitir `sale_reversal`, `expense_reversal`, `purchase_payment_reversal`, `payment_received_reversal` y `payment_made_reversal` como tipos propios, distinguibles de los retiros, de los egresos operativos y de los ajustes manuales en los reportes de caja, y SHALL distinguir además el pago de una compra al contado (`purchase_payment`) de la cancelación de una deuda de cuenta corriente con un proveedor (`payment_made`), y el cobro de una cuenta corriente (`payment_received`) de una venta del día (`sale`). Cada contra-movimiento automático SHALL tener su tipo propio en lugar de reutilizar `adjustment`, que está reservado para la corrección manual y exige motivo.

La clasificación por **signo** y la clasificación por **familia de la superficie** SHALL tratarse como dos taxonomías distintas: los cinco contra-movimientos automáticos comparten la familia de reversiones y no comparten signo entre sí, porque revertir una venta o un cobro saca dinero de la caja mientras que revertir un gasto, una compra o un pago a proveedor lo repone.

La anulación de un cobro y la anulación de un pago a proveedor SHALL tener **etiquetas propias y distintas entre sí**, por el mismo motivo por el que lo tienen los hechos que revierten: en el historial de caja son dos movimientos de signo opuesto y confundirlos impediría entender el arqueo.

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

#### Scenario: Las dos anulaciones de pago no comparten etiqueta
- **WHEN** se lista una sesión que contiene un `payment_received_reversal` y un `payment_made_reversal`
- **THEN** el primero se identifica como anulación de cobro y el segundo como anulación de pago
- **AND** el primero es un egreso y el segundo un ingreso

#### Scenario: La superficie de caja nombra los tipos nuevos
- **WHEN** se muestra el historial de una caja que contiene una reversión de compra, un cobro, un pago y las anulaciones de esos dos últimos
- **THEN** cada movimiento tiene etiqueta e ícono propios
- **AND** las cinco reversiones caen dentro del filtro de reversas
- **AND** el cobro cae dentro del filtro de ingresos y el pago dentro del de egresos
- **AND** todos usan los tonos semánticos del design system

#### Scenario: El cambio de etiqueta no reescribe filas
- **WHEN** se aplica el cambio de etiqueta de `purchase_payment`
- **THEN** ninguna fila de `cash_movements` es modificada

## ADDED Requirements

### Requirement: Contra-movimiento de caja por anulación de un cobro o de un pago de cuenta corriente

El sistema SHALL registrar, al anular un cobro o un pago de cuenta corriente que había movido la caja, un contra-movimiento por el importe **exactamente opuesto** al registrado, de tipo `payment_received_reversal` o `payment_made_reversal` según corresponda, con referencia al pago anulado.

El contra-movimiento SHALL registrarse contra la **sesión abierta actual de la misma caja** que recibió el movimiento original, y SHALL NOT modificar la sesión original. Cuando no hay sesión abierta en esa caja, el sistema SHALL rechazar la anulación entera con `P0426` en lugar de proceder sin compensar.

La compensación SHALL dispararse por la **existencia** del movimiento de caja del pago —evaluada como importe agregado distinto de cero sobre los movimientos del tipo del alta—, y SHALL NOT condicionarse a que ese importe tenga un signo determinado. Un guard de signo dejaría pasar el borrado del documento sin compensar la caja y sin levantar ningún error.

El motivo de la anulación, cuando se informa, SHALL viajar como descripción del contra-movimiento.

#### Scenario: Anulación de un cobro en efectivo saca el dinero del cajón

- **GIVEN** un cobro de 400 en efectivo con su movimiento `payment_received` de `+400`
- **WHEN** se anula
- **THEN** existe un `payment_received_reversal` de `−400` en la sesión abierta actual de la misma caja
- **AND** el movimiento original permanece intacto en su sesión

#### Scenario: Anulación de un pago a proveedor en efectivo repone el dinero

- **GIVEN** un pago de 400 en efectivo con su movimiento `payment_made` de `−400`
- **WHEN** se anula
- **THEN** existe un `payment_made_reversal` de `+400` en la sesión abierta actual de la misma caja

#### Scenario: Sin sesión abierta la anulación se rechaza entera

- **GIVEN** un cobro con movimiento de caja y ninguna sesión abierta en esa caja
- **WHEN** se intenta anular
- **THEN** la operación falla con `P0426`
- **AND** no se registra ningún contra-movimiento en ningún libro
- **AND** el documento del cobro sigue existiendo

#### Scenario: El disparo no depende del signo del movimiento original

- **GIVEN** un cobro cuyo movimiento de caja quedó registrado con signo contrario al esperado para su tipo
- **WHEN** se anula
- **THEN** el contra-movimiento se registra igual, por el importe opuesto al registrado
- **AND** la anulación no procede jamás dejando la caja sin compensar

#### Scenario: Un pago sin movimiento de caja no exige sesión abierta

- **GIVEN** un cobro bancario, sin ningún movimiento de caja
- **WHEN** se anula estando todas las cajas cerradas
- **THEN** la anulación procede normalmente y no se registra ningún movimiento de caja
