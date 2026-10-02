# internal-document-numbering Specification

## Purpose
Numeración interna, visible y correlativa por cuenta de los documentos comerciales **no fiscales** (el presupuesto primero; el remito la reutiliza). Define la secuencia `internal_document_sequences` por `(account_id, document_type)`, la entrega del siguiente número sin huecos ni repetidos bajo concurrencia, la asignación obligatoria en el alta del documento mediante un disparador genérico parametrizado por tipo y el formato visible del número. Es independiente de la numeración fiscal por punto de venta (`document_sequences`), que ningún documento no fiscal toca.
## Requirements
### Requirement: Secuencia interna por cuenta y tipo de documento no fiscal
El sistema SHALL persistir la numeración de los documentos comerciales **no fiscales** en la tabla `internal_document_sequences`, con clave primaria `(account_id, document_type)` y el último número entregado (`last_number bigint`, 0 inicial). `document_type` SHALL pertenecer a un conjunto cerrado por `CHECK`, que se amplía de forma aditiva cuando un tipo de documento nuevo empieza a numerarse. El primer tipo es `quote`. Esta numeración SHALL ser independiente de la numeración fiscal por punto de venta (`document_sequences`), y ningún documento fiscal SHALL numerarse con ella.

#### Scenario: una fila por cuenta y tipo
- **GIVEN** una fila de secuencia para la cuenta A y el tipo `quote`
- **WHEN** se intenta insertar otra fila con la misma cuenta y el mismo tipo
- **THEN** el INSERT falla por la clave primaria

#### Scenario: tipo no admitido
- **WHEN** se intenta registrar una secuencia para un tipo fuera del conjunto cerrado
- **THEN** el `CHECK` lo rechaza

#### Scenario: independiente de la numeración fiscal
- **WHEN** se numera un presupuesto
- **THEN** ninguna fila de `document_sequences` cambia

### Requirement: Entrega del siguiente número sin huecos ni repetidos
El sistema SHALL entregar el siguiente número de una secuencia interna mediante una función interna sin permiso de ejecución para los roles de aplicación. La función SHALL incrementar la fila bajo bloqueo de fila dentro de la transacción del alta del documento; si la fila no existe, SHALL crearla con el patrón UPDATE-then-INSERT, reintentando el UPDATE ante una inserción concurrente, y nunca con un upsert acumulativo. Un alta que se revierte SHALL revertir también el incremento, de modo que la secuencia de cada cuenta y tipo no tenga huecos ni repetidos, incluso bajo concurrencia.

#### Scenario: primer número de una cuenta
- **GIVEN** una cuenta sin fila de secuencia para `quote`
- **WHEN** se crea su primer presupuesto
- **THEN** se crea la fila y el presupuesto recibe el número 1

#### Scenario: un alta fallida no consume número
- **GIVEN** una cuenta cuyo último número de presupuesto es 4
- **WHEN** falla el alta de un presupuesto (por ejemplo, por un producto de otra cuenta) y luego se crea otro con éxito
- **THEN** el presupuesto creado recibe el número 5

#### Scenario: altas concurrentes
- **WHEN** 20 transacciones concurrentes crean presupuestos en la misma cuenta
- **THEN** reciben exactamente los números 1 a 20, sin huecos ni repetidos

#### Scenario: la función no es invocable desde la aplicación
- **WHEN** un usuario autenticado intenta ejecutar directamente la función que entrega números
- **THEN** la ejecución es rechazada por permisos

### Requirement: Asignación obligatoria del número en el alta del documento
El sistema SHALL asignar el número interno en la propia base de datos, mediante un disparador `BEFORE INSERT` sobre la tabla del documento, cuando la fila nueva no trae número, de modo que ningún camino de escritura con los disparadores activos (operación de negocio, backend, proceso o carga de datos) pueda crear un documento numerado sin número. El número SHALL ser único por cuenta (`UNIQUE (account_id, number)`). Un número explícito provisto por el escritor SHALL respetarse y SHALL avanzar la secuencia hasta él cuando es mayor que el último entregado, de modo que un alta posterior no choque con él; un duplicado SHALL rechazarse por la unicidad.

La regla de asignación (siguiente número o avance por número explícito) SHALL vivir en una función interna compartida, y el disparador SHALL ser una única función genérica parametrizada por el tipo de documento, de modo que un tipo nuevo se numere agregando sólo su disparador y su valor al conjunto cerrado, sin copiar la lógica. Las reglas propias de un tipo de documento (por ejemplo, la validez por defecto del presupuesto) NOT SHALL vivir en esa pieza compartida.

#### Scenario: alta sin número
- **WHEN** se inserta un presupuesto sin número por cualquier camino
- **THEN** la fila queda con el siguiente número de la secuencia de su cuenta

#### Scenario: número duplicado explícito
- **GIVEN** un presupuesto número 3 en la cuenta A
- **WHEN** se inserta otro presupuesto de la cuenta A con número 3 explícito
- **THEN** el INSERT falla por la unicidad

#### Scenario: el disparador es el genérico del tipo
- **WHEN** se inspeccionan los disparadores de `quotes`
- **THEN** la numeración la asigna la función genérica con el tipo `quote` como argumento

#### Scenario: un número explícito avanza la secuencia
- **GIVEN** una cuenta cuyo último número entregado es 2
- **WHEN** se inserta un presupuesto con número 10 explícito y después uno sin número
- **THEN** el segundo recibe el número 11

### Requirement: Formato visible del número interno
El sistema SHALL mostrar el número interno con un prefijo por tipo de documento y el número rellenado a 8 dígitos: `P-` para presupuestos (`P-00000012`). El formato SHALL tener una única definición por lenguaje (frontend y backend), verificada contra un mismo conjunto de casos compartido. Toda superficie que muestre el número —listados, detalle, PDF, nombre de archivo y textos para compartir— SHALL usar esa definición. La búsqueda por número SHALL aceptar el formato con prefijo, el número sin ceros y el número con ceros.

#### Scenario: formato de un presupuesto
- **WHEN** se formatea el número 12 de un presupuesto
- **THEN** el resultado es `P-00000012`

#### Scenario: misma salida en backend y frontend
- **WHEN** los dos lenguajes formatean los casos del archivo compartido
- **THEN** producen exactamente las salidas esperadas por ese archivo

