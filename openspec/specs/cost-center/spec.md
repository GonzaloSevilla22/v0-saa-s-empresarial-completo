# cost-center Specification

## Purpose

Dimensión analítica **opcional** para imputar costos —gastos y compras— a un área, proyecto o unidad de negocio, y poder leerlos agregados por esa dimensión. Es **ortogonal** a `branch_id` (dónde ocurrió) y a `expenses.category` (qué tipo de gasto es): ninguna reemplaza a otra. Cubre el catálogo plano por cuenta (`cost_centers`, CRUD gateado a `owner`/`admin`), la columna nullable `cost_center_id` en `expenses` y `purchases`, las superficies que la hacen usable (gestión del catálogo, reporte de costos por centro, filtros en los listados) y la propagación del centro al asiento contable.

Es dimensión de **costos, no de ingresos**: las ventas no se imputan y por lo tanto no existe margen por centro de costo. Fuera de alcance por decisión: jerarquías de centros y distribución porcentual.

## Requirements
### Requirement: Catálogo de centros de costo por cuenta

El sistema SHALL persistir un catálogo plano de centros de costo en la tabla `cost_centers` (`id` UUID PK, `account_id` UUID FK `accounts` NOT NULL, `name` TEXT NOT NULL, `code` TEXT NULL, `is_active` BOOLEAN NOT NULL DEFAULT TRUE, `created_at` TIMESTAMPTZ). El catálogo SHALL ser **plano** (sin jerarquías ni columna `parent_id`) y sin distribución porcentual. El sistema SHALL impedir nombres duplicados dentro de una misma cuenta de forma case-insensitive (`UNIQUE(account_id, lower(name))`). La tabla SHALL tener RLS por `account_id`.

#### Scenario: Crear un centro de costo

- **WHEN** un `owner`/`admin` crea un centro de costo con un nombre válido
- **THEN** se persiste una fila en `cost_centers` con `account_id` de su cuenta, `is_active = true` y el nombre dado

#### Scenario: Nombre duplicado en la misma cuenta es rechazado

- **GIVEN** una cuenta que ya tiene un centro de costo "Logística"
- **WHEN** se intenta crear otro "logística" (misma cuenta, distinta capitalización)
- **THEN** la operación es rechazada por el unique case-insensitive

#### Scenario: Aislamiento por cuenta

- **GIVEN** centros de costo de la cuenta A y de la cuenta B
- **WHEN** un usuario de la cuenta A lista los centros de costo
- **THEN** sólo ve los de la cuenta A (RLS por `account_id`)

---

### Requirement: Gestión del catálogo gateada por rol

El sistema SHALL permitir **leer** los centros de costo a cualquier miembro de la cuenta y **crear/editar/desactivar** sólo a `owner`/`admin`. La autorización de escritura SHALL aplicarse tanto a nivel de RLS (policy de `INSERT`/`UPDATE`) como en el service (`require_role`), de modo que un `member` no pueda modificar el catálogo aunque alcance la capa de datos.

#### Scenario: Member puede leer pero no escribir

- **GIVEN** un usuario con rol `member`
- **WHEN** lista los centros de costo de su cuenta
- **THEN** la lectura es permitida
- **AND** **WHEN** intenta crear o editar un centro de costo
- **THEN** la operación es rechazada (403)

#### Scenario: Owner/admin gestiona el catálogo

- **GIVEN** un usuario con rol `owner` o `admin`
- **WHEN** crea, renombra o desactiva un centro de costo de su cuenta
- **THEN** la operación es permitida y persiste

---

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

---

### Requirement: Imputación opcional de gastos a un centro de costo

El sistema SHALL permitir imputar opcionalmente un gasto a un centro de costo mediante una columna nullable `cost_center_id` (FK a `cost_centers`, `ON DELETE SET NULL`) en `public.expenses`. El campo SHALL ser opcional: un gasto sin centro de costo es válido y queda `NULL`. El `cost_center_id` provisto SHALL pertenecer a la misma cuenta que el gasto. La columna `cost_center_id` SHALL ser ortogonal a `expenses.category` (texto libre) y a `branch_id`: ninguna reemplaza a otra.

#### Scenario: Alta de gasto con centro de costo

- **WHEN** se crea un gasto con un `cost_center_id` activo de la cuenta
- **THEN** el gasto se persiste con ese `cost_center_id`

#### Scenario: Alta de gasto sin centro de costo

- **WHEN** se crea un gasto sin especificar centro de costo
- **THEN** el gasto se persiste con `cost_center_id = NULL` (válido)

#### Scenario: Centro de costo de otra cuenta es rechazado

- **WHEN** se intenta crear un gasto con un `cost_center_id` que pertenece a otra cuenta
- **THEN** la operación es rechazada (no se imputa cross-account)

---

### Requirement: Imputación opcional de compras a un centro de costo (por operación)

El sistema SHALL permitir imputar opcionalmente una compra a un centro de costo mediante una columna nullable `cost_center_id` (FK a `cost_centers`, `ON DELETE SET NULL`) en `public.purchases`. En una compra multi-línea (varias filas `purchases` con el mismo `operation_id`), el centro de costo SHALL ser **por operación**: todas las líneas de la operación comparten el mismo `cost_center_id`. El alta de compra (`rpc_create_purchase_operation`) SHALL aceptar un `cost_center_id` opcional, validar que pertenezca a la cuenta (igual que valida `branch_id`) y persistirlo en todas las líneas. La firma de idempotencia de la compra NO SHALL cambiar (no se agrega un `operation_kind` nuevo).

#### Scenario: Alta de compra multi-línea con centro de costo

- **WHEN** se crea una compra de 3 líneas con un `cost_center_id` activo de la cuenta
- **THEN** las 3 filas `purchases` de esa operación se persisten con el mismo `cost_center_id`

#### Scenario: Alta de compra sin centro de costo (regresión)

- **WHEN** se crea una compra sin especificar centro de costo
- **THEN** la compra se persiste con `cost_center_id = NULL` y el comportamiento previo no cambia

#### Scenario: Centro de costo de otra cuenta es rechazado en la compra

- **WHEN** se intenta crear una compra con un `cost_center_id` de otra cuenta
- **THEN** la operación es rechazada (validación de pertenencia, espejo de `branch_id`)

---

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

