## MODIFIED Requirements

### Requirement: Relay authorization model

El relay SHALL leer los eventos pendientes de todas las cuentas y actualizar su marca de procesado a través de una función con privilegio de definidor cuyo permiso de ejecución esté revocado de **los tres roles de aplicación** —el pseudo-rol público, el rol anónimo y el rol autenticado—, sin debilitar el aislamiento por cuenta de los usuarios normales.

La formulación anterior nombraba únicamente al rol anónimo y al pseudo-rol público. Ese silencio sobre el rol autenticado no fue una omisión inofensiva: las dos funciones del relay nacieron con permiso de ejecución concedido explícitamente a ese rol, y por lo tanto quedaron invocables desde la API de datos por cualquier usuario con sesión iniciada. Como ninguna de las dos filtra por cuenta —no filtrar es su razón de ser—, la combinación convierte al outbox en una lectura completa de los eventos de todos los inquilinos, con su contenido legible, y en la posibilidad de marcarlos procesados sin haberlos procesado. Lo segundo es más grave que lo primero: un evento marcado sin haber sido despachado **nunca** produce su asiento contable, porque el despachador real sólo mira los pendientes.

Una función del relay SHALL NOT resolverse agregándole un filtro por cuenta. Recorrer todas las cuentas es el contrato que este requisito le exige; filtrarla la volvería inútil como relay y no impediría que un consumidor incompleto cierre eventos ajenos. La forma correcta SHALL ser dejarla fuera del alcance de los roles de aplicación y alcanzarla únicamente desde un contexto de máquina.

El aislamiento por cuenta sobre la tabla de eventos para los usuarios normales SHALL seguir siendo de sólo lectura y limitado a su propia cuenta, y el código de aplicación SHALL NOT usar la clave de servicio para eludirlo.

#### Scenario: Un usuario autenticado no puede recorrer el outbox

- **WHEN** un usuario con sesión iniciada intenta invocar directamente, desde la API de datos, la función que devuelve el lote de eventos pendientes
- **THEN** la invocación es rechazada por falta de permiso de ejecución, y no obtiene ningún evento de ninguna cuenta

#### Scenario: Un usuario autenticado no puede cerrar un evento ajeno

- **WHEN** un usuario con sesión iniciada intenta invocar directamente la función que marca un evento como procesado, informando el identificador de un evento de otra cuenta
- **THEN** la invocación es rechazada, la marca de procesado del evento no cambia, y el despachador lo sigue viendo pendiente

#### Scenario: Normal user cannot read another account's events

- **WHEN** an authenticated user queries `events` directly
- **THEN** RLS returns only rows for that user's `account_id`, never other accounts' events

#### Scenario: Relay processes across accounts via the definer RPC

- **WHEN** the pg_cron relay invokes the outbox-processing RPC
- **THEN** the `SECURITY DEFINER` owner bypasses RLS for the relay's pending scan and `processed_at` update only, with EXECUTE not granted to `anon`/`PUBLIC`/`authenticated`, and no `service_role` key used in app code

## ADDED Requirements

### Requirement: Hay un único despachador del outbox

El sistema SHALL despachar los eventos del outbox por un único componente, el despachador en base de datos que ejecuta los cuatro consumidores en orden, y SHALL NOT mantener un segundo componente que seleccione eventos pendientes y los marque procesados con un subconjunto de los consumidores.

El requisito de despacho ya exige que la marca de procesado se escriba **sólo después** de que todos los consumidores en alcance del evento tengan éxito. Dos componentes que comparten la misma tabla, el mismo predicado de selección y la misma marca, pero que corren distinta cantidad de consumidores, **violan ese requisito por construcción**: el que corre menos consumidores gana la carrera para algunos eventos y los cierra, y el otro nunca los vuelve a ver. El resultado no es un reintento perdido, es una omisión permanente y silenciosa — el evento queda contabilizado como procesado sin haber generado ni su asiento contable ni su notificación.

El disparador manual del relay, que existe para depuración y operación puntual, SHALL invocar al mismo despachador único en lugar de implementar su propio recorrido de consumidores.

#### Scenario: El disparador manual produce el mismo resultado que el despachador programado

- **GIVEN** un evento pendiente cuyo tipo produce asiento contable
- **WHEN** el relay se dispara manualmente en lugar de esperar a la corrida programada
- **THEN** el evento queda procesado con sus cuatro consumidores aplicados, incluido su asiento contable, igual que si lo hubiera tomado la corrida programada

#### Scenario: No existe un segundo camino que marque procesado con menos consumidores

- **WHEN** se inspeccionan los componentes capaces de escribir la marca de procesado sobre un evento
- **THEN** el único que la escribe es el despachador de cuatro consumidores

#### Scenario: Ningún evento queda procesado sin su asiento

- **GIVEN** un conjunto de eventos de tipos que producen asiento contable
- **WHEN** se los procesa por cualquiera de los dos disparadores
- **THEN** no queda ningún evento con marca de procesado que carezca de su asiento correspondiente

### Requirement: El disparador manual del relay es un camino de servicio con acceso restringido a administración de plataforma

El sistema SHALL exigir rol de administrador de plataforma para disparar el relay del outbox manualmente, y SHALL ejecutar ese disparo sobre el contexto de conexión de servicio, separado del contexto de conexión del pedido de usuario.

El disparador recorre el outbox de **todos** los inquilinos por diseño: es una operación de máquina, no una operación de un inquilino sobre sus propios datos. Hasta ahora sólo exigía tener sesión iniciada, de modo que cualquier usuario podía provocar el recorrido completo. La verificación de rol SHALL resolverse con el mecanismo de administración de plataforma que ya existe y se usa en otros comandos administrativos, y no con uno nuevo.

Ejecutarlo sobre el contexto de conexión de servicio SHALL ser parte del contrato y no un detalle de implementación: es lo que hace que la restricción de permisos sobre las funciones del relay siga siendo válida cuando el contexto de pedido de usuario adopte el rol de aplicación. El contexto de servicio SHALL NOT adoptar ese rol bajo ninguna configuración, y esa propiedad SHALL estar verificada por una prueba automatizada y no solamente documentada.

#### Scenario: Un usuario común no puede disparar el relay

- **GIVEN** un usuario con sesión iniciada que no es administrador de plataforma
- **WHEN** invoca el disparador manual del relay
- **THEN** recibe un rechazo por permisos y ningún evento cambia de estado

#### Scenario: El administrador de plataforma sí puede

- **GIVEN** un usuario que es administrador de plataforma
- **WHEN** invoca el disparador manual del relay
- **THEN** el despacho se ejecuta y la respuesta informa cuántos eventos se procesaron

#### Scenario: El contexto de servicio no adopta el rol de aplicación

- **WHEN** ambas palancas de alcance de transacción y de adopción de rol están activas
- **THEN** una conexión obtenida por el contexto de servicio sigue operando con el rol propietario, de modo que el disparador funciona aunque las funciones del relay estén revocadas del rol de aplicación
