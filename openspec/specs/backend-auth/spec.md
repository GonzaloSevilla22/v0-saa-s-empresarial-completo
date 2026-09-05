# backend-auth — Spec

## Purpose

Middleware de autenticación para FastAPI que valida JWTs emitidos por Supabase. FastAPI no emite tokens propios — actúa como resource server que verifica la firma del token.

## Requirements

### Requirement: Validación de JWT de Supabase

El middleware SHALL decodificar y verificar tokens usando `SUPABASE_JWT_SECRET` y algoritmo `HS256`.

#### Scenario: Decodificación HS256 con el secreto compartido cuando no hay `supabase_url`

- **GIVEN** `settings.supabase_url` está vacío (entorno de desarrollo o tests, sin JWKS de Supabase disponible)
- **WHEN** llega un token firmado con `SUPABASE_JWT_SECRET` usando el algoritmo `HS256`
- **THEN** `get_current_user` lo decodifica con ese secreto y retorna el contexto de autenticación (verificado por `test_valid_token_returns_user` en `backend/tests/test_auth.py`)

> Nota de cobertura: cuando `supabase_url` SÍ está configurado (producción), `get_current_user` valida en cambio contra las JWKS de Supabase con `ES256`/`RS256` (`backend/core/auth.py`, rama `get_jwks_client()`) — un mecanismo que este requisito no menciona. El HS256 con secreto compartido documentado acá es exclusivamente el fallback de dev/test.

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

### Requirement: Sin verificación de audience

La verificación de `aud` SHALL estar desactivada (`verify_aud: False`), dado que Supabase emite `aud: "authenticated"` (string no-URL) y de lo contrario se producirían falsos 401.

#### Scenario: Token con `aud: "authenticated"` se acepta sin validar audience

- **GIVEN** un JWT válido cuyo claim `aud` es la cadena `"authenticated"` (no una URL)
- **WHEN** `get_current_user` lo decodifica, ya sea por el path HS256 (dev/test) o por el path JWKS (producción)
- **THEN** ambas llamadas a `pyjwt.decode` pasan `options={"verify_aud": False}`, de modo que el token se acepta sin fallar por audience mientras el resto de las validaciones (firma, expiración) sean correctas

### Requirement: Header Bearer en HTTP, query param en WebSocket

El middleware SHALL aceptar el token vía `Authorization: Bearer <token>` en endpoints HTTP y vía query param `?token=<token>` en endpoints WebSocket (los browsers no envían headers custom en el WS handshake).

#### Scenario: Endpoint HTTP recibe el token por el header Authorization

- **WHEN** un cliente llama a un endpoint HTTP protegido con `Authorization: Bearer <token>`
- **THEN** `oauth2_scheme` (`OAuth2PasswordBearer`) extrae el token del header y lo inyecta como dependencia en `get_current_user`

#### Scenario: Endpoint WebSocket recibe el token por query param

- **WHEN** un cliente abre `WebSocket /ws/{room_id}?token=<token>`
- **THEN** `backend/routers/ws.py` valida el token recibido por el query param `token` (declarado con `Query(default=None)`) en vez de un header, y cierra la conexión con code 1008 si el token es inválido o está ausente

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

El contexto de autenticación del backend SHALL incorporar el rol de tenant como una clave propia del contrato tipado, distinta de la clave que transporta el rol de plataforma. Ambas SHALL estar declaradas en el tipo y verificadas por la comprobación de contrato existente, de modo que ninguna de las dos pueda agregarse o quitarse sin que la suite lo detecte.

Un guard de autorización NOT SHALL comparar el valor de una de esas claves contra valores del otro espacio de nombres.

#### Scenario: El contexto expone rol de plataforma y rol de tenant por separado

- **WHEN** un request presenta un token que trae ambos roles y el dependency de autenticación resuelve el contexto
- **THEN** el contexto expone el rol de plataforma y el rol de tenant en claves distintas, cada una con el valor de su propia fuente

#### Scenario: Los guards de rol de plataforma conservan su comportamiento

- **GIVEN** un token que trae el rol de tenant además del de plataforma
- **WHEN** se ejercita un endpoint cuyo guard evalúa el rol de plataforma
- **THEN** la decisión de autorización depende únicamente del rol de plataforma, y es la misma que se obtenía sin el claim de rol de tenant

### Requirement: Resolución del rol de tenant con respaldo en la base durante la transición

Cuando un guard requiera el rol de tenant, el backend SHALL usar el claim del token si está presente. Si el claim está ausente —situación esperada mientras siguen vigentes tokens emitidos antes de habilitar la emisión de claims— el backend SHALL resolver el rol consultando la membresía del usuario en la cuenta activa.

Si no puede determinarse un rol de tenant por ninguna de las dos vías, el guard SHALL denegar. La ausencia de información de rol NOT SHALL resolverse asumiendo un rol permisivo.

#### Scenario: El claim presente evita la consulta a la base

- **GIVEN** un token que trae el rol de tenant
- **WHEN** se ejercita un endpoint cuyo guard requiere rol de tenant
- **THEN** la decisión se toma con el valor del claim, sin consultar la membresía en la base

#### Scenario: Un token sin el claim resuelve el rol contra la base

- **GIVEN** un token emitido antes de habilitar la emisión de claims, todavía vigente
- **WHEN** se ejercita un endpoint cuyo guard requiere rol de tenant
- **THEN** el rol se resuelve consultando la membresía del usuario, y la autorización produce el mismo resultado que con el claim presente

#### Scenario: Sin membresía, el guard deniega

- **GIVEN** un usuario autenticado sin membresía en ninguna cuenta y un token sin el claim de rol de tenant
- **WHEN** se ejercita un endpoint cuyo guard requiere rol de tenant
- **THEN** el acceso se deniega, en lugar de concederse por ausencia de información

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
