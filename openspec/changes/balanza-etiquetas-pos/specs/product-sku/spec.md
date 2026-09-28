## ADDED Requirements

### Requirement: Código de balanza (PLU) opcional y tri-estado en el producto

El sistema SHALL exponer `products.scale_plu` —el número de artículo (PLU) con el que la balanza etiquetadora identifica al producto y que imprime en el código de barras de la etiqueta— como un campo **opcional** del alta y la edición de producto: un entero de 1 a 999.999, `NULL` por defecto. La restricción de rango SHALL vivir en la base de datos (CHECK) y en la validación de la API. La edición SHALL distinguir tres estados por **ausencia o presencia del campo** en el payload, nunca por comparación contra nulo: ausente conserva el valor vigente, con valor lo asigna, en nulo lo desasigna. Un producto padre con variantes (`stock_control_type = 'variant_only'`) NO SHALL admitir código de balanza, porque se vende a través de sus variantes; la regla SHALL vivir en la base de datos (CHECK) además de la API, para que la sostengan también el importador, la conversión de un producto en padre y cualquier escritura directa. El código de balanza SHALL viajar en la respuesta de producto y en `v_products_with_stock` como última columna de la vista.

#### Scenario: Alta de producto con código de balanza

- **WHEN** se crea un producto informando el código de balanza 509
- **THEN** el producto queda persistido con `scale_plu = 509` y la lectura del producto lo devuelve

#### Scenario: Editar un producto sin tocar su código de balanza lo conserva

- **GIVEN** un producto con código de balanza 509
- **WHEN** se edita cambiando el precio, sin incluir el campo de código de balanza en el payload
- **THEN** el producto conserva el código de balanza 509

#### Scenario: Quitar el código de balanza

- **GIVEN** un producto con código de balanza 509
- **WHEN** se edita informando el código de balanza en nulo
- **THEN** el producto queda con `scale_plu = NULL`

#### Scenario: Código de balanza fuera de rango

- **WHEN** se intenta guardar un producto con código de balanza 0 o 1.000.000
- **THEN** la API responde 422 y, si la escritura llegara directo a la base, el CHECK la rechaza

#### Scenario: Un padre con variantes no admite código de balanza

- **WHEN** se intenta asignar un código de balanza a un producto con `stock_control_type = 'variant_only'`
- **THEN** la API responde 422 indicando que el código se asigna a cada variante

#### Scenario: La base sostiene la regla del padre

- **GIVEN** un producto con código de balanza 509
- **WHEN** una escritura directa contra la base lo pasa a `stock_control_type = 'variant_only'`, o asigna un código de balanza a un producto que ya es padre
- **THEN** la escritura se rechaza por el CHECK y el producto no cambia

#### Scenario: El alta persiste el código y el nulo lo borra

- **WHEN** se crea un producto con código de balanza 509 y después se edita informando el código en nulo
- **THEN** la fila de la base tiene `scale_plu = 509` después del alta y `scale_plu = NULL` después de la edición

### Requirement: El código de balanza es único por cuenta, sobre las filas vivas

El sistema SHALL garantizar que un código de balanza identifique como máximo un producto vivo dentro de una cuenta, mediante un índice único parcial sobre `(account_id, scale_plu)` restringido a las filas con código de balanza no nulo y `deleted_at IS NULL`. El alcance SHALL ser la cuenta, igual que el SKU y el código de barras. Todo camino que resuelva un producto por su código de balanza SHALL usar ese mismo alcance.

#### Scenario: Código de balanza duplicado dentro de la cuenta es rechazado

- **GIVEN** una cuenta con un producto vivo de código de balanza 509
- **WHEN** se intenta crear otro producto con código de balanza 509 en la misma cuenta
- **THEN** la operación es rechazada por el índice único y el segundo producto no se persiste

#### Scenario: Dos cuentas pueden usar el mismo código de balanza

- **GIVEN** la cuenta A con un producto de código de balanza 509
- **WHEN** la cuenta B crea un producto con código de balanza 509
- **THEN** ambos coexisten, cada uno en su cuenta

#### Scenario: Se puede reutilizar el código de balanza de un producto borrado

- **GIVEN** un producto de código de balanza 509 que fue soft-deleteado
- **WHEN** se crea un producto nuevo con código de balanza 509 en la misma cuenta
- **THEN** la operación es permitida, porque el índice único sólo alcanza a las filas vivas

### Requirement: El conflicto de código de balanza se comunica como un error legible

El sistema SHALL traducir la violación del índice único de código de balanza a una respuesta 409 con un mensaje que nombre el código en conflicto, en el alta y en la edición de producto. La fuente de verdad del rechazo SHALL ser la restricción de la base de datos y no una comprobación previa. El formulario de producto SHALL mostrar ese mensaje junto al campo "Código de balanza (PLU)".

#### Scenario: El formulario informa el conflicto

- **WHEN** el usuario intenta guardar un producto con un código de balanza que ya pertenece a otro producto vivo de su cuenta
- **THEN** la API responde 409 y la pantalla muestra que ese código de balanza ya lo usa otro producto

#### Scenario: El rechazo se sostiene aunque se evada la comprobación previa

- **WHEN** una solicitud llega directamente a la API con un código de balanza en conflicto
- **THEN** la escritura es rechazada por la restricción de la base de datos y el producto no se persiste

### Requirement: El código de balanza es criterio de búsqueda exacta del listado de productos

El sistema SHALL incluir el código de balanza entre los criterios de la búsqueda del listado de productos, con coincidencia **exacta** del número (no por prefijo ni por contenido), junto a los criterios vigentes, con un único predicado para productos sueltos, padres y variantes. El buscador de productos compartido (POS, formulario de venta y formulario de compra) SHALL encontrar también un producto por su código de balanza, con la misma coincidencia exacta del número (no por contenido).

#### Scenario: Buscar un producto por su código de balanza

- **GIVEN** un producto "Tomate" con código de balanza 509
- **WHEN** el usuario escribe `509` en la búsqueda del listado de productos
- **THEN** el listado muestra "Tomate"

#### Scenario: La búsqueda por código de balanza es exacta

- **GIVEN** un producto con código de balanza 509 cuyo nombre, SKU y código de barras no contienen `50`
- **WHEN** el usuario escribe `50`
- **THEN** ese producto no aparece por su código de balanza
