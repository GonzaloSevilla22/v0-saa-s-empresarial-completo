## ADDED Requirements

### Requirement: El límite de historial es enforceable en el servidor, no sólo en la interfaz

`plan_limits.history_days` SHALL tratarse como un límite **enforceable**, no como una sugerencia de presentación: todo read-model que exponga una ventana temporal elegida por el usuario SHALL recortar esa ventana al historial que el plan de la cuenta habilita, dentro del propio read-model.

La resolución del plan efectivo para este recorte SHALL hacerse contra la base de datos por la definición normativa única de plan efectivo, y NOT SHALL derivarse de la información de plan que viaja en el token de acceso: mientras esa información no viaje de forma garantizada, el camino que la lee cae a un valor por defecto permisivo y el límite deja de existir sin que nada falle.

El recorte SHALL preservar el acceso al módulo —recorta la ventana, no rechaza la consulta— y el read-model SHALL informar la ventana efectivamente aplicada, de modo que la superficie pueda explicar el recorte en lugar de mostrar un período vacío sin causa aparente.

#### Scenario: El recorte ocurre aunque el cliente pida más

- **GIVEN** una cuenta cuyo plan habilita 30 días de historial
- **WHEN** se consulta un read-model con una ventana de 365 días, sin pasar por la interfaz
- **THEN** el resultado cubre únicamente los últimos 30 días

#### Scenario: El límite no depende del claim de plan del token

- **GIVEN** un token de acceso que no transporta información de plan
- **WHEN** se consulta un read-model con ventana temporal
- **THEN** el historial aplicado es el del plan efectivo de la cuenta resuelto contra la base, no el del valor por defecto del camino que lee el token

#### Scenario: La ventana aplicada viaja en la respuesta

- **WHEN** un read-model recorta la ventana solicitada
- **THEN** informa la ventana que efectivamente aplicó

#### Scenario: Recorte, no rechazo

- **GIVEN** un usuario del plan más restrictivo
- **WHEN** solicita una ventana mayor a la que su plan habilita
- **THEN** recibe los datos de la ventana recortada, no un error de autorización
