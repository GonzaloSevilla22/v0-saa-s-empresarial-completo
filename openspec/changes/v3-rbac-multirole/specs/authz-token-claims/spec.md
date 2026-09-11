## MODIFIED Requirements

### Requirement: Contrato de evolución hacia múltiples roles por miembro

El claim de rol de tenant singular SHALL conservar su forma y su significado ahora que la membresía admite múltiples roles: sigue transportando **un** valor, derivado por precedencia del conjunto de roles activos y expresado en el vocabulario heredado. Su forma NOT SHALL redefinirse para transportar un conjunto.

El conjunto de roles activos SHALL viajar en un claim **distinto y nuevo**, cuyo contenido SHALL excluir toda asignación vencida al instante de la emisión. Una asignación vencida NOT SHALL figurar en el claim aunque su registro siga existiendo en la base.

Mientras existan tokens emitidos bajo el contrato anterior, ambos claims SHALL emitirse juntos, de modo que un consumidor que sólo conozca el claim singular siga funcionando sin modificarse.

#### Scenario: La introducción de múltiples roles no redefine el claim existente

- **WHEN** el modelo de membresía pasa a admitir varios roles por miembro
- **THEN** el conjunto de roles viaja en un claim nuevo y el claim singular preexistente conserva su forma y su significado

#### Scenario: El token de un miembro con varios roles transporta ambos claims

- **GIVEN** un miembro con asignaciones activas de administrador, vendedor y cajero
- **WHEN** se emite su token
- **THEN** el claim nuevo contiene los tres roles y el claim singular contiene el de mayor precedencia

#### Scenario: Un rol vencido no viaja en el token

- **GIVEN** un miembro con una asignación activa de vendedor y otra vencida de cajero
- **WHEN** se emite su token
- **THEN** el claim del conjunto contiene el rol de vendedor y no contiene el de cajero

#### Scenario: Un consumidor del claim singular no se ve afectado

- **GIVEN** un consumidor que sólo lee el claim de rol de tenant singular
- **WHEN** se emiten tokens bajo el contrato ampliado
- **THEN** la decisión de autorización de ese consumidor es la misma que antes de la ampliación

### Requirement: Claims de autorización emitidos en el token de acceso

El sistema SHALL inyectar en cada token de acceso emitido —tanto en el login como en cada renovación— los claims de autorización derivados del estado vigente en la base de datos: el rol de plataforma del usuario, el rol de tenant que el usuario tiene en su cuenta activa, **el conjunto de roles de tenant activos en esa cuenta**, y el plan efectivo de esa cuenta.

El plan efectivo SHALL respetar la regla ya vigente de la capability de gating por plan: un período de prueba vigente tiene precedencia sobre el plan contratado.

El cálculo del conjunto de roles SHALL quedar comprendido dentro del mismo blindaje que ya protege la emisión: un error al resolverlo SHALL degradar devolviendo los claims intactos y dejando rastro, y NOT SHALL impedir que el usuario obtenga su token.

#### Scenario: El token de un usuario con cuenta y plan trae los claims de autorización

- **WHEN** se emite un token para un usuario que pertenece a una cuenta
- **THEN** el token contiene el rol de plataforma del usuario, el rol de tenant en su cuenta activa, el conjunto de roles de tenant activos y el plan efectivo de esa cuenta

#### Scenario: Un período de prueba vigente determina el plan del claim

- **GIVEN** una cuenta con plan contratado básico y un período de prueba vigente de un plan superior
- **WHEN** se emite un token para un miembro de esa cuenta
- **THEN** el claim de plan contiene el plan del período de prueba, no el plan contratado

#### Scenario: Los claims se recalculan en cada renovación

- **GIVEN** un usuario con un token vigente emitido antes de que cambiara el plan de su cuenta
- **WHEN** el token se renueva
- **THEN** el claim de plan del token nuevo refleja el plan vigente al momento de la renovación

#### Scenario: Un rol asignado se refleja en el token siguiente

- **GIVEN** un miembro al que se le asignó un rol después de emitido su token vigente
- **WHEN** su token se renueva
- **THEN** el claim del conjunto de roles incluye el rol asignado

#### Scenario: Un error al resolver los roles no impide el login

- **GIVEN** una condición de error durante la resolución del conjunto de roles
- **WHEN** un usuario inicia sesión
- **THEN** obtiene un token válido, el inicio de sesión no falla, y la degradación queda registrada
