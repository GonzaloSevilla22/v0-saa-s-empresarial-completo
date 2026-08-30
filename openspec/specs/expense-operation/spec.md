# expense-operation Specification

## Purpose
TBD - created by archiving change gastos-forma-pago. Update Purpose after archive.
## Requirements
### Requirement: El gasto imputa una forma de pago del catálogo de su cuenta

El sistema SHALL permitir imputar opcionalmente un gasto a una forma de pago del catálogo `payment_methods`, mediante una columna nullable `payment_method_id` en `public.expenses` (FK a `payment_methods`, `ON DELETE SET NULL`), espejo exacto de la columna homónima de `sales` y `purchases`.

La forma de pago SHALL pertenecer a la misma cuenta que el gasto, SHALL estar activa y no borrada; en cualquier otro caso el alta SHALL rechazarse con el código de error `P0404`, sin persistir el gasto.

El `kind` de la forma de pago SHALL derivarse **en el servidor** a partir del catálogo y SHALL NOT aceptarse como texto enviado por el cliente, aplicando el mismo predicado de derivación y validación que ya usa el alta de venta.

El campo SHALL ser opcional: un gasto sin forma de pago es válido, queda en `NULL` y no produce ningún efecto en libros.

#### Scenario: Alta de gasto con forma de pago activa de la cuenta

- **WHEN** se crea un gasto informando una forma de pago activa de la propia cuenta
- **THEN** el gasto se persiste con esa forma de pago imputada
- **AND** el `kind` que gobierna los efectos se derivó del catálogo, no del payload

#### Scenario: Alta de gasto sin forma de pago

- **WHEN** se crea un gasto sin informar forma de pago
- **THEN** el gasto se persiste con la forma de pago en nulo
- **AND** no se registra ningún movimiento de caja ni bancario

#### Scenario: Forma de pago de otra cuenta

- **WHEN** se intenta crear un gasto con una forma de pago que pertenece a otra cuenta
- **THEN** la operación es rechazada con `P0404`
- **AND** no queda ninguna fila nueva en gastos

#### Scenario: Forma de pago desactivada o borrada

- **WHEN** se intenta crear un gasto con una forma de pago inactiva o dada de baja
- **THEN** la operación es rechazada con `P0404`

#### Scenario: Los gastos históricos quedan sin imputar

- **GIVEN** los gastos existentes al momento de la migración
- **WHEN** se aplica la migración
- **THEN** todos conservan la forma de pago en nulo
- **AND** ninguno recibe una imputación inventada por backfill

### Requirement: El importe de un gasto es estrictamente positivo

El sistema SHALL rechazar con el código de error `P0400` el alta y la edición de un gasto cuyo importe no sea estrictamente mayor que cero, con el mismo criterio y el mismo código que ya usan el alta de venta y el alta de compra, y SHALL hacerlo en el servidor aunque la superficie ya lo limite.

El importe SHALL ser positivo también a nivel de persistencia: la tabla de gastos SHALL tener una restricción que lo garantice para todo camino de escritura, incluidos los que no pasan por las operaciones de gasto.

El motivo SHALL entenderse como una **precondición de los efectos en libros**: el signo del movimiento lo pone la operación —la caja recibe el importe en negativo y el banco un egreso—, de modo que un importe negativo invertiría el efecto en los dos libros sin que ningún guard posterior lo advierta, y dejaría la compensación del borrado sin disparar.

En la edición, la ausencia del importe SHALL seguir significando "no cambia", y SHALL NOT interpretarse como un importe inválido.

#### Scenario: Alta de gasto con importe negativo

- **WHEN** se intenta crear un gasto con importe negativo
- **THEN** la operación es rechazada con `P0400`
- **AND** no queda ninguna fila nueva en gastos
- **AND** no se registra ningún movimiento de caja ni bancario

#### Scenario: Alta de gasto con importe cero

- **WHEN** se intenta crear un gasto con importe cero
- **THEN** la operación es rechazada con `P0400`

#### Scenario: Edición de un gasto a un importe no positivo

- **WHEN** se intenta editar un gasto llevando su importe a cero o a un valor negativo
- **THEN** la operación es rechazada con `P0400`
- **AND** el gasto conserva su importe anterior

#### Scenario: Escritura directa con importe no positivo

- **WHEN** se intenta persistir un gasto con importe no positivo por un camino que no pasa por las operaciones de gasto
- **THEN** la restricción de la tabla lo rechaza

#### Scenario: El importe válido sigue entrando

- **WHEN** se crea un gasto con un importe positivo
- **THEN** el gasto se persiste y sus efectos en libros se registran normalmente

### Requirement: Cuenta corriente no es un camino válido para un gasto

El sistema SHALL rechazar el alta de un gasto cuya forma de pago tenga `kind = 'credit'`, con el código de error `P0400`, porque un gasto no tiene contraparte con cuenta corriente: `public.expenses` no referencia ni cliente ni proveedor y no existe cuenta alguna que cargar.

La superficie de alta de gasto SHALL NOT ofrecer las formas de pago de ese `kind`, y SHALL indicar cuál es el camino correcto para un egreso que se paga después.

#### Scenario: Alta de gasto a cuenta corriente por la API

- **WHEN** se intenta crear un gasto con una forma de pago de tipo cuenta corriente
- **THEN** la operación es rechazada con `P0400`
- **AND** no queda ninguna fila nueva en gastos ni ningún movimiento en ningún libro

#### Scenario: El selector de gasto no ofrece cuenta corriente

- **WHEN** un usuario abre el selector de forma de pago del formulario de gasto
- **THEN** las formas de pago de tipo cuenta corriente no aparecen entre las opciones
- **AND** el texto de apoyo indica que un egreso a pagar después se registra como compra a proveedor

### Requirement: El gasto persiste su sucursal

El sistema SHALL persistir `branch_id` en todo gasto nuevo, resolviéndolo como la sucursal informada o, en su ausencia, la sucursal por defecto de la cuenta — el mismo criterio de resolución que ya usa el alta de venta. La columna SHALL permanecer nullable para no invalidar los gastos históricos, que fueron creados por un camino que nunca la escribió.

Este requisito cumple RN-93 para el documento de gasto, que hasta ahora era el único documento operativo que no lo cumplía.

#### Scenario: Alta de gasto sin sucursal informada

- **WHEN** se crea un gasto sin informar sucursal
- **THEN** el gasto queda persistido con la sucursal por defecto de la cuenta

#### Scenario: Alta de gasto con sucursal informada

- **WHEN** se crea un gasto informando una sucursal activa de la propia cuenta
- **THEN** el gasto queda persistido con esa sucursal

#### Scenario: El gasto queda dentro del predicado de agregación por sucursal

- **GIVEN** un gasto nuevo imputado a una sucursal
- **WHEN** se agregan los gastos del período por sucursal
- **THEN** el gasto queda atribuido a esa sucursal

> El read-model del reporte por sucursal tiene un defecto **pre-existente y ajeno a este cambio** (una referencia ambigua a la columna de sucursal) que lo hace fallar para todo llamador, así que esa pantalla todavía no puede mostrar ningún gasto. Este requisito cubre la atribución del dato, que es lo que este cambio entrega; arreglar ese read-model queda como cambio propio.

#### Scenario: Los gastos históricos siguen siendo válidos sin sucursal

- **GIVEN** gastos anteriores a este cambio, sin sucursal
- **WHEN** se listan y se leen
- **THEN** siguen siendo legibles y editables, con la sucursal en nulo

### Requirement: El alta, la edición y el borrado de un gasto son operaciones atómicas de servidor

El sistema SHALL ejecutar el alta, la edición y el borrado de un gasto dentro de una RPC `SECURITY DEFINER` propia por operación, con `search_path` fijo, que evalúe todos sus guards y aplique la escritura del gasto **y** todos sus efectos en libros en la misma transacción.

El repositorio de la aplicación SHALL NOT componer SQL ni orquestar pasos de negocio: SHALL emitir una única llamada por operación.

Ninguna combinación de fallos SHALL poder dejar un gasto sin sus movimientos ni movimientos sin su gasto.

#### Scenario: Fallo al postear el movimiento de caja

- **WHEN** el alta de un gasto en efectivo falla al registrar el movimiento de caja
- **THEN** la transacción completa se revierte
- **AND** no queda ninguna fila nueva en gastos

#### Scenario: Fallo al postear el movimiento bancario

- **WHEN** el alta de un gasto por transferencia falla al registrar el movimiento bancario
- **THEN** la transacción completa se revierte
- **AND** no queda ninguna fila nueva en gastos

#### Scenario: El repositorio no orquesta pasos de negocio

- **WHEN** el backend crea, edita o borra un gasto
- **THEN** emite una única llamada a la RPC correspondiente
- **AND** no evalúa guards ni compone secuencias de escritura del lado de la aplicación

### Requirement: Las operaciones de gasto resuelven el tenant desde la sesión y exigen rol de escritura

El sistema SHALL resolver la cuenta del gasto a partir de la sesión del usuario en curso, y SHALL NOT aceptarla como parámetro, porque una función con privilegio de definidor deja las políticas de fila fuera de juego y un identificador de cuenta recibido por parámetro habilita escritura cruzada entre organizaciones.

Las tres operaciones SHALL exigir además rol de escritura sobre la cuenta resuelta.

La edición y el borrado SHALL localizar el gasto restringiendo por la cuenta resuelta, y SHALL responder con `P0404` cuando el gasto no pertenezca a ella, sin distinguir "no existe" de "es de otra cuenta".

Las tres funciones SHALL revocar la ejecución de los roles anónimo y público y otorgarla únicamente al rol autenticado, según el patrón uniforme de ACL del proyecto, y SHALL NOT introducir funciones auxiliares nuevas.

#### Scenario: Editar un gasto de otra cuenta

- **WHEN** un usuario intenta editar un gasto que pertenece a otra cuenta
- **THEN** la operación es rechazada con `P0404`
- **AND** el gasto ajeno queda intacto

#### Scenario: Borrar un gasto de otra cuenta

- **WHEN** un usuario intenta borrar un gasto que pertenece a otra cuenta
- **THEN** la operación es rechazada con `P0404`
- **AND** el gasto ajeno sigue existiendo

#### Scenario: Un miembro sin rol de escritura no puede registrar un gasto

- **WHEN** un usuario que es miembro de la cuenta pero no tiene rol de escritura intenta crear un gasto
- **THEN** la operación es rechazada
- **AND** no queda ninguna fila nueva

#### Scenario: Las funciones de gasto no son ejecutables por el rol anónimo

- **WHEN** se inspeccionan los permisos de las funciones de alta, edición y borrado de gasto
- **THEN** ninguna es ejecutable por el rol anónimo ni por el público
- **AND** existe exactamente una definición viva de cada una

### Requirement: El gasto en efectivo descuenta de la caja mediante opt-in con tres condiciones verificadas en el servidor

El sistema SHALL aceptar en el alta de gasto una sesión de caja opcional. Cuando no se informe, el alta SHALL ser un no-op respecto de la caja: el gasto se guarda y ningún movimiento se registra.

Cuando se informe, el servidor SHALL verificar las tres condiciones —y SHALL NOT confiar en la verificación del cliente—, rechazando con `P0422` si alguna falla:

1. el `kind` derivado del catálogo es efectivo;
2. la sesión existe, está abierta y su caja pertenece a la sucursal efectiva del gasto;
3. la fecha del gasto corresponde al día local de hoy.

Cumplidas las tres, el sistema SHALL registrar un movimiento de caja de tipo `expense` con **importe negativo** y referencia al gasto, dentro de la misma transacción, delegando en el helper intra-transaccional de caja que ya existe.

La comparación de la fecha del gasto contra el día local SHALL ser independiente de la zona horaria de la sesión de base de datos. La fecha del gasto se almacena con hora y la sesión del servidor corre en UTC, mientras que el día local se calcula en la zona del tenant: convertir el valor almacenado a fecha con la zona de la sesión rechazaría con error un gasto legítimo de hoy cargado en las últimas horas de la tarde-noche local. La fecha SHALL viajar y compararse como fecha calendario, que es lo que la superficie ya envía.

#### Scenario: Gasto en efectivo de hoy con caja abierta

- **GIVEN** una sesión de caja abierta en la sucursal del gasto y una forma de pago de tipo efectivo
- **WHEN** se crea un gasto de hoy informando esa sesión
- **THEN** el gasto queda persistido
- **AND** la sesión registra un movimiento de tipo `expense` con importe negativo igual al del gasto
- **AND** el saldo posterior de la sesión disminuye en ese importe

#### Scenario: Gasto de hoy cargado al cierre del día local

- **GIVEN** una sesión de caja abierta y una forma de pago de tipo efectivo
- **WHEN** se crea un gasto del día local de hoy en el tramo horario en el que la fecha en la zona del servidor ya es la del día siguiente
- **THEN** el gasto se acepta y registra su movimiento de caja
- **AND** no es rechazado por la verificación de día

#### Scenario: El resultado no depende de la zona horaria de la sesión

- **GIVEN** el mismo alta de gasto en efectivo del día local de hoy
- **WHEN** se ejecuta con la sesión de base de datos en la zona del servidor y con la sesión en la zona local del tenant
- **THEN** las dos ejecuciones dan el mismo resultado de aceptación

#### Scenario: Gasto en efectivo sin informar sesión

- **WHEN** se crea un gasto con forma de pago de tipo efectivo sin informar sesión de caja
- **THEN** el gasto queda persistido
- **AND** ningún movimiento de caja se registra

#### Scenario: Sesión de caja informada con una forma de pago que no es efectivo

- **WHEN** se crea un gasto por transferencia informando una sesión de caja
- **THEN** la operación es rechazada con `P0422`
- **AND** no queda ninguna fila nueva ni ningún movimiento

#### Scenario: Sesión cerrada o de otra sucursal

- **WHEN** se crea un gasto en efectivo informando una sesión cerrada, o abierta pero de una sucursal distinta de la del gasto
- **THEN** la operación es rechazada con `P0422`

#### Scenario: Gasto retroactivo en efectivo

- **WHEN** se crea un gasto en efectivo con fecha anterior a hoy informando la sesión abierta de hoy
- **THEN** la operación es rechazada con `P0422`
- **AND** el motivo indica que el impacto en caja sólo aplica a gastos del día

#### Scenario: Un gasto retroactivo se sigue pudiendo registrar

- **WHEN** se crea un gasto en efectivo con fecha anterior a hoy sin informar sesión de caja
- **THEN** el gasto queda persistido normalmente
- **AND** el registro del gasto nunca queda bloqueado por el estado de la caja

#### Scenario: Sesión de caja de otra cuenta

- **WHEN** se crea un gasto informando una sesión de caja que pertenece a otra organización
- **THEN** la operación es rechazada
- **AND** la caja de la otra organización no registra ningún movimiento

### Requirement: El gasto por método bancario registra su movimiento en el ledger bancario

El sistema SHALL delegar la pata bancaria del gasto en el helper transaccional de movimiento bancario de operaciones que ya existe, invocándolo de forma **incondicional** con sentido de egreso y tipo de documento de origen `expense`, igual que lo hacen el alta de venta y el alta de compra. El helper SHALL seguir siendo el único lugar donde vive el predicado de qué `kind` es bancario, la resolución y validación de la cuenta bancaria destino, el mapeo a tipo de movimiento, el signo y el guard de período conciliado.

La fecha valor del movimiento SHALL ser la fecha del gasto, para que la sugerencia automática de conciliación pueda engancharlo contra el extracto; SHALL NOT quedar en nulo.

El helper SHALL NOT modificarse: su comportamiento vigente para venta y compra SHALL permanecer idéntico.

#### Scenario: Gasto por transferencia con cuenta destino resuelta

- **GIVEN** una forma de pago de tipo transferencia y una cuenta bancaria activa de la organización
- **WHEN** se crea un gasto por ese medio
- **THEN** el ledger bancario registra un egreso por el importe del gasto, referenciando el gasto como documento de origen
- **AND** la fecha valor del movimiento es la fecha del gasto

#### Scenario: Gasto en efectivo no toca el banco

- **WHEN** se crea un gasto con forma de pago de tipo efectivo
- **THEN** no se registra ningún movimiento bancario

#### Scenario: El movimiento bancario del gasto es atómico con el gasto

- **WHEN** el alta del gasto falla después de registrar el movimiento bancario
- **THEN** el movimiento bancario se revierte junto con el gasto

#### Scenario: Gasto retroactivo dentro de un período ya conciliado

- **GIVEN** un período de conciliación cerrado para la cuenta bancaria destino
- **WHEN** se crea un gasto por transferencia con fecha dentro de ese período
- **THEN** la operación completa es rechazada
- **AND** no queda ni el gasto ni el movimiento

### Requirement: El gasto con dinero posteado es inmutable

El sistema SHALL rechazar con el código de error `P0423` la edición de un gasto que tenga un movimiento de caja o un movimiento bancario asociado, evaluando los guards **antes** de cualquier escritura, con los mismos predicados de localización que usa el borrado y con el mismo criterio uniforme que ya rige para ventas y compras.

El mensaje de error SHALL distinguir cuál de los dos libros produjo el bloqueo.

El camino de corrección SHALL ser borrar y volver a cargar, que este mismo cambio vuelve seguro al dotar al borrado de compensación.

Un gasto sin movimientos asociados SHALL seguir siendo plenamente editable.

#### Scenario: Editar un gasto con movimiento de caja

- **GIVEN** un gasto en efectivo que registró su egreso de caja
- **WHEN** un usuario intenta editar su importe
- **THEN** la operación es rechazada con `P0423`
- **AND** el mensaje indica que el bloqueo proviene del movimiento de caja
- **AND** ni el gasto ni el movimiento cambian

#### Scenario: Editar un gasto con movimiento bancario

- **GIVEN** un gasto por transferencia que registró su egreso bancario
- **WHEN** un usuario intenta editar su importe
- **THEN** la operación es rechazada con `P0423`
- **AND** el mensaje indica que el bloqueo proviene del movimiento bancario

#### Scenario: Editar un gasto sin dinero posteado

- **GIVEN** un gasto sin forma de pago imputada
- **WHEN** un usuario edita su importe, su categoría o su centro de costo
- **THEN** la edición procede normalmente

#### Scenario: Los gastos históricos siguen siendo editables

- **GIVEN** un gasto anterior a este cambio, sin forma de pago ni movimientos
- **WHEN** un usuario lo edita
- **THEN** la edición procede normalmente

### Requirement: La edición de un gasto preserva su contexto mediante contrato tri-estado

El sistema SHALL aplicar a la edición de un gasto el contrato tri-estado ya vigente en ventas y compras: la **ausencia** de una clave en la petición conserva el valor vigente, un **nulo explícito** desimputa, y un identificador **reimputa**. El contrato SHALL aplicarse a la forma de pago, la sucursal y el centro de costo.

Ningún campo de contexto SHALL perderse por omisión, ni en el alta ni en la edición. Este requisito cierra dos pérdidas silenciosas preexistentes: la sucursal se descartaba al crear y el centro de costo se borraba en cada edición.

El valor reimputado SHALL pertenecer a la misma cuenta y estar activo, con el mismo criterio de rechazo que el alta.

Reenviar el valor que el gasto **ya tiene** SHALL entenderse como preservación y SHALL NOT validarse como una reimputación: la superficie de edición envía siempre la forma de pago vigente y ofrece a propósito las formas dadas de baja para que un gasto histórico siga nombrando la suya, de modo que exigir que esté activa volvería inoperable todo gasto imputado a una forma de pago desactivada después. La pertenencia a la cuenta SHALL verificarse igual en los dos casos.

#### Scenario: Editar el importe conserva la forma de pago y el centro de costo

- **GIVEN** un gasto sin movimientos, con forma de pago y centro de costo imputados
- **WHEN** se edita únicamente su importe
- **THEN** la forma de pago y el centro de costo siguen siendo los mismos

#### Scenario: Desimputar la forma de pago explícitamente

- **WHEN** se edita un gasto enviando la forma de pago en nulo de forma explícita
- **THEN** el gasto queda sin forma de pago imputada

#### Scenario: Reimputar el centro de costo

- **WHEN** se edita un gasto informando otro centro de costo activo de la cuenta
- **THEN** el gasto queda imputado al centro nuevo

#### Scenario: El alta persiste la sucursal que el formulario envía

- **WHEN** un usuario crea un gasto eligiendo una sucursal en el formulario
- **THEN** el gasto queda persistido con esa sucursal
- **AND** el valor no se pierde entre el formulario y la base

#### Scenario: Editar un gasto imputado a una forma de pago desactivada

- **GIVEN** un gasto sin dinero posteado, imputado a una forma de pago que después se desactivó
- **WHEN** se edita cualquier otro campo del gasto reenviando su forma de pago vigente
- **THEN** la edición se aplica
- **AND** el gasto conserva su imputación histórica

#### Scenario: Reimputar a otra forma de pago inactiva sigue rechazándose

- **WHEN** se edita un gasto reimputándolo a una forma de pago distinta de la vigente que está inactiva
- **THEN** la operación es rechazada
- **AND** el gasto conserva su forma de pago anterior

#### Scenario: Reimputar a un valor de otra cuenta es rechazado

- **WHEN** se edita un gasto reimputándolo a una forma de pago, una sucursal o un centro de costo de otra cuenta
- **THEN** la operación es rechazada
- **AND** el gasto conserva sus valores anteriores

#### Scenario: El formulario de edición muestra el contexto vigente

- **WHEN** un usuario abre la edición de un gasto con sucursal, centro de costo y forma de pago imputados
- **THEN** los tres selectores aparecen con el valor vigente preseleccionado

### Requirement: Superficie de gastos con forma de pago

La interfaz SHALL exponer la imputación de forma de pago y su efecto en libros dentro de la pantalla de Gastos, que ya existe y ya está enlazada desde el menú lateral: SHALL NOT crearse una ruta ni una entrada de menú nuevas.

El formulario de gasto SHALL reutilizar el selector de forma de pago y el selector de cuenta bancaria destino que ya usan venta y compra, extendidos con el contexto de gasto y su texto de apoyo propio; SHALL NOT crearse componentes paralelos.

El bloque de impacto en caja SHALL declarar el efecto **antes** de confirmar, y cuando alguna de las tres condiciones no se cumpla SHALL NOT ocultarse en silencio: SHALL mostrarse con el motivo concreto por el que no aplica.

El listado SHALL mostrar la forma de pago de cada gasto y SHALL permitir filtrar por ella. Las etiquetas SHALL usar los tonos semánticos del design system y SHALL NOT usar colores literales.

Toda la superficie SHALL verificarse en escritorio y en móvil, y en tema claro y oscuro.

#### Scenario: Elegir efectivo con la caja abierta

- **GIVEN** una sesión de caja abierta en la sucursal del gasto y la fecha de hoy
- **WHEN** el usuario elige una forma de pago de tipo efectivo en el formulario
- **THEN** aparece el control de impacto en caja indicando la sesión sobre la que se va a registrar
- **AND** el texto declara que el gasto va a descontar de la caja

#### Scenario: Elegir efectivo sin caja abierta

- **GIVEN** ninguna sesión de caja abierta en la sucursal del gasto
- **WHEN** el usuario elige una forma de pago de tipo efectivo
- **THEN** el control de impacto en caja se muestra deshabilitado con el motivo visible
- **AND** el usuario puede guardar el gasto igualmente

#### Scenario: Elegir efectivo con fecha anterior a hoy

- **WHEN** el usuario elige efectivo y una fecha anterior a hoy
- **THEN** el control de impacto en caja se muestra deshabilitado indicando que sólo aplica a gastos del día

#### Scenario: Elegir transferencia muestra el destino bancario

- **GIVEN** una organización con al menos una cuenta bancaria activa
- **WHEN** el usuario elige una forma de pago de tipo transferencia
- **THEN** aparece el selector de cuenta bancaria destino
- **AND** el texto declara que el gasto va a aparecer en la conciliación bancaria

#### Scenario: Listado con la forma de pago visible

- **WHEN** un usuario abre el listado de gastos
- **THEN** cada gasto muestra su forma de pago, y los gastos sin imputar la muestran como "Sin especificar"
- **AND** el listado se puede filtrar por forma de pago

#### Scenario: El buscador declara los campos que busca

- **WHEN** un usuario mira el buscador del listado de gastos
- **THEN** el texto de ayuda nombra los mismos campos que el filtro del servidor busca

#### Scenario: Presentación responsive y por tema

- **WHEN** el formulario y el listado de gastos se muestran en escritorio o en móvil, en tema claro u oscuro
- **THEN** usan los tokens semánticos del design system
- **AND** son legibles y operables en las cuatro combinaciones

### Requirement: El estado de bloqueo del gasto es visible antes de intentar la acción

La interfaz SHALL exponer, para cada gasto del listado, si está bloqueado para edición por tener dinero posteado y si su borrado está bloqueado por no haber sesión de caja abierta donde compensar, derivando los dos estados de los **mismos predicados** que evalúan los guards del servidor, y SHALL deshabilitar cada control mostrando la razón, en lugar de dejar que el usuario descubra el bloqueo recién al recibir el error.

Los dos estados, más la distinción de qué libro produjo el bloqueo, SHALL viajar como **campos derivados de la lectura del gasto**, calculados en el servidor con los mismos predicados de existencia de movimientos que usan los guards, con el mismo mecanismo con el que ya viajan los estados de bloqueo de una venta. El predicado SHALL NOT reimplementarse en el cliente ni derivarse de consultas sueltas por fila.

Para que esos derivados lleguen a la pantalla, el listado de gastos SHALL leerse por el camino de lectura del servidor de la aplicación, paginado y con sus filtros resueltos en el servidor, con el mismo contrato de paginación que ya usa el listado de ventas. El estado de bloqueo SHALL NOT depender de una lectura directa de la tabla de gastos, que sólo expone sus propias columnas y por lo tanto no puede exponer un derivado de los libros.

El diálogo de borrado SHALL enumerar qué se va a compensar en cada libro antes de pedir confirmación, usando esos mismos derivados.

#### Scenario: Gasto con movimiento de caja en el listado

- **WHEN** un usuario ve en el listado un gasto que descontó de la caja
- **THEN** el control de edición aparece deshabilitado
- **AND** la razón del bloqueo es visible

#### Scenario: Gasto sin dinero posteado en el listado

- **WHEN** un usuario ve en el listado un gasto sin forma de pago imputada
- **THEN** el control de edición está habilitado

#### Scenario: El listado recibe el estado de bloqueo del servidor

- **WHEN** se lista una página de gastos
- **THEN** cada fila llega con su estado de bloqueo de edición, su estado de bloqueo de borrado y la indicación de qué libros tiene afectados
- **AND** esos valores provienen de los mismos predicados que evalúan los guards de la edición y del borrado

#### Scenario: Borrado deshabilitado con la caja cerrada

- **WHEN** un usuario ve en el listado un gasto que descontó de la caja mientras no hay ninguna sesión abierta en esa caja
- **THEN** el control de borrado aparece deshabilitado
- **AND** la razón del bloqueo es visible antes de intentar la acción

#### Scenario: Diálogo de borrado de un gasto con dinero posteado

- **WHEN** un usuario abre el diálogo de borrado de un gasto que descontó de caja y registró un egreso bancario
- **THEN** el diálogo enumera la reversión del movimiento de caja y la del movimiento bancario antes de pedir confirmación

### Requirement: Las mutaciones de gasto refrescan todas las superficies que el gasto altera

La interfaz SHALL invalidar, en las tres mutaciones de gasto, no sólo el listado de gastos sino también las superficies de caja, banco, conciliación bancaria y reporte de formas de pago que un gasto puede alterar, reutilizando las claves de caché que ya existen para cada una.

Los paneles de historial de caja y de banco administran su propio estado imperativo, no participan de esa caché y no están montados mientras el usuario opera sobre gastos: SHALL refrescarse al montarse, con el criterio ya vigente de que refrescarlos es responsabilidad de la pantalla que los monta y no de la mutación. Las mutaciones de gasto SHALL NOT intentar forzarlos.

#### Scenario: Alta de un gasto en efectivo

- **WHEN** se crea un gasto que descuenta de la caja
- **THEN** el saldo de la sesión de caja y su historial de movimientos reflejan el egreso sin requerir una recarga manual de la página

#### Scenario: Alta de un gasto por transferencia

- **WHEN** se crea un gasto que registra un egreso bancario
- **THEN** el saldo de la cuenta bancaria, su historial y la lista de movimientos pendientes de conciliar reflejan el egreso sin requerir una recarga manual

#### Scenario: Borrado de un gasto con dinero posteado

- **WHEN** se borra un gasto que había impactado caja y banco
- **THEN** las mismas superficies reflejan los contra-movimientos sin requerir una recarga manual

### Requirement: El importador de gastos no imputa forma de pago

El sistema SHALL NOT aceptar forma de pago en el importador de gastos por archivo: la plantilla SHALL conservar sus columnas actuales y las filas importadas SHALL quedar sin forma de pago imputada y sin efecto en libros.

La ayuda del importador SHALL declararlo explícitamente, y SHALL decirlo sin prometer un efecto que el sistema no produce: imputar la forma de pago después desde el listado es **sólo una etiqueta**, porque la edición de un gasto no postea movimientos; para que el gasto impacte caja o banco hay que cargarlo desde el formulario.

El motivo SHALL ser que el importador emite una llamada por fila sin transacción que abarque el lote: con impacto en libros, un fallo a mitad del proceso dejaría parte de los gastos con movimiento y parte sin él, sin forma de reconstruir el estado.

#### Scenario: Importación de un archivo de gastos

- **WHEN** se importa un archivo con varias filas de gasto
- **THEN** todos los gastos quedan creados sin forma de pago
- **AND** no se registra ningún movimiento de caja ni bancario

#### Scenario: La ayuda del importador declara la limitación

- **WHEN** un usuario abre el diálogo de importación
- **THEN** la ayuda indica que los gastos importados quedan sin forma de pago y sin impacto en libros
- **AND** aclara que imputarles la forma de pago después es sólo una etiqueta y que para impactar los libros hay que cargar el gasto desde el formulario

#### Scenario: Imputar la forma de pago a un gasto importado no mueve ningún libro

- **GIVEN** un gasto creado por importación, sin forma de pago
- **WHEN** se lo edita imputándole una forma de pago de tipo efectivo o de tipo transferencia
- **THEN** el gasto queda con esa forma de pago imputada
- **AND** no se registra ningún movimiento de caja ni bancario
