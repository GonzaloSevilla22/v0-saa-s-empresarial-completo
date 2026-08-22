## ADDED Requirements

### Requirement: Historial de movimientos de libro consultable en caja y banco
El sistema SHALL exponer, en el módulo de Caja y en el de Banco, un historial de los movimientos del libro correspondiente con la misma estructura de lectura que el historial de movimientos de stock: cabecera colapsable con resumen, filtros por familia de tipo, búsqueda, badge de tipo con etiqueta e ícono propios, saldo resultante por fila, carga incremental y exportación a CSV. El historial SHALL ser de sólo lectura: no expone edición ni borrado de movimientos, porque ambos libros son append-only.

#### Scenario: El usuario abre el historial de caja
- **GIVEN** una caja con movimientos registrados
- **WHEN** el usuario despliega el historial en `/caja`
- **THEN** ve los movimientos más recientes primero, cada uno con fecha, tipo etiquetado, importe con signo y saldo resultante

#### Scenario: El usuario abre el historial de banco
- **GIVEN** una cuenta bancaria con movimientos registrados
- **WHEN** el usuario despliega el historial en la pestaña Movimientos de `/banco`
- **THEN** ve los movimientos ordenados por fecha valor descendente, cada uno con tipo etiquetado, importe con signo, saldo resultante y estado de conciliación

#### Scenario: El historial no ofrece editar ni borrar
- **WHEN** el usuario inspecciona cualquier fila del historial en cualquiera de los dos libros
- **THEN** no existe acción de edición ni de borrado del movimiento

### Requirement: El historial de caja cubre todas las sesiones de la caja
El sistema SHALL listar en el historial de caja los movimientos de **todas** las sesiones de la caja seleccionada, no solamente los de la sesión abierta, y SHALL identificar en cada fila a qué sesión pertenece el movimiento y si esa sesión está abierta o cerrada. Cerrar una sesión NO SHALL hacer desaparecer sus movimientos del historial.

#### Scenario: Los movimientos sobreviven al cierre de la sesión
- **GIVEN** una caja con una sesión ya cerrada que contenía movimientos y una sesión abierta con otros
- **WHEN** el usuario abre el historial de la caja
- **THEN** ve los movimientos de ambas sesiones en una sola lista continua, cada uno atribuido a su sesión

#### Scenario: La sesión se identifica en la fila
- **WHEN** el usuario mira un movimiento de una sesión cerrada
- **THEN** la fila indica la sesión (por su fecha de apertura) y su estado `cerrada`

### Requirement: Los filtros del historial se resuelven en el servidor
El sistema SHALL aplicar los filtros del historial (familia de tipo, tipo, rango de fechas, texto y —en banco— estado de conciliación) **en el servidor**, sobre el conjunto completo de movimientos, y NO SHALL filtrar únicamente sobre las filas ya cargadas en el cliente. Un filtro que no tiene coincidencias en la página cargada pero sí en el resto del libro SHALL devolver esas coincidencias.

#### Scenario: Filtrar por un tipo ausente de la primera página
- **GIVEN** un libro con cientos de movimientos donde los de tipo `adjustment` son los más antiguos
- **WHEN** el usuario filtra por la familia "Ajustes"
- **THEN** el historial devuelve los ajustes aunque no estuvieran entre los movimientos ya cargados

#### Scenario: Filtrar por estado de conciliación en banco
- **GIVEN** una cuenta bancaria con movimientos conciliados y sin conciliar
- **WHEN** el usuario filtra por `sin conciliar`
- **THEN** el historial devuelve solamente los movimientos con `reconciliation_status = 'unreconciled'`

### Requirement: Los listados de movimientos usan la paginación estándar de la API
El sistema SHALL exponer la lectura de ambos historiales como endpoints del backend FastAPI con el contrato de paginación estándar `?page&size` y el envelope `{items, total, page, pages}`, construidos en las tres capas (routers → services → repositories) con JWT-passthrough y sin `service_role`, y con errores en formato RFC 7807. El historial de caja SHALL listarse por caja (`cashbox`) y el de banco por cuenta bancaria.

#### Scenario: Listado paginado de movimientos de caja
- **WHEN** se llama `GET /cashboxes/{cashbox_id}/movements?page=0&size=30`
- **THEN** la respuesta es `{items: [...], total: N, page: 0, pages: ceil(N/30)}` con a lo sumo 30 elementos

#### Scenario: Listado paginado de movimientos bancarios
- **WHEN** se llama `GET /bank-accounts/{bank_account_id}/movements?page=0&size=30`
- **THEN** la respuesta es `{items: [...], total: N, page: 0, pages: ceil(N/30)}` con a lo sumo 30 elementos

#### Scenario: Página fuera de rango
- **WHEN** se pide una `page` mayor que `pages` en cualquiera de los dos listados
- **THEN** la respuesta es `200` con `items: []` y `total`/`page`/`pages` consistentes

#### Scenario: Aislamiento por cuenta
- **WHEN** un usuario pide los movimientos de una caja o de una cuenta bancaria que no pertenece a su cuenta (tenant)
- **THEN** la respuesta no incluye ningún movimiento ajeno

### Requirement: La taxonomía de tipos de movimiento se declara una sola vez por libro
El sistema SHALL declarar la etiqueta, el ícono, el tratamiento visual y la familia de filtro de cada `movement_type` en una fuente única por libro, reutilizada por el historial, los badges y la exportación, y NO SHALL duplicar ese mapeo en cada pantalla que muestre movimientos. El componente de historial SHALL ser uno solo, parametrizado por la configuración del libro, en vez de una implementación por libro.

#### Scenario: Un tipo nuevo se agrega en un solo lugar
- **WHEN** se incorpora un `movement_type` nuevo a un libro
- **THEN** basta agregarlo a la taxonomía de ese libro para que aparezca etiquetado en el historial, en el filtro por familia y en el CSV

#### Scenario: Un tipo desconocido no rompe la pantalla
- **WHEN** el historial recibe un movimiento cuyo `movement_type` no está en la taxonomía
- **THEN** la fila se muestra con el código crudo del tipo y un tratamiento neutro, sin romper el listado

### Requirement: El historial exporta a CSV lo que está viendo el usuario
El sistema SHALL permitir exportar el historial a CSV respetando los filtros activos, incluyendo por cada movimiento la fecha, el tipo etiquetado, el importe con signo, el saldo resultante, el motivo cuando exista, y —según el libro— la sesión de caja o el estado de conciliación.

#### Scenario: Exportar el historial filtrado
- **GIVEN** un historial con un filtro de familia activo
- **WHEN** el usuario exporta a CSV
- **THEN** el archivo contiene exactamente los movimientos que cumplen el filtro, con el motivo de los ajustes incluido
