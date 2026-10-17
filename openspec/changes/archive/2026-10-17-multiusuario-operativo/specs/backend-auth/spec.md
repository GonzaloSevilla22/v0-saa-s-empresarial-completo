## ADDED Requirements

### Requirement: Los claims de rol de tenant sólo valen para la cuenta que describen
El backend SHALL transportar en el contexto de autenticación la cuenta activa que declara el token, y SHALL usar los claims de rol de tenant y de conjunto de roles para autorizar **sólo** cuando el token declara esa cuenta. Cuando el token no la declara, el backend SHALL resolver el conjunto de roles consultando las asignaciones vigentes de la base en la cuenta activa del request, como si los claims de rol no viajaran.

La consulta de respaldo SHALL devolver los roles de la membresía en la cuenta activa del request, NOT los de la membresía más antigua del usuario.

#### Scenario: Un token sin cuenta declarada no autoriza con sus claims de rol
- **GIVEN** un token emitido antes de que el token declarara la cuenta activa, con claims de rol de otra membresía del usuario
- **WHEN** se ejercita un endpoint cuyo guard requiere rol de tenant
- **THEN** la decisión se toma con los roles vigentes del usuario en la cuenta activa del request, consultados en la base

#### Scenario: Un token con cuenta declarada autoriza con sus claims
- **GIVEN** un token que declara la cuenta activa y trae el conjunto de roles de esa cuenta
- **WHEN** se ejercita un endpoint cuyo guard requiere un rol de tenant que no es el de configuración
- **THEN** la decisión se toma con el claim, sin consultar la base
