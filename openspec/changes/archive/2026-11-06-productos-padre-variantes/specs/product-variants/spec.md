## ADDED Requirements

### Requirement: El alta de producto distingue producto simple de producto con variantes

La pantalla `/productos` (entrada de menú "Productos", grupo Catálogo) SHALL iniciar el alta con el paso "¿Qué querés crear?" y dos opciones accesibles por teclado: **Producto simple** y **Producto con variantes**. Producto simple SHALL abrir el formulario de producto sin selector de padre. Producto con variantes SHALL crear un padre `variant_only` con un formulario que pide **sólo** nombre, categoría y unidad de medida de la familia, y al guardar SHALL continuar con "Agregar la primera variante" con el padre fijo. La acción "Nueva variante" desde la fila de un padre SHALL abrir el formulario de variante con el padre fijo y sin selector de padre. El paso y los formularios SHALL verificarse en desktop y móvil y en tema claro y oscuro.

#### Scenario: Crear un producto con variantes

- **WHEN** el usuario elige "Producto con variantes", completa nombre, categoría y unidad y guarda
- **THEN** se crea un producto `variant_only` con precio `0`, sin costo, sin stock, sin SKU, sin código de barras y sin PLU
- **AND** el diálogo pasa a "Agregar la primera variante" con ese padre fijo

#### Scenario: El formulario del padre no muestra campos que no usa

- **WHEN** el usuario está en el formulario del producto con variantes
- **THEN** no ve stock inicial, stock mínimo, código de barras, código de balanza, SKU, precio ni costo

#### Scenario: Crear un producto simple

- **WHEN** el usuario elige "Producto simple"
- **THEN** ve el formulario completo (precio, costo, stock, SKU, código de barras, código de balanza, categoría, unidad) sin selector de padre

#### Scenario: Nueva variante desde la fila del padre

- **WHEN** el usuario elige "Nueva variante" en la fila de un padre
- **THEN** el formulario de variante abre con ese padre fijo, la categoría y la unidad del padre en sólo lectura, y campos propios de stock, SKU, código de barras, código de balanza, precio y costo

### Requirement: El servidor rechaza en un padre los datos que un padre no lleva

`POST /products` con `stock_control_type = 'variant_only'` SHALL rechazarse con `422`, `code = parent_field_not_allowed` y `field` igual al campo, si informa precio distinto de `0`, costo no nulo, stock distinto de `0`, stock mínimo distinto de `0`, SKU no vacío, código de barras no vacío o un `parent_id` (un padre no es variante de otro). El código de balanza conserva su rechazo propio (`scale_plu_parent`). `PUT /products/{id}` sobre un padre `variant_only` SHALL rechazar con el mismo `422` un campo informado con un valor distinto del vigente y distinto del neutro (`0`, nulo o vacío); informar el valor vigente o el neutro SHALL aceptarse. La edición NO SHALL cambiar `stock_control_type` hacia o desde `variant_only` (`422`, `code = stock_control_type_locked`); informar el mismo tipo SHALL aceptarse. El rechazo SHALL ocurrir antes de escribir cualquier campo.

#### Scenario: Alta de padre con precio

- **WHEN** se crea un producto `variant_only` con precio `1500`
- **THEN** la API responde `422` con `code = parent_field_not_allowed` y `field = price`, y no se crea nada

#### Scenario: Alta de padre con stock inicial

- **WHEN** se crea un producto `variant_only` con stock `10`
- **THEN** la API responde `422` con `field = stock` y no se escribe ningún movimiento de stock

#### Scenario: El formulario anterior sigue pudiendo editar un padre

- **GIVEN** un padre `variant_only` con código de barras legado "7790001"
- **WHEN** una edición cambia el nombre y manda el código de barras "7790001", precio `0` y el mismo `stock_control_type`
- **THEN** el nombre se actualiza y el código de barras se conserva

#### Scenario: Asignarle un código de barras nuevo a un padre se rechaza

- **GIVEN** un padre `variant_only`
- **WHEN** una edición le informa un código de barras distinto del vigente
- **THEN** la API responde `422` con `field = barcode` y nada cambia

#### Scenario: Convertir un producto en padre por la API se rechaza

- **GIVEN** un producto `tracked`
- **WHEN** una edición informa `stock_control_type = 'variant_only'`
- **THEN** la API responde `422` con `code = stock_control_type_locked`

### Requirement: Un padre variant_only no tiene precio ni costo en la base

La base SHALL sostener con el CHECK `products_variant_only_no_price_cost` que toda fila con `stock_control_type = 'variant_only'` tenga `price = 0` y `cost` nulo, para cualquier escritor (API, PostgREST, importador o una función futura). La migración que introduce el CHECK SHALL llevar antes a esa forma a los padres existentes con precio o costo, dejando una fila de `audit_logs` por producto con los valores anteriores, y NO SHALL reescribir ninguna línea de venta, compra ni presupuesto. El precio y el costo NO SHALL heredarse del padre a las variantes: cada variante conserva y usa su propio precio y costo. Si el CHECK rechaza una escritura de la API, la respuesta SHALL ser el mismo `422` `parent_field_not_allowed`.

#### Scenario: Backfill de los padres con precio

- **GIVEN** padres `variant_only` con precio o costo cargado y variantes con precio propio
- **WHEN** se aplica la migración
- **THEN** esos padres quedan con precio `0` y sin costo, cada uno con su fila en `audit_logs`
- **AND** las variantes conservan sus precios y la línea de venta histórica de un padre conserva su precio de línea

#### Scenario: El CHECK frena a un escritor directo

- **WHEN** un `authenticated` intenta por PostgREST poner precio `100` a un padre `variant_only`
- **THEN** la base rechaza la escritura con el CHECK `products_variant_only_no_price_cost`

#### Scenario: La variante no hereda precio

- **GIVEN** un padre `variant_only` y una variante nueva sin precio cargado
- **WHEN** se guarda la variante
- **THEN** la variante queda con su propio precio (el informado o `0`), nunca uno tomado del padre

### Requirement: La variante hereda la unidad de medida de su padre

El alta de una variante SHALL dejar `base_unit_id` nulo para que herede la unidad del padre (`COALESCE(propia, padre)`), ignorando cualquier unidad que mande el cliente. La edición de una variante que informe una unidad SHALL ignorarla sin validarla ni escribirla. El formulario de variante SHALL mostrar la unidad del padre como sólo lectura. La unidad de la familia se corrige en el padre (capability `units-of-measure`).

#### Scenario: Alta de variante con unidad informada

- **GIVEN** un padre en Kilogramo
- **WHEN** se crea una variante informando unidad Unidad
- **THEN** la variante queda con `base_unit_id = NULL` y su unidad efectiva es Kilogramo

#### Scenario: Edición de variante con unidad informada

- **WHEN** una edición de variante informa una unidad
- **THEN** la unidad propia de la variante no cambia

### Requirement: La edición espeja el modo del producto

Al editar, `/productos` SHALL abrir el formulario que corresponde al modo del producto: el de padre para un `variant_only`, el de variante para un producto con padre y el de producto simple para el resto. Un producto `tracked` o `untracked` que tiene variantes (padre armado a mano antes de este cambio) SHALL abrirse con el formulario de producto simple y un aviso de que lo que se vende es cada variante; NO SHALL convertirse automáticamente en `variant_only` ni perder su stock, precio o códigos. El listado SHALL mostrar en la fila de un padre `variant_only` el rango "desde $X" tomado del menor precio de sus variantes vivas, en lugar de su precio `0`.

#### Scenario: Editar un padre variant_only

- **WHEN** el usuario edita un padre `variant_only`
- **THEN** ve el formulario del padre (nombre, categoría, unidad) sin precio, costo, stock, SKU, código de barras ni código de balanza

#### Scenario: Editar un padre armado a mano

- **GIVEN** un producto `tracked` con stock propio y variantes
- **WHEN** el usuario lo edita
- **THEN** ve el formulario de producto simple con el aviso de que tiene variantes, y su stock, precio y códigos se conservan

#### Scenario: Precio del padre en el listado

- **GIVEN** un padre `variant_only` con variantes de $1.200 y $1.500
- **WHEN** se muestra el listado de `/productos`
- **THEN** la fila del padre muestra "desde $1.200"
