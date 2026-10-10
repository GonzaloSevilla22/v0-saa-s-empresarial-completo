# branches — Spec (sucursales-module-pro)

## Purpose

Gestión de sucursales (puntos de venta) por cuenta. Exclusivo plan PRO. Permite asignar operaciones (ventas, compras, gastos, stock) a sucursales específicas, filtrar/reportar por ellas y, desde C-26, operar su ciclo de vida (apertura/cierre operacional).
## Requirements
### Requirement: Creación de sucursal vía RPC con límite de plan

El sistema SHALL crear sucursales únicamente a través de la RPC `rpc_create_branch(p_account_id UUID, p_name TEXT, p_address TEXT)`, que verifica que el número de sucursales activas de la cuenta no supera `plan_limits.max_branches` del plan efectivo antes de insertar.

#### Scenario: Cuenta PRO crea su primera sucursal

- **GIVEN** una cuenta con `billing_plan = 'pro'` y 0 sucursales activas
- **WHEN** el owner llama a `rpc_create_branch` con un nombre válido
- **THEN** se inserta una fila en `branches` con `is_active = TRUE` y se retorna el objeto creado

#### Scenario: Cuenta PRO intenta crear la cuarta sucursal

- **GIVEN** una cuenta con `billing_plan = 'pro'` y 3 sucursales activas (límite = 3)
- **WHEN** cualquier miembro llama a `rpc_create_branch`
- **THEN** la RPC retorna error `branch_limit_exceeded` y NO inserta ninguna fila

#### Scenario: Cuenta no-PRO no puede crear sucursales

- **GIVEN** una cuenta con `billing_plan = 'avanzado'` (hasBranchesModule = false)
- **WHEN** el owner llama a `rpc_create_branch`
- **THEN** la RPC retorna error `branch_limit_exceeded`

#### Scenario: El nombre de sucursal debe ser único dentro de la cuenta

- **GIVEN** una cuenta con una sucursal llamada "Mendoza Centro"
- **WHEN** se intenta crear otra sucursal con el mismo nombre en la misma cuenta
- **THEN** la RPC retorna error `branch_name_duplicate` (violación de UNIQUE constraint `(account_id, name)`)

---

### Requirement: Listado y edición de sucursales

El sistema SHALL permitir a los miembros listar las sucursales activas de su cuenta, y a `owner` y `admin` editar nombre y dirección.

#### Scenario: Miembro lista las sucursales de su cuenta

- **GIVEN** un usuario miembro de una cuenta con 2 sucursales activas
- **WHEN** consulta `SELECT * FROM branches WHERE account_id = :account_id AND is_active = TRUE`
- **THEN** ve exactamente 2 filas

#### Scenario: Miembro no ve sucursales de otra cuenta

- **GIVEN** dos cuentas A y B, cada una con sucursales propias
- **WHEN** un miembro de la cuenta A consulta `branches`
- **THEN** solo ve las sucursales de la cuenta A (RLS aísla)

#### Scenario: Owner actualiza el nombre de una sucursal

- **GIVEN** una sucursal `id = X` que pertenece a la cuenta del owner
- **WHEN** el owner hace UPDATE `branches SET name = 'Nuevo Nombre' WHERE id = X`
- **THEN** la actualización es permitida por RLS

#### Scenario: Member no puede editar sucursales

- **GIVEN** un usuario con rol `member` en la cuenta
- **WHEN** intenta UPDATE `branches SET name = 'Hack' WHERE id = X`
- **THEN** la RLS rechaza la operación

---

### Requirement: Soft-delete de sucursales

El sistema SHALL marcar las sucursales como inactivas (`is_active = FALSE`) en lugar de borrarlas físicamente, preservando el historial de operaciones asociadas, y SHALL exigir que la sucursal esté **vacía de contenido operativo** antes de aceptar la desactivación.

La desactivación deja de ser una operación libre. Una sucursal con existencias, con una sesión de caja abierta o con transferencias sin completar SHALL NOT poder desactivarse; el detalle del predicado, del punto donde se aplica y del mensaje de rechazo vive en la capacidad `branch-decommission-guard`. El motivo es que la desactivación saca a la sucursal de la resolución de la sucursal por defecto de la cuenta: desactivar una sucursal llena convierte su inventario en existente pero inalcanzable, sin ningún aviso.

El borrado físico de la sucursal SHALL estar prohibido en todos los casos.

#### Scenario: Owner desactiva una sucursal vacía

- **GIVEN** una sucursal con `is_active = TRUE`, sin existencias en su inventario, y con operaciones históricas con `branch_id = X`
- **WHEN** el owner llama a la función de desactivación
- **THEN** `branches.is_active` pasa a `FALSE` y las filas de `sales` y demás tablas conservan su `branch_id = X`

#### Scenario: Owner intenta desactivar una sucursal con mercadería

- **GIVEN** una sucursal con `is_active = TRUE` y existencias distintas de cero en su inventario por sucursal
- **WHEN** el owner llama a la función de desactivación
- **THEN** la operación es rechazada, `is_active` sigue en `TRUE`, y el rechazo indica cuánto stock hay y que se transfiera a otra sucursal

#### Scenario: Sucursal inactiva no aparece en el selector

- **GIVEN** una sucursal con `is_active = FALSE`
- **WHEN** el sistema carga el listado de sucursales disponibles para el selector de formularios
- **THEN** la sucursal inactiva no está en el listado

#### Scenario: Sucursal inactiva aparece en reportes históricos

- **GIVEN** ventas registradas con `branch_id = X` cuando la sucursal estaba activa
- **WHEN** se consulta el reporte por sucursal incluyendo sucursales inactivas
- **THEN** las ventas de la sucursal X aparecen en el reporte (no se pierden datos históricos)

---

### Requirement: La sucursal registra quién la creó y quién la dio de baja

El sistema SHALL registrar sobre la propia sucursal la **autoría de su alta** y la **autoría y el momento de su desactivación**.

La entidad hoy no guarda autoría de ninguna clase. Cuando hubo que reconstruir el incidente del 22-08 fue imposible decir quién había creado cada sucursal y quién había desactivado la original: se infirió sobre marcas de tiempo. La máquina de estados operacional ya guarda cuándo se abrió y cuándo se cerró la sucursal, pero tampoco guarda quién.

La autoría SHALL ser una referencia lógica a la identidad del usuario, **sin clave foránea dura** al catálogo de identidades, en línea con las demás columnas de autoría que el proyecto ya tiene (autor del borrado lógico de maestros, autor de las transferencias de stock).

El sistema SHALL NOT agregar a la sucursal columnas de borrado lógico de maestros. La política de borrado ya adoptada excluye a las sucursales a propósito — la sucursal se desactiva, no se borra — y duplicar esa semántica junto a `is_active` contradiría una decisión vigente. La autoría de la baja SHALL expresarse dentro del vocabulario que la sucursal ya usa.

El sistema SHALL NOT registrar autoría de edición en una columna. Una columna retiene sólo al último editor y no dice qué cambió; la pregunta "quién le cambió el nombre" la contesta el registro de auditoría, no la entidad.

**No hay backfill.** Las sucursales existentes al aplicar este cambio SHALL quedar con autoría de alta nula, porque no se puede inventar quién creó una fila de hace meses. Esa ausencia SHALL estar documentada en el propio modelo de datos y SHALL presentarse en la interfaz como "no registrado", nunca como un vacío sin explicación.

Los caminos de alta **de sistema** — el alta perezosa de la sucursal por defecto cuando una cuenta nueva recibe su primer movimiento de stock, y las siembras de aprovisionamiento — SHALL dejar la autoría nula a propósito, porque no hay persona detrás. Esa distinción SHALL estar documentada en el modelo, para que un valor nulo no se lea como un dato perdido.

#### Scenario: El alta por la interfaz registra al usuario que la hizo

- **GIVEN** un owner autenticado
- **WHEN** crea una sucursal desde la interfaz
- **THEN** la sucursal queda con la autoría de alta apuntando a ese usuario

#### Scenario: El alta automática del sistema deja la autoría nula

- **GIVEN** una cuenta nueva sin ninguna sucursal
- **WHEN** el sistema crea automáticamente su sucursal por defecto al recibir el primer movimiento de stock
- **THEN** la sucursal queda con autoría de alta nula, porque no hubo una persona que la creara

#### Scenario: La desactivación registra autor y momento

- **GIVEN** una sucursal vacía que se puede desactivar
- **WHEN** un owner la desactiva
- **THEN** la sucursal queda con la autoría de la baja apuntando a ese usuario y con el momento de la baja registrado

#### Scenario: Las sucursales preexistentes quedan sin autoría y así se muestran

- **GIVEN** una sucursal creada antes de este cambio
- **WHEN** se consulta su autoría
- **THEN** la autoría es nula, y la interfaz la presenta como "no registrado" en lugar de dejar el dato en blanco

---

### Requirement: El ciclo de vida de la sucursal deja rastro en el registro de auditoría

El sistema SHALL registrar en el log de auditoría de la plataforma el ciclo de vida completo de cada sucursal: alta, edición, desactivación, reactivación, cierre operacional y apertura operacional.

Las columnas de autoría contestan "quién la creó" y "quién la dio de baja", pero retienen un solo valor. La pregunta "quién le cambió el nombre y cuándo" sólo la puede contestar un registro histórico. Hoy el log de auditoría **no recibe nada** del ciclo de vida de sucursales.

Cada registro SHALL identificar el **tipo de entidad** y el **identificador de la sucursal**, y SHALL llevar en su campo de metadatos los datos del cambio suficientes para reconstruirlo.

Escribir en ese log SHALL NOT generar notificaciones al usuario: las notificaciones de la interfaz salen de su propia tabla, no de este registro.

#### Scenario: Renombrar una sucursal queda registrado

- **GIVEN** una sucursal existente
- **WHEN** un owner le cambia el nombre
- **THEN** el registro de auditoría contiene una entrada de edición con el identificador de la sucursal, el autor y los datos del cambio

#### Scenario: El alta y la baja quedan registradas

- **GIVEN** una cuenta con el módulo de sucursales
- **WHEN** se crea una sucursal y más tarde se la desactiva
- **THEN** el registro de auditoría contiene una entrada de alta y una de baja, ambas con el identificador de la sucursal y su autor

#### Scenario: El registro no produce notificaciones al usuario

- **GIVEN** un usuario con la bandeja de notificaciones abierta
- **WHEN** se registra el ciclo de vida de una sucursal en el log de auditoría
- **THEN** no aparece ninguna notificación nueva para ese usuario

---

### Requirement: La confirmación de baja muestra el contenido de la sucursal antes de preguntar

El sistema SHALL mostrar, antes de pedir la confirmación de baja de una sucursal, **qué contiene** esa sucursal, y SHALL NOT ofrecer un botón de confirmación que vaya a fallar.

Hoy la confirmación dice únicamente que los registros históricos se conservan — una frase tranquilizadora que en el incidente resultó ser lo único que la usuaria leyó antes de dejar su negocio invendible. Si la sucursal tiene contenido, la confirmación SHALL informarlo y SHALL ofrecer el camino a la transferencia de stock en lugar de un botón de confirmar que el sistema va a rechazar.

La superficie SHALL ser la pantalla de sucursales, en la acción de baja de cada sucursal listada.

#### Scenario: Confirmación de baja de una sucursal con mercadería

- **GIVEN** una sucursal con existencias
- **WHEN** el owner activa la acción de baja desde la pantalla de sucursales
- **THEN** el diálogo informa cuánto contiene la sucursal y ofrece ir a transferir el stock, sin ofrecer confirmar la baja

#### Scenario: Confirmación de baja de una sucursal vacía

- **GIVEN** una sucursal sin contenido operativo
- **WHEN** el owner activa la acción de baja
- **THEN** el diálogo informa que la sucursal está vacía y ofrece confirmar

#### Scenario: La autoría es visible en el listado de sucursales

- **GIVEN** una sucursal creada desde la interfaz por un usuario conocido
- **WHEN** un miembro de la cuenta abre la pantalla de sucursales
- **THEN** ve quién la creó, y en las inactivas, quién la desactivó y cuándo

---

### Requirement: Asociación opcional de operaciones a una sucursal

El sistema SHALL permitir registrar compras y gastos, y los movimientos de stock que generan las compras, con un `branch_id` opcional. Si `branch_id` es NULL, la operación pertenece a la cuenta pero no a una sucursal específica.

Para el gasto, el **alta** resuelve la sucursal informada o, si no se informa ninguna, la principal de la cuenta (capability `expense-operation`, requirement «El gasto persiste su sucursal»); los gastos históricos y la edición de un gasto siguen admitiendo `NULL` según esa misma capability.

La venta NO admite esta asociación opcional: toda venta queda registrada en una sucursal (requirement «Toda venta queda registrada en una sucursal»).

#### Scenario: Compra creada sin sucursal asignada

- **GIVEN** un formulario de compra sin sucursal seleccionada
- **WHEN** el usuario registra la compra
- **THEN** la fila en `purchases` tiene `branch_id = NULL`

#### Scenario: Venta creada con sucursal asignada

- **GIVEN** un formulario de venta con una sucursal seleccionada
- **WHEN** el usuario registra la venta
- **THEN** la fila en `sales` tiene `branch_id` igual al id de la sucursal seleccionada

#### Scenario: Venta creada sin sucursal elegida

- **GIVEN** una venta registrada sin elegir sucursal
- **WHEN** se persiste la venta
- **THEN** la fila en `sales` tiene `branch_id` igual a la sucursal principal de la cuenta, nunca `NULL`

#### Scenario: Venta de una cuenta sin módulo de sucursales

- **GIVEN** un usuario cuyo plan no incluye el módulo de sucursales, de modo que el formulario no muestra el selector
- **WHEN** registra una venta
- **THEN** la fila en `sales` tiene `branch_id` igual a la sucursal principal de la cuenta (`c26_default_branch`): su única sucursal si tiene una sola ("Casa Central" si es la que creó el alta de la cuenta), o la más antigua operativa si conserva varias de un plan anterior

---

### Requirement: Filtro de dashboard por sucursal

El sistema SHALL filtrar todos los KPIs y datos del dashboard por la sucursal seleccionada en el header, propagado vía URL query param `branch`.

#### Scenario: Dashboard sin filtro de sucursal muestra toda la cuenta

- **GIVEN** un usuario PRO con 2 sucursales
- **WHEN** accede a `/dashboard` sin query param `branch`
- **THEN** los KPIs consolidan datos de todas las sucursales + operaciones sin sucursal (account_id completo)

#### Scenario: Dashboard filtrado por sucursal muestra solo esa sucursal

- **GIVEN** un usuario PRO que selecciona la sucursal "Mendoza Centro" (id = X)
- **WHEN** el header propaga `?branch=X` a la URL
- **THEN** los KPIs y tablas solo muestran operaciones con `branch_id = X`

#### Scenario: URL con branch inválido o de otra cuenta es ignorado

- **GIVEN** un usuario que manipula la URL con un `branch` id de otra cuenta
- **WHEN** el servidor resuelve el filtro
- **THEN** el filtro es ignorado (la RLS aísla la sucursal) y el dashboard muestra toda la cuenta

---

### Requirement: Reporte por sucursal

El sistema SHALL proveer un reporte en `/reportes/sucursal` que desglosa ventas, gastos y cantidad de operaciones por sucursal para el período seleccionado, incluyendo una fila para "Sin sucursal" (operaciones con `branch_id = NULL`).

#### Scenario: Reporte muestra totales por sucursal

- **GIVEN** un período seleccionado con ventas en 2 sucursales y ventas sin sucursal
- **WHEN** el usuario accede a `/reportes/sucursal`
- **THEN** la tabla muestra 3 filas: una por cada sucursal activa + "Sin sucursal", con totales de ventas y gastos

#### Scenario: Cuenta no-PRO no puede acceder al reporte por sucursal

- **GIVEN** un usuario con plan `avanzado`
- **WHEN** intenta navegar a `/reportes/sucursal`
- **THEN** ve el componente `PlanGate` con CTA de upgrade a PRO

---

### Requirement: Visualización del stock por sucursal en la página de sucursales

El sistema SHALL mostrar en `/sucursales` el stock total asignado a cada sucursal (suma de `branch_stock.quantity` de todos los productos de esa sucursal) como indicador de inventario.

#### Scenario: Card de sucursal muestra productos con stock asignado

- **GIVEN** una sucursal A con `branch_stock` para 4 productos (distintas cantidades)
- **WHEN** el owner navega a `/sucursales`
- **THEN** la card de la sucursal A muestra "4 productos con stock asignado" o equivalente

#### Scenario: Sucursal sin stock asignado muestra indicador vacío

- **GIVEN** una sucursal B recién creada sin ninguna fila en `branch_stock`
- **WHEN** el owner navega a `/sucursales`
- **THEN** la card de sucursal B muestra "Sin stock asignado" o "0 productos"

---

### Requirement: Acceso a inventario desde la gestión de sucursales

El sistema SHALL proveer en `/sucursales/:id` un enlace o botón "Ver stock" que navega a `/sucursales/:id/stock`.

#### Scenario: Owner accede al inventario desde la página de sucursal

- **GIVEN** el owner está en `/sucursales/:id` (detalle de una sucursal)
- **WHEN** hace clic en "Ver stock"
- **THEN** navega a `/sucursales/:id/stock` con el inventario de esa sucursal

### Requirement: Lifecycle operacional de sucursal (open/close)
El sistema SHALL mantener en cada sucursal un estado operacional `status` (`'active'` | `'closed'`) independiente del soft-delete (`is_active`), con timestamps `opened_at`/`closed_at`, modificable únicamente por `owner`/`admin` vía `rpc_open_branch(p_branch_id)` y `rpc_close_branch(p_branch_id)`.

#### Scenario: Owner cierra una sucursal sin stock
- **GIVEN** una sucursal con `status = 'active'` y `Σ branch_stock = 0`
- **WHEN** el owner llama a `rpc_close_branch`
- **THEN** `status` pasa a `'closed'`, `closed_at = now()`, y la sucursal sigue visible en historial y reportes (`is_active` no cambia)

#### Scenario: Owner reabre una sucursal cerrada
- **GIVEN** una sucursal con `status = 'closed'`
- **WHEN** el owner llama a `rpc_open_branch`
- **THEN** `status` pasa a `'active'` y `opened_at = now()`

#### Scenario: Member no puede operar el lifecycle
- **GIVEN** un usuario con rol `member` en la cuenta
- **WHEN** llama a `rpc_open_branch` o `rpc_close_branch`
- **THEN** la RPC retorna error `P0401` (solo owner/admin)

### Requirement: Cierre de sucursal bloqueado con stock o si es la última operativa
El sistema SHALL rechazar `rpc_close_branch` si la sucursal tiene contenido operativo bloqueante (existencias con cantidad distinta de cero en `branch_stock`, sesión de caja abierta, o transferencias sin completar — error `P0428 branch_has_stock`, mismo predicado y mismo código que la desactivación, ver `branch-decommission-guard`) o si es la última sucursal con `status = 'active'` de la cuenta (error `P0409 last_active_branch`, sin cambios).

#### Scenario: Cierre con stock es rechazado
- **GIVEN** una sucursal con 5 unidades de algún producto en `branch_stock`
- **WHEN** el owner llama a `rpc_close_branch`
- **THEN** la RPC retorna `P0428 branch_has_stock` y el estado no cambia (transferir el stock primero)

#### Scenario: No se puede cerrar la única sucursal operativa
- **GIVEN** una cuenta cuya única sucursal con `status = 'active'` es la default
- **WHEN** el owner intenta cerrarla
- **THEN** la RPC retorna `P0409 last_active_branch`

### Requirement: Operaciones solo contra sucursales operativas
El sistema SHALL rechazar ventas, compras, ajustes y transferencias que referencien explícitamente una sucursal con `status = 'closed'`, con error `P0422 branch_closed`.

#### Scenario: Venta en sucursal cerrada falla
- **GIVEN** una sucursal con `status = 'closed'`
- **WHEN** se registra una venta con `p_branch_id` de esa sucursal
- **THEN** la RPC retorna `P0422 branch_closed` y no inserta ninguna fila

#### Scenario: Transferencia hacia o desde sucursal cerrada falla
- **GIVEN** una transferencia cuyo origen o destino tiene `status = 'closed'`
- **WHEN** se llama a `rpc_transfer_stock`
- **THEN** la RPC retorna `P0422 branch_closed` y no modifica ningún ledger

#### Scenario: UI muestra estado y acciones de lifecycle
- **GIVEN** el owner navega a `/sucursales/:id`
- **WHEN** la página carga
- **THEN** ve el badge de estado (`Activa`/`Cerrada`), el botón Abrir/Cerrar con confirmación, y el listado de transferencias de la sucursal

### Requirement: El usuario es avisado cuando cambia su sucursal por defecto

El sistema SHALL avisar al usuario, mediante una notificación no bloqueante, cuando la sucursal por defecto de su cuenta cambió respecto de la última vez que la vio en esa pestaña.

`c26_default_branch(p_account_id)` resuelve la sucursal por defecto (la "sucursal principal") como la sucursal más antigua por `created_at ASC` que está activa (`is_active`) **y operativa** (`status = 'active'`). Si ninguna cumple las dos condiciones, cae a la más antigua de la cuenta.

El cliente SHALL resolverla con la misma regla, desde una única definición compartida (`frontend/lib/default-branch.ts`) que consumen este aviso, el selector de sucursal de la venta, el opt-in de caja y el punto de venta (POS). Así nunca presenta como principal, ni usa para operar, una sucursal cerrada que el servidor saltea mientras exista una sucursal activa y operativa.

Límite declarado: el cliente sólo conoce las sucursales activas. Cuando ninguna sucursal activa está operativa, el cliente presenta la primera activa (cerrada) y el servidor cae a la más antigua de todas, incluidas las inactivas. En ese estado la venta sin sucursal elegida se rechaza (requirement «Toda venta queda registrada en una sucursal»), así que la diferencia no llega a persistirse.

Desactivar o cerrar la sucursal que hoy ocupa ese lugar hace que el sistema empiece a resolver otra por defecto de forma silenciosa. Sin este aviso, el usuario no tiene manera de enterarse de que las operaciones sin sucursal explícita empezaron a caer en un lugar distinto. Este requirement no reemplaza al guard de `branch-decommission-guard` (que impide desactivar una sucursal con contenido operativo): cubre el caso, legítimo, en que la sucursal por defecto cambia sin ningún contenido bloqueante de por medio.

El aviso SHALL persistirse por pestaña (no por dispositivo ni de forma permanente): lo que importa es el cambio ocurrido dentro de la sesión activa, no reabrir en cada pestaña nueva un cambio que ya pasó.

#### Scenario: Primera carga de la pestaña, sin aviso previo
- **GIVEN** un usuario que abre la aplicación en una pestaña nueva
- **WHEN** el sistema resuelve la sucursal por defecto de su cuenta por primera vez en esa pestaña
- **THEN** no se muestra ningún aviso, y la sucursal resuelta queda registrada para comparaciones futuras en esa pestaña

#### Scenario: La sucursal por defecto no cambió
- **GIVEN** un usuario cuya pestaña ya registró la sucursal por defecto actual de su cuenta
- **WHEN** el sistema vuelve a resolverla y es la misma
- **THEN** no se muestra ningún aviso

#### Scenario: La sucursal por defecto cambió
- **GIVEN** un usuario cuya pestaña registró una sucursal por defecto, y esa sucursal dejó de serlo (por ejemplo, se desactivó)
- **WHEN** el sistema resuelve la nueva sucursal por defecto
- **THEN** se muestra un aviso no bloqueante que nombra la nueva sucursal por defecto, y la pestaña actualiza su registro a la nueva sucursal

#### Scenario: Una sucursal cerrada no es la sucursal por defecto
- **GIVEN** una cuenta cuya sucursal más antigua está activa pero cerrada (`status = 'closed'`) y una segunda sucursal activa y operativa
- **WHEN** el cliente resuelve la sucursal por defecto
- **THEN** resuelve la segunda, la misma que `c26_default_branch`, y es la que nombran el aviso y el selector de la venta, la que usa el opt-in de caja para buscar la sesión, y la que el POS usa para su caja y envía como sucursal de la venta

### Requirement: Toda venta queda registrada en una sucursal

El sistema SHALL registrar en una sucursal toda venta que se cree o se edite por el formulario, la API o sus funciones de base: la que el usuario eligió o, si no eligió ninguna, la sucursal principal de la cuenta (`c26_default_branch`). La sucursal escrita en la fila de `sales` y en su movimiento de stock SHALL ser la misma de la que se descontó el stock. En el alta SHALL ser, además, la misma contra la que se validó el stock y se resolvieron la caja y el movimiento bancario. La edición conserva su validación de stock contra el total de la cuenta, sin cambios.

Si no se eligió sucursal y la cuenta no tiene ninguna sucursal operativa a la cual resolver (no tiene sucursales, o todas están inactivas o cerradas), el alta y la edición SHALL rechazarse con `P0422 no_branch_found` sin persistir nada. Es el mismo token que usan el POS y "Facturar venta manual" cuando la cuenta no tiene ninguna sucursal. Con sucursales pero ninguna operativa, esos dos caminos no cambian y se comportan distinto (el POS rechaza la sucursal resuelta por cerrada o no encontrada; "Facturar venta manual" no valida que opere). El sistema NO SHALL registrar una venta en una sucursal inactiva o cerrada por resolución implícita, igual que rechaza una sucursal inactiva o cerrada elegida explícitamente.

Aplica a los dos caminos de alta del formulario y la API (`rpc_create_sale_operation_v2` y la rama legacy de `rpc_create_sale_operation`) y a la edición (`rpc_atomic_update_sale_operation`). El POS, la confirmación de órdenes y los presupuestos aceptados ya registran la sucursal resuelta y no cambian. Queda como excepción nombrada la pareja legacy `rpc_atomic_create_sale`, que inserta ventas sin sucursal, sólo la puede ejecutar `service_role`, ningún código la llama y se retira en un change posterior junto con la restricción `NOT NULL`.

Este requirement cumple RN-93 y DEC-19 para la venta: «toda venta, compra, gasto y movimiento de caja lleva `branch_id`».

#### Scenario: Venta sin sucursal elegida queda en la principal
- **GIVEN** una cuenta con la sucursal principal A y otra sucursal B, y una venta de dos líneas (una con producto, una de servicio) registrada sin elegir sucursal
- **WHEN** se registra la venta
- **THEN** todas las filas de `sales` de la operación tienen `branch_id = A`, el movimiento de stock de la línea con producto tiene `branch_id = A`, el stock baja en A y B no se toca

#### Scenario: Venta por la API sin el campo de sucursal
- **WHEN** se llama a `POST /sales` sin `branch_id` (o con `branch_id: null`)
- **THEN** la venta queda registrada en la sucursal principal de la cuenta

#### Scenario: Una sucursal cerrada no recibe las ventas sin sucursal elegida
- **GIVEN** una cuenta cuya sucursal más antigua A está cerrada y una sucursal B activa y operativa
- **WHEN** se registra una venta sin elegir sucursal
- **THEN** la venta, su movimiento y el descuento de stock quedan en B

#### Scenario: La venta, su stock, su caja y su banco quedan en la misma sucursal
- **GIVEN** una venta sin sucursal elegida, pagada con una forma de pago bancaria
- **WHEN** se registra
- **THEN** la fila de `sales`, su movimiento de stock y su movimiento bancario llevan la misma sucursal, la principal

#### Scenario: El camino legacy del alta se comporta igual
- **GIVEN** una cuenta con el flag `sale_items_rpc_v2` apagado
- **WHEN** se registra una venta sin elegir sucursal
- **THEN** la venta y su movimiento de stock quedan en la sucursal principal, igual que por el camino vigente

#### Scenario: Cuenta sin ninguna sucursal
- **GIVEN** una cuenta sin ninguna sucursal
- **WHEN** se intenta registrar una venta sin sucursal
- **THEN** la operación se rechaza con `P0422 no_branch_found` y no se persiste ninguna fila de venta, de idempotencia ni de stock

#### Scenario: Cuenta sin ninguna sucursal operativa
- **GIVEN** una cuenta cuyas sucursales están todas desactivadas o cerradas
- **WHEN** se intenta registrar o editar una venta sin elegir sucursal
- **THEN** la operación se rechaza con `P0422 no_branch_found`, no se persiste nada y no se descuenta stock de ninguna sucursal

#### Scenario: Editar una venta informando "sin sucursal" la registra en la principal
- **GIVEN** una venta registrada en la sucursal B
- **WHEN** se edita informando la sucursal como `NULL`
- **THEN** la operación resultante queda en la sucursal principal, el stock vuelve a B y se descuenta de la principal

#### Scenario: Editar una venta histórica sin sucursal la registra en la principal
- **GIVEN** una venta con `branch_id` nulo que la asignación de históricos no pudo resolver en su momento
- **WHEN** se edita sin informar sucursal
- **THEN** la operación resultante queda en la sucursal principal

### Requirement: Las ventas históricas sin sucursal se asignan a una sucursal

El sistema SHALL asignar una sucursal, una única vez y de forma idempotente, a toda venta histórica con `branch_id` nulo de una cuenta que tenga sucursales. La asignación SHALL resolverse por **operación**: todas las filas nulas de una operación reciben la misma sucursal. El orden de precedencia es este:

1. la única sucursal que ya tengan las demás filas de su misma operación;
2. la sucursal de su orden de venta, si la operación pasó por "Facturar venta manual" y su comprobante ya salió (autorizado, o pendiente con marca de envío a ARCA);
3. la única sucursal que ya registren los movimientos de stock de tipo venta de esas filas;
4. la sucursal de su orden de venta, si la operación pasó por "Facturar venta manual" y su comprobante no salió;
5. si no, la sucursal principal vigente de la cuenta al aplicar la asignación.

Las reglas 3, 4 y 5 aplican sólo si la sucursal que resulta está activa y operativa (`is_active AND status = 'active'`); si no, se pasa a la siguiente. Las reglas 1 y 2 aplican aunque la sucursal ya no opere, porque la operación o su factura ya viven en ella.

Los movimientos de stock de tipo venta con `branch_id` nulo de esas ventas SHALL tomar la sucursal asignada sólo cuando se puede demostrar que de ahí salió el stock: cuando se registró el movimiento, la sucursal asignada era la única de la cuenta. Rige la excepción declarada en la capability `inventory-single-ledger`. Los demás SHALL conservar `branch_id` nulo y la asignación SHALL contarlos. Los movimientos que ya registran una sucursal NO SHALL modificarse; cuando esa sucursal difiere de la asignada a su venta, la asignación SHALL informarlo como discrepancia. También SHALL informar las ventas que quedan en una sucursal distinta de la de su orden.

La asignación NO SHALL tocar los movimientos de caja, de banco ni de cuenta corriente, los asientos, los eventos, las órdenes, las líneas ni el stock. Tampoco SHALL disparar notificaciones, eventos ni registros de analítica. SHALL dejar una fila de auditoría por cuenta afectada con las ventas y los movimientos asignados. SHALL informar, sin abortar, el residuo que no pueda resolver (filas sin cuenta, cuentas sin sucursal operativa a las que no alcanzan las reglas 1 y 2) y las ventas con evidencia de otra sucursal.

#### Scenario: Cuenta con una sola sucursal
- **GIVEN** una venta histórica con `branch_id` nulo de una cuenta con una única sucursal operativa
- **WHEN** se aplica la asignación
- **THEN** la venta queda en esa sucursal

#### Scenario: Cuenta con varias sucursales
- **GIVEN** una venta histórica con `branch_id` nulo de una cuenta con las sucursales A (principal) y B, sin movimiento de stock con sucursal ni orden
- **WHEN** se aplica la asignación
- **THEN** la venta queda en A

#### Scenario: Operación con filas de distinta sucursal
- **GIVEN** una operación con una fila en la sucursal operativa B y otra con `branch_id` nulo
- **WHEN** se aplica la asignación
- **THEN** la fila nula queda en B y "Facturar venta manual" sobre esa operación ya no se rechaza por "distinta sucursal"

#### Scenario: Operación con filas en una sucursal cerrada
- **GIVEN** una operación con una fila en la sucursal B, hoy cerrada, y otra con `branch_id` nulo
- **WHEN** se aplica la asignación
- **THEN** la fila nula queda en B, la operación deja de ser mixta y la asignación lo cuenta como asignación a una sucursal no operativa

#### Scenario: Una venta ya facturada sigue a su factura
- **GIVEN** una venta histórica con `branch_id` nulo cuya operación tiene una orden de venta en la sucursal B con su comprobante autorizado, y cuyo movimiento de stock registró la sucursal X
- **WHEN** se aplica la asignación
- **THEN** la venta queda en B, la misma sucursal que su orden y su factura, el movimiento conserva X y la asignación informa la discrepancia entre la venta y su movimiento

#### Scenario: La venta sigue a la sucursal que ya registró su movimiento de stock
- **GIVEN** una venta histórica con `branch_id` nulo, sin comprobante emitido, editada en su momento, cuyo movimiento de stock de tipo venta registró la sucursal operativa X, en una cuenta cuya principal hoy es A
- **WHEN** se aplica la asignación
- **THEN** la venta queda en X, y borrarla o editarla repone el stock en X

#### Scenario: Una venta pasada por "Facturar venta manual" sin factura emitida
- **GIVEN** una venta histórica con `branch_id` nulo, sin movimiento de stock con sucursal, cuya operación tiene una orden de venta sin comprobante emitido en la sucursal operativa B, aunque la principal sea A
- **WHEN** se aplica la asignación
- **THEN** la venta queda en B, la misma sucursal que su orden

#### Scenario: La venta queda distinta de su orden sin factura hasta la próxima edición
- **GIVEN** una venta histórica con `branch_id` nulo cuyo movimiento de stock registró la sucursal operativa X y cuya orden, sin comprobante emitido, está en B
- **WHEN** se aplica la asignación
- **THEN** la venta queda en X, la orden conserva B y la asignación informa la discrepancia entre la venta y su orden

#### Scenario: Una regla que da una sucursal no operativa se saltea
- **GIVEN** una venta histórica con `branch_id` nulo cuya orden de venta, sin comprobante emitido, está en una sucursal hoy cerrada, en una cuenta con la principal A operativa
- **WHEN** se aplica la asignación
- **THEN** la venta queda en A y la asignación cuenta la regla salteada

#### Scenario: El movimiento de stock sigue a la venta cuando su origen es demostrable
- **GIVEN** una venta histórica con `branch_id` nulo y su movimiento de stock también nulo, de una cuenta cuya única sucursal cuando se registró la venta era A
- **WHEN** se aplica la asignación y después se borra esa venta
- **THEN** la venta y el movimiento quedan en A, y el borrado repone el stock en A

#### Scenario: El movimiento de stock de origen incierto queda nulo
- **GIVEN** una venta histórica con `branch_id` nulo y su movimiento de stock también nulo, de una cuenta que ya tenía otra sucursal además de la asignada cuando se registró la venta
- **WHEN** se aplica la asignación
- **THEN** la venta queda en su sucursal asignada, el movimiento conserva `branch_id` nulo y la asignación lo cuenta como de origen incierto

#### Scenario: Un movimiento con sucursal distinta de la venta se informa
- **GIVEN** una venta histórica con `branch_id` nulo cuyo movimiento de stock registró una sucursal hoy cerrada, y la venta queda asignada a otra sucursal por una regla posterior
- **WHEN** se aplica la asignación
- **THEN** el movimiento conserva su sucursal y la asignación informa la discrepancia entre la venta y su movimiento

#### Scenario: Una venta sin cuenta queda como residuo informado
- **GIVEN** una fila de `sales` con `branch_id` y `account_id` nulos
- **WHEN** se aplica la asignación
- **THEN** la fila conserva `branch_id` nulo, se informa como residuo y la asignación termina sin error

#### Scenario: Una cuenta sin sucursal operativa queda como residuo
- **GIVEN** una venta histórica con `branch_id` nulo, sin otras filas con sucursal en su operación ni orden con comprobante emitido, de una cuenta cuyas sucursales están todas desactivadas o cerradas
- **WHEN** se aplica la asignación
- **THEN** la venta conserva `branch_id` nulo y se informa como residuo

#### Scenario: Reaplicar no cambia nada
- **GIVEN** la asignación ya aplicada
- **WHEN** se ejecuta otra vez
- **THEN** ninguna fila cambia y no se escribe ninguna fila de auditoría nueva

#### Scenario: Sin efectos laterales
- **WHEN** se aplica la asignación
- **THEN** no se crean eventos, notificaciones ni registros de analítica, y los movimientos de caja, de banco y de cuenta corriente y los asientos quedan intactos

#### Scenario: Rastro de lo asignado por el sistema
- **WHEN** la asignación modifica ventas de una cuenta
- **THEN** queda una fila de auditoría de esa cuenta que lista las ventas y los movimientos asignados, cuántos se resolvieron por cada regla, cuántos se asignaron a una sucursal no operativa por las reglas 1 y 2, cuántas reglas se saltearon, cuántos movimientos quedaron nulos por origen incierto y cuántas discrepancias quedaron con los movimientos y con las órdenes

### Requirement: El selector de sucursal de la venta ofrece la principal en lugar de "Sin sucursal"

Toda superficie que registre una venta con un selector de sucursal (hoy, el formulario de venta) SHALL mostrar ese selector con el rótulo «Sucursal» asociado al control y sin la opción «Sin sucursal (general)». De entrada SHALL mostrar seleccionada la sucursal que el servidor va a usar si el usuario no elige otra: la del documento de origen, cuando la venta nace de uno que ya tiene sucursal (por ejemplo, la conversión de un presupuesto), o si no la sucursal principal de la cuenta, resuelta con la definición compartida del cliente. La principal SHALL identificarse como «(principal)» en la lista. Mientras las sucursales cargan, el selector NO SHALL mostrar el texto «Sin sucursal».

Si el usuario no cambia la selección, la venta se registra en la sucursal mostrada. Si elige otra sucursal, se registra en esa.

Los formularios de compra y de gasto, y el importador de gastos, que comparten el componente, SHALL conservar su opción sin sucursal con su texto actual (compra y gasto: «Sin sucursal (general)»; importador de gastos: «Sin sucursal por defecto»). El selector SHALL leerse y operarse en escritorio y en móvil, con tema claro y oscuro.

#### Scenario: El alta abre con la principal seleccionada
- **GIVEN** una cuenta con módulo de sucursales y las sucursales A (principal) y B
- **WHEN** el usuario abre "Nueva venta"
- **THEN** el selector rotulado "Sucursal" muestra A marcada "(principal)" y la lista no ofrece "Sin sucursal (general)"

#### Scenario: Sin tocar el selector, la venta queda en la principal
- **WHEN** el usuario registra la venta sin cambiar el selector
- **THEN** la venta queda registrada en A

#### Scenario: Elegir otra sucursal la registra en esa
- **WHEN** el usuario elige B y registra la venta
- **THEN** la venta queda registrada en B

#### Scenario: Una venta que nace de un documento con sucursal muestra la de ese documento
- **GIVEN** una superficie que registra una venta a partir de un documento de la sucursal B, en una cuenta cuya principal es A
- **WHEN** el usuario la abre
- **THEN** el selector muestra B, y si la venta se registra sin cambiar el selector queda en B

#### Scenario: Compra, gasto e importador conservan su opción
- **WHEN** el usuario abre el formulario de compra, el de gasto o el importador de gastos
- **THEN** su selector de sucursal sigue ofreciendo su opción sin sucursal con el mismo texto que antes de este cambio

#### Scenario: Cuenta sin módulo de sucursales
- **GIVEN** una cuenta cuyo plan no incluye el módulo de sucursales
- **WHEN** el usuario registra una venta
- **THEN** el formulario no muestra ni el selector ni su rótulo, y la venta queda en la sucursal principal de la cuenta

#### Scenario: La edición muestra la sucursal de la venta
- **GIVEN** una venta registrada en B
- **WHEN** el usuario la edita
- **THEN** el selector muestra B y no ofrece "Sin sucursal (general)"

#### Scenario: Escritorio y móvil, tema claro y oscuro
- **WHEN** el formulario de venta se abre en escritorio y en un ancho de 375 px, con tema claro y con tema oscuro
- **THEN** el rótulo, la sucursal seleccionada y la marca "(principal)" se leen con contraste AA y el selector se opera sin desborde horizontal

