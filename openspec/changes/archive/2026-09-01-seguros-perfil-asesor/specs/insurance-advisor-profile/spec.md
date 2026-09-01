## ADDED Requirements

### Requirement: El catálogo de seguros distingue ofertas de perfiles de asesor
`community.seguros` SHALL discriminar el tipo de cada entrada mediante una columna `entry_type` con un conjunto cerrado de valores (`'offer'`, `'advisor'`), con default `'offer'` para preservar el comportamiento de las filas existentes. Una entrada de tipo `'advisor'` MUST tener `slug`; esa invariante MUST estar expresada como restricción de la tabla y no sólo como validación del formulario, para que no se pueda evadir escribiendo por la Data API.

#### Scenario: El default preserva la forma legacy
- **WHEN** se inserta una fila sin declarar `entry_type`
- **THEN** la fila queda con `entry_type = 'offer'` y se renderiza como la card de oferta con su link saliente, igual que antes del change

#### Scenario: Un tipo desconocido es rechazado
- **WHEN** se intenta insertar o actualizar una fila con `entry_type = 'partner'`
- **THEN** la escritura falla por violación de la restricción CHECK

#### Scenario: Un asesor sin slug es rechazado
- **WHEN** se intenta escribir una fila con `entry_type = 'advisor'` y `slug` nulo
- **THEN** la escritura falla por violación de restricción, tanto desde el formulario de admin como desde una llamada directa a la Data API

### Requirement: El contenido del perfil de asesor se modela estructurado
El perfil SHALL almacenar el material del asesor en campos con significado propio y no aplastado en texto libre: identidad (`advisor_name`, `advisor_role`), frase ancla y presentación (`headline`, `bio`), líneas de servicio y pilares de asesoramiento como listas ordenadas, zonas de cobertura como lista de strings, contacto estructurado (`contact_phone`, `contact_whatsapp`, `contact_email`, `contact_url`) y foto opcional (`photo_url`). Las listas ordenadas MUST persistirse como arrays y la base MUST rechazar un valor que no sea un array; la forma de cada elemento MUST validarse en el borde de la aplicación con el validador de esquemas del proyecto. Ningún tipo de estas estructuras SHALL declararse como `any` en TypeScript.

#### Scenario: Las líneas de servicio conservan su orden editorial
- **WHEN** se carga un asesor con tres líneas de servicio y se abre su perfil
- **THEN** las tres se renderizan en el mismo orden en que fueron cargadas

#### Scenario: La base rechaza una lista que no es array
- **WHEN** se intenta escribir un objeto o un escalar en `service_lines` o en `pillars`
- **THEN** la escritura falla por violación de la restricción de tipo de la columna

#### Scenario: Un perfil sin listas cargadas no rompe
- **WHEN** se abre el perfil de un asesor cuyas listas de servicios y pilares están vacías
- **THEN** la página renderiza la identidad y el contacto sin secciones vacías ni error

### Requirement: El perfil del asesor es accesible por una URL propia y estable
El sistema SHALL exponer el perfil en `/seguros/[slug]`, resolviendo el `slug` contra una entrada visible de tipo `'advisor'`. El `slug` MUST ser único entre las entradas que lo tienen y SHALL tratarse como identificador estable: es una URL que el partner puede compartir y renombrarla rompe los enlaces existentes.

#### Scenario: El slug resuelve el perfil
- **WHEN** un usuario autenticado navega a `/seguros/julian-dupas` y existe una entrada visible de tipo `advisor` con ese slug
- **THEN** se renderiza el perfil de ese asesor

#### Scenario: Slug inexistente
- **WHEN** un usuario navega a `/seguros/<slug-que-no-existe>`
- **THEN** la aplicación responde con la pantalla de no encontrado, sin filtrar detalle interno ni lanzar error no controlado

#### Scenario: Un asesor oculto no es accesible por URL directa
- **WHEN** un usuario sin rol de admin navega al slug de una entrada con `is_visible = false`
- **THEN** no se le muestra el perfil (la policy de lectura sólo alcanza filas visibles)

#### Scenario: Dos entradas no pueden compartir slug
- **WHEN** se intenta guardar una segunda entrada con un `slug` ya usado
- **THEN** la escritura falla por violación del índice único

### Requirement: El índice de seguros se adapta al conteo de asesores visibles
`/seguros` SHALL decidir su presentación a partir del conteo real de entradas visibles y no de una constante cableada. Con un único asesor visible y ninguna oferta, la página MUST llevar al usuario al perfil de ese asesor sin simular una grilla de catálogo; con dos o más asesores visibles, MUST renderizar una grilla donde cada card enlaza a `/seguros/[slug]`. Las entradas de tipo `'offer'` MUST seguir renderizándose como hasta ahora, con su enlace saliente. El estado vacío existente MUST conservarse cuando no hay ninguna entrada visible.

#### Scenario: Un solo asesor no deja huecos en la grilla
- **WHEN** hay exactamente una entrada visible, de tipo `advisor`, y ninguna oferta visible
- **THEN** la página presenta a ese asesor con su contenido y su acceso al perfil, sin renderizar una grilla de tres columnas con dos celdas vacías

#### Scenario: Varios asesores vuelven a la grilla
- **WHEN** hay dos o más entradas visibles de tipo `advisor`
- **THEN** se renderiza una card por asesor y cada una enlaza a `/seguros/<su slug>`

#### Scenario: Las ofertas legacy siguen funcionando
- **WHEN** hay al menos una entrada visible de tipo `offer`
- **THEN** esa entrada se renderiza como la card de oferta actual, con su botón "Más información" apuntando a `contact_url` en pestaña nueva con `rel="noopener noreferrer"`

#### Scenario: Sin contenido visible se conserva el estado vacío
- **WHEN** no hay ninguna entrada visible
- **THEN** se muestra el estado vacío existente de la página

### Requirement: El perfil identifica al asesor con su matrícula y declara el rol de Aliadata
El perfil SHALL publicar la identificación profesional del asesor —número de matrícula y, cuando esté cargada, la leyenda del organismo correspondiente— junto a su nombre y rol. El perfil MUST poder mostrar un texto de deslinde que aclare que Aliadata no es aseguradora ni intermediaria y que la contratación es directa con el asesor y la compañía. Tanto la leyenda regulatoria como el texto de deslinde MUST ser contenido editable por fila y no constantes en el código, de modo que corregirlos no requiera un despliegue. Un campo regulatorio vacío NOT SHALL renderizarse con texto de relleno ni con un valor inventado.

#### Scenario: Matrícula visible junto a la identidad
- **WHEN** se abre el perfil de un asesor con `license_number` cargado
- **THEN** el número de matrícula se muestra asociado al nombre y al rol profesional del asesor

#### Scenario: Leyenda del organismo sin cargar
- **WHEN** el perfil tiene `license_number` cargado y `license_authority` vacío
- **THEN** se muestra el número sin inventar organismo ni leyenda, y sin dejar una etiqueta huérfana

#### Scenario: El deslinde se corrige sin desplegar
- **WHEN** un admin edita el texto de deslinde desde el panel y guarda
- **THEN** el perfil muestra el texto nuevo sin necesidad de un nuevo despliegue de la aplicación

### Requirement: Las vías de contacto se renderizan sólo cuando su dato existe
El perfil SHALL ofrecer las vías de contacto cargadas —WhatsApp, correo, teléfono y web— y MUST omitir por completo la que no tenga dato. No SHALL renderizarse un control de contacto inerte, deshabilitado o que lleve a un destino vacío. El número de WhatsApp MUST persistirse ya normalizado en formato internacional apto para el enlace, separado del teléfono legible que se muestra, para que el enlace no dependa de un formateo hecho en el cliente. Los enlaces que abren en pestaña nueva MUST llevar `rel="noopener noreferrer"`.

#### Scenario: Sin WhatsApp confirmado el botón no existe
- **WHEN** se abre el perfil de un asesor cuyo `contact_whatsapp` está vacío
- **THEN** no se renderiza ningún control de WhatsApp, y el resto de las vías cargadas se muestran normalmente

#### Scenario: El enlace de WhatsApp usa el valor normalizado
- **WHEN** el asesor tiene `contact_whatsapp` cargado
- **THEN** el control enlaza a `https://wa.me/<ese valor>` en pestaña nueva con `rel="noopener noreferrer"`

#### Scenario: Correo y teléfono usan esquemas nativos
- **WHEN** el asesor tiene `contact_email` y `contact_phone` cargados
- **THEN** los controles correspondientes usan `mailto:` y `tel:` respectivamente

### Requirement: El registro de clicks distingue la vía de contacto sin alterar el contador total
El sistema SHALL registrar por cuál vía de contacto optó el usuario, incrementando en una sola operación atómica tanto el contador total existente (`clicks_count`) como el desglose por vía. El contador total MUST seguir significando exactamente lo mismo que antes del change: la cantidad de clicks de contacto de esa entrada. La función de tracking preexistente `public.increment_seguros_clicks(uuid)` NOT SHALL modificarse, renombrarse ni deprecarse, y los casos de prueba que hoy fijan su contrato MUST seguir pasando sin ser editados. Una vía no reconocida NOT SHALL escribir una clave arbitraria en el desglose. El tracking MUST conservar su contrato de fallo silencioso: ante cualquier error, se registra en consola y la navegación del usuario continúa, sin re-lanzar ni bloquear.

#### Scenario: Contacto por una vía incrementa total y desglose
- **WHEN** un usuario usa el control de WhatsApp de un asesor cuyo `clicks_count` vale 4
- **THEN** `clicks_count` pasa a 5 y el desglose de esa entrada registra un click más para la vía WhatsApp, en una única operación atómica

#### Scenario: Vía no reconocida no ensucia el desglose
- **WHEN** se invoca el tracking con una vía fuera del conjunto admitido
- **THEN** no se agrega esa clave al desglose y la operación no lanza error al usuario

#### Scenario: Un fallo del tracking no rompe la navegación
- **WHEN** la llamada de tracking falla por error de red o de permisos al usar un control de contacto
- **THEN** el error se registra en consola, la promesa no re-lanza, y el usuario llega igual a su destino de contacto

#### Scenario: El contrato del contador legacy sigue intacto
- **WHEN** se ejecuta la suite existente de tracking de clicks de seguros sin modificar sus casos
- **THEN** los casos pasan, incluido el que verifica que ante error el servicio no cae en una escritura no atómica sobre la tabla

### Requirement: La función de tracking por vía tiene ACLs restrictivos
La función nueva de tracking SHALL declararse `SECURITY DEFINER` con `search_path` vacío y referenciar `community.seguros` con schema calificado, siguiendo el patrón de la función de contador existente. Tras crearla, la migración MUST revocar `EXECUTE` explícitamente de `PUBLIC` y de `anon`, y otorgarlo únicamente al rol `authenticated`; revocar sólo de `PUBLIC` no alcanza, porque una función recién creada recibe `EXECUTE` para `anon` por privilegios por defecto.

#### Scenario: anon no puede ejecutar la función
- **WHEN** se consulta `has_function_privilege` para el rol `anon` sobre la función nueva
- **THEN** el resultado es falso

#### Scenario: authenticated puede ejecutar la función
- **WHEN** se consulta `has_function_privilege` para el rol `authenticated` sobre la función nueva
- **THEN** el resultado es verdadero

#### Scenario: El gate de ACLs pasa
- **WHEN** corre el gate de ACLs de funciones en CI con la migración aplicada
- **THEN** no reporta la función nueva como permisiva

### Requirement: Todos los campos del perfil son editables desde el panel de administración
`/admin/seguros` SHALL permitir crear y editar cada campo del perfil de asesor: tipo de entrada, slug, identidad y rol, matrícula y leyenda, presentación, líneas de servicio y pilares como listas ordenadas con alta, baja y reordenamiento, zonas de cobertura, las cuatro vías de contacto, foto, deslinde y destacado. Un campo del modelo que no tenga superficie de edición NOT SHALL considerarse entregado: sería contenido que nadie puede cargar. El panel MUST seguir exponiendo la visibilidad como acción explícita y MUST mostrar el desglose de clicks por vía junto al total.

#### Scenario: Alta completa de un asesor desde el panel
- **WHEN** un admin crea una entrada de tipo `advisor` cargando identidad, slug, matrícula, listas de servicios y pilares, zonas y vías de contacto, y guarda
- **THEN** la entrada se persiste con todos esos campos y el perfil los refleja al abrirse

#### Scenario: Reordenar una lista se persiste
- **WHEN** un admin cambia el orden de las líneas de servicio y guarda
- **THEN** el perfil las muestra en el orden nuevo

#### Scenario: El formulario de oferta legacy sigue operando
- **WHEN** un admin edita una entrada de tipo `offer`
- **THEN** puede editar los campos que esa forma usa sin que el formulario le exija los campos propios del perfil de asesor

#### Scenario: El desglose por vía es visible para el admin
- **WHEN** un admin abre el panel de seguros y hay clicks registrados por distintas vías
- **THEN** ve el total y el desglose por vía de contacto

### Requirement: El perfil cumple el sistema de diseño en ambos temas y ambos tamaños
El perfil y el índice SHALL construirse con los tokens semánticos y los componentes base del sistema de diseño del proyecto, y MUST verificarse en tema claro y oscuro y en desktop y mobile antes del merge. La ausencia de foto del asesor MUST degradar a las iniciales derivadas de su nombre, ocupando el mismo espacio que ocuparía la imagen para que el layout no cambie. Los componentes nuevos MUST nombrarse en PascalCase.

#### Scenario: Sin foto se rinden las iniciales
- **WHEN** se abre el perfil de un asesor sin `photo_url`
- **THEN** se muestran sus iniciales en el lugar y con las dimensiones que tendría la foto, sin hueco ni salto de layout

#### Scenario: Legibilidad en ambos temas
- **WHEN** se visualiza el perfil en tema claro y en tema oscuro
- **THEN** todo el texto y los controles cumplen el contraste exigido por el sistema de diseño, sin colores cableados fuera de los tokens

#### Scenario: Perfil usable en mobile
- **WHEN** se visualiza el perfil en un viewport de ancho de teléfono
- **THEN** el contenido se reordena en una columna, sin desbordes horizontales, y las vías de contacto siguen alcanzables

### Requirement: La carga inicial del partner es idempotente y no publica automáticamente
La migración SHALL sembrar la entrada del partner de forma idempotente, de modo que reaplicarla no duplique la fila ni pise ediciones hechas desde el panel con valores vacíos. La entrada MUST sembrarse con `is_visible = false`: la publicación es una decisión explícita del PO mediante la acción de visibilidad ya existente, nunca un efecto colateral de desplegar. Los campos cuyo contenido dependa de una confirmación pendiente MUST sembrarse vacíos y quedar completables desde el panel sin requerir una migración nueva.

#### Scenario: Reaplicar la migración no duplica
- **WHEN** la migración se aplica dos veces sobre la misma base
- **THEN** existe exactamente una entrada con ese slug

#### Scenario: El despliegue no publica al partner
- **WHEN** la migración se aplica en producción
- **THEN** la entrada del partner queda con `is_visible = false` y `/seguros` sigue mostrando lo que mostraba antes para un usuario no admin

#### Scenario: Completar un dato pendiente no requiere migración
- **WHEN** el PO carga desde el panel un dato que se sembró vacío, como el WhatsApp confirmado o la leyenda del organismo
- **THEN** el perfil lo refleja sin desplegar ni migrar
