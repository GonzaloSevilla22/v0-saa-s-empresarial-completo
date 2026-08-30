# Safety net previo — `gastos-forma-pago` (grupo 1)

- **Fecha**: 2026-08-29
- **Rama**: `opsx/gastos-forma-pago-apply`, creada desde `origin/main` (`348b573`)
- **Stack local**: `npx supabase db reset` limpio (exit 0, 263 migraciones, `MAX(version) = 20261014000001` — idéntico a prod)

Todo lo de acá es el **antes**. Cualquier número que se mueva después está causado por este change y hay que justificarlo por escrito.

---

## Task 1.2 — suite backend completa

```
python -m pytest backend/tests -q -p no:cacheprovider
→ 1591 passed, 3 skipped, 1 warning in 22.51s   (exit 0)
```

**Baseline: 1591/1591 verdes, 3 skipped, 0 fallos preexistentes.**

## Task 1.3 — suite frontend completa

```
pnpm vitest run
→ Test Files  184 passed (184)
        Tests  1457 passed (1457)          (exit 0)
```

**Baseline: 1457/1457 verdes, 0 fallos preexistentes.**

> ⚠️ **Divergencia con lo que preveía `tasks.md` 1.3.** La task decía *"hay 1 fallo preexistente ajeno; confirmarlo y no tocarlo"* — ese dato venía de la época de `compras-proveedor-cuenta-corriente` (1331/1332). **Hoy la suite está 100% verde.** Consecuencia práctica: **no hay coartada**. Cualquier fallo de frontend que aparezca durante este change es de este change.

## Task 1.2b — safety net DIRIGIDO (D15), archivo por archivo

Corrido **antes** de tocar nada. Los cuatro archivos cubren justamente lo que este change reescribe.

| Archivo | Casos | Estado | Lo toca |
|---|---|---|---|
| `backend/tests/test_expenses.py` | **7** (`def test_`) | ✅ 7 passed | grupo 7 (el repositorio pasa de SQL crudo a RPC) |
| `frontend/__tests__/hooks/use-expenses.test.ts` | **5** | ✅ | grupo 9 (el hook se reescribe entero; estos 5 casos fijan los payloads actuales) |
| `frontend/__tests__/components/expense-form-date-default.test.tsx` | **1** | ✅ | grupo 10 (el formulario suma selectores) |
| `frontend/__tests__/components/expense-import-dialog-parse-and-validate.test.ts` | **3** | ✅ | task 11.7 (sólo el texto de ayuda) |
| `frontend/__tests__/components/RecentActivity.test.tsx` | **2** | ✅ | indirecto (mockea `useExpenses`) |

Frontend, los 4 archivos juntos: `Test Files 4 passed (4) · Tests 11 passed (11)` (exit 0).
Backend, `test_expenses.py`: `7 passed`.

**Los 7 tests backend por nombre** (para poder justificar uno por uno lo que cambie):
`test_get_expenses_ok`, `test_get_expenses_serializes_timestamp_date_with_time_component`, `test_get_expenses_empty`, `test_create_expense_ok`, `test_create_expense_member_forbidden`, `test_delete_expense_member_forbidden`, `test_get_expense_cross_org_empty`.

> `test_get_expenses_ok` y `test_get_expenses_empty` assertan la **lista plana** que `GET /expenses` devuelve hoy. D18 la convierte en `{items,total,page,pages}`: **esos dos van a cambiar a propósito** y quedan justificados de antemano acá.

---

## Task 1.4 — gates del workflow, en el orden exacto de CI

Corridos con `psql -v ON_ERROR_STOP=1` dentro del contenedor, después de la cadena de reapply (que en CI corre antes que los gates).

**33 de 33 gates SQL verdes. 0 fallos.**

`test_kpis` · `test_kpis_edge_cases` · `test_function_acl_gate` · `test_errcode_5char_gate` · `test_idempotency` · `test_sale_items_rpc_v2_activation` · `test_operation_edit_lines` · `test_stock_movements_edicion` · `test_payment_methods_catalog` · `test_payment_methods_seed` · `test_payment_method_operations` · `test_payment_method_report` · `test_pos_payment_vocabulary` · `test_confirm_core_integrity` · `test_pos_rpc_signatures` · `test_pos_confirm_payment_method` · `test_analytics_events` · `test_admin_kpis` · `test_community_interactions` · `test_internal_logs_retention` · `test_edicion_preserva_contexto` · `test_pagos_cableados_restantes` · `test_pos_banco_movimientos` · `test_asiento_venta_formulario` · `test_delete_guard_ledgers` · `test_banco_caja_historial_ajustes` · `test_cuentas_billetera_tipo` · `test_compras_proveedor_cuenta_corriente` · `test_tenancy_rls_role` · `test_cuenta_corriente_party_guard` · `test_outbox_single_dispatcher` · `test_tenancy_guard_caja_outbox` · `test_sucursal_guard_vaciado`

Los dos gates de referencia que **no** son psql también pasan:

```
scripts/ci/check_backend_table_refs.py  → OK: 131 archivos, 89 relaciones/funciones verificadas
scripts/ci/check_frontend_table_refs.py → OK: 460 archivos, 66 relaciones/funciones verificadas (3 dinámicas omitidas)
```

> **Gotcha de entorno**: no hay `psql` en el PATH del host. Los gates SQL se corren dentro del contenedor (`docker cp` del árbol `supabase/` + `docker exec`), y los dos gates de referencia se corrieron con un wrapper que redirige su única llamada a `psql` por `docker exec` **sin modificar el script del gate**. El wrapper vive en el scratchpad, no en el repo.
>
> **Gotcha que costó una corrida**: la lista de gates generada en el host viene en **CRLF**; dentro del contenedor cada nombre de archivo arrastraba un `\r` y **los 33 gates "fallaban"** con rc=1 y sin una sola línea `ERROR` (psql no encontraba el archivo). Un gate que falla sin `ERROR` en el output es señal de path, no de regresión. Se resuelve con `tr -d '\r'`.

`token-contrast-aa.test.ts` es parte de la suite vitest y ya está cubierto por el 1457/1457 de la task 1.3.

---

## Task 1.5 — cadena de reapply idempotente

Se extrajo **literal** el script del step *"Verify G1/G4 migrations are idempotent on reapply"* del `KPI_Validation.yml` (333 líneas, 16 `psql -f`) y se corrió dentro del contenedor. Único ajuste: el puerto del DSN (54322 del host → 5432 adentro).

**Resultado: exit 0. Fallan sólo los dos eslabones tolerados que el YAML documenta, y por el motivo documentado.**

| Eslabón | Qué pasó | ¿Tolerado por el YAML? |
|---|---|---|
| fingerprint G1/G4 | `Idempotent: fingerprint unchanged on reapply (0\|0\|0\|0)` | — |
| `20260928000001` | aborta en su **gate ANTI-OVERLOAD**, `ERROR ... rpc_create_sale_operation tiene 2 definiciones` | ✅ sí, con marcador literal `GATE ANTI-OVERLOAD FAILED` → reconverge con `20260930000001` |
| `20261002000001` | aborta en su gate `GATE POS-BANCO-MOVIMIENTOS FAILED (1, 42725)` | ✅ sí → reconverge al final de la cadena |
| las otras 14 migraciones | aplican limpio | — |

### 🛑 La verificación que D14 pedía explícitamente (y que NO se supone)

D14 depende de que el reapply de `20260928000001` **aborte antes** de llegar al `CREATE` de `rpc_payment_method_report` con la firma vieja de 7 columnas. Si llegara, chocaría con la firma nueva de 8 y daría **42P13**. Medido, no supuesto:

| Punto | Línea en `20260928000001_payment_methods_operaciones.sql` |
|---|---|
| Sección 9 — gate ANTI-OVERLOAD | 1807-1838 |
| **Punto real donde aborta el reapply** | **1838** |
| Sección 10 — `CREATE OR REPLACE FUNCTION public.rpc_payment_method_report(` | **1850** |
| Sección 11 — sus ACLs (`REVOKE`/`GRANT`) | 1945-1947 |
| Sección 12 — gate de introspección del reporte | 1951 |

**El abort (1838) ocurre 12 líneas antes del `CREATE` (1850).** Las secciones 10, 11 y 12 se saltean en la cadena, exactamente como dice el comentario del YAML. **No se introduce ningún 42P13.** ✅

### Estado de las funciones DESPUÉS de la cadena completa

Las 11 funciones del gate de integridad quedan con **exactamente 1 definición cada una** y **el md5 idéntico al de prod**. La cadena converge de verdad; el reapply no deja overloads fantasma ni cuerpos viejos.

> ⚠️ **Falta la segunda mitad de esta task**: repetir la cadena **después** de aplicar `20261015000001` y volver a verificar el punto de abort (re-check al cerrar el grupo 6, como indica la propia task 1.5).

---

## Task 1.9 — caminos de escritura a `expenses`

**Backend** — un único camino, como esperaba el propose:

```
backend/repositories/expense_repository.py:26  INSERT INTO expenses (...)
backend/repositories/expense_repository.py:46  UPDATE expenses SET ... WHERE id=$1 AND account_id=$2
backend/repositories/expense_repository.py:54  DELETE FROM expenses WHERE id=$1 AND account_id=$2
```

Nada más en `backend/` escribe la tabla. El importador CSV pasa por el mismo endpoint.

**Frontend** — un hallazgo que el propose no anticipaba (esperaba "ninguno"):

| Camino | Qué es | ¿Vivo? |
|---|---|---|
| `frontend/lib/supabase/services.ts:66` — `supabase.from('expenses').insert([...])` | **INSERT directo por PostgREST**, sin pasar por el backend | ❌ **código muerto**: `createExpense` no tiene **ningún** llamador y el módulo `lib/supabase/services` no tiene **ningún** importador en todo el frontend |
| `frontend/app/(dashboard)/gastos/page.tsx:75` — `usePaginatedQuery({ table: "expenses" })` | lectura por PostgREST directo | ✅ vivo — **es justo lo que D18 migra** a `GET /expenses` |
| `frontend/lib/ai/buildBusinessSnapshot.ts:117`, `frontend/lib/services/aiCopilotService.ts:65` | lecturas por PostgREST para IA | ✅ vivas, **sólo lectura**, no afectadas |

**Conclusión:** hoy no hay bypass real del repositorio. Pero `services.createExpense` es un bypass **latente**: si alguien lo reviviera, crearía un gasto sin pasar por `rpc_create_expense` y por lo tanto sin tocar ningún libro — exactamente el estado que este change viene a cerrar. Además está tipado con `any` (prohibido por el CLAUDE.md del proyecto). **Candidato a borrarlo**; no se toca en el grupo 1.
