# Baselines vivos de prod — qa-integral-modulos (task 0.1)

**Procedencia**: `pg_get_functiondef()` ejecutado contra el proyecto Supabase de producción
`gxdhpxvdjjkmxhdkkwyb` el **2026-08-31**, vía MCP (solo SELECT). Transferencia en base64
(`encode(convert_to(..., 'UTF8'), 'base64')`) para preservar bytes exactos; cada archivo
`.live.sql` de este directorio reproduce el cuerpo vivo **byte a byte** (md5 local == md5
calculado por Postgres en prod). El `.gitattributes` de este directorio (`*.sql -text`)
impide que autocrlf altere los bytes.

**Estado de prod al momento de la captura**:
- `MAX(version)` en `supabase_migrations.schema_migrations` = **`20261015000001`** (264 migraciones; el directorio local también tiene 264 — sin drift).
- ⇒ La migración prevista por el propose, **`20261016000001_qa_integral_fixes.sql`, sigue válida sin renumerar**.

| Función (firma viva) | md5 (prod == archivo) | length | Último archivo de migración | ¿Diverge? |
|---|---|---|---|---|
| `rpc_branch_report(uuid,date,date)` | `fd21f8864b9878d7cb271ff210ee6953` | 2279 | `20260814000001_v3_reporting_invariants.sql` | **NO** (cuerpo normalizado idéntico) |
| `rpc_product_profitability(integer)` | `eb25445906c068f6025600517012bf38` | 3285 | `20260814000001_v3_reporting_invariants.sql` | **SÍ** — el archivo (L153) dice `ERRCODE = 'P403'`; el cuerpo vivo dice `'P0403'`. Única diferencia. Causa identificada: la reescritura **in-place** del G3 de `20261003000001_limpiezas_pagos_admin.sql` (`pg_get_functiondef` + `regexp_replace` + `CREATE OR REPLACE` — la función está en su `v_expected`), el mismo mecanismo que ya divergió `rpc_create_purchase_operation` en `compras-proveedor-cuenta-corriente`. El baseline es el cuerpo VIVO. La DB local (post `db reset`) también tiene `'P0403'` — coincide con prod en contenido, difiere solo en formato de `pg_get_functiondef` local. |
| `rpc_create_expense(text,numeric,date,text,uuid,uuid,uuid,uuid,uuid)` | `b58ac4d270aa0d62c479da92e5290b21` | 12382 | `20261015000001_gastos_forma_pago.sql` | **NO** (cuerpo normalizado idéntico) |
| `rpc_delete_expense(uuid)` — capturado en el apply (2026-08-31) porque la task 16.2 exige el motivo también en las reversas del borrado | `819bd69422dfec39dceea76148a7634c` | 6038 (6174 bytes) | `20261015000001_gastos_forma_pago.sql` | **NO** (md5 prod == md5 local) |

> **Corrección 2026-09-01**: `rpc_delete_expense.live.sql` se había commiteado con
> **un `\n` de más** al final (6175 bytes, md5 `e279409f…`), así que el archivo no era
> byte-idéntico al md5 que esta tabla y el encabezado de la migración documentan. Se
> re-verificó contra prod vía MCP (`octet_length` = 6174, `md5` = `819bd694…`, termina
> en `$function$\n`) y se le quitó ese byte: ahora los **cuatro** archivos reproducen
> el cuerpo vivo byte a byte. El diff de la migración contra el baseline no cambia —
> la diferencia real de `rpc_delete_expense` sigue siendo solo el motivo en las reversas.

**Verificaciones sobre el cuerpo vivo** (anclas de los fixes del change):
- `rpc_branch_report`: el CTE `all_branch_ids` usa `branch_id` SIN calificar (`SELECT DISTINCT branch_id FROM branch_sales` / `... FROM branch_expenses`) contra el parámetro OUT homónimo → el `42702` de H4 está en el vivo tal como lo describe el design (D4). Fix admisible: calificar la columna.
- `rpc_product_profitability`: `RETURNS TABLE(... last_sale_date date)` con `MAX(s.date)` (timestamptz) en el SELECT → el `42804` de G8 está en el vivo (D6). Fix admisible: cast consciente de zona (`AT TIME ZONE 'America/Argentina/Mendoza'`)::date, conservando la firma.
- `rpc_create_expense`: llama `c28_register_cash_movement(p_cash_session_id, -p_amount, 'expense', v_expense_id)` (4 args — omite el 5º `p_description`) y `_pay_register_operation_bank_movement(..., p_date, v_gate_branch, NULL)` (`NULL` literal en `p_description`) → el motivo vacío de H11 está en el vivo (D9). Fix admisible: pasar `p_description` en ambas llamadas.
- Lateral (fuera de alcance de este change, solo constancia): `rpc_dashboard_kpi_summary` en `20260814000001` L475 también tiene el typo `'P403'` en el archivo.

**Regla de integridad**: toda reescritura de estas tres funciones en `20261016000001` parte
de estos `.live.sql`, NUNCA de los archivos de migración. La única diferencia admisible por
función es el fix puntual documentado arriba. `DROP+CREATE` está prohibido (resetea ACLs y
`rpc_branch_report`/`rpc_product_profitability` devuelven TABLE — cambiar el tipo de retorno
exigiría DROP); usar `CREATE OR REPLACE` conservando firma y tipo de retorno, y re-aplicar
los GRANT/REVOKE vigentes en el mismo archivo.
