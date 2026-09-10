## MODIFIED Requirements

### Requirement: El SKU es la clave de upsert de la carga masiva

El sistema SHALL conservar el SKU como clave de upsert de la carga masiva: una fila cuyo SKU coincide con el de un producto vivo de la cuenta SHALL **actualizar** ese producto en lugar de crear uno nuevo, y una fila sin SKU SHALL seguir resolviéndose por los criterios de deduplicación ya vigentes. La resolución SHALL alcanzarse por cuenta, en coherencia con el índice único.

El alcance de cuenta SHALL regir **todas** las resoluciones por SKU de la carga masiva, incluida la búsqueda del producto padre que una fila de variante referencia por SKU cuando ese padre no viene en el mismo archivo. Ninguna capa —cliente incluido— SHALL resolver una referencia de la carga masiva alcanzándola por usuario: dos alcances distintos para la misma búsqueda hacen que el cliente y el servidor encuentren productos distintos, y que una variante quede huérfana sólo porque su padre lo creó otro miembro de la cuenta.

El sistema SHALL advertir en el paso de revisión cuando dos filas del **mismo archivo** traen el mismo SKU, porque la segunda actualiza la fila que escribió la primera y hoy eso ocurre en silencio.

#### Scenario: Reimportar actualiza el producto existente

- **GIVEN** un producto de la cuenta con SKU "REM-001"
- **WHEN** se importa un archivo con una fila de SKU "REM-001" y un precio distinto
- **THEN** el producto existente queda actualizado y no se crea un producto nuevo

#### Scenario: SKU repetido dentro del archivo se advierte

- **WHEN** un archivo trae dos filas con el mismo SKU y nombres distintos
- **THEN** el paso de revisión advierte que ambas filas afectan al mismo producto

#### Scenario: La resolución de la carga masiva usa el alcance de la cuenta

- **GIVEN** un producto con SKU "REM-001" creado por otro miembro de la misma cuenta
- **WHEN** un miembro importa un archivo con una fila de SKU "REM-001"
- **THEN** la fila actualiza ese producto existente en lugar de crear un duplicado en la misma cuenta

#### Scenario: La referencia de padre por SKU también usa el alcance de la cuenta

- **GIVEN** un producto padre con SKU "ZAP-NIKE" creado por otro miembro de la misma cuenta
- **WHEN** un miembro importa un archivo con una fila de variante que referencia "ZAP-NIKE" como SKU padre
- **THEN** la variante queda vinculada a ese producto padre y no se importa como producto independiente
