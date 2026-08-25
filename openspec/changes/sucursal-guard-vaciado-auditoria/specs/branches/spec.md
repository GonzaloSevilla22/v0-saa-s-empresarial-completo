## MODIFIED Requirements

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

## ADDED Requirements

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
