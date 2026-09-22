## MODIFIED Requirements

### Requirement: El borrado consulta los mismos locks que la edición

El sistema SHALL evaluar en el borrado de una operación los mismos predicados de lock que ya gobiernan su edición — comprobante fiscal y dinero posteado en los libros — y SHALL resolverlos de forma diferenciada: el lock por dinero posteado habilita la acción compensando los libros en lugar de impedirla, y el lock fiscal tiene dos resultados según el comprobante haya salido o no hacia ARCA.

El lock fiscal SHALL bloquear con `P0423` cuando el comprobante ya salió hacia ARCA (`authorized`, o `pending_cae` con marca de envío o congelado), y SHALL habilitar la acción anulando el comprobante (`voided`) en la misma transacción cuando todavía no salió. Edición y borrado SHALL compartir una única definición de esa regla, no dos copias.

#### Scenario: Operación con comprobante fiscal ya enviado

- **WHEN** se intenta borrar una operación cuyo comprobante está `authorized`, marcado como enviado o congelado
- **THEN** el sistema rechaza el borrado con `P0423`
- **AND** aplica exactamente el mismo predicado que bloquea la edición

#### Scenario: Operación con comprobante pendiente no enviado

- **WHEN** se borra una operación cuyo comprobante está en `pending_cae` sin marca de envío
- **THEN** el borrado procede y el comprobante queda anulado en la misma transacción
- **AND** la edición de esa misma operación se resuelve igual, por la misma definición

#### Scenario: Operación con dinero posteado y sin comprobante

- **WHEN** se borra una operación bloqueada para edición por tener dinero posteado, pero sin comprobante fiscal
- **THEN** el borrado procede
- **AND** cada libro con movimientos de esa operación recibe su contra-movimiento

## ADDED Requirements

### Requirement: La edición avisa y pide confirmación antes de anular el comprobante pendiente

El formulario de edición de una venta SHALL distinguir en pantalla los tres casos fiscales, y NO SHALL presentarse en solo lectura salvo que la acción esté efectivamente bloqueada.

Cuando el comprobante YA SALIÓ hacia ARCA, el formulario SHALL abrirse en solo lectura con el control de guardado deshabilitado, y el motivo accesible SHALL nombrar la causa REAL —autorizado por ARCA, enviado y esperando respuesta, o congelado— porque la acción que le queda al usuario es distinta en cada caso.

Cuando el comprobante está pendiente y NO salió, el formulario SHALL quedar completamente editable y SHALL avisar, antes de guardar, que guardar va a anular ese comprobante, identificándolo por su número. Ese aviso SHALL presentarse como advertencia y no como error: anular algo que nunca salió hacia ARCA no es destructivo y se puede volver a emitir.

El guardado en ese caso SHALL exigir una confirmación explícita que explique el motivo y la salida (volver a emitir después), y al cerrarse SHALL devolver el foco al control que la abrió, para no obligar a quien navega con teclado a recorrer el formulario de nuevo.

El resultado que la interfaz informa SHALL provenir de la respuesta del servidor y NO de lo que el cliente creía antes de guardar: si la carrera contra el relay hizo que el servidor bloqueara, el usuario SHALL ver el rechazo y nunca un "se anuló" falso.

El listado de ventas SHALL exponer el estado del comprobante —incluido el anulado, con rótulo propio— y SHALL habilitar o deshabilitar las acciones de editar y borrar según el mismo predicado del servidor, nombrando la causa real cuando estén deshabilitadas.

#### Scenario: comprobante pendiente no enviado

- **WHEN** el usuario abre la edición de una venta con comprobante pendiente sin enviar
- **THEN** el formulario está editable y muestra el aviso de que guardar anulará ese comprobante, con su número

#### Scenario: confirmación explícita

- **WHEN** el usuario guarda esa edición
- **THEN** se le pide una confirmación que explica que el comprobante se anula para no emitirse con los importes viejos, y que podrá emitir uno nuevo

#### Scenario: el foco no se pierde al cancelar

- **WHEN** el usuario cancela la confirmación
- **THEN** el foco vuelve al control de guardado que la abrió

#### Scenario: comprobante ya enviado

- **WHEN** el usuario abre la edición de una venta cuyo comprobante ya salió hacia ARCA
- **THEN** el formulario se presenta en solo lectura, con el motivo real nombrado y el control de guardado deshabilitado con su motivo accesible

#### Scenario: el resultado lo dicta el servidor

- **GIVEN** una edición que el cliente creía anulable
- **WHEN** el servidor la rechaza porque el comprobante salió hacia ARCA en el intervalo
- **THEN** la interfaz muestra el rechazo y no informa ninguna anulación
