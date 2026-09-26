# Design — venta-editable-sin-cae

Governance: **CRÍTICO** (dominio fiscal). Migración `20261060000001`.

Los códigos `D*` son los que citan los comentarios del código; el relato largo del
change (hallazgos, mediciones de prod, verificación) vive en la entrada de
`CHANGES.md`.

## Context

El pedido del PO deroga el predicado "hay comprobante ⇒ inmutable". La pieza que
lo hace posible es `fiscal-riesgos-residuales` (#580): `cae_submit_started_at` se
persiste **antes** del `FECAESolicitar`, en su propia transacción, así que el
instante del envío es un dato exacto y sobrevive a que el proceso muera.

Tres escritores tocan un `fiscal_documents`: la **emisión** (lo crea y lo vincula
a la orden), el **relay** (lo marca y lo manda a ARCA) y —nuevo— la
**edición/borrado** (lo anula). Casi todo el diseño es la exclusión mutua entre
los tres.

## Decisiones

- **D1 — `voided` como 4º estado terminal**, no un booleano `is_voided` ni un
  borrado de la fila. El comprobante consumió un número y eso tiene que quedar
  visible; y el estado viaja por la misma maquinaria de FSM e historial que ya
  existe. **No es una nota de crédito**: la NC revierte un comprobante que tuvo
  efecto fiscal, y un `voided` nunca llegó a ARCA.
- **D2 — el predicado**. Editable/borrable si (a) sin comprobante, (b) el
  comprobante está `rejected`/`voided`, o (c) está `pending_cae` **y**
  `cae_submit_started_at IS NULL AND cae_submit_unconfirmed_at IS NULL`. Bloquea
  en cualquier otro caso. Es una **allow-list**: un status futuro desconocido
  bloquea (lección de #577/#580 — guards cerrados por defecto).
- **D3 — `next_attempt_at` NO entra en el predicado.** Conflacia el lease de
  `claim_pending` (+5 min) con el backoff de `update_retry` ([1,2,5,15,60] min):
  incluirlo dejaría la venta inmutable hasta 60 minutos por un comprobante que
  nunca llegó a ARCA. Hay un gate dedicado para que nadie lo "endurezca".
- **D4 — concurrencia.** Cuatro pasos, y el orden importa:
  0. la **orden** con `SELECT ... FOR UPDATE`, y el `fiscal_document_id` leído de
     esa fila bloqueada. Excluye a la emisión (que toma el mismo lock antes de
     crear el comprobante) y fija el orden `so → fd`, el mismo que usa la
     emisión: sin ciclo no hay deadlock. Las dos mitades de esto las encontró el
     red team del 2026-09-22 (M1 y M2), reproducidas con dos conexiones.
  1. el **comprobante** sin lock, sólo para rechazar rápido;
  2. el lock del comprobante con **NOWAIT** — un request de usuario no puede
     esperar detrás de un round-trip SOAP; `55P03` → `P0423` transitorio;
  3. la anulación con el **predicado adentro del `UPDATE`**: es la re-evaluación
     bajo el lock, y ahí no se puede borrar el guard sin borrar la escritura
     (antes era un `IF` aparte que el arnés de mutación del red team borraba con
     los 7 gates en verde, m3).
- **D5 — la re-emisión** (`rpc_emit_sale_invoice`) pasa de "¿hay comprobante?" a
  una allow-list `status IN ('rejected','voided')`. Deny-list sería peor que el
  bug que arregla: un status futuro desconocido habilitaría una **segunda factura
  real**. `NULL` (vínculo ilegible) también bloquea.
- **D6 — motivo obligatorio** en la transición: la fila del catálogo nace con
  `requires_reason = true`, así que `record_status_transition` exige el texto y
  el historial nunca queda sin causa. Sin una línea de código extra.
- **D7 — `allowed_role = NULL`** en la fila del catálogo, igual que las otras tres
  de `fiscal_document`: quien puede editar la venta ya pasó los guards del
  service y de la RPC.
- **D8 — el helper no toca `sales_orders.fiscal_document_id`.** El vínculo
  sobrevive a la anulación: es lo que le permite al badge mostrar "Anulado" y al
  historial ser reconstruible.
- **D9 — el número NO se reutiliza.** El hueco en `document_sequences` es
  deliberado: ante ARCA el número autoritativo se pide en el envío, y reutilizar
  el local abriría la puerta a dos documentos con el mismo número.
- **D10 — guard de tenencia en el choke point**, no en los callers (precedente
  `cuenta-corriente-party-guard` + hotfix #454). El helper es `SECURITY DEFINER`
  con el tenant por parámetro: es la única defensa que un caller futuro no puede
  olvidarse. Medido en prod antes de escribirlo: 0/126 órdenes con `account_id`
  nulo o divergente del de sus `sales`, 0 usuarios multi-cuenta.
- **D11 — la UI nombra la causa REAL.** Tres causas comparten `P0423` y la salida
  del usuario es distinta en cada una (nota de crédito / esperar / reintentar),
  así que el read model expone la evidencia cruda del comprobante y la pantalla
  elige el texto. El resultado que se informa sale de la **respuesta del
  servidor** (`voided_fiscal_document`), nunca de lo que el cliente creía antes
  de guardar: si la carrera la gana el relay, llega un 409 y no se muestra
  ninguna anulación falsa.
- **D12 — el relay no cambia de comportamiento.** Sus dos filtros por
  `status = 'pending_cae'` (`claim_pending`, `mark_submit_started`) son lo único
  que impide que un anulado llegue a ARCA, y ahora tienen gate. Lo único que
  cambia es el **nivel de log**: encontrarse un comprobante anulado en medio del
  tick es un camino normal desde este change, no un fallo (m2 del red team);
  cualquier otro `P0437` sigue saliendo en ERROR con su stack trace.

## Prueba de exclusión edición-vs-los-otros-dos

| # | Secuencia | Resultado | Dónde se prueba |
|---|-----------|-----------|-----------------|
| (a) | la edición gana | `claim_pending` no matchea y `mark_submit_started` da `P0437`: el `FECAESolicitar` nunca sale | bloque (4) del gate `.sql` |
| (b) | el relay gana con marca commiteada | `P0423` terminal, sin lock ni anulación | gate 2.10 de `test_edicion_preserva_contexto.sql` |
| (c) | el relay tiene la fila tomada | `55P03` → `P0423` transitorio, sin colgarse; liberada, el mismo pedido funciona | caso (c) del `.sh` |
| (d) | el relay reclamó (lease) sin marcar | la edición anula igual; el relay ya no puede enviar | bloque (4) del gate `.sql` |
| (e) | la **emisión** abierta y la edición en el medio | la edición espera la orden, ve el comprobante recién creado y lo anula | caso (e) del `.sh` |
| (f) | orden de locks contra la emisión | ninguna de las dos sesiones ve `40P01` | caso (f) del `.sh` |

## Non-Goals

- Nota de crédito / anulación de un comprobante **autorizado**: es otro dominio
  (tiene efecto fiscal y se corrige ante ARCA).
- Editar el comprobante en vez de anularlo y re-emitir.
- Cambiar el borrado físico de la venta por soft delete.
- Reutilizar el número local liberado (D9).
