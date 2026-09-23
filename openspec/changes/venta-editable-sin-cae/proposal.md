## Why

Pedido textual del PO (2026-09-22): *"necesito que las ventas se puedan modificar, sólo si ésta no tiene el CAE, es decir no se envió al ARCA aún"*.

La regla vigente es **más estricta que eso**: `rpc_atomic_update_sale_operation` (edición, `20260930000001` F2) y `rpc_delete_sale_operation` (borrado, `20261005000001`) rechazan con `P0423` en cuanto la `sales_orders` de la venta tiene un `fiscal_documents` en `pending_cae` **o** `authorized`. O sea: la venta queda inmutable desde el instante en que se aprieta "Facturar", aunque ARCA todavía no haya recibido nada y quizá no lo reciba por minutos. El usuario que se equivocó en una cantidad y ya emitió no tiene ninguna salida: ni editar, ni borrar y rehacer.

Hasta `fiscal-riesgos-residuales` (#580) eso era defendible, porque no existía forma de saber si el pedido había salido. Ahora sí: `cae_submit_started_at` es la marca que se persiste **antes** del `FECAESolicitar` (en su propia transacción, para sobrevivir a que el proceso muera), y `cae_submit_unconfirmed_at` marca el congelado. El instante del envío pasó a ser un dato, no una suposición — y con él, "emitido" e "inmutable" dejaron de ser lo mismo.

## What Changes

- **Estado terminal nuevo `voided`** en `fiscal_documents` (4º valor del CHECK) + fila `pending_cae → voided` en el catálogo FSM (terminal, con motivo obligatorio). Ninguna otra transición hacia o desde `voided`: el catálogo ES el guard de `authorized → voided`. NO es una nota de crédito — un `voided` nunca llegó a ARCA.
- **Helper `_fiscal_void_pending_for_sale_edit`**: única definición de la regla, compartida por la edición y el borrado. Anula el comprobante pendiente NO enviado en la misma transacción de la edición/borrado, para que el relay no facture importes viejos; bloquea con `P0423` y **tres tokens distintos** (autorizado / enviado o congelado / tomado por el relay) porque la acción que le queda al usuario es distinta en cada caso.
- **Exclusión mutua con los otros dos escritores del comprobante**: toma el lock de la orden ANTES de leer el vínculo (excluye a la emisión, que toma ese mismo lock antes de crear el comprobante) y con eso unifica el orden de locks a orden → comprobante (sin ciclo = sin deadlock); pide el lock del comprobante con NOWAIT (nunca colgar un request de usuario detrás de un round-trip SOAP); y re-evalúa la condición bajo el lock DENTRO de la sentencia que escribe. Guard de tenencia en ese mismo punto de paso.
- **Re-emisión habilitada** (`rpc_emit_sale_invoice`): el guard de idempotencia pasa de "¿hay comprobante?" a una **allow-list** de los estados que no tuvieron efecto fiscal (`rejected`, `voided`). Efecto lateral declarado: cierra el bug preexistente de que una orden con un único comprobante `rejected` no se podía volver a facturar nunca.
- **Superficie frontend completa** (regla dura del proyecto): read model del estado fiscal en el listado (`is_fiscally_locked` reemplaza `is_invoiced`, más la evidencia cruda del comprobante), badge con el estado anulado, aviso + confirmación explícita antes de anular, motivo real en el lápiz/tacho deshabilitados, y "Volver a facturar" después de anular.
- **El relay no cambia de comportamiento**, y sus dos puntos de paso (`claim_pending`, `mark_submit_started`) conservan su filtro por `status = 'pending_cae'` —lo único que impide que un anulado llegue a ARCA— ahora con gate propio. Sí deja de tratar como fallo el caso normal de encontrarse un comprobante anulado en medio del tick.

## Impact

- Capabilities: `afip-fiscal-document` (MODIFIED + ADDED + REMOVED), `operation-delete-compensation` (MODIFIED), `operation-edit-context` (MODIFIED + ADDED).
- Migración: `20261060000001_venta_editable_sin_cae.sql` — CHECK, catálogo FSM, helper nuevo y **tres RPCs reescritas desde su `pg_get_functiondef` vivo** (edición, borrado, emisión), con firma idéntica.
- Gates nuevos en `KPI_Validation.yml`: `test_venta_editable_sin_cae.sql` (introspección, re-emisión, allow-list, carrera contra el lease, tenencia del helper) y `test_venta_editable_sin_cae_race.sh` (tres carreras con dos conexiones reales: contra la emisión abierta, orden de locks, y el relay con la fila tomada).
- Governance: **CRÍTICO** (dominio fiscal: anula comprobantes y toca la RPC de emisión), con tramos MEDIOS en la superficie frontend.
- **BREAKING de dominio declarado**: una venta con comprobante `pending_cae` sin enviar pasa de inmutable a editable/borrable, y su comprobante pasa a anularse. El bloqueo de una venta enviada o autorizada NO se relaja.
