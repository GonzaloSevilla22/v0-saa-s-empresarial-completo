## Context

El modelo V3 §2 define un patrón transversal: cada documento tiene una FSM declarada **como datos** (transiciones válidas, `is_terminal`, `requires_reason`, `allowed_role`) y todo cambio de estado inserta una fila en un historial **append-only** `document_status_history`, en la misma transacción que la transición (RN-A1..A5). Hoy en Aliadata las FSMs están implícitas en `CHECK (status IN (...))` por tabla y no hay historial; el `AuditLog` (vía outbox) es técnico y no consultable como "línea de tiempo del documento".

Estado real verificado en `supabase/migrations/` (la última `CREATE OR REPLACE FUNCTION` / definición de tabla gana):

| Documento | Tabla / CHECK vigente | Migración | RPC que transiciona hoy |
|---|---|---|---|
| Quote | `quotes.status IN ('draft','sent','accepted','expired','rejected')` | `20260702000001` | `rpc_accept_quote` (`→accepted`); INSERT directo vía RLS (creación); `expire()` on-read |
| SalesOrder | `sales_orders.status IN ('draft','confirmed','canceled')` | `20260702000001` | `_c29_confirm_order_core` (`→confirmed`); **`canceled` sin RPC** (definido en CHECK, nadie lo escribe) |
| FiscalDocument | `fiscal_documents.status IN ('pending_cae','authorized','rejected')` | `20260627000001` | `rpc_emit_pending_cae` (crea `pending_cae`); relay backend + pg_cron (`→authorized|rejected`) |
| CashSession | `cash_sessions.status IN ('open','closed')` | `20260701000001` | `rpc_close_cash_session` (`→closed`, con diferencia de arqueo) |
| Reconciliation | `reconciliation_sessions.status IN ('open','closed')` | `20260805000001` | `rpc_close_reconciliation_session` (`→closed`) |
| StockTransfer | `stock_transfers.status IN ('completed')` | `20260625000001` | ninguno — la transferencia nace `completed` (atómica); el enum "habilita in-transit en el futuro sin migrar" |

Constraints del proyecto: aditivo sin drops; RLS org-based (`is_account_writer`, `current_account_ids`); el hot path transaccional vive en RPCs `SECURITY DEFINER` (equivalente del UoW); CI aplica migraciones a prod al mergear a main (nunca a mano ni MCP `apply_migration`); el gate `validate-kpis` corre contra DB vacía; governance **MEDIO** (tabla + triggers nuevos, no cambia la semántica de los documentos) → apply procede con checkpoints, sin sign-off bloqueante del PO. Prerequisito downstream: `v3-rbac-multirole` (matriz rol×transición, RN-A4).

## Goals / Non-Goals

**Goals:**
- Tabla `document_status_history` append-only genérica, con RLS solo-SELECT y escritura exclusiva vía `SECURITY DEFINER` (RN-A3 por grants).
- `StatusTransitionPolicy` **como datos** (catálogo `document_status_transitions` + helpers), no `if`s dispersos, con la dimensión `allowed_role` estructurada y permisiva para RBAC futuro (RN-A4).
- Helper `record_status_transition` que valida la transición, exige `reason` cuando la policy lo pide (RN-A5) e inserta el historial en la misma transacción (RN-A1).
- Retrofit de los RPCs de transición vigentes para invocar `record_status_transition`, incluida la creación con `from_status = NULL` (RN-A2), sin alterar la semántica de negocio.
- Seed del catálogo con las FSMs reales (las de los CHECKs, no las ideales del roadmap).
- Timeline "línea de tiempo del documento" en el detalle de venta/presupuesto/factura.

**Non-Goals:**
- Activar el enforcement por rol (RN-A4): `allowed_role` se crea permisiva; poblarla y validarla es `v3-rbac-multirole`.
- Agregar transiciones que hoy no existen (`sales_order → canceled` sin RPC, `stock_transfer` `dispatched/received`, `fiscal_document → credited`): el catálogo modela solo lo que las tablas permiten hoy.
- Backfill retroactivo del historial de documentos ya existentes (arranca vacío, se llena hacia adelante).
- Migrar la escritura a backend Python (el patrón sigue en RPCs SQL).
- Tocar stock, caja, idempotencia o el CHECK de `operation_idempotency.operation_kind`.

## Decisions

### D1 — `StatusTransitionPolicy` como TABLA catálogo + funciones helper (no una función con `CASE`)
Se modela como una tabla `document_status_transitions (document_type, from_status, to_status, is_terminal_to, requires_reason, allowed_role, PRIMARY KEY (document_type, from_status, to_status))` sembrada con las transiciones válidas, más tres funciones `STABLE`: `is_valid_transition(doc_type, from, to) → bool`, `is_terminal_status(doc_type, status) → bool`, `transition_requires_reason(doc_type, to) → bool`.
- *Por qué tabla y no función con `CASE`*: (a) `v3-rbac-multirole` necesita **poblar `allowed_role` sin migración disruptiva** — con una tabla es un `UPDATE`/`INSERT` de datos, con un `CASE` es reescribir la función; (b) las transiciones válidas son consultables por la UI (mostrar acciones posibles) sin duplicar lógica; (c) es exactamente el patrón "FSM como datos" del V3 §2 y de Food Store (`EstadoPedido` con `es_terminal`). El `from_status = NULL` (creación) se modela con una fila especial `from_status IS NULL` por `document_type`.
- *Alternativa descartada*: enum de Postgres + función pura. Rechazado: los enums son rígidos (agregar un valor requiere `ALTER TYPE`), y no portan `requires_reason`/`allowed_role` sin una tabla lateral igual.

### D2 — `document_type` como TEXT con CHECK, no FK ni enum
`document_type TEXT NOT NULL CHECK (document_type IN ('quote','sales_order','fiscal_document','cash_session','reconciliation_session','stock_transfer'))`. `document_id UUID NOT NULL` es un puntero polimórfico **sin FK** (no puede haber una FK a seis tablas distintas). La integridad se garantiza porque solo los RPCs `SECURITY DEFINER` escriben, y cada uno pasa su propio `document_type` literal.
- *Por qué sin FK polimórfica*: una FK a seis tablas es imposible en Postgres; triggers de validación cruzada añadirían costo al hot path sin beneficio (la escritura ya está encapsulada en RPCs confiables). El CHECK sobre `document_type` evita typos.

### D3 — Append-only enforzado por GRANTS + ausencia de policies (RN-A3), no por convención ni por trigger
`document_status_history` tiene RLS habilitada con **una sola policy: SELECT** por `account_id IN (SELECT current_account_ids())`. No hay policy de INSERT/UPDATE/DELETE → el rol `authenticated` no puede escribir directamente. La escritura ocurre solo vía `record_status_transition` (`SECURITY DEFINER`, dueño con bypass de RLS). Además `REVOKE UPDATE, DELETE ON document_status_history FROM authenticated` como cinturón adicional.
- *Por qué no un trigger `BEFORE UPDATE/DELETE ... RAISE`*: el grant-based es más simple, se evalúa antes y no añade overhead por fila. La combinación "sin policy de escritura + REVOKE explícito" es el patrón que el proyecto ya usa en `sales_orders`/`stock_transfers` (escritura solo por RPC). RN-A3 queda enforzado estructuralmente, no por disciplina.

### D4 — `record_status_transition` es un helper `SECURITY DEFINER` reutilizable, invocado dentro de cada RPC
Firma: `record_status_transition(p_account_id uuid, p_document_type text, p_document_id uuid, p_from_status text, p_to_status text, p_performed_by uuid, p_reason text DEFAULT NULL) RETURNS void`. Valida con `is_valid_transition` (excepto cuando `p_from_status IS NULL`, que es creación — RN-A2), exige `p_reason` no vacío cuando `transition_requires_reason` es true (RN-A5, `ERRCODE P0400`), e inserta la fila. Se `REVOKE`a de `PUBLIC/anon/authenticated` (helper interno, como `_c29_confirm_order_core`).
- *Por qué un helper y no repetir el INSERT en cada RPC*: centraliza las reglas RN-A3/A4/A5 en un punto; cada RPC solo añade una línea `PERFORM record_status_transition(...)`. El delta de retrofit por RPC es mínimo y auditable.
- *Validación permisiva ante transición no catalogada*: si la transición no está en el catálogo, `is_valid_transition` devuelve false y `record_status_transition` **lanza** `P0409` — pero como el seed cubre exactamente las transiciones que los RPCs vigentes ejecutan, en la práctica ningún RPC actual dispara ese error. Esto protege contra transiciones futuras mal cableadas.

### D5 — La dimensión `role` queda estructurada pero INERTE en este change
`document_status_transitions.allowed_role TEXT NULL` (`NULL` = cualquier rol permitido). `record_status_transition` **no** valida `allowed_role` en este change (recibe `p_performed_by` pero no chequea su rol contra la fila). `v3-rbac-multirole` poblará `allowed_role` y añadirá el check `require_role`/comparación dentro de `record_status_transition` (o en una capa superior) sin migración disruptiva — solo un `UPDATE` de datos + un `CREATE OR REPLACE FUNCTION` del helper. RN-A4 queda "estructurado, no activado", tal como pide el scope.

### D6 — El seed refleja las FSMs REALES (los CHECKs), no las del roadmap
El catálogo se siembra con las transiciones que las tablas permiten hoy:
```
quote:                  NULL→draft, draft→sent, draft→accepted, sent→accepted,
                        draft→expired, sent→expired, draft→rejected, sent→rejected
sales_order:            NULL→draft, draft→confirmed        (canceled: en CHECK pero sin RPC → NO se siembra transición entrante aún)
fiscal_document:        NULL→pending_cae, pending_cae→authorized, pending_cae→rejected
cash_session:           NULL→open, open→closed             (requires_reason=true en open→closed cuando hay diferencia — ver D7)
reconciliation_session: NULL→open, open→closed
stock_transfer:         NULL→completed                     (terminal; sin transiciones salientes)
```
- *Por qué no sembrar `sales_order → canceled` / `stock_transfer → dispatched`*: no existe RPC que las ejecute; sembrarlas sería modelar deuda futura como si estuviera implementada. Cuando el change que agregue esas transiciones llegue, extiende el seed. El catálogo describe la realidad, no la aspiración.

### D7 — `requires_reason` a nivel transición, con el `reason` real provisto por el RPC llamador
`open→closed` de `cash_session` marca `requires_reason = true`; el `rpc_close_cash_session` computa la diferencia de arqueo y pasa `p_reason` = descripción de la diferencia (o un texto estándar) cuando la hay. Para `reconciliation_session` `open→closed`, `requires_reason = false` (el cierre no es destructivo). Las transiciones destructivas del roadmap (cancelación, anulación, ajuste) que aún no tienen RPC quedan documentadas en el seed cuando se agreguen. RN-A5 se cumple para las transiciones que hoy existen y lo ameritan.

### D8 — Timeline UI: Server Component que lee el historial ordenado, con fallback vacío
`DocumentTimeline` (PascalCase, Server Component en App Router) recibe `documentType` + `documentId`, hace la query server-side (`document_status_history` filtrado + ordenado por `occurred_at`), y renderiza una lista vertical con shadcn/ui. Para documentos sin historial (creados antes de este change), muestra un estado vacío ("Sin historial de estados registrado") — coherente con el Non-Goal de no backfillear. La query se colocaliza en el server (RN de `nextjs-app-router-patterns`); si el detalle es Client Component, se expone vía un endpoint/`route.ts` o TanStack Query con la data inicial hidratada. Nunca `any` en los tipos (tipo `DocumentStatusHistoryEntry` en `lib/types.ts`).

## Risks / Trade-offs

- **[Regresión al reemplazar un RPC de transición desde un cuerpo viejo]** → Partir siempre del cuerpo de la migración vigente listada en Context; diff explícito; el único delta permitido es la línea `PERFORM record_status_transition(...)`. Smoke test de aceptar-quote / confirmar-orden / cerrar-caja / cerrar-conciliación post-migración.
- **[`document_id` polimórfico sin FK deja historial "huérfano" si el documento se borra]** → Aceptado: los documentos confirmados no se borran (política de soft delete V3 §4 — se anulan, no se eliminan); el historial es append-only por diseño y su valor es justamente sobrevivir. No se añade `ON DELETE`.
- **[Una transición no catalogada aborta un RPC con P0409]** → El seed cubre exactamente las transiciones vigentes; se verifica en un gate SQL RED/GREEN que cada RPC retrofiteado ejecuta una transición presente en el catálogo. Riesgo real solo si se agrega un RPC nuevo sin sembrar su transición → queda como checklist para changes futuros.
- **[El relay del CAE corre en el backend Python + pg_cron, no en un RPC único]** → La transición `pending_cae → authorized|rejected` la aplica el backend al persistir el CAE. Registrar el historial ahí requiere que el backend llame a `record_status_transition` (o un RPC wrapper `rpc_record_fiscal_transition`) tras la respuesta de ARCA. Se expone un RPC delgado invocable desde el backend con `SECURITY DEFINER` para no abrir escritura directa. Ver Open Question.
- **[Gate de CI `validate-kpis` contra DB vacía]** → Los DO-blocks de verificación no insertan en `auth.users` sin considerar el trigger `handle_new_user`; usan el patrón anchor sintético con `ON CONFLICT DO NOTHING` + `ROLLBACK` conceptual, como C2/C3.
- **[Overhead por transición]** → Un INSERT extra por cambio de estado. Índice en `document_status_history (account_id, document_type, document_id, occurred_at)` para la query del timeline; el INSERT es O(1) y no está en un loop de líneas. Impacto despreciable en el hot path.

## Migration Plan

1. Nueva migración `supabase/migrations/2026NNNN000001_v3_document_status_history.sql` (timestamp posterior a `20260806000001`):
   - `CREATE TABLE document_status_history` (append-only) + RLS solo-SELECT + `REVOKE UPDATE,DELETE FROM authenticated` + índice del timeline.
   - `CREATE TABLE document_status_transitions` (catálogo) + `INSERT` del seed (D6) con `allowed_role = NULL` (D5).
   - Helpers `STABLE`: `is_valid_transition`, `is_terminal_status`, `transition_requires_reason`.
   - `record_status_transition` (`SECURITY DEFINER`, `REVOKE` de PUBLIC/anon/authenticated).
   - `CREATE OR REPLACE FUNCTION` de `rpc_accept_quote`, `_c29_confirm_order_core`, `rpc_close_cash_session`, `rpc_close_reconciliation_session` — partiendo del cuerpo vigente, agregando el `PERFORM record_status_transition(...)` en la misma transacción, más el registro de creación (`from_status = NULL`) en las rutas de creación (quote/sales_order/cash_session/reconciliation/fiscal_document).
   - RPC wrapper `rpc_record_fiscal_transition` (o parámetro en la ruta de relay) para que el backend registre `pending_cae → authorized|rejected` tras ARCA.
   - Gates SQL RED→GREEN (transición válida inserta historial; transición inválida lanza P0409; `reason` faltante en `requires_reason` lanza P0400; historial no admite UPDATE/DELETE) con ROLLBACK total.
2. Frontend: componente `DocumentTimeline` + tipo `DocumentStatusHistoryEntry` + inserción en el detalle de venta/presupuesto/factura; hook/query de TanStack si el detalle es Client.
3. Actualizar `knowledge-base/05_reglas_de_negocio.md` con RN-A1..A5 en la sección "Dominio: Modelo V3 (retrofit)".
4. Actualizar `CHANGES.md` tras el archive; notar que `v3-rbac-multirole` puede consumir `document_status_transitions.allowed_role`.
5. **Rollback**: todo aditivo → `DROP FUNCTION` de los helpers/`record_status_transition`, restaurar los cuerpos de RPC previos (guardar el diff), `DROP TABLE document_status_transitions, document_status_history`. Ninguna estructura existente referencia las nuevas tablas. Smoke test antes de mergear.

## Open Questions

- **¿Cómo registra el historial la transición del CAE (`pending_cae → authorized|rejected`), que la aplica el backend Python + pg_cron, no un RPC atómico único?** Recomendación: exponer `rpc_record_fiscal_transition(p_fiscal_document_id, p_to_status, p_reason)` `SECURITY DEFINER` que el backend invoca tras persistir la respuesta de ARCA, dentro de la misma transacción en que actualiza `fiscal_documents.status`. Confirmar el punto exacto del código del relay durante el apply.
- **¿`reason` estándar para el cierre de caja sin diferencia?** Opciones: `NULL` (no destructivo, no lo exige) vs. texto informativo ("cierre sin diferencia"). Recomendación: `requires_reason` solo cuando hay diferencia de arqueo ≠ 0; el RPC decide.
- **¿El timeline debe mostrar el `performed_by` como nombre de usuario (join a `auth.users`/membership) o solo el id?** Decisión de UI; el dato (`performed_by`) queda disponible para cualquiera de las dos.
- **¿Se registra `expire()` de Quote (cómputo defensivo on-read, sin RPC dedicado) en el historial?** Hoy la expiración es on-read (no persiste una transición). Recomendación: fuera de scope — registrar `expired` requeriría materializar la transición, que es otro cambio de comportamiento; documentarlo como transición futura del catálogo.
