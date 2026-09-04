# product-ranking Specification

## Purpose
Da al módulo de estadísticas de ventas un ranking de productos por unidades vendidas y por importe facturado, con las variantes agrupadas bajo su producto padre y el margen por producto informado sólo donde el costo es derivable (con su cobertura declarada cuando es parcial). Provee además el detalle de evolución por producto (con desglose por variante) alcanzable desde una fila del ranking. Las líneas de servicio (sin producto asociado) quedan fuera del ranking y su importe se declara aparte. El agregado por categoría de producto NO vive en esta capability: es la 5ª dimensión de los desgloses que define `sales-statistics` (`rpc_sales_breakdown`), con la misma forma de salida que canal, sucursal, día de la semana y horario.

## Requirements

### Requirement: Ranking de productos por unidades y por importe como vistas separadas

El sistema SHALL exponer el ranking de productos vendidos del período ordenable por **unidades vendidas** y por **importe facturado**, como dos ordenamientos distintos del mismo read-model.

Los dos ordenamientos SHALL ofrecerse por separado y NO SHALL colapsarse en una única "mejor" métrica: producen rankings genuinamente distintos —en producción difieren desde el tercer puesto— y responden preguntas distintas (qué reponer contra qué sostiene la facturación).

Cada fila SHALL informar unidades vendidas, importe facturado y cantidad de operaciones. El read-model SHALL derivar su conjunto de líneas del helper canónico compartido definido por la capability `sales-statistics`, nunca de una agregación propia.

#### Scenario: El orden por unidades y por importe difieren

- **GIVEN** un período donde el producto más vendido en unidades no es el de mayor facturación
- **WHEN** se consulta el ranking por unidades y luego por importe
- **THEN** ambos rankings devuelven órdenes distintos, cada uno consistente con su métrica

#### Scenario: Sólo aparecen productos con ventas en el período

- **GIVEN** una cuenta con productos sin ventas en el período consultado
- **WHEN** se consulta el ranking
- **THEN** esos productos no aparecen

#### Scenario: El ranking se pagina

- **GIVEN** una cuenta con más productos vendidos que el tamaño de página
- **WHEN** se consulta el ranking
- **THEN** la respuesta se pagina y el orden se resuelve sobre el conjunto completo, nunca sobre la página visible

### Requirement: Las variantes se agrupan bajo el producto padre

El ranking SHALL agrupar las variantes de un producto bajo su **producto padre**, informando el agregado del grupo y permitiendo consultar el detalle por variante.

Sin agrupación el ranking se atomiza —en producción el 42% de los productos son variantes— y ningún producto real alcanza los primeros puestos. Una variante cuyo producto padre ya no existe SHALL agruparse bajo sí misma: dejó de tener padre y ese es su agregado correcto.

Cada fila agrupada SHALL informar cuántas variantes agrupa, de modo que el usuario distinga un producto simple de un grupo.

#### Scenario: Las variantes suman bajo el padre

- **GIVEN** un producto con tres variantes, cada una con ventas en el período
- **WHEN** se consulta el ranking agrupado
- **THEN** aparece una sola fila para el producto padre, con la suma de unidades e importe de sus tres variantes

#### Scenario: El detalle por variante está disponible

- **GIVEN** una fila del ranking que agrupa variantes
- **WHEN** el usuario consulta su detalle
- **THEN** ve el desglose de unidades e importe por cada variante

#### Scenario: Variante sin padre agrupa bajo sí misma

- **GIVEN** una variante cuyo producto padre fue eliminado del catálogo
- **WHEN** se consulta el ranking agrupado
- **THEN** esa variante aparece como una fila propia, sin perderse del ranking

### Requirement: Margen por producto sólo donde hay costo, con su cobertura declarada

El ranking SHALL informar el margen del producto en el período cuando el costo sea derivable, usando la cascada canónica de costo: el costo congelado en la línea de venta, con fallback al costo del catálogo únicamente cuando la línea no tiene snapshot.

Un grupo sin **ningún** costo resoluble SHALL informar el margen como ausente y la superficie SHALL mostrarlo como tal — NUNCA como cero, y nunca con un valor derivado de un costo inventado.

Un grupo con cobertura **parcial** de costo SHALL informar además qué proporción de sus líneas tiene costo, y la superficie SHALL mostrarlo: un grupo con cobertura baja exhibe un margen aparentemente alto y sería indistinguible de uno medido sobre todas sus líneas.

#### Scenario: Producto sin costo muestra margen ausente

- **GIVEN** un producto cuyas líneas de venta no tienen costo congelado ni costo de catálogo
- **WHEN** se consulta el ranking
- **THEN** su margen se informa como ausente y la superficie lo muestra como tal, no como cero

#### Scenario: El margen usa el costo congelado, no el actual

- **GIVEN** un producto vendido con costo congelado en la línea, cuyo costo de catálogo cambió después
- **WHEN** se consulta el ranking del período que contiene esa venta
- **THEN** el margen se calcula con el costo congelado

#### Scenario: Cobertura parcial declarada

- **GIVEN** un grupo donde sólo parte de sus líneas tienen costo
- **WHEN** se consulta el ranking
- **THEN** la fila informa su proporción de cobertura de costo y la superficie la muestra junto al margen

### Requirement: Las líneas de servicio quedan fuera del ranking y su importe se declara

Las líneas de venta sin producto asociado (líneas de servicio) NO SHALL aparecer en el ranking de productos: no son productos y no tienen dónde rankear.

Su importe SHALL declararse en la superficie del ranking, porque **sí** es facturación real y **sí** está incluida en los agregados de facturación del módulo. Sin esa declaración, un usuario que compare el total del ranking con el total del período encuentra una diferencia sin explicación.

#### Scenario: La línea de servicio no aparece como producto

- **GIVEN** un período con líneas de venta sin producto asociado
- **WHEN** se consulta el ranking de productos
- **THEN** ninguna fila representa esas líneas

#### Scenario: El importe excluido se declara

- **GIVEN** un período con líneas de servicio facturadas
- **WHEN** el usuario ve el ranking
- **THEN** la superficie declara el importe facturado que el ranking no incluye

### Requirement: Detalle de evolución por producto

El sistema SHALL proveer una pantalla de detalle por producto, alcanzable desde una fila del ranking, que muestre la evolución de las ventas de ese producto en el período —y, cuando la fila agrupa variantes, el desglose por variante.

La pantalla SHALL vivir dentro del módulo de estadísticas y SHALL enlazar al producto en el catálogo, sin sustituir ni anticipar una pantalla de detalle de catálogo.

#### Scenario: Desde el ranking al detalle

- **GIVEN** un usuario viendo el ranking de productos
- **WHEN** abre una fila
- **THEN** llega al detalle de ese producto con su evolución de ventas del período

#### Scenario: Detalle de un grupo con variantes

- **GIVEN** un producto con variantes vendidas en el período
- **WHEN** se abre su detalle
- **THEN** se muestra la evolución del grupo y el desglose por variante

#### Scenario: El detalle enlaza al catálogo

- **WHEN** el usuario abre el detalle de un producto
- **THEN** existe un enlace al producto en el catálogo

### Requirement: Superficie y estados del ranking

La pantalla del ranking SHALL permitir cambiar entre los ordenamientos disponibles y activar o desactivar la agrupación de variantes, sin recargar la página.

SHALL funcionar en tema claro y oscuro, en escritorio y móvil, usando tokens semánticos, y su tabla SHALL desplazarse horizontalmente dentro de su contenedor sin desbordar el shell. SHALL mostrar un estado vacío explicativo cuando el período no tiene ventas, y un estado de error visible y distinguible cuando la consulta falla.

#### Scenario: Cambio de ordenamiento

- **GIVEN** el ranking mostrado por unidades
- **WHEN** el usuario cambia a importe
- **THEN** el ranking se reordena por importe

#### Scenario: Alternar la agrupación de variantes

- **GIVEN** el ranking agrupado por producto padre
- **WHEN** el usuario desactiva la agrupación
- **THEN** cada variante aparece como una fila propia

#### Scenario: Período sin ventas

- **GIVEN** un rango sin ventas
- **WHEN** el usuario consulta el ranking
- **THEN** ve un estado vacío explicativo, distinguible de un error

