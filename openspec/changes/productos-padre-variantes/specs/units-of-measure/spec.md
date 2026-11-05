## MODIFIED Requirements

### Requirement: La unidad base efectiva de un producto no cambia debajo de su stock

*(D11 / decisión D-C, firmada por el PO el 2026-11-05 en `productos-padre-variantes`.)* La base de datos SHALL rechazar, para cualquier escritor (API, PostgREST, el importador o una función futura), todo cambio que altere la unidad base **efectiva** de un producto (la propia o, para una variante que no declara una, la de su padre) si el producto afectado tiene stock distinto de `0` en alguna sucursal o algún movimiento de stock: `P0409` con token `base_unit_locked`. Esto incluye cambiar o quitar `base_unit_id`, re-parentar o desenganchar una variante que hereda la unidad, y borrar físicamente el padre de una variante que hereda y sobrevive al borrado (la acción `ON DELETE SET NULL` la desengancharía); borrar el padre junto con sus variantes en la misma sentencia no se traba. Asignar una unidad base a un producto que no tenía unidad efectiva SHALL permitirse aunque tenga stock, **salvo** que el producto (o las variantes que la heredarían) tenga stock o movimientos **y** alguna línea de venta, compra, orden o presupuesto grabada con una unidad explícita distinta de la que se asigna (cuarta revisión): en ese caso, `P0409` `base_unit_locked`. Las líneas sin unidad no declaran ninguna y no traban la asignación. En el importador de productos, un cambio rechazado vuelve como error de esa fila y el resto del lote sigue. La unidad base SHALL ser del sistema o de la cuenta del producto (`P0404`, `base_unit_not_found`). Este bloqueo es el comportamiento por defecto de **todo** camino de escritura; la única excepción es la corrección explícita de la unidad de una familia (`rpc_relabel_product_unit`, requirement "La unidad de una familia de productos se corrige en el padre sin convertir cantidades"), que la base reconoce sólo para las filas de ese grupo, dentro de la transacción de esa función, y nunca para un re-parent ni un cambio de cuenta.

La carrera entre un cambio de unidad base y una venta o compra concurrente del mismo producto SHALL resolverse sin escribir stock en la unidad vieja: las funciones que escriben stock SHALL normalizar la cantidad de cada línea que **aplican** recién después de tomar la fila del producto con bloqueo, y el guard de la unidad base SHALL tomar las variantes que heredan con bloqueo y, al re-parentar, el padre nuevo con bloqueo compartido (un cambio concurrente de la unidad base de ese padre espera y decide sobre lo commiteado). Queda exceptuada la reversa de una edición: devuelve el delta guardado del movimiento de la fila vieja y sólo si esa fila no tiene movimiento normaliza con la unidad de la línea vieja sin bloquear el producto — la unidad vieja es la correcta para revertir y un producto con movimientos no puede cambiar de unidad base.

#### Scenario: Cambiar la unidad base de un producto con stock se rechaza

- **GIVEN** un producto con unidad base Kilogramo, stock `10` y movimientos
- **WHEN** se intenta cambiar su unidad base a Gramo, o quitarla, por la API o con un `PATCH` de PostgREST como `authenticated`
- **THEN** la operación falla con `P0409` y token `base_unit_locked`, y la unidad base sigue siendo Kilogramo

#### Scenario: Asignar la unidad a un producto que no tenía se permite

- **GIVEN** un producto sin unidad base con stock `10`, cuyas líneas no tienen unidad o están en Kilogramo
- **WHEN** se le asigna Kilogramo
- **THEN** el cambio se acepta y el stock pasa a leerse en kilogramos

#### Scenario: Asignar sobre stock e historia en otra unidad se rechaza

- **GIVEN** un producto sin unidad base con stock y ventas grabadas en Kilogramo, y otro con stock y ventas grabadas en Unidad
- **WHEN** se le asigna Gramo al primero, o Kilogramo al segundo, por la API o por PostgREST como `authenticated`, directamente o asignándola al padre del que la heredaría o re-parentándolo bajo un padre con esa unidad
- **THEN** la operación falla con `P0409` y token `base_unit_locked`, y el producto sigue sin unidad base
- **AND** al segundo sí se le puede asignar Unidad

#### Scenario: Borrar el padre de una variante que hereda con stock se rechaza

- **GIVEN** un padre con unidad base Kilogramo y una variante sin unidad propia con stock `5`
- **WHEN** se borra físicamente el padre por PostgREST como `authenticated`
- **THEN** el borrado falla con `P0409` y token `base_unit_locked`, y la variante conserva el padre
- **AND** borrar el padre junto con la variante en la misma sentencia se permite, igual que borrar un padre sin unidad base

#### Scenario: El importador informa el re-parent rechazado como error de fila

- **GIVEN** una variante con stock que hereda Kilogramo
- **WHEN** una fila del CSV de productos la re-parenta a un padre en Unidad
- **THEN** esa fila vuelve como error con `base_unit_locked` y su número de fila, nada cambia y el resto del lote sigue

#### Scenario: Re-parentar una variante que hereda con stock se rechaza

- **GIVEN** una variante sin unidad base propia, hija de un padre en Kilogramo, con stock `5`
- **WHEN** se la re-parenta a un padre en Unidad, o se la desengancha (`parent_id = NULL`)
- **THEN** la operación falla con `P0409` y token `base_unit_locked`
- **AND** re-parentarla a otro padre en Kilogramo se permite, igual que re-parentar una variante con unidad base propia

#### Scenario: Cambio de unidad base concurrente con una compra

- **GIVEN** un producto con unidad base Kilogramo, sin stock ni movimientos
- **WHEN** una sesión cambia su unidad base a Unidad y, antes de que commitee, otra sesión registra una compra de `2000` con unidad Gramo
- **THEN** la compra espera la fila del producto y termina con `P0400` (`unit_type_mismatch`), sin stock, movimiento ni fila de compra
- **AND** en el orden inverso (compra abierta, cambio después) el cambio de unidad espera y termina con `P0409`

#### Scenario: Re-parent concurrente con un cambio de la unidad base del padre nuevo

- **GIVEN** una variante con stock `5` que hereda Kilogramo, y otro padre en Kilogramo
- **WHEN** una sesión la re-parenta a ese padre y, antes de que commitee, otra sesión le cambia al padre nuevo la unidad base a Unidad (o en el orden inverso)
- **THEN** la sesión que llega segunda espera y termina con `P0409`: la variante nunca queda con 5 kg bajo un padre en Unidad

#### Scenario: El camino ordinario sigue bloqueado aunque exista el relabel

- **GIVEN** un padre sin unidad cuya variante tiene stock `10` y movimientos
- **WHEN** se intenta asignarle o cambiarle la unidad base con `PUT /products/{id}` o con un `PATCH` de PostgREST como `authenticated`
- **THEN** la operación sigue fallando con `P0409` y token `base_unit_locked` cuando la regla de arriba lo exige
- **AND** sólo `rpc_relabel_product_unit` puede hacer esa corrección

## ADDED Requirements

### Requirement: La unidad de una familia de productos se corrige en el padre sin convertir cantidades

El sistema SHALL permitir corregir la unidad base de un producto (o de la familia de un padre con variantes) aunque el grupo tenga stock o movimientos, mediante `rpc_relabel_product_unit(p_product_id, p_new_unit_id, p_dry_run)` (`SECURITY DEFINER`), expuesta como `POST /products/{id}/relabel-unit`. La corrección SHALL ser un **cambio de rótulo**: ninguna cantidad de `branch_stock`, `stock_movements` ni de ninguna línea se convierte ni se reescribe. La función SHALL resolver el grupo desde la raíz (`COALESCE(parent_id, id)`), escribir la unidad nueva en la raíz y dejar a **todas** las variantes vivas heredándola (`base_unit_id = NULL`, incluidas las que tenían una unidad propia), tomando con bloqueo la raíz y luego las variantes por orden de id.

La función SHALL exigir que el usuario pueda escribir en la cuenta del producto (`P0401`) y que tenga rol de dueño o administrador (`P0403`, `insufficient_role`); un producto inexistente, borrado o de otra cuenta SHALL responder `P0404` sin revelar si existe. La unidad nueva SHALL ser del sistema o de la cuenta (`P0404`, `base_unit_not_found`) y SHALL ser obligatoria (`P0400`). Si alguna línea de venta, compra, orden, presupuesto o remito del grupo se grabó con una unidad explícita distinta de la nueva, la corrección SHALL rechazarse con `P0409` y token `unit_relabel_conflict` sin escribir nada. Una corrección sin efecto (la familia ya tiene esa unidad) SHALL devolver `changed = false` sin escribir ni auditar. Toda corrección aplicada SHALL dejar una fila en `audit_logs` (`product.unit_relabel`) con la unidad anterior y la nueva, las variantes afectadas, los productos con stock y la cantidad de movimientos, y el usuario.

Con `p_dry_run = true` la función SHALL devolver el mismo resultado (variantes, variantes con unidad propia, productos con stock, movimientos, unidad en conflicto) sin escribir, sin auditar y sin lanzar por conflicto, para que la confirmación muestre el impacto.

#### Scenario: Corregir la unidad de un padre con historia

- **GIVEN** un padre sin unidad con tres variantes, una con stock `12` y movimientos, ninguna línea con unidad explícita
- **WHEN** un dueño corrige la unidad de la familia a Kilogramo
- **THEN** el padre queda con unidad base Kilogramo, las tres variantes la heredan y el stock de la primera se lee `12 kg`
- **AND** ninguna cantidad de stock, movimiento ni línea cambió y hay una fila `product.unit_relabel` en `audit_logs`

#### Scenario: Las variantes con unidad propia pasan a heredar

- **GIVEN** un padre en Unidad con una variante que tiene unidad propia Kilogramo
- **WHEN** se corrige la unidad de la familia a Unidad
- **THEN** la variante queda con `base_unit_id = NULL` y hereda Unidad

#### Scenario: Una línea grabada en otra unidad impide la corrección

- **GIVEN** una familia con una venta cuya línea se grabó con unidad Kilogramo
- **WHEN** se intenta corregir la unidad de la familia a Unidad
- **THEN** la operación falla con `P0409` y token `unit_relabel_conflict`, y nada cambia
- **AND** corregirla a Kilogramo se permite

#### Scenario: La vista previa no escribe

- **WHEN** se llama a la corrección con `dry_run = true`
- **THEN** devuelve variantes, productos con stock, movimientos y la unidad en conflicto si la hay, sin cambiar ninguna fila ni escribir `audit_logs`

#### Scenario: Sólo dueño o administrador

- **GIVEN** un miembro con rol de stock o de cajero
- **WHEN** intenta corregir la unidad de una familia por la API o llamando la función
- **THEN** recibe `403` (`P0403`, `insufficient_role`) y nada cambia

#### Scenario: Producto de otra cuenta

- **WHEN** un usuario intenta corregir la unidad de un producto de otra cuenta
- **THEN** recibe `404` y el producto ajeno no cambia

#### Scenario: Corrección concurrente con una compra

- **GIVEN** una familia sin unidad con una variante con stock
- **WHEN** una sesión corrige la unidad a Unidad y, antes de que commitee, otra registra una compra de esa variante con unidad Kilogramo (o en el orden inverso)
- **THEN** la que llega segunda espera la fila del producto y decide sobre lo commiteado: la compra termina rechazada por unidad incompatible, o la corrección termina con `unit_relabel_conflict`
- **AND** nunca queda stock grabado en una unidad distinta de la base efectiva

#### Scenario: La salida del guard no se puede usar fuera de la corrección

- **WHEN** un `authenticated` intenta, por PostgREST, cambiar la unidad base de un producto con stock o re-parentar una variante que hereda
- **THEN** sigue recibiendo `P0409` `base_unit_locked`

### Requirement: La confirmación de la corrección de unidad muestra el impacto

El formulario de edición del padre (o de un producto simple) SHALL ofrecer, a dueño y administrador, la acción "Corregir unidad" cuando el grupo tiene stock o movimientos, en lugar del selector de unidad libre. La acción SHALL abrir un diálogo que, antes de confirmar, muestre la vista previa del servidor: variantes afectadas, productos con stock, movimientos y un ejemplo con una cantidad real que explique que no se convierte ninguna cantidad (por ejemplo "12 u pasarán a leerse 12 kg"). Si la vista previa informa una unidad en conflicto, el diálogo SHALL explicarlo y no SHALL permitir confirmar. Otros roles NO SHALL ver la acción. El diálogo SHALL funcionar en desktop y móvil y en tema claro y oscuro.

#### Scenario: Confirmación con impacto

- **GIVEN** un dueño editando un padre cuyas variantes tienen stock
- **WHEN** elige "Corregir unidad" y Kilogramo
- **THEN** ve cuántas variantes, productos con stock y movimientos cambian de rótulo y un ejemplo con una cantidad real antes de confirmar

#### Scenario: Conflicto explicado

- **WHEN** la vista previa informa una línea grabada en otra unidad
- **THEN** el diálogo explica qué unidad está en conflicto y el botón de confirmar queda deshabilitado

#### Scenario: Rol sin permiso

- **WHEN** un cajero edita un producto con historia
- **THEN** no ve la acción "Corregir unidad"
