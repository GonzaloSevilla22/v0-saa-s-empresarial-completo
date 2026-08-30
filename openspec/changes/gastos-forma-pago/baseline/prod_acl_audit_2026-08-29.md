# Auditoría de ACLs y daño preexistente en PROD — `gastos-forma-pago`

- **Proyecto**: `gxdhpxvdjjkmxhdkkwyb` (prod, usuarios reales)
- **Fecha de captura**: 2026-08-29
- **Método**: MCP `execute_sql`, **SOLO `SELECT`** (sin DDL ni DML). Tasks 1.1, 1.6, 1.7, 1.8 y 1.10 de `tasks.md`.
- **Gotcha #432 vigente**: prod concede `EXECUTE` directo a los roles, no vía `PUBLIC`. Todo se midió con `has_function_privilege(<rol>, oid, 'EXECUTE')` **y** con el `proacl` crudo.

---

## 1. Task 1.1 — número de la migración

| Medición | Valor |
|---|---|
| `MAX(version)` en `supabase_migrations.schema_migrations` (prod) | **`20261014000001`** |
| Migraciones registradas en prod | **263** |
| Último archivo en `supabase/migrations/` de `origin/main` | `20261014000001_sucursal_guard_vaciado_auditoria.sql` |
| Archivos `.sql` en el repo | 263 |

**Prod y repo están sincronizados exactamente.** El número previsto por el propose sigue libre: la migración de este change nace como **`20261015000001_gastos_forma_pago.sql`**.

> ⚠️ **Se re-verifica otra vez inmediatamente antes de escribir el archivo** (task 2.2). En este proyecto la renumeración mordió tres veces: `cuenta-corriente-party-guard` se renumeró 3× y el número que preveía `tenancy-guard-caja-outbox` se lo llevó un hotfix.

---

## 2. Tasks 1.6 y 1.7 — gate de integridad de función

### Resultado: **11 de 11 sin divergencia. Cero hallazgos.**

Se capturó el `pg_get_functiondef` **vivo de prod** de las 11 funciones que este change reescribe o de las que copia predicados. Cada baseline vive en `baseline/<nombre>.sql` con cabecera de procedencia, `md5` y `length`.

| Función | Rol en el change | md5 (prod) | length | Último archivo que la declara | Cuerpo vivo textual en ese archivo |
|---|---|---|---|---|---|
| `rpc_payment_method_report` | **SE REESCRIBE** (D14) | `e452c30331368d3bdbc0c24bc305dda2` | 3370 | `20260928000001_payment_methods_operaciones.sql` | ✅ |
| `rpc_create_sale_operation_v2` | referencia: opt-in de caja + derivación de `kind` (D1) | `0b6bcc5b6caa1a3c01e0da16518c7d35` | 13914 | `20261004000001_asiento_venta_formulario.sql` | ✅ |
| `rpc_create_purchase_operation` | referencia: pata bancaria de egreso (D2) | `058f4d291d85bec0ae46589bde49e3a3` | 19438 | `20261009000001_compras_proveedor_cuenta_corriente.sql` | ✅ |
| `rpc_delete_sale_operation` | referencia: compensación de dos patas (D8) | `8b99cf9f0fc19f4aa999f1906160aa3a` | 6809 | `20261005000001_delete_guard_ledgers.sql` | ✅ |
| `rpc_atomic_update_sale_operation` | referencia: guards `P0423` + tri-estado (D11/D12) | `b46e4c8c2780e28affc280953cc20310` | 26592 | `20261004000001_asiento_venta_formulario.sql` | ✅ |
| `c28_register_cash_movement` | reuso sin tocar: pata de caja | `1b0692ad5ba614f267389b335e4d366a` | 4413 | `20261013000001_tenancy_guard_caja_sesion.sql` | ✅ |
| `_pay_register_operation_bank_movement` | reuso sin tocar: pata bancaria | `89bd5f041fbee39a44925d1f3aff61c6` | 3231 | `20261002000001_pos_banco_movimientos.sql` | ✅ |
| `_pay_resolve_bank_account` | reuso sin tocar: resolución de cuenta | `0a9dcc86484b07a7bf66a52c64b213d0` | 1488 | `20261002000001_pos_banco_movimientos.sql` | ✅ |
| `_register_bank_movement` | reuso sin tocar: reversa por borrado (D8) | `6005feacb6c1a62bb1918f8f4d47949e` | 1943 | `20260804000002_bank_account_ledger.sql` | ✅ |
| `c26_default_branch` | reuso sin tocar: `COALESCE` de sucursal (D6) | `5fa1096b4c1481b36d6e04c8eaadbfdc` | 469 | `20260625000001_c26_branch_as_root.sql` | ✅ |
| `reporting_local_today` | reuso sin tocar: día local ART (D1) | `83e9af886e5b9317c1e4aa90b83e3659` | 184 | `20260814000001_v3_reporting_invariants.sql` | ✅ |

### Cómo se verificó (más fuerte que un diff a ojo)

1. Se midió `md5(pg_get_functiondef(oid))` **en prod** vía MCP.
2. Se midió lo mismo en el stack local recién reseteado (`npx supabase db reset` sobre las **mismas 263 migraciones** del repo).
3. **Los 11 md5 coinciden EXACTO.** Como el stack local se construye reproduciendo el repo entero, la igualdad prueba que **la cadena de migraciones del repo produce byte a byte el cuerpo vivo de prod**: no hay ninguna divergencia repo↔prod en estas 11 funciones. Es la forma fuerte de la task 1.7 — un diff textual archivo por archivo es más débil, porque `pg_get_functiondef` normaliza la declaración.
4. Además se verificó, para cada función, que el **cuerpo vivo aparece textual** dentro del último archivo que la declara (columna final de la tabla). Esto importa porque **36 migraciones del repo usan `pg_get_functiondef` para reescribir funciones in-place**, y en ese patrón el archivo puede dejar de ser fuente segura para copiar predicados. **No es el caso de ninguna de las 11**: el archivo y lo vivo coinciden.

> **Antecedente que motivaba el chequeo**: el G3 de `20261003000001` había sido reescrito in-place y quedó desalineado con su archivo (`compras-proveedor-cuenta-corriente`). **Esta vez no se reprodujo.**

### Nota de procedencia del byte exacto

El stack local guarda **CR embebidos** en los cuerpos, porque los `.sql` del working tree están en CRLF (`core.autocrlf=true`). Por eso el hash se calcula sobre `replace(def, chr(13), '')`, que da **byte-idéntico a prod**. Los archivos de `baseline/` quedan en LF y se congelan con un `.gitattributes` propio (`*.sql -text`), para que el `md5` de la cabecera siga siendo verificable después de un checkout — cosa que **no** pasa con `archive/2026-08-23-cuenta-corriente-party-guard/baseline/`, que quedó `w/crlf`.

---

## 3. Task 1.8 — permisos vivos en prod

```sql
SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args, p.prosecdef,
       has_function_privilege('anon',p.oid,'EXECUTE')          AS anon,
       has_function_privilege('authenticated',p.oid,'EXECUTE') AS authenticated,
       has_function_privilege('service_role',p.oid,'EXECUTE')  AS service_role,
       coalesce(array_to_string(p.proacl,' | '),'(null)')       AS proacl
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname IN (...);
```

| Función | secdef | anon | authenticated | service_role | `proacl` |
|---|---|---|---|---|---|
| `rpc_payment_method_report` | true | false | **true** | true | `postgres=X/postgres \| authenticated=X/postgres \| service_role=X/postgres` |
| `rpc_create_sale_operation_v2` | true | false | true | true | `postgres=X \| authenticated=X \| service_role=X` |
| `rpc_create_purchase_operation` | true | false | true | true | `postgres=X \| authenticated=X \| service_role=X` |
| `rpc_delete_sale_operation` | true | false | true | true | `postgres=X \| service_role=X \| authenticated=X` |
| `rpc_atomic_update_sale_operation` | true | false | true | true | `postgres=X \| authenticated=X \| service_role=X` |
| `c28_register_cash_movement` | **false** | false | true | true | `postgres=X \| service_role=X \| authenticated=X` |
| `_pay_register_operation_bank_movement` | true | false | **false** | true | `postgres=X \| service_role=X` |
| `_pay_resolve_bank_account` | true | false | **false** | true | `postgres=X \| service_role=X` |
| `_register_bank_movement` | true | false | **false** | true | `postgres=X \| service_role=X` |
| `c26_default_branch` | false | false | **false** | true | `postgres=X \| service_role=X` |
| `reporting_local_today` | false | true | true | true | `=X/postgres \| postgres=X \| anon=X \| authenticated=X \| service_role=X` |
| `is_account_writer` | true | true | true | true | `postgres=X \| anon=X \| authenticated=X \| service_role=X` |
| `current_account_ids` | true | true | true | true | `postgres=X \| anon=X \| authenticated=X \| service_role=X` |

**Lecturas relevantes para el change:**

- Los tres helpers de dinero (`_pay_*`, `_register_bank_movement`) tienen `authenticated = false`: son internos, sólo alcanzables desde una RPC `SECURITY DEFINER` que corra como `postgres`. Es el estado que dejó `20261010000001_revoke_internal_money_helpers.sql` tras el hotfix #454. **Las tres RPCs nuevas de gasto tienen que ser `SECURITY DEFINER` para poder llamarlos** — no es una preferencia de estilo, es la única forma de alcanzarlos.
- `c28_register_cash_movement` es **`SECURITY INVOKER`** (`prosecdef = false`) con `EXECUTE` para `authenticated`. Dato a tener presente en el grupo 4: se lo llama desde adentro de un `DEFINER`, así que corre con los privilegios del invocador de la RPC, no de `postgres`.
- `reporting_local_today` conserva la entrada `PUBLIC` (`=X/postgres`) — es anterior a la política de REVOKE. No se toca (fuera de alcance).

### Verificación adicional: qué ACLs deja el `DROP FUNCTION` + `CREATE` de D14

D14 exige re-emitir las ACLs completas después del `DROP`, porque el `DROP` las resetea. Se midió el **default privilege** vivo de prod para no suponer cuál es el estado post-`CREATE`:

```sql
SELECT pg_get_userbyid(defaclrole), nspname, defaclobjtype, array_to_string(defaclacl,' | ')
FROM pg_default_acl d LEFT JOIN pg_namespace n ON n.oid=d.defaclnamespace
WHERE defaclobjtype='f' AND nspname='public';
```

| owner | schema | default ACL para funciones nuevas |
|---|---|---|
| `postgres` | `public` | `postgres=X \| anon=X \| authenticated=X \| service_role=X` |
| `supabase_admin` | `public` | `postgres=X \| anon=X \| authenticated=X \| service_role=X` |

**Consecuencia (verificada, no supuesta):** una función recién creada en `public` nace con `anon + authenticated + service_role` y **sin entrada `PUBLIC`** (el `pg_default_acl` reemplaza al default interno, que sí incluiría `PUBLIC`). Entonces la secuencia de D14 —`REVOKE ALL FROM PUBLIC` (no-op acá) + `REVOKE EXECUTE FROM anon` + `GRANT EXECUTE TO authenticated`— reconstruye **exactamente** el `proacl` vivo de hoy: `postgres=X | authenticated=X | service_role=X`. `service_role` vuelve solo por el default privilege; **no hace falta un `GRANT` explícito** para él, y tampoco lo tiene hoy la migración `20260928000001:1945-1947`.

---

## 4. Task 1.10 — auditoría de daño preexistente

Todos los conteos son `SELECT` sobre prod.

| # | Chequeo | Esperado | **Medido** |
|---|---|---|---|
| a | `cash_movements` con `movement_type = 'expense'` | 0 | **0** |
| b | `cash_movements` con `movement_type = 'expense_reversal'` | 0 (el tipo ni existe en el `CHECK`) | **0** |
| c | `cash_movements` cuyo `reference_id` apunta a un gasto | 0 | **0** |
| d | `bank_movements` con `source_doc_type = 'expense'` | 0 | **0** |
| e | `bank_movements` cuyo `source_doc_ref` apunta a un gasto | 0 | **0** |

**Resultado: 0 en los cinco conteos. No hay daño histórico que reparar y no hay blocker.** Es coherente con la premisa del change: el camino nunca existió, así que no pudo ensuciar nada.

### Estado medido que el design daba por cierto (re-verificado hoy, 1 día después)

| Hecho | Valor en el design (2026-08-28) | **Hoy (2026-08-29)** | ¿Cambió? |
|---|---|---|---|
| Gastos en prod | 175 | **175** | no |
| Gastos con `branch_id` | 0 | **0** | no |
| Gastos con `cost_center_id` | 0 | **0** | no |
| `payment_methods` con `bank_account_id` | 0 | **0** | no |
| Cuentas con ≥1 `bank_accounts` activa | 4 | **4** | no |
| `cash_movements` totales | 67 | **67** | no |

Ninguna premisa del design se movió. En particular sigue en pie el bloqueante de producto de **D5**: **0 catálogos con destino bancario configurado**, así que sin el guard `P0412` en el caller de gasto el pedido del PO fallaría en silencio para el 100% de los tenants.
