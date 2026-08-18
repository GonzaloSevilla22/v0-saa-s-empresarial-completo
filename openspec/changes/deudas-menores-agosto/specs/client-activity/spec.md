## MODIFIED Requirements

### Requirement: Señalización de actividad en la lista de clientes
La lista de clientes SHALL mostrar el estado de actividad de cada cliente mediante un indicador con texto visible, SHALL permitir filtrar por estado de actividad y ordenar por última compra, total comprado o cantidad de compras, y SHALL presentarse ordenada por última compra descendente de forma predeterminada.

El orden predeterminado SHALL resolverse en el servidor, dentro de la misma consulta que produce la página, y los clientes sin compras SHALL quedar al final. El frontend NO SHALL reordenar la página recibida.

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

#### Scenario: Orden predeterminado al abrir la lista
- **WHEN** se solicita la primera página de la lista sin especificar criterio de orden
- **THEN** los clientes vienen ordenados por fecha de última compra, del más reciente al más antiguo, con los clientes sin compras al final

#### Scenario: Paginación estable con clientes sin compras
- **WHEN** se recorren todas las páginas del listado con el orden predeterminado
- **THEN** ningún cliente aparece dos veces ni queda omitido, incluso entre clientes cuya fecha de última compra es la misma o nula

## ADDED Requirements

### Requirement: El estado de cliente visible es exclusivamente el calculado
El sistema NO SHALL exponer en la interfaz el campo de estado declarado manualmente del cliente, ni para lectura ni para edición; el único estado de cliente presentado al usuario SHALL ser el estado de actividad calculado.

La columna manual SHALL permanecer en la base de datos sin cambios de esquema ni de datos: se retira su superficie, no el dato. Los formularios de alta y edición de cliente NO SHALL enviar ese campo en su payload.

#### Scenario: El formulario de cliente no ofrece el estado manual
- **WHEN** el usuario abre el formulario de edición de un cliente
- **THEN** no existe ningún control para elegir un estado manual del cliente

#### Scenario: El alta de cliente no envía el estado manual
- **WHEN** se crea o se actualiza un cliente desde la interfaz
- **THEN** el payload enviado no incluye el campo de estado manual

#### Scenario: El dato histórico sobrevive
- **WHEN** se consulta un cliente cuyo estado manual tenía un valor antes de este cambio
- **THEN** ese valor sigue almacenado en la base de datos, inalterado
