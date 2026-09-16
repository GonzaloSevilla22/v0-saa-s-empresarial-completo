## ADDED Requirements

### Requirement: La aceptación de una invitación exige la identidad invitada

La operación de aceptación SHALL exigir que la identidad autenticada que canjea el token corresponda al email declarado en la invitación, comparando ambos valores sin distinguir mayúsculas de minúsculas, y SHALL rechazar la aceptación cuando no coincidan.

El email de la identidad que acepta SHALL resolverse **contra el registro de identidades del proveedor**, a partir del identificador del usuario autenticado, y NOT SHALL depender exclusivamente de un claim del token: el backend propio empuja a la base una reconstrucción mínima de claims que NO incluye el email, de modo que una comprobación keyeada sólo en el claim rechazaría toda aceptación que llegara por ese camino. El claim SHALL usarse, cuando esté presente, únicamente como atajo equivalente.

El rechazo SHALL usar el mismo contrato de error —mismo código y mismo texto— que el rechazo por token inexistente o vencido, de modo que el consumidor no necesite distinguir este caso y la respuesta no confirme que el token es válido para otra identidad.

#### Scenario: Otra identidad no puede canjear una invitación dirigida

- **GIVEN** una invitación vigente dirigida a un email concreto
- **WHEN** una identidad autenticada distinta de ese email presenta el token
- **THEN** la aceptación se rechaza y no se crea ninguna membresía ni ninguna asignación de rol

#### Scenario: La identidad invitada acepta con normalidad

- **GIVEN** una invitación vigente dirigida a un email concreto
- **WHEN** la identidad autenticada correspondiente a ese email presenta el token
- **THEN** la membresía y el conjunto de roles se crean como hasta ahora

#### Scenario: La comparación ignora mayúsculas

- **GIVEN** una invitación cuyo email fue cargado con mayúsculas
- **WHEN** la identidad autenticada correspondiente, escrita en minúsculas, presenta el token
- **THEN** la aceptación se completa

#### Scenario: La aceptación funciona con el conjunto de claims que empuja el backend propio

- **GIVEN** una invitación vigente dirigida a un email concreto
- **AND** un contexto de base de datos cuyos claims contienen únicamente el sujeto y el rol de conexión, sin email, que es la forma exacta que empuja el backend propio
- **WHEN** la identidad invitada presenta el token
- **THEN** la aceptación se completa, porque el email se resuelve desde el registro de identidades del proveedor

#### Scenario: El rechazo no revela que el token es válido para otra identidad

- **GIVEN** una invitación vigente dirigida a un email concreto
- **WHEN** una identidad distinta presenta el token
- **THEN** el error devuelto es indistinguible del que produce un token inexistente o vencido

### Requirement: La aceptación de una invitación toma lock sobre la invitación

La operación de aceptación SHALL tomar un bloqueo sobre la fila de la invitación **antes** de validar su estado y su vigencia, de modo que dos aceptaciones concurrentes del mismo token no puedan ambas observar el estado pendiente.

Exactamente una de las aceptaciones concurrentes SHALL tener éxito; la otra SHALL rechazarse por invitación ya utilizada, con el mismo contrato de error que el resto de las validaciones.

#### Scenario: Dos aceptaciones concurrentes del mismo token

- **GIVEN** una invitación vigente en estado pendiente
- **WHEN** dos transacciones intentan canjear el mismo token simultáneamente
- **THEN** una completa la aceptación y la otra se rechaza por invitación ya utilizada, sin que se cree una segunda membresía

#### Scenario: El estado de la invitación queda consistente

- **WHEN** una aceptación se completa
- **THEN** la invitación queda marcada como aceptada en la misma transacción en que se crean la membresía y sus roles
