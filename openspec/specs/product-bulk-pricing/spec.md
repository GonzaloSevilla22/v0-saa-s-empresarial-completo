# product-bulk-pricing Specification

## Purpose
TBD - created by archiving change productos-padre-variantes. Update Purpose after archive.
## Requirements
### Requirement: Modificación de precios en lote

El sistema SHALL permitir modificar el precio de varios productos a la vez mediante `rpc_bulk_adjust_prices(p_product_ids, p_mode, p_direction, p_value, p_dry_run)` (`SECURITY DEFINER`), expuesta como `PATCH /products/bulk-price`. El modo SHALL ser porcentaje (`percent`) o importe fijo (`amount`), la dirección aumento (`increase`) o baja (`decrease`) y el valor mayor que `0`; el porcentaje efectivo SHALL estar entre −90 y +1000. Cada llamada SHALL admitir entre 1 y 500 ids; fuera de esos límites, o con un modo, dirección o valor inválidos, SHALL rechazarse con `P0400` (`422` en la API) sin escribir. Sólo se modifica el **precio**: el costo nunca cambia por esta vía.

Los ids SHALL filtrarse por la cuenta activa del usuario y por filas vivas: un id de otra cuenta o borrado NO SHALL producir error ni revelar existencia. Cada id SHALL normalizarse a su raíz y expandirse a la raíz más sus variantes vivas; las filas `variant_only` SHALL excluirse (no tienen precio) y contarse como padres omitidos. El precio nuevo SHALL ser, con porcentaje, el precio actual por `1 ± valor/100` redondeado; con importe, el precio actual `±` el valor redondeado y acotado a `0` como mínimo. Una fila cuyo precio no cambia NO SHALL escribirse. La escritura SHALL ser un único `UPDATE` atómico por llamada.

La función SHALL devolver cuántos ids se pidieron, cuántos productos eran elegibles, cuántos cambian, cuántos quedan igual, cuántos padres se omitieron, cuántos se acotaron a `0` y una muestra de hasta 10 productos con precio anterior y nuevo. Con `p_dry_run = true` SHALL devolver lo mismo sin escribir: es la vista previa. Una aplicación con cambios SHALL dejar una fila en `audit_logs` (`product.bulk_price_adjusted`) con modo, dirección, valor, productos cambiados y acotados, y el usuario.

#### Scenario: Aumento por porcentaje

- **GIVEN** dos productos simples de $1.000 y $2.345
- **WHEN** se aplica un aumento del 10 %
- **THEN** quedan en $1.100 y $2.580 y hay una fila `product.bulk_price_adjusted` en `audit_logs`

#### Scenario: Baja por importe con piso cero

- **GIVEN** productos de $300 y $1.000
- **WHEN** se aplica una baja de $500
- **THEN** quedan en $0 y $500, y el resultado informa un producto acotado a `0`

#### Scenario: Un padre seleccionado se expande a sus variantes

- **GIVEN** un padre `variant_only` con dos variantes de $1.000
- **WHEN** se selecciona sólo el padre y se aplica un aumento del 20 %
- **THEN** las dos variantes quedan en $1.200, el padre sigue en $0 y el resultado informa un padre omitido

#### Scenario: La vista previa no escribe

- **WHEN** se llama con `dry_run = true`
- **THEN** el resultado informa los cambios y la muestra antes → después, y ningún precio cambia ni se escribe `audit_logs`

#### Scenario: Productos de otra cuenta

- **WHEN** la lista incluye ids de otra cuenta
- **THEN** esos productos no cambian, no hay error y no se cuentan como elegibles

#### Scenario: Valor fuera de rango

- **WHEN** se pide una baja del 95 % o un aumento del 1.500 %
- **THEN** la API responde `422` y nada cambia

#### Scenario: Más de 500 ids

- **WHEN** una llamada informa 501 ids
- **THEN** la API responde `422` y nada cambia

### Requirement: Sólo dueño o administrador modifica precios en lote

La función y el endpoint SHALL exigir que el usuario pueda escribir en la cuenta (`P0401`) y que tenga rol de dueño o administrador (`P0403`, `insufficient_role`, `403` en la API). La acción "Modificar precios" NO SHALL mostrarse a otros roles. La función NO SHALL tener `EXECUTE` para `anon`.

#### Scenario: Un vendedor no modifica precios en lote

- **GIVEN** un miembro con rol de vendedor
- **WHEN** llama a `PATCH /products/bulk-price` o a la función
- **THEN** recibe `403` y ningún precio cambia
- **AND** no ve la acción "Modificar precios" en `/productos`

### Requirement: Una sola definición del redondeo de precios

El redondeo de precios a pesos enteros SHALL tener una única definición por lenguaje: `product_round_price(numeric)` en SQL y `roundToPesos` en `frontend/lib/product-pricing.ts`, ambas con redondeo de la mitad hacia afuera del cero. Ambas SHALL verificarse contra la misma tabla de casos compartida. La modificación en lote y la sugerencia de precio SHALL usar esa definición; ningún otro camino SHALL redondear precios por su cuenta.

#### Scenario: Paridad del redondeo

- **WHEN** se evalúan los casos compartidos (por ejemplo 0,5; 1234,5; 1234,49; 2,675)
- **THEN** `product_round_price` y `roundToPesos` devuelven 1; 1235; 1234; 3 respectivamente

### Requirement: Superficie de la modificación de precios en lote

`/productos` SHALL ofrecer la acción "Modificar precios" junto a "Recategorizar", sobre la misma selección múltiple (checkbox por fila y "seleccionar visibles"). La acción SHALL abrir un diálogo con dirección, modo y valor, y SHALL mostrar la vista previa del servidor (cuántos cambian, cuántos quedan igual, padres omitidos, acotados a `0` y la muestra antes → después) antes de habilitar la confirmación. El diálogo SHALL avisar que deshacer con el porcentaje inverso no es exacto por el redondeo. La selección SHALL trocearse en bloques de hasta 500 ids reutilizando el troceo de la recategorización en lote; cada bloque es atómico y, si uno falla, el diálogo SHALL informar cuántos productos se aplicaron. Al terminar SHALL refrescar el listado. La superficie SHALL verificarse en desktop y móvil y en tema claro y oscuro.

#### Scenario: Vista previa antes de confirmar

- **GIVEN** un dueño con 30 productos seleccionados
- **WHEN** elige "Modificar precios", aumento, 15 %
- **THEN** ve cuántos cambian y ejemplos antes → después, y recién entonces puede confirmar

#### Scenario: Falla de un bloque

- **GIVEN** una selección de 1.200 productos
- **WHEN** el segundo bloque falla
- **THEN** el diálogo informa que se aplicaron los productos del primer bloque y cuáles quedaron sin aplicar

### Requirement: Sugerencia de precio a partir del costo

El formulario de producto simple y el de variante SHALL sugerir el precio como costo × `SUGGESTED_MARKUP_FACTOR` (`1.5`, constante única en `frontend/lib/product-pricing.ts`), redondeado con `roundToPesos`, al escribir el costo. La sugerencia SHALL completar el precio **sólo si** el precio está vacío o en `0`, o sigue siendo igual a la última sugerencia aplicada; un precio escrito por el usuario NUNCA SHALL pisarse. Al editar un producto que ya tiene precio, NO SHALL sugerirse. Un costo vacío o `0` NO SHALL producir sugerencia. El formulario SHALL mostrar junto al precio que es una sugerencia editable. El importador de productos NO SHALL aplicar la sugerencia.

#### Scenario: Sugerencia en un alta

- **GIVEN** un producto nuevo sin precio
- **WHEN** el usuario escribe costo `1000`
- **THEN** el precio se completa con `1500` y se indica que es una sugerencia

#### Scenario: La sugerencia sigue al costo mientras el usuario no toque el precio

- **GIVEN** un alta donde el precio vale la sugerencia `1500`
- **WHEN** el usuario cambia el costo a `1200`
- **THEN** el precio pasa a `1800`

#### Scenario: Un precio escrito no se pisa

- **GIVEN** un alta donde el usuario escribió precio `2000`
- **WHEN** cambia el costo
- **THEN** el precio sigue en `2000`

#### Scenario: Sin costo no hay sugerencia

- **WHEN** el costo queda vacío o en `0`
- **THEN** el precio no cambia

#### Scenario: Edición de un producto con precio

- **GIVEN** un producto existente con precio `900`
- **WHEN** se edita su costo
- **THEN** el precio sigue en `900`

