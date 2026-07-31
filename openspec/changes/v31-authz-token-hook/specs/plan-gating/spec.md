## ADDED Requirements

### Requirement: El enforcement del backend deriva el plan del token, no de un valor optimista

El enforcement de límites por plan que realiza el backend SHALL derivar el plan efectivo del claim de plan del token de acceso, que refleja el plan de la cuenta activa con el período de prueba vigente teniendo precedencia.

La ausencia de información de plan NOT SHALL resolverse concediendo el plan más alto. Mientras convivan tokens emitidos antes de habilitar la emisión de claims, el backend PUEDE aplicar un valor de transición explícitamente documentado como tal; ese valor de transición NOT SHALL sobrevivir al cierre de la ventana de convivencia.

#### Scenario: El límite aplicado corresponde al plan de la cuenta

- **GIVEN** una cuenta con plan básico cuyo token trae el claim de plan
- **WHEN** un miembro de esa cuenta intenta superar el límite de recursos del plan básico
- **THEN** la operación se rechaza indicando el límite del plan básico, en lugar de aplicar el límite de un plan superior

#### Scenario: Un período de prueba vigente eleva el límite aplicado

- **GIVEN** una cuenta con plan básico y un período de prueba vigente de un plan superior
- **WHEN** un miembro de esa cuenta consume recursos por encima del límite del plan básico y por debajo del límite del plan de prueba
- **THEN** la operación se permite

#### Scenario: Los recursos existentes por encima del límite no se destruyen al empezar a enforcar

- **GIVEN** una cuenta cuyo consumo actual ya supera el límite de su plan
- **WHEN** empieza a aplicarse el límite real de su plan
- **THEN** los recursos ya existentes se conservan y siguen siendo legibles y editables, y lo que se impide es la creación de recursos nuevos
