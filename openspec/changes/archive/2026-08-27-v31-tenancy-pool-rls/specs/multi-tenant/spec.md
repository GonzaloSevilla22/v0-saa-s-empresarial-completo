## ADDED Requirements

### Requirement: El aislamiento entre cuentas está respaldado por la base, no sólo por la aplicación

El aislamiento de datos entre cuentas SHALL estar garantizado por la seguridad a nivel de fila de la base de datos para **todos** los caminos de acceso de usuario final, incluido el backend de aplicación, y NOT SHALL depender exclusivamente de que cada consulta recuerde filtrar por cuenta.

Una consulta de la aplicación que omita el filtro por cuenta SHALL producir, como máximo, las filas de las cuentas a las que el usuario pertenece. La omisión de un filtro SHALL ser un defecto de calidad, no una brecha de aislamiento.

#### Scenario: Un camino de acceso no puede quedar exento de la evaluación de policies

- **WHEN** se enumeran los caminos por los que un usuario final alcanza los datos
- **THEN** todos evalúan las policies de seguridad a nivel de fila, sin que ninguno opere con un rol que las bypasee

#### Scenario: Una consulta sin filtro no expone datos de otra cuenta

- **GIVEN** un usuario perteneciente a una sola cuenta
- **WHEN** una consulta de la aplicación omite el filtro por cuenta
- **THEN** el resultado se limita a los datos de la cuenta del usuario

#### Scenario: Un identificador de otra cuenta no es alcanzable por acceso directo

- **GIVEN** un usuario de una cuenta que conoce el identificador de un registro de otra cuenta
- **WHEN** solicita ese registro por identificador
- **THEN** el sistema responde como si el registro no existiera, sin revelar su contenido ni su existencia

### Requirement: Las operaciones de máquina son un camino distinto y acotado

Las operaciones que el sistema ejecuta sin un usuario autenticado —recepción de avisos de pago, procesos programados, tareas en segundo plano— SHALL constituir un camino de acceso explícitamente distinto del camino de request de usuario, con su propio contexto de conexión. Ese camino PUEDE operar sin la restricción de cuenta, por ser transversal por diseño, y SHALL estar restringido a los puntos de entrada enumerados y auditables.

Un endpoint de usuario final NOT SHALL usar el camino de máquina para eludir el aislamiento por cuenta.

#### Scenario: El camino de máquina no depende de claims de usuario

- **WHEN** se procesa un aviso de pago o una tarea programada
- **THEN** la operación se completa sin requerir claims de un usuario, y no queda sujeta al alcance de cuenta de ningún request

#### Scenario: Los endpoints de usuario no usan el camino de máquina

- **WHEN** se revisan los endpoints que atienden a usuarios autenticados
- **THEN** ninguno obtiene su conexión por el camino de máquina
