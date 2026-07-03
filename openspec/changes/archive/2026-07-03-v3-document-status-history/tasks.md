## 0. Governance MEDIO — checkpoints (no bloqueante)

- [x] 0.1 Governance MEDIO: el apply procede con checkpoints, sin sign-off bloqueante del PO. Surgir a revisión las decisiones no obvias (D1 tabla vs. función, D5 rol inerte, Open Question del relay CAE) antes de cablearlas.
- [x] 0.2 Antes de tocar cada RPC, capturar el cuerpo vigente de su migración (`rpc_accept_quote` → `20260806000001` / `20260702000001`; `_c29_confirm_order_core` → `20260806000001` / `20260721000001`; `rpc_close_cash_session` → `20260701000001`; `rpc_close_reconciliation_session` → `20260805000001`; `rpc_emit_pending_cae` → `20260806000001` / `20260800000006`) para partir de ahí y guardar el diff de rollback. Partir SIEMPRE del cuerpo más reciente (la última `CREATE OR REPLACE FUNCTION` gana).
- [x] 0.3 Confirmar que el change NO recrea el CHECK de `operation_idempotency.operation_kind` ni toca stock/caja/idempotencia; el único delta permitido por RPC es la llamada a `record_status_transition`.
- [x] 0.4 Resolver con el PO/durante el apply la Open Question del relay CAE (punto exacto donde el backend registra `pending_cae → authorized|rejected`).

## 1. DDL: tabla de historial append-only

- [x] 1.1 Crear la migración `supabase/migrations/2026NNNN000001_v3_document_status_history.sql` (timestamp posterior a `20260806000001`), con header de governance MEDIO y bloque de rollback documentado.
- [x] 1.2 `CREATE TABLE public.document_status_history` con `id uuid PK`, `account_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE`, `document_type text NOT NULL CHECK (document_type IN ('quote','sales_order','fiscal_document','cash_session','reconciliation_session','stock_transfer'))`, `document_id uuid NOT NULL`, `from_status text NULL`, `to_status text NOT NULL`, `performed_by uuid NOT NULL`, `reason text NULL`, `occurred_at timestamptz NOT NULL DEFAULT now()`.
- [x] 1.3 Índice para el timeline: `CREATE INDEX ... ON document_status_history (account_id, document_type, document_id, occurred_at)`.
- [x] 1.4 RLS: `ENABLE ROW LEVEL SECURITY` + única policy `document_status_history_select` (SELECT, `account_id IN (SELECT current_account_ids())`). Sin policy de INSERT/UPDATE/DELETE (D3).
- [x] 1.5 `REVOKE UPDATE, DELETE ON public.document_status_history FROM authenticated, anon` (cinturón append-only adicional, RN-A3).

## 2. StatusTransitionPolicy como datos (catálogo + helpers)

- [x] 2.1 `CREATE TABLE public.document_status_transitions` con `document_type text NOT NULL`, `from_status text NULL`, `to_status text NOT NULL`, `is_terminal_to boolean NOT NULL DEFAULT false`, `requires_reason boolean NOT NULL DEFAULT false`, `allowed_role text NULL` (D5 — permisiva), y unicidad `(document_type, from_status, to_status)` con NULL manejado (índice único parcial para la fila de creación `from_status IS NULL`).
- [x] 2.2 Seed del catálogo con las FSMs vigentes (D6): quote (`NULL→draft`, `draft→sent`, `draft|sent→accepted`, `draft|sent→expired`, `draft|sent→rejected`), sales_order (`NULL→draft`, `draft→confirmed`), fiscal_document (`NULL→pending_cae`, `pending_cae→authorized`, `pending_cae→rejected`), cash_session (`NULL→open`, `open→closed` con `requires_reason` gestionado por el RPC — D7), reconciliation_session (`NULL→open`, `open→closed`), stock_transfer (`NULL→completed`, `is_terminal_to=true`). NO sembrar transiciones sin RPC (`sales_order→canceled`, etc.).
- [x] 2.3 Helpers `STABLE`: `is_valid_transition(p_document_type text, p_from text, p_to text) RETURNS boolean`, `is_terminal_status(p_document_type text, p_status text) RETURNS boolean`, `transition_requires_reason(p_document_type text, p_to text) RETURNS boolean` — todos consultando el catálogo.
- [x] 2.4 `GRANT EXECUTE` de los tres helpers a `authenticated` (los usa la UI para mostrar acciones posibles); son de solo lectura.

## 3. Helper de registro de transición

- [x] 3.1 `CREATE OR REPLACE FUNCTION public.record_status_transition(p_account_id uuid, p_document_type text, p_document_id uuid, p_from_status text, p_to_status text, p_performed_by uuid, p_reason text DEFAULT NULL) RETURNS void` `SECURITY DEFINER SET search_path = public`.
- [x] 3.2 Lógica: si `p_from_status IS NOT NULL`, validar `is_valid_transition` → si falso, `RAISE ... ERRCODE 'P0409'` (RN-A4 estructural). Si `transition_requires_reason(p_document_type, p_to_status)` y `p_reason` nulo/vacío → `RAISE ... ERRCODE 'P0400'` (RN-A5). Insertar la fila en `document_status_history`. NO validar `allowed_role` (D5 — inerte en este change; dejar comentario `-- v3-rbac-multirole activará el check de allowed_role aquí`).
- [x] 3.3 `REVOKE ALL ON FUNCTION public.record_status_transition(...) FROM PUBLIC, anon, authenticated` (helper interno; solo lo invocan otros `SECURITY DEFINER`).

## 4. Retrofit de los RPCs de transición (misma transacción)

- [x] 4.1 `rpc_accept_quote`: partir del cuerpo vigente; agregar `PERFORM record_status_transition(v_account_id, 'quote', p_quote_id, v_quote.status, 'accepted', v_uid)` justo antes/después del `UPDATE quotes SET status='accepted'`, en la misma transacción. No alterar la copia de items ni la creación del SalesOrder.
- [x] 4.2 Creación de Quote: en la ruta que crea el presupuesto (INSERT directo vía RLS o su repositorio), registrar `from_status = NULL → 'draft'`. Como el INSERT del quote no pasa por un RPC definer hoy, evaluar: (a) un `AFTER INSERT` trigger que llame `record_status_transition`, o (b) un RPC de creación de quote. Elegir la opción que preserve el patrón append-only sin abrir escritura directa; documentar la decisión.
- [x] 4.3 `_c29_confirm_order_core`: agregar el registro `from_status = NULL → 'draft'` en la creación de la SalesOrder (en `rpc_quick_sale`/`rpc_accept_quote` que la crean) y `draft → confirmed` en la confirmación, dentro de la transacción atómica. Verificar que el replay idempotente (return temprano `replayed=true`) NO inserta historial duplicado.
- [x] 4.4 `rpc_close_cash_session`: agregar `NULL → open` en la apertura (`rpc_open_cash_session` si existe, o donde se cree la sesión) y `open → closed` en el cierre, pasando `p_reason` = descripción de la diferencia de arqueo cuando la diferencia ≠ 0 (D7).
- [x] 4.5 `rpc_close_reconciliation_session`: agregar `NULL → open` en la apertura y `open → closed` en el cierre.
- [x] 4.6 Ruta de emisión/relay del CAE: `rpc_emit_pending_cae` registra `NULL → pending_cae`. Para `pending_cae → authorized|rejected`, exponer `rpc_record_fiscal_transition(p_fiscal_document_id uuid, p_to_status text, p_reason text DEFAULT NULL)` `SECURITY DEFINER` que el backend invoca tras persistir la respuesta de ARCA (resolver el punto exacto — Open Question 0.4). No abrir escritura directa sobre el historial.

## 5. Gates SQL (RED→GREEN, ROLLBACK total)

- [x] 5.1 GATE: una transición válida inserta exactamente una fila en `document_status_history` (verificar `from/to/performed_by/occurred_at`).
- [x] 5.2 GATE: una transición no catalogada hace fallar `record_status_transition` con `P0409`.
- [x] 5.3 GATE: una transición con `requires_reason=true` y `reason` vacío falla con `P0400`.
- [x] 5.4 GATE: `UPDATE`/`DELETE` sobre `document_status_history` como `authenticated` es rechazado (RLS/grants).
- [x] 5.5 GATE: la creación registra `from_status = NULL` (RN-A2). Envolver todos los gates en `DO $$ ... $$` con SAVEPOINTs y ROLLBACK total (patrón C-28/C-29); no insertar en `auth.users` sin considerar `handle_new_user` (gate `validate-kpis` corre contra DB vacía).

## 6. UI — timeline del documento

- [x] 6.1 Definir el tipo `DocumentStatusHistoryEntry` en `lib/types.ts` (sin `any`).
- [x] 6.2 Crear el componente `DocumentTimeline.tsx` (PascalCase, Server Component) que recibe `documentType` + `documentId`, lee `document_status_history` server-side ordenado por `occurred_at`, y renderiza la línea de tiempo con shadcn/ui. Estado vacío para documentos sin historial ("Sin historial de estados registrado").
- [x] 6.3 Insertar `DocumentTimeline` en el detalle de venta, presupuesto y factura. Si el detalle es Client Component, exponer la data vía `route.ts`/Server Action + TanStack Query con data inicial hidratada (no fetch en Client Component directo).

## 7. Knowledge base y verificación

- [x] 7.1 Agregar RN-A1..A5 a `knowledge-base/05_reglas_de_negocio.md` en la sección "Dominio: Modelo V3 (retrofit)" (junto a RN-100): A1 historial en la misma transacción; A2 creación con `from_status=NULL`; A3 append-only por grants; A4 política como datos + dimensión rol estructurada (activada por RBAC); A5 `reason` obligatorio en transiciones destructivas.
- [x] 7.2 Tests (TDD): registrar transición inserta historial; transición inválida rechazada; `reason` obligatorio; append-only no admite UPDATE/DELETE; creación con `from_status=NULL`; idempotencia de confirmación no duplica historial. Cubrir con gates SQL (§5) + tests pytest del lado backend donde aplique (quote/relay CAE).
- [x] 7.3 `supabase db advisors` tras el cambio de schema/RPC; resolver hallazgos (verificar `SET search_path` en toda función nueva/reemplazada).
- [x] 7.4 Smoke test con plan de rollback antes de mergear: aceptar presupuesto, confirmar orden/quickSale, cerrar caja (con y sin diferencia), cerrar conciliación, emitir comprobante → verificar que cada uno inserta su fila de historial y que stock/caja/idempotencia no regresan.
- [ ] 7.5 Tras el archive, actualizar `CHANGES.md` (estado del change) y notar que `v3-rbac-multirole` puede consumir `document_status_transitions.allowed_role`. — Post-archive, fuera de este apply.
