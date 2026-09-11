## MODIFIED Requirements

### Requirement: Dimensión de rol estructurada para RBAC futuro

El catálogo `document_status_transitions` SHALL declarar, por transición, el **conjunto** de roles de tenant habilitados a ejecutarla (`allowed_role`). Un conjunto ausente SHALL significar "sin restricción de rol", NOT "ningún rol habilitado": es la forma en que se declaran las transiciones que no ejecuta una persona.

El sistema SHALL hacer cumplir esa dimensión (RN-A4): deja de ser estructura inerte y pasa a ser la política que el registro de transición evalúa.

Poblar, ampliar o restringir el conjunto de roles de una transición SHALL requerir únicamente un cambio de datos sobre el catálogo, sin modificar ninguna función ni ninguna política.

#### Scenario: Una transición sin roles declarados no verifica el rol del actor
- **WHEN** se registra una transición cuya fila de catálogo no declara roles
- **THEN** la transición se acepta sin verificar el rol del actor

#### Scenario: Una transición declara varios roles habilitados
- **WHEN** se consulta la fila de catálogo de una transición que pueden ejecutar tanto un vendedor como un administrador
- **THEN** la fila declara ambos roles, sin necesidad de duplicar la fila ni de elegir uno solo

#### Scenario: Restringir una transición es un cambio de datos
- **WHEN** se retira un rol del conjunto habilitado de una transición
- **THEN** basta un cambio de datos sobre el catálogo, sin modificar la función que registra transiciones ni ninguna política

### Requirement: Registro de transición valida y exige motivo cuando corresponde

El sistema SHALL exponer un helper de escritura (`record_status_transition`) que, en la misma transacción de la transición: valida la transición contra la política (salvo cuando `from_status` es NULL, que representa la creación), exige un `reason` no vacío cuando la política marca `requires_reason` para el estado destino (RN-A5), **verifica que el actor esté habilitado por la política para ejecutar esa transición**, e inserta la fila de historial. El helper SHALL ser invocable solo desde funciones internas con privilegios elevados, NOT directamente por el rol `authenticated`.

La verificación de rol SHALL tener exactamente dos exenciones, ambas explícitas:

1. Cuando la transición se ejecuta **sin actor humano** —el actor recibido es nulo, como ocurre en el relay fiscal y en los procesos programados—, la verificación de rol NOT SHALL aplicarse. Un proceso de sistema NOT SHALL requerir una membresía para transicionar un documento.
2. Cuando la fila de catálogo no declara ningún rol habilitado, la verificación NOT SHALL aplicarse.

Fuera de esas exenciones, el sistema SHALL rechazar la transición cuando ninguno de los roles activos del actor en la cuenta del documento figure entre los habilitados, con un código de error que la capa de aplicación traduzca a una denegación por permisos insuficientes.

Un rol **vencido** del actor NOT SHALL habilitar una transición.

#### Scenario: Un actor con rol habilitado ejecuta la transición
- **GIVEN** un actor con un rol activo que figura entre los habilitados para la transición
- **WHEN** ejecuta esa transición
- **THEN** la transición se registra y el documento cambia de estado

#### Scenario: Un actor sin rol habilitado es rechazado
- **GIVEN** un actor cuyos roles activos no incluyen ninguno de los habilitados para la transición
- **WHEN** intenta ejecutar esa transición
- **THEN** la operación es rechazada por permisos insuficientes, el documento no cambia de estado y no se registra fila de historial

#### Scenario: El relay fiscal transiciona sin actor
- **GIVEN** una transición de documento fiscal ejecutada por el relay, sin actor humano
- **WHEN** se registra la transición
- **THEN** se acepta sin verificar rol alguno

#### Scenario: Un proceso programado transiciona sin actor
- **GIVEN** el proceso que vence presupuestos, ejecutándose sin actor humano
- **WHEN** registra la transición a vencido
- **THEN** se acepta sin verificar rol alguno

#### Scenario: Un rol vencido no habilita la transición
- **GIVEN** un actor cuyo único rol habilitado para esa transición ya venció
- **WHEN** intenta ejecutar la transición
- **THEN** la operación es rechazada por permisos insuficientes

#### Scenario: El motivo se sigue exigiendo con independencia del rol
- **GIVEN** un actor con rol habilitado y una transición cuya política exige motivo
- **WHEN** ejecuta la transición sin motivo
- **THEN** la operación es rechazada por falta de motivo

## ADDED Requirements

### Requirement: La política de roles por transición refleja la segregación de funciones del negocio

El catálogo SHALL declarar los roles habilitados de cada transición de acuerdo con la segregación de funciones del negocio (RN-A4), de modo que quien cobra NOT SHALL poder anular, y quien mueve mercadería NOT SHALL confirmar operaciones de compra.

Las transiciones que ejecuta un proceso automático y no una persona —la emisión y resolución de comprobantes fiscales, y el vencimiento automático de presupuestos— SHALL quedar declaradas sin roles habilitados, de modo que ningún cambio de la política de roles pueda interrumpirlas.

#### Scenario: El cajero confirma una venta
- **GIVEN** un actor cuyo único rol activo es el de cajero
- **WHEN** confirma una orden de venta en borrador
- **THEN** la transición se registra

#### Scenario: El cajero no anula una venta confirmada
- **GIVEN** un actor cuyo único rol activo es el de cajero
- **WHEN** intenta anular una orden de venta confirmada
- **THEN** la operación es rechazada por permisos insuficientes

#### Scenario: El encargado de depósito completa una transferencia de stock
- **GIVEN** un actor cuyo único rol activo es el de depósito
- **WHEN** completa una transferencia de stock entre sucursales
- **THEN** la transición se registra

#### Scenario: El contable abre y cierra una conciliación
- **GIVEN** un actor cuyo único rol activo es el contable
- **WHEN** abre una sesión de conciliación bancaria y luego la cierra
- **THEN** ambas transiciones se registran

#### Scenario: Las transiciones fiscales quedan sin roles declarados
- **WHEN** se consultan las filas de catálogo de las transiciones de comprobante fiscal
- **THEN** ninguna declara roles habilitados
