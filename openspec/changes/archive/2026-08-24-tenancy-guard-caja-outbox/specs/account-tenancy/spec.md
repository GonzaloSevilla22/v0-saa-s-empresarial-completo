## ADDED Requirements

### Requirement: Las funciones que recorren el outbox completo integran una lista curada y no son alcanzables desde los roles de aplicación

El sistema SHALL mantener enumerada, en una lista curada verificada por integración continua, toda función con privilegio de definidor que **lea o actualice** la tabla de eventos del outbox, y SHALL fallar el pipeline cuando aparezca una que no esté en la lista.

El gate vigente ya cubre los helpers internos por convención de nombre, y **excluye deliberadamente** a los comandos públicos de la API, porque enumerarlos a todos produciría una allowlist inmantenible. Esa exclusión dejó un punto ciego preciso: una función que **sí** es un comando público por su nombre, pero cuyo cuerpo recorre el outbox de todos los inquilinos, no cae en ningún radar. Es exactamente donde vivía la fuga: dos comandos del relay, ejecutables por el rol autenticado, que devolvían y cerraban eventos de cualquier cuenta.

El criterio de la lista SHALL ser leer o actualizar la tabla de eventos, y SHALL NOT ser insertar en ella: producir un evento propio es lo que hacen todos los productores legítimos del sistema y no permite leer ni cerrar los eventos de nadie más. Ese recorte es lo que mantiene la lista corta y por lo tanto legible — una lista que nadie lee es un gate apagado.

Cada entrada de la lista SHALL declarar si la función puede ser ejecutable por los roles de aplicación y, en caso afirmativo, por qué. Una función que recorre el outbox por diseño de relay SHALL NOT ser ejecutable por ningún rol de aplicación. Una función que actualiza un evento propio como parte de una operación de negocio ya verificada por cuenta SHALL poder serlo, con su justificación escrita.

La regla de mantenimiento SHALL ser la misma que rige la lista cerrada de helpers de dinero: la lista **sólo crece**, y agregar una entrada SHALL exigir justificación escrita en el pull request.

El gate SHALL correr contra la base resultante de aplicar **todas** las migraciones, no contra el texto de los archivos, y la verificación del estado real de permisos SHALL hacerse además contra **producción**, porque el entorno hospedado concede la ejecución a los roles de aplicación de forma directa y no a través del pseudo-rol público.

#### Scenario: Una función nueva que recorre el outbox y no está en la lista falla el pipeline

- **GIVEN** una migración que agrega una función con privilegio de definidor cuyo cuerpo consulta la tabla de eventos
- **WHEN** corre el gate de integración continua
- **THEN** el gate falla e identifica la función por nombre y firma, indicando que debe declararse en la lista con su veredicto

#### Scenario: Reexponer una función del relay falla el pipeline

- **GIVEN** una función del relay declarada en la lista como no expuesta
- **WHEN** una migración posterior le concede ejecución al rol autenticado
- **THEN** el gate falla e identifica esa función

#### Scenario: Un productor de eventos no es reportado

- **GIVEN** un comando de negocio con privilegio de definidor que sólo inserta un evento propio en el outbox
- **WHEN** corre el gate
- **THEN** no lo reporta, porque insertar no permite leer ni cerrar eventos ajenos

#### Scenario: El gate nace en verde

- **WHEN** el gate se agrega al pipeline sobre el estado actual del esquema
- **THEN** pasa, porque todas las funciones que hoy recorren el outbox están declaradas con su veredicto y las que quedan expuestas tienen su justificación escrita

#### Scenario: El gate se verifica también contra producción

- **WHEN** se audita el estado real de permisos después de desplegar
- **THEN** la verificación se hace contra la base de producción y no únicamente contra la de integración continua, porque las concesiones directas a los roles de aplicación pueden diferir entre ambas
