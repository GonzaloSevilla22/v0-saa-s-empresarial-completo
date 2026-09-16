## ADDED Requirements

### Requirement: La sesión del navegador vive sólo en cookies httpOnly escritas por el servidor

El sistema SHALL persistir la sesión de autenticación (access token y refresh token) exclusivamente en cookies marcadas `HttpOnly`, `Secure` en producción, `SameSite=Lax` y `Path=/`, escritas **únicamente** desde código de servidor (middleware, Route Handlers y Server Actions).

Ningún código que se ejecute en el navegador SHALL escribir, leer ni derivar el contenido de esas cookies. En particular, el refresh token NOT SHALL ser accesible desde JavaScript en ninguna circunstancia.

Los atributos de cookie SHALL provenir de una **única** definición compartida por todos los caminos de servidor que construyen el cliente de autenticación, de modo que no exista un camino que escriba la sesión con atributos distintos de otro.

#### Scenario: La respuesta de un login exitoso marca la cookie como httpOnly

- **WHEN** un usuario inicia sesión correctamente
- **THEN** la respuesta emite la cookie de sesión con los atributos `HttpOnly`, `SameSite=Lax` y `Path=/`, y con `Secure` cuando el entorno es producción

#### Scenario: El refresh token no es alcanzable desde el navegador

- **GIVEN** una sesión iniciada
- **WHEN** se inspecciona todo el estado accesible a JavaScript en la página (cookies legibles, almacenamiento local, almacenamiento de sesión y variables expuestas)
- **THEN** el refresh token no aparece en ninguno de ellos

#### Scenario: Todos los caminos de servidor escriben con los mismos atributos

- **WHEN** se revisan los lugares donde el servidor construye el cliente de autenticación (middleware, Route Handlers y Server Actions)
- **THEN** todos toman los atributos de cookie de la misma definición compartida, y ninguno declara sus propios atributos

#### Scenario: Las sesiones ya abiertas sobreviven al despliegue

- **GIVEN** una sesión válida iniciada antes de este cambio, con cookies sin `HttpOnly`
- **WHEN** el usuario navega después del despliegue
- **THEN** la sesión sigue siendo válida sin pedir un nuevo inicio de sesión, y el servidor reescribe las cookies con `HttpOnly` en la primera renovación

### Requirement: Las operaciones de autenticación ocurren en el servidor

El sistema SHALL ejecutar en el servidor toda operación que cree, modifique o destruya la sesión: inicio de sesión con contraseña (incluido el token de captcha), registro, enlace mágico, recuperación de contraseña, reenvío de verificación, cambio de contraseña o de email, intercambio del código PKCE y cierre de sesión.

El navegador NOT SHALL invocar directamente el proveedor de autenticación para ninguna de esas operaciones: SHALL invocar una acción de servidor o un manejador de ruta del propio dominio, que es el único que ve las credenciales del proveedor y el único que escribe las cookies.

#### Scenario: El inicio de sesión no viaja desde el navegador al proveedor

- **WHEN** el usuario envía el formulario de inicio de sesión
- **THEN** el navegador envía las credenciales y el token de captcha a una acción del propio dominio, y es el servidor quien contacta al proveedor de autenticación

#### Scenario: El cierre de sesión revoca del lado del servidor

- **WHEN** el usuario cierra sesión
- **THEN** el servidor revoca la sesión contra el proveedor y borra las cookies de sesión en la misma respuesta

#### Scenario: El intercambio del código de un enlace por email ocurre en el servidor

- **WHEN** el usuario abre un enlace de recuperación, de verificación o de cambio de email
- **THEN** el manejador de ruta del servidor intercambia el código por una sesión y escribe las cookies, sin que el código ni la sesión pasen por JavaScript del navegador

### Requirement: La pantalla de verificación de email consulta el estado al servidor

El sistema SHALL exponer un manejador de ruta que informe si la dirección de correo de la sesión actual ya fue confirmada, forzando para ello una renovación contra el proveedor —que es la única forma de observar una confirmación recién ocurrida— y devolviendo únicamente la dirección y el instante de confirmación.

La pantalla de verificación NOT SHALL sondear al proveedor desde el navegador ni suscribirse a su observador de estado de autenticación: con el token provisto desde el exterior, esas operaciones dejan de estar disponibles. El reenvío del correo de verificación SHALL ocurrir también en el servidor, conservando el límite de frecuencia que hoy aplica la pantalla.

Ese manejador NOT SHALL devolver token alguno.

#### Scenario: La pantalla detecta la confirmación sin recargar

- **GIVEN** un usuario recién registrado esperando en la pantalla de verificación
- **WHEN** confirma su dirección desde el enlace recibido por correo
- **THEN** la pantalla lo detecta consultando el manejador de estado y continúa al área autenticada, sin que el usuario recargue

#### Scenario: El estado de verificación no expone credenciales

- **WHEN** se consulta el manejador de estado de verificación
- **THEN** la respuesta contiene la dirección y el instante de confirmación, y no contiene ningún token

### Requirement: El navegador obtiene un access token efímero en memoria, nunca el refresh token

El sistema SHALL exponer un manejador de ruta que, leyendo la cookie httpOnly de sesión, devuelva al navegador el **access token vigente**, su instante de vencimiento y la identidad del usuario, y NOT SHALL devolver nunca el refresh token.

El access token SHALL mantenerse únicamente en memoria del proceso de la página. NOT SHALL persistirse en cookies legibles, almacenamiento local ni almacenamiento de sesión, de modo que se pierda al cerrar la pestaña.

Cuando el token esté por vencer, cuando la pestaña vuelva a ser visible, o cuando cualquier consumidor reciba una respuesta de no autorizado, el navegador SHALL volver a pedirlo. Si esa renovación produce credenciales rotadas, el servidor SHALL reescribir las cookies httpOnly en esa misma respuesta.

Ese manejador es el único punto donde la credencial protegida vuelve a ser legible, y por lo tanto SHALL cumplir además:

- SHALL emitir `Cache-Control: no-store` y declarar que su respuesta varía según la cookie, de modo que ninguna capa intermedia pueda servir el token de una identidad a otra.
- NOT SHALL emitir encabezados que autoricen la lectura desde otro origen, bajo ninguna configuración.
- SHALL rechazar la petición cuando el navegador declare que no proviene del mismo sitio.
- SHALL aplicar **la misma decisión de inactividad** que el middleware sobre la ruta protegida y, cuando la sesión esté ociosa, SHALL revocarla, borrar las cookies y responder que no hay sesión, en lugar de renovarla. Sin esa condición, este manejador sería un segundo camino de renovación **no sujeto al corte por inactividad**, que mantendría viva indefinidamente la sesión de un usuario ausente desde una pestaña de fondo.
- SHALL deduplicar las renovaciones en vuelo, de modo que varias peticiones concurrentes no presenten el mismo token de renovación por separado, y NOT SHALL renovar cuando la propia petición ya obtuvo credenciales frescas por otro camino del servidor.

La obtención del token desde el navegador SHALL resolverse con un valor vacío cuando no hay sesión, y NOT SHALL lanzar: una página pública sin sesión debe seguir funcionando con la clave anónima en lugar de romperse.

#### Scenario: El endpoint de token no filtra el refresh token

- **WHEN** el navegador pide el access token al manejador de ruta
- **THEN** la respuesta contiene el access token, su vencimiento y la identidad del usuario, y no contiene el refresh token bajo ningún nombre

#### Scenario: El token no sobrevive al cierre de la pestaña

- **GIVEN** una sesión activa con el access token en memoria
- **WHEN** se cierra y se vuelve a abrir la pestaña
- **THEN** el navegador no encuentra ningún token almacenado y lo vuelve a pedir al servidor, que lo entrega porque la cookie httpOnly sigue presente

#### Scenario: La renovación rota las cookies del servidor

- **WHEN** el access token está por vencer y el navegador lo vuelve a pedir
- **THEN** el servidor renueva contra el proveedor, emite las cookies de sesión rotadas con los mismos atributos y devuelve el access token nuevo

#### Scenario: Sin sesión, el endpoint no entrega token

- **GIVEN** una petición sin cookie de sesión válida
- **WHEN** se pide el access token
- **THEN** el manejador responde que no hay sesión, sin emitir token alguno

#### Scenario: Sin sesión, una página pública no se rompe

- **GIVEN** un visitante anónimo en una página pública que consulta datos al proveedor
- **WHEN** la obtención del token resuelve sin sesión
- **THEN** la consulta se emite con la clave anónima y la página renderiza, en lugar de fallar por una excepción

#### Scenario: La respuesta del endpoint de token no es cacheable ni legible desde otro origen

- **WHEN** se inspecciona la respuesta del manejador de token
- **THEN** declara que no debe almacenarse, declara que varía según la cookie, y no incluye ningún encabezado que autorice la lectura desde otro origen

#### Scenario: Una petición que no es del mismo sitio se rechaza

- **WHEN** llega una petición al manejador de token cuyo navegador declara un origen distinto del propio sitio
- **THEN** el manejador la rechaza sin emitir token

#### Scenario: Una sesión ociosa no se renueva por el endpoint de token

- **GIVEN** una sesión cuya última actividad registrada excede el umbral de inactividad
- **WHEN** una pestaña en segundo plano pide el access token
- **THEN** el manejador revoca la sesión, borra las cookies y responde que no hay sesión, sin renovar nada

#### Scenario: Dos pedidos concurrentes producen una sola renovación

- **GIVEN** dos consumidores que piden el token a la vez con el access token vencido
- **WHEN** el manejador atiende ambos
- **THEN** se realiza una sola renovación contra el proveedor y ambos reciben el mismo token nuevo

### Requirement: Los consumidores del navegador toman el token del proveedor en memoria

El sistema SHALL construir el cliente de datos del navegador de modo que obtenga el access token de la fuente en memoria en cada llamada, y NOT SHALL construirlo sobre un almacenamiento de sesión propio del navegador.

Todo transporte del navegador hacia el backend propio SHALL adjuntar el encabezado de autorización **sólo** cuando haya un token, y NOT SHALL enviar un encabezado con valor vacío. La resolución del token SHALL estar centralizada: NOT SHALL existir más de una implementación de "armar los encabezados de autenticación".

#### Scenario: Las llamadas de datos llevan el token en memoria

- **WHEN** la página consulta datos al proveedor o al backend propio
- **THEN** la llamada lleva el access token obtenido de la fuente en memoria, sin leer ninguna cookie desde JavaScript

#### Scenario: Sin token no se envía encabezado vacío

- **GIVEN** un momento en que no hay access token disponible
- **WHEN** se arma una llamada al backend propio
- **THEN** la llamada se emite sin encabezado de autorización, en lugar de emitirlo con un valor vacío

#### Scenario: Una sola implementación arma los encabezados

- **WHEN** se revisan los transportes del navegador hacia el backend propio
- **THEN** todos derivan sus encabezados de autenticación de la misma implementación compartida

### Requirement: Los eventos de sesión se propagan por un bus propio de la aplicación

El sistema SHALL propagar los cambios de estado de sesión (sesión iniciada, token renovado, sesión cerrada) mediante un bus de eventos de la propia aplicación, y NOT SHALL depender del observador de estado de autenticación de la librería del proveedor, que deja de estar disponible cuando el token se provee desde el exterior.

El bus SHALL reutilizar el transporte entre pestañas ya existente en el proyecto, en lugar de introducir un segundo mecanismo equivalente. Esa reutilización SHALL resolver dos incompatibilidades del transporte actual antes de apoyarse en él:

- El transporte SHALL admitir **varios suscriptores** simultáneos. Hoy registrar un receptor **reemplaza** al anterior, de modo que montar el bus sobre la misma instancia desuscribiría en silencio al temporizador de inactividad.
- Los eventos de sesión SHALL usar **tipos de mensaje propios**, distintos de los del temporizador de inactividad. En particular NOT SHALL reutilizarse el mensaje de cierre del temporizador, que ya significa "cierre por inactividad" para su consumidor: hacerlo haría que un cierre manual en una pestaña mostrara a las demás el aviso de inactividad.

#### Scenario: El temporizador de inactividad sigue recibiendo sus mensajes

- **GIVEN** el temporizador de inactividad y el bus de sesión suscritos al mismo transporte
- **WHEN** otra pestaña emite un mensaje de actividad
- **THEN** el temporizador lo recibe, sin que la suscripción del bus lo haya desplazado

#### Scenario: Un cierre manual no se confunde con un cierre por inactividad

- **GIVEN** la aplicación abierta en dos pestañas
- **WHEN** el usuario cierra sesión manualmente en una
- **THEN** la otra pestaña deja de considerarlo autenticado sin mostrar el aviso de cierre por inactividad

#### Scenario: El cierre de sesión alcanza a las demás pestañas

- **GIVEN** la aplicación abierta en dos pestañas
- **WHEN** el usuario cierra sesión en una
- **THEN** la otra recibe el evento por el bus y deja de considerar al usuario autenticado

#### Scenario: No se introduce un transporte duplicado

- **WHEN** se revisa cómo se comunican las pestañas entre sí
- **THEN** existe un único transporte entre pestañas en el proyecto, compartido por el temporizador de inactividad y por el bus de sesión

### Requirement: La política de seguridad de contenido usa un nonce por petición en producción

El sistema SHALL emitir en producción una directiva de scripts basada en un **nonce generado por petición** junto con `'strict-dynamic'`, y NOT SHALL incluir `'unsafe-inline'` ni `'unsafe-eval'` en esa directiva.

`'unsafe-eval'` SHALL admitirse únicamente cuando el entorno no es producción. La directiva de estilos SHALL conservar `'unsafe-inline'`, porque el sistema de estilos y los componentes de gráficos inyectan estilos en tiempo de ejecución.

El nonce SHALL generarse en el middleware **una sola vez por petición** y SHALL reutilizarse para todos los scripts de esa respuesta.

El middleware SHALL propagar el nonce al render adjuntando a los **encabezados de la petición reenviada** tanto un encabezado propio con el valor del nonce como el **encabezado completo de política de seguridad de contenido**, y SHALL emitir la **misma** política —con el **mismo** nonce— en la respuesta. El framework obtiene el nonce de sus propios scripts de arranque e hidratación parseando el encabezado de política en la petición, no el encabezado propio: si sólo viaja el encabezado propio, esos scripts salen sin nonce y, bajo `'strict-dynamic'`, la página queda **en blanco**.

Esa propagación SHALL preservarse en **todos** los puntos donde el middleware reconstruye la respuesta, incluido el camino que se ejecuta al rotar las cookies de sesión: reconstruir la respuesta descartando los encabezados de petición modificados afecta precisamente a las peticiones autenticadas.

El nonce SHALL aplicarse además a todo script en línea que la aplicación emita, incluido el que inyecta el proveedor de temas para evitar el parpadeo de tema. Como el componente que lo monta se ejecuta en el cliente, el valor SHALL leerse en el layout raíz del servidor y pasarse hacia abajo.

La directiva SHALL admitir la instanciación de WebAssembly en producción, de modo que retirar la evaluación dinámica no deshabilite de forma colateral los decodificadores que la interfaz 3D puede necesitar.

#### Scenario: La respuesta de producción no habilita scripts en línea arbitrarios

- **WHEN** se inspecciona el encabezado de política de seguridad de contenido de una respuesta de producción
- **THEN** la directiva de scripts contiene un nonce y `'strict-dynamic'`, y no contiene `'unsafe-inline'` ni `'unsafe-eval'`

#### Scenario: Cada petición recibe un nonce distinto

- **WHEN** se piden dos páginas consecutivas
- **THEN** el nonce de la segunda difiere del de la primera

#### Scenario: El nonce viaja en la petición reenviada y coincide con el de la respuesta

- **WHEN** el middleware procesa una petición de página
- **THEN** los encabezados de la petición reenviada incluyen la política de seguridad de contenido completa, y el nonce que declara es idéntico al de la política emitida en la respuesta

#### Scenario: Rotar las cookies no descarta el nonce de la petición

- **GIVEN** una petición autenticada en la que el servidor renueva la sesión y reescribe las cookies
- **WHEN** el middleware reconstruye la respuesta en ese camino
- **THEN** los encabezados de la petición reenviada siguen llevando la política con el nonce, y no quedan descartados

#### Scenario: Los scripts propios del framework se ejecutan bajo la política

- **WHEN** se carga una página de producción cuya política declara nonce y `'strict-dynamic'` sin permisos en línea
- **THEN** la página hidrata y funciona, porque los scripts de arranque del framework llevan el nonce de esa petición

#### Scenario: El script de tema lleva el nonce y no parpadea

- **WHEN** se carga una página en producción con el tema oscuro seleccionado
- **THEN** el script en línea del proveedor de temas se ejecuta porque lleva el nonce de esa petición, y la página no muestra el parpadeo de tema claro

#### Scenario: Fuera de producción se conserva la evaluación dinámica

- **WHEN** la aplicación corre en un entorno que no es producción
- **THEN** la directiva de scripts admite `'unsafe-eval'`, de modo que las herramientas de desarrollo siguen funcionando

### Requirement: Toda ruta del área autenticada está protegida por construcción

El sistema SHALL determinar las rutas protegidas por **exclusión**: SHALL declarar una lista explícita de rutas públicas, y SHALL tratar como protegida toda ruta del área autenticada que no figure en ella.

La suite de tests SHALL verificar la cobertura leyendo el árbol de rutas del área autenticada desde el sistema de archivos, y SHALL fallar cuando exista un árbol de ruta que no quede cubierto ni por la lista pública ni por la regla de protección. La verificación NOT SHALL consistir en comprobar un prefijo enumerado a mano, y SHALL declarar explícitamente qué árboles quedan fuera de su alcance en lugar de aparentar cubrirlos.

Las rutas de autenticación SHALL quedar fuera del conjunto protegido, para que el destino del redireccionamiento no pueda entrar en bucle.

Las rutas de interfaz de programación del propio dominio SHALL quedar fuera del redireccionamiento: NOT SHALL recibir una respuesta de redirección hacia la página de inicio de sesión, y cada manejador SHALL responder no autorizado con cuerpo de datos cuando no exista sesión. Redirigirlas devolvería una página HTML donde el consumidor espera datos, y en particular dejaría inutilizable el propio manejador que entrega el access token.

#### Scenario: Una ruta de interfaz de programación sin sesión responde no autorizado, no una redirección

- **GIVEN** un visitante sin sesión
- **WHEN** solicita una ruta de interfaz de programación del propio dominio, incluida la que entrega el access token
- **THEN** recibe una respuesta de no autorizado con cuerpo de datos, y no una redirección a la página de inicio de sesión

#### Scenario: Una ruta del área autenticada exige sesión

- **GIVEN** un visitante sin sesión
- **WHEN** solicita cualquier ruta del área autenticada
- **THEN** recibe un redireccionamiento a la página de inicio de sesión con la ruta original como destino de retorno

#### Scenario: Una ruta nueva sin cobertura rompe la suite

- **GIVEN** un árbol de ruta nuevo agregado al área autenticada que no figura en la lista pública ni queda cubierto por la regla
- **WHEN** se ejecuta la suite de tests
- **THEN** la suite falla señalando la ruta sin cobertura

#### Scenario: Las rutas de autenticación no se gatean

- **WHEN** un visitante sin sesión solicita la página de inicio de sesión
- **THEN** la página se renderiza sin redireccionamiento

### Requirement: El destino de retorno se valida en un único lugar

El sistema SHALL validar el parámetro de destino de retorno con **una sola** implementación compartida, consumida por **todos** los caminos que resuelven ese destino: el middleware, el manejador de la ruta de retorno de los enlaces por email y el formulario de inicio de sesión.

Un destino que no sea una ruta interna del propio sitio SHALL reemplazarse por la ruta principal del área autenticada. Ningún camino de la aplicación SHALL concatenar el destino recibido a la URL base sin validarlo.

La validación SHALL rechazar los caracteres de control, y el camino que resuelve el destino contra la URL base SHALL comprobar que el origen de la URL resultante es el propio antes de emitirla. Comprobar únicamente los primeros caracteres de la cadena no alcanza: el analizador de URL del navegador **elimina** el tabulador, el salto de línea y el retorno de carro antes de analizar, de modo que un destino con uno de esos caracteres en segunda posición se resuelve contra otro host aunque empiece por una sola barra.

Ningún componente ni manejador SHALL redirigir a una ruta de inicio de sesión que no exista: el destino SHALL ser siempre la ruta real de inicio de sesión, con el destino de retorno adjunto.

#### Scenario: Un destino externo se descarta

- **WHEN** llega un destino de retorno que apunta a otro host o que no empieza por una barra
- **THEN** el redireccionamiento resuelve a la ruta principal del área autenticada, no al destino recibido

#### Scenario: Un destino con caracteres de control se descarta

- **WHEN** llega un destino de retorno que contiene un tabulador, un salto de línea o un retorno de carro
- **THEN** se descarta y el redireccionamiento resuelve a la ruta principal del área autenticada, dentro del propio origen

#### Scenario: El retorno de un enlace por email valida igual que el middleware

- **WHEN** el manejador de la ruta de retorno recibe un destino manipulado
- **THEN** aplica exactamente la misma validación que el middleware y no redirige fuera del sitio

#### Scenario: El formulario de inicio de sesión valida igual que el middleware

- **GIVEN** un visitante sin sesión, para quien el middleware no evalúa el destino de retorno porque la página de inicio de sesión es pública
- **WHEN** inicia sesión con éxito y el destino de retorno recibido apunta a otro host
- **THEN** la navegación posterior resuelve a la ruta principal del área autenticada, nunca fuera del sitio

#### Scenario: Ningún componente apunta a una ruta de login inexistente

- **WHEN** se revisa el árbol de páginas y manejadores en busca de redireccionamientos al inicio de sesión
- **THEN** todos apuntan a la ruta real de inicio de sesión, y la suite falla si aparece el literal de la ruta inexistente

### Requirement: Las cookies renovadas viajan en los redireccionamientos que no cierran la sesión

El sistema SHALL copiar las cookies de sesión escritas durante la petición a toda respuesta de redireccionamiento **que no tenga por objeto terminar la sesión**, y NOT SHALL devolver un redireccionamiento de ese tipo que descarte una renovación ya realizada.

Los redireccionamientos cuyo propósito **es** terminar la sesión —la purga de una sesión cuyo token de renovación ya no existe, y el cierre forzado por inactividad— NOT SHALL recibir esa copia: su respuesta SHALL contener únicamente borrados de las cookies de sesión. Copiar allí las cookies recién escritas las repondría y anularía en silencio tanto la recuperación de la sesión muerta como el corte por inactividad.

#### Scenario: Un redireccionamiento ordinario conserva la sesión renovada

- **GIVEN** una petición en la que el servidor renovó la sesión y escribió cookies nuevas
- **WHEN** el middleware redirige por una razón que no cierra la sesión (email sin confirmar, falta de permisos de administración, o usuario autenticado que pide una ruta de autenticación)
- **THEN** la respuesta de redireccionamiento incluye las cookies renovadas

#### Scenario: El cierre por inactividad no repone las cookies de sesión

- **GIVEN** una petición en la que el servidor renovó la sesión antes de evaluar la inactividad
- **WHEN** el middleware fuerza el cierre por inactividad
- **THEN** la respuesta no emite ninguna cookie de sesión salvo sus borrados

#### Scenario: La purga de una sesión muerta no repone las cookies de sesión

- **WHEN** el middleware detecta que el token de renovación ya no existe y purga la sesión
- **THEN** la respuesta no emite ninguna cookie de sesión salvo sus borrados

### Requirement: El cierre de sesión es uno solo y no deja residuos

El sistema SHALL cerrar la sesión con un mecanismo compartido por los tres caminos —cierre manual, cierre por inactividad del cliente y cierre por inactividad del servidor—, que SHALL revocar la sesión del lado del servidor y SHALL borrar **todas** las cookies de experiencia asociadas a la sesión, incluidas la de última actividad y la de cuenta activa.

El cierre manual y el cierre por inactividad SHALL revocar **únicamente la sesión actual**. La acción explícita de cerrar todas las sesiones SHALL conservar el alcance global; ninguna otra acción SHALL revocar sesiones de otros dispositivos.

#### Scenario: Cerrar sesión no desloguea los otros dispositivos

- **GIVEN** el mismo usuario con sesión iniciada en dos dispositivos
- **WHEN** cierra sesión en uno
- **THEN** la sesión del otro dispositivo sigue activa

#### Scenario: Cerrar todas las sesiones sí alcanza a los demás dispositivos

- **WHEN** el usuario activa la acción explícita de cerrar todas las sesiones
- **THEN** las sesiones de todos los dispositivos quedan revocadas

#### Scenario: El cierre por inactividad del servidor revoca antes de borrar

- **WHEN** el middleware detecta inactividad y fuerza el cierre
- **THEN** revoca la sesión contra el proveedor y sólo después borra las cookies de la respuesta

#### Scenario: El primer reingreso tras un cierre por inactividad no rebota

- **GIVEN** una sesión cerrada por inactividad
- **WHEN** el usuario vuelve a iniciar sesión y navega al área autenticada
- **THEN** la navegación se completa en el primer intento, sin ser devuelto a la página de inicio de sesión

### Requirement: Una respuesta de no autorizado del backend propio lleva al inicio de sesión

El sistema SHALL reaccionar a una respuesta de no autorizado del backend propio consultando el estado de sesión y, cuando no exista sesión, SHALL navegar a la página de inicio de sesión con el motivo de vencimiento y la ruta actual como destino de retorno.

NOT SHALL limitarse a mostrar un mensaje que sugiera recargar la página, porque la renovación por navegación no ocurre en toda ruta.

La consulta del estado de sesión SHALL distinguir tres desenlaces —sesión presente, sesión ausente y estado indeterminado— y SHALL navegar **únicamente** cuando la sesión esté ausente: un fallo transitorio de la consulta no es una sesión ausente, y navegar en ese caso descarta el estado de la pantalla en curso. Cuando la sesión esté presente, el mensaje NOT SHALL afirmar un problema de permisos si el token vigente difiere del que se envió en la llamada rechazada: en ese caso el rechazo fue por frescura y ya está resuelto.

La página de inicio de sesión SHALL explicar ese motivo al usuario, con el mismo mecanismo con que ya explica el cierre por inactividad: un motivo de vencimiento que llega sin mensaje visible deja al usuario frente a un formulario que no pidió, sin saber por qué.

#### Scenario: La página de inicio de sesión explica el vencimiento

- **WHEN** la página de inicio de sesión se carga con el motivo de vencimiento
- **THEN** se muestra un mensaje indicando que la sesión venció, análogo al que se muestra para el cierre por inactividad

#### Scenario: Sesión vencida durante el uso

- **GIVEN** un usuario cuyo token venció mientras usaba una pantalla
- **WHEN** una llamada al backend propio responde no autorizado y no existe sesión
- **THEN** la aplicación navega a la página de inicio de sesión con el motivo de vencimiento y la ruta actual como destino de retorno

#### Scenario: Un no autorizado con sesión viva conserva el error

- **GIVEN** una sesión válida
- **WHEN** una llamada responde no autorizado por una razón distinta del vencimiento
- **THEN** la aplicación muestra el error sin cerrar la sesión ni navegar

#### Scenario: Un estado de sesión indeterminado no expulsa al usuario

- **GIVEN** una consulta del estado de sesión que falla sin poder determinarlo
- **WHEN** una llamada al backend propio responde no autorizado
- **THEN** la aplicación conserva la pantalla en curso, no navega, y el mensaje no afirma un problema de permisos

#### Scenario: Un no autorizado cuya sesión se renovó no se informa como falta de permisos

- **GIVEN** un token que venció mientras la pantalla estaba abierta y una consulta de sesión que lo renueva
- **WHEN** la llamada rechazada se compara con el token vigente y difieren
- **THEN** el mensaje indica que la sesión se renovó y que la operación puede reintentarse, sin navegar

### Requirement: El modelo declara qué protege y qué no

El sistema SHALL documentar que este modelo elimina la **exfiltración** de la credencial renovable y su uso fuera del navegador de la víctima, y que NOT SHALL considerarse una defensa completa contra la ejecución de código ajeno en la página: mientras la pestaña está abierta, código inyectado puede obtener el access token efímero y actuar como el usuario durante la vida de ese token.

La política de seguridad de contenido con nonce SHALL declararse como el control que reduce la probabilidad de esa ejecución, y las cookies httpOnly como el control que reduce su impacto y su persistencia.

#### Scenario: El alcance del control queda documentado

- **WHEN** se revisa la documentación del modelo de sesión
- **THEN** declara explícitamente que el riesgo residual es la actuación en la página durante la vida del access token, y que lo que se cierra es la exfiltración del token de renovación
