## ADDED Requirements

### Requirement: La gestión del catálogo es alcanzable desde la interfaz

El sistema SHALL exponer la gestión del catálogo de centros de costo en una pantalla alcanzable por navegación desde la aplicación, sin requerir llamadas directas a la API. La pantalla SHALL permitir a un `owner`/`admin` crear, renombrar y desactivar centros de costo, y SHALL listar tanto los activos como los desactivados (distinguibles entre sí). Un `member` SHALL poder ver el listado sin ver las acciones de escritura. La superficie SHALL ser responsive (desktop y mobile) y legible en tema claro y oscuro.

#### Scenario: Owner llega a la gestión del catálogo navegando

- **GIVEN** un usuario con rol `owner` o `admin` autenticado
- **WHEN** navega a la sección de configuración de la aplicación
- **THEN** encuentra la gestión de centros de costo y puede crear el primero sin salir de la aplicación

#### Scenario: El selector de altas deja de estar vacío

- **GIVEN** una cuenta sin ningún centro de costo definido
- **WHEN** un `owner`/`admin` crea "Marketing" desde la pantalla de gestión
- **THEN** "Marketing" queda disponible en el selector "Centro de costo (opcional)" del alta de gasto y del alta de compra

#### Scenario: Member ve el catálogo sin acciones de escritura

- **GIVEN** un usuario con rol `member`
- **WHEN** abre la pantalla de gestión del catálogo
- **THEN** ve el listado de centros de costo y no se le ofrecen las acciones de crear, editar ni desactivar

---

### Requirement: Read-model de costos agregados por centro de costo

El sistema SHALL proveer un read-model `rpc_cost_center_report(p_account_id uuid, p_start date, p_end date)` que agregue los **costos** de un rango por centro de costo, devolviendo por fila: `cost_center_id`, `cost_center_name`, `cost_center_code`, `total_expenses`, `total_purchases`, `total_cost` (= `total_expenses` + `total_purchases`) y `operation_count`. Los importes SHALL ser `NUMERIC`. Las compras SHALL sumarse como `COALESCE(total, amount)` y los gastos como `amount`. El `operation_count` SHALL contar las compras como `COUNT(DISTINCT COALESCE(operation_id, id))` más una unidad por cada fila de gasto. El rango SHALL incluir el día final completo. El RPC SHALL rechazar al caller que no sea miembro de `p_account_id`. El read-model SHALL cubrir únicamente costos: las ventas no participan, porque el centro de costo no se imputa a ingresos.

#### Scenario: Compra multilínea aporta su total de línea y una sola operación

- **GIVEN** una compra de 3 líneas imputada a "Logística", con totales de línea $1.000, $2.000 y $3.000
- **WHEN** se ejecuta el reporte sobre un rango que la contiene
- **THEN** la fila "Logística" tiene `total_purchases = 6000` y aporta exactamente 1 al `operation_count`

#### Scenario: Gasto y compra del mismo centro se suman en total_cost

- **GIVEN** un centro "Marketing" con un gasto de $5.000 y una compra de $10.000 en el rango
- **WHEN** se ejecuta el reporte
- **THEN** la fila "Marketing" tiene `total_expenses = 5000`, `total_purchases = 10000` y `total_cost = 15000`

#### Scenario: Fila con hora real en el último día del rango queda incluida

- **GIVEN** un gasto imputado a un centro registrado el último día del rango a las 15:00 UTC
- **WHEN** se ejecuta el reporte con ese rango
- **THEN** el gasto está incluido en los totales del centro

#### Scenario: Caller ajeno a la cuenta es rechazado

- **WHEN** un usuario que no es miembro de `p_account_id` ejecuta el reporte de esa cuenta
- **THEN** la operación es rechazada

#### Scenario: Las ventas no participan del reporte

- **GIVEN** una cuenta con ventas y costos en el rango
- **WHEN** se ejecuta el reporte
- **THEN** ninguna columna del resultado incluye importes de ventas

---

### Requirement: Los costos no imputados son visibles como una fila propia

El sistema SHALL representar los gastos y compras del rango sin centro de costo (`cost_center_id IS NULL`) como una fila propia del reporte, identificada como "Sin centro de costo", en lugar de excluirlos. La suma de todas las filas del reporte SHALL igualar el costo total del rango, de modo que la imputación parcial no produzca un reporte que subvalúe los costos.

#### Scenario: Cuenta sin ninguna imputación ve todo su costo en una fila

- **GIVEN** una cuenta con $50.000 de gastos y compras en el rango, ninguno imputado a un centro de costo
- **WHEN** se ejecuta el reporte
- **THEN** el resultado tiene una única fila "Sin centro de costo" con `total_cost = 50000`

#### Scenario: El total del reporte iguala el costo del período

- **GIVEN** un rango con $30.000 imputados a centros y $20.000 sin imputar
- **WHEN** se suman todas las filas del reporte
- **THEN** el total es $50.000

---

### Requirement: Los listados de gastos y compras se filtran por centro de costo

El sistema SHALL permitir filtrar el listado de gastos y el listado de compras por centro de costo, y SHALL mostrar en cada fila el centro al que está imputada. El filtro SHALL aplicarse del lado del servidor y SHALL ser consistente con la paginación: el total de resultados y las páginas SHALL reflejar el filtro aplicado. El filtro SHALL ser opcional y componible con los filtros ya existentes de esos listados (búsqueda y rango de fechas). Un cambio de centro de costo seleccionado SHALL refrescar los resultados.

#### Scenario: Filtrar gastos por un centro de costo

- **GIVEN** una cuenta con 10 gastos, de los cuales 3 están imputados a "Marketing"
- **WHEN** el usuario filtra el listado de gastos por "Marketing"
- **THEN** el listado muestra 3 gastos y el total de la paginación es 3

#### Scenario: El filtro se compone con el rango de fechas

- **GIVEN** 3 gastos imputados a "Marketing", de los cuales 1 cae fuera del rango de fechas seleccionado
- **WHEN** el usuario aplica ambos filtros a la vez
- **THEN** el listado muestra 2 gastos

#### Scenario: Filtrar compras por un centro de costo

- **GIVEN** una cuenta con compras imputadas a distintos centros
- **WHEN** el usuario filtra el listado de compras por un centro
- **THEN** solo se listan las operaciones de compra imputadas a ese centro

#### Scenario: Sin filtro seleccionado el listado no cambia

- **WHEN** el usuario no selecciona ningún centro de costo
- **THEN** el listado devuelve los mismos resultados que antes de existir el filtro

## MODIFIED Requirements

### Requirement: La baja es desactivación y preserva la imputación histórica

El sistema SHALL dar de baja un centro de costo mediante **desactivación** (`is_active = false`), NO mediante borrado físico. Un centro de costo desactivado NO SHALL ofrecerse para imputar gastos o compras nuevos, pero los gastos y compras ya imputados a él SHALL conservar la referencia (el nombre histórico no se pierde). Un centro desactivado SHALL seguir siendo legible en las superficies de lectura: SHALL aparecer en el reporte por centro de costo con su nombre histórico cuando tenga costos en el rango consultado, y SHALL poder seleccionarse como filtro de los listados de gastos y compras.

#### Scenario: Desactivar un centro de costo en uso

- **GIVEN** un centro de costo "Marketing" con gastos ya imputados
- **WHEN** un `owner`/`admin` lo desactiva
- **THEN** `is_active` queda en `false` y deja de aparecer en el selector de altas nuevas
- **AND** los gastos históricos imputados a "Marketing" conservan su `cost_center_id`

#### Scenario: Un centro desactivado sigue apareciendo en el reporte

- **GIVEN** un centro "Marketing" desactivado, con $8.000 de gastos imputados dentro del rango consultado
- **WHEN** se ejecuta el reporte por centro de costo sobre ese rango
- **THEN** la fila "Marketing" aparece con `total_cost = 8000` y su nombre histórico
