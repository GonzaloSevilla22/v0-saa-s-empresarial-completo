## ADDED Requirements

### Requirement: RN-D2 — un costo ausente nunca se sustituye por cero

La cascada canónica de costo (snapshot congelado de la línea, con fallback al costo del catálogo) SHALL admitir no resolver, y todo read-model que la consuma SHALL propagar esa ausencia a su costo, su margen y su porcentaje de margen — NOT SHALL sustituirla por cero ni por ninguna estimación local.

El costo del catálogo es un dato **opcional** (capability `product-cost`): un `COALESCE(unit_cost_snapshot, products.cost, 0)` escrito en un read-model no es una guarda defensiva, es la reintroducción del defecto. Un costo ausente tratado como cero produce un margen del 100 % indistinguible de un margen medido, y ubica sistemáticamente al producto peor documentado en la cabecera de todo orden por rentabilidad.

Cuando un read-model agrega líneas de las cuales **sólo algunas** tienen costo resoluble, SHALL informar el costo y el margen sobre las líneas que sí lo tienen **y** declarar en la misma fila la proporción de cobertura. La cobertura SHALL medirse sobre **costo resoluble por la cascada**, no sobre presencia de snapshot: sin esa declaración, un agregado con cobertura baja es indistinguible de uno medido sobre todas sus líneas.

Los read-models que valorizan existencias (no márgenes) SHALL declarar cuántos de sus productos no tienen costo, en lugar de sumarlos como cero en silencio: la aritmética de una valorización que excluye lo que no puede valorizar es correcta, pero un total del que no se sabe qué proporción quedó afuera no es auditable.

**Excepción declarada** — `rpc_dashboard_kpi_summary` (columnas `cost_per_sale`/`prev_cost_per_sale`, derivadas de su CTE `sales_agg.cogs`) y `rpc_dashboard_channel_margin` (columna `margin_pct` por canal) son agregados de rentabilidad de **toda la cuenta**, no read-models por producto: siguen sumando el costo ausente como cero, comportamiento idéntico al de antes de este change (`products.cost` ya era `0`, nunca `NULL`, para estos productos). No es la reintroducción del defecto que este requirement prohíbe — es un defecto preexistente que este change no corrige, porque corregirlo cambiaría el número que informan (el margen agregado bajaría), no sólo cómo lo declaran. Candidato propio, ver `CHANGES.md`.

#### Scenario: Un read-model no inventa un costo cero

- **GIVEN** una línea de venta sin snapshot de costo, de un producto sin costo de catálogo
- **WHEN** cualquier read-model de reporting **por producto** agrega el costo y el margen del período
- **THEN** esa línea no aporta costo
- **AND** si es la única línea del agregado, el costo y el margen del agregado se informan ausentes, nunca en cero

#### Scenario: Cobertura parcial declarada sobre costo resoluble

- **GIVEN** un agregado de 4 líneas donde 3 tienen costo resoluble y 1 no
- **WHEN** se consulta el read-model
- **THEN** el costo y el margen se informan sobre las 3 líneas con costo
- **AND** la fila declara una cobertura de costo del 75 %

#### Scenario: Una línea sin snapshot pero con costo de catálogo cuenta como cubierta

- **GIVEN** una línea de venta sin snapshot de costo, cuyo producto sí tiene costo en el catálogo
- **WHEN** se calcula la cobertura de costo del agregado que la contiene
- **THEN** la línea cuenta como cubierta, porque su costo es resoluble por la cascada

#### Scenario: Una valorización de existencias declara lo que no pudo valorizar

- **GIVEN** una valorización de stock cuyos productos incluyen algunos sin costo cargado
- **WHEN** se informa el valor total
- **THEN** el read-model informa además cuántos productos quedaron sin valorizar por falta de costo
