## ADDED Requirements

### Requirement: La aceptación de una invitación exige la identidad invitada

Cuando una invitación declara el email del invitado, la operación de aceptación SHALL exigir que la identidad autenticada que la canjea corresponda a ese email, comparando ambos valores sin distinguir mayúsculas de minúsculas, y SHALL rechazar la aceptación cuando no coincidan.

Una invitación que NO declara email SHALL seguir siendo canjeable por cualquier identidad autenticada que presente el token, porque ese es el caso de un enlace compartido deliberadamente.

El rechazo SHALL usar el mismo contrato de error que el resto de las validaciones de la operación, de modo que el consumidor no necesite distinguir este caso de los demás.

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

#### Scenario: Una invitación sin email declarado sigue siendo canjeable

- **GIVEN** una invitación vigente que no declara email
- **WHEN** una identidad autenticada presenta el token
- **THEN** la aceptación se completa

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
