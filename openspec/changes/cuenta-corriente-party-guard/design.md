# Design — `cuenta-corriente-party-guard`

> **Governance: MEDIUM** (con un tramo de severidad alta). Toca RPCs de dinero vivas en producción y revoca permisos de la superficie pública de PostgREST. Los checkpoints 🛑 de `tasks.md` exigen mostrarle el resultado al PO antes de seguir.

## Context

### Lo que está roto, con evidencia

La auditoría de tenencia que acompañó al hotfix #446 (2026-08-22) leyó por `pg_get_functiondef` las RPCs `SECURITY DEFINER` de cuenta corriente en prod (`gxdhpxvdjjkmxhdkkwyb`). Confirmó dos familias de problema, ninguna de las cuales entraba en el alcance de ese hotfix (que era sobre repositorios Python que confiaban solo en RLS).

**Familia 1 — incoherencia `(cuenta, parte)`.** Las tres RPCs de pago resuelven el tenant bien y la parte mal:

| RPC | Definición vigente | Resuelve `account_id` | Valida `is_account_writer` | Valida que la parte sea del tenant |
|---|---|---|---|---|
| `rpc_register_payment_received` | `20260907000001` L487 | ✅ `current_account_ids()` | ✅ | ❌ |
| `rpc_register_payment_made` | `20260907000001` L678 | ✅ | ✅ | ❌ |
| `rpc_register_supplier_charge` | `20260720000001` L895 (nunca redefinida) | ✅ | ✅ | ❌ |
| `rpc_create_customer_account` | `20260720000001` L509 | ✅ | ✅ | ✅ `P0404` |
| `rpc_create_supplier_account` | `20260720000001` L565 | ✅ | ✅ | ✅ `P0404` |

Las tres primeras invocan directo `c30_get_or_create_customer_account(v_account_id, p_client_id)` / `c30_get_or_create_supplier_account(...)` (`20260720000001` L443 / L478), que hacen:

```sql
INSERT INTO public.customer_accounts (account_id, client_id, balance, created_by)
VALUES (p_account_id, p_client_id, 0, auth.uid())
ON CONFLICT (account_id, client_id) DO NOTHING;
```

El único FK es `client_id REFERENCES clients(id)` — no está scopeado por tenant, y el `UNIQUE (account_id, client_id)` tampoco lo exige. La fila entra.

**El mismo hueco está en el camino de más volumen.** Los callers del helper compartido `_pay_register_party_charge` reciben `p_client_id`/`p_supplier_id` del payload y tampoco validan:

| Caller | Definición vigente | Guard de tenencia de la parte |
|---|---|---|
| `_c29_confirm_order_core` (POS) | `20261003000001` L1057 | ❌ (sí valida la orden: lee `account_id` de `sales_orders` y aplica `is_account_writer`) |
| `rpc_create_sale_operation_v2` (formulario) | `20261004000001` L848 | ❌ |
| `rpc_create_sale_operation` | `20261002000001` L1397 | ❌ |
| `rpc_create_purchase_operation` | `20261002000001` | ❌ (aún no postea cargo — lo cablea `compras-proveedor-cuenta-corriente`) |

La única validación relacionada es `IF v_kind = 'credit' AND p_client_id IS NULL`. Verificado por ausencia: no hay una sola ocurrencia de `FROM public.clients` en `20261002000001`, `20261003000001` ni `20261004000001`.

**No hay red debajo.** `grep -rn "client_not_found\|supplier_not_found" supabase/migrations/*.sql` devuelve **exactamente 2 líneas** en todo el repo (L541 y L594 de `20260720000001`). No hay trigger, no hay CHECK, no hay constraint compuesta que ate `client_id` a `account_id`.

**Familia 2 — primitiva de escritura cross-tenant (hallazgo nuevo de este propose).** Peor que la anterior, porque no depende de que alguien se equivoque de UUID:

```
_pay_register_party_charge(p_account_id uuid, p_party_kind text, p_party_id uuid, ...)
  SECURITY DEFINER
  GRANT EXECUTE ... TO authenticated      -- 20261001000001 L137
```

Recibe el `account_id` **como parámetro**. No lo resuelve de la sesión, no llama a `current_account_ids()`, no llama a `is_account_writer`. Y está `GRANT`-eada a `authenticated`, o sea que es invocable por PostgREST (`POST /rest/v1/rpc/_pay_register_party_charge`) por cualquier usuario logueado con la anon key —que es pública, va en el bundle del frontend—. Un usuario del tenant A puede escribir un movimiento en la cuenta corriente **real** del tenant B, emitirle un `CustomerAccountCharged` y, vía el outbox, postearle un asiento contable.

`_journal_post_from_event(public.events)` es el mismo caso, con un agravante de proveniencia:

| Migración | ACL para `authenticated` |
|---|---|
| `20260803000001` L517 | `REVOKE EXECUTE` ✅ |
| `20260804000007` L934 | `REVOKE EXECUTE` ✅ |
| `20261001000001` L1914 | **`GRANT EXECUTE`** ❌ |
| `20261004000001` L1778 | `GRANT EXECUTE` ❌ (arrastrado) |

Se perdió en `20261001000001`, cuya cabecera declara literalmente que reafirma "REVOKE/GRANT explícito después del CREATE … mantiene el patrón uniforme". El patrón uniforme —pensado para el gotcha de `ALTER DEFAULT PRIVILEGES` en DROP+CREATE— aplicó `GRANT ... TO authenticated` a un helper que nunca lo tuvo. Recibe una fila de `events` completa (composite; PostgREST acepta un objeto JSON) → permite forjar un evento con cualquier `account_id` y postear un asiento arbitrario.

**Ninguno de los dos tiene caller del lado app.** `grep` sobre `frontend/`, `backend/` y `supabase/functions/` los encuentra solo en comentarios, en tests de migración y en `frontend/lib/database.types.ts` —que es generado, y su presencia ahí es justamente la confirmación de que PostgREST los expone—. El contraste correcto es `_pay_reverse_party_charge` (`20261005000001` L186), nacido en `delete-guard-ledgers` con `REVOKE ALL ... FROM PUBLIC, anon, authenticated`.

**Por qué el gate existente no lo atrapó.** `test_function_acl_gate.sql` tiene dos chequeos: (1) funciones **trigger** `SECURITY DEFINER` ejecutables por `anon`/`authenticated`, y (2) funciones `SECURITY DEFINER` ejecutables por **`anon`**, con allowlist. Ninguna función no-trigger ejecutable por `authenticated` cae en el radar. Es un punto ciego estructural, no un descuido puntual: hay más candidatos vivos con la misma forma (`c28_register_cash_movement(uuid,numeric,text,uuid,text)` tiene `REVOKE ... FROM PUBLIC, anon, authenticated` en `20261006000001` L266 e inmediatamente `GRANT EXECUTE ... TO authenticated` en L267).

### Restricciones que condicionan el diseño

- **Gate de integridad de función** (regla de la casa desde la saga de métodos de pago): toda reescritura de una RPC viva parte del `pg_get_functiondef` de **prod**, no del archivo de migración. El bloque `credit` de C-30 se perdió en silencio exactamente así en julio.
- **ACLs de prod ≠ ACLs de local** (hallazgo post-merge #432, `asiento-venta-formulario`): el proyecto hospedado otorga `EXECUTE` a `anon`/`authenticated` **directamente** sobre funciones nuevas, no vía el pseudo-rol `PUBLIC`. Un `REVOKE ALL ... FROM PUBLIC` que se ve limpio en el stack local puede estar abierto en prod. Toda auditoría de ACL de este change se corre con `has_function_privilege('authenticated', oid, 'EXECUTE')` contra **prod**.
- **`TENANCY_TX_SCOPE_ENABLED` está apagada** (Paso 2 de `v31-tenancy-pool-rls`): el pool del backend Python corre como owner de las tablas, así que la RLS **no aplica** en ese camino. Es el contexto que hizo real la fuga de #446 y la razón por la que el guard tiene que estar en la función, no delegado a RLS.
- **Prohibido**: MCP `apply_migration`, branching de Supabase, cualquier escritura contra prod desde el agente.

## Goals / Non-Goals

**Goals**

1. Que sea **imposible** registrar un cobro, un pago, un cargo manual o un cargo de venta/compra a crédito contra una parte que no pertenece al tenant de la operación — por cualquier camino, presente o futuro.
2. Cerrar la primitiva de escritura cross-tenant de `_pay_register_party_charge` y `_journal_post_from_event`.
3. Dejar una **red permanente** en CI que impida que el "patrón uniforme" de REVOKE+GRANT vuelva a regalar un helper interno al rol de aplicación.
4. Medir —no suponer— si el hueco ya produjo filas corruptas en producción.
5. Cero regresión: los siete gates SQL de dinero vigentes y la suite backend siguen verdes.

**Non-Goals**

- **No** se valida `p_client_id` en las RPCs de alta de venta/compra para el caso **no** crédito. Una venta al contado con `client_id` ajeno sigue siendo posible y sigue siendo un dato malo en `sales` — es un hueco real, más ancho, y merece su propio change (ver OQ-4). Este change cubre todo lo que toca **libros de terceros**.
- **No** se toca `rpc_create_customer_account` / `rpc_create_supplier_account`: ya validan.
- **No** hay reparación automática de datos históricos. Si la auditoría encuentra filas, es checkpoint 🛑 firmado.
- **No** se rediseña `test_function_acl_gate.sql`: se le suma un chequeo (3), respetando su estructura y su convención de allowlist.
- **No** se cambia ninguna firma. Sin `DROP FUNCTION`, sin riesgo 42725.
- Sin superficie frontend (excepción declarada en `proposal.md`).

## Decisions

### D1 — El guard va en el choke point `c30_get_or_create_*`, **y además** explícito en las tres RPCs de pago (opción B, no A)

**Decisión:** las dos capas.

- **Capa 1 (la que cubre)**: `c30_get_or_create_customer_account` y `c30_get_or_create_supplier_account` validan la pertenencia antes del `INSERT`. Una sola redefinición por parte cubre **todos** los llamadores: las 3 RPCs de pago, `_pay_register_party_charge` (→ POS, formulario de venta, y el alta de compra que va a cablear `compras-proveedor-cuenta-corriente`), y los dos `rpc_create_*_account` que ya validaban.
- **Capa 2 (la que comunica)**: las 3 RPCs de pago validan explícito, con el mismo `SELECT ... WHERE id = ? AND account_id = ?` y el mismo `P0404`.

**Alternativas consideradas**

- *Opción A — solo las 3 RPCs de pago (el pedido textual).* **Descartada.** Deja intacto el hueco en `rpc_create_sale_operation_v2`, `rpc_create_sale_operation` y `_c29_confirm_order_core`, que es donde pasa el volumen real (241 operaciones a crédito históricas según `pagos-cableados-restantes`). Arreglar la puerta de servicio y dejar la principal abierta.
- *Opción B pura — solo el choke point.* Descartada por dos motivos concretos, no estéticos: (i) el `RAISE` caería después del `INSERT` de idempotencia en las RPCs de pago (ver D2), y (ii) el mensaje de error vendría de un helper interno, no del dominio del llamador.
- *Un helper nuevo `_party_assert_owned(account_id, kind, id)`.* **Descartado por la Regla de Tres**: quedarían 5 sitios de uso, pero el predicado es un `SELECT 1 ... WHERE id = ? AND account_id = ?` de tres líneas, y el proyecto ya tiene su forma canónica escrita y probada en `rpc_create_customer_account`. La regla de la casa es "reutilización antes que repetición" —reutilizar el **patrón** canónico, no inventar una abstracción nueva para envolverlo—. Además, un helper nuevo sería otra función más que hay que acordarse de REVOKE-ar, que es precisamente el modo de falla que este change está cerrando.

**Por qué B es seguro en el camino de ventas.** El riesgo de mover el guard al choke point es que un `P0404` nuevo aborte transacciones grandes (`rpc_create_sale_operation_v2`, `_c29_confirm_order_core`, `rpc_quick_sale`). Verificado:

- El caso que ahora falla es exactamente el caso que hoy **corrompe**. No hay uso legítimo que se rompa: los selectores de cliente y proveedor del frontend listan filtrando por `account_id`, así que la UI no puede producir el input rechazado.
- `P0404` no termina en 500. Está mapeado a 404 en `backend/core/errors.py` L92 (`_BUSINESS_ERRCODE_STATUS`), y el handler global de `asyncpg.PostgresError` está registrado en `backend/main.py:68`. Además hay mapeo explícito en `backend/services/sales.py` L111, `sales_orders.py` L170, `quotes.py` L174, `customer_accounts.py` L26 y `supplier_accounts.py` L23.
- Los helpers son `SECURITY INVOKER` (solo `SET search_path = public`), pero se invocan siempre desde funciones `SECURITY DEFINER`: el `SELECT` contra `clients`/`suppliers` corre como el definer, sin RLS de por medio, y el filtro por `account_id` es explícito. No hay riesgo de que el guard se auto-bloquee.

### D2 — El guard va **antes** del `INSERT` de idempotencia, no después

En las tres RPCs de pago el orden vigente es: resolver tenant → `is_account_writer` → validar `amount` → validar `payment_method`/`bank_account` → **`INSERT` en `operation_idempotency`** → `c30_get_or_create_*` → movimiento → …

El guard nuevo se ubica junto a las demás validaciones de payload, **antes** del `INSERT` de idempotencia.

Es cierto que un `RAISE` revierte la transacción entera y con ella la fila de `operation_idempotency` —la key no queda "quemada"—, así que funcionalmente daría igual. Se elige el orden temprano por tres razones: (i) coherencia con las otras cuatro validaciones de payload que ya están ahí; (ii) el `RETURN` de replay (`v_inserted = 0`) devuelve el resultado original sin re-ejecutar nada, así que un guard posterior al `INSERT` sería inalcanzable en el segundo intento y el error solo aparecería la primera vez — comportamiento inconsistente; (iii) es más barato.

### D3 — `REVOKE`, no rediseño, para los dos helpers expuestos

`REVOKE EXECUTE ... FROM authenticated` sobre `_pay_register_party_charge(uuid, text, uuid, numeric, uuid, uuid)` y `_journal_post_from_event(public.events)`.

**Alternativa considerada:** agregarles validación de sesión (`current_account_ids()` / `is_account_writer`) para que sean seguras aun expuestas. **Descartada**: son helpers **intra-transacción** llamados desde RPCs que ya validaron; agregarles la validación duplicaría el chequeo en el hot path, y en el caso de `_journal_post_from_event` sería directamente incorrecto (lo invoca el dispatcher del outbox, que corre sin sesión de usuario). El diseño correcto para un helper interno es no ser alcanzable, que es lo que ya hace `_pay_reverse_party_charge`.

**Verificación de que el revoke no rompe nada:** el `PERFORM public._pay_register_party_charge(...)` dentro de una función `SECURITY DEFINER` se ejecuta con los privilegios del definer, no del rol de sesión — el revoke a `authenticated` es transparente para todos los callers reales. Los cuatro callers de `_journal_post_from_event` (`20260803000001` L654, `20260808000001` L461, `20261004000001` L809, `20261005000001` L1051) están todos dentro de `rpc_process_outbox_dispatch`, `SECURITY DEFINER`.

**Se declara BREAKING** en `proposal.md` porque cambia la superficie pública de PostgREST, aunque no haya consumidor conocido.

### D4 — El gate permanente cubre el punto ciego, con allowlist explícita

`test_function_acl_gate.sql` suma un chequeo **(3)**: ninguna función `SECURITY DEFINER` del schema `public` cuyo nombre sea claramente interno —prefijo `_`, o prefijo de fase `c28_`/`c29_`/`c30_`— puede quedar `EXECUTE`-able por `authenticated`, salvo allowlist explícita.

**Por qué por convención de nombre y no por "todas las `SECURITY DEFINER`":** hay decenas de `rpc_*` que legítimamente necesitan `EXECUTE` para `authenticated` (son la API). Gatearlas todas produciría una allowlist de mantenimiento imposible que nadie leería —y una allowlist que nadie lee es un gate apagado—. El prefijo `_` ya es la convención del proyecto para "helper intra-transacción", y `c28_`/`c29_`/`c30_` es la convención de los helpers de fase. La regla de mantenimiento es la misma que ya tiene el gate: **achicar** la allowlist siempre es válido; **agregar** una entrada exige justificar en el PR por qué ese helper necesita ser invocable desde el rol de aplicación.

Se espera que la primera corrida encuentre offenders más allá de los dos que este change revoca —`c28_register_cash_movement` y `_c29_confirm_order_core` son candidatos conocidos—. **Se entran a la allowlist con su comentario, no se revocan en este change** (ver OQ-3): revocar `c28_register_cash_movement` o `_c29_confirm_order_core` sin auditar sus llamadores es exactamente el tipo de cambio que rompe el POS en producción un sábado. El gate los deja anotados y visibles, que es su función.

### D5 — Migración idempotente, sin `DROP`, con reafirmación de ACLs

- Nombre: `20261010000001_cuenta_corriente_party_guard.sql` (renumerado desde `20261008000001` — ver "Post-apply (2026-08-23)", punto (f)). El MAX local era `20261006000001` al abrir el propose, pero `20261007000001_cuentas_billetera_tipo.sql` (PR #447) aterrizó en `main` **mientras este propose estaba en revisión** y se quedó con ese número — de ahí el `20261008`. **La task 1.1 vuelve a verificar el MAX vivo en prod antes de escribir el archivo** y renumera si prod está más adelante todavía.
- `CREATE OR REPLACE` puro: ninguna de las cinco funciones cambia de firma, así que no hay overload 42725 ni hace falta `DROP`. `CREATE OR REPLACE` preserva ACLs, pero se reafirman igual tras cada `CREATE` —patrón uniforme documentado en la cabecera de `20261001000001`—, **con una corrección importante**: para los helpers internos la reafirmación es `REVOKE ALL ... FROM PUBLIC, anon, authenticated` **sin `GRANT`**. Copiar el bloque REVOKE+GRANT tal cual es precisamente el bug que produjo el hallazgo (D3).
- Sin BOM UTF-8 (hay gate en CI).
- Se reaplica dos veces en local y se verifica que el segundo apply es no-op.

### D6 — Sin ERRCODEs nuevos

Se reutiliza `P0404` con los mensajes canónicos `client_not_found: %` y `supplier_not_found: %`. Acuñar un código nuevo obligaría a mapearlo en `backend/core/errors.py` y en cinco services, y a documentarlo — para expresar exactamente la misma semántica que ya expresa `P0404` en las dos RPCs hermanas. `test_errcode_5char_gate.sql` sigue verde por construcción (5 caracteres).

### D7 — La reparación histórica es un checkpoint firmado, nunca una migración

Igual que el backfill de `delete-guard-ledgers`: si la auditoría read-only encuentra filas corruptas, el script vive en `scripts/sql/` (dato puntual, no schema), se ejecuta post-merge, gateado por conteos re-medidos inmediatamente antes, y con firma explícita del PO. Lo esperable es 0 filas —el vector de la Familia 1 exige conocer un UUID ajeno, y el de la Familia 2 exige un ataque deliberado—, pero se mide.

## Risks / Trade-offs

| Riesgo | Mitigación |
|---|---|
| **Reescribir las 3 RPCs desde el archivo de migración y perder un bloque vivo** (le pasó al bloque `credit` de C-30 en julio) | Checkpoint 🛑 task 1.4: capturar `pg_get_functiondef` de prod, guardarlo en `baseline/`, diffear contra el archivo, **reportar antes de escribir una línea de SQL**. La sesión que redactó este propose **no pudo** capturar los baselines (ver "Estado del baseline" abajo) — el checkpoint es obligatorio, no opcional. |
| El `P0404` nuevo en el choke point rompe un camino legítimo de venta/POS | Verificado que `P0404 → 404` está mapeado global y localmente (D1). Tests SQL específicos: venta a crédito con cliente propio sigue funcionando (control positivo) y con cliente ajeno falla sin dejar filas. Los siete gates de dinero vigentes se re-corren como safety net. |
| El `REVOKE` rompe un consumidor no identificado de PostgREST | `grep` sobre `frontend/`, `backend/` y `supabase/functions/` da cero callers reales. Los `PERFORM` internos corren como definer. Rollback trivial: un `GRANT` de una línea. |
| **ACLs de prod distintas a las de local** — el revoke se ve aplicado en CI y en prod queda abierto | La task de auditoría corre `has_function_privilege('authenticated', oid, 'EXECUTE')` **contra prod** post-merge, no solo en CI (gotcha #432). El `REVOKE` se escribe con la lista completa `FROM PUBLIC, anon, authenticated`, no solo `FROM PUBLIC`. |
| El gate (3) nuevo falla el pipeline con offenders preexistentes y bloquea el PR | Se descubre la lista real en la task 6.2 **antes** de escribir el gate, y los preexistentes entran a la allowlist con su comentario (D4). El gate nace verde y sirve de aquí en adelante. |
| La cadena de reapply de CI se desincroniza | La migración se suma como **último** eslabón, con comentario propio. No cambia ninguna firma, así que no puede generar overloads fantasma — es el caso más simple de la cadena. |
| Solapamiento con `compras-proveedor-cuenta-corriente` | No hay conflicto de archivos: aquel toca `suppliers`, el formulario de compra y `rpc_create_purchase_operation`; este toca los helpers `c30_get_or_create_*`, las 3 RPCs de pago y dos ACLs. Si `compras-*` se aplica primero, queda cubierto sin cambios (el guard está en el choke point). Recomendado: **este change primero**. |

### Estado del baseline de prod

**No se pudieron capturar los baselines en este propose.** El worktree tiene el proyecto linkeado (`supabase/.temp/project-ref` = `gxdhpxvdjjkmxhdkkwyb`) y hay un stack local en Docker con `psql` disponible dentro del contenedor, pero `supabase/.temp/pooler-url` **no contiene contraseña** (`fe_sendauth: no password supplied` al intentar la conexión) y la lectura de `backend/.env` está denegada para el agente. No hay `psql` en el PATH del host ni cliente Postgres en `node_modules`.

En consecuencia, `baseline/` queda **vacío** y la captura pasa a ser el checkpoint 🛑 de la task 1.4, que debe ejecutar quien tenga las credenciales antes de escribir la migración. Las cinco definiciones a capturar:

```
public.c30_get_or_create_customer_account(uuid, uuid)
public.c30_get_or_create_supplier_account(uuid, uuid)
public.rpc_register_payment_received(text, uuid, numeric, uuid, text, uuid)
public.rpc_register_payment_made(text, uuid, numeric, uuid, text, uuid)
public.rpc_register_supplier_charge(text, uuid, numeric, uuid)
```

Se dejan documentadas acá las **referencias de archivo** contra las que hay que diffear, que sí están verificadas: `20260907000001` L487 / L678 para las dos primeras RPCs de pago, `20260720000001` L895 para `rpc_register_supplier_charge`, y `20260720000001` L443 / L478 para los dos helpers.

## Migration Plan

1. **Pre**: safety net (suite backend 1495/1495, gates SQL verdes), MAX de migraciones en prod, captura de baselines 🛑.
2. **RED**: `supabase/tests/test_cuenta_corriente_party_guard.sql` escrito y fallando contra el schema actual.
3. **GREEN**: `20261010000001_cuenta_corriente_party_guard.sql` — guards + ACLs. Doble apply en local sin diferencia.
4. **CI**: eslabón de reapply + step del test nuevo + chequeo (3) en el gate de ACLs.
5. **Backend**: tests pytest de propagación `P0404 → 404`.
6. **Auditoría read-only en prod** de filas corruptas → si hay, checkpoint 🛑.
7. **Post-merge**: verificar en prod `MAX(version) = 20261010000001` y que `has_function_privilege('authenticated', ...)` es `false` para los dos helpers revocados.

**Rollback.** Cada pieza revierte por separado y sin pérdida de datos:
- Guards: `CREATE OR REPLACE` con el cuerpo del baseline (por eso el baseline es obligatorio).
- ACLs: un `GRANT EXECUTE ... TO authenticated` de una línea.
- Gate (3): borrar el bloque del test.
Nada de esto muta datos, así que no hay rollback de datos que planificar. La única operación que sí muta datos —la reparación histórica— es un script aparte, post-merge y firmado.

## Open Questions

> El apply implementa la **recomendación** de cada OQ si el PO no responde. Las que están marcadas 🛑 requieren respuesta antes de la task correspondiente.

**OQ-1 — ¿Alcance del guard: opción A (3 RPCs) o B (choke point + 3 RPCs)?**
*Recomendación: **B**.* A sola deja el hueco abierto en el camino de venta a crédito, que es el de volumen. B es una redefinición de dos helpers de 15 líneas, cubre todo caller presente y futuro, y no rompe ningún uso legítimo (verificado el mapeo `P0404 → 404` en los cinco services relevantes). El costo de B sobre A es un test SQL más.

**OQ-2 🛑 — ¿El `REVOKE` de `_pay_register_party_charge` y `_journal_post_from_event` entra en este change o se saca como hotfix inmediato?**
*Recomendación: **entra en este change**, salvo que el PO prefiera cortarlo antes.* Es la mitad más grave del hallazgo y son tres líneas de SQL con rollback de una línea, así que no justifica un change propio. Pero es una decisión del PO: si prefiere el patrón de #446 (hotfix de seguridad directo a `main`, mergeado el mismo día), las dos líneas de `REVOKE` se separan a un PR propio y este change se queda con los guards y el gate. **Lo que no es aceptable es dejarlo abierto esperando el apply.** Marcado 🛑 porque cambia el orden de trabajo.

**Resuelto 2026-08-23 — hotfix, no apply.** El PO ordenó "arreglalo" el mismo día que se detectó: el `REVOKE` salió como hotfix directo a `main` (PR #454, rama `fix/revoke-internal-money-helpers`, `supabase/migrations/20261010000001_revoke_internal_money_helpers.sql`), patrón #446. El **grupo 5** de `tasks.md` queda SUPERSEDED por ese PR — no repetir el `REVOKE` en el apply de este change. El gate que agregó ese hotfix a `test_function_acl_gate.sql` es un **check (3) angosto** (lista cerrada `v_internal_only_fns`: los 2 helpers + `_pay_reverse_party_charge`), distinto del **gate (3) amplio** que describe este design (patrón de nombre `_%`/`c28_%`/`c29_%`/`c30_%` + allowlist, tasks 6.1-6.8) — el apply de este change debe agregar el suyo como **check (4)**, no (3), y actualizar la numeración de las tasks del grupo 6 en consecuencia.

**OQ-3 — Los offenders preexistentes del gate (3): ¿allowlist o revoke?**
*Recomendación: **allowlist con comentario, revoke en un change propio**.* Se conocen al menos dos candidatos (`c28_register_cash_movement` con su `GRANT` inmediatamente después del `REVOKE` en `20261006000001` L266-267, y `_c29_confirm_order_core`, que sí valida `is_account_writer` sobre el `account_id` que lee de la orden — o sea que está expuesto pero **no** es una primitiva cross-tenant). Revocarlos sin auditar sus llamadores arriesga el POS. El gate los deja anotados y visibles, que es el 90% del valor.

**OQ-4 — La venta/compra **no** crédito con `client_id`/`supplier_id` ajeno queda sin guard. ¿Change propio?**
*Recomendación: **sí, change propio (`operacion-party-guard`), fuera de este alcance**.* Este change cubre todo lo que toca libros de terceros. Una venta al contado con `client_id` ajeno no crea saldo ni asiento contra un tercero, pero sí deja una fila mala en `sales` que ninguna pantalla va a mostrar. El guard natural es validar `p_client_id` en `rpc_create_sale_operation(_v2)`, `_c29_confirm_order_core` y `rpc_create_purchase_operation` — cuatro RPCs grandes, cada una con su baseline y su reescritura completa. Meterlo acá triplicaría el riesgo del change por un problema estrictamente menor.

**OQ-5 — Si la auditoría encuentra filas corruptas: ¿borrar, reasignar o dejar y anotar?**
*Recomendación: **decidirlo con los datos a la vista, no antes**.* Sin filas no hay pregunta. Con filas, la reparación depende de si hay dinero real detrás (un `payment_received` contra un cliente ajeno es plata que entró y hay que atribuir a alguien) o si es una fila de saldo 0 sin movimientos (se borra). Checkpoint 🛑 con los conteos reales.

**OQ-6 — ¿Se agrega un constraint de integridad referencial compuesta en vez del guard en código?**
*Recomendación: **no**.* La forma "correcta" en Postgres sería `UNIQUE (id, account_id)` en `clients` y un `FOREIGN KEY (client_id, account_id) REFERENCES clients (id, account_id)` en `customer_accounts` — declarativo, imposible de saltear, sin costo en el hot path. Se descarta para este change por dos razones: (i) `clients.account_id` es nullable en el histórico, y un FK compuesto exige garantizar que no lo sea, lo que arrastra un backfill y una validación de tabla completa en prod; (ii) no cubre la Familia 2 (el atacante que pasa un `account_id` ajeno **con** un cliente de ese tenant satisface el FK perfectamente). Vale la pena como endurecimiento posterior, no como reemplazo. Queda anotado como candidato.
