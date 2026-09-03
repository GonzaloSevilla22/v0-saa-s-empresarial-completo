# receivables-aging Specification

## Purpose
Plazo de pago en cascada (cuenta → cliente/proveedor, `NULL` = sin plazo, nunca 0), vencimiento congelado en la fila de cargo del ledger (`customer_account_movements`/`supplier_account_movements.due_date`), imputación FIFO derivada pura sobre las líneas de flotación —nunca escrita, siempre recalculada, con el invariante `SUM(abierto) = balance`— y aging en cinco tramos con un tramo propio "sin vencimiento" que nunca se pliega sobre "al día". Incluye el barrido diario (`pg_cron`, dedup por día argentino) que dispara las notificaciones y el email de deuda vencida, y el recordatorio manual por WhatsApp. Nace de `cobranzas-vencimientos` (2026-09-03), Etapa B del módulo de cobranzas: le da a `receivables-panel` (Etapa A, `cobranzas-panel`) el dato de vencimiento que le faltaba para dejar de decir "el sistema todavía no registra vencimientos".
## Requirements
### Requirement: Plazo de pago en cascada de tres niveles

El sistema SHALL permitir configurar un **plazo de pago en días** en tres niveles —un valor por defecto de la cuenta, y una excepción por cliente y por proveedor— y SHALL resolver el plazo efectivo de una parte tomando el de la parte cuando está definido y, en su defecto, el de la cuenta.

Los tres valores SHALL admitir la ausencia de valor, y la ausencia SHALL significar **"sin plazo de pago definido"**, nunca cero. Un plazo efectivo ausente SHALL producir un cargo **sin vencimiento**. El sistema NO SHALL asumir un plazo por omisión: instalar un plazo que ningún negocio eligió declararía vencida, de un día para el otro, deuda real que nadie pactó.

El valor cero SHALL ser válido y SHALL significar *contado a la vista* —el cargo vence el mismo día en que se postea—, distinguible de la ausencia de valor.

Un plazo negativo SHALL ser rechazado.

#### Scenario: El plazo de la parte gana sobre el de la cuenta

- **GIVEN** una cuenta con plazo por defecto de 30 días
- **AND** un cliente con plazo propio de 60 días
- **WHEN** se resuelve el plazo efectivo de ese cliente
- **THEN** es de 60 días

#### Scenario: El cliente sin plazo propio hereda el de la cuenta

- **GIVEN** una cuenta con plazo por defecto de 30 días
- **AND** un cliente sin plazo propio
- **WHEN** se resuelve el plazo efectivo de ese cliente
- **THEN** es de 30 días

#### Scenario: Sin plazo en ningún nivel no hay vencimiento

- **GIVEN** una cuenta sin plazo por defecto y un cliente sin plazo propio
- **WHEN** se postea un cargo a la cuenta corriente de ese cliente
- **THEN** el cargo queda sin vencimiento, y no se lo considera vencido en ningún momento futuro

#### Scenario: Plazo cero significa contado a la vista

- **GIVEN** un cliente con plazo propio de 0 días
- **WHEN** se postea un cargo hoy a su cuenta corriente
- **THEN** el vencimiento del cargo es hoy, y el cargo NO está vencido hoy

#### Scenario: Plazo negativo rechazado

- **WHEN** se intenta configurar un plazo de pago negativo en cualquiera de los tres niveles
- **THEN** la operación es rechazada y ningún valor queda persistido

#### Scenario: El proveedor tiene su propio plazo

- **GIVEN** una cuenta con plazo por defecto de 30 días y un proveedor con plazo propio de 15 días
- **WHEN** se postea un cargo por una compra a crédito a ese proveedor
- **THEN** el vencimiento se calcula con 15 días

### Requirement: El vencimiento se congela en la fila de cargo del ledger

El sistema SHALL persistir el vencimiento **en la fila del movimiento de cargo** de la cuenta corriente, resuelto y escrito en el mismo `INSERT` que crea el movimiento, y NO SHALL recalcularlo en lecturas posteriores.

El vencimiento es un hecho pactado el día de la operación, no una función del presente: cambiar el plazo de pago de una parte NO SHALL alterar el vencimiento de ningún cargo ya posteado. La ausencia de vencimiento SHALL ser representable y SHALL persistir como tal.

La incorporación del vencimiento NO SHALL alterar la naturaleza append-only del ledger: la fila SHALL escribirse una sola vez y NO SHALL actualizarse después. El saldo materializado de la cabecera NO SHALL verse afectado por este dato.

#### Scenario: El vencimiento se escribe con el cargo

- **GIVEN** un cliente con plazo efectivo de 30 días
- **WHEN** se postea un cargo por una venta a crédito el día D
- **THEN** el movimiento de cargo queda con vencimiento en D+30

#### Scenario: Cambiar el plazo no reescribe la deuda pasada

- **GIVEN** un cargo posteado con vencimiento en D+30
- **WHEN** se cambia el plazo de pago del cliente a 60 días
- **THEN** el vencimiento del cargo ya posteado sigue siendo D+30
- **AND** un cargo nuevo del mismo cliente vence a los 60 días

#### Scenario: Los cargos históricos quedan sin vencimiento

- **GIVEN** cargos posteados antes de que existiera el concepto de vencimiento
- **WHEN** se consulta su vencimiento
- **THEN** es ausente, y ninguna migración les asigna uno retroactivamente

#### Scenario: El movimiento sigue sin poder actualizarse

- **WHEN** se intenta modificar el vencimiento de un movimiento ya persistido
- **THEN** la operación es denegada, igual que cualquier otra actualización sobre el ledger

### Requirement: El vencimiento puede fijarse explícitamente en la venta a crédito

El sistema SHALL aceptar, en el alta de una operación a crédito, un vencimiento explícito que SHALL prevalecer sobre el resuelto por la cascada de plazos. Cuando no se informa vencimiento explícito, el sistema SHALL resolverlo por la cascada.

Un vencimiento explícito **anterior a la fecha del cargo** SHALL ser rechazado con el código de error de payload inválido, sin dejar operación ni movimiento: un cargo no puede vencer antes de existir. Un vencimiento anterior a hoy pero posterior a la fecha del cargo SHALL aceptarse — registrar hoy una operación de días atrás cuyo vencimiento ya se cumplió es legítimo.

#### Scenario: El vencimiento explícito gana

- **GIVEN** un cliente con plazo efectivo de 30 días
- **WHEN** se registra una venta a crédito informando un vencimiento a 7 días
- **THEN** el cargo queda con el vencimiento a 7 días y no con el de 30

#### Scenario: Sin vencimiento explícito se usa la cascada

- **GIVEN** un cliente con plazo efectivo de 30 días
- **WHEN** se registra una venta a crédito sin informar vencimiento
- **THEN** el cargo queda con vencimiento a 30 días de la fecha del cargo

#### Scenario: Vencimiento anterior al cargo rechazado

- **WHEN** se registra una venta a crédito con fecha de operación D y vencimiento anterior a D
- **THEN** la operación falla con el error de payload inválido, y no queda ni la venta ni el movimiento de cuenta corriente

#### Scenario: Vencimiento ya cumplido pero posterior al cargo

- **WHEN** se registra hoy una venta con fecha de operación de hace 10 días y vencimiento de hace 3 días
- **THEN** la operación se registra, y el cargo queda vencido desde hace 3 días

### Requirement: La imputación de cobros es una derivación FIFO, no un estado almacenado

El sistema SHALL determinar qué parte de cada cargo permanece abierta **derivándola del ledger** en el momento de la consulta, y NO SHALL almacenar la imputación de cobros a cargos en ninguna tabla ni columna.

La derivación SHALL funcionar por línea de flotación: los cargos se ordenan del más viejo al más nuevo y el crédito disponible los cancela en ese orden, quedando parcialmente abierto aquel donde el crédito se agota y enteramente abiertos los posteriores.

SHALL considerarse **cargo** —y por lo tanto susceptible de estar abierto y vencido— el movimiento de venta (o de compra, del lado proveedor) y el ajuste de importe positivo. Todo otro movimiento SHALL contribuir al crédito disponible **con su propio signo**, de modo que un cobro y una nota de crédito lo aumentan y la anulación de un cobro lo disminuye.

La anulación de un cobro NO SHALL crear un cargo nuevo: SHALL reducir el crédito disponible, con lo que los cargos que ese cobro había cancelado vuelven a abrirse en orden inverso al que se cerraron. Tratar la anulación como un cargo propio produciría un ítem abierto fechado el día de la anulación, rejuveneciendo la deuda.

La derivación SHALL satisfacer el **invariante de cierre**: la suma de los importes abiertos de todos los cargos de una cuenta corriente SHALL ser exactamente igual al saldo materializado de esa cuenta, cualquiera sea la combinación de tipos de movimiento presentes.

#### Scenario: Un cobro cancela el cargo más viejo

- **GIVEN** una cuenta corriente con un cargo de 1000 del día D y otro de 500 del día D+5
- **WHEN** se registra un cobro de 1000
- **THEN** el cargo del día D queda con importe abierto 0 y el del día D+5 queda abierto por 500

#### Scenario: Un cobro parcial deja un cargo parcialmente abierto

- **GIVEN** una cuenta corriente con un único cargo de 1000
- **WHEN** se registra un cobro de 400
- **THEN** ese cargo queda con importe abierto 600

#### Scenario: Anular un cobro reabre los cargos que había cancelado

- **GIVEN** una cuenta con cargos de 1000 y 500, y un cobro de 1200 ya imputado
- **WHEN** se anula ese cobro
- **THEN** el cargo de 1000 vuelve a estar abierto por 1000 y el de 500 por 500

#### Scenario: Una nota de crédito consume como un cobro

- **GIVEN** una cuenta con un cargo de 1000 y otro de 500, ambos abiertos
- **WHEN** se registra una nota de crédito de 1000
- **THEN** el cargo más viejo queda con importe abierto 0

#### Scenario: El invariante de cierre se sostiene

- **GIVEN** una cuenta corriente con cualquier secuencia de cargos, cobros, notas y anulaciones
- **WHEN** se derivan los importes abiertos de todos sus cargos
- **THEN** su suma es exactamente igual al saldo materializado de la cuenta corriente

#### Scenario: Un tipo de movimiento no previsto no descuadra el invariante

- **GIVEN** una cuenta corriente que contiene un movimiento de un tipo que no está clasificado como cargo
- **WHEN** se derivan los importes abiertos
- **THEN** ese movimiento contribuye al crédito disponible con su signo, no genera un ítem abierto propio, y el invariante de cierre se sigue cumpliendo

### Requirement: El orden de imputación y la clasificación por tramo son reglas distintas

El sistema SHALL usar, para **imputar**, un orden cronológico que tome el vencimiento del cargo cuando existe y su fecha de posteo cuando no, de modo que los cargos más antiguos —incluidos los que no tienen vencimiento— se cancelen primero.

El sistema SHALL clasificar por tramo de antigüedad **únicamente** los cargos que tienen vencimiento. Un cargo sin vencimiento NO SHALL considerarse vencido por antiguo que sea, y SHALL clasificarse siempre en un tramo propio de "sin vencimiento".

Las dos reglas SHALL mantenerse separadas: unificarlas produciría, o bien que los cargos sin vencimiento nunca se cobren, o bien que deuda para la que nadie pactó un plazo aparezca vencida.

#### Scenario: Un cargo sin vencimiento se cobra primero por ser el más viejo

- **GIVEN** una cuenta con un cargo sin vencimiento del día D y un cargo con vencimiento del día D+10
- **WHEN** se registra un cobro que alcanza para uno solo
- **THEN** el cargo del día D queda cancelado y el del día D+10 sigue abierto

#### Scenario: Un cargo sin vencimiento nunca está vencido

- **GIVEN** un cargo sin vencimiento posteado hace 200 días y todavía abierto
- **WHEN** se clasifica por tramo de antigüedad
- **THEN** cae en el tramo de "sin vencimiento" y no en ninguno de los tramos de vencido

### Requirement: Los tramos de antigüedad se computan en día calendario argentino y suman el saldo

El sistema SHALL clasificar el importe abierto de cada cargo en uno de cinco tramos —al día, vencido de 1 a 30 días, vencido de 31 a 60 días, vencido más de 60 días, y sin vencimiento— computando los días de atraso como la diferencia entre el día de hoy y el vencimiento del cargo.

El día de hoy SHALL obtenerse en día calendario `America/Argentina/Mendoza` conforme al canon de la plataforma, y NO SHALL derivarse del huso del servidor ni del dispositivo. Un cargo cuyo vencimiento es hoy SHALL estar **al día**, no vencido.

Los cinco tramos SHALL ser exhaustivos y mutuamente excluyentes, y su suma SHALL ser igual al saldo de la cuenta corriente. El tramo "sin vencimiento" NO SHALL plegarse sobre el de "al día": afirmar que una parte está al día sobre deuda cuyo plazo nadie pactó es una afirmación que el sistema no puede sostener.

#### Scenario: Vencimiento hoy no está vencido

- **GIVEN** un cargo abierto cuyo vencimiento es hoy
- **WHEN** se clasifica por tramo
- **THEN** cae en el tramo "al día"

#### Scenario: Frontera del primer tramo de vencido

- **GIVEN** un cargo abierto cuyo vencimiento fue ayer
- **WHEN** se clasifica por tramo
- **THEN** cae en el tramo de vencido de 1 a 30 días

#### Scenario: Fronteras de los tramos siguientes

- **GIVEN** tres cargos abiertos vencidos hace 30, 31 y 61 días
- **WHEN** se clasifican por tramo
- **THEN** caen respectivamente en 1-30, en 31-60 y en más de 60

#### Scenario: Los tramos suman el saldo

- **GIVEN** una cuenta corriente con saldo 9000 repartido en cargos de distintos vencimientos
- **WHEN** se suman los cinco tramos
- **THEN** el resultado es 9000

#### Scenario: Vencimiento en la franja nocturna

- **WHEN** se evalúa un cargo cuyo vencimiento es hoy, siendo las 22:00 hora argentina (ya el día siguiente en tiempo universal)
- **THEN** el cargo se clasifica como al día, porque el día de referencia es el día calendario argentino

### Requirement: Aviso diario de deuda vencida, resumido y deduplicado por día

El sistema SHALL ejecutar un barrido diario que, por cada cuenta con importe vencido mayor que cero, produzca **un único aviso resumido** dirigido a la administración de esa cuenta, indicando la cantidad de partes con deuda vencida y el importe total vencido.

El aviso SHALL emitirse por **dos canales** —notificación en la aplicación y correo electrónico— con una **única deduplicación** que cubra ambos: el registro de correo SHALL insertarse primero, y el evento que produce la notificación SHALL crearse únicamente para los registros de correo efectivamente insertados.

La unidad de deduplicación SHALL ser el **día calendario argentino**: dos ejecuciones del barrido en el mismo día NO SHALL producir un segundo aviso a la misma cuenta, aunque los importes hayan cambiado entre ambas.

El barrido SHALL producir un aviso por cada lado del circuito —deuda por cobrar y deuda por pagar— y ambos SHALL resolverse en la misma ejecución.

El barrido SHALL ser de solo lectura sobre los libros: NO SHALL alterar saldos, movimientos, cargos ni cobros, y NO SHALL emitir ningún evento que produzca un asiento contable.

Una cuenta sin importe vencido NO SHALL recibir aviso alguno.

#### Scenario: Aviso resumido con la cifra agregada

- **GIVEN** una cuenta con 3 clientes con deuda vencida por 45000 en total
- **WHEN** corre el barrido diario
- **THEN** se produce un único aviso para esa cuenta que informa 3 partes y 45000

#### Scenario: Un aviso, dos canales, una deduplicación

- **WHEN** el barrido produce el aviso de una cuenta
- **THEN** se registra un correo y se emite un evento de notificación para esa misma cuenta
- **AND** el evento se emite únicamente porque el registro de correo fue insertado

#### Scenario: Dos corridas el mismo día no duplican

- **GIVEN** que el barrido ya avisó hoy a una cuenta
- **WHEN** el barrido vuelve a ejecutarse el mismo día, incluso con un importe vencido distinto
- **THEN** no se produce ningún aviso adicional para esa cuenta

#### Scenario: Al día siguiente vuelve a avisar

- **GIVEN** una cuenta que recibió el aviso ayer y sigue con deuda vencida
- **WHEN** corre el barrido al día siguiente
- **THEN** recibe un aviso nuevo

#### Scenario: Sin deuda vencida no hay aviso

- **GIVEN** una cuenta cuya deuda está toda al día o sin vencimiento
- **WHEN** corre el barrido
- **THEN** no se produce ningún aviso para esa cuenta

#### Scenario: Deuda por pagar avisada por el mismo barrido

- **GIVEN** una cuenta con deuda vencida con proveedores
- **WHEN** corre el barrido
- **THEN** produce también su aviso de deuda por pagar, en la misma ejecución

#### Scenario: El barrido no toca los libros

- **WHEN** corre el barrido
- **THEN** ningún saldo de cuenta corriente, movimiento, cobro ni pago resulta creado o modificado
- **AND** no se genera ningún asiento contable

### Requirement: Configuración del plazo por defecto reservada a quien puede escribir en la cuenta

El sistema SHALL exponer la configuración del plazo de pago por defecto de la cuenta a través de una operación que valide, antes de escribir, que quien la invoca tiene permiso de escritura sobre esa cuenta, rechazando en caso contrario con el código de negocio de falta de permiso.

El plazo por defecto es política comercial del negocio y su cambio afecta el vencimiento de toda la deuda futura, de modo que NO SHALL ser modificable por cualquier miembro sin permiso de escritura ni por el rol anónimo.

#### Scenario: Un miembro con permiso configura el plazo

- **WHEN** un usuario con permiso de escritura sobre la cuenta fija el plazo por defecto en 30 días
- **THEN** el valor queda persistido para esa cuenta

#### Scenario: Un usuario de otra cuenta no puede configurarlo

- **WHEN** un usuario que no es miembro de la cuenta intenta fijar su plazo por defecto
- **THEN** la operación es rechazada con el código de falta de permiso y ningún valor cambia

#### Scenario: El rol anónimo no puede ejecutarla

- **WHEN** se inspeccionan los permisos de la operación de configuración
- **THEN** el rol anónimo no tiene permiso de ejecución

### Requirement: Superficie de configuración del plazo de pago

El sistema SHALL ofrecer al usuario una superficie para configurar el plazo de pago por defecto de la cuenta dentro de la pantalla de Configuración, y un campo de plazo de pago propio en el formulario de alta y edición de clientes y en el de proveedores.

El campo por parte SHALL admitir quedar vacío, y el vacío SHALL presentarse como "usa el plazo de la cuenta", no como cero. La edición de un cliente o de un proveedor que **no** informe el plazo NO SHALL borrar el plazo ya configurado: la omisión de un campo en una edición parcial no es una instrucción de vaciarlo.

Cuando la cuenta no tiene plazo por defecto configurado, la superficie de cobranzas SHALL explicarlo y SHALL ofrecer el acceso a configurarlo, en lugar de mostrar la ausencia de vencimientos como si fuera un estado normal sin explicación.

#### Scenario: Configurar el plazo por defecto

- **WHEN** el usuario abre la sección de cobranzas de la pantalla de Configuración y fija el plazo por defecto en 30 días
- **THEN** el valor queda guardado para la cuenta y los cargos nuevos lo usan

#### Scenario: Plazo propio del cliente

- **WHEN** el usuario edita un cliente y fija su plazo de pago en 60 días
- **THEN** los cargos nuevos de ese cliente vencen a los 60 días

#### Scenario: Campo vacío significa heredar

- **WHEN** el usuario mira el campo de plazo de un cliente que no tiene plazo propio
- **THEN** el campo está vacío y se explica que usa el plazo de la cuenta, sin mostrar cero

#### Scenario: Editar sin informar el plazo no lo borra

- **GIVEN** un cliente con plazo propio de 60 días
- **WHEN** se edita ese cliente cambiando sólo su teléfono, sin informar el plazo
- **THEN** el plazo del cliente sigue siendo 60 días

#### Scenario: Sin plazo configurado la pantalla lo explica

- **GIVEN** una cuenta sin plazo por defecto y sin plazos por cliente
- **WHEN** el usuario abre la pantalla de cobranzas
- **THEN** se le explica que todavía no hay vencimientos configurados y se le ofrece el acceso a configurarlos

