## ADDED Requirements

### Requirement: La adopción del rol restringido se verifica antes de exponer la conexión

Cuando la adopción del rol restringido está activa, el sistema SHALL comprobar —después de adoptarlo y antes de entregar la conexión al código de negocio— que la adopción efectivamente tomó, y SHALL rechazar el request si no puede comprobarlo.

Emitir la adopción no equivale a que la adopción haya tenido efecto, y por eso la comprobación es normativa y no una precaución redundante. Los modos de falla que atrapa son los que dejan la adopción sin efecto sin levantar error: la membresía de rol que habilita la adopción puede haber sido revocada del lado de la base, y un statement puede ser tragado sin que el cliente reciba error alguno. El riesgo de que el cambio de rol se encamine a una conexión física distinta de aquella donde corren las consultas de negocio lo cierra la **transacción explícita** por request —materia de los requirements que fijan esa transacción y la adopción dentro de ella, no de esta comprobación—, que fija ambos statements sobre la misma conexión física; esta comprobación se apoya en esa co-locación, no la sustituye. En cualquiera de los casos que sí atrapa, sin comprobación el request correría con el rol de conexión original —que sí tiene el atributo de bypass de seguridad a nivel de fila— **creyendo estar sujeto a las policies y sin emitir señal alguna**. Un fallo de aislamiento silencioso es peor que la ausencia del mecanismo, porque además suprime la sospecha.

La comprobación SHALL leer el **rol efectivo** de la sesión —el que las policies evalúan—, no el rol con el que se estableció la conexión, que informaría el valor original aunque la adopción hubiese tomado. La comprobación SHALL realizarse sobre la misma conexión y dentro de la misma transacción en la que correrán las consultas de negocio del request: una comprobación hecha fuera de ese alcance no prueba nada bajo un pooler en modo transacción, que es exactamente el escenario que la motiva. La comprobación NOT SHALL adelantarse a la adopción que verifica ni realizarse después de haber entregado la conexión.

El criterio SHALL ser de **igualdad estricta** contra el rol restringido esperado. El sistema NOT SHALL aceptar el request por descarte —"cualquier rol distinto del rol de conexión original"—: toda respuesta que no sea exactamente el rol esperado, **incluida una respuesta vacía o ausente**, SHALL tratarse como comprobación fallida. Un criterio negativo dejaría pasar la respuesta ausente de un intermediario que se come el resultado, que es el caso que la comprobación existe para atrapar.

Ante una comprobación fallida el sistema SHALL fallar **cerrado**: SHALL rechazar el request señalando indisponibilidad temporal del servicio —no un error de autorización, porque el cliente no hizo nada mal— y NOT SHALL entregar la conexión. Ninguna consulta de negocio SHALL ejecutarse jamás sobre una conexión que se cree sujeta a las policies sin estarlo, y el request rechazado NOT SHALL degradarse a un éxito parcial ni continuar con el rol privilegiado. El mensaje de rechazo SHALL ser opaco: NOT SHALL revelar el rol efectivo observado ni ningún otro detalle interno de la sesión de base de datos.

Una comprobación fallida SHALL registrarse con el nivel de severidad más alto disponible, incluyendo el rol efectivo observado y el identificador del sujeto del request, de modo que la presencia de un fallo sea imposible de pasar por alto.

La comprobación SHALL ejecutarse una sola vez por conexión de request entregada —no una vez por consulta— y SHALL costar a lo sumo un intercambio adicional con la base por conexión entregada. SHALL existir únicamente donde existe la adopción que verifica: con la adopción desactivada, el sistema NOT SHALL emitir comprobación alguna ni pagar el intercambio adicional, y los caminos previos SHALL quedar idénticos. La comprobación SHALL aplicar únicamente a las conexiones obtenidas por el contexto de request, que es donde ocurre la adopción; toda conexión obtenida por el contexto de servicio —el que por diseño conserva el bypass para operar sin identidad de usuario— SHALL quedar fuera de su alcance, y la comprobación NOT SHALL poder rechazarla.

#### Scenario: La adopción se comprueba antes de entregar la conexión

- **GIVEN** un request autenticado con la adopción del rol restringido activa
- **WHEN** la adopción toma correctamente
- **THEN** el rol efectivo se comprueba una sola vez, después de la adopción y antes de que la conexión quede disponible para el código de negocio, y el request continúa con normalidad

#### Scenario: Una adopción que no tomó rechaza el request sin entregar la conexión

- **GIVEN** un request autenticado con la adopción activa
- **WHEN** el rol efectivo resulta ser el rol de conexión original, con atributo de bypass de seguridad a nivel de fila
- **THEN** el request se rechaza con indisponibilidad del servicio y ninguna consulta de negocio llega a ejecutarse sobre esa conexión

#### Scenario: Una respuesta que no es exactamente el rol esperado también rechaza

- **GIVEN** un request autenticado con la adopción activa
- **WHEN** la comprobación devuelve una respuesta ausente o vacía en lugar de un nombre de rol
- **THEN** el request se rechaza igual que si el rol observado hubiese sido el privilegiado, porque el criterio es de igualdad estricta y no de descarte

#### Scenario: El mensaje de rechazo no revela el estado interno de la sesión

- **GIVEN** un request rechazado por comprobación fallida
- **WHEN** el cliente recibe la respuesta
- **THEN** el mensaje no contiene el rol efectivo observado ni ningún otro detalle de la sesión de base de datos

#### Scenario: Un rechazo por comprobación fallida deja rastro operativo

- **GIVEN** un request rechazado por comprobación fallida
- **WHEN** se inspeccionan los registros operativos del período
- **THEN** el rechazo aparece registrado con la severidad más alta disponible, con el rol efectivo observado y el sujeto del request, de modo que sea imposible de pasar por alto

#### Scenario: Sin adopción de rol no hay comprobación ni costo adicional

- **GIVEN** un request autenticado con la adopción del rol restringido desactivada
- **WHEN** obtiene una conexión del pool
- **THEN** no se emite ninguna comprobación del rol efectivo ni ningún intercambio adicional con la base, y el comportamiento observable es el mismo que el de un ciclo de vida de conexión sin comprobación

#### Scenario: El camino de conexión de servicio queda fuera de la comprobación

- **GIVEN** una operación que obtiene su conexión por el contexto de servicio, con todas las palancas activadas
- **WHEN** obtiene su conexión
- **THEN** no adopta el rol restringido, la comprobación no se le aplica y no puede rechazarla
