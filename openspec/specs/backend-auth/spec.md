# backend-auth — Spec

## Purpose

Middleware de autenticación para FastAPI que valida JWTs emitidos por Supabase. FastAPI no emite tokens propios — actúa como resource server que verifica la firma del token.
## Requirements
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

### Requirement: Claims extraídos

El dependency SHALL retornar, tras una validación exitosa, el objeto `{"user_id": str, "role": str}`, donde `user_id` = claim `sub` y `role` = claim `role` (default: `"authenticated"` si ausente).

> **Superado por "Contrato tipado del contexto de autenticación" (más abajo, `v31-fix-auth-shape-500`, 2026-07-31).** El shape real incluye una tercera clave (`plan`) y el default de `role` cuando el claim está ausente es `"user"`, no `"authenticated"`. Se conserva este requisito legacy sin editar para no perder historial; el requisito nuevo es la fuente normativa vigente. Normalizar el resto del archivo al formato canónico es trabajo de `v31-docs-refresh` (H-22), fuera de alcance de este sync.

#### Scenario: El objeto real producido diverge del shape de dos claves aquí descripto

- **GIVEN** el contexto que produce hoy `get_current_user` (`backend/core/auth.py`)
- **WHEN** se lo compara contra el objeto `{"user_id": str, "role": str}` con default `"authenticated"` que describe este requisito
- **THEN** el objeto real contiene tres claves (`user_id`, `role`, `plan`) y el default de `role` cuando el claim de `app_metadata` está ausente es `"user"` — no `"authenticated"` —, tal como fija el requisito vigente "Contrato tipado del contexto de autenticación" y confirma `test_token_without_role_defaults_user`

### Requirement: Token inválido → 401

Si el token tiene firma incorrecta, ha expirado, o está malformado, el middleware SHALL responder HTTP 401 con body `{"detail": "Invalid token"}`.

#### Scenario: Firma incorrecta o token expirado responden 401

- **WHEN** el token presenta una firma inválida o ya expiró
- **THEN** `get_current_user` captura `PyJWTError`/`PyJWKClientError` y lanza `HTTPException(status_code=401, detail="Invalid token")`, verificado por `test_invalid_signature_raises_401` y `test_expired_token_raises_401` en `backend/tests/test_auth.py`

#### Scenario: Token ausente responde 401 antes de intentar decodificar

- **WHEN** no se provee ningún token (el `Authorization` header está ausente y `oauth2_scheme` resuelve `token` como vacío)
- **THEN** `get_current_user` responde HTTP 401 con `{"detail": "Invalid token"}` sin llegar a invocar `pyjwt.decode`

### Requirement: Contrato tipado del contexto de autenticación

El dependency de autenticación del backend SHALL declarar el contexto que produce como un tipo explícito (`AuthContext`) con exactamente tres claves obligatorias: `user_id` (el claim `sub` del JWT), `role` (el rol de aplicación) y `plan` (el plan comercial). El tipo SHALL ser la única declaración normativa de ese contrato: cualquier clave que el dependency produzca SHALL estar declarada en el tipo, y cualquier clave declarada en el tipo SHALL ser producida por el dependency. El contrato SHALL ser un mapeo (compatible con acceso por clave), de modo que los consumidores existentes no requieran reescritura.

Este requisito reemplaza la descripción del contexto de `REQ-BA-02`, que documenta un shape de dos claves (`user_id`, `role`) que el código dejó atrás al incorporar `plan`, y que atribuye a `role` un valor por defecto (`authenticated`) distinto del que el sistema produce.

#### Scenario: El contexto expone las tres claves del contrato

- **WHEN** un request presenta un JWT válido y el dependency de autenticación resuelve el contexto
- **THEN** el contexto contiene exactamente las claves `user_id`, `role` y `plan`, con `user_id` igual al claim `sub` del token

#### Scenario: Una divergencia entre el tipo declarado y el contexto producido falla la suite

- **WHEN** el conjunto de claves que el dependency produce deja de coincidir con el conjunto de claves declaradas en el tipo (por agregado, renombre o eliminación en cualquiera de los dos lados)
- **THEN** la suite de tests falla, en lugar de propagar el contexto divergente

### Requirement: Los consumidores derivan actor y tenant de las fuentes canónicas

Todo consumidor del contexto de autenticación SHALL derivar la identidad del actor exclusivamente de la clave `user_id`, y NOT SHALL leer claves ausentes del contrato (en particular `sub` o `account_id`, que el contexto no expone). La cuenta (tenant) sobre la que opera un endpoint SHALL resolverse mediante la dependencia de resolución de cuenta del backend, y NOT SHALL derivarse de la identidad del usuario ni de ningún claim del JWT.

Un acceso a una clave inexistente con valor por defecto vacío SHALL considerarse un defecto, no una degradación aceptable: propaga una cadena vacía a columnas que esperan un identificador y produce un fallo del servidor aguas abajo.

#### Scenario: La creación de un presupuesto registra al actor real

- **WHEN** un usuario autenticado crea un presupuesto
- **THEN** el presupuesto se persiste con el identificador del usuario autenticado como autor, y el endpoint responde con éxito en lugar de fallar con un error del servidor

#### Scenario: Los endpoints de cuenta corriente operan sobre la cuenta resuelta

- **WHEN** un usuario autenticado consulta la cuenta corriente de un cliente o de un proveedor
- **THEN** la consulta se ejecuta contra la cuenta resuelta por la dependencia de resolución de cuenta, y el endpoint responde con éxito en lugar de fallar con un error del servidor

#### Scenario: Ningún consumidor lee claves fuera del contrato

- **WHEN** se revisa el backend en busca de lecturas del contexto de autenticación
- **THEN** toda lectura referencia únicamente claves declaradas en el contrato, sin valores por defecto que sustituyan una clave ausente

### Requirement: Los dobles de test no pueden divergir del contrato real

Los dobles de test que sustituyan el contexto de autenticación SHALL construirse a partir del contrato declarado, y la suite SHALL contener al menos una verificación que observe el identificador efectivamente propagado a la capa de datos en los endpoints que lo consumen. Un test NOT SHALL considerarse cobertura válida si su doble reproduce el mismo error que el código bajo prueba, de modo que ambos defectos se cancelen y el test pase.

#### Scenario: El test observa el identificador que llega a la capa de datos

- **WHEN** se ejercita un endpoint que persiste la identidad del actor o la cuenta del tenant
- **THEN** el test verifica el valor concreto recibido por el repositorio, y falla si ese valor es una cadena vacía o difiere del identificador autenticado

### Requirement: El contexto de autenticación transporta el rol de tenant como clave propia

El contexto de autenticación del backend SHALL incorporar el rol de tenant como una clave propia del contrato tipado, distinta de la clave que transporta el rol de plataforma, y SHALL incorporar además el **conjunto** de roles de tenant activos como una tercera clave, también propia y distinta de las dos anteriores. Las tres SHALL estar declaradas en el tipo y verificadas por la comprobación de contrato existente, de modo que ninguna pueda agregarse o quitarse sin que la suite lo detecte.

Un guard de autorización NOT SHALL comparar el valor de una de esas claves contra valores de otro espacio de nombres. En particular, el rol de plataforma NOT SHALL evaluarse contra el catálogo de roles de tenant ni a la inversa, aunque ambos catálogos contengan nombres homónimos.

#### Scenario: El contexto expone rol de plataforma y rol de tenant por separado

- **WHEN** un request presenta un token que trae ambos roles y el dependency de autenticación resuelve el contexto
- **THEN** el contexto expone el rol de plataforma y el rol de tenant en claves distintas, cada una con el valor de su propia fuente

#### Scenario: El contexto expone el conjunto de roles de tenant

- **GIVEN** un token cuyo claim de conjunto de roles trae varios roles activos
- **WHEN** el dependency de autenticación resuelve el contexto
- **THEN** el contexto expone ese conjunto completo, además del rol de tenant singular derivado

#### Scenario: Los guards de rol de plataforma conservan su comportamiento

- **GIVEN** un token que trae el conjunto de roles de tenant además del rol de plataforma
- **WHEN** se ejercita un endpoint cuyo guard evalúa el rol de plataforma
- **THEN** la decisión de autorización depende únicamente del rol de plataforma, y es la misma que se obtenía antes de existir el conjunto

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

### Requirement: La administración de centros de costo se autoriza por rol de tenant

Los endpoints de creación, edición y baja de centros de costo SHALL autorizar contra el **rol de tenant** del usuario en la cuenta sobre la que operan, y NOT SHALL evaluarlo contra el espacio de nombres del rol de plataforma. Un usuario que es dueño de su cuenta SHALL poder administrar los centros de costo de esa cuenta.

#### Scenario: El dueño de la cuenta administra sus centros de costo

- **GIVEN** un usuario autenticado que es dueño de su cuenta
- **WHEN** crea un centro de costo en esa cuenta
- **THEN** el centro de costo se persiste y el endpoint responde con éxito, en lugar de denegar por rol insuficiente

#### Scenario: Un miembro de sólo lectura no administra centros de costo

- **GIVEN** un usuario autenticado cuyo rol de tenant no habilita escritura
- **WHEN** intenta crear un centro de costo
- **THEN** el acceso se deniega

### Requirement: Verificación de emisor y audiencia

El middleware SHALL verificar la audiencia del token contra el valor que emite el proveedor para usuarios autenticados, y SHALL verificar además el emisor contra la URL del proveedor configurada.

La verificación de audiencia SHALL realizarse declarando el valor esperado, no desactivando la comprobación: un token cuya audiencia no coincida SHALL rechazarse, y un token con la audiencia esperada NOT SHALL rechazarse por el hecho de que ese valor no sea una URL.

La URL del proveedor SHALL normalizarse **una sola vez**, removiendo una barra final si la hubiera, y esa misma URL normalizada SHALL usarse tanto para construir el emisor esperado como para construir la dirección de las claves públicas. Una barra final en la configuración NOT SHALL alterar el emisor esperado: hoy es invisible, y sin normalizar convertiría el endurecimiento en un rechazo de todo el tráfico legítimo.

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

#### Scenario: Una barra final en la URL configurada no rompe la verificación

- **GIVEN** la URL del proveedor configurada con una barra final
- **WHEN** llega un token legítimo del proveedor
- **THEN** la verificación lo acepta, porque el emisor esperado se construye sobre la URL normalizada

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

