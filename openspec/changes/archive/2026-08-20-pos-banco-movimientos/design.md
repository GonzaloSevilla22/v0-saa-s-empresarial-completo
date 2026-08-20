## Context

### Cómo funciona hoy el módulo bancario (verificado en prod, 2026-08-20)

| Tabla | Filas | Quién escribe hoy |
|---|---|---|
| `bank_accounts` | 6 (todas activas, **todas de 1 sola de las 35 cuentas**) | `rpc_create_bank_account` (alta desde `/finanzas/conciliacion`) |
| `bank_movements` | **0** | `rpc_register_bank_movement` (manual) y `rpc_register_payment_received/made` con `kind` bancario (C2) |
| `payments_received` / `payments_made` | **0 / 0** | RPCs de cobro/pago de cuenta corriente (C-30) |
| `bank_statement_lines` / `reconciliation_sessions` | **0 / 0** | `rpc_import_bank_statement` / `rpc_open_reconciliation_session` (C3) |

El ledger operativo está vacío porque sus dos escritores viven fuera del camino diario: la carga manual (que nadie usa como rutina) y las RPCs de cobro/pago de cuenta corriente (que tienen 0 filas). La **venta**, que es el hecho económico de todos los días, no escribe una sola fila. Consecuencia directa: el saldo bancario del sistema es el `opening_balance` congelado, y la conciliación de C3 —construida entera— no tiene contra qué matchear un extracto.

Esto no es un olvido: es una **deuda declarada**. `bank-payment-routing` (C2, 2026-07-02) cerró su **OQ-4** como *"journal-only en C2 — el `bank_movement` operativo del camino de la venta queda diferido a un change posterior"*, y `pos-catalogo-pagos` (#421) lo dejó anotado como **OQ-A** al archivarse. Este change es ese diferido.

### Lo que ya está construido y que este change reutiliza

- **`_register_bank_movement(p_bank_account_id, p_amount, p_type, p_source_doc_type, p_source_doc_ref, p_value_date, p_branch_id, p_description)`** — helper intra-tx, `SECURITY DEFINER`, `EXECUTE` revocado de `authenticated`. Calcula `balance_after` bajo `FOR UPDATE` sobre `bank_accounts` y denormaliza `account_id`. **No valida** pertenencia, `is_active` ni `deleted_at`: eso es responsabilidad del llamador (así lo hacen hoy `rpc_register_bank_movement` y las RPCs de pago).
- **`payment_methods`** con `kind` cerrado de 7 valores, sembrado por provisioning (6 métodos por cuenta: `cash`, `transfer`, `card`, `wallet`, `credit`, `other` — **`check` no se siembra**), soft delete y `sort_order`.
- **`_c29_confirm_order_core`** (definición viva capturada con `pg_get_functiondef` el 2026-08-20, 8 args) ya resuelve `v_kind` contra el catálogo antes de tocar stock, y tiene los bloques de caja (`c28_register_cash_movement`) y de cuenta corriente (`_pay_register_party_charge`) **contiguos**, justo antes del bloque fiscal. Ese es el punto de inserción exacto.
- **`useBankAccounts`** (`frontend/hooks/data/use-bank-accounts.ts`) ya trae las cuentas activas y fue escrito, textualmente, "for the payment-method bank-account picker" en C2.
- **C3 matching**: `reconciliation_matches` con `match_group`, cardinalidades 1:1 / 1:N / N:1, invariante Σ(líneas) = Σ(movimientos) (`P0433`), sugerencias 1:1 por monto exacto y `value_date` ±3 días, y `reconciliation_status` mantenido **exclusivamente** por las RPCs de match.

### Restricciones que enmarcan el diseño

- **34 de 35 cuentas no tienen ninguna `bank_account`.** Cualquier diseño que exija elegir una cuenta bancaria para cobrar por transferencia rompe el POS de casi todos los tenants. La no-configuración tiene que ser un camino válido y silencioso.
- El POS es **táctil y de mostrador**: cada pulsación extra cuesta. La fricción es el criterio de diseño, no un detalle de UI.
- El gate `test_confirm_core_integrity` (transitivo desde #425) exige que el cuerpo publicado del hot path contenga los bloques de caja, cuenta corriente, `credit_requires_client`, fiscal, outbox e historial de estado.
- `ALTER DEFAULT PRIVILEGES` del proyecto otorga `EXECUTE` a `anon` sobre toda función nueva: `REVOKE ... FROM anon` explícito en cada función tocada (gotcha visto en #420, #421, #423 y #425).

## Goals / Non-Goals

**Goals:**
- Que una venta (POS y formulario) y una compra por método bancario dejen su rastro en `bank_movements` **en la misma transacción** que la operación.
- Que ese rastro sea **conciliable por C3 sin cambiarle una línea** al módulo de conciliación.
- Que la cuenta bancaria destino se configure **una vez por método** y no se pregunte en cada venta, con override disponible.
- Que la ausencia de configuración deje el sistema **byte a byte como hoy**.
- Que una operación con movimiento bancario posteado quede protegida de la edición, coherente con D6 de #425.

**Non-Goals:**
- **Tocar el asiento contable.** `_journal_post_from_event` ya rutea `transfer/card/check/wallet` a `1110 Banco` desde C2 y #425. Este change no lo modifica, no emite eventos nuevos y no cambia payloads. Los dos ledgers de C1/C2 siguen separados: `bank_movements` operativo intra-tx, `1110` contable asíncrono.
- **Netear la liquidación de tarjeta** (comisión, retenciones, fecha de acreditación T+N). Heredado de C2: se asienta bruto y se concilia N:1 con los `fee`/`tax_debit` manuales de C3.
- **Backfill de movimientos históricos.**
- **Cheques en cartera** (el circuito recibido → depositado → acreditado). `check` ni siquiera se siembra en el catálogo.
- **Multi-moneda.** `bank_accounts.currency` sigue siendo ARS de hecho.
- **Reversa automática al eliminar una operación** — ver OQ-2.

## Decisions

### D1 — El movimiento es inmediato e `unreconciled`; NO se inventa un estado "esperado"

**La decisión central del change.** Un `bank_movement` escrito por la venta **es** el movimiento esperado: es la afirmación del sistema de que entró plata a la cuenta X, todavía no confirmada por el banco. C3 ya modela esa incertidumbre con `reconciliation_status = 'unreconciled'` (el default de nacimiento) y la resuelve con el match contra `bank_statement_lines`. Agregar un estado `expected`/`pending` sería una **segunda fuente de verdad para el mismo hecho** y obligaría a tocar C3.

El flujo queda cerrado sin ninguna pieza nueva:

```
venta transfer $10.000 ──intra-tx──▶ bank_movements(+10000, transfer_in, unreconciled)
                                              │
extracto del banco ──import C3──▶ bank_statement_lines(+10000)   │
                                              └──── match 1:1 ───┘ ──▶ matched
```

La sugerencia automática de C3 (monto exacto + `value_date` ±3 días) engancha el par sin intervención en el caso típico de transferencia.

**Alternativa descartada — movimiento diferido, creado recién al conciliar**: dejaría el saldo bancario del sistema desactualizado entre la venta y el extracto (que llega mensualmente), que es exactamente el problema que este change existe para resolver; y rompería la atomicidad (el movimiento dejaría de estar en el commit de la venta).

**Alternativa descartada — tabla `expected_bank_movements` aparte**: duplica el ledger, obliga a que C3 matchee contra dos orígenes y desperdicia `reconciliation_status`, que ya significa exactamente eso.

### D2 — Regla de escritura: `kind` bancario **Y** cuenta resuelta

```
escribe bank_movement  ⟺  kind ∈ {transfer, card, check, wallet}  ∧  cuenta bancaria resuelta ≠ NULL
```

La resolución (helper `_pay_resolve_bank_account`) es, en orden:

1. `p_bank_account_id` explícito de la operación (override), si vino;
2. `payment_methods.bank_account_id` del método imputado (default por método);
3. `NULL` → **no se escribe nada** y la operación sigue su curso normal.

La cuenta resuelta se valida siempre: existe, `account_id` = el de la operación, `is_active`, `deleted_at IS NULL`. Falla → `P0412` (el mismo código que ya usan C1/C2 para cuenta inexistente o inactiva). Un `p_bank_account_id` explícito sobre un `kind` **no** bancario → `P0400` (`bank_account_requires_bank_kind`): es un error del cliente, no algo para ignorar en silencio.

**Por qué el paso 3 no es un error**: 34 de 35 cuentas no tienen bancos cargados. Hacer obligatoria la cuenta convertiría "cobrar por transferencia" en un flujo bloqueado para casi todos los tenants el día del deploy. La no-configuración es el default y significa, con toda literalidad, *"no llevo el banco en el sistema"*.

**Efecto lateral buscado**: el debate sobre `check` (¿el cheque recibido está en el banco o en un cajón?) se resuelve solo — el que no quiera cheques en el ledger simplemente no le configura cuenta al método. La política es del usuario, no del código.

**Alternativa descartada — cuenta obligatoria para todo `kind` bancario**: rompe a 34 tenants y agrega una pulsación obligatoria al mostrador.

**Alternativa descartada — una cuenta "default de la organización"** (la primera activa): escribe a ciegas en la cuenta equivocada, que es el riesgo que C2 nombró explícitamente al resolver su OQ-1 a favor del parámetro explícito.

### D3 — Mapa `kind → movement_type`, heredado de C2 sin reinterpretar

| `kind` | `movement_type` | signo venta | signo compra |
|---|---|---|---|
| `transfer` | `transfer_in` / `transfer_out` | `+total` | `−total` |
| `card` | `card_settlement` | `+total` (bruto) | `−total` |
| `check` | `transfer_in` / `transfer_out` | `+total` | `−total` |
| `wallet` | `transfer_in` / `transfer_out` | `+total` | `−total` |
| `cash`, `credit`, `other` | — (no escribe) | | |

Idéntico al que C2 fijó para las RPCs de pago (spec `bank-movement`), más `wallet` a `transfer_in`, coherente con #425 D7 que ya mandó `wallet` a `1110 Banco` en el asiento: una billetera virtual no es efectivo en el cajón y su conciliación se parece a la bancaria. `card_settlement` está **reservado a escritores automáticos** por el spec de C3 — la venta lo es, así que el uso es legítimo.

**Sobre `card` bruto**: el extracto acredita el neto (bruto − comisión − retenciones) y en fecha posterior. El procedimiento de conciliación es el que C3 ya diseñó para su V1 "solo anotar": el usuario registra la comisión como `bank_movement` manual `fee` (y el impuesto como `tax_debit`) y hace un match **N:1** cuyo grupo suma exactamente la línea neta del extracto — `+10.000` (venta) `−350` (fee) = `+9.650` (línea). No hace falta ninguna pieza nueva; sí hace falta documentarlo (task de docs).

### D4 — `value_date` = el día de la operación, con guard de período conciliado

`value_date` se toma de la fecha de la operación: `public.reporting_local_today()` en el POS (día argentino, canon `business-day-timezone`) y `p_date` en los formularios, que admiten fechas pasadas.

Un movimiento con `value_date` retroactiva **no reescribe historia contable** (C3 persiste `ledger_closing_balance` como snapshot al cerrar la sesión), pero sí aparecería dentro de un período que alguien ya declaró conciliado, sin línea de extracto disponible para matchearlo — un huérfano permanente. Por eso: si la `value_date` cae dentro de `[period_from, period_to]` de una sesión **`closed`** de esa cuenta bancaria, la escritura se rechaza con `P0424` (`bank_period_reconciled`), con un mensaje que indica registrar el movimiento como ajuste manual.

El camino del POS **no puede** dispararlo (opera siempre sobre hoy, y hoy no puede estar en un período cerrado sin que alguien haya conciliado el futuro). Impacto retroactivo hoy: **cero sesiones en prod**.

**Alternativa descartada — clampear la fecha a hoy**: falsea la fecha valor, que es la clave de matching de C3.

**Alternativa descartada — permitir y no avisar**: genera huérfanos silenciosos en el ledger, justo lo que la conciliación existe para eliminar.

### D5 — Un único escritor: `_pay_register_operation_bank_movement`

Las seis RPCs afectadas **no** llaman a `_register_bank_movement` cada una por su cuenta. Llaman a un helper nuevo que concentra resolución (D2), validación, mapa de tipos (D3), guard de período (D4) y la llamada al helper de C1:

```sql
_pay_register_operation_bank_movement(
  p_account_id        uuid,
  p_kind              text,     -- kind YA resuelto por la RPC (nunca el texto del cliente)
  p_payment_method_id uuid,     -- para el default por método
  p_bank_account_id   uuid,     -- override explícito (NULL = usar default)
  p_amount_abs        numeric,  -- siempre positivo; el helper aplica el signo
  p_direction         text,     -- 'in' | 'out'
  p_source_doc_type   text,     -- 'sale' | 'purchase'
  p_source_doc_ref    uuid,
  p_value_date        date,
  p_branch_id         uuid,
  p_description       text
) RETURNS uuid   -- id del movimiento, o NULL si no correspondía escribir
```

Es el mismo patrón que #425 D1 estableció con `_pay_register_party_charge` y por la misma razón (regla del PO 2026-08-02, "reutilización antes que repetición"): seis copias de la misma regla divergen en silencio, y ese fue el vector literal de la regresión de julio. `SECURITY DEFINER`, `SET search_path = public, pg_temp`, `EXECUTE` revocado de `PUBLIC`/`anon`/`authenticated`.

**Alternativa descartada — llamada inline en cada RPC**: seis autoridades para una sola regla; el gate de integridad tendría que verificar seis cuerpos.

### D6 — Firmas: `DROP` + `CREATE` + re-`GRANT` donde entra el parámetro

`p_bank_account_id uuid DEFAULT NULL` entra como parámetro **trailing** en `_c29_confirm_order_core`, `rpc_quick_sale`, `rpc_confirm_sales_order`, `rpc_create_sale_operation`, `rpc_create_sale_operation_v2` y `rpc_create_purchase_operation`. Agregar un parámetro cambia la firma: `CREATE OR REPLACE` dejaría **conviviendo** la firma vieja y produciría `42725` (ambiguous function) en la primera llamada. Por eso `DROP FUNCTION IF EXISTS` con la lista de tipos **exacta capturada de prod** y luego `CREATE`, con el trío completo en cada una:

```sql
REVOKE ALL ON FUNCTION public.<fn>(<args>) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.<fn>(<args>) FROM anon;
GRANT EXECUTE ON FUNCTION public.<fn>(<args>) TO authenticated;
```

(`_c29_confirm_order_core` y los helpers `_pay_*` no llevan `GRANT` a `authenticated`: se llaman desde RPCs `SECURITY DEFINER`.)

`rpc_atomic_update_sale_operation` y `rpc_atomic_update_purchase_operation` **conservan firma** → `CREATE OR REPLACE`. Un gate de conteo de firmas (`SELECT count(*) FROM pg_proc WHERE proname = ...` = 1 por nombre) cierra el riesgo de overload, como en #421/#423/#425.

### D7 — El default bancario del método usa contrato tri-estado

`rpc_update_payment_method` gana `p_bank_account_id uuid` + `p_bank_account_provided boolean` — el mismo contrato tri-estado que `p_payment_method_provided` en las RPCs de edición: *no enviado* (conserva), *enviado con valor* (asigna), *enviado en NULL* (desasigna). Sin el booleano no hay forma de expresar "sacale la cuenta a este método". En el backend se deriva de `model_fields_set` (precedente #419/#423). La cuenta asignada se valida igual que en D2 (pertenencia, activa, no borrada). `ON DELETE SET NULL` en la FK degrada solo: borrar una cuenta bancaria deja al método sin default, no rompe el catálogo.

### D8 — Edición: `bank_movements` entra al bloqueo `P0423` (extensión de #425 D6)

El guard existente de `rpc_atomic_update_sale_operation` / `rpc_atomic_update_purchase_operation` suma un tercer `EXISTS`, con la **misma doble referencia** que ya usa para caja y cuenta corriente (`sales.operation_id` para el camino del formulario, `sales_orders.id` para el camino POS):

```sql
IF EXISTS (SELECT 1 FROM public.bank_movements bm
           WHERE bm.source_doc_type IN ('sale','purchase')
             AND bm.source_doc_ref IN ( ...mismo UNION que el guard de caja... ))
THEN RAISE EXCEPTION 'operation_has_bank_movement_immutable: ...' USING ERRCODE = 'P0423';
```

Motivos, en orden de peso: (1) `bank_movements` es **append-only** por diseño C1 — no existe UPDATE para `authenticated`; (2) el movimiento puede estar ya `matched` dentro de una sesión de conciliación **cerrada**, y mutarlo destruiría una conciliación firmada por alguien; (3) `balance_after` es acumulativo: cambiar un `amount` intermedio invalidaría el saldo de todos los movimientos posteriores. El precedente (#425 D6, y antes `edicion-preserva-contexto` F2) ya está aprobado por el PO y mapeado a HTTP 409.

Se extiende también el **predicado `editable`** que `sales_repository.py` / `purchase_repository.py` calculan para que la UI deshabilite el botón con la razón visible, en vez de fallar al confirmar (escenario ya exigido por el spec `operation-edit-context`).

### D9 — UX: default invisible, override de una pulsación

| Superficie | Comportamiento |
|---|---|
| **POS**, `kind` bancario **con** default | Chip discreto bajo la grilla de métodos: `Galicia CC ·  Cambiar`. Cero pulsaciones en el flujo feliz. |
| **POS**, `kind` bancario **sin** default, cuenta **con** bancos | El mismo chip en estado vacío: `Elegir cuenta (opcional)`. Nunca bloquea el cobro. |
| **POS**, cuenta **sin** bancos | No se renderiza nada. El POS queda idéntico a hoy. |
| **Override** | `Sheet` táctil (el patrón ya usado en el POS) con las cuentas activas de `useBankAccounts`, botones de ≥44px. |
| **Formularios** venta/compra | `Select` de cuenta contiguo al `PaymentMethodSelect`, visible solo si el `kind` es bancario y hay bancos; texto de apoyo que nombra el efecto ("registra el movimiento en el banco elegido"). |
| **`/configuracion` → `PaymentMethodManager`** | Columna "Cuenta bancaria" con el default editable por método; vacío = "Sin cuenta (no registra movimiento)". |
| **`/finanzas/conciliacion`** | Sin trabajo nuevo: el tablero ya lista `bank_movements` y los nuevos aparecen como `unreconciled`, listos para matchear. |

Todo con tokens semánticos del design system, verificado en desktop y mobile y en tema claro y oscuro (regla PO 2026-08-02).

**Alternativa descartada — preguntar la cuenta en cada venta**: una pulsación obligatoria por cobro en un flujo de mostrador; y con una sola cuenta bancaria (el caso típico) la pregunta no aporta información.

**Alternativa descartada — sin override, solo default**: el caso real "esta transferencia entró a la otra cuenta" quedaría sin salida y empujaría al usuario a corregir a mano en el ledger, que es append-only.

### D10 — Gate de integridad transitivo, extendido

`scripts/ci/test_confirm_core_integrity.sql` (transitivo desde #425 D3) suma un eslabón: `_c29_confirm_order_core`, `rpc_create_sale_operation_v2` y `rpc_create_purchase_operation` contienen `_pay_register_operation_bank_movement`, y ese helper contiene `_register_bank_movement` y `_pay_resolve_bank_account`. Se verifica **RED real** contra la definición viva antes de aplicar la migración, como en #421 y #425. Se suma un gate de conteo de firmas (D6) y el gate de ACL (`REVOKE anon`) ya vigente del proyecto.

## Risks / Trade-offs

- **[El saldo bancario empieza a moverse solo y sorprende al usuario]** → El movimiento requiere una configuración deliberada (asignar la cuenta al método). Sin configurar, nada cambia: hoy hay **0 filas** y **0 métodos con cuenta asignada**, así que el deploy es un no-op funcional hasta que alguien opte.
- **[Repetir la regresión de julio reescribiendo el hot path]** → Tres capas: los cuerpos se copian de la **definición viva** capturada con `pg_get_functiondef` (no del repo); el gate transitivo se extiende **en el mismo commit**; y el bloque fiscal se copia sin tocar una línea, igual que en #421 y #425.
- **[`card` bruto no matchea la línea neta del extracto]** → Es la decisión heredada de C2 (OQ-2) y C3 ya tiene el instrumento (`fee`/`tax_debit` manual + match N:1). El riesgo real es de **documentación**, no de datos: se cubre con el texto de apoyo en la UI y una nota en la superficie de conciliación.
- **[Doble contabilización venta a crédito + cobro posterior]** → Imposible por construcción: `credit` no escribe movimiento bancario (no es un `kind` bancario); el movimiento lo escribe `rpc_register_payment_received` cuando se cobra. **El movimiento lo registra quien realmente mueve la plata**, y los dos caminos son disjuntos.
- **[`P0424` bloquea una venta legítima con fecha pasada]** → Solo si el usuario ya cerró una conciliación que cubre esa fecha, y solo en el formulario. El mensaje indica la vía (movimiento manual de ajuste). Cero impacto retroactivo: 0 sesiones en prod.
- **[`42725` por overload si faltara un `DROP`]** → Gate de conteo de firmas, más el precedente de tres PRs que ya lo pisaron.
- **[Auto-apply de Supabase GitHub]** → Migración idempotente extremo a extremo (`ADD COLUMN IF NOT EXISTS`, `DROP ... IF EXISTS`, `CREATE OR REPLACE`) y re-ejecutable sin efectos.
- **[Colisión de timestamp de migración]** → Base `20261002000001` (MAX en prod hoy: `20261001000001`); se re-verifica `MAX(version)` justo antes de abrir el PR, regla del proyecto.

## Migration Plan

1. Capturar (ya hecho, 2026-08-20) y versionar como referencia las definiciones vivas de las 8 funciones a tocar.
2. `supabase/migrations/20261002000001_pos_banco_movimientos.sql`: columna `payment_methods.bank_account_id` → helpers `_pay_resolve_bank_account` y `_pay_register_operation_bank_movement` → `DROP`+`CREATE`+re-`GRANT` de las 6 RPCs de operación → `CREATE OR REPLACE` de las 2 RPCs de edición y de `rpc_update_payment_method` → gates DO-block (conteo de firmas, ACL, integridad transitiva).
3. Backend: schemas → repositories → services → routers, con `pytest` en RED primero.
4. Frontend: hook + POS + formularios + manager, con `vitest` en RED primero.
5. Merge → CI (`validate-kpis` + vitest + pytest ≥87% + Playwright) → deploy automático (Vercel + `db push`) → Render redeploy.
6. Verificación post-deploy **read-only** vía MCP: asignar una cuenta a "Transferencia bancaria" en la cuenta que tiene bancos, hacer una venta de prueba y confirmar que aparece 1 fila en `bank_movements` con `unreconciled` y el `balance_after` correcto.

**Rollback**: `DROP`+`CREATE` de las funciones a su definición previa (capturada en el paso 1) y `ALTER TABLE payment_methods DROP COLUMN bank_account_id`. Los `bank_movements` ya escritos **se conservan**: son la verdad operativa y el ledger es append-only.

## Open Questions

- **OQ-1 — ¿`check` debería escribir movimiento bancario?** Un cheque recibido no está en el banco hasta depositarse. **Recomendación (default implementado)**: sí escribe, pero solo si el usuario le configura cuenta al método — la política queda en manos del usuario (D2) y el catálogo ni siquiera siembra `check` hoy. Si el PO quiere excluirlo por regla, es sacar `'check'` de una lista en un helper. Sin bloqueo.
- **OQ-2 — Eliminar una operación con `bank_movement` posteado.** Hoy el DELETE de una venta/compra es directo (`DELETE FROM sales`), sin RPC ni guard: el movimiento quedaría huérfano. **No es una regresión de este change** — el mismo hueco existe ya para `cash_movements` y `customer_account_movements` desde #425. Cerrarlo bien pide decidir entre bloquear el borrado o emitir un contra-movimiento, y alcanza a los tres ledgers. **Recomendación**: change propio (`eliminacion-operaciones-ledgers`), fuera de este alcance.
- **OQ-3 — Fecha de acreditación de tarjeta (T+N).** El `value_date` bruto en el día de la venta hace que la sugerencia automática de C3 (±3 días) casi nunca enganche una liquidación de tarjeta. Modelar `settlement_date` por método es la solución completa. **Recomendación**: diferir; el match manual funciona y el volumen de tarjeta hoy es cero.
- **OQ-4 — ¿Los gastos (`expenses`) pagados por transferencia también deberían escribir?** Simétrico y barato, pero `expenses` no tiene forma de pago imputada hoy. **Recomendación**: diferir hasta que el catálogo llegue a gastos.
