# Mediciones de producción — checkpoint 1.1/1.2/1.8 (2026-09-01)

Todas las queries corrieron **SELECT-only** vía `mcp__supabase__execute_sql` contra el
proyecto real (`gxdhpxvdjjkmxhdkkwyb`). Nunca se usó `apply_migration`.

## 1.1 — MAX de `supabase_migrations.schema_migrations`

```
max(version) = 20261017000001
count(*)     = 266
```

Coincide con el último archivo local en `origin/main`
(`20261017000001_seguros_perfil_asesor.sql`). Sin renumeración. El archivo de
migración de este change nace como `20261018000001_caja_compras_cobranzas.sql`.

## 1.2 — Checkpoint de integridad de función

`md5(pg_get_functiondef(oid))` + `length(...)` de las cuatro RPCs a reescribir y las
dos de referencia, comparado contra la tabla de `design.md`:

| Función | md5 vivo | length vivo | Coincide con design.md |
|---|---|---|---|
| `rpc_create_purchase_operation` | `058f4d291d85bec0ae46589bde49e3a3` | 19438 | ✅ |
| `rpc_delete_purchase_operation` | `e10a1505250d1d6d9301de38a719ee75` | 4165 | ✅ |
| `rpc_register_payment_received` | `3af320ebaf30a94eaa7bbf8e3cd05404` | 7031 | ✅ |
| `rpc_register_payment_made` | `f4b6bdfa06f4c35c487459c24a143b31` | 6148 | ✅ |
| `rpc_atomic_update_purchase_operation` | `0dc8bcf0902710ecb126a9edb9bc3e5f` | 23205 | ✅ |
| `rpc_create_expense` (referencia) | `c8f2ef987a6efe06ba0303e93d367d6a` | 12701 | ✅ |
| `rpc_delete_expense` (referencia) | `4d78ee3b241bea2f4df34ceb0afb7cce` | 6498 | ✅ |

**🛑 CHECKPOINT PASA — cero divergencia.** Los 7 cuerpos vivos coinciden byte a byte
(mismo md5) con lo que `design.md` registró al escribirse el propose. Se procede a
escribir SQL. Los 7 cuerpos completos quedan volcados en este mismo directorio
(`baseline/*.sql`), cada uno con su procedencia, md5 y length en el encabezado.

## Firmas de los helpers reutilizados (verificadas, no se tocan)

```
c28_register_cash_movement(p_session_id uuid, p_amount numeric, p_type text,
  p_reference_id uuid DEFAULT NULL, p_description text DEFAULT NULL)
```
`p_description` (5º arg) ya existe en prod — lo agregó `qa-integral-modulos`
(G16/H11, migración `20261016000001`, ya en `main`) para que el motivo del gasto
viaje al historial de caja. Este change lo reutiliza también en compra
(`p_description` de `rpc_create_purchase_operation`) y en la reversa del borrado.

```
_pay_register_operation_bank_movement(p_account_id uuid, p_kind text,
  p_payment_method_id uuid, p_bank_account_id uuid, p_amount_abs numeric,
  p_direction text, p_source_doc_type text, p_source_doc_ref uuid,
  p_value_date date, p_branch_id uuid, p_description text)

_pay_register_party_charge(p_account_id uuid, p_party_kind text, p_party_id uuid,
  p_amount numeric, p_reference_id uuid, p_operation_id uuid)

_pay_reverse_party_charge(p_account_id uuid, p_party_kind text,
  p_party_account_id uuid, p_amount numeric, p_reference_id uuid,
  p_operation_id uuid)

reporting_local_today() RETURNS date
```

Ninguno de los cuatro cambia de firma en este change.

## 1.8 — Mediciones de producto re-medidas hoy

| Medición | Valor medido 2026-09-01 | Valor del proposal | ¿Coincide? |
|---|---|---|---|
| Compras imputadas a `kind='cash'` | 4 | 4 | ✅ |
| `payments_received` | 6 | 6 | ✅ |
| `payments_made` | 1 | 1 | ✅ |
| Sesiones de caja `open` | 3 | 3 | ✅ |
| Compras con `branch_id` no nulo | 0 de 507 | 0 de 507 | ✅ |
| `cash_movements` vivos por tipo | `sale`=65, `expense`=3, `sale_reversal`=2, `expense_reversal`=1 (total 71) | igual | ✅ |
| Filas con `movement_type='purchase_payment'` | 0 (el tipo está en el CHECK pero ninguna función viva lo escribe — verificado en el texto de las 4 funciones baseline: ninguna menciona `'purchase_payment'`) | 0 | ✅ |

Ninguna medición cambió de orden de magnitud respecto del propose. Se procede sin
revisar el diseño.
