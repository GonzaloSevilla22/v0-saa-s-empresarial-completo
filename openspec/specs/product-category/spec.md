# product-category Specification

## Purpose
Da a cada cuenta un catálogo plano y editable de categorías de producto (`product_categories`), sembrado con siete valores por defecto en el provisioning y usado como fuente única de verdad por todo el sistema — reemplazando la lista fija de 7 categorías que antes vivía horneada en el cliente y en el importador. La columna `products.category_id` es la **única representación física** de la categoría del producto; no existe ninguna columna con el nombre de la categoría en la tabla de productos — el nombre legible se deriva del catálogo en el momento de la lectura. Incluye la gestión del catálogo (alta, renombre, reorden, baja como soft delete), la herencia automática de categoría de variante a partir de su padre, la resolución/creación de categorías durante la carga masiva, y la recategorización en lote de productos desde el listado.

## Requirements

### Requirement: Catálogo de categorías de producto por cuenta

El sistema SHALL persistir un catálogo plano de categorías de producto en la tabla `product_categories` (`id` UUID PK, `account_id` UUID FK `accounts` NOT NULL, `name` TEXT NOT NULL, `is_active` BOOLEAN NOT NULL DEFAULT TRUE, `sort_order` INTEGER NOT NULL DEFAULT 0, `created_at` TIMESTAMPTZ NOT NULL DEFAULT now(), `deleted_at` TIMESTAMPTZ NULL, `deleted_by` UUID NULL). El catálogo SHALL ser **plano** (sin jerarquía ni subcategorías) y enteramente editable por el usuario en su `name` y su `sort_order`. El sistema SHALL impedir nombres duplicados dentro de una misma cuenta de forma case-insensitive sobre las filas vivas (`UNIQUE(account_id, lower(name)) WHERE deleted_at IS NULL`). La tabla SHALL tener RLS por `account_id` con tenancy account-direct, igual que `cost_centers` y `payment_methods`.

Ninguna capa del sistema SHALL conservar una lista fija global de categorías de producto: la lista de 7 valores horneada en el cliente y la copia propia del importador SHALL retirarse, de modo que el catálogo de la cuenta sea la única fuente.

#### Scenario: Crear una categoría

- **WHEN** un `owner`/`admin` crea una categoría con un nombre válido
- **THEN** se persiste una fila en `product_categories` con el `account_id` de su cuenta, `is_active = true` y `deleted_at = NULL`

#### Scenario: Nombre duplicado en la misma cuenta es rechazado

- **GIVEN** una cuenta que ya tiene una categoría viva "Ferretería"
- **WHEN** se intenta crear otra "ferreteria " en la misma cuenta
- **THEN** la operación es rechazada por el unique case-insensitive

#### Scenario: Aislamiento por cuenta

- **GIVEN** categorías de la cuenta A y de la cuenta B
- **WHEN** un usuario de la cuenta A lista sus categorías
- **THEN** sólo ve las de la cuenta A

#### Scenario: Dos cuentas pueden usar el mismo nombre

- **GIVEN** la cuenta A con una categoría "Repuestos"
- **WHEN** la cuenta B crea su propia categoría "Repuestos"
- **THEN** ambas coexisten como filas distintas, cada una en su cuenta

#### Scenario: No sobrevive ninguna lista fija de categorías

- **WHEN** se inspecciona el código en busca de enumeraciones literales de categorías de producto
- **THEN** no existe ninguna constante de cliente ni conjunto de validación del importador que enumere categorías
- **AND** toda superficie que ofrece categorías las obtiene del catálogo de la cuenta

### Requirement: Seed de categorías en el provisioning de la cuenta

El sistema SHALL sembrar siete categorías al crear una cuenta —Electrónica, Ropa, Alimentos, Hogar, Salud, Accesorios y Otros, con `sort_order` 1 a 7— de modo que un tenant nuevo pueda imputar productos sin configuración manual. El seed SHALL ejecutarse dentro de `handle_new_user` envuelto de forma que un fallo suyo **NUNCA** aborte el signup (degrada con warning), SHALL ser idempotente, y SHALL aplicarse por backfill a las cuentas ya existentes.

Las siete categorías sembradas SHALL ser un valor por defecto y no un conjunto privilegiado: SHALL poder renombrarse, reordenarse y desactivarse exactamente igual que cualquier categoría creada por el usuario, sin ningún tratamiento especial en el código.

#### Scenario: Cuenta nueva nace con el catálogo sembrado

- **WHEN** se registra un usuario nuevo y se provisiona su cuenta
- **THEN** la cuenta tiene las siete categorías activas, sin intervención manual

#### Scenario: El seed no puede romper el registro

- **GIVEN** una condición que hace fallar el sub-bloque de seed de categorías
- **WHEN** se registra un usuario nuevo
- **THEN** el perfil, la cuenta y la membresía se crean igual y el fallo del seed sólo deja un warning

#### Scenario: Re-ejecución idempotente

- **GIVEN** una cuenta que ya tiene el catálogo sembrado
- **WHEN** el backfill vuelve a ejecutarse
- **THEN** no se duplica ninguna categoría

#### Scenario: Una categoría sembrada se renombra como cualquier otra

- **GIVEN** la categoría sembrada "Otros"
- **WHEN** un `owner` la renombra a "Sin clasificar"
- **THEN** la operación es permitida y ningún camino del sistema depende del literal anterior

### Requirement: Imputación del producto a una categoría del catálogo

El sistema SHALL imputar cada producto a una categoría mediante la columna `products.category_id` (FK a `product_categories`, nullable en la base, `ON DELETE RESTRICT`), que SHALL ser la **única representación física** de la categoría del producto. El sistema NOT SHALL mantener una segunda columna con el nombre de la categoría en la tabla de productos: el nombre legible SHALL derivarse del catálogo en la lectura.

La categoría informada SHALL validarse contra la cuenta del producto **en la base de datos**, como punto de paso obligado de todo camino de escritura —incluidos los que no pasan por la capa de aplicación, como la carga masiva—, rechazando con `P0404` la imputación a una categoría de otra cuenta. Esta validación NO SHALL depender de lo que envíe el cliente, y SHALL sobrevivir a cualquier cambio en el mecanismo que la hospede.

#### Scenario: Alta de producto con categoría del catálogo

- **WHEN** se crea un producto informando una categoría activa de la cuenta
- **THEN** el producto queda con ese `category_id`
- **AND** al leerlo, su categoría se lee con el nombre de esa categoría

#### Scenario: Categoría de otra cuenta es rechazada

- **WHEN** se crea o se edita un producto informando un `category_id` que pertenece a otra cuenta
- **THEN** la operación es rechazada con `P0404` y el producto no queda imputado a ella

#### Scenario: La validación de cuenta no depende de la capa de aplicación

- **WHEN** un camino de escritura que no pasa por la capa de aplicación intenta imputar un producto a una categoría de otra cuenta
- **THEN** la escritura es rechazada igualmente con `P0404`

#### Scenario: Renombrar una categoría se refleja en sus productos

- **GIVEN** una categoría "Ropa" con productos imputados
- **WHEN** un `owner` la renombra a "Indumentaria"
- **THEN** los productos conservan su `category_id`
- **AND** su categoría pasa a leerse "Indumentaria", sin que ningún lector cambie

#### Scenario: Renombrar una categoría no reescribe los productos

- **GIVEN** una categoría con productos imputados
- **WHEN** se la renombra
- **THEN** el nombre nuevo se lee en todos sus productos
- **AND** ninguna fila de productos es reescrita para lograrlo

#### Scenario: La categoría no puede quedar desincronizada

- **WHEN** un producto se crea o se edita por cualquier camino de escritura del sistema, incluida la carga masiva
- **THEN** la categoría que se lee es siempre la del `category_id` vigente del producto, porque no existe ninguna otra representación que pueda divergir

### Requirement: La variante hereda la categoría de su producto padre

El sistema SHALL asignar a un producto variante la misma categoría que su producto padre, resolviéndola en el servidor a partir del padre y no del payload del cliente. El formulario NO SHALL pedir la categoría cuando se está creando una variante.

#### Scenario: Alta de variante hereda la categoría

- **GIVEN** un producto padre imputado a "Indumentaria"
- **WHEN** se crea una variante de ese padre
- **THEN** la variante queda con el mismo `category_id` que el padre, sin que se le haya pedido categoría al usuario

#### Scenario: La variante no puede contradecir al padre

- **WHEN** una solicitud crea una variante informando una categoría distinta a la del padre
- **THEN** el sistema aplica la categoría del padre

### Requirement: Gestión del catálogo gateada por rol

El sistema SHALL permitir a cualquier miembro de la cuenta **leer** el catálogo de categorías, y SHALL restringir crear, renombrar, reordenar y desactivar a los roles `owner` y `admin`. La gestión SHALL exponerse a través del backend FastAPI en las tres capas (router → service → repository), con validación Pydantic v2 en el endpoint, guardas de rol en el service y errores en formato RFC 7807 según `api-standards`. El frontend NO SHALL escribir el catálogo directamente contra Supabase.

#### Scenario: Member puede leer pero no escribir

- **GIVEN** un usuario con rol `member`
- **WHEN** lista las categorías de su cuenta
- **THEN** la lectura es permitida
- **AND** **WHEN** intenta crear o renombrar una categoría
- **THEN** la operación es rechazada con 403 en formato RFC 7807, sin tocar la base

#### Scenario: Owner/admin gestiona el catálogo

- **GIVEN** un usuario con rol `owner` o `admin`
- **WHEN** crea, renombra, reordena o desactiva una categoría de su cuenta
- **THEN** la operación es permitida y persiste

#### Scenario: Listar incluyendo inactivas

- **WHEN** la pantalla de gestión pide el catálogo incluyendo inactivas
- **THEN** el backend devuelve también las categorías desactivadas de la cuenta, y sólo las de esa cuenta

### Requirement: La baja de una categoría es desactivación y preserva la imputación histórica

El sistema SHALL tratar la baja de una categoría como desactivación (`is_active = false`) o soft delete (`deleted_at`/`deleted_by`), y NO SHALL borrar físicamente una fila referenciada por productos. Los productos ya imputados SHALL conservar su `category_id` y su nombre de categoría SHALL seguir siendo legible. Una categoría dada de baja NO SHALL aparecer en los selectores de altas nuevas, pero SÍ SHALL seguir apareciendo en los listados y filtros de los productos que la usan.

#### Scenario: Desactivar una categoría en uso

- **GIVEN** la categoría "Salud" con productos ya imputados
- **WHEN** un `owner`/`admin` la desactiva
- **THEN** deja de ofrecerse en el selector de altas nuevas
- **AND** los productos históricos conservan su `category_id` y siguen mostrando "Salud"

#### Scenario: La fila de una categoría en uso no se elimina físicamente

- **WHEN** se intenta eliminar físicamente una categoría referenciada por productos
- **THEN** la operación es rechazada por la integridad referencial

#### Scenario: Reactivar una categoría desactivada

- **GIVEN** una categoría desactivada
- **WHEN** un `owner`/`admin` la reactiva
- **THEN** vuelve a ofrecerse en los selectores, y sus productos nunca dejaron de estar imputados a ella

### Requirement: Superficies del catálogo de categorías

El sistema SHALL exponer el gestor del catálogo de categorías como una pestaña propia de la pantalla de configuración, junto a los demás catálogos de la cuenta (centros de costo y formas de pago), de modo que todos los catálogos se gestionen en un único lugar. El sistema SHALL ofrecer el catálogo de la cuenta —ordenado por `sort_order`, sólo las activas— a través de un **mismo componente selector** en toda superficie que pida elegir una categoría de producto. Ninguna superficie SHALL declarar una lista de opciones propia.

Toda superficie que ofrezca el selector SHALL permitir **crear una categoría nueva en el lugar**, sin abandonar el formulario en curso ni perder lo ya cargado, y SHALL dejar la categoría recién creada seleccionada. La creación inline NO SHALL abrir un diálogo anidado sobre el formulario que ya está en un diálogo.

Las superficies SHALL usar los tokens semánticos y los componentes base del design system, y SHALL ser legibles y operables en escritorio y en móvil, en tema claro y en tema oscuro.

#### Scenario: El gestor vive junto a los demás catálogos de la cuenta

- **WHEN** un usuario abre la pantalla de configuración
- **THEN** encuentra la gestión de categorías de producto como una pestaña propia, junto a las de centros de costo y formas de pago
- **AND** no necesita buscarla en otra pantalla

#### Scenario: El formulario de producto ofrece el catálogo de la cuenta

- **WHEN** el usuario abre el formulario de alta de producto
- **THEN** ve el selector de categoría con las categorías activas de su cuenta, ordenadas por `sort_order`

#### Scenario: El alta inline de producto desde una compra ofrece el mismo catálogo

- **WHEN** el usuario crea un producto desde el formulario de compra
- **THEN** ve el mismo conjunto de categorías, resuelto por el mismo componente selector

#### Scenario: Crear una categoría desde el selector

- **GIVEN** un usuario completando el formulario de producto que no encuentra su categoría
- **WHEN** usa la acción de categoría nueva del selector e informa un nombre
- **THEN** la categoría se crea en su cuenta y queda seleccionada
- **AND** los datos ya cargados del formulario se conservan
- **AND** no se abre un diálogo por encima del diálogo del formulario

#### Scenario: Renombrar se refleja en los selectores

- **GIVEN** un usuario que renombró "Otros" a "Sin clasificar" en el gestor
- **WHEN** abre el formulario de producto
- **THEN** la opción aparece como "Sin clasificar"

#### Scenario: Cuenta sin categorías activas sigue pudiendo dar de alta

- **GIVEN** una cuenta que desactivó todas sus categorías
- **WHEN** el usuario abre el formulario de alta de producto
- **THEN** la pantalla lo advierte y ofrece crear una categoría en el lugar
- **AND** no queda bloqueado sin salida

#### Scenario: Presentación responsive y por tema

- **WHEN** el gestor y el selector se muestran en escritorio o en móvil, en tema claro u oscuro
- **THEN** usan los tokens semánticos del design system y son legibles y operables en las cuatro combinaciones

### Requirement: Categoría por defecto de la cuenta

El sistema SHALL permitir a la cuenta configurar explícitamente **cuál** de sus categorías activas es la categoría por defecto (`accounts.default_product_category_id`), usada para imputar las filas sin categoría de la carga masiva. Fijar o limpiar el default SHALL restringirse a los roles `owner` y `admin`; cualquier miembro SHALL poder leer cuál es el default vigente. Una categoría inexistente, de otra cuenta, desactivada o borrada SHALL rechazarse al intentar fijarla como default, con el error de recurso no encontrado.

Cuando el default configurado deje de estar vivo y activo (se desactivó o se borró) sin que la cuenta haya vuelto a fijar uno nuevo, el sistema NO SHALL fallar: SHALL recaer en la heurística existente ("Otros" si sigue viva y activa; si no, la última categoría activa por `sort_order`). El default configurado, cuando está vivo y activo, SHALL tener prioridad sobre esa heurística.

#### Scenario: Configurar el default de la cuenta

- **GIVEN** un usuario `owner`/`admin` con la categoría activa "Ferretería" en su cuenta
- **WHEN** la fija como categoría por defecto
- **THEN** la cuenta queda con "Ferretería" como default
- **AND** cualquier miembro de la cuenta puede leer que ese es el default vigente

#### Scenario: Limpiar el default vuelve a la heurística

- **GIVEN** una cuenta con un default configurado
- **WHEN** un `owner`/`admin` lo limpia (informando `null`)
- **THEN** la cuenta queda sin default configurado
- **AND** la carga masiva vuelve a usar la heurística existente para las filas sin categoría

#### Scenario: Default de otra cuenta o inexistente es rechazado

- **WHEN** se intenta fijar como default una categoría que no existe o que pertenece a otra cuenta
- **THEN** la operación es rechazada con el error de recurso no encontrado
- **AND** el default de la cuenta no cambia

#### Scenario: Member no puede fijar el default

- **GIVEN** un usuario con rol `member`
- **WHEN** intenta fijar o limpiar el default de su cuenta
- **THEN** la operación es rechazada con 403, sin tocar la base

#### Scenario: La carga masiva usa el default configurado en vez de "Otros"

- **GIVEN** una cuenta con "Ferretería" fijada como default y su catálogo sembrado (incluida "Otros")
- **WHEN** se importa un archivo con filas cuya columna de categoría está vacía
- **THEN** esas filas quedan imputadas a "Ferretería"
- **AND** ninguna queda imputada a "Otros"

#### Scenario: Default desactivado degrada a la heurística sin fallar

- **GIVEN** una cuenta cuyo default configurado apunta a una categoría que luego fue desactivada, sin haber fijado un default nuevo
- **WHEN** se importa un archivo con filas sin categoría
- **THEN** la importación no falla
- **AND** esas filas quedan imputadas según la heurística existente ("Otros" si vive y activa, si no la última activa por `sort_order`)

### Requirement: La carga masiva resuelve la categoría contra el catálogo del tenant y crea las que faltan

El sistema SHALL resolver la columna `Categoría` de la carga masiva contra el catálogo de la cuenta importadora de forma case-insensitive y tolerante a espacios, y SHALL **crear** la categoría cuando no exista, imputando el producto a ella. El sistema NO SHALL reemplazar por una categoría por defecto una categoría informada por el usuario.

La creación SHALL ocurrir en el servidor, dentro de la misma transacción por lote que persiste los productos, de modo que la tenencia se imponga del lado del servidor y no queden categorías creadas por un lote que falló.

La creación automática SHALL estar acotada por dos salvaguardas: el sistema SHALL **anunciar en el paso de revisión, antes de confirmar**, qué categorías se van a crear y cuántas filas usan cada una; y SHALL rechazar la importación con un error explicativo cuando el archivo introduzca más categorías nuevas distintas que el tope admitido, en vez de crearlas. Una fila con errores fatales NO SHALL originar la creación de una categoría.

Una fila sin categoría informada SHALL imputarse a la categoría por defecto de la cuenta, sin crear nada.

#### Scenario: Categoría desconocida se crea e imputa

- **GIVEN** una cuenta cuyo catálogo no tiene "Ferretería"
- **WHEN** se importa un archivo con filas cuya categoría es "Ferretería"
- **THEN** se crea la categoría "Ferretería" en esa cuenta
- **AND** los productos de esas filas quedan imputados a ella
- **AND** ninguno queda imputado a la categoría por defecto

#### Scenario: Categoría existente se reutiliza sin duplicar

- **GIVEN** una cuenta con la categoría "Ropa"
- **WHEN** se importa un archivo con las variantes de escritura "ropa", "Ropa " y "ROPA"
- **THEN** todas las filas se imputan a la categoría "Ropa" existente
- **AND** no se crea ninguna categoría nueva

#### Scenario: Las categorías a crear se anuncian antes de confirmar

- **WHEN** el usuario llega al paso de revisión con un archivo que trae categorías nuevas
- **THEN** la pantalla lista las categorías que se van a crear y cuántas filas usa cada una, antes de que confirme la importación

#### Scenario: Superar el tope detiene la importación

- **WHEN** un archivo introduce más categorías nuevas distintas que el tope admitido
- **THEN** la importación es rechazada con un error que explica el tope y sugiere revisar el mapeo de la columna
- **AND** no se crea ninguna categoría

#### Scenario: Una fila con error no crea su categoría

- **GIVEN** una fila sin nombre de producto y con una categoría nueva
- **WHEN** se importa el archivo
- **THEN** la fila se omite por su error
- **AND** su categoría no se crea

#### Scenario: Fila sin categoría informada

- **WHEN** se importa una fila con la columna de categoría vacía
- **THEN** el producto queda imputado a la categoría por defecto de la cuenta y no se crea ninguna categoría

#### Scenario: El template de ejemplo refleja el catálogo de la cuenta

- **WHEN** un usuario descarga el template de ejemplo de la carga masiva
- **THEN** las filas de ejemplo usan categorías reales de su cuenta
- **AND** la referencia de columnas declara que una categoría inexistente se crea y que un SKU coincidente actualiza el producto existente

### Requirement: Recategorización en lote de productos

El sistema SHALL permitir asignar una categoría a **varios productos de una vez** desde el listado de productos, mediante selección múltiple y una acción de cambio de categoría. La operación SHALL aplicarse de forma atómica y SHALL ser idempotente: repetirla con la misma categoría destino SHALL dejar el mismo estado final sin reescribir filas que ya la tienen.

La categoría destino SHALL validarse contra la cuenta del usuario y contra su estado vivo y activo **antes** de aplicar el cambio; una categoría inexistente, de otra cuenta, borrada o inactiva SHALL rechazarse con el error de recurso no encontrado, con un mensaje que no revele si el identificador existe en otra cuenta. Los identificadores de producto que no pertenezcan a la cuenta NO SHALL producir error ni ser modificados: SHALL quedar simplemente fuera del alcance de la escritura, de modo que la respuesta no revele su existencia.

La operación SHALL informar cuántos productos se solicitaron y cuántos se actualizaron efectivamente, para que la interfaz pueda advertir que algo no se aplicó sin que el servidor explique por qué.

Recategorizar un producto padre SHALL propagar la categoría a **todas sus variantes** en la misma operación, porque el invariante de herencia padre→variante no admite un estado intermedio en el que difieran. Un identificador de variante recibido de forma suelta SHALL resolverse a su producto padre y recategorizar el grupo completo, por la misma razón.

La escritura SHALL filtrar explícitamente por la cuenta del usuario y NO SHALL depender únicamente de la RLS como control de tenencia.

#### Scenario: Recategorizar varios productos a la vez

- **GIVEN** un usuario con tres productos en "Otros"
- **WHEN** los selecciona en el listado y aplica la categoría "Ferretería"
- **THEN** los tres quedan imputados a "Ferretería"
- **AND** la operación informa tres solicitados y tres actualizados

#### Scenario: La operación es idempotente

- **GIVEN** productos que ya están imputados a "Ferretería"
- **WHEN** se vuelve a aplicar "Ferretería" sobre la misma selección
- **THEN** el estado final es el mismo
- **AND** la operación informa que no se actualizó ninguna fila

#### Scenario: Recategorizar un padre propaga a sus variantes

- **GIVEN** un producto padre con tres variantes, todos en "Ropa"
- **WHEN** se recategoriza el padre a "Indumentaria"
- **THEN** el padre y sus tres variantes quedan en "Indumentaria"
- **AND** no queda ninguna variante con una categoría distinta a la de su padre

#### Scenario: Una variante suelta recategoriza su grupo

- **WHEN** la operación recibe el identificador de una variante sin el de su padre
- **THEN** se recategoriza el grupo completo, padre incluido
- **AND** no se produce un estado en el que la variante contradiga al padre

#### Scenario: Categoría destino de otra cuenta es rechazada

- **WHEN** se solicita recategorizar informando una categoría que pertenece a otra cuenta
- **THEN** la operación falla con el error de recurso no encontrado
- **AND** ningún producto es modificado

#### Scenario: Categoría destino inactiva es rechazada

- **WHEN** se solicita recategorizar hacia una categoría desactivada
- **THEN** la operación es rechazada y ningún producto es modificado

#### Scenario: Productos de otra cuenta quedan fuera del alcance

- **GIVEN** una solicitud que mezcla identificadores de productos propios y de otra cuenta
- **WHEN** se aplica la recategorización
- **THEN** sólo se actualizan los productos de la cuenta del usuario
- **AND** los ajenos no se modifican ni provocan un error que revele su existencia

#### Scenario: La acción declara el alcance antes de aplicar

- **WHEN** el usuario tiene productos seleccionados y elige una categoría destino
- **THEN** la pantalla indica cuántos productos va a recategorizar y hacia qué categoría, y pide confirmación antes de aplicar

#### Scenario: La selección no sobrevive a un cambio de contexto

- **GIVEN** un usuario con productos seleccionados
- **WHEN** cambia el criterio de búsqueda del listado
- **THEN** la selección se limpia, de modo que no se aplique sobre un conjunto que ya no está viendo

#### Scenario: La acción en lote reutiliza el selector de categorías

- **WHEN** el usuario elige la categoría destino de la acción en lote
- **THEN** lo hace con el mismo componente selector que el resto de las superficies, alimentado por el catálogo de su cuenta

### Requirement: El nombre legible de la categoría se deriva del catálogo sin excluir productos

El sistema SHALL derivar el nombre de la categoría de un producto resolviéndolo contra `product_categories` por `products.category_id` al momento de la lectura, y esa derivación NOT SHALL excluir ningún producto del resultado por no poder resolver su categoría. Un producto sin categoría imputada, o cuya categoría no sea visible para quien consulta, SHALL seguir apareciendo en el catálogo, en el stock y en las búsquedas por SKU y por código de barras, con su nombre de categoría vacío.

El sistema SHALL exponer esta derivación en el mismo punto de lectura que ya consumen los lectores existentes de la categoría del producto, conservando el nombre de campo, de modo que ningún consumidor de ese dato deba cambiar.

#### Scenario: Un producto sin categoría imputada sigue siendo visible

- **GIVEN** un producto sin `category_id`
- **WHEN** se lista el catálogo de la cuenta
- **THEN** el producto aparece en la lista, con su categoría vacía

#### Scenario: La derivación no filtra el catálogo

- **GIVEN** una cuenta con N productos
- **WHEN** se lee el catálogo por el punto de lectura que deriva la categoría
- **THEN** se obtienen exactamente N filas

#### Scenario: Un lector existente de la categoría no cambia

- **WHEN** un lector que ya consumía el nombre de la categoría del producto vuelve a leerlo tras el retiro de la columna desnormalizada
- **THEN** obtiene el mismo nombre de campo con el nombre vigente de la categoría

### Requirement: Un producto imputado a una categoría dada de baja conserva su nombre legible

El sistema SHALL seguir resolviendo el nombre de la categoría de un producto cuando esa categoría fue dada de baja —desactivada o soft-deleted—, de modo que la imputación histórica siga siendo legible para quien la consulta. La visibilidad de la categoría a efectos de esta derivación NOT SHALL depender de su estado de actividad ni de su borrado lógico, sino únicamente de la pertenencia a la cuenta.

#### Scenario: Categoría desactivada

- **GIVEN** un producto imputado a una categoría que luego se desactiva
- **WHEN** se lee el producto
- **THEN** su categoría se sigue leyendo con el nombre de esa categoría

#### Scenario: Categoría soft-deleted

- **GIVEN** un producto imputado a una categoría que luego se da de baja como soft delete
- **WHEN** se lee el producto
- **THEN** su categoría se sigue leyendo con el nombre de esa categoría

### Requirement: El nombre de la categoría no se acepta como dato de entrada del producto

El sistema NOT SHALL aceptar el nombre de la categoría como campo de entrada al crear o editar un producto: la única forma de imputar la categoría SHALL ser el identificador de la categoría del catálogo. Un nombre de categoría enviado por un cliente SHALL ignorarse sin provocar un error, de modo que un cliente desactualizado siga funcionando contra el servidor nuevo.

Esta regla NOT SHALL aplicar a la carga masiva, donde el nombre de la categoría es el dato que el usuario carga en su archivo y que el sistema resuelve contra el catálogo del tenant.

#### Scenario: Un cliente envía el nombre de la categoría

- **WHEN** una solicitud de alta o edición de producto incluye el nombre de la categoría además del identificador
- **THEN** el nombre se ignora, la solicitud no falla, y la categoría queda determinada por el identificador

#### Scenario: La carga masiva sigue aceptando el nombre

- **WHEN** se importa un archivo con una columna de categoría por nombre
- **THEN** el sistema resuelve ese nombre contra el catálogo de la cuenta como hasta ahora

