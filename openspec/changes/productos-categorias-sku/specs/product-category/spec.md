## ADDED Requirements

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

El sistema SHALL imputar cada producto a una categoría mediante la columna `products.category_id` (FK a `product_categories`, nullable en la base, `ON DELETE RESTRICT`), que SHALL ser la fuente de verdad de la categoría del producto. La categoría informada SHALL validarse en el servidor contra la cuenta del producto: una categoría de otra cuenta SHALL rechazarse, y esa validación NO SHALL depender de lo que envíe el cliente.

La columna `products.category` (TEXT) SHALL conservarse como **espejo desnormalizado** del nombre de la categoría referenciada, mantenido por el sistema y nunca escrito a mano por un camino de aplicación, de modo que todo lector existente de esa columna siga obteniendo el nombre vigente sin modificarse. El espejo SHALL actualizarse tanto cuando cambia la categoría de un producto como cuando se renombra una categoría del catálogo.

#### Scenario: Alta de producto con categoría del catálogo

- **WHEN** se crea un producto informando una categoría activa de la cuenta
- **THEN** el producto queda con ese `category_id` y con `products.category` igual al nombre de esa categoría

#### Scenario: Categoría de otra cuenta es rechazada

- **WHEN** se crea o se edita un producto informando un `category_id` que pertenece a otra cuenta
- **THEN** la operación es rechazada y el producto no queda imputado a ella

#### Scenario: Renombrar una categoría se refleja en sus productos

- **GIVEN** una categoría "Ropa" con productos imputados
- **WHEN** un `owner` la renombra a "Indumentaria"
- **THEN** los productos conservan su `category_id`
- **AND** su `products.category` pasa a decir "Indumentaria", sin que ningún lector de esa columna cambie

#### Scenario: El espejo no puede desincronizarse por el camino de escritura

- **WHEN** un producto se crea o se edita por cualquier camino de escritura del sistema, incluida la carga masiva
- **THEN** `products.category` queda con el nombre de la categoría referenciada por `category_id`

#### Scenario: Ningún producto queda sin categoría por la migración

- **WHEN** se aplica el backfill sobre los productos existentes
- **THEN** cada producto queda con el `category_id` de la categoría de su propia cuenta cuyo nombre coincide con su categoría de texto
- **AND** ningún producto pierde el valor de `products.category`

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

El sistema SHALL exponer un gestor del catálogo de categorías alcanzable desde la pantalla de productos, sin requerir navegación nueva ni una entrada de menú adicional, y SHALL ofrecer el catálogo de la cuenta —ordenado por `sort_order`, sólo las activas— a través de un **mismo componente selector** en toda superficie que pida elegir una categoría de producto. Ninguna superficie SHALL declarar una lista de opciones propia.

Toda superficie que ofrezca el selector SHALL permitir **crear una categoría nueva en el lugar**, sin abandonar el formulario en curso ni perder lo ya cargado, y SHALL dejar la categoría recién creada seleccionada. La creación inline NO SHALL abrir un diálogo anidado sobre el formulario que ya está en un diálogo.

Las superficies SHALL usar los tokens semánticos y los componentes base del design system, y SHALL ser legibles y operables en escritorio y en móvil, en tema claro y en tema oscuro.

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
