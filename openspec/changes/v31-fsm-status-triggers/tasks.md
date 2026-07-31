> **Modo TDD estricto.** El "test" de este change es SQL: cada gate de comportamiento se escribe **antes** que el trigger que lo satisface y debe fallar por la razón esperada (RED) antes de implementar (GREEN). Ninguna tarea `[x]` sin ejecutar `npx supabase db reset` local y ver el resultado.
> **Governance ALTO.** Las tareas del grupo 1 son **bloqueantes**: si la verificación de compatibilidad encuentra un estado huérfano o una transición vigente no catalogada, detenerse y reportar antes de escribir la migración. La migración se revisa antes del merge.
> **Regla dura**: la migración se aplica por CI al mergear. NUNCA `db push` manual ni el MCP `apply_migration`.

## 1. Compatibilidad — verificación bloqueante antes de escribir nada

- [ ] 1.1 Ejecutar `npx supabase db reset` local y registrar el baseline: la suite SQL (`supabase/tests/test_kpis.sql`, `test_kpis_edge_cases.sql`) pasa y los gates de las migraciones existentes no reportan `FAILED`. Si algo ya falla, reportarlo como preexistente y detenerse.
- [ ] 1.2 Volcar el catálogo vigente (`SELECT document_type, from_status, to_status, is_terminal_to FROM document_status_transitions ORDER BY 1,2,3`) y confirmar las 18 filas y los 6 tipos.
- [ ] 1.3 Enumerar **todos** los caminos que escriben `status` en las 6 tablas de documento: los 9 RPCs retrofiteados, `quote_repository.transition_quote`, `fiscal_document_repository.update_authorized/update_rejected`, y cualquier otro que aparezca (grep de `SET status` en `supabase/migrations/`, `backend/repositories/` y `frontend/`). Contrastar cada par `(from, to)` contra el volcado de 1.2. **Bloqueante**: si alguno no está catalogado, detenerse y reportar — el trigger lo rompería en producción.
- [ ] 1.4 Consultar en **producción** (read-only, MCP) la distribución real de `status` por tabla para las 6 tablas. **Bloqueante**: si existen filas en un estado que no figura en el catálogo, o en un estado no terminal desde el que no sale ninguna transición catalogada, detenerse y reportar antes de continuar (quedarían congeladas).
- [ ] 1.5 Confirmar el timestamp de la migración nueva: posterior a la última en `supabase/migrations/`. Anotarlo.

## 2. RED — Gates de comportamiento antes del trigger

- [ ] 2.1 Escribir el bloque `DO $$` de gates en la migración nueva **antes** de escribir la función y los triggers, con el anchor sintético del patrón vigente (`v3-document-status-history` §COMPORTAMIENTO, solo cuando `accounts` está vacía).
- [ ] 2.2 Gate **(a) negativo**: `UPDATE quotes SET status = <estado no catalogado desde draft>` debe abortar con `P0409`. Ejecutar `db reset`: debe **fallar** el gate (hoy el `UPDATE` tiene éxito) — ésta es la prueba de que el gate no es una tautología.
- [ ] 2.3 Gate **(b) positivo**: `UPDATE quotes SET status='sent'` desde `draft` debe tener éxito. Ejecutar: pasa hoy (protege contra el falso positivo).
- [ ] 2.4 Gate **(c) no-interferencia**: `UPDATE` de una columna distinta de `status` sobre un documento en estado terminal debe tener éxito. Ejecutar: pasa hoy.
- [ ] 2.5 Gate **(d) terminal**: `UPDATE` que intenta sacar a un documento de un estado terminal debe abortar con `P0409`. Ejecutar: debe **fallar** hoy.

## 3. GREEN — Función genérica de validación (D2, D3)

- [ ] 3.1 Escribir `public.trg_enforce_status_transition()` — `RETURNS trigger`, `LANGUAGE plpgsql`, `SECURITY DEFINER`, `SET search_path = public`. Toma el `document_type` de `TG_ARGV[0]`, delega en `public.is_valid_transition(TG_ARGV[0], OLD.status, NEW.status)` y, si es falso, `RAISE EXCEPTION ... USING ERRCODE = 'P0409'` con un mensaje que identifique origen, tabla, `from` y `to` (D7). Retorna `NEW`. Usar `CREATE OR REPLACE` (idempotencia).
- [ ] 3.2 Crear el trigger sobre `public.quotes`: `DROP TRIGGER IF EXISTS` + `CREATE TRIGGER ... BEFORE UPDATE ... FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status) EXECUTE FUNCTION public.trg_enforce_status_transition('quote')`. Ejecutar `db reset`: los gates 2.2 y 2.5 pasan a **verde**; 2.3 y 2.4 siguen verdes.
- [ ] 3.3 **TRIANGULATE** — Agregar los 5 triggers restantes con su `document_type` correspondiente: `sales_orders`→`sales_order`, `fiscal_documents`→`fiscal_document`, `cash_sessions`→`cash_session`, `reconciliation_sessions`→`reconciliation_session`, `stock_transfers`→`stock_transfer` (D6). Agregar un gate de comportamiento sobre una segunda tabla (p. ej. `cash_sessions`: `open→closed` pasa, `open→<no catalogado>` aborta) para probar que el parámetro `TG_ARGV[0]` se respeta y no está hardcodeado a `quote`. Ejecutar: todos verdes.
- [ ] 3.4 Agregar `REVOKE ALL ON FUNCTION public.trg_enforce_status_transition() FROM PUBLIC, anon, authenticated;` — no es invocable directamente, solo por los triggers.

## 4. Gates estructurales y cabecera de la migración

- [ ] 4.1 Gate estructural: los 6 triggers existen sobre sus 6 tablas, apuntan a `trg_enforce_status_transition` y están **habilitados** (`tgenabled = 'O'` — mitigación explícita del riesgo de "deshabilitado y olvidado").
- [ ] 4.2 Gate estructural: la función existe con `prosecdef = true` y no es ejecutable por `authenticated`/`anon`.
- [ ] 4.3 Gate estructural: el catálogo sigue con 18 filas y los 6 `document_type` (este change **no** lo modifica).
- [ ] 4.4 Gate **negativo** (lección C3): el `CHECK` de `operation_idempotency.operation_kind` no cambió. Si en algún momento hubiera que recrearlo, enumerar antes la unión vigente en prod con `pg_get_constraintdef` — CI no lo atrapa porque su base está vacía.
- [ ] 4.5 Escribir la cabecera de la migración con el formato del proyecto: CHANGE, referencia a `design.md`, decisiones implementadas (D1–D8), ERRCODEs, GOVERNANCE (ALTO), APLICACIÓN (CI al mergear, nunca `db push` manual ni MCP), ROLLBACK completo en orden (6 `DROP TRIGGER IF EXISTS` + `DROP FUNCTION IF EXISTS`), y VERIFICATION post-merge read-only.
- [ ] 4.6 Documentar en un comentario de la migración la decisión D4 (sin bypass en runtime; el escape sancionado es `ALTER TABLE ... DISABLE/ENABLE TRIGGER` dentro de una migración versionada) para que el próximo que necesite un backfill encuentre el mecanismo correcto y no invente un GUC.

## 5. Idempotencia y regresión

- [ ] 5.1 Ejecutar la migración **dos veces seguidas** sobre la base local y confirmar que la segunda no arroja error (la integración GitHub de Supabase auto-aplica al mergear, antes del `db push` de Actions).
- [ ] 5.2 `npx supabase db reset` completo: todos los gates de **todas** las migraciones (no solo esta) pasan; confirmar que ninguno de los gates de comportamiento preexistentes se rompió por el trigger nuevo — en particular los de `v3-document-status-history` (que ejercitan RPCs con transiciones reales) y los de `bank-reconciliation`.
- [ ] 5.3 Ejecutar la suite backend Python completa (`pytest backend/tests`) — no debería cambiar (este change no toca código de aplicación); confirmar el conteo contra el baseline.
- [ ] 5.4 Ejecutar `supabase/tests/test_kpis.sql` y `test_kpis_edge_cases.sql` (lo que corre `validate-kpis`) y confirmar verde.
- [ ] 5.5 Medir el costo del gate en el hot path: comparar el tiempo de una confirmación de venta (`_c29_confirm_order_core`) antes y después del trigger en la base local, y anotar el delta en el PR. Si fuera no despreciable, reportarlo antes de mergear.

## 6. Cierre

- [ ] 6.1 Abrir el PR con: la tabla de compatibilidad de 1.3/1.4 (camino → transición → catalogada sí/no), la tabla de evidencia del ciclo RED/GREEN por gate, y el delta de performance de 5.5.
- [ ] 6.2 Confirmar en el diff que la migración **no** toca: RLS, RPCs existentes, el catálogo `document_status_transitions`, `record_status_transition`, ni el `CHECK` de `operation_idempotency`.
- [ ] 6.3 Confirmar que **no** se agregó nada de la matriz rol×transición (`allowed_role` sigue `NULL` en las 18 filas) ni el gancho maker-checker — ambos son de `v3-rbac-multirole` por sign-off del PO del 2026-07-30.
- [ ] 6.4 Verificación post-merge en prod (read-only, MCP): 6 triggers presentes y habilitados; función con `prosecdef = true`; catálogo intacto en 18 filas; y una prueba negativa dentro de `BEGIN ... ROLLBACK` sobre un documento real confirmando el `P0409`. Registrar la salida.
- [ ] 6.5 Anotar los gaps G1–G4 de `design.md` donde corresponda (`CHANGES.md` y/o el follow-up de `v31-sales-delete-rpc-reversal` para G3, que deberá sembrar `sales_order → canceled` en su propia migración).
