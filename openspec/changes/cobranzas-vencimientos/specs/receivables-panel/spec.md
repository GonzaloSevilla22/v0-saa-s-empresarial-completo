## MODIFIED Requirements

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

## REMOVED Requirements

### Requirement: El panel no promete mora ni vencimientos que el sistema no tiene

**Reason**: El requirement prohibía rotular la antigüedad como mora y ofrecer tramos de aging **porque el sistema no tenía vencimientos** — lo dice su propio texto: *"mientras no exista un vencimiento asociado a cada cargo"*. Este change crea ese vencimiento, con lo que la condición que lo motivaba deja de valer y la prohibición pasaría a impedir mostrar un dato que ahora sí es real y verificable. Lo que el requirement protegía —que la pantalla no afirme lo que no puede sostener— no se pierde: se traslada, más fuerte, a las cláusulas de la capability `receivables-aging` que exigen que el tramo "sin vencimiento" sea propio y no se pliegue sobre "al día", y a la cláusula de este capability que exige explicar la ausencia de plazos configurados.

**Migration**: La nota al pie que declara que el sistema todavía no registra vencimientos se retira. Los deudores cuya deuda no tiene vencimiento —los históricos, y los de toda cuenta sin plazo configurado— siguen sin ser rotulados como vencidos: caen en el tramo propio "sin vencimiento". La cuenta que aún no configuró ningún plazo ve, en lugar de la nota vieja, la explicación de que no hay vencimientos configurados y el acceso para configurarlos.

## ADDED Requirements

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
