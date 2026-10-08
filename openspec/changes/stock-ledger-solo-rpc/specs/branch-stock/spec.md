## MODIFIED Requirements

### Requirement: Ajuste manual de stock por sucursal

El sistema SHALL permitir a los miembros con un rol activo `owner`, `admin` o `stock` ajustar manualmente la cantidad de stock de un producto en una sucursal mediante `rpc_adjust_branch_stock(p_product_id, p_branch_id, p_new_quantity, p_reason)`, fijando la cantidad absoluta de esa sucursal y generando un `stock_movements` de tipo `adjustment` por la diferencia. La RPC SHALL ser un envoltorio público del núcleo único de ajuste manual (ver "Núcleo único de ajuste manual de stock"): hereda de él el rol exigido en la base, el motivo obligatorio, la tenencia por `products.account_id` y el sello de cuenta, sucursal y autor del movimiento. El motivo SHALL persistirse en `stock_movements.reason` (no en `notes`). El producto SHALL pertenecer a la cuenta del usuario y la sucursal SHALL pertenecer a esa misma cuenta y no estar cerrada.

La spec anterior decía "owner y admin" mientras el código dejaba pasar a todo rol con `is_writer` (7 de 8): la exigencia de rol SHALL vivir en la base, no sólo en el formulario del cliente.

#### Scenario: Owner ajusta stock de una sucursal

- **GIVEN** un producto con 10 unidades en `branch_stock` de la sucursal A
- **WHEN** el owner llama a `rpc_adjust_branch_stock(product_id, branch_id=A, new_quantity=15, reason="conteo físico")`
- **THEN** `branch_stock.quantity` pasa a 15, se inserta un `stock_movements` con `type='adjustment'`, `quantity_delta=5`, `reason='conteo físico'`, `account_id` de la cuenta, `branch_id=A` y `performed_by` = el owner

#### Scenario: El rol de depósito puede ajustar stock de una sucursal

- **GIVEN** un miembro cuyo único rol activo es `stock`
- **WHEN** llama a `rpc_adjust_branch_stock` con un motivo no vacío sobre un producto y una sucursal de su cuenta
- **THEN** el ajuste se aplica y deja su movimiento

#### Scenario: Un rol que escribe pero no ajusta stock es rechazado

- **GIVEN** un miembro cuyos roles activos son `seller`, `cashier`, `purchases` o `accountant`
- **WHEN** llama a `rpc_adjust_branch_stock`
- **THEN** la RPC retorna `P0403 insufficient_role` y no cambia `branch_stock` ni inserta movimiento

#### Scenario: Un viewer no puede ajustar stock de sucursal

- **GIVEN** un miembro cuyo único rol activo es `viewer`
- **WHEN** llama a `rpc_adjust_branch_stock`
- **THEN** la RPC retorna `P0401` y no cambia nada

#### Scenario: Ajuste sin motivo es rechazado

- **WHEN** un owner llama a `rpc_adjust_branch_stock` con `p_reason` nulo, vacío o sólo espacios
- **THEN** la RPC retorna `P0400 stock_adjustment_reason_required` y no cambia nada

#### Scenario: Producto de otra cuenta es rechazado

- **GIVEN** un producto que pertenece a otra cuenta
- **WHEN** un owner llama a `rpc_adjust_branch_stock` con ese producto y una sucursal propia
- **THEN** la RPC retorna `P0404` y no crea ninguna fila de `branch_stock` para ese producto

#### Scenario: Ajuste a cero genera stock_movements con delta negativo

- **GIVEN** un producto con 8 unidades en `branch_stock` de la sucursal B
- **WHEN** el owner ajusta a `new_quantity = 0` con motivo
- **THEN** se inserta `stock_movements` con `quantity_delta = -8` y `branch_stock.quantity = 0`

## ADDED Requirements

### Requirement: Núcleo único de ajuste manual de stock

El sistema SHALL tener **un solo núcleo** de ajuste manual de stock, interno (sin `EXECUTE` para `anon` ni `authenticated`), y SHALL ser el único camino por el que un usuario cambia el saldo de un producto a mano. Las RPCs públicas `rpc_stock_adjustment` (modal y CSV de `/stock`), `rpc_adjust_branch_stock` (inventario por sucursal) y `rpc_apply_product_stock_delta` (stock inicial del alta de producto) SHALL ser envoltorios de ese núcleo que conservan su firma y la forma de su respuesta.

El núcleo SHALL, en este orden y antes de escribir nada:

1. resolver la **tenencia por `products.account_id`**: el producto SHALL pertenecer a una cuenta del usuario (`current_account_ids()`); si no, `P0404` sin revelar si existe. La tenencia por `products.user_id` SHALL dejar de usarse;
2. exigir el **rol en la base**: `is_account_writer` de esa cuenta (`P0401`) y al menos un rol activo en `{owner, admin, stock}` (`P0403 insufficient_role`);
3. exigir un **motivo no vacío** tras recortar espacios (`P0400 stock_adjustment_reason_required`);
4. aceptar sólo los tipos de ajuste manual `adjustment`, `physical_count`, `loss`, `damage` y `expiry` (`P0400 stock_adjustment_type_invalid`); `loss`, `damage` y `expiry` SHALL sólo restar;
5. rechazar el ajuste de un producto padre `variant_only` o `untracked` (RN-20);
6. rechazar un resultado negativo en la sucursal afectada (`P0409`).

Todo ajuste aceptado SHALL dejar **exactamente un** movimiento con `account_id`, `branch_id`, `user_id`, `performed_by`, `reason` y `quantity_after = quantity_before + quantity_delta` expresados sobre la **sucursal** afectada. Un `CHECK` sobre `stock_movements` SHALL rechazar, por cualquier camino, una fila de tipo de ajuste manual sin motivo; las filas históricas sin motivo SHALL conservarse sin reescribir.

Los parámetros internos de `rpc_apply_product_stock_delta` —`p_log_movement = false` (cambiar el saldo sin movimiento) y `p_allow_negative = true` (piso en cero)— SHALL NOT ser alcanzables desde `authenticated`: el envoltorio SHALL rechazarlos con `P0400`.

#### Scenario: Los tres envoltorios exigen el mismo rol

- **GIVEN** un miembro cuyo único rol activo es `seller`
- **WHEN** llama a `rpc_stock_adjustment`, a `rpc_adjust_branch_stock` o a `rpc_apply_product_stock_delta` sobre un producto de su cuenta, con motivo
- **THEN** las tres retornan `P0403 insufficient_role` y ninguna cambia `branch_stock` ni inserta movimiento

#### Scenario: Los tres envoltorios exigen motivo

- **GIVEN** un owner
- **WHEN** llama a cualquiera de los tres envoltorios con motivo nulo o en blanco
- **THEN** los tres retornan `P0400 stock_adjustment_reason_required` y ninguno escribe

#### Scenario: El modal de /stock sella cuenta, sucursal y autor

- **GIVEN** un miembro con rol `stock` y un producto de su cuenta
- **WHEN** registra una pérdida de 2 unidades con motivo `"rotura en depósito"` vía `rpc_stock_adjustment`
- **THEN** se inserta un movimiento `type='loss'`, `quantity_delta=-2`, con `account_id` de la cuenta, `branch_id` de la sucursal afectada, `performed_by` = el miembro y el motivo persistido, visible en el historial bajo RLS

#### Scenario: Un miembro que no creó el producto puede ajustarlo

- **GIVEN** una cuenta con dos miembros, y un producto creado por el primero
- **WHEN** el segundo, con rol `admin`, lo ajusta con motivo
- **THEN** el ajuste se aplica (la tenencia es por cuenta, no por `products.user_id`)

#### Scenario: Cambiar el saldo sin movimiento ya no es alcanzable

- **WHEN** un owner llama a `rpc_apply_product_stock_delta(..., p_log_movement => false)` o con `p_allow_negative => true`
- **THEN** la RPC retorna `P0400` y no cambia el saldo

#### Scenario: El stock inicial del alta de producto sigue funcionando

- **GIVEN** un owner que crea un producto con 12 unidades de stock inicial
- **WHEN** el backend llama a `rpc_apply_product_stock_delta(producto, 12, NULL, 'Stock inicial', true, false)`
- **THEN** el saldo de la sucursal operativa por defecto queda en 12 y se inserta un movimiento `adjustment` con motivo `"Stock inicial"`, cuenta, sucursal y autor

#### Scenario: Un padre variant_only no se ajusta por ningún camino

- **WHEN** un owner intenta ajustar un producto padre `variant_only` por cualquiera de los tres envoltorios
- **THEN** la operación es rechazada y no se crea saldo para el padre

#### Scenario: El CHECK de motivo rechaza filas sin motivo aunque vengan de una función interna

- **WHEN** cualquier escritor, incluso uno `SECURITY DEFINER`, inserta un movimiento `adjustment`, `physical_count`, `loss`, `damage` o `expiry` con `reason` nulo o en blanco
- **THEN** la inserción falla por el `CHECK` y no queda ninguna fila

#### Scenario: Los movimientos históricos sin motivo no se reescriben

- **WHEN** se aplica la migración del `CHECK`
- **THEN** las filas de ajuste manual anteriores sin motivo conservan su contenido y la migración no falla por ellas

### Requirement: La superficie de ajuste manual se ofrece sólo a quien puede ajustar y exige el motivo

El sistema SHALL mostrar las acciones de ajuste manual de stock únicamente a los miembros con un rol activo en `CAN_STOCK` (`owner`, `admin`, `stock`), decidido sobre el **conjunto** de roles activos (`useOrgRole().roles`) con el espejo `CAN_STOCK` de `frontend/lib/rbac-capabilities.ts`, atado por test a `backend/core/rbac.py` y al conjunto que exige la base. Mientras el conjunto de roles no resolvió, la decisión SHALL ser optimista (la barrera real es la base). Aplica a: el botón "Ajustar stock" y la acción por fila de `/stock`, el botón "Importar ajuste" de `/stock`, la acción de ajuste de `/sucursales/[id]/stock` y el acceso al ajuste desde el formulario de producto. La transferencia entre sucursales conserva su propia condición de visibilidad.

Todo formulario de ajuste SHALL exigir un motivo no vacío antes de enviar: el modal de `/stock`, el diálogo de ajuste por sucursal y el importador CSV de ajustes, en el que la columna "Motivo" SHALL ser obligatoria (encabezado ausente o celda vacía = error bloqueante de esa fila). Los rechazos del servidor por rol, motivo, tipo o stock insuficiente SHALL mostrarse en castellano accionable a través del mapa canónico `lib/operation-errors.ts`, sin exponer códigos ni identificadores.

La superficie SHALL verificarse en desktop y mobile y en tema claro y oscuro.

#### Scenario: Un vendedor no ve las acciones de ajuste

- **GIVEN** un miembro cuyo único rol activo es `seller`
- **WHEN** abre `/stock`
- **THEN** no ve "Ajustar stock", la acción de ajuste por fila ni "Importar ajuste", y sigue viendo el listado

#### Scenario: El rol de depósito ve y usa el ajuste

- **GIVEN** un miembro con rol `stock`
- **WHEN** abre `/stock`
- **THEN** ve las acciones de ajuste y puede registrar un ajuste con motivo

#### Scenario: El modal no envía sin motivo

- **WHEN** un usuario con permiso completa producto y cantidad en el modal de `/stock` y deja el motivo vacío o en blanco
- **THEN** el modal muestra que el motivo es obligatorio y no llama al servidor

#### Scenario: El CSV sin motivo bloquea la fila

- **WHEN** un usuario importa un CSV de ajustes con una fila sin motivo
- **THEN** esa fila queda marcada como error bloqueante con el texto "Falta el motivo" y no se aplica

#### Scenario: Un rechazo de rol del servidor se explica en castellano

- **GIVEN** un miembro con un rol que no ajusta stock y una pestaña abierta antes de perder el rol
- **WHEN** intenta un ajuste y la base responde `insufficient_role`
- **THEN** ve un mensaje que explica que su rol no permite ajustar stock a mano y quién puede asignarle el rol, sin el código crudo

### Requirement: El formulario de producto no edita el stock

El sistema SHALL tratar el formulario de producto así: en el **alta**, el campo "Stock inicial" SHALL ofrecerse sólo a quien puede ajustar stock (`CAN_STOCK`) y sólo para productos con control de stock propio (nunca para un padre `variant_only`); su valor viaja como stock inicial y el backend lo registra con el motivo fijo "Stock inicial" sin pedir otro. En la **edición**, el formulario SHALL mostrar el stock actual en sólo lectura y, a quien puede ajustar, una acción "Ajustar stock" que abre el modal de ajuste existente con el producto preseleccionado; la edición SHALL NOT enviar `stock`.

`POST /products` con stock inicial distinto de cero SHALL exigir `CAN_STOCK` **antes** de escribir nada (403 RFC 7807, el producto no se crea). `PUT /products/{id}` SHALL NOT ajustar stock: si el cuerpo trae un `stock` distinto del saldo actual, SHALL responder `422` con código `stock_adjust_required` sin escribir; si trae el mismo valor, SHALL ignorarlo.

#### Scenario: El alta con stock inicial queda registrada con su motivo fijo

- **GIVEN** un owner
- **WHEN** crea un producto con stock inicial 5
- **THEN** el producto se crea, el saldo queda en 5 y el movimiento lleva motivo `"Stock inicial"`

#### Scenario: Un vendedor no carga stock inicial

- **GIVEN** un miembro con rol `seller`
- **WHEN** abre el alta de producto
- **THEN** no ve el campo "Stock inicial"; y si un cliente envía igual `stock = 5` a `POST /products`, la respuesta es 403 y el producto no se crea

#### Scenario: La edición deriva al modal de ajuste

- **GIVEN** un owner que edita un producto con 10 unidades
- **WHEN** abre el formulario de edición
- **THEN** ve "Stock actual: 10" en sólo lectura y una acción "Ajustar stock" que abre el modal con ese producto preseleccionado, que exige motivo

#### Scenario: Guardar la edición no toca el stock

- **GIVEN** un producto con 10 unidades y un formulario de edición abierto, y una venta posterior que deja el saldo en 8
- **WHEN** el usuario cambia el precio y guarda
- **THEN** el saldo sigue en 8 y no se inserta ningún movimiento de ajuste

#### Scenario: Un cliente viejo que envía otro stock por PUT es rechazado

- **WHEN** un cliente envía `PUT /products/{id}` con `stock` distinto del saldo actual
- **THEN** la respuesta es `422` con código `stock_adjust_required`, ningún campo del producto se escribe y el saldo no cambia
