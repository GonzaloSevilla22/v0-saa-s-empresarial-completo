## ADDED Requirements

### Requirement: Estados de actividad comercial del cliente
El sistema SHALL clasificar cada cliente en exactamente uno de cuatro estados de actividad — `frecuente`, `activo`, `inactivo`, `sin_compras` — derivados de sus operaciones de venta registradas, sin depender de ningún campo declarado manualmente.

El estado SHALL resolverse en el backend y viajar ya calculado al frontend; el frontend NO SHALL reimplementar la clasificación. La columna manual `clients.status` SHALL permanecer sin cambios y sin participar de este cómputo.

#### Scenario: Cliente sin ninguna venta registrada
- **WHEN** un cliente no tiene ninguna operación de venta asociada
- **THEN** su estado de actividad es `sin_compras`, distinto de `inactivo`

#### Scenario: Cliente con compras recientes frecuentes
- **WHEN** un cliente registra 3 o más operaciones de venta dentro de la ventana de frecuencia y su última compra está dentro del umbral de inactividad
- **THEN** su estado de actividad es `frecuente`

#### Scenario: Cliente con compras pero sin actividad reciente
- **WHEN** la última operación de venta de un cliente ocurrió hace 60 días o más
- **THEN** su estado de actividad es `inactivo`

#### Scenario: Cliente con actividad normal
- **WHEN** un cliente tiene al menos una compra, su última compra ocurrió hace menos de 60 días y registra menos de 3 operaciones en la ventana de frecuencia
- **THEN** su estado de actividad es `activo`

### Requirement: Precedencia determinística entre estados
El sistema SHALL evaluar los estados en el orden `sin_compras` → `inactivo` → `frecuente` → `activo`, de modo que un cliente que satisface simultáneamente los criterios de `frecuente` e `inactivo` se clasifique como `inactivo`.

La precedencia SHALL ser explícita y no depender del orden de las ramas de una expresión condicional ni del orden de las filas.

#### Scenario: Cliente frecuente que dejó de comprar
- **WHEN** un cliente acumula 3 o más operaciones dentro de la ventana de frecuencia pero todas ocurrieron hace 60 días o más
- **THEN** su estado de actividad es `inactivo`, no `frecuente`

#### Scenario: Cliente sin compras nunca es inactivo
- **WHEN** un cliente no tiene operaciones de venta
- **THEN** su estado es `sin_compras` aunque su antigüedad supere el umbral de inactividad

### Requirement: Umbrales canónicos en una única fuente de verdad
El sistema SHALL definir los umbrales de clasificación —cantidad mínima de operaciones para `frecuente`, tamaño de la ventana de frecuencia y días mínimos para `inactivo`— como constantes nombradas en un único módulo canónico del backend.

Las constantes SHALL pasarse a las consultas SQL como parámetros, no interpoladas en el texto de la consulta. Ningún otro módulo, capa o lenguaje SHALL declarar su propia copia de estos valores. Los valores iniciales son 3 operaciones, ventana de 90 días y 60 días de inactividad.

#### Scenario: Ajuste de un umbral
- **WHEN** se modifica el valor de una de las constantes canónicas
- **THEN** la clasificación cambia en toda la aplicación sin editar ninguna otra capa

#### Scenario: El frontend no replica umbrales
- **WHEN** el frontend renderiza el indicador de actividad de un cliente
- **THEN** usa el estado recibido del backend y no compara cantidades ni fechas contra umbrales propios

### Requirement: La unidad de compra es la operación de venta
El sistema SHALL contar como una compra cada operación de venta distinta, agrupando las filas de `sales` por `COALESCE(operation_id, id)`, de modo que una venta de varios productos cuente como una sola compra.

Las filas de venta sin `operation_id` SHALL contarse como una operación propia identificada por su `id`.

#### Scenario: Venta de varios productos en una operación
- **WHEN** un cliente compra 3 productos distintos en una misma operación de venta
- **THEN** la operación cuenta como 1 compra, no como 3

#### Scenario: Venta legacy sin operation_id
- **WHEN** una fila de venta asociada al cliente no tiene `operation_id`
- **THEN** se cuenta como una compra independiente identificada por su propio `id`

### Requirement: Agregados de actividad por cliente
El sistema SHALL exponer, para cada cliente, la cantidad total de compras, la cantidad de compras dentro de la ventana de frecuencia, el total comprado, la fecha de la última compra y los días transcurridos desde esa última compra.

Los agregados SHALL calcularse en la base de datos dentro de la misma consulta que recupera la página de clientes, sin emitir una consulta por cliente y sin transferir operaciones de venta al frontend para su cómputo.

#### Scenario: Listado de clientes con sus agregados
- **WHEN** se solicita una página del listado de clientes con actividad
- **THEN** cada cliente incluye sus agregados y la respuesta se resuelve en una sola consulta de datos

#### Scenario: Cliente sin compras
- **WHEN** un cliente no tiene operaciones de venta
- **THEN** su cantidad de compras y su total comprado son 0, y su fecha de última compra y días transcurridos son nulos

#### Scenario: Ventas no atribuidas a ningún cliente
- **WHEN** existen ventas sin `client_id`
- **THEN** no se atribuyen a ningún cliente ni afectan ningún agregado

### Requirement: Días y ventanas en día calendario argentino
El sistema SHALL computar los días transcurridos desde la última compra y los límites de la ventana de frecuencia en día calendario `America/Argentina/Mendoza`, conforme al canon `business-day-timezone`.

La fecha de cada operación SHALL convertirse al día calendario argentino antes de compararse, y el día de referencia SHALL obtenerse de `reporting_local_today()`. El sistema NO SHALL derivar estas ventanas de restas directas sobre `now()` ni del huso del servidor o del dispositivo del usuario.

#### Scenario: Compra registrada en la franja nocturna
- **WHEN** la última compra de un cliente se registró a las 22:00 hora argentina del día D (01:00 UTC del día D+1)
- **THEN** el cálculo de días transcurridos toma el día D como fecha de esa compra

#### Scenario: Ventana de frecuencia inclusiva
- **WHEN** se evalúa la ventana de frecuencia de 90 días en el día argentino D
- **THEN** se consideran las operaciones cuyo día argentino está entre D−89 y D inclusive

### Requirement: Señalización de actividad en la lista de clientes
La lista de clientes SHALL mostrar el estado de actividad de cada cliente mediante un indicador con texto visible, y SHALL permitir filtrar por estado de actividad y ordenar por última compra, total comprado o cantidad de compras.

El estado NO SHALL comunicarse únicamente por color. El indicador SHALL usar tokens semánticos del sistema de diseño y SHALL renderizarse correctamente en tema claro y oscuro, en viewport de escritorio y móvil.

#### Scenario: Cliente inactivo en la lista
- **WHEN** la lista muestra un cliente cuyo estado es `inactivo`
- **THEN** su indicador incluye un texto legible que identifica el estado, no sólo un color

#### Scenario: Filtro por estado de actividad
- **WHEN** el usuario filtra la lista por el estado `inactivo`
- **THEN** la lista muestra únicamente clientes en ese estado, con la paginación recalculada sobre el conjunto filtrado

#### Scenario: Orden por última compra
- **WHEN** el usuario ordena la lista por última compra descendente
- **THEN** los clientes se ordenan por su fecha de última compra y los clientes sin compras quedan al final
