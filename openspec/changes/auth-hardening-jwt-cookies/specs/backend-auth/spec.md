## MODIFIED Requirements

### Requirement: Validación de JWT de Supabase

El middleware SHALL verificar los tokens contra las **JWKS públicas de Supabase** (`ES256`/`RS256`), que es el camino que corre en producción, y SHALL rechazar el token si su firma, su emisor, su audiencia o su vigencia no son válidos.

La verificación SHALL exigir explícitamente la presencia de los claims `exp` y `sub`: un token válidamente firmado que carezca de cualquiera de los dos SHALL rechazarse, en lugar de aceptarse (`exp`) o de fallar con un error del servidor (`sub`). La verificación SHALL admitir una tolerancia de reloj acotada, de modo que una diferencia menor entre el reloj del host y el del emisor no rechace tokens recién emitidos.

La verificación con **secreto compartido y algoritmo `HS256`** SHALL ser un camino de desarrollo y de tests, habilitado **únicamente** por una palanca de configuración explícita cuyo valor por defecto es "deshabilitado". Con la palanca deshabilitada, el camino `HS256` NOT SHALL ser alcanzable por omisión de una variable de entorno.

#### Scenario: Token firmado por el proveedor se acepta por el camino JWKS

- **GIVEN** la URL del proveedor configurada y la palanca de `HS256` deshabilitada
- **WHEN** llega un token firmado con la clave vigente del proveedor, con emisor y audiencia correctos y no vencido
- **THEN** se decodifica resolviendo la clave de firma por su identificador desde las JWKS y se retorna el contexto de autenticación

#### Scenario: Token sin `exp` se rechaza

- **WHEN** llega un token correctamente firmado que no declara vencimiento
- **THEN** la verificación lo rechaza con no autorizado, en lugar de aceptarlo por tiempo indefinido

#### Scenario: Token sin `sub` responde no autorizado, no error del servidor

- **WHEN** llega un token correctamente firmado que no declara sujeto
- **THEN** la respuesta es no autorizado, y no un error interno del servidor

#### Scenario: Una diferencia menor de reloj no rechaza el token

- **GIVEN** un reloj del host levemente atrasado respecto del emisor
- **WHEN** llega un token recién emitido
- **THEN** la verificación lo acepta gracias a la tolerancia de reloj declarada

#### Scenario: El camino HS256 exige la palanca explícita

- **GIVEN** la palanca de `HS256` habilitada explícitamente y sin URL del proveedor configurada
- **WHEN** llega un token firmado con el secreto compartido
- **THEN** se decodifica por ese camino y se retorna el contexto de autenticación

#### Scenario: La rama que corre en producción está cubierta por tests

- **WHEN** se revisa la suite del backend
- **THEN** existe al menos un test que ejercita la verificación por JWKS con una clave asimétrica, además de los que ejercitan el camino del secreto compartido

### Requirement: Sin verificación de audience

El middleware SHALL verificar la audiencia del token contra el valor que emite el proveedor para usuarios autenticados, y SHALL verificar además el emisor contra la URL del proveedor configurada.

La verificación de audiencia SHALL realizarse declarando el valor esperado, no desactivando la comprobación: un token cuya audiencia no coincida SHALL rechazarse, y un token con la audiencia esperada NOT SHALL rechazarse por el hecho de que ese valor no sea una URL.

#### Scenario: Token con la audiencia esperada se acepta

- **GIVEN** un token válido cuyo claim de audiencia es el valor que el proveedor emite para usuarios autenticados
- **WHEN** se decodifica
- **THEN** la verificación de audiencia pasa y el token se acepta si el resto de las validaciones son correctas

#### Scenario: Token con otra audiencia se rechaza

- **WHEN** llega un token correctamente firmado cuya audiencia es distinta de la esperada
- **THEN** la verificación lo rechaza con no autorizado

#### Scenario: Token de otro emisor se rechaza

- **WHEN** llega un token correctamente firmado cuyo emisor no corresponde al proveedor configurado
- **THEN** la verificación lo rechaza con no autorizado

### Requirement: Resolución del rol de tenant con respaldo en la base durante la transición

Cuando un guard requiera el rol de tenant, el backend SHALL evaluar el **conjunto** de roles activos del usuario y SHALL autorizar si alguno de ellos figura entre los permitidos por el guard.

El conjunto SHALL resolverse por el primero disponible de estos caminos, en orden: el claim del token que transporta el conjunto; el claim singular de rol de tenant, interpretado como un conjunto de un solo elemento —situación esperada mientras sigan vigentes tokens emitidos antes de la ampliación del contrato—; y, si ninguno de los dos claims viaja, la consulta de las asignaciones de rol del usuario en su cuenta activa. Esa consulta SHALL leer las asignaciones vigentes, NOT una columna de rol único que haya dejado de ser la fuente de verdad.

**Excepción para las acciones de configuración**: cuando el conjunto permitido por el guard es el conjunto nombrado que habilita configurar la cuenta, el backend SHALL consultar las asignaciones vigentes en la base **aunque el claim esté presente**, y SHALL decidir con lo que devuelve la base. Para esas acciones el claim SHALL tratarse como un caché y la base como la autoridad, de modo que un rol revocado o vencido deje de autorizar sin esperar a la próxima emisión de token.

Si no puede determinarse ningún rol de tenant por ninguna de las vías, el guard SHALL denegar. La ausencia de información de rol NOT SHALL resolverse asumiendo un rol permisivo.

El backend SHALL exponer los conjuntos de roles permitidos como **capacidades nombradas declaradas en un único lugar**, y los puntos de autorización NOT SHALL enumerar roles literales de forma dispersa.

#### Scenario: El claim del conjunto evita la consulta a la base

- **GIVEN** un token que trae el claim con el conjunto de roles de tenant
- **WHEN** se ejercita un endpoint cuyo guard requiere rol de tenant y cuyo conjunto permitido no es el de configuración
- **THEN** la decisión se toma con el valor del claim, sin consultar las asignaciones en la base

#### Scenario: Una acción de configuración consulta la base aunque el claim esté

- **GIVEN** un token que trae el claim con el conjunto de roles de tenant
- **WHEN** se ejercita un endpoint cuyo guard requiere el conjunto de configuración
- **THEN** la autorización consulta las asignaciones vigentes en la base y decide con ese resultado

#### Scenario: Un rol revocado deja de configurar antes de que venza el token

- **GIVEN** un usuario cuyo rol de configuración fue revocado y cuyo token todavía lo declara en el claim
- **WHEN** intenta una acción de configuración
- **THEN** el acceso se deniega, porque la base ya no registra ese rol como vigente

#### Scenario: Basta un rol del conjunto para autorizar

- **GIVEN** un usuario cuyo conjunto de roles activos incluye uno de los permitidos por el guard y varios que no lo están
- **WHEN** se ejercita ese endpoint
- **THEN** el acceso se concede

#### Scenario: Un token anterior a la ampliación resuelve por el claim singular

- **GIVEN** un token emitido antes de la ampliación del contrato, que trae el rol de tenant singular y no el conjunto
- **WHEN** se ejercita un endpoint cuyo guard requiere rol de tenant y cuyo conjunto permitido no es el de configuración
- **THEN** el rol singular se interpreta como un conjunto de un elemento y la autorización produce el mismo resultado que antes de la ampliación

#### Scenario: Un token sin ningún claim de rol resuelve contra las asignaciones

- **GIVEN** un token emitido antes de habilitar la emisión de claims, todavía vigente
- **WHEN** se ejercita un endpoint cuyo guard requiere rol de tenant
- **THEN** el conjunto se resuelve consultando las asignaciones de rol vigentes del usuario, y la autorización produce el mismo resultado que con el claim presente

#### Scenario: Un rol vencido no autoriza por ninguna vía

- **GIVEN** un usuario cuya única asignación que habilitaba el endpoint ya venció, y un token sin claims de rol
- **WHEN** se ejercita ese endpoint
- **THEN** el acceso se deniega

#### Scenario: Sin membresía, el guard deniega

- **GIVEN** un usuario autenticado sin membresía en ninguna cuenta y un token sin claims de rol de tenant
- **WHEN** se ejercita un endpoint cuyo guard requiere rol de tenant
- **THEN** el acceso se deniega, en lugar de concederse por ausencia de información

#### Scenario: Los conjuntos permitidos se declaran una sola vez

- **WHEN** se revisa cómo cada punto de autorización declara los roles que admite
- **THEN** lo hace mediante una capacidad nombrada, y el conjunto de roles de esa capacidad está definido en un único lugar del backend

## ADDED Requirements

### Requirement: El token viaja únicamente por el encabezado de autorización

El backend SHALL aceptar el token de usuario final **exclusivamente** por el encabezado de autorización con esquema Bearer, y NOT SHALL aceptarlo por parámetro de consulta, por cuerpo de la petición ni por cookie.

El motivo es que un parámetro de consulta queda escrito en los registros del proveedor de hosting y en cualquier intermediario, mientras que un encabezado no.

#### Scenario: Endpoint HTTP recibe el token por el encabezado de autorización

- **WHEN** un cliente llama a un endpoint protegido con el encabezado de autorización y esquema Bearer
- **THEN** el token se extrae de ese encabezado y se inyecta en la dependencia de autenticación

#### Scenario: No existe ningún camino que acepte el token por parámetro de consulta

- **WHEN** se revisa la superficie del backend en busca de extracciones de token
- **THEN** ninguna las obtiene de un parámetro de consulta

### Requirement: Una configuración de autenticación inválida impide el arranque

El backend SHALL validar en el arranque que la configuración de verificación de tokens sea coherente, y SHALL abortar el arranque cuando no lo sea, en lugar de degradar silenciosamente en el primer request.

En particular, cuando la palanca del camino con secreto compartido está deshabilitada y la URL del proveedor está ausente o no es una URL segura, el proceso NOT SHALL levantar. El mensaje de error SHALL nombrar la variable de configuración faltante.

#### Scenario: Sin URL del proveedor y sin palanca, el proceso no levanta

- **GIVEN** la palanca del camino con secreto compartido deshabilitada y la URL del proveedor ausente
- **WHEN** se inicia la aplicación
- **THEN** el arranque falla con un error de configuración que nombra la variable faltante, y la aplicación no atiende ningún request

#### Scenario: Con la configuración correcta el arranque es normal

- **GIVEN** la URL del proveedor configurada como URL segura
- **WHEN** se inicia la aplicación
- **THEN** el arranque se completa y la verificación usa el camino por JWKS

### Requirement: Un fallo de las JWKS se distingue de un token inválido en los registros

El backend SHALL registrar de forma diferenciada el fallo al obtener o resolver las claves públicas del proveedor, con nivel de advertencia, y SHALL seguir respondiendo no autorizado al cliente.

Un fallo de disponibilidad del proveedor de claves NOT SHALL ser indistinguible en los registros de un token forjado o vencido, porque son incidentes distintos con respuestas operativas distintas.

#### Scenario: Caída del proveedor de claves deja rastro propio

- **GIVEN** el endpoint de claves públicas del proveedor inaccesible
- **WHEN** llega una petición con un token
- **THEN** el backend registra una advertencia identificando el fallo de obtención de claves y responde no autorizado

#### Scenario: Un token forjado no genera esa advertencia

- **WHEN** llega un token con firma inválida
- **THEN** el backend responde no autorizado sin registrar el fallo de obtención de claves

## REMOVED Requirements

### Requirement: Header Bearer en HTTP, query param en WebSocket

**Reason**: El canal WebSocket propio se retira por completo en este change (ver la capability `realtime-websocket`): autenticaba el handshake pero no autorizaba la sala, recibía el token por parámetro de consulta —que queda escrito en los registros del proveedor de hosting— y validaba una sola vez para toda la vida de la conexión. Sin ese canal, el parámetro de consulta deja de ser un transporte válido de token en ningún punto del backend.

**Migration**: El transporte del token queda fijado por el requisito nuevo "El token viaja únicamente por el encabezado de autorización". No hay consumidor que migrar: ningún archivo del frontend abría una conexión a ese canal, y el tiempo real de la aplicación ocurre por la integración de Realtime del proveedor, que lleva el token por su propio canal.
