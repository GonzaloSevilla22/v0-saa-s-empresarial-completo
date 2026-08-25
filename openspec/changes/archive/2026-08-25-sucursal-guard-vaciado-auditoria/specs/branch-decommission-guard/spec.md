## ADDED Requirements

### Requirement: No se da de baja una sucursal con contenido operativo adentro

El sistema SHALL rechazar todo intento de dar de baja una sucursal que tenga contenido operativo, sin escribir ningún cambio sobre la sucursal.

"Dar de baja" abarca las dos formas de baja que el sistema admite: la **desactivación** (la sucursal deja de existir a efectos operativos y desaparece de los selectores) y el **cierre operacional** (la sucursal existe pero no puede operar). Ambas sacan a la sucursal de la resolución de la sucursal por defecto de la cuenta, que es el mecanismo que convierte una baja descuidada en un inventario inalcanzable.

"Contenido operativo" SHALL abarcar tres cosas, evaluadas en este orden:

1. **Existencias**: alguna posición del inventario por sucursal con cantidad distinta de cero. El predicado SHALL ser *distinta de cero* y no *mayor que cero*: una cantidad negativa producto de una anomalía debe bloquear la baja, nunca autorizarla en silencio.
2. **Una sesión de caja abierta** en alguna caja de la sucursal. Desactivar la sucursal deja esa sesión imposible de cerrar desde la interfaz y sus movimientos huérfanos.
3. **Transferencias de stock sin completar** con la sucursal como origen o como destino.

La verificación SHALL leer el **ledger canónico de stock por sucursal** que el sistema ya mantiene. SHALL NOT recalcularse a partir del stock agregado del catálogo ni escribirse una segunda definición de "cuánto hay en esta sucursal".

#### Scenario: Desactivar una sucursal con mercadería es rechazado

- **GIVEN** una sucursal activa con existencias distintas de cero en su inventario
- **WHEN** el owner de la cuenta la desactiva
- **THEN** la operación es rechazada y la sucursal sigue activa

#### Scenario: Desactivar una sucursal vacía funciona

- **GIVEN** una sucursal activa sin existencias, sin sesión de caja abierta y sin transferencias en vuelo
- **WHEN** el owner de la cuenta la desactiva
- **THEN** la sucursal queda inactiva

#### Scenario: Transferir el stock destraba la baja — el recorrido completo del incidente

- **GIVEN** una sucursal activa con existencias y otra sucursal activa de la misma cuenta
- **WHEN** se transfiere la totalidad de las existencias a la otra sucursal y recién entonces se desactiva la primera
- **THEN** la transferencia se completa y la desactivación es aceptada

#### Scenario: Una sesión de caja abierta bloquea la baja

- **GIVEN** una sucursal sin existencias pero con una sesión de caja abierta en una de sus cajas
- **WHEN** se intenta desactivarla
- **THEN** la operación es rechazada y el motivo informado es la sesión de caja, no las existencias

#### Scenario: Una transferencia sin completar bloquea la baja

- **GIVEN** una sucursal sin existencias con una transferencia de stock aún no completada donde figura como origen
- **WHEN** se intenta desactivarla
- **THEN** la operación es rechazada

#### Scenario: El cierre operacional queda sujeto al mismo predicado

- **GIVEN** una sucursal activa con existencias
- **WHEN** se la cierra operacionalmente
- **THEN** la operación es rechazada por el mismo motivo y con el mismo vocabulario de error que la desactivación

---

### Requirement: La verificación vive en el punto de paso obligado de la entidad sucursal

El sistema SHALL aplicar la verificación de vaciado en el punto que atraviesa **toda** escritura sobre la sucursal, y no únicamente dentro de los comandos publicados.

Hoy conviven cuatro caminos capaces de bajar una sucursal: el comando de desactivación, el comando de cierre operacional, la actualización directa que hace la capa de datos del backend contra la tabla, y la escritura directa desde el navegador que las políticas de fila habilitan a quien tenga rol de escritura en la cuenta. Sólo uno de los cuatro verifica algo, y no es el que se usó en el incidente. La verificación SHALL cubrir por construcción a **todos los caminos presentes y futuros**, incluido cualquiera que se agregue después sin acordarse del invariante.

La verificación del punto de paso obligado SHALL ser **autosuficiente**: SHALL NOT delegar ninguna parte de su decisión en un chequeo posterior ni presuponer que el llamador verificó algo antes.

Los comandos publicados SHALL conservar además su propia verificación, como defensa en profundidad y para poder devolver un mensaje más rico. Esa verificación redundante SHALL NOT ser la garantía.

La verificación SHALL evaluar la **transición** hacia la baja, no el estado en que la sucursal queda. Renombrar una sucursal, cambiarle la dirección o **reactivarla** SHALL seguir funcionando aunque tenga existencias.

El predicado de contenido bloqueante SHALL escribirse **una sola vez** y ser consumido por el punto de paso obligado y por los comandos. SHALL NOT existir dos redacciones del mismo predicado susceptibles de divergir.

#### Scenario: La actualización directa contra la tabla también es rechazada

- **GIVEN** una sucursal activa con existencias
- **WHEN** se la desactiva mediante una escritura directa sobre la entidad, sin pasar por ningún comando publicado
- **THEN** la operación es rechazada igual que por el camino del comando

#### Scenario: Renombrar una sucursal con mercadería sigue funcionando

- **GIVEN** una sucursal activa con existencias
- **WHEN** el owner le cambia el nombre
- **THEN** el cambio se aplica

#### Scenario: Reactivar una sucursal inactiva con mercadería sigue funcionando

- **GIVEN** una sucursal inactiva que conserva existencias en su inventario
- **WHEN** el owner la reactiva
- **THEN** la sucursal vuelve a estar activa

#### Scenario: El predicado tiene una única definición

- **WHEN** se inspecciona el esquema tras el cambio
- **THEN** existe una sola definición del inventario de contenido bloqueante de una sucursal, y tanto el punto de paso obligado como los comandos publicados la consumen

---

### Requirement: El borrado físico de una sucursal está prohibido

El sistema SHALL rechazar todo borrado físico de una sucursal, tenga contenido o no, y SHALL nombrar la desactivación como la vía correcta.

La prohibición SHALL ser **incondicional**. Aunque la sucursal esté vacía de existencias, su borrado arrastra en cascada sus cajas y ambos extremos del historial de transferencias en que participó, y anula la imputación de ventas, compras, gastos y movimientos de stock históricos. Los pedidos y los movimientos bancarios, que la referencian sin cascada, harían fallar el borrado con un error de integridad ilegible. Es decir: hoy el borrado físico destruye inventario en silencio o revienta con un mensaje inútil, según qué haya en la cuenta.

La política de borrado ya adoptada por el proyecto excluye a las sucursales del borrado lógico de maestros con este mismo razonamiento — la sucursal se desactiva, no se borra. Este requisito le da **cumplimiento** a una decisión que hasta ahora sólo estaba escrita.

#### Scenario: Borrar una sucursal con mercadería es rechazado

- **GIVEN** una sucursal con existencias
- **WHEN** se intenta borrarla físicamente
- **THEN** la operación es rechazada y la sucursal y su inventario siguen existiendo

#### Scenario: Borrar una sucursal vacía también es rechazado

- **GIVEN** una sucursal sin existencias, sin cajas con sesión abierta y sin transferencias en vuelo
- **WHEN** se intenta borrarla físicamente
- **THEN** la operación es rechazada y el mensaje indica que la vía correcta es desactivarla

---

### Requirement: El rechazo informa cuánto hay adentro y qué hacer para destrabarlo

El sistema SHALL informar, en el rechazo, **el motivo concreto con sus cantidades** y **la acción que destraba la baja**.

Cuando lo que bloquea son existencias, el mensaje SHALL nombrar la cantidad de unidades y la cantidad de productos involucrados, y SHALL nombrar la transferencia a otra sucursal como la acción que destraba. Un mensaje que sólo diga "la sucursal tiene stock" reproduce el problema original: el PO, que conoce el sistema, no sabía que la transferencia existía.

Cuando la sucursal es la **única** de la cuenta, el mensaje SHALL distinguir ese caso y decir que primero hay que crear la sucursal destino, en lugar de mandar a una transferencia imposible.

El error SHALL identificarse con un código propio, distinto de los ya asignados y verificado libre tanto en el repositorio como en las funciones vivas del sistema en producción, y SHALL traducirse a un estado de conflicto de la interfaz de programación pública, de la misma familia que los demás conflictos de estado del sistema.

El vocabulario textual que la traducción del cliente ya reconoce para el caso de existencias SHALL conservarse dentro del mensaje, de modo que la traducción existente siga funcionando sin modificarse cuando el comando de cierre se unifique al código nuevo.

#### Scenario: El mensaje cuenta las unidades

- **GIVEN** una sucursal con 585 unidades repartidas en 518 productos
- **WHEN** se intenta desactivarla
- **THEN** el rechazo nombra la cantidad de unidades y de productos, y menciona la transferencia a otra sucursal

#### Scenario: La única sucursal de la cuenta recibe un mensaje distinto

- **GIVEN** una cuenta con una sola sucursal, que tiene existencias
- **WHEN** se intenta desactivarla
- **THEN** el rechazo indica que primero hay que crear otra sucursal a la cual transferir

#### Scenario: El código de error es propio y no colisiona

- **WHEN** se censan los códigos de error del repositorio y los de las funciones vivas del sistema en producción
- **THEN** el código elegido para este rechazo no aparece en ninguno de los dos censos antes de este cambio

#### Scenario: La traducción existente del cliente sigue funcionando tras unificar el cierre

- **GIVEN** un cliente que traduce el rechazo de cierre por su vocabulario textual y no por su código
- **WHEN** el comando de cierre pasa a usar el código nuevo
- **THEN** el cliente sigue mostrando su mensaje traducido, sin cambios en su lógica de traducción
