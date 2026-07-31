## ADDED Requirements

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
