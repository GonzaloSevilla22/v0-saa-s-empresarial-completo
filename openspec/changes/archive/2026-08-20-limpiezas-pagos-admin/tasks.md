> **Strict TDD**: cada grupo con lógica arranca por el gate en RED. Todo commit va por PR (nunca directo a `main`), rama nueva por cambio. Migración única `20261003000001_limpiezas_pagos_admin.sql`, idempotente. `npx supabase db push` — NUNCA MCP `apply_migration`.
>
> **Orden obligatorio**: G3 → G2 → G1. El DROP de la columna va último, cuando ya nada la escribe.

## 1. Preparación y baseline

- [x] 1.1 Rama nueva desde `main` actualizado; verificar que `MAX(version)` de `supabase/migrations/` sigue siendo `20261002000001` y que ningún PR de la saga quedó sin mergear. Verificado también contra prod (MCP, solo SELECT): `MAX(version) = 20261002000001` — coincide.
- [x] 1.2 **Safety net**: gates corridos contra una réplica local (misma versión, verificada byte a byte idéntica a prod para las 8 funciones y los 5 ERRCODEs) antes de tocar nada — todos verdes en el estado pre-change. `pytest backend/tests`: 1438 passed, 3 skipped (antes de mis +1 test). `pnpm vitest run`: 1204 passed (antes de mis +3 tests).
- [x] 1.3 Baseline `pg_get_functiondef()` guardado en `openspec/changes/limpiezas-pagos-admin/baseline/` para las 8 funciones. **Ampliado durante el apply** con `rpc_quick_sale` y `handle_new_user` (`.NEW.sql` incluidos) — ver hallazgo de 4.1.
- [x] 1.4 Migración `supabase/migrations/20261003000001_limpiezas_pagos_admin.sql` creada con cabecera de contexto completa.

## 2. G3 — ERRCODEs de 4 caracteres (RED primero)

- [x] 2.1 **RED**: `supabase/tests/test_errcode_5char_gate.sql` escrito y corrido en RED contra la base pre-fix — listó las 5 funciones esperadas.
- [x] 2.2 **RED (triangulación)**: segundo caso (`rpc_product_profitability` sin cuenta activa, anchor sin `account_members`) agregado — RED confirmado (bloqueado por el fallo del caso 1, que aborta todo el `DO`).
- [x] 2.3 **GREEN**: bloque `DO` dinámico agregado a la migración, reutilizando el mecanismo de `20260624000001`. Gate → PASA.
- [x] 2.4 Gate de residuo cero + verificación de conjunto agregados. **Ajuste real durante el apply**: la verificación de "conjunto exacto" se relajó a "subconjunto del esperado" — la reconvergencia de CI (ver 7.3) reaplica migraciones viejas que revierten solo 1-4 de las 5 funciones, y exigir el conjunto completo abortaba esa reconvergencia legítima.
- [x] 2.5 Verificado: las 5 funciones conservan `SECURITY DEFINER`/`search_path`/ACLs tras el `CREATE OR REPLACE`.
- [x] 2.6 `test_errcode_5char_gate.sql` cableado en `.github/workflows/KPI_Validation.yml`.
- [x] 2.7 **Idempotencia**: migración reaplicada sobre la misma base — `DO` no reescribe nada, gates verdes.

## 3. G2 — Baja de las 4 RPCs `get_admin_*` huérfanas

- [x] 3.1 **RED**: gate de ausencia agregado a `test_kpis.sql` (§5/§7 reemplazados, §9 eliminado) — corrido en RED (las 4 existían).
- [x] 3.2 **GREEN**: `DROP FUNCTION IF EXISTS` con firma explícita para las 4 RPCs agregado a la migración.
- [x] 3.3 Gate interno que verifica que `get_admin_community_interactions` sigue existiendo, agregado.
- [x] 3.4 `test_kpis.sql` podado.
- [x] 3.5 `test_kpis_edge_cases.sql` podado (§3 guard admin, §6 rango invertido).
- [x] 3.6 Confirmado: `test_function_acl_gate.sql` no requirió edición.
- [x] 3.7 `test_kpis.sql`, `test_kpis_edge_cases.sql`, `test_admin_kpis.sql`, `test_community_interactions.sql`, `test_function_acl_gate.sql` → todos verdes.
- [x] 3.8 `frontend/lib/adminAnalytics.ts` actualizado: el comentario ya no dice "no se tocan en la base" — dice que fueron dropeadas.

## 4. G1a — Los sitios de escritura dejan de escribir el texto

- [x] 4.1 **RED**: `supabase/tests/test_sales_order_payment_method_drop.sql` escrito (regex con lookaround despojando comentarios/strings antes de matchear, para evitar falsos positivos de texto descriptivo) y corrido en RED. **HALLAZGO REAL**: además de confirmar que la columna/CHECK seguían existiendo, el check (3) (ninguna función referencia la columna cruda) detectó que `rpc_quick_sale` **también** escribía `payment_method` al crear el draft — un 4º sitio de escritura no inventariado en el design original (que listaba solo 3: `rpc_accept_quote`, `rpc_promote_legacy_sale_to_order`, `_c29_confirm_order_core`). Sin este hallazgo, el `DROP COLUMN` de G1c habría roto toda venta del POS.
- [x] 4.2 **GREEN (escrituras)**: `CREATE OR REPLACE` de `rpc_accept_quote` y `rpc_promote_legacy_sale_to_order` (quitando la columna del INSERT) **más `rpc_quick_sale`** (mismo criterio D7, agregado por el hallazgo de 4.1). Misma firma en los tres → sin `DROP`, sin re-`GRANT`.
- [x] 4.3 **GREEN (confirm)**: `CREATE OR REPLACE` de `_c29_confirm_order_core` — (a) UPDATE final sin `payment_method = v_kind`; (b) rama `ELSE` resuelve por `kind` (desempate `sort_order`, luego `id`) reasignando el parámetro `p_payment_method_id`, sin abortar si no hay match.
- [x] 4.4 Verificado (gate interno agregado a la migración): el payload del evento `SaleConfirmed` sigue emitiendo `'payment_method', v_kind` sin cambios.
- [x] 4.5 **TRIANGULACIÓN**: `test_pos_confirm_payment_method.sql` extendido. (i) ya cubierto por los escenarios preexistentes (5/7/8/9) + assert nuevo del payload del evento en el caso 8; (ii) caso (11) — legacy `cash` sin id resuelve a la forma sembrada; (iii) caso (12) — legacy `check` **sin** método vivo/activo (desactivado a propósito en el setup, ya que OQ-1 sembró `check` en la misma migración) confirma con `payment_method_id NULL` sin abortar. **Además**, el caso (4) preexistente (antes probaba que `other` quedaba sin imputar) se corrigió: con `other` sembrado, D2 ahora SÍ resuelve — el caso pasó a demostrar la resolución, no la ausencia de ella.
- [x] 4.6 `test_confirm_core_integrity.sql`, `test_pos_rpc_signatures.sql`, `test_pagos_cableados_restantes.sql`, `test_pos_banco_movimientos.sql`, `test_edicion_preserva_contexto.sql` (este último requirió un fix propio — ver 6.1) → verdes, firma de `_c29_confirm_order_core` intacta.

## 5. G1b — Los dos consumidores de lectura migran a `payment_method_id`

- [x] 5.1 **RED (backend)**: `backend/tests/test_sales.py::test_list_sales_pos_derivation_joins_by_payment_method_id_not_kind` agregado — verifica el TEXTO de la query (el pool mockeado no ejecuta SQL real, así que no hay fan-out con filas reales para ejercitar; se verifica la propiedad estructural que lo elimina por construcción). RED confirmado contra el JOIN viejo.
- [x] 5.2 **GREEN (backend)**: `backend/repositories/sales_repository.py` — JOIN cambiado a `pos_pm.id = so.payment_method_id`, comentario actualizado.
- [x] 5.3 **TRIANGULACIÓN (backend)**: ya cubierto por los tests preexistentes (`test_list_sales_row_exposes_is_invoiced_flag` y afines ejercitan `payment_method_id`/NULL explícitos); el test nuevo de 5.1 agrega el caso estructural del fan-out.
- [x] 5.4 **RED (frontend)**: `frontend/__tests__/SalesOrderDetailPage.test.tsx` (archivo nuevo) — 3 casos. RED razonado: el mock de datos no incluye el campo viejo `order.payment_method` (solo `payment_method_id`/`payment_methods`), así que el código viejo (`order.payment_method === "cash" ? ... : ...`) no renderiza nada — el assert `getByText("Billetera virtual")` falla.
- [x] 5.5 **GREEN (frontend)**: `page.tsx` actualizado — `.select(...)` trae `payment_method_id` + `payment_methods(name, kind)` embebido; interfaz `SalesOrderRow` sin `any`; renderiza el nombre real o "Sin especificar".
- [x] 5.6 Sin superficie nueva (pantalla existente, cambio de renderizado). Verificación visual completa desktop/mobile/claro-oscuro no se ejecutó en vivo en esta sesión (mismo criterio que `edicion-preserva-contexto`/`pagos-cableados-restantes`: mitigado por reusar tokens/componentes ya verificados y por los 3 tests de componente).
- [x] 5.7 Grep final confirmado: cero referencias vivas fuera de migraciones históricas, `database.types.ts` (regenerado en 7.1, ver abajo) y `.claude/worktrees/` (ver OQ-4).

## 6. G1c — DROP de la columna

- [x] 6.1 `test_pos_payment_vocabulary.sql` reescrito (D6). **Deuda adicional encontrada**: `test_edicion_preserva_contexto.sql` insertaba `payment_method` como dato de fixture en 4 `INSERT INTO sales_orders` — no estaba en el inventario original (no es un "sitio de escritura" de producción, es fixture de test) pero rompía tras el `DROP COLUMN`; corregido en el mismo commit de G1.
- [x] 6.2 **GREEN**: `ALTER TABLE ... DROP COLUMN IF EXISTS payment_method` + gate agregados, al final de la migración.
- [x] 6.3 `test_sales_order_payment_method_drop.sql` → PASA. `test_pos_payment_vocabulary.sql` reescrito → PASA.
- [x] 6.4 **Idempotencia end-to-end**: migración completa reaplicada sobre la base ya migrada → sin errores, sin cambios, gates verdes.
- [x] 6.5 `test_confirm_core_integrity.sql` verde. `check_backend_table_refs.py`/`check_frontend_table_refs.py` (corridos vía un driver Python ad-hoc, sin `psql` nativo en el entorno) → 0 violaciones cada uno.

## 7. Cierre

- [x] 7.1 Suite completa local corrida en el orden exacto de `KPI_Validation.yml` (24 archivos `.sql`) — todos verdes. `pytest backend/tests` con `--cov-fail-under=87`: **1439 passed, 3 skipped, coverage 89.52%**. `pnpm vitest run`: **1207/1208** (1 flake pre-existente documentado, `SuscripcionesAmbiguasPage`, pasa 11/11 aislado). `tsc --noEmit`: mismos errores pre-existentes exactos antes/después de regenerar `database.types.ts` (OQ-2), ninguno nuevo. Sin gate de `lint` en CI para este repo (`Frontend_Tests.yml` solo corre vitest).
- [x] 7.2 PR #429 abierto con tabla de consumidores, tabla de las 5 funciones, veredicto por RPC admin y la justificación de `_journal_post_from_event`.
- [x] 7.3 Todos los checks verdes (`KPI Validation`, `Backend Tests`, `Frontend Tests`, `E2E Tests`, Vercel) — mergeado (squash) como `f7d0dcd`. Build+deploy+migración automáticos verificados vía `gh run watch` (run 32368964435, job "Deploy Supabase" → "Deploy Database Migrations" ✅).
- [x] 7.4 **Smoke en prod post-deploy (solo SELECTs)**: verificado que la migración quedó aplicada (`MAX(version) = 20261003000001`), columna/CHECK ausentes, 4 RPCs ausentes + `community_interactions` viva, ERRCODEs `P04xx` presentes/residuo cero, seed 35 cuentas × 7 `kind`. **No se ejecutó** una venta POS real desde la UI en prod (escritura interactiva, fuera del alcance permitido de la sesión — prod solo SELECT) — mismo criterio ya documentado en `pos-banco-movimientos`/`edicion-preserva-contexto`. La cadena completa (confirm→stock→caja/cuenta-corriente/banco→outbox) ya está ejercitada extensivamente por los gates sintéticos de CI (`test_pos_confirm_payment_method.sql`, 12 escenarios).
- [x] 7.5 Verificado en prod: las 4 RPCs admin no están; `get_admin_community_interactions` sigue viva.
- [ ] 7.6 **No ejecutado**: forzar un `RAISE` corregido en prod requeriría una llamada API real (p.ej. una compra que dispare `stock_insuficiente` en `rpc_create_purchase_operation`) — es una operación con efectos, fuera del alcance solo-SELECT de la sesión. Verificado en su lugar, por SELECT, que el `prosrc` de las 5 funciones ya tiene los códigos `P04xx` nuevos (residuo de 4 caracteres = 0) — el comportamiento del `RAISE` en sí está cubierto por el gate de comportamiento de `test_errcode_5char_gate.sql` (caso 2, corrido localmente contra una réplica idéntica).
- [x] 7.7 `CHANGES.md` actualizado: OQ-F (de `pos-catalogo-pagos`) y OQ-3 (de `deudas-menores-agosto`) cerradas; entrada nueva para `limpiezas-pagos-admin` con el hallazgo de `rpc_quick_sale`, inventarios G1/G2/G3, y las 4 micro-OQs con su resolución (OQ-1 sembrada, OQ-2 regenerado, OQ-3/OQ-4 sin acción/informativas).
- [x] 7.8 `mem_save` con `topic_key: "opsx/limpiezas-pagos-admin/apply"` hecho. Archive: este documento (etapa 2, PR separado por instrucción explícita del PO en vez de `/opsx:archive` de un tirón).
