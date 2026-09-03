# receivables-panel Specification

## Purpose
Read-model agregado de cuentas por cobrar y por pagar que responde "¿quién le debe a la cuenta y cuánto?" sin recorrer cliente por cliente: `rpc_receivables_report`/`rpc_payables_report` devuelven una fila por deudor con saldo materializado, antigüedad derivada del ledger y (desde `cobranzas-vencimientos`) tramo de vencimiento; pantalla `/cobranzas` con las dos caras Por cobrar / Por pagar, KPI "Por cobrar" en el Tablero, columna de saldo y acceso a la cuenta corriente por fila en `/clientes`, cobro en línea reutilizando el flujo existente (`RegisterPaymentForm`), filtro por estado de vencimiento y recordatorio de deuda por WhatsApp. Entregado en dos etapas: `cobranzas-panel` (2026-09-02) construyó la visibilidad agregada sin vencimientos; `cobranzas-vencimientos` (2026-09-03) sumó el estado de vencimiento, el filtro por tramo, la pestaña Por pagar y el recordatorio, retirando la prohibición original de mostrar mora que dejó de aplicar una vez que el sistema pasó a tener vencimientos reales.
## Requirements
### Requirement: Read-model agregado de cuentas por cobrar

El sistema SHALL exponer un read-model agregado de las cuentas corrientes con deuda viva de la cuenta, que devuelva una fila por cliente deudor con su identificador, su nombre, su saldo, la antigüedad de su último cargo, la de su último cobro, **su importe vencido, el reparto de su saldo en los cinco tramos de antigüedad y el vencimiento más antiguo que tiene abierto**, resueltos en una sola consulta a la base de datos.

Los tramos SHALL derivarse del mismo read-model que produce el saldo, y NO SHALL calcularse en una función separada con su propio predicado de "quién es deudor": una segunda definición del predicado es lo que hace que el total de la cabecera deje de cerrar contra los tramos de la tabla que tiene al lado.

El read-model SHALL implementarse como una función `SECURITY DEFINER` que reciba el identificador de la cuenta y valide, **como primera acción y antes de leer dato alguno**, que quien la invoca es miembro de esa cuenta, rechazando con el código de negocio `P0401` en caso contrario. La función NO SHALL ser ejecutable por el rol anónimo: sus permisos SHALL revocarse de `PUBLIC` y de `anon` y otorgarse explícitamente al rol autenticado **en el mismo archivo de migración** que la define.

El sistema SHALL exponer un read-model **espejo para la deuda por pagar** con proveedores, con la misma forma, los mismos tramos y las mismas garantías de tenencia y de permisos.

Ambos read-models son de **solo lectura**: NO SHALL insertar, actualizar ni borrar ninguna fila, ni emitir ningún evento.

#### Scenario: Un deudor aparece con su saldo y su nombre

- **GIVEN** un cliente de la cuenta con saldo 12000 en su cuenta corriente
- **WHEN** se consulta el read-model de cuentas por cobrar
- **THEN** el cliente aparece con su nombre y un saldo de 12000

#### Scenario: Un deudor trae su reparto por tramos

- **GIVEN** un cliente con 1000 vencidos hace 10 días, 500 vencidos hace 40 y 300 que vencen la semana próxima
- **WHEN** se consulta el read-model
- **THEN** su fila informa 1500 de importe vencido, 1000 en el tramo de 1 a 30 días, 500 en el de 31 a 60, 300 al día y 0 en el de más de 60

#### Scenario: Los tramos cierran contra el saldo de la fila

- **WHEN** se consulta cualquier fila del read-model
- **THEN** la suma de sus cinco tramos es igual a su saldo

#### Scenario: Un no miembro es rechazado

- **WHEN** un usuario que no es miembro de la cuenta invoca el read-model con el identificador de esa cuenta
- **THEN** la operación falla con `P0401` y no devuelve ninguna fila

#### Scenario: El rol anónimo no puede ejecutarlo

- **WHEN** se inspeccionan los permisos de la función del read-model
- **THEN** el rol anónimo no tiene permiso de ejecución y el rol autenticado sí

#### Scenario: La consulta no escribe nada

- **WHEN** se consulta el read-model
- **THEN** no se crea ni se modifica ninguna fila en `customer_accounts`, `customer_account_movements`, `payments_received` ni `events`

#### Scenario: El espejo de proveedores tiene la misma forma

- **GIVEN** un proveedor con saldo a favor de 8000, de los cuales 3000 están vencidos
- **WHEN** se consulta el read-model de cuentas por pagar
- **THEN** el proveedor aparece con su nombre, su saldo, su importe vencido y su reparto por tramos, con las mismas garantías de tenencia y de permisos que el de cuentas por cobrar

### Requirement: Sólo el cliente vigente con deuda viva entra en el read-model

El sistema SHALL incluir en el read-model únicamente las cuentas corrientes con saldo estrictamente mayor que cero cuyo cliente no esté dado de baja. Un cliente al día (saldo cero) NO SHALL aparecer, y un cliente dado de baja NO SHALL aparecer aunque su saldo sea positivo.

La exclusión del cliente dado de baja es coherente con el listado de clientes, que tampoco lo muestra: un deudor que la aplicación no lista no es accionable. La consecuencia SHALL declararse en lugar de quedar tácita — el panel oculta esa deuda, no la resuelve.

#### Scenario: Cliente al día

- **GIVEN** un cliente con cuenta corriente y saldo 0
- **WHEN** se consulta el read-model
- **THEN** ese cliente no aparece

#### Scenario: Cliente sin cuenta corriente

- **GIVEN** un cliente que nunca compró a crédito y no tiene cuenta corriente
- **WHEN** se consulta el read-model
- **THEN** ese cliente no aparece

#### Scenario: Cliente dado de baja con deuda

- **GIVEN** un cliente dado de baja cuya cuenta corriente tiene saldo 5000
- **WHEN** se consulta el read-model
- **THEN** ese cliente no aparece, igual que no aparece en el listado de clientes

#### Scenario: Sólo los deudores de la propia cuenta

- **GIVEN** deudores en dos cuentas distintas
- **WHEN** un miembro de la primera consulta el read-model
- **THEN** sólo ve los deudores de su cuenta

### Requirement: La antigüedad se deriva de tipos de movimiento explícitos y en día calendario argentino

El sistema SHALL derivar la antigüedad del último cargo de cada deudor a partir **exclusivamente** de los movimientos de tipo `sale` de su cuenta corriente, y la antigüedad del último cobro **exclusivamente** de los de tipo `payment_received`.

`payment_received_reversal` NO SHALL contar como cobro: deshace uno, de modo que contarlo haría que anular un cobro rejuveneciera la deuda en la pantalla. `credit_note` y `adjustment` NO SHALL contar como cargo: el primero revierte un cargo y el segundo es corrección manual.

Los días SHALL computarse en día calendario `America/Argentina/Mendoza` conforme al canon `business-day-timezone`, con el día de referencia obtenido de `reporting_local_today()`. El sistema NO SHALL derivarlos de restas sobre `now()` ni del huso del servidor o del dispositivo.

Cuando no existe ningún movimiento del tipo correspondiente, el derivado SHALL ser nulo, y la superficie SHALL mostrar la ausencia como tal y NO SHALL mostrar cero: un cliente que nunca pagó no pagó hoy.

#### Scenario: Días desde el último cargo

- **GIVEN** un deudor cuyo último movimiento de tipo `sale` ocurrió hace 12 días argentinos
- **WHEN** se consulta el read-model
- **THEN** su antigüedad de último cargo es 12

#### Scenario: Anular un cobro no rejuvenece la deuda

- **GIVEN** un deudor cuyo último cobro fue hace 30 días y que hoy tiene ese cobro anulado
- **WHEN** se consulta el read-model
- **THEN** su antigüedad de último cobro sigue siendo la del cobro original y no se reinicia por la reversa

#### Scenario: Un ajuste no cuenta como cargo

- **GIVEN** un deudor cuya deuda proviene únicamente de un movimiento de tipo `adjustment`
- **WHEN** se consulta el read-model
- **THEN** aparece con su saldo y con la antigüedad de último cargo nula

#### Scenario: Cargo en la franja nocturna

- **WHEN** el último cargo de un deudor se registró a las 22:00 hora argentina del día D (01:00 UTC del día D+1)
- **THEN** el cálculo de días toma el día D como fecha de ese cargo

#### Scenario: Deudor que nunca pagó

- **GIVEN** un deudor sin ningún movimiento de tipo `payment_received`
- **WHEN** se muestra su fila en el panel
- **THEN** la antigüedad de último cobro se presenta como ausente y no como cero

### Requirement: El listado de deudores se pagina y se ordena en el servidor

El sistema SHALL exponer el read-model de deudores como un listado HTTP con el contrato de paginación estándar de la plataforma (`?page&size` con envelope `{items, total, page, pages}`), donde `total` es la **cantidad de deudores** y no un importe.

El criterio de orden SHALL resolverse **en el servidor**, dentro de la misma consulta que produce la página, y SHALL aceptarse por parámetro acotado a un dominio cerrado de criterios, traducido a columna por correspondencia y nunca por interpolación de texto. El frontend NO SHALL reordenar la página recibida: con paginación del lado del servidor, ordenar sólo la página visible le mentiría al usuario sobre quién debe más.

El orden predeterminado SHALL ser por saldo descendente.

#### Scenario: Envelope estándar

- **WHEN** se pide la primera página del listado de deudores con tamaño 25
- **THEN** la respuesta es `{items, total, page, pages}` con a lo sumo 25 elementos y `total` igual a la cantidad de deudores

#### Scenario: Orden predeterminado por saldo

- **WHEN** se pide el listado sin especificar criterio de orden
- **THEN** los deudores vienen ordenados por saldo de mayor a menor

#### Scenario: Orden por antigüedad del último cobro

- **WHEN** el usuario ordena por antigüedad del último cobro
- **THEN** el orden se resuelve en el servidor sobre el conjunto completo, no sobre la página visible

#### Scenario: Criterio de orden fuera del dominio

- **WHEN** se solicita el listado con un criterio de orden que no pertenece al dominio aceptado
- **THEN** la petición se rechaza con el error de validación estándar de la plataforma y no se ejecuta ninguna consulta

#### Scenario: Página fuera de rango

- **WHEN** se pide una página mayor que el total de páginas
- **THEN** la respuesta es exitosa con la lista vacía, el total correcto y la paginación consistente

### Requirement: El total por cobrar se deriva del mismo predicado que la lista

El sistema SHALL exponer un resumen agregado con el **importe total por cobrar** y la **cantidad de deudores**, derivado del mismo read-model que produce la lista y NO de un predicado propio.

Una segunda definición de "quién es deudor" SHALL considerarse un defecto: es lo que hace que el total de la cabecera deje de cerrar contra la suma de la tabla el día que una de las dos cambie.

El importe total NO SHALL viajar dentro del envelope de paginación del listado, cuyo campo `total` designa una cantidad de filas.

#### Scenario: El total cierra contra la lista

- **GIVEN** tres deudores con saldos 1000, 2500 y 400
- **WHEN** se consulta el resumen
- **THEN** el importe total por cobrar es 3900 y la cantidad de deudores es 3
- **AND** ese importe coincide con la suma de los saldos de todas las páginas del listado

#### Scenario: Sin deudores

- **WHEN** se consulta el resumen de una cuenta sin ningún deudor
- **THEN** el importe total por cobrar es 0 y la cantidad de deudores es 0

#### Scenario: El resumen respeta las mismas exclusiones

- **GIVEN** un cliente dado de baja con saldo 5000 y un cliente vigente con saldo 1000
- **WHEN** se consulta el resumen
- **THEN** el importe total por cobrar es 1000

### Requirement: Pantalla de cobranzas alcanzable desde el menú

El sistema SHALL exponer una pantalla de cobranzas en la ruta `/cobranzas`, alcanzable desde una entrada propia del menú lateral en el grupo de **Operaciones**, junto a Caja y Banco.

La ubicación es deliberada: la cobranza es una tarea diaria del negocio —abrir, mirar, llamar, cobrar—, no un reporte que se consulta para decidir. La entrada NO SHALL estar restringida por plan, coherentemente con que la cuenta corriente está disponible en todos los planes.

La pantalla SHALL mostrar el total por cobrar en su cabecera y la tabla de deudores con, por fila, el nombre del cliente, el saldo, la antigüedad del último cargo y la del último cobro. Cada fila SHALL ofrecer acceso a la cuenta corriente del cliente. Cuando no hay deudores, la pantalla SHALL mostrar un estado vacío explicativo en lugar de una tabla sin filas.

La ruta SHALL tener nombre propio en el mapa del breadcrumb de la barra superior.

#### Scenario: Acceso desde el menú

- **WHEN** el usuario abre el menú lateral
- **THEN** existe una entrada de cobranzas en el grupo de Operaciones que lleva a `/cobranzas`

#### Scenario: Cabecera y tabla

- **GIVEN** una cuenta con tres deudores
- **WHEN** el usuario abre `/cobranzas`
- **THEN** la cabecera muestra el total por cobrar y la tabla lista los tres deudores con su saldo y sus antigüedades

#### Scenario: Acceso a la cuenta corriente desde la fila

- **WHEN** el usuario usa el acceso a la cuenta corriente de una fila
- **THEN** navega a la cuenta corriente de ese cliente

#### Scenario: Sin deudores

- **WHEN** el usuario abre `/cobranzas` en una cuenta sin deudores
- **THEN** ve un estado vacío que explica la situación, y no una tabla vacía ni un error

#### Scenario: Breadcrumb de la pantalla

- **WHEN** el usuario está en `/cobranzas`
- **THEN** el breadcrumb nombra la pantalla y no muestra únicamente el literal de marca

### Requirement: El cobro desde el panel reutiliza el flujo de cobro existente

El sistema SHALL ofrecer, en cada fila del panel de cobranzas, la acción de registrar un cobro, y esa acción SHALL abrir el **formulario de registro de cobro ya existente** sin declarar un formulario propio.

El panel es superficie de **lectura**: NO SHALL introducir ningún camino de escritura nuevo, ni modificar el comando de registro de cobro, ni alterar sus guards. La forma de pago del catálogo, la exigencia de cuenta bancaria para los `kind` bancarios, el impacto en caja pre-marcado y la idempotencia SHALL comportarse exactamente igual que en la cuenta corriente del cliente, porque son literalmente el mismo formulario.

#### Scenario: Cobrar desde una fila

- **GIVEN** un deudor con saldo 1000 listado en el panel
- **WHEN** el usuario usa la acción de cobrar de esa fila y registra un cobro de 400
- **THEN** el cobro se registra por el mismo camino que desde la cuenta corriente del cliente, y el saldo queda en 600

#### Scenario: El formulario es el mismo

- **WHEN** el usuario abre la acción de cobrar desde el panel
- **THEN** ve el selector de formas de pago del catálogo, el bloque de impacto en caja y el guard de cuenta bancaria, con el mismo comportamiento que en la cuenta corriente del cliente

#### Scenario: El panel no agrega guards propios

- **WHEN** se registra un cobro desde el panel que el servidor rechaza
- **THEN** el error que ve el usuario es el del comando de cobro, sin ninguna validación adicional introducida por el panel

### Requirement: El panel refleja todo cobro registrado, sea cual sea el camino

El sistema SHALL refrescar el panel de cobranzas y el total por cobrar ante cualquier mutación que altere un saldo de cuenta corriente —el registro de un cobro, su anulación y la venta a cuenta corriente por cualquiera de sus caminos—, y esa invalidación SHALL vivir en la capa compartida de la mutación y NO en la pantalla de cobranzas.

Ubicarla en la pantalla dejaría el panel y el indicador del Tablero mostrando una deuda ya cobrada cada vez que el cobro se registra desde la cuenta corriente del cliente o desde el mostrador, que es la mayoría de las veces.

#### Scenario: Cobro registrado desde la cuenta corriente del cliente

- **GIVEN** el panel de cobranzas abierto mostrando a un cliente con saldo 1000
- **WHEN** se registra un cobro de 1000 para ese cliente desde su cuenta corriente
- **THEN** el panel deja de listarlo y el total por cobrar se reduce en 1000, sin recargar la aplicación

#### Scenario: Cobro anulado

- **GIVEN** un cliente que salió del panel al saldar su deuda
- **WHEN** se anula ese cobro
- **THEN** el cliente vuelve a aparecer en el panel con su saldo repuesto

#### Scenario: Venta a cuenta corriente nueva

- **WHEN** se registra una venta a cuenta corriente para un cliente que no tenía deuda
- **THEN** el cliente aparece en el panel y el total por cobrar aumenta por el importe de la venta

### Requirement: El Tablero muestra el total por cobrar y lleva al panel

El Tablero SHALL mostrar el total por cobrar de la cuenta como un indicador de la grilla de indicadores del día, y ese indicador SHALL enlazar a la pantalla de cobranzas.

El indicador NO SHALL incorporarse al bloque de resumen mensual con variación contra el mes anterior: el total por cobrar es un **saldo al instante**, no un flujo del período, y una variación mensual sobre él compararía contra un saldo histórico que el sistema no almacena.

El indicador SHALL alimentarse del resumen agregado y NO SHALL requerir traer filas de deudores que no se van a mostrar. NO SHALL verse afectado por el filtro de sucursal del Tablero: la cuenta corriente no referencia sucursal, y filtrarla exigiría repartir el saldo entre las ventas que lo formaron.

#### Scenario: Total visible en el Tablero

- **GIVEN** una cuenta con 3900 por cobrar
- **WHEN** el usuario abre el Tablero
- **THEN** ve un indicador con el total por cobrar

#### Scenario: El indicador lleva al panel

- **WHEN** el usuario activa el indicador de total por cobrar
- **THEN** navega a `/cobranzas`

#### Scenario: El filtro de sucursal no lo altera

- **WHEN** el usuario aplica un filtro de sucursal en el Tablero
- **THEN** el total por cobrar no cambia, porque es el total de la cuenta

#### Scenario: El bloque mensual no cambia

- **WHEN** se inspecciona el bloque de resumen mensual del Tablero
- **THEN** conserva sus indicadores existentes y no incorpora el total por cobrar

### Requirement: El panel es legible y operable en las cuatro combinaciones

El panel de cobranzas SHALL usar los tokens semánticos del sistema de diseño y SHALL ser legible y operable en tema claro y oscuro, en viewport de escritorio y móvil.

La tabla SHALL desplazarse dentro de su propio contenedor cuando el ancho disponible no alcanza, y NO SHALL provocar desplazamiento horizontal del documento. Ninguna columna SHALL ocultarse por completo en móvil: la información se alcanza desplazando, no desapareciendo.

El importe del total y los saldos SHALL comunicarse con texto y no únicamente por color.

#### Scenario: Cuatro combinaciones

- **WHEN** el panel se muestra en escritorio o en móvil, en tema claro u oscuro
- **THEN** es legible y operable en las cuatro combinaciones, con tokens semánticos del sistema de diseño

#### Scenario: Tabla angosta en móvil

- **WHEN** el panel se muestra en un viewport móvil
- **THEN** la tabla se desplaza dentro de su contenedor y el documento no desborda horizontalmente

#### Scenario: El saldo no se comunica sólo por color

- **WHEN** el usuario mira una fila de deudor
- **THEN** el saldo se lee como importe, sin depender del color para su interpretación

### Requirement: El panel muestra el estado de vencimiento y permite filtrar por tramo

El panel de cobranzas SHALL mostrar, por cada deudor, su importe vencido y el tramo de antigüedad más severo en el que tiene deuda abierta, expresados **en texto** —no únicamente por color— y con los tokens semánticos del sistema de diseño.

El panel SHALL permitir filtrar la lista por estado de vencimiento, y el filtro SHALL resolverse **en el servidor**, sobre el conjunto completo de deudores y no sobre la página visible.

El deudor cuya deuda no tiene vencimiento SHALL presentarse como tal y NO SHALL presentarse como al día ni como vencido.

La cabecera SHALL mostrar, junto al total por cobrar, el **total vencido**, de modo que la primera lectura de la pantalla distinga la deuda que reclama acción de la que sólo está pendiente.

#### Scenario: Estado de vencimiento por fila

- **GIVEN** un deudor con 1000 vencidos hace 45 días
- **WHEN** el usuario abre el panel
- **THEN** la fila informa el importe vencido y el tramo de 31 a 60 días en texto legible

#### Scenario: Filtro por tramo

- **WHEN** el usuario filtra por deuda vencida de más de 60 días
- **THEN** la lista muestra únicamente los deudores con importe abierto en ese tramo, resuelto sobre el conjunto completo y no sobre la página visible

#### Scenario: Deudor sin vencimiento

- **GIVEN** un deudor cuya deuda no tiene vencimiento
- **WHEN** el usuario mira su fila
- **THEN** se presenta como deuda sin vencimiento, y no como al día ni como vencida

#### Scenario: Total vencido en la cabecera

- **GIVEN** una cuenta con 100000 por cobrar de los cuales 30000 están vencidos
- **WHEN** el usuario abre el panel
- **THEN** la cabecera muestra los dos importes distinguidos

#### Scenario: El estado no depende del color

- **WHEN** el usuario mira una fila con deuda vencida
- **THEN** el estado se lee en texto, sin depender del color para interpretarlo

### Requirement: El panel expone la deuda por pagar en la misma pantalla

El panel de cobranzas SHALL exponer la deuda con proveedores en una **segunda vista de la misma pantalla**, con la misma tabla, los mismos tramos y el mismo filtro que la deuda por cobrar, y SHALL permitir alternar entre ambas sin salir de la pantalla.

La vista de deuda por pagar SHALL ofrecer, por fila, el acceso a la cuenta corriente del proveedor y la acción de registrar un pago, reutilizando el formulario de pago existente sin declarar uno propio.

Una ruta y un menú separados para la deuda por pagar NO SHALL introducirse: es el mismo mecanismo sobre la otra parte del circuito, y duplicar cabecera, filtros y navegación para él haría que las dos caras del estado de cuentas se mantuvieran por separado.

#### Scenario: Alternar entre las dos caras

- **WHEN** el usuario abre el panel y alterna a la deuda por pagar
- **THEN** ve la tabla de proveedores con su saldo, su importe vencido y sus tramos, sin navegar a otra ruta

#### Scenario: Pago desde la fila del proveedor

- **WHEN** el usuario usa la acción de pagar de una fila de proveedor
- **THEN** se abre el formulario de pago existente, con el mismo comportamiento que desde la cuenta corriente del proveedor

#### Scenario: Sin deuda con proveedores

- **WHEN** el usuario abre la vista de deuda por pagar en una cuenta sin proveedores con saldo
- **THEN** ve un estado vacío explicativo, y no una tabla vacía ni un error

### Requirement: El panel ofrece un recordatorio de deuda por mensajería

El panel de cobranzas SHALL ofrecer, en la fila de cada cliente deudor, la acción de enviarle un **recordatorio de deuda** por mensajería, abriendo la conversación con un mensaje ya redactado que incluya el importe adeudado y, cuando exista, el estado de vencimiento.

El recordatorio SHALL reutilizar el mismo mecanismo de enlace directo de mensajería que ya usa el envío de comprobantes, con su misma normalización de números, y NO SHALL declarar uno propio. Cuando el teléfono del cliente no permite resolver un destinatario, la acción SHALL abrir de todos modos la mensajería con el mensaje redactado para que el usuario elija el contacto, en lugar de quedar inoperante.

El texto del mensaje SHALL construirse en una función pura, verificable sin interfaz.

El envío NO SHALL registrarse en ninguna bitácora en este alcance: el recordatorio es una acción asistida del usuario, no un envío del sistema.

#### Scenario: Recordatorio con el importe

- **GIVEN** un deudor con 12000 de deuda, 5000 de ellos vencidos hace 20 días
- **WHEN** el usuario usa la acción de recordatorio de esa fila
- **THEN** se abre la conversación con ese cliente con un mensaje que menciona el importe adeudado y su estado de vencimiento

#### Scenario: Cliente sin teléfono utilizable

- **GIVEN** un deudor cuyo teléfono no permite resolver un destinatario
- **WHEN** el usuario usa la acción de recordatorio
- **THEN** se abre la mensajería con el mensaje redactado y sin destinatario resuelto, y la acción no falla

#### Scenario: El texto se arma sin interfaz

- **WHEN** se construye el texto del recordatorio para un deudor dado
- **THEN** el resultado se obtiene de una función pura, verificable sin renderizar la pantalla

