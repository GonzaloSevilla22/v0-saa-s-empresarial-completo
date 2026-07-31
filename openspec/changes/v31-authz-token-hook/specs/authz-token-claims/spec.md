## ADDED Requirements

### Requirement: Espacios de nombres separados para rol de plataforma y rol de tenant

El sistema SHALL tratar el rol de **plataforma** (quién es staff del producto) y el rol de **tenant** (qué puede hacer una persona dentro de su propia empresa) como dos dimensiones independientes, cada una con su propio claim en el token de acceso y su propio conjunto de valores admitidos. Un claim NOT SHALL transportar valores del otro espacio de nombres, aun cuando ambos espacios compartan un nombre de rol homónimo.

El claim de rol de plataforma SHALL conservar el nombre y la semántica que los consumidores existentes ya asumen, de modo que habilitar la emisión de claims NOT SHALL alterar el resultado de autorización de ningún consumidor que hoy funcione.

#### Scenario: El rol de tenant no desplaza al rol de plataforma

- **WHEN** se emite un token para un usuario que es dueño de su cuenta y no es staff de la plataforma
- **THEN** el claim de rol de plataforma contiene el valor de plataforma de ese usuario, y el rol de dueño viaja exclusivamente en el claim de rol de tenant

#### Scenario: Habilitar la emisión de claims no cambia decisiones de autorización preexistentes

- **WHEN** se habilita la emisión de claims y un usuario ejercita un endpoint cuya autorización depende del rol de plataforma
- **THEN** la decisión de autorización es la misma que antes de habilitarla

### Requirement: Claims de autorización emitidos en el token de acceso

El sistema SHALL inyectar en cada token de acceso emitido —tanto en el login como en cada renovación— los claims de autorización derivados del estado vigente en la base de datos: el rol de plataforma del usuario, el rol de tenant que el usuario tiene en su cuenta activa, y el plan efectivo de esa cuenta.

El plan efectivo SHALL respetar la regla ya vigente de la capability de gating por plan: un período de prueba vigente tiene precedencia sobre el plan contratado.

#### Scenario: El token de un usuario con cuenta y plan trae los tres claims

- **WHEN** se emite un token para un usuario que pertenece a una cuenta
- **THEN** el token contiene el rol de plataforma del usuario, el rol de tenant en su cuenta activa y el plan efectivo de esa cuenta

#### Scenario: Un período de prueba vigente determina el plan del claim

- **GIVEN** una cuenta con plan contratado básico y un período de prueba vigente de un plan superior
- **WHEN** se emite un token para un miembro de esa cuenta
- **THEN** el claim de plan contiene el plan del período de prueba, no el plan contratado

#### Scenario: Los claims se recalculan en cada renovación

- **GIVEN** un usuario con un token vigente emitido antes de que cambiara el plan de su cuenta
- **WHEN** el token se renueva
- **THEN** el claim de plan del token nuevo refleja el plan vigente al momento de la renovación

### Requirement: Resolución determinística de la cuenta activa

El sistema SHALL resolver la cuenta activa de un usuario mediante un criterio de ordenamiento explícito y estable, y SHALL usar ese mismo criterio tanto al emitir los claims del token como al resolver la cuenta sobre la que opera un request. Una resolución sin ordenamiento definido NOT SHALL considerarse aceptable, aunque hoy ningún usuario pertenezca a más de una cuenta.

#### Scenario: El claim y el resolver de cuenta coinciden bajo multi-membresía

- **GIVEN** un usuario que pertenece a más de una cuenta
- **WHEN** se emite su token y a continuación opera sobre un endpoint que resuelve la cuenta del tenant
- **THEN** la cuenta descrita por los claims del token es la misma sobre la que opera el endpoint

#### Scenario: La resolución es estable entre invocaciones

- **GIVEN** un usuario con varias membresías, sin cambios en ellas
- **WHEN** se resuelve su cuenta activa repetidas veces
- **THEN** el resultado es siempre el mismo

### Requirement: La emisión de claims degrada sin romper la autenticación, y deja rastro

La emisión de claims SHALL estar blindada de forma que cualquier error durante su cálculo devuelva los claims originales intactos y NOT SHALL impedir que el usuario obtenga su token. Ese blindaje NOT SHALL ocultar el error: toda degradación SHALL registrar una advertencia con el código de error, de modo que una falta de permisos de lectura o un cambio de esquema sea diagnosticable en lugar de manifestarse como claims ausentes.

El proceso de emisión SHALL tener concedidos, de forma explícita, los permisos de lectura sobre cada tabla de la que derive un claim.

#### Scenario: Un error de cálculo no impide el login

- **GIVEN** una condición de error durante el cálculo de los claims
- **WHEN** un usuario inicia sesión
- **THEN** el usuario obtiene un token válido con los claims originales, y el inicio de sesión no falla

#### Scenario: La degradación queda registrada

- **WHEN** el cálculo de los claims degrada por un error
- **THEN** se registra una advertencia que identifica el error, en lugar de degradar en silencio

#### Scenario: El despliegue falla si la emisión no produce los claims esperados

- **WHEN** se despliega la definición de la emisión de claims y una verificación la ejercita contra un usuario existente
- **THEN** el despliegue falla si el resultado no contiene los tres claims, en lugar de dejar la falla para producción

### Requirement: La habilitación en producción es una acción deliberada fuera del repositorio

El sistema SHALL mantener la definición de la emisión de claims versionada en el repositorio y desplegable por el pipeline, pero su **activación** en producción SHALL ser una acción explícita sobre la configuración del proveedor de autenticación, ejecutada por una persona con autoridad para ello. La configuración local de desarrollo NOT SHALL considerarse evidencia del estado de producción.

Desactivar la emisión SHALL restituir el comportamiento previo sin requerir ninguna operación destructiva sobre datos ni forzar el cierre de sesiones activas.

#### Scenario: Desplegar la definición no activa la emisión

- **WHEN** el pipeline despliega la definición de la emisión de claims
- **THEN** los tokens siguen emitiéndose sin los claims hasta que la activación se realice explícitamente

#### Scenario: Desactivar restituye el estado previo sin efectos destructivos

- **WHEN** se desactiva la emisión de claims
- **THEN** los tokens siguientes se emiten sin los claims, los tokens ya emitidos siguen siendo válidos, y no se pierde ningún dato

### Requirement: Verificación de la emisión sin exponer tokens ni credenciales

El sistema SHALL ofrecer un medio de verificar que los claims llegan efectivamente al token, que NOT SHALL requerir fabricar credenciales, iniciar sesión en nombre de otra persona, ni exponer el token o su contenido crudo. La verificación SHALL informar, para el usuario que la solicita y sólo para él, la presencia de cada claim y su valor efectivo.

La verificación NOT SHALL basarse en los metadatos persistidos del usuario: la emisión de claims afecta únicamente al token emitido y no modifica el registro del usuario, de modo que inspeccionar ese registro produciría una conclusión incorrecta.

#### Scenario: El usuario autenticado consulta el estado de sus claims

- **WHEN** un usuario autenticado consulta el diagnóstico de claims
- **THEN** obtiene la presencia de cada claim y sus valores efectivos, sin que la respuesta incluya el token ni su contenido crudo

#### Scenario: El diagnóstico no revela información de terceros

- **WHEN** un usuario autenticado consulta el diagnóstico de claims
- **THEN** la respuesta describe únicamente su propia sesión

#### Scenario: Los metadatos persistidos del usuario no cambian al activar la emisión

- **GIVEN** la emisión de claims activada
- **WHEN** un usuario obtiene un token nuevo
- **THEN** el token contiene los claims y el registro persistido del usuario permanece sin modificar

### Requirement: Contrato de evolución hacia múltiples roles por miembro

El claim de rol de tenant SHALL ser singular mientras la membresía admita un único rol por miembro. Cuando la membresía pase a admitir múltiples roles con vigencia, el sistema SHALL introducir un claim **nuevo** que transporte el conjunto de roles activos —excluyendo los vencidos— y SHALL conservar el claim singular como valor derivado de compatibilidad mientras existan tokens emitidos con el contrato anterior. La forma del claim singular NOT SHALL redefinirse para transportar un conjunto.

#### Scenario: La introducción de múltiples roles no redefine el claim existente

- **WHEN** el modelo de membresía pasa a admitir varios roles por miembro
- **THEN** el conjunto de roles viaja en un claim nuevo y el claim singular preexistente conserva su forma y su significado
