# expense-import Specification

## Purpose
Importación de un archivo de gastos como una operación de lote atómica de servidor: reutiliza `rpc_create_expense` por fila sin duplicar ninguno de sus guards, resuelve forma de pago, sucursal y centro de costo por nombre contra los catálogos de la cuenta, aplica la misma política de libros que el alta suelta (banco sí, caja no, con aviso explícito por fila), reporta los errores fila por fila sin escribir nada cuando el lote se rechaza, y es idempotente por clave y deduplicada por archivo. Nace de `importador-gastos-transaccional` (2026-09-10): el importador era la única superficie de dinero del sistema que emitía una llamada por fila sin ninguna transacción que abarcara el lote, motivo por el cual `gastos-forma-pago` le había negado la forma de pago.
## Requirements
### Requirement: La importación de gastos por archivo es una operación de lote atómica

El sistema SHALL importar un archivo de gastos como **una sola unidad de trabajo de servidor**: o quedan escritos todos los gastos del archivo con todos sus efectos en libros, o no queda escrito ninguno.

La unidad de trabajo SHALL implementarse como una función de base de datos `SECURITY DEFINER` que reciba el lote completo, y NO SHALL implementarse como una secuencia de llamadas independientes por fila desde el cliente ni desde la capa de aplicación: una atomicidad que sólo vale mientras la capa de aplicación no falle no es atomicidad.

El lote NO SHALL trocearse en sub-lotes: trocear reintroduce exactamente el fallo parcial que este comportamiento existe para eliminar.

Cuando el lote se rechaza, el sistema NO SHALL dejar rastro alguno de él: ni gastos, ni movimientos de caja, ni movimientos bancarios, ni la fila de importación, ni la marca de idempotencia.

#### Scenario: Una fila inválida no deja escrita ninguna de las válidas

- **GIVEN** un archivo de tres filas de gasto en el que la segunda viola una regla de negocio
- **WHEN** se importa el archivo
- **THEN** el resultado informa que el lote no se aplicó
- **AND** no queda ningún gasto nuevo, ningún movimiento bancario, ningún movimiento de caja y ninguna fila de importación

#### Scenario: Un lote válido se aplica entero

- **GIVEN** un archivo de tres filas de gasto todas válidas
- **WHEN** se importa el archivo
- **THEN** los tres gastos quedan persistidos con sus efectos en libros
- **AND** el resultado informa las tres filas como importadas

#### Scenario: Un fallo estructural también aborta el lote entero

- **GIVEN** un archivo cuyo procesamiento produce un error no previsto por las reglas de negocio
- **WHEN** se importa el archivo
- **THEN** el lote se rechaza completo y el resultado informa el código del error
- **AND** no queda ninguna escritura parcial

### Requirement: El lote reutiliza el alta de gasto y no duplica ninguna de sus reglas

El lote SHALL crear cada gasto **invocando la misma operación de alta de gasto** que usa el formulario, y NO SHALL reimplementar, copiar ni relajar ninguno de sus guards: importe estrictamente positivo, derivación del tipo de la forma de pago desde el catálogo, rechazo de la cuenta corriente como forma de pago de un gasto, validación de sucursal y de centro de costo, exigencia de cuenta bancaria de origen y guard de período conciliado.

La operación de alta de gasto NO SHALL modificarse por este comportamiento: el camino del formulario SHALL permanecer idéntico.

Los guards de tenencia y de rol de escritura SHALL evaluarse **por cada fila**, con el mismo criterio que el alta suelta: resolver la organización desde la sesión y nunca desde un parámetro del payload.

#### Scenario: Un gasto importado es indistinguible de uno cargado a mano

- **GIVEN** los mismos datos de gasto cargados una vez por el formulario y otra vez por importación
- **WHEN** se comparan las dos filas resultantes y sus movimientos de libros
- **THEN** son equivalentes en forma de pago, sucursal, centro de costo, importe, fecha y movimiento bancario

#### Scenario: Una fila con cuenta corriente como forma de pago se rechaza

- **WHEN** el archivo trae una fila cuya forma de pago es de tipo cuenta corriente
- **THEN** esa fila se reporta como error con el mismo código que el alta suelta
- **AND** el lote completo se rechaza

#### Scenario: Una fila con importe no positivo se rechaza

- **WHEN** el archivo trae una fila con importe cero o negativo
- **THEN** esa fila se reporta como error
- **AND** no queda ningún gasto escrito

### Requirement: Cada fila del archivo declara su forma de pago, su sucursal y su centro de costo por nombre

El sistema SHALL aceptar en el archivo de importación tres columnas opcionales —forma de pago, sucursal y centro de costo— cuyo valor SHALL resolverse **por nombre** contra los catálogos de la organización, considerando únicamente las filas activas y no borradas de esa organización.

Cuando la celda venga vacía, el sistema SHALL usar el valor por defecto que la superficie de importación haya elegido para esa dimensión y, si tampoco hay uno, SHALL delegar la resolución en el alta de gasto, que para la sucursal aplica la sucursal por defecto de la organización.

Cuando la celda traiga un nombre que **no** resuelve, el sistema SHALL reportar la fila como error indicando la columna y los nombres válidos, y NO SHALL sustituirlo por ningún valor por defecto: asignar en silencio una forma de pago distinta de la declarada manda el dinero al libro equivocado sin ninguna señal para el usuario.

El sistema NO SHALL crear entradas de catálogo a partir del archivo: el tipo de una forma de pago no es derivable de su nombre, y de ese tipo depende a qué libro va el dinero.

#### Scenario: Nombre de forma de pago que resuelve

- **GIVEN** una organización cuyo catálogo tiene una forma de pago llamada "Transferencia bancaria"
- **WHEN** una fila del archivo declara esa forma de pago
- **THEN** el gasto queda imputado a esa forma de pago del catálogo de esa organización

#### Scenario: Nombre de forma de pago que no resuelve

- **WHEN** una fila del archivo declara una forma de pago que no existe en el catálogo de la organización
- **THEN** la fila se reporta como error nombrando la columna y las formas de pago disponibles
- **AND** el lote completo se rechaza
- **AND** no se crea ninguna forma de pago nueva

#### Scenario: Celda vacía con valor por defecto elegido

- **GIVEN** que la superficie de importación eligió una forma de pago por defecto para el lote
- **WHEN** una fila deja la columna de forma de pago vacía
- **THEN** el gasto queda imputado a la forma de pago por defecto del lote

#### Scenario: Celda vacía sin valor por defecto

- **WHEN** una fila deja vacía la columna de forma de pago y el lote no eligió ninguna por defecto
- **THEN** el gasto queda sin forma de pago imputada y sin efecto en libros
- **AND** la fila no se reporta como error

#### Scenario: Catálogo de otra organización

- **WHEN** una fila declara el nombre de una forma de pago, una sucursal o un centro de costo que pertenece a otra organización
- **THEN** la fila se reporta como error
- **AND** nada se escribe en ninguna de las dos organizaciones

### Requirement: El lote reporta los errores fila por fila en su resultado, sin escribir nada

El sistema SHALL devolver, en el resultado de la importación, **todas** las filas con problema y no solamente la primera, cada una con su número de fila, el código de error y el motivo, de modo que el usuario pueda corregir el archivo de una sola vez.

El reporte SHALL viajar en el **resultado normal** de la operación y NO SHALL viajar como una condición de error de la transacción del pedido: dejar la transacción del pedido en estado abortado obliga a construir la respuesta sin volver a consultar la base y convierte cualquier lectura posterior en un fallo.

El motivo de cada fila SHALL ser el que produce la operación de alta de gasto, sin reescribirlo: una segunda redacción del mismo error diverge de la primera.

#### Scenario: Varias filas con problemas distintos

- **GIVEN** un archivo en el que la fila 2 tiene una forma de pago inexistente y la fila 5 un importe negativo
- **WHEN** se importa el archivo
- **THEN** el resultado informa las dos filas, cada una con su número, su código y su motivo
- **AND** el lote no se aplicó

#### Scenario: El pedido responde normalmente aunque el lote se rechace

- **WHEN** un lote se rechaza por errores de fila
- **THEN** el pedido responde con su resultado estructurado
- **AND** la operación no deja la sesión de base de datos en estado inutilizable

### Requirement: El lote registra el movimiento bancario de los gastos pagados por medio bancario

El sistema SHALL registrar, para cada fila cuyo tipo de forma de pago sea bancario, el movimiento en el ledger bancario con la misma delegación, el mismo sentido de egreso, el mismo tipo de documento de origen y la misma fecha valor —la fecha del gasto— que el alta de gasto individual.

El movimiento bancario de un gasto importado SHALL ser **retroactivo cuando la fila lo es**: el ledger bancario no tiene sesión ni arqueo y su conciliación se resuelve por fecha e importe contra el extracto, de modo que un egreso de una fecha pasada es un dato correcto.

Cuando la cuenta bancaria de origen no resuelva y la organización tenga cuentas bancarias activas, la fila SHALL rechazarse con el mismo código que el alta suelta, y el lote SHALL rechazarse completo.

La superficie de importación SHALL permitir elegir una cuenta bancaria de origen para el lote, que actúe como **respaldo** y NO como sustitución: el destino configurado en la forma de pago conserva la precedencia.

#### Scenario: Gasto importado por transferencia llega al ledger bancario

- **GIVEN** una forma de pago de tipo transferencia con cuenta bancaria resuelta
- **WHEN** se importa una fila con esa forma de pago y fecha de un mes atrás
- **THEN** el ledger bancario registra un egreso por ese importe, con fecha valor igual a la del gasto y el gasto como documento de origen

#### Scenario: El respaldo del lote no pisa el destino de la forma de pago

- **GIVEN** una forma de pago con cuenta bancaria configurada y un respaldo de lote distinto
- **WHEN** se importa una fila con esa forma de pago
- **THEN** el movimiento se registra contra la cuenta configurada en la forma de pago

#### Scenario: Sin cuenta bancaria resoluble y con bancos activos

- **GIVEN** una organización con cuentas bancarias activas y una forma de pago bancaria sin destino configurado
- **WHEN** se importa una fila con esa forma de pago y el lote no eligió respaldo
- **THEN** la fila se reporta como error indicando que falta la cuenta bancaria de origen
- **AND** el lote completo se rechaza

#### Scenario: Fila dentro de un período ya conciliado

- **GIVEN** un período de conciliación cerrado para la cuenta bancaria de destino
- **WHEN** el archivo trae una fila bancaria con fecha dentro de ese período
- **THEN** la fila se reporta como error
- **AND** el lote completo se rechaza sin dejar ningún movimiento

### Requirement: El lote nunca registra movimientos de caja, y lo declara fila por fila

El sistema NO SHALL registrar ningún movimiento de caja como consecuencia de una importación de gastos, cualquiera sea el tipo de forma de pago de la fila, la fecha de la fila y el estado de las sesiones de caja de la organización.

El motivo SHALL declararse: el libro de caja es un registro por sesión que se cuenta, se arquea y se firma al cerrar; una sesión pasada ya está cerrada y no admite escrituras, y anotar un egreso de otra fecha en la sesión abierta de hoy inventa una diferencia en un arqueo que se va a firmar.

El sistema SHALL informar explícitamente, por cada fila cuya forma de pago sea de tipo efectivo, que el gasto quedó registrado **sin impacto en la caja**, y SHALL indicar que el camino para que un gasto en efectivo impacte el arqueo es cargarlo desde el formulario. Este aviso NO SHALL omitirse: un efecto ausente y no declarado es indistinguible de un fallo silencioso.

#### Scenario: Fila en efectivo de una fecha pasada

- **WHEN** se importa una fila con forma de pago de tipo efectivo y fecha anterior a hoy
- **THEN** el gasto queda persistido con su forma de pago imputada
- **AND** no se registra ningún movimiento de caja
- **AND** el resultado informa esa fila como registrada sin impacto en la caja

#### Scenario: Fila en efectivo de hoy con la caja abierta

- **GIVEN** una sesión de caja abierta en la sucursal de la fila y una fila en efectivo fechada hoy
- **WHEN** se importa el archivo
- **THEN** el gasto queda persistido
- **AND** la sesión de caja no registra ningún movimiento
- **AND** el resultado informa esa fila como registrada sin impacto en la caja

#### Scenario: La ayuda del importador declara la limitación de caja

- **WHEN** un usuario abre la superficie de importación
- **THEN** la ayuda indica que los gastos en efectivo importados no impactan la caja
- **AND** indica que para que un gasto en efectivo impacte el arqueo hay que cargarlo desde el formulario

### Requirement: El lote tiene un tope de filas y lo verifica en el servidor

El sistema SHALL rechazar un lote que exceda el tope de filas por importación, con un código de error propio de forma de payload y un mensaje que nombre el tope y sugiera partir el archivo, **antes** de intentar ninguna escritura.

El tope SHALL verificarse en el servidor aunque la superficie también lo aplique: la superficie evita el viaje inútil, el servidor es la autoridad.

El sistema SHALL rechazar igualmente un lote vacío o un payload que no sea una lista de filas.

#### Scenario: Archivo por encima del tope

- **WHEN** se importa un archivo con más filas que el tope
- **THEN** la operación se rechaza indicando el tope y sugiriendo partir el archivo
- **AND** no se escribe ninguna fila

#### Scenario: Archivo vacío

- **WHEN** se importa un archivo sin filas de datos
- **THEN** la operación se rechaza
- **AND** no se escribe nada

### Requirement: La importación es idempotente por clave y deduplicada por archivo

El sistema SHALL aceptar una clave de idempotencia por el header HTTP estándar del proyecto y SHALL registrarla en la misma transacción que el lote, de modo que un reintento con la misma clave devuelva el resultado del lote previo sin volver a escribir.

El sistema SHALL además deduplicar **por contenido de archivo**: una importación cuyo hash de archivo ya fue importado por esa organización SHALL devolverse como repetición del lote anterior, sin escribir un segundo lote. La clave de idempotencia protege el reintento técnico; el hash protege el error humano de volver a subir el mismo archivo.

El sistema SHALL persistir una fila de importación por lote aplicado —con el nombre del archivo, su hash, el total de filas y la cantidad importada— y SHALL marcar cada gasto creado con la importación de la que proviene, de modo que el "todo o nada" sea auditable después del hecho.

La fila de importación SHALL ser legible únicamente por miembros de su organización y NO SHALL ser escribible por ningún rol de aplicación: su escritura es exclusiva de la función de lote.

Un lote rechazado NO SHALL consumir la clave de idempotencia ni dejar fila de importación: corregir el archivo y reintentar con la misma clave SHALL poder aplicarse.

#### Scenario: Reintento con la misma clave

- **WHEN** se envía dos veces la misma importación con la misma clave de idempotencia
- **THEN** la segunda respuesta devuelve el resultado de la primera
- **AND** no se crea un segundo conjunto de gastos

#### Scenario: Mismo archivo con otra clave

- **GIVEN** un archivo ya importado por la organización
- **WHEN** se vuelve a importar el mismo archivo con una clave de idempotencia distinta
- **THEN** el resultado informa que ese archivo ya había sido importado
- **AND** no se crea un segundo conjunto de gastos

#### Scenario: Un lote rechazado no quema la clave

- **GIVEN** un lote rechazado por errores de fila
- **WHEN** se corrige el archivo y se reintenta con la misma clave de idempotencia
- **THEN** el lote se aplica normalmente

#### Scenario: Los gastos importados apuntan a su importación

- **WHEN** un lote se aplica
- **THEN** cada gasto creado queda asociado a la fila de importación de ese lote

#### Scenario: La fila de importación no es escribible desde la aplicación

- **WHEN** se inspeccionan los permisos de la tabla de importaciones
- **THEN** el rol autenticado puede leerla y no puede insertar, actualizar ni borrar
- **AND** el rol anónimo no tiene ningún permiso de escritura

### Requirement: La vista previa de la importación es el veredicto del servidor

El sistema SHALL ofrecer un modo de **simulación** del lote que ejecute exactamente el mismo camino —resolución de nombres, alta de cada fila y evaluación de todos los guards— y deshaga todo su efecto antes de terminar, devolviendo el mismo reporte de errores y avisos que devolvería el lote real.

La superficie de importación SHALL usar ese modo para construir su vista previa, de modo que el usuario vea antes de confirmar los problemas que **sólo el servidor** puede conocer: período conciliado, sucursal cerrada, centro de costo inactivo, cuenta bancaria faltante y nombres de catálogo que no resuelven.

La simulación NO SHALL implementarse como un validador separado: una segunda definición de las reglas diverge de la que escribe.

La simulación NO SHALL dejar ninguna escritura, ni siquiera la marca de idempotencia ni la fila de importación.

#### Scenario: La vista previa anticipa un problema que el cliente no puede conocer

- **GIVEN** un archivo con una fila bancaria cuya fecha cae en un período de conciliación cerrado
- **WHEN** el usuario avanza a la revisión del archivo
- **THEN** la vista previa muestra esa fila como error con su motivo, antes de confirmar

#### Scenario: La simulación no escribe nada

- **WHEN** se ejecuta la importación en modo simulación sobre un archivo completamente válido
- **THEN** el resultado informa cuántas filas se importarían
- **AND** no queda ningún gasto, movimiento, fila de importación ni marca de idempotencia

### Requirement: Superficie de importación de gastos

La superficie de importación SHALL exponerse desde la pantalla de gastos que ya la ofrece, sin ruta ni entrada de menú nuevas, y SHALL permitir en el paso de carga del archivo elegir los valores por defecto del lote: forma de pago, sucursal, centro de costo y cuenta bancaria de respaldo, todos opcionales.

El selector de cuenta bancaria SHALL mostrarse únicamente cuando la organización tenga cuentas bancarias activas, con el mismo criterio que el formulario de gasto.

El paso de revisión SHALL mostrar, por fila, los valores resueltos y su estado —correcta, con aviso o con error— con el motivo visible, y SHALL **deshabilitar la confirmación mientras exista al menos una fila con error**: siendo el lote todo o nada, ofrecer "importar las que se pueda" sería ofrecer algo que el sistema no hace.

El paso de resultado SHALL informar la cantidad de gastos importados, el nombre del archivo y, si el lote fue una repetición, que ese archivo ya se había importado.

La plantilla descargable SHALL incluir las columnas nuevas, y el sistema SHALL seguir aceptando archivos con las columnas anteriores: las columnas nuevas son opcionales.

La superficie SHALL usar los tokens semánticos del sistema de diseño para los estados de fila —nunca colores literales— y SHALL verificarse en pantalla ancha y angosta, y en tema claro y oscuro. El contenido ancho del paso de revisión SHALL desplazarse dentro de su propio contenedor y NO SHALL ensanchar el documento.

Al confirmarse un lote, la superficie SHALL refrescar **una sola vez** todas las vistas que el lote altera —gastos y ledger bancario incluidos—, y NO SHALL refrescarlas una vez por fila.

#### Scenario: Valores por defecto del lote

- **WHEN** el usuario carga un archivo y elige una forma de pago y una sucursal por defecto
- **THEN** las filas que dejan esas columnas vacías se importan con esos valores

#### Scenario: Confirmación bloqueada por una fila con error

- **GIVEN** una vista previa con al menos una fila en error
- **WHEN** el usuario intenta confirmar la importación
- **THEN** la confirmación está deshabilitada y el motivo es visible

#### Scenario: Archivo con las columnas anteriores

- **WHEN** se importa un archivo con las cuatro columnas originales y ninguna de las nuevas
- **THEN** el archivo se importa normalmente
- **AND** las filas quedan con los valores por defecto del lote, o sin imputar si no se eligió ninguno

#### Scenario: Revisión en pantalla angosta

- **WHEN** se abre el paso de revisión en una pantalla angosta
- **THEN** la tabla se desplaza dentro de su contenedor
- **AND** el documento no se ensancha ni esconde el botón de confirmación

#### Scenario: Un solo refresco por lote

- **WHEN** se confirma un lote de varias filas
- **THEN** las vistas afectadas se invalidan una sola vez al terminar el lote

### Requirement: El endpoint de importación de gastos respeta los estándares de API del proyecto

El backend SHALL exponer la importación como una mutación propia del recurso de gastos, resuelta en las tres capas del backend —router, service y repository— sin lógica de negocio en el router ni en el service: el service SHALL limitarse a validar el rol de escritura, traducir el payload y mapear los códigos de error a `problem+json`.

El endpoint SHALL tomar la clave de idempotencia del header estándar, con la misma precedencia que el resto de las mutaciones no idempotentes del proyecto.

El endpoint SHALL responder con el reporte estructurado del lote —aplicado o rechazado— y SHALL reservar las respuestas de error para lo que sí es un error de protocolo o de autorización: payload malformado, tope excedido, falta de rol de escritura o ausencia de organización activa.

La función de lote NO SHALL ser ejecutable por el rol anónimo: sus permisos SHALL revocarse de `PUBLIC` y de `anon` y otorgarse explícitamente al rol autenticado **en el mismo archivo de migración** que la define.

#### Scenario: Mutación sin clave de idempotencia

- **WHEN** se llama al endpoint de importación sin clave de idempotencia
- **THEN** la request es rechazada indicando que la clave es requerida

#### Scenario: Usuario sin rol de escritura

- **WHEN** un usuario sin rol de escritura intenta importar un archivo de gastos
- **THEN** la operación es rechazada
- **AND** no se escribe ninguna fila

#### Scenario: El rol anónimo no puede ejecutar la función de lote

- **WHEN** se inspeccionan los permisos de la función de lote
- **THEN** el rol anónimo no tiene permiso de ejecución y el rol autenticado sí

#### Scenario: Lote rechazado por errores de fila

- **WHEN** se importa un archivo con filas en error
- **THEN** la respuesta trae el reporte con la lista de filas en error
- **AND** la respuesta no es un error de protocolo
