# Auditoría de ACLs, callers y daño histórico en PROD — `tenancy-guard-caja-outbox` (tramo h1)

- **Proyecto**: `gxdhpxvdjjkmxhdkkwyb` (prod, usuarios reales)
- **Fecha de captura**: 2026-08-24
- **Método**: MCP `execute_sql`, SOLO `SELECT` (cero DDL/DML). Tasks 1.5, 1.6, 1.7, 1.9 y 7.1/7.2/7.5 de `tasks.md`.
- **Estado de la DB**: `MAX(supabase_migrations.schema_migrations.version)` = **`20261012000001`**, **261 migraciones**
  (incluye el hotfix h2 de la PR #460). → La migración de h1 nace como **`20261013000001_tenancy_guard_caja_sesion.sql`**.
- **Gotcha #432 vigente**: prod concede `EXECUTE` a `anon`/`authenticated` **directo**, no vía `PUBLIC`.
  Todo lo de abajo se midió con `has_function_privilege(<rol>, oid, 'EXECUTE')` y se contrasta con `proacl`.

---

## 1. Task 1.5 — integridad de las definiciones vivas

Query:

```sql
SELECT p.oid::regprocedure::text AS firma, p.prosecdef,
       md5(pg_get_functiondef(p.oid)) AS md5, length(pg_get_functiondef(p.oid)) AS len,
       has_function_privilege('anon',         p.oid,'EXECUTE') AS anon,
       has_function_privilege('authenticated',p.oid,'EXECUTE') AS auth,
       has_function_privilege('service_role', p.oid,'EXECUTE') AS svc,
       pg_get_userbyid(p.proowner) AS owner, p.proacl::text AS acl
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN (...);
```

| Función (firma completa) | secdef | md5 | len | ¿coincide con el propose? |
|---|---|---|---|---|
| `_c29_confirm_order_core(text,uuid,text,uuid,text,uuid,text,uuid,uuid)` | **true** | `cecd8c5454611f267a5e131d73bf7928` | 15110 | ✅ |
| `c28_register_cash_movement(uuid,numeric,text,uuid,text)` | **false** (INVOKER) | `510adc8e150fb5c315e6e9a2635eaff8` | 2288 | ✅ |
| `rpc_quick_sale(text,uuid,jsonb,text,uuid,text,uuid,uuid,text,uuid,uuid)` | true | `ccb8afa0730195cb3df65807eb0a05ed` | 4046 | ✅ |
| `rpc_confirm_sales_order(text,uuid,text,uuid,text,uuid,uuid,text,uuid,uuid)` | true | `38f2902380018ef717ff5b04cc711d20` | 777 | ✅ |
| `rpc_create_sale_operation_v2(text,uuid,date,text,jsonb,uuid,text,uuid,uuid,uuid)` | true | `0b6bcc5b6caa1a3c01e0da16518c7d35` | 13914 | ✅ |
| `rpc_register_cash_movement(uuid,numeric,text,uuid,text)` | true | `914e0c3ce6fa15275822121c4dec51d0` | 1256 | ✅ |

**Nada cambió en prod desde el propose**: los 6 md5 y los 6 `length` coinciden exactamente con los
registrados el 2026-08-23. Los seis baselines quedaron capturados en `baseline/<nombre>.sql`, cada uno
verificado recomputando `md5` sobre el texto del archivo desde la línea `CREATE OR REPLACE` (mismo
criterio que el baseline de `cuenta-corriente-party-guard`: incluye el salto de línea final que emite
`pg_get_functiondef`).

## 2. Task 1.7 — estado real de permisos

| Función | secdef | anon | authenticated | service_role | `proacl` |
|---|---|---|---|---|---|
| `_c29_confirm_order_core(...)` | true | false | **true** | true | `{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}` |
| `c28_register_cash_movement(...)` | false | false | **true** | true | `{postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}` |
| `rpc_quick_sale(...)` | true | false | **true** | true | `{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}` |
| `rpc_confirm_sales_order(...)` | true | false | **true** | true | `{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}` |
| `rpc_create_sale_operation_v2(...)` | true | false | **true** | true | `{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}` |
| `rpc_register_cash_movement(...)` | true | false | **true** | true | `{postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}` |
| `rpc_process_outbox_batch(integer)` | true | false | **false** | true | `{postgres=X/postgres,service_role=X/postgres}` |
| `rpc_mark_event_processed(uuid)` | true | false | **false** | true | `{postgres=X/postgres,service_role=X/postgres}` |
| `rpc_process_outbox_dispatch(integer)` | true | false | false | true | `{postgres=X/postgres,service_role=X/postgres}` |

Notas:

- Las tres últimas son el **tramo h2, ya cerrado por el hotfix (PR #460)**: `authenticated=false` en las dos
  que se revocaron, `rpc_process_outbox_dispatch` sin cambios. No se toca nada de eso en este tramo.
- Ninguna de las seis funciones de h1 concede `EXECUTE` a `anon`, y **ninguna lo concede vía `PUBLIC`**
  (`proacl` enumera roles explícitos): la reafirmación de ACLs de la migración nueva tiene que **enumerar
  los tres roles** tras cada `CREATE OR REPLACE`, no confiar en `PUBLIC`.
- `c28_register_cash_movement` conserva su `GRANT` a `authenticated` (OQ-4: no se revoca en este change).

## 3. Task 1.6 — diff del baseline vivo contra el archivo de migración de referencia

Normalización aplicada: dollar-quote unificado, `SET search_path TO 'public'` ≡ `SET search_path = public`,
colapso de whitespace y descarte de líneas vacías. Todo lo demás se compara literal.

| Función | Archivo de referencia | Resultado |
|---|---|---|
| `_c29_confirm_order_core` | `20261003000001_limpiezas_pagos_admin.sql` L760 | **IDÉNTICOS** — 335 líneas normalizadas en cada lado, cero diferencias (firma y cuerpo) |
| `c28_register_cash_movement` | `20261006000001_banco_caja_historial_ajustes.sql` §5 (L197) | **Cuerpo IDÉNTICO**; única diferencia = formato de la lista de parámetros (el archivo la escribe en 6 líneas, `pg_get_functiondef` la aplana en 1). Misma firma, mismos defaults, mismo orden |

**Cero divergencia semántica.** El antecedente concreto que motivaba el checkpoint —`_c29_confirm_order_core`
había divergido del archivo en `compras-proveedor-cuenta-corriente` por una reescritura in-place del G3 de
`20261003000001`— **no está presente hoy**: prod y el archivo coinciden línea por línea.

Se verificó además que ninguna migración posterior redefine las dos funciones: las menciones en
`20261004000001`, `20261010000001`, `20261011000001` y `20261012000001` son **sólo comentarios**
(cero `CREATE OR REPLACE` de esos nombres después de sus archivos de referencia).

## 4. Task 1.9 — callers vivos de `c28_register_cash_movement` (por `pg_get_functiondef`, no por grep)

```sql
SELECT p.oid::regprocedure::text, p.prosecdef,
       p.prosrc ILIKE '%c28_register_cash_movement(%' AS llama_literal,
       regexp_count(p.prosrc, '(PERFORM|:=|SELECT)[^\n]*c28_register_cash_movement') AS invocaciones
FROM pg_proc p
WHERE p.pronamespace='public'::regnamespace AND p.prosrc ILIKE '%c28_register_cash_movement%';
```

| Caller | secdef | ¿invoca? | Cómo llega la sesión | Bajo la capa 2 |
|---|---|---|---|---|
| `rpc_register_cash_movement(uuid,numeric,text,uuid,text)` | true | ✅ 1 | parámetro, ya validado con `is_account_writer` sobre el `account_id` derivado por la misma cadena de FKs | **pasa** (redundante a propósito) |
| `rpc_create_sale_operation_v2(...)` | true | ✅ 1 | parámetro, validado por `cash_optin_requires_open_session` (`cs.status='open' AND cb.branch_id = v_gate_branch`) | **pasa** |
| `rpc_create_sale_operation(...)` (legacy) | true | ✅ 1 | ídem — el guard `cash_optin_requires_open_session` está presente en su cuerpo vivo | **pasa** |
| `rpc_delete_sale_operation(uuid,uuid,text)` | true | ✅ 1 | **derivada**: agrupa los `cash_movements` de la operación → `cashbox_id` → sesión `open` más reciente de esa caja (`P0426` si no hay) | **pasa** (ver nota) |
| `_c29_confirm_order_core(...)` | true | ✅ 1 | **parámetro sin validar** | **es el que se cierra** |
| `_register_bank_movement(uuid,numeric,text,text,uuid,date,uuid,text)` | — | ❌ 0 | sólo la **menciona en un comentario** | no aplica |
| `rpc_atomic_update_sale_operation(...11 args...)` | — | ❌ 0 | sólo la **menciona en un comentario** | no aplica |

**Coincide exactamente con la tabla de `design.md` D1**: los mismos **5** callers reales, ni uno de más ni
uno de menos, y los dos falsos positivos del grep (`_register_bank_movement`,
`rpc_atomic_update_sale_operation`) confirmados como menciones en comentarios (`llama_literal = false`,
`invocaciones = 0`). **Ningún caller nuevo desde el propose** → el diseño de la capa 2 no cambia.

**Sexto caller, fuera de `pg_proc`**: el gate de comportamiento embebido en
`20260804000003_fix_c28_cash_movement_balance.sql` §(b) (L256-289), que invoca el helper tres veces sobre un
anchor sintético. Su usuario **no** queda en `account_members` de la cuenta del anchor, así que con la capa 2
el guard rechaza la **primera** llamada. Su manejador es:

```sql
EXCEPTION
  WHEN raise_exception THEN
    IF SQLERRM <> 'GATE_ROLLBACK_SENTINEL' THEN RAISE; END IF;   -- ← matchea SÓLO P0001
  WHEN OTHERS THEN
    RAISE NOTICE 'fix-c28-balance: gate (b) saltado por entorno (%) — ...', SQLERRM;
```

Confirma la restricción de D1/D8 leyendo el código: **con `P0001` el gate re-lanza y aborta
`npx supabase db reset`; con `P0401` cae en `WHEN OTHERS` y degrada a `NOTICE`.** La verificación empírica
es la task 3.6.

**Nota sobre `rpc_delete_sale_operation`** (consecuencia de segundo orden, relevante para los tests): deriva
la caja de los `cash_movements` de la operación borrada. Con la capa 2, si alguna vez existiera un
movimiento fantasma en la caja de otra cuenta, el borrado dejaría de escribir el contra-movimiento en la
caja ajena y fallaría con `P0401` en lugar de contaminarla. Como el daño histórico medido es **0**
(sección 5), hoy no hay ninguna operación viva en ese estado.

## 5. Tasks 7.1 / 7.2 / 7.5 — daño histórico del tramo h1 (read-only)

```sql
WITH cm AS (
  SELECT cm.id, cm.reference_id, b.account_id AS caja_account
  FROM public.cash_movements cm
  JOIN public.cash_sessions cs ON cs.id = cm.session_id
  JOIN public.cashboxes    cb ON cb.id = cs.cashbox_id
  JOIN public.branches      b ON b.id  = cb.branch_id
) ...
```

Cadena verificada contra `information_schema.columns` antes de escribirla:
`cash_movements.session_id → cash_sessions.cashbox_id → cashboxes.branch_id → branches.account_id`,
y `cash_movements.reference_id` contra `sales_orders.id` (camino POS) / `sales.operation_id` (camino
formulario).

| Medición | Valor |
|---|---|
| `cash_movements` totales | **65** |
| …con `reference_id` que resuelve a una `sales_orders` | **65** (el 100 %) |
| **7.1 — cross-tenant por orden** (`sales_orders.account_id <> branches.account_id`) | **0** |
| …con `reference_id` que resuelve a `sales.operation_id` | 0 |
| **7.2 — cross-tenant por venta** | **0** |
| movimientos sin `reference_id` | 0 |
| movimientos con `reference_id` huérfano (ni orden ni venta) | 0 |

Contexto (task 7.5), para que los ceros no sean triviales:

| Métrica | Valor |
|---|---|
| `cash_sessions` | 4 (**3 abiertas**, de **3 tenants distintos**) |
| `cashboxes` | 37 |
| `branches` | 40, en 37 tenants |
| `sales_orders` confirmadas | 119 |
| `events` | 626 (**0 pendientes**) |

**Conclusión**: se confirma el conteo preliminar del propose para el tramo h1 — **0 de 2 consultas con
filas**. El hueco está abierto y es alcanzable (los 65 movimientos vivos pasaron por el único camino sin
guard, y hay 3 cajas abiertas de 3 tenants), pero **todavía no produjo datos corruptos**: no hay reparación
histórica pendiente y la OQ-5 queda cerrada por ausencia de datos, igual que en
`cuenta-corriente-party-guard`.

## 6. Tasks 1.2 / 1.3 / 1.4 — safety net previo (stack local, 2026-08-24)

Rama `opsx/tenancy-guard-caja-h1-apply`, creada desde `origin/main` = `5ce75cf`
(«fix(security): cierra la lectura y el cierre cross-tenant del outbox (hotfix h2) (#460)»).

| Verificación | Resultado |
|---|---|
| **1.2** `python -m pytest backend/tests -q -p no:cacheprovider` | **1580 passed / 3 skipped**, exit 0, 22 s. Cero fallos preexistentes |
| **1.3** `npx supabase db reset` | OK — **261 migraciones**, `MAX(version) = 20261012000001`, idéntico a prod |
| **1.3** los **31 gates SQL** del workflow, en el orden exacto de CI | **31/31 PASS**, 0 fallos |
| **1.4** cadena de reapply del step "Verify G1/G4 migrations are idempotent on reapply" | 12/14 eslabones OK; fallan **sólo** los dos tolerados, cada uno por su marcador literal: `20260928000001` → `GATE ANTI-OVERLOAD FAILED`, `20261002000001` → `GATE POS-BANCO-MOVIMIENTOS FAILED (1, 42725)`. Fingerprint `0|0|0|0` sin cambios antes y después |

> El baseline de pytest **no** es el 1604/3 que anota el propose: ese número es
> anterior al hotfix h2 (#460), que retiró los cinco archivos de tests del relay
> Python y los reemplazó por los del disparador. **1580/3 es el baseline vigente de
> `main`** y es contra ése que se compara el tramo h1.

Los dos gates Python del workflow (`scripts/ci/check_backend_table_refs.py` y
`check_frontend_table_refs.py`) **no corren en este entorno**: exigen `psql` en el
`PATH` del host y acá `psql` sólo existe dentro del contenedor. Corren en CI.

## 7. Gotcha nuevo — el cuerpo vivo LOCAL trae CR embebidos, el de prod no

Medido tras el `db reset`:

| Función | `length(pg_get_functiondef)` local | CRs en `prosrc` | md5 local **quitando** `chr(13)` | md5 prod |
|---|---|---|---|---|
| `_c29_confirm_order_core` | 15484 | **374** | `cecd8c5454611f267a5e131d73bf7928` | `cecd8c5454611f267a5e131d73bf7928` ✅ |
| `c28_register_cash_movement` | 2345 | **57** | `510adc8e150fb5c315e6e9a2635eaff8` | `510adc8e150fb5c315e6e9a2635eaff8` ✅ |

Causa: el working tree está en CRLF (`core.autocrlf=true`) y `psql -f` mete el
archivo tal cual dentro del dollar-quote, así que **cada salto de línea del cuerpo
queda con su `\r` en `prosrc`**. Supabase, en cambio, aplica desde el blob de git
(LF), y prod queda limpio.

Dos consecuencias prácticas para el resto del apply:

1. **Local y prod son idénticos** en las dos funciones a reescribir — pero eso sólo
   se ve **después** de normalizar `chr(13)`. Comparar `md5(pg_get_functiondef(...))`
   crudo entre local y prod da divergencia falsa.
2. Toda verificación de integridad de función que se corra en local (la del cierre:
   "extraer el cuerpo de la migración, quitarle el guard, diffear contra el
   baseline") tiene que hacer `replace(..., chr(13), '')` o normalizar el texto en
   Python. Sin eso, el candado reporta una diferencia que no existe.

Colateral del mismo barrido: en local, `has_function_privilege('service_role', …)`
da **false** para las seis funciones de h1, mientras que en prod da **true**. Es la
otra cara del gotcha #432 — **la verificación de ACLs se hace contra prod**, nunca
contra el stack local.
