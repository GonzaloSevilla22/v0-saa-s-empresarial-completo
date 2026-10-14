## MODIFIED Requirements

### Requirement: Resolución determinística de la cuenta activa

El sistema SHALL resolver la cuenta activa de un usuario con un único resolver canónico —la cuenta que el usuario eligió, mientras siga siendo una de sus membresías; si no eligió ninguna o dejó de serlo, la membresía más antigua, desempatada por su identificador— y SHALL usar ese mismo resolver tanto al emitir los claims del token como al resolver la cuenta sobre la que opera un request que no la declara. Una resolución sin ordenamiento definido NOT SHALL considerarse aceptable, y ningún componente SHALL mantener un criterio propio distinto del resolver canónico.

#### Scenario: El claim y el resolver de cuenta coinciden bajo multi-membresía

- **GIVEN** un usuario que pertenece a más de una cuenta
- **WHEN** se emite su token y a continuación opera sobre un endpoint que resuelve la cuenta del tenant
- **THEN** la cuenta descrita por los claims del token es la misma sobre la que opera el endpoint

#### Scenario: La resolución es estable entre invocaciones

- **GIVEN** un usuario con varias membresías, sin cambios en ellas ni en su elección
- **WHEN** se resuelve su cuenta activa repetidas veces
- **THEN** el resultado es siempre el mismo

#### Scenario: La cuenta elegida determina los claims

- **GIVEN** un usuario miembro de A (más antigua) y de B, que eligió B como cuenta activa
- **WHEN** se emite su token
- **THEN** los claims de rol de tenant, del conjunto de roles y de plan describen la cuenta B

#### Scenario: Sin elección vigente, gana la membresía más antigua

- **GIVEN** un usuario miembro de A (más antigua) y de B, que nunca eligió cuenta
- **WHEN** se emite su token
- **THEN** los claims describen la cuenta A

## ADDED Requirements

### Requirement: El token declara la cuenta que describen sus claims de tenant
El sistema SHALL incluir en cada token de acceso emitido el identificador de la cuenta activa a la que corresponden sus claims de rol de tenant, de conjunto de roles y de plan. Los tres claims y el identificador SHALL describir siempre la misma cuenta.

Ante un error al resolver la cuenta activa, la emisión SHALL degradar devolviendo los claims intactos y dejando rastro, y NOT SHALL impedir que el usuario obtenga su token.

#### Scenario: El token trae la cuenta y sus claims coinciden

- **WHEN** se emite un token para un usuario que pertenece a una cuenta
- **THEN** el token declara el identificador de la cuenta activa, y los claims de rol, de conjunto de roles y de plan son los de esa cuenta

#### Scenario: Cambiar de cuenta se refleja en el token siguiente

- **GIVEN** un usuario que cambia su cuenta activa de A a B
- **WHEN** su token se renueva
- **THEN** el token nuevo declara B y trae los roles y el plan de B
