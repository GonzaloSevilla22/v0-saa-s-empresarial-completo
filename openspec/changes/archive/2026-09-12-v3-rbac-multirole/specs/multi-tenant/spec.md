## MODIFIED Requirements

### Requirement: Modelo de cuenta y membresía

El sistema SHALL representar una cuenta (`accounts`) que puede ser compartida por múltiples usuarios a través de una tabla de membresía (`account_members`), donde cada miembro tiene **uno o más roles** provenientes de un catálogo cerrado y global, cada uno con su autoría y su vigencia (capability `account-membership-roles`).

El rol único preexistente de la membresía SHALL conservarse como **valor derivado** del conjunto de roles activos, expresado en el vocabulario heredado y mantenido automáticamente por la base, de modo que los consumidores que ya lo leen sigan obteniendo la misma respuesta. Ese valor derivado NOT SHALL ser una segunda fuente de verdad: las asignaciones de rol son la única.

Ningún rol del catálogo SHALL estar condicionado al plan contratado por la cuenta. El gating comercial del trabajo en equipo se ejerce por la cantidad de usuarios admitidos por el plan.

#### Scenario: Una cuenta tiene un owner
- **WHEN** se crea una `account`
- **THEN** existe exactamente una membresía con una asignación activa del rol de propietario para esa cuenta

#### Scenario: Un usuario pertenece a una cuenta
- **GIVEN** un usuario miembro de una cuenta
- **WHEN** se consulta `current_account_ids()` para ese usuario
- **THEN** el resultado incluye el `account_id` de su cuenta

#### Scenario: La pertenencia a la cuenta no depende del rol
- **GIVEN** un usuario cuyo único rol activo venció
- **WHEN** se consulta `current_account_ids()` para ese usuario
- **THEN** el resultado sigue incluyendo el `account_id` de su cuenta, porque la pertenencia y el rol son dimensiones distintas

#### Scenario: Los valores de rol permitidos provienen del catálogo
- **GIVEN** cualquier intento de asignar un rol a una membresía
- **WHEN** el valor no figura en el catálogo global de roles
- **THEN** la base rechaza la operación

#### Scenario: El valor derivado refleja las asignaciones
- **GIVEN** una membresía con asignaciones activas de administrador y de cajero
- **WHEN** se consulta el rol único heredado de esa membresía
- **THEN** vale administrador, por precedencia, y no se puede alterar sin alterar las asignaciones

#### Scenario: Ningún rol está reservado a un plan
- **GIVEN** una cuenta en el plan de menor precio con cupo de usuarios disponible
- **WHEN** su propietario asigna a un segundo miembro cualquier rol del catálogo
- **THEN** la asignación se registra, sin que el plan lo impida
