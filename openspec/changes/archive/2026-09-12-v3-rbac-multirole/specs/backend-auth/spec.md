## MODIFIED Requirements

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

Si no puede determinarse ningún rol de tenant por ninguna de las tres vías, el guard SHALL denegar. La ausencia de información de rol NOT SHALL resolverse asumiendo un rol permisivo.

El backend SHALL exponer los conjuntos de roles permitidos como **capacidades nombradas declaradas en un único lugar**, y los puntos de autorización NOT SHALL enumerar roles literales de forma dispersa.

#### Scenario: El claim del conjunto evita la consulta a la base

- **GIVEN** un token que trae el claim con el conjunto de roles de tenant
- **WHEN** se ejercita un endpoint cuyo guard requiere rol de tenant
- **THEN** la decisión se toma con el valor del claim, sin consultar las asignaciones en la base

#### Scenario: Basta un rol del conjunto para autorizar

- **GIVEN** un usuario cuyo conjunto de roles activos incluye uno de los permitidos por el guard y varios que no lo están
- **WHEN** se ejercita ese endpoint
- **THEN** el acceso se concede

#### Scenario: Un token anterior a la ampliación resuelve por el claim singular

- **GIVEN** un token emitido antes de la ampliación del contrato, que trae el rol de tenant singular y no el conjunto
- **WHEN** se ejercita un endpoint cuyo guard requiere rol de tenant
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
