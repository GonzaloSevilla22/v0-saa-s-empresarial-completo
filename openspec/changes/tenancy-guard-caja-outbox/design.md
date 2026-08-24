# Design — `tenancy-guard-caja-outbox`

> **Governance: CRÍTICO.** Dominio seguridad multi-tenant + dinero (arqueo de caja) + contabilidad (outbox → asientos). **El apply no arranca sin sign-off explícito del PO** (checkpoint 🛑 en `tasks.md` 0.1). El PO autorizó *proponer*, no *aplicar*. Los demás checkpoints 🛑 exigen mostrarle el resultado antes de seguir.

## Context

### Lo que está roto, con evidencia

Todo lo de esta sección se midió el **2026-08-23 contra producción** (`gxdhpxvdjjkmxhdkkwyb`, sólo `SELECT`, vía MCP) leyendo el `pg_get_functiondef` **vivo**, no los archivos de migración. Los dos hallazgos salieron de la auditoría del vecindario de `cuenta-corriente-party-guard`, que los dejó anotados como h1 y h2 en su `design.md` §"Hallazgos laterales de la revisión de seguridad" sin corregirlos.

#### Familia 1 (h1) — la sesión de caja no se valida en el POS

| Camino | Definición viva | Valida sesión abierta | Valida sucursal de la caja | Valida tenant de la caja |
|---|---|---|---|---|
| `rpc_create_sale_operation_v2` (formulario) | md5 `0b6bcc5b6caa1a3c01e0da16518c7d35`, len 13914 | ✅ | ✅ `cb.branch_id = v_gate_branch` | ✅ (implícito: la sucursal es la efectiva del tenant) |
| `rpc_create_sale_operation` (legacy) | md5 `74c8bfb096ec770ab43e4ba47111bfed` | ✅ | ✅ | ✅ |
| `rpc_register_cash_movement` (ajustes) | md5 `914e0c3ce6fa15275822121c4dec51d0` | ✅ (delega) | — | ✅ `is_account_writer` sobre `branches.account_id` |
| `rpc_delete_sale_operation` (compensación) | md5 `8b99cf9f0fc19f4aa999f1906160aa3a` | ✅ `P0426` | — | ✅ (deriva la caja de los movimientos de la operación, ya validada) |
| **`_c29_confirm_order_core` (POS)** | md5 `cecd8c5454611f267a5e131d73bf7928`, len 15110 | ❌ | ❌ | ❌ |

El texto vivo del formulario, que es el patrón a copiar:

```sql
SELECT cs.status, cb.branch_id INTO v_cash_session_status, v_cash_session_branch
FROM public.cash_sessions cs
JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
WHERE cs.id = p_cash_session_id;

IF v_cash_session_status IS DISTINCT FROM 'open'
   OR v_cash_session_branch IS DISTINCT FROM v_gate_branch THEN
  RAISE EXCEPTION 'cash_optin_requires_open_session: la sesión de caja debe estar abierta y pertenecer a la sucursal efectiva de la venta'
    USING ERRCODE = 'P0422';
END IF;
```

El texto vivo del POS, que es todo lo que hay:

```sql
IF v_kind = 'cash' AND p_cash_session_id IS NULL THEN
  RAISE EXCEPTION 'cash_requires_session: payment_method=cash exige cash_session_id'
    USING ERRCODE = 'P0400';
END IF;
```

…y 350 caracteres más adelante, `PERFORM public.c28_register_cash_movement(p_cash_session_id, v_total, 'sale', p_sales_order_id)` — el parámetro llega crudo desde el payload.

`c28_register_cash_movement(uuid,numeric,text,uuid,text)` (md5 `510adc8e150fb5c315e6e9a2635eaff8`, len 2288) es **`SECURITY INVOKER`** (`prosecdef = false`, contra lo que anticipaba el design del change anterior, que ya lo corrigió) y sólo valida `status = 'open'` y `branches.status = 'active'`. No consulta `account_id` en ningún lado. Como sus cinco llamadores son `SECURITY DEFINER` y corren como `postgres`, la RLS de `cash_movements` no interviene.

**Exposición real, no teórica.** En prod hay **65 movimientos de caja** (63 `sale` + 2 `sale_reversal`), **los 65 con `reference_id` en `sales_orders`**: el 100 % del ledger de caja vivo entró por el único camino sin guard. Hay **4 sesiones de caja, 3 abiertas, en 3 tenants distintos**. La precondición del ataque —conocer el UUID de una sesión abierta ajena— es la misma que la de la Familia 1 del change anterior: no es enumerable por RLS, pero tampoco es un secreto criptográfico.

**Consecuencia de segundo orden.** `rpc_delete_sale_operation` deriva la caja a compensar de los `cash_movements` de la operación borrada. Si h1 ya metió un movimiento fantasma en la caja de otro tenant, borrar esa venta intenta escribir el contra-movimiento **también** en la caja de la víctima, o falla con `P0426` si esa caja no tiene sesión abierta. El hueco contamina el camino de borrado sin tocarlo.

#### Familia 2 (h2) — el outbox no filtra por tenant, y el endpoint no filtra por rol

| Función | `prosecdef` | `anon` | `authenticated` | `service_role` | Filtra tenant |
|---|---|---|---|---|---|
| `rpc_process_outbox_batch(integer)` | ✅ | ❌ | **✅** | ✅ | ❌ |
| `rpc_mark_event_processed(uuid)` | ✅ | ❌ | **✅** | ✅ | ❌ |
| `rpc_process_outbox_dispatch(integer)` | ✅ | ❌ | ❌ | ✅ | ❌ (correcto: no es alcanzable) |

Las dos primeras nacen en `20260718000001_c25_events_outbox_reconcile.sql` (L172 y L203) con `REVOKE … FROM PUBLIC` + `REVOKE … FROM anon` + **`GRANT EXECUTE … TO authenticated`**, y ninguna migración posterior las revoca. El lote `20260830000001` las conservó adrede pensando en el Paso 2 del pool. Reproducido en local con `SET LOCAL ROLE authenticated` y los claims del usuario A: el batch devuelve eventos del tenant B con el payload completo (`account_id`, `amount`, `client_id`) y `rpc_mark_event_processed` los cierra.

El endpoint que las consume, `POST /outbox/process-pending` (`backend/routers/outbox.py` L32-35), sólo declara `auth: dict = Depends(get_current_user)`. No hay `require_role`, no hay `require_platform_admin`. Y el pool corre como owner (`TENANCY_TX_SCOPE_ENABLED` apagada), así que ni siquiera la RLS interviene.

#### Familia 2 bis (h2 bis) — dos relays compitiendo por el mismo flag

Esto **no** estaba en el hallazgo original. Se verificó leyendo los dos consumidores, no se asumió.

| | `rpc_process_outbox_dispatch` (pg_cron job 8) | `OutboxRelayService` (endpoint Python) |
|---|---|---|
| Selección | `WHERE processed_at IS NULL` `FOR UPDATE SKIP LOCKED` | idéntica, vía `rpc_process_outbox_batch` |
| Consumer 1 AuditLog | ✅ | ✅ |
| Consumer 2 Email | ✅ | ✅ |
| **Consumer 3 JournalEntry** | ✅ `_journal_post_from_event` | ❌ |
| **Consumer 4 Notification** | ✅ `_notification_from_event` | ❌ |
| Marca `processed_at` | después de los 4 | **después de los 2** |

Los dos leen el mismo predicado y escriben el mismo flag. **Todo evento que gane el relay Python queda cerrado sin su asiento contable ni su notificación, para siempre**: el dispatcher no lo vuelve a ver. La idempotencia por `(event_id, consumer_type)` no salva nada — protege contra duplicados, no contra omisiones.

Tres confirmaciones independientes de que el relay Python es el que sobra, no el dispatcher:

1. **El spec vigente ya lo dice.** `openspec/specs/transactional-outbox/spec.md`, requirement "Outbox relay dispatch": *"The relay SHALL run its consumers in order — AuditLog (1), EmailNotification (2), JournalEntry (3), Notification (4)"*. El relay Python **incumple el spec como está escrito hoy**.
2. **El cron no lo llama.** `cron.job` id 8 (`relay-process-outbox`, `* * * * *`) ejecuta `SELECT public.rpc_process_outbox_dispatch(100)`, y su propio comentario dice: *"El endpoint Python (/outbox/process-pending) se mantiene como trigger manual/secundario para debugging y operaciones puntuales"*. El docstring del router, en cambio, afirma *"Called by the pg_cron job relay-process-outbox (Decision 1)"* — **está desactualizado** desde el pivot de C-25.
3. **`v31-tenancy-pool-rls` ya lo tiene marcado para morir.** Su inventario del Paso 2 lista `events` y `email_logs` entre las tablas con INSERT directo del backend y **cero policy de INSERT** para `authenticated`. El relay Python inserta directo en `audit_logs`, `email_logs` y `operation_idempotency`: el día que se encienda `TENANCY_RLS_ROLE_ENABLED`, ese camino se rompe entero. El `OutboxRepository.insert_audit_log` tiene, en su propio docstring, cinco párrafos de disculpas sobre este mismo problema sin resolverlo.

**Daño histórico: cero.** 626 eventos, 0 pendientes, 10 tenants con eventos, 464 eventos elegibles para asiento y 465 asientos, **0 eventos procesados sin su asiento**. El endpoint nunca se usó en producción. Sigue siendo un botón, sin llave, que borra la contabilidad de todos los tenants.

### Restricciones que condicionan el diseño

- **Gate de integridad de función** (regla de la casa desde la saga de métodos de pago): toda reescritura de una RPC viva parte del `pg_get_functiondef` de **prod**, nunca del archivo. El bloque `credit` de C-30 se perdió en silencio exactamente así en julio. `_c29_confirm_order_core` es la RPC más grande que este change reescribe (15 110 caracteres) y **ya tiene antecedentes de divergencia**: `compras-proveedor-cuenta-corriente` encontró que su `pg_get_functiondef` vivo no coincidía con el último archivo por una reescritura in-place del G3 de `20261003000001`.
- **ACLs de prod ≠ ACLs de local** (gotcha #432): el proyecto hospedado otorga `EXECUTE` a `anon`/`authenticated` **directo**, no vía `PUBLIC`. Todo `REVOKE` nombra la lista completa `PUBLIC, anon, authenticated`, y la verificación se corre contra **prod**.
- **`TENANCY_TX_SCOPE_ENABLED` y `TENANCY_RLS_ROLE_ENABLED` están apagadas.** El pool corre como owner: la RLS no aplica en el camino del backend. Es la razón por la que los guards van en la función, no delegados a RLS — y también la razón por la que el diseño de h2 tiene que sobrevivir a que se enciendan (D3).
- **Prohibido**: MCP `apply_migration`, branching de Supabase, cualquier escritura contra prod desde el agente.

## Goals / Non-Goals

**Goals**

1. Que sea **imposible** que una venta impute su movimiento de caja a una sesión que no es de la sucursal efectiva de la venta — por cualquier camino, presente o futuro.
2. Que el outbox deje de ser legible y marcable desde el rol de aplicación, **de una forma que sobreviva al Paso 2 del pool**.
3. Que haya **un solo dispatcher del outbox**, para que disparar el relay manualmente no pueda volver a suprimir asientos.
4. Dejar una **red permanente en CI** que cubra el punto ciego que el chequeo (4) no cubre: las `rpc_*` que recorren el outbox completo.
5. Medir —no suponer— si los dos huecos ya produjeron datos corruptos en producción.
6. Cero regresión: los 30 gates del workflow y la suite backend siguen verdes.

**Non-Goals**

- **No** se valida el `p_cash_session_id` en `rpc_close_cash_session` ni en el resto del módulo de caja: esas RPCs ya resuelven el tenant desde la sesión. Verificado.
- **No** se toca `rpc_quick_sale` ni `rpc_confirm_sales_order`: son wrappers finos y heredan el guard del core. Tocarlos sería reescribir dos RPCs vivas sin necesidad.
- **No** se le pone filtro por tenant a `rpc_process_outbox_batch` / `rpc_mark_event_processed` (D3 explica por qué sería incorrecto, no sólo innecesario).
- **No** se rediseña el dispatcher SQL ni se cambia el orden de sus consumers.
- **No** hay reparación automática de datos históricos. Si la auditoría encuentra filas, es checkpoint 🛑 firmado.
- **No** se cambia ninguna firma. Sin `DROP FUNCTION`, sin riesgo 42725.
- Sin superficie frontend (excepción declarada en `proposal.md`).

## Decisions

### D1 — h1: el guard va en `_c29_confirm_order_core` **y** en `c28_register_cash_movement`, con invariantes distintos

**Decisión: las dos capas, y no son redundantes** — expresan cosas diferentes.

- **Capa 1, en `_c29_confirm_order_core`: invariante de SUCURSAL.** Espejo exacto del `cash_optin_requires_open_session` del formulario: `cs.status = 'open' AND cb.branch_id = v_gate_branch` → `P0422`. Es la **única** capa que puede expresar esto, porque `v_gate_branch` —la sucursal efectiva de la venta— sólo existe dentro del core. Cierra el POS por sus dos wrappers de una vez.
- **Capa 2, en `c28_register_cash_movement`: invariante de TENANT.** `branches.account_id = ANY(current_account_ids())`. Es la **única** capa que cubre callers futuros: cualquier función nueva que registre caja hereda el backstop sin acordarse de nada.

Un guard de tenant en el choke point **no alcanza** para h1: dejaría pasar que una venta de la sucursal X impute su caja a la sesión de la sucursal Y del mismo tenant, que es justo lo que el formulario ya prohíbe. Y un guard de sucursal en el core no cubre callers futuros. Por eso las dos, y por eso la lección del change anterior ("el choke point es superior") **no se aplica por analogía acá**: allá las dos capas decían lo mismo con distinto alcance; acá dicen cosas distintas.

**Los tres obstáculos de la capa 2, analizados con evidencia** (el brief pedía específicamente no pasarlos por alto):

**(i) ¿Hay que cambiar la firma?** **No.** El tenant es derivable de los parámetros que la función ya recibe, por `cash_sessions → cashboxes → branches.account_id`. No es una hipótesis: `rpc_register_cash_movement` (`20261006000001` §4, líneas 160-166) hace **exactamente** esa resolución antes de delegar. Se copia ese `SELECT`, no se inventa. Sin `DROP FUNCTION`, sin overload 42725, `CREATE OR REPLACE` puro.

**(ii) ¿`current_account_ids()` resuelve bien cuando la llamada viene de un `SECURITY DEFINER` que corre como `postgres`?** **Sí, verificado empíricamente, no por lectura de documentación.** `current_account_ids()` es `SECURITY DEFINER STABLE` y su cuerpo es `SELECT account_id FROM public.account_members WHERE user_id = (SELECT auth.uid())`; `auth.uid()` lee el GUC `request.jwt.claims`, que es de sesión/transacción y **no lo toca el cambio de rol de `SECURITY DEFINER`**. La prueba directa está en la propia función que vamos a modificar: `c28_register_cash_movement` ya llama a `auth.uid()` para poblar `created_by`, que es `NOT NULL` — y **los 65 movimientos de caja de prod tienen `created_by` no nulo**, los 65 escritos desde `_c29_confirm_order_core`, que es `SECURITY DEFINER`. Si `auth.uid()` no resolviera en ese contexto, esas 65 filas no existirían.

**(iii) ¿Membresía o rol de escritura?** **Membresía (`current_account_ids()`), no `is_account_writer`.** `rpc_register_cash_movement` usa `is_account_writer` (owner/admin), pero copiarlo al choke point **endurecería el rol** del camino del formulario, que hoy resuelve con `current_account_ids()`: un miembro no-owner que hoy puede registrar una venta en efectivo dejaría de poder. Eso sería una regresión de permiso encubierta dentro de un change de seguridad. La capa 2 es un backstop de tenencia, no de autorización; la autorización sigue donde está.

**Enumeración completa de los callers de `c28_register_cash_movement`** (por `pg_get_functiondef` vivo en prod, no por `grep` sobre archivos superseded — `rpc_atomic_update_sale_operation` y `_register_bank_movement` aparecen en el `grep` pero sólo lo mencionan en comentarios):

| Caller | Cómo llega la sesión | Bajo la capa 2 |
|---|---|---|
| `rpc_register_cash_movement` | parámetro, ya validado con `is_account_writer` sobre el mismo `account_id` derivado | pasa (redundante a propósito) |
| `rpc_create_sale_operation_v2` | parámetro, ya validado contra `v_gate_branch` | pasa |
| `rpc_create_sale_operation` | ídem | pasa |
| `rpc_delete_sale_operation` | derivada de los `cash_movements` de la operación (ya validada por `current_account_ids()`) | pasa |
| `_c29_confirm_order_core` | **parámetro sin validar** | **es el que se cierra** |
| gate embebido de `20260804000003` §(b) | anchor sintético dentro de la migración | **se degrada — ver abajo** |

**El único costo real de la capa 2, y es real.** `20260804000003_fix_c28_cash_movement_balance.sql` tiene un gate de comportamiento **dentro de la migración** que invoca `c28_register_cash_movement` tres veces sobre un anchor sintético para verificar que el saldo usa `opening + SUM(amount)` y no `MAX(balance_after)`. Ese anchor inserta en `auth.users` (lo que dispara `handle_new_user` y le crea **su propia** cuenta), y aparte inserta una fila en `accounts` con un id explícito del que cuelgan la sucursal, la caja y la sesión. El usuario **no queda en `account_members` de esa cuenta**, así que con la capa 2 activa `current_account_ids()` no la incluye y el guard rechaza. Consecuencias:

- **No aborta la migración**, siempre que el ERRCODE del guard **no sea `P0001`**: el bloque tiene `EXCEPTION WHEN raise_exception … WHEN OTHERS THEN RAISE NOTICE 'gate (b) saltado por entorno'`, y `WHEN raise_exception` matchea únicamente `P0001`. Con `P0401`/`P0422` cae en `WHEN OTHERS` y degrada a `NOTICE`. **Con `P0001` abortaría `supabase db reset`.** Es un detalle de una línea que decide si el stack local arranca.
- **Sí apaga en silencio ese gate** en toda DB fresca (sólo corre cuando `accounts` está vacía). Mitigación obligatoria, no opcional: el gate nuevo de este change **replica esa aserción** (+500 / −200 / +300 → 1500 / 1300 / 1600) sobre un tenant bien provisionado, para que la cobertura no se pierda. Task 3.7.
- **No se edita `20260804000003`.** Es una migración ya aplicada en prod; editarla no cambia nada allá y sí cambia CI, que es exactamente el anti-patrón que produjo la regresión de julio.

**Alternativas descartadas**

- *Sólo la capa 1.* Cierra h1 hoy y deja el choke point abierto para el próximo caller. El proyecto ya vivió esto: `rpc_create_sale_operation_v2` tenía el guard y `_c29_confirm_order_core` no, durante meses.
- *Sólo la capa 2.* No puede expresar el invariante de sucursal (no conoce `v_gate_branch`) y por lo tanto no cierra h1 del todo.
- *Un helper nuevo `_cash_assert_session_owned(...)`.* Descartado por la Regla de Tres: quedarían dos sitios de uso con predicados **distintos** (sucursal vs. tenant), y el proyecto ya tiene las dos formas canónicas escritas y probadas. Además, un helper nuevo es otra función más que hay que acordarse de revocar — el modo de falla que el chequeo (4) del gate existe para cerrar.

### D2 — h1: el guard va donde está el resto de la validación de payload, antes de tocar nada

En `_c29_confirm_order_core` el orden vigente es: resolver orden → `is_account_writer` → resolver `payment_method_id` → `cash_requires_session` (`IS NULL`) → `credit_requires_client` → resolver banco → escribir `sales` → **caja** → cuenta corriente → banco → evento.

El guard nuevo va **inmediatamente después de `cash_requires_session`**, junto a las demás validaciones de payload y **antes de la primera escritura**. Razones: (i) coherencia con el formulario, donde el bloque `cash_optin_*` está exactamente ahí; (ii) un `RAISE` posterior a las escrituras revierte igual —la transacción es una sola— pero desperdicia trabajo y hace el error más difícil de leer; (iii) congela el orden como invariante testeable: un test puede verificar que con `p_cash_session_id` ajeno **y** un payload inválido por otra razón, gana el error de payload.

### D3 — h2: ni `REVOKE` a secas ni filtro por tenant — se saca el outbox del camino de la aplicación, y **después** se revoca

Esta es la decisión difícil del change y la que el brief marca como riesgosa. La objeción es correcta: **un `REVOKE … FROM authenticated` a secas es peligroso** porque el Paso 2 de `v31-tenancy-pool-rls` (PR #453, palanca `TENANCY_RLS_ROLE_ENABLED` hoy apagada) haría que el pool corra como `authenticated`, y el endpoint dejaría de funcionar. Pero **el filtro por tenant tampoco es la respuesta**, y no sólo por incompleto:

1. **Sería semánticamente incorrecto.** El spec vigente de `transactional-outbox` (requirement "Relay authorization model") exige que el relay *"SHALL read all pending events across accounts"*. Filtrar por `current_account_ids()` convierte al relay en un relay de un solo tenant: bajo el Paso 2 sólo procesaría los eventos del admin que aprieta el botón, y los demás quedarían pendientes para siempre. Se cambiaría una fuga por una avería.
2. **No arregla h2 bis.** Un relay Python con filtro de tenant sigue siendo un consumidor de 2 de 4 que marca `processed_at`: seguiría suprimiendo asientos, sólo que los propios.
3. **El camino ya está roto para el Paso 2 por otro lado.** El relay Python inserta directo en `audit_logs`, `email_logs` y `operation_idempotency`; el propio inventario de `v31-tenancy-pool-rls` lista esas tablas entre las que tienen SELECT policy y ninguna de INSERT para `authenticated`. Encender el Paso 2 rompe ese endpoint con o sin este change.

**Decisión, en este orden:**

1. **El endpoint pasa a `get_service_conn` + `require_platform_admin` + `rpc_process_outbox_dispatch`.** `get_service_conn` es el camino de servicio que `v31-tenancy-pool-rls` D5 declara explícitamente separado: *"nunca pasa por acá, no recibe claims, no queda dentro de la transacción del request y NUNCA adopta el rol `authenticated` sin importar el estado de ninguna de las dos palancas"*. Es el mismo camino que ya usan el webhook de pagos y el relay del CAE. **Ésa es la pieza que hace que el `REVOKE` sobreviva al Paso 2**, y es la respuesta concreta a la objeción del brief.
2. **`require_platform_admin(conn, auth)`, no un `require_admin` nuevo.** Ya existe en `backend/core/guards.py` y ya se usa con este patrón exacto en `backend/routers/fiscal.py` L225-226 (`from backend.core.guards import require_platform_admin; await require_platform_admin(conn, auth)`). Reutilización antes que repetición.
3. **Recién entonces, `REVOKE ALL ON FUNCTION … FROM PUBLIC, anon, authenticated`** sobre `rpc_process_outbox_batch(integer)` y `rpc_mark_event_processed(uuid)`, que a esa altura **no tienen ningún caller de aplicación**. `service_role` conserva su `EXECUTE` (ningún `REVOKE` lo nombra), igual que en el hotfix #454.
4. **Entran a `v_internal_only_fns`** del chequeo (3) del gate ACL, que es una lista cerrada sin allowlist y que sólo crece.

**El `REVOKE` no rompe al dispatcher**: `rpc_process_outbox_dispatch` no invoca a ninguna de las dos (tiene su propio `FOR … LOOP` sobre `events`), y lo llama el pg_cron como `postgres`, que es el owner.

**Rollback**: un `GRANT` de dos líneas para el ACL, y revertir el router es un `git revert` de un archivo. Nada de esto muta datos.

### D4 — h2 bis: el relay Python se retira, no se parchea

Verificado, no asumido (ver Context §Familia 2 bis): el relay Python es una segunda implementación incompleta de los consumers 1 y 2, incumple el spec vigente, el cron no lo llama, y el Paso 2 lo rompe. **Entra en el alcance de este change** por una razón de seguridad, no de prolijidad: admin-gatear un consumidor lesivo deja un botón que un administrador legítimo puede apretar para suprimir la contabilidad de los diez tenants. Cerrar la puerta y dejar la bomba adentro no es cerrar nada.

Qué se retira y qué se conserva:

| Pieza | Destino | Por qué |
|---|---|---|
| `backend/services/outbox_relay_service.py` | **eliminado** | duplica los consumers 1-2 del dispatcher SQL; es el mecanismo de la supresión |
| `OutboxRepository.fetch_pending_batch` / `mark_processed` / `insert_audit_log` / `insert_email_log` / `claim_idempotency` | **eliminados** | sus únicos consumidores son el servicio retirado (verificado por `grep` sobre `backend/`) |
| `OutboxRepository.emit_event` | **se conserva** | lo usan `purchase_repository.py` L349 y `stock_repository.py` L86 como productores (DEC-20) |
| `OutboxRepository.run_dispatch` | **nuevo** | una línea: `SELECT public.rpc_process_outbox_dispatch($1::int)` |
| `backend/tests/outbox/` (5 archivos) | **reemplazados** | testean el relay retirado; se sustituyen por tests del disparador y del gating |

El docstring del router se corrige: hoy afirma que lo llama el pg_cron, y el pg_cron llama a la RPC desde el pivot de C-25.

### D5 — Alcance conjunto, con grupos independientes

**Van juntos.** Cuatro razones concretas:

1. Son **la misma clase de bug** —un identificador ajeno recibido por parámetro que nadie valida— y salieron del mismo informe. Separarlos obliga a contar dos veces la misma historia.
2. **Un solo sign-off.** Son los dos CRÍTICO; dos changes CRÍTICO en paralelo son dos colas de aprobación del PO para el mismo problema.
3. **Los dos tocan los mismos dos archivos compartidos**: `.github/workflows/KPI_Validation.yml` (cadena de reapply + step de gate) y `supabase/tests/test_function_acl_gate.sql`. En ramas separadas eso es conflicto garantizado, y el conflicto de `KPI_Validation.yml` ya se pagó en el rebase del change anterior.
4. **Un solo gate SQL nuevo** y un solo baseline de prod que capturar.

**Pero no se mezclan.** No comparten **un solo objeto de base de datos**: h1 toca `_c29_confirm_order_core` y `c28_register_cash_movement`; h2 toca dos `rpc_*` del outbox y el router Python. `tasks.md` los mantiene en grupos separados (3 = h1, 4-5 = h2) para que se puedan aplicar, revisar y —si hiciera falta— revertir por separado, y la migración los separa en dos secciones con encabezado propio.

### D6 — El gate permanente es una lista curada, porque un gate estático honesto no puede hacer más

El chequeo (4) vigente **no habría atrapado h2**: su filtro de nombre excluye `rpc_*` deliberadamente (hay ~76 `rpc_*` `SECURITY DEFINER` que legítimamente necesitan `EXECUTE` para `authenticated` — son la API), y h2 vive justamente en dos `rpc_*`. Hay que cubrir ese punto ciego sin apagar el gate con una allowlist inmantenible.

**Lo que se descartó primero, y por qué.** La formulación tentadora es *"toda RPC `SECURITY DEFINER` que lea o escriba una tabla con `account_id` sin filtrar por tenant"*. **No es implementable con honestidad**: distinguir "menciona `account_id`" de "**filtra** por `account_id`" exige analizar el árbol de la consulta, no el texto del cuerpo. Un gate que busca la subcadena `account_id` daría verde a una función que la nombra en un `INSERT` y nunca la usa en un `WHERE` — falsa cobertura, que es peor que ninguna. No se propone.

**Lo que sí se propone — chequeo (5), `v_cross_tenant_event_fns`.** El outbox es una tabla especial: es la **única** que un relay tiene que recorrer entera, cross-account, por diseño. Eso hace que el conjunto de funciones que la **leen** (`FROM public.events`) o la **actualizan** (`UPDATE public.events`) sea chico, estable y auditable a mano. Medido en prod hoy — **exactamente cuatro**:

| Función | `authenticated` hoy | Veredicto |
|---|---|---|
| `rpc_process_outbox_dispatch(integer)` | ❌ | correcto, modelo a seguir |
| `rpc_process_outbox_batch(integer)` | ✅ | **se revoca** |
| `rpc_mark_event_processed(uuid)` | ✅ | **se revoca** |
| `rpc_atomic_update_sale_operation(...)` | ✅ | **legítimo**: `asiento-venta-formulario` le dio el reemplazo in-place del evento pendiente, y opera sobre la operación que ya validó por tenant. Entra a la lista **con justificación**, no se revoca |

Regla del chequeo (5), calcada de la del (3): **lista cerrada que sólo crece**; toda función que lea o actualice `public.events` tiene que estar enumerada con su veredicto (`expuesta: no` / `expuesta: sí + justificación`), y una que aparezca sin estar en la lista falla el pipeline. Los productores que sólo hacen `INSERT INTO public.events` **no** entran: insertar en el propio outbox no permite leer ni cerrar los eventos de nadie.

**Lo que el gate no puede hacer, dicho en voz alta.** El (5) detecta que alguien expuso una función que recorre el outbox; **no** detecta que alguien escriba una consulta cross-tenant nueva contra otra tabla. Para eso no hay gate estático honesto: la red es la revisión y el requirement de `account-tenancy`. Se prefiere un gate chico que sí funciona a uno grande que da falsa sensación de cobertura.

### D7 — Migración idempotente, sin `DROP`, con reafirmación de ACLs

- Nombre: **`20261012000001_tenancy_guard_caja_outbox.sql`**. `MAX(version)` vivo en prod verificado hoy: `20261011000001` (260 migraciones). **La task 1.1 vuelve a verificarlo antes de escribir el archivo**: en `cuenta-corriente-party-guard` el número se movió **tres veces** porque otras ramas tomaron los intermedios, y un archivo con número menor o igual al MAX remoto **no lo aplica nunca** el push automático de Supabase.
- `CREATE OR REPLACE` puro: ninguna de las dos funciones reescritas cambia de firma. Sin `DROP`, sin 42725. Gate anti-overload dentro de la migración (`count(*) = 1` por nombre) igual, por higiene.
- ACLs reafirmadas tras cada `CREATE OR REPLACE`, **con la corrección que motivó el hotfix #454**: para `c28_register_cash_movement` la reafirmación conserva su `GRANT` a `authenticated` (es alcanzable legítimamente vía `rpc_register_cash_movement`… **verificar en la task 4.4**: si ningún camino la invoca directo desde PostgREST, es candidata a revoke — pero eso es OQ-4, no se decide de oficio en un change CRÍTICO).
- Sin BOM UTF-8 (hay gate en CI). ERRCODEs de 5 caracteres (hay gate en CI).
- Se reaplica dos veces en local y se verifica que el segundo apply es no-op por fingerprint de cuerpos + ACLs + comentarios.

### D8 — Sin ERRCODEs nuevos

- **h1 capa 1**: `P0422`, con el mensaje canónico `cash_optin_requires_open_session` — literalmente el mismo del formulario, para que las dos superficies produzcan el mismo error y el frontend no tenga que distinguirlas.
- **h1 capa 2**: `P0401 unauthorized`, el que `rpc_register_cash_movement` ya usa para el mismo predicado de tenencia de caja. (Ver D1: **no** `P0001`, o abortaría el gate embebido de `20260804000003`.)
- **h2**: el gating es HTTP (403 de `require_platform_admin`), y el revoke produce `42501 insufficient_privilege`, que es de Postgres. Cero códigos nuevos.

Acuñar un código nuevo obligaría a mapearlo en `backend/core/errors.py` y en los services, para expresar exactamente lo mismo que ya expresan dos códigos vivos.

### D9 — La reparación histórica es un checkpoint firmado, nunca una migración

Igual que en `delete-guard-ledgers` y en `cuenta-corriente-party-guard`: si la auditoría read-only encuentra filas, el script vive en `scripts/sql/`, se ejecuta post-merge, gateado por conteos re-medidos inmediatamente antes, y con firma explícita del PO. Los tres conteos preliminares de este propose dieron **0**, pero se re-miden.

## Risks / Trade-offs

| Riesgo | Mitigación |
|---|---|
| **Reescribir `_c29_confirm_order_core` (15 110 caracteres) desde el archivo y perder un bloque vivo** — le pasó al bloque `credit` de C-30 en julio, y `compras-proveedor-cuenta-corriente` encontró que esta RPC concreta ya había divergido del archivo | Checkpoint 🛑 task 1.5: capturar `pg_get_functiondef` de prod, guardarlo en `baseline/` con md5 y `length`, diffear contra el archivo de referencia (`20261003000001` ~L760), **reportar antes de escribir una línea de SQL**. Verificación en la otra dirección al final: extraer el cuerpo de la migración, quitarle el guard, diffear contra el baseline → única diferencia admisible = el guard |
| El `P0422` nuevo rompe una venta legítima del POS | El caso que ahora falla es exactamente el caso que hoy corrompe. El selector de caja del POS lista sólo las cajas de la sucursal seleccionada. Control positivo obligatorio en el gate: venta POS en efectivo con la sesión correcta sigue funcionando y sigue escribiendo su movimiento |
| **El guard de la capa 2 apaga en silencio el gate (b) de `20260804000003`** | Analizado en D1: no aborta si el ERRCODE no es `P0001` (**task 3.6 lo verifica explícitamente**), y la aserción de saldo firmado se **replica** en el gate nuevo (task 3.7) para no perder cobertura |
| El `REVOKE` de las dos RPCs del outbox rompe el endpoint bajo el Paso 2 del pool | Resuelto por construcción (D3): el endpoint deja de usarlas y pasa al camino de servicio, que por contrato de `v31-tenancy-pool-rls` D5 nunca adopta `authenticated`. **Task 5.6: verificar con la palanca encendida en local**, no sólo razonarlo |
| Retirar `OutboxRelayService` rompe algo no identificado | `grep` sobre `backend/` da un único consumidor (el router). `emit_event` se conserva. La suite completa se corre antes y después contra el baseline de la task 1.2 |
| **ACLs de prod distintas a las de local** — el revoke se ve aplicado en CI y en prod queda abierto | El `REVOKE` nombra `PUBLIC, anon, authenticated`. La verificación post-merge corre `has_function_privilege` **contra prod** (gotcha #432) |
| El chequeo (5) nace en rojo por offenders preexistentes | La lista real se descubre en la task 6.2 **antes** de escribir el gate. Hoy son 4 y las 4 tienen veredicto (D6). El gate nace verde |
| La cadena de reapply de CI se desincroniza | La migración va como **último** eslabón, con comentario propio. Precedente directo: el apply del change anterior descubrió que el eslabón es *load-bearing* —el reapply de `20261001000001` y `20261004000001` re-otorga GRANTs en silencio—, así que el orden no es cosmético |
| Solapamiento con los cuatro changes in-progress | Verificado contra el estado vivo: ninguno redefine `c28_register_cash_movement`, `_c29_confirm_order_core` ni las RPCs del outbox. El único acoplamiento es de **contrato**, con `v31-tenancy-pool-rls` D5, y este change depende de que ese contrato se sostenga — anotado en OQ-6 |

### Estado del baseline de prod

Este propose **no capturó** los archivos de `baseline/` (mismo motivo que el change anterior: la captura vive en el apply, con el checkpoint 🛑 de la task 1.5). Sí verificó, contra prod, los **md5 y `length`** de todo lo que hay que capturar, que es el insumo con el que la task 1.5 confirma que el baseline es el correcto y no una versión vieja:

```
public._c29_confirm_order_core(text,uuid,text,uuid,text,uuid,text,uuid,uuid)
  md5 cecd8c5454611f267a5e131d73bf7928   len 15110   secdef=t  anon=f auth=t svc=t
public.c28_register_cash_movement(uuid,numeric,text,uuid,text)
  md5 510adc8e150fb5c315e6e9a2635eaff8   len  2288   secdef=f  anon=f auth=t svc=t
public.rpc_process_outbox_batch(integer)
  md5 e56e9eddda40754a4fc31a234a8d3309   len   963   secdef=t  anon=f auth=t svc=t
public.rpc_mark_event_processed(uuid)
  md5 b1396bac350179e570b091069738db41   len   266   secdef=t  anon=f auth=t svc=t
public.rpc_process_outbox_dispatch(integer)      -- referencia, no se toca
  md5 28ef69cefc0fd0a5d112b656e7795ac6   len  5933   secdef=t  anon=f auth=f svc=t
public.rpc_quick_sale(...)                       -- wrapper, no se toca
  md5 ccb8afa0730195cb3df65807eb0a05ed   len  4046
public.rpc_confirm_sales_order(...)              -- wrapper, no se toca
  md5 38f2902380018ef717ff5b04cc711d20   len   777
public.rpc_create_sale_operation_v2(...)         -- fuente del predicado a copiar
  md5 0b6bcc5b6caa1a3c01e0da16518c7d35   len 13914
```

Archivo de referencia contra el que diffear `_c29_confirm_order_core`: `supabase/migrations/20261003000001_limpiezas_pagos_admin.sql` ~L760. Para `c28_register_cash_movement`: `supabase/migrations/20261006000001_banco_caja_historial_ajustes.sql` §5. Para las dos del outbox: `supabase/migrations/20260718000001_c25_events_outbox_reconcile.sql` L172 y L203.

## Migration Plan

1. **🛑 Sign-off del PO** (governance CRÍTICO). Sin esto no arranca nada.
2. **Pre**: baseline de la suite backend, 30 gates verdes, `MAX(version)` de prod, captura y diff de baselines 🛑.
3. **RED**: `supabase/tests/test_tenancy_guard_caja_outbox.sql` escrito y fallando contra el schema actual (h1 y h2 por separado).
4. **GREEN h1**: capa 1 en `_c29_confirm_order_core`, capa 2 en `c28_register_cash_movement`.
5. **GREEN h2**: router al camino de servicio + `require_platform_admin` + dispatch RPC; retiro del relay Python; `REVOKE` de las dos RPCs.
6. **CI**: eslabón de reapply + step del gate nuevo + chequeo (5) en el gate de ACLs.
7. **Auditoría read-only en prod** → si algún conteo > 0, checkpoint 🛑.
8. **Post-merge**: verificar en prod `MAX(version) = 20261012000001`, los ACLs por `has_function_privilege`, y que los cuerpos vivos contienen los guards.

**Rollback.** Cada pieza revierte por separado y sin pérdida de datos: los guards con un `CREATE OR REPLACE` desde el baseline (por eso el baseline es obligatorio); los ACLs con un `GRANT` de dos líneas; el router con un `revert` de un archivo; el chequeo (5) borrando su bloque. La única operación que muta datos —la reparación histórica— es un script aparte, post-merge y firmado.

## Open Questions

> El apply implementa la **recomendación** de cada OQ si el PO no responde. Las marcadas 🛑 requieren respuesta antes de la task correspondiente. **OQ-0 es distinta: sin ella no hay apply.**

**OQ-0 🛑 — ¿El PO aprueba ejecutar el apply?**
Governance CRÍTICO: el propose está autorizado, el apply no. *Recomendación: **aprobar, y priorizarlo sobre el resto del backlog**.* Los dos huecos están abiertos en producción con 10 tenants y 3 cajas abiertas, el daño histórico medido es 0 (o sea que todavía no costó nada), y el precedente del proyecto para esta clase de hallazgo es el hotfix del mismo día (#446, #454). Si el PO prefiere ese patrón, ver OQ-1.

**OQ-1 🛑 — ¿Sale algún tramo como hotfix inmediato, al estilo #446/#454?**
*Recomendación: **el tramo h2 sí, el tramo h1 no**.* h2 es la fuga más barata de cerrar y la más grave de las dos en términos de datos ajenos legibles: el `REVOKE` de las dos RPCs más el `require_platform_admin` del endpoint son un PR chico con rollback de dos líneas — el molde exacto de #454. h1, en cambio, exige reescribir una RPC de 15 110 caracteres desde el baseline vivo: es precisamente el trabajo que **no** conviene hacer con urgencia de hotfix. Marcada 🛑 porque cambia el orden de trabajo y porque el change anterior perdió tiempo cuando el PO respondió lo contrario de la recomendación **después** de escrito el apply.

> **RESUELTA — el PO firmó la recomendación (2026-08-24): "h2 sale como hotfix ahora, h1 después".**
> Ejecutado en la rama `fix/outbox-cross-tenant-hotfix` con la migración
> **`20261012000001_revoke_outbox_cross_tenant.sql`**: los grupos 4 y 5
> completos, más la parte de h2 del grupo 6 (chequeo (5) del gate de ACLs, gate
> de comportamiento `supabase/tests/test_outbox_single_dispatcher.sql` con step
> propio, y la migración como último eslabón de la cadena de reapply). Mismo
> patrón de registro que la OQ-2 del change anterior, resuelta como el hotfix
> #454.
>
> Tres consecuencias para lo que queda de este change:
> 1. **h1 renumera.** El número `20261012000001` está tomado; la migración de
>    h1 deja de llamarse `20261012000001_tenancy_guard_caja_outbox.sql` y toma
>    el siguiente libre, re-verificando el `MAX` vivo (task 1.1).
> 2. **OQ-3 quedó resuelta con ella**, por su recomendación: el retiro de
>    `OutboxRelayService` entró en el hotfix, no salió aparte (D4).
> 3. **OQ-6 quedó resuelta con ella**, por su recomendación: el contrato de
>    `get_service_conn` ya tiene su test (task 5.6), así que D3 dejó de
>    apoyarse en un docstring. Le sirve también a `v31-tenancy-pool-rls`.
>
> Lo que **no** cambió: h1 sigue entero y sin tocar en este change —
> `_c29_confirm_order_core`, `c28_register_cash_movement`, `rpc_quick_sale` y
> `rpc_confirm_sales_order` no aparecen en el hotfix. La OQ-0 (sign-off del
> apply de h1) sigue abierta.

**OQ-2 — h1: ¿las dos capas, o sólo la de sucursal?**
*Recomendación: **las dos** (D1).* La capa 2 cuesta un `SELECT` de cuatro líneas en una función de 2 288 caracteres, no cambia la firma, y es lo único que cubre callers futuros. Su único costo verificado —el gate embebido de `20260804000003` degradado a `NOTICE`— tiene mitigación escrita (task 3.7).

**OQ-3 — h2 bis: ¿el retiro de `OutboxRelayService` entra en este change o sale aparte?**
*Recomendación: **entra** (D4).* Admin-gatear un consumidor que suprime asientos deja el arma cargada del lado de adentro. Es además el tramo con menos riesgo del change: cero cambios de schema, un endpoint sin consumidores de UI, y el dispatcher que lo reemplaza corre en producción cada minuto desde hace meses. Si el PO prefiere acotarlo, la alternativa mínima defendible es dejar el endpoint gateado pero **apuntando al dispatcher** —o sea D4 sin el borrado de archivos—, conservando el servicio como código muerto.

**OQ-4 — ¿`c28_register_cash_movement` debería quedar revocada de `authenticated`?**
*Recomendación: **no en este change**.* Es `SECURITY INVOKER` (no cae en los chequeos (3) ni (4), que filtran por `prosecdef`) y tiene `GRANT` explícito desde `20261006000001` L267. Con la capa 2 puesta, invocarla directo desde PostgREST ya no permite escribir en caja ajena, así que deja de ser una primitiva cross-tenant. Revocarla igual sería más limpio, pero exige auditar si algún camino la llama directo, y **revocar algo del hot path de caja sin esa auditoría es cómo se rompe el POS un sábado**. Queda anotada como candidata.

**OQ-5 — Si la auditoría de daño histórico encuentra filas: ¿reparar, reasignar o anotar?**
*Recomendación: **decidirlo con los datos a la vista, no antes**.* Los tres conteos preliminares dieron 0. Con filas, la reparación depende de si hay dinero real detrás: un movimiento de caja fantasma en el arqueo de otro tenant no se puede borrar sin más si esa sesión ya cerró con arqueo firmado (RN-99: los ledgers se corrigen con contra-asiento, no con `DELETE`). Checkpoint 🛑 con los conteos reales.

**OQ-6 — ¿Qué pasa si `v31-tenancy-pool-rls` cambia el contrato de `get_service_conn`?**
*Recomendación: **anclar la dependencia con un test, no con un comentario**.* Todo D3 se apoya en que el camino de servicio nunca adopta `authenticated`. Ese contrato hoy está escrito en el docstring de `backend/core/database.py` y en el design de aquel change, pero **no hay un test que lo afirme**. La recomendación es que este change agregue ese test (task 5.6): con las dos palancas encendidas, `get_service_conn` sigue devolviendo una conexión cuyo `current_user` es el owner. Es tres líneas y convierte una suposición en un candado — y le sirve igual a aquel change.

**OQ-7 — ¿El chequeo (5) debería cubrir también `INSERT INTO public.events`?**
*Recomendación: **no**.* Insertar en el propio outbox es lo que hacen todos los productores legítimos (`rpc_create_sale_operation_v2`, `rpc_atomic_update_sale_operation`, `rpc_close_cash_session`, …): incluirlos convertiría una lista de 4 entradas en una de decenas, que es exactamente la allowlist inmantenible que D6 evita. Insertar un evento propio no permite leer ni cerrar los de nadie más.
