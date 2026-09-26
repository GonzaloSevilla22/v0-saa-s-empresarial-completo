# Tasks — venta-editable-sin-cae

## 1. Base de datos (migración `20261060000001`)

- [x] 1.1 Verificar los cuerpos VIVOS de las tres RPCs a reescribir contra prod y contra el stack local (`pg_get_functiondef`, md5 CR-stripped idéntico en los tres lados) antes de escribir una línea de SQL.
- [x] 1.2 CHECK de `fiscal_documents.status` con el 4º estado `voided` (drop + add idempotente).
- [x] 1.3 Fila `pending_cae → voided` en `document_status_transitions` (terminal, `requires_reason`, `allowed_role NULL`), con `ON CONFLICT` que repite el predicado del índice único PARCIAL (gotcha `42P10`).
- [x] 1.4 Helper `_fiscal_void_pending_for_sale_edit`: única definición de la regla, `SECURITY DEFINER`, ACLs cerradas a `anon`/`authenticated`.
- [x] 1.5 `rpc_atomic_update_sale_operation`: guard fiscal reescrito, descriptor del comprobante anulado en el `RETURN`.
- [x] 1.6 `rpc_delete_sale_operation`: mismo helper, primer guard del borrado.
- [x] 1.7 `rpc_emit_sale_invoice`: allow-list de re-emisión (`rejected`/`voided`), con el lock del comprobante tomado.
- [x] 1.8 Gate de introspección embebido en la migración (falla el deploy si falta cualquier pieza).

## 2. Contrato de concurrencia (cierre del red team 2026-09-22)

- [x] 2.1 El helper toma la ORDEN con `FOR UPDATE` antes de leer el vínculo, y lee `fiscal_document_id` de la fila bloqueada — exclusión contra la emisión (M1).
- [x] 2.2 Orden de locks unificado a `sales_orders → fiscal_documents`, el mismo de la emisión (M2). Verificado que ninguna otra función invierte ese orden.
- [x] 2.3 La edición deja de filtrar las órdenes por `fiscal_document_id IS NOT NULL`: ese filtro se evaluaba sin lock y era el agujero de M1.
- [x] 2.4 Guard de tenencia (`account_id` de la orden vs. el parámetro) en el choke point (m1).
- [x] 2.5 Predicado de la anulación DENTRO del `UPDATE` que escribe (m3).
- [x] 2.6 Cinco aserciones nuevas de introspección sobre los cuerpos vivos, en el gate embebido, sobre el cuerpo sin comentarios y con espacios colapsados.

## 3. Backend (3 capas)

- [x] 3.1 Read model del estado fiscal en el listado de ventas: `is_fiscally_locked` (reemplaza `is_invoiced`) + evidencia cruda del comprobante, con el MISMO predicado que el helper SQL.
- [x] 3.2 `PUT /sales/operation` devuelve `voided_fiscal_document` (schema Pydantic propio); el repository pasa de `execute` a `fetchval` y decodifica el jsonb.
- [x] 3.3 El tick del relay trata el comprobante anulado como camino normal (INFO) y cualquier otro `P0437` como fallo (ERROR), clasificando por el estado REAL releído (m2).

## 4. Frontend

- [x] 4.1 Badge con el estado `voided` ("Anulado (no se envió a ARCA)"), tokens semánticos, sin canal de Realtime.
- [x] 4.2 Badge fail-closed ante un estado desconocido (no rompe el render de la fila) y read model que valida en vez de castear (n1/n2).
- [x] 4.3 Listado: lápiz/tacho habilitados según el predicado del servidor, con el motivo REAL cuando están deshabilitados.
- [x] 4.4 Formulario de edición: banner de aviso (advertencia, no error) identificando el comprobante que se va a anular.
- [x] 4.5 Confirmación explícita antes de guardar, con el motivo y la salida; foco de vuelta al botón que la abrió al cerrarse.
- [x] 4.6 Toast armado con la respuesta del servidor, nunca con lo que el cliente creía.
- [x] 4.7 "Volver a facturar" después de anular.
- [x] 4.8 Verificación visual en desktop + mobile, claro + oscuro.

## 5. Gates

- [x] 5.1 `test_venta_editable_sin_cae.sql`: introspección, re-emisión con número nuevo, allow-list, carrera contra el lease, tenencia del helper. Aborta si el setup falla (nunca degrada en silencio).
- [x] 5.2 `test_venta_editable_sin_cae_race.sh`: tres carreras con dos conexiones reales — emisión abierta (e), orden de locks (f), relay con la fila tomada (c).
- [x] 5.3 Extensión de `test_edicion_preserva_contexto.sql` y `test_delete_guard_ledgers.sql` con los casos del predicado nuevo.
- [x] 5.4 Las dos cláusulas `status = 'pending_cae'` del relay ancladas con gate propio.
- [x] 5.5 Los dos gates nuevos cableados en `KPI_Validation.yml`.

## 6. Documentación

- [x] 6.1 Entrada del change en `CHANGES.md` (+ `AGENTS.md` sincronizado por `check_docs_sync.py`).
- [x] 6.2 Delta specs: `afip-fiscal-document`, `operation-delete-compensation`, `operation-edit-context`.

## 7. Pendiente de otros

- [x] 7.1 Verificación en prod (2026-09-26, SELECT-only): `fiscal_documents_status_check` incluye el 4º estado `voided`; helper `_fiscal_void_pending_for_sale_edit` es `SECURITY DEFINER` con ACL `{postgres, service_role}` (sin `anon`/`authenticated`); `max(version)=20261062000001` (309 migraciones, ⩾ `20261060000001`). Humo real del PO NO ejercitó específicamente el camino de este change (editar/borrar una venta con un comprobante `pending_cae` sin marca de envío) — lo que sí se ejercitó: (a) el e2e local de `#585` mostró que, tras autorizarse el comprobante, los controles de editar/borrar pasan a estar bloqueados (consistente con el guard que este change endurece), y (b) la factura real del PO el 2026-09-25 (Sumar, Factura C 0003-00000501, autorizada por ARCA en 1 s) ejercitó de punta a punta el camino promover→emitir que corre sobre este change. Pendiente real, no cubierto: una edición real en prod de una venta con comprobante `pending_cae` sin marca (para ver la anulación `voided` en acción).
