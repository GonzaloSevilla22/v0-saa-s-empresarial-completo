## ADDED Requirements

### Requirement: La política de transiciones es inevadible a nivel de base de datos

El sistema SHALL rechazar, en la propia base de datos, todo cambio del estado de un documento cuya transición `(document_type, from_status, to_status)` no esté presente en `document_status_transitions`. El rechazo SHALL producirse cualquiera sea el camino de escritura: llamada a un RPC, `UPDATE` directo emitido por el cliente vía la API de datos, `UPDATE` emitido por el backend, o `UPDATE` emitido por un rol que ignore RLS. La política NOT SHALL depender de que el escritor invoque el helper de registro.

El enforcement SHALL cubrir los mismos tipos de documento que declara el catálogo, y SHALL abortar la transacción de negocio completa cuando la transición es inválida, sin dejar el documento en el estado no catalogado.

#### Scenario: Un UPDATE directo a un estado no catalogado es rechazado

- **WHEN** cualquier escritor emite un `UPDATE` que cambia el estado de un documento a un estado destino que no está catalogado para su tipo y estado de origen
- **THEN** la base de datos aborta la operación con un error de conflicto de estado y el documento conserva su estado anterior

#### Scenario: Una transición catalogada sigue siendo posible

- **WHEN** un camino de escritura vigente ejecuta una transición presente en el catálogo
- **THEN** la operación se completa con éxito y el enforcement no la interfiere

#### Scenario: El enforcement alcanza a los escritores que ignoran RLS

- **WHEN** el `UPDATE` de estado proviene de una conexión cuyo rol no está sujeto a las políticas de fila (por ejemplo el pool del backend o un rol de servicio)
- **THEN** la transición se valida igualmente contra el catálogo y se rechaza si no está catalogada

#### Scenario: Un estado terminal no admite salida

- **WHEN** se intenta cambiar el estado de un documento que ya está en un estado marcado terminal
- **THEN** la operación es rechazada, porque no existe transición saliente catalogada desde ese estado

### Requirement: El enforcement valida sin registrar, y solo cuando el estado cambia

El enforcement estructural SHALL limitarse a validar la transición: NOT SHALL insertar filas en `document_status_history`. El registro del historial SHALL seguir siendo responsabilidad exclusiva del helper de escritura invocado por las operaciones de negocio, que es el único que dispone del motivo (`reason`) y del actor de la transición.

El enforcement NOT SHALL intervenir en actualizaciones que no modifiquen el estado del documento: un `UPDATE` sobre otras columnas SHALL completarse con normalidad, incluso sobre documentos en estado terminal.

#### Scenario: Una transición de negocio produce exactamente una fila de historial

- **WHEN** una operación de negocio registra su transición mediante el helper de escritura y luego actualiza el estado del documento
- **THEN** el historial contiene exactamente una fila para esa transición, sin duplicado originado por el enforcement

#### Scenario: Actualizar otras columnas de un documento terminal no es interferido

- **WHEN** se actualizan columnas distintas del estado sobre un documento en estado terminal
- **THEN** la actualización se completa con éxito y no se evalúa ninguna transición

### Requirement: Las excepciones al enforcement son explícitas y auditables

El sistema NOT SHALL exponer ningún mecanismo de tiempo de ejecución que permita a la aplicación eludir el enforcement (por ejemplo un parámetro de sesión de bypass), porque un mecanismo alcanzable desde la aplicación restituye exactamente la evasión que el enforcement elimina. Toda excepción legítima (corrección de datos, backfill) SHALL realizarse deshabilitando explícitamente el enforcement dentro de una migración versionada, operación que requiere propiedad de la tabla y queda visible en la revisión del cambio, y SHALL volver a habilitarlo en la misma migración.

#### Scenario: No existe un bypass invocable desde la aplicación

- **WHEN** un cliente autenticado o el backend intentan desactivar el enforcement por medios de tiempo de ejecución antes de emitir un `UPDATE` de estado
- **THEN** la transición se valida igual contra el catálogo y se rechaza si no está catalogada

#### Scenario: El enforcement queda habilitado tras una excepción de migración

- **WHEN** una migración deshabilita el enforcement para ejecutar una corrección de datos
- **THEN** la misma migración lo vuelve a habilitar, y la verificación estructural del sistema detecta cualquier enforcement que haya quedado deshabilitado
