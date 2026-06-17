## Context

C-29 es el **hot path comercial** de la Fase 7 (V2.1). Todas las piezas que orquesta ya están en producción:

- **Stock (C-21 + C-26)**: `branch_stock` es el único ledger; el descuento va por `c21_apply_branch_stock_delta(account_id, product_id, branch_id, delta)` con resolución de branch default vía `c26_default_branch`; invariante físico `branch_stock.quantity >= 0` (CHECK). El gate de venta es per-branch contra `v_gate_branch = COALESCE(p_branch_id, c26_default_branch(account_id))`. Operar contra branch cerrada → `P0422 branch_closed`.
- **Caja (C-28)**: helper intra-transacción `public.c28_register_cash_movement(p_session_id, p_amount, p_type, p_reference_id)` — **NO abre transacción propia**, corre en la del llamador, lockea la fila de sesión `FOR UPDATE`, calcula `balance_after`, inserta en `cash_movements` (append-only). Pensado exactamente para que C-29 lo invoque dentro de `confirm()`. `REVOKE` de PUBLIC: solo callable desde RPCs `SECURITY DEFINER`. `movement_type` permitido incluye `'sale'`. Errores: `no_open_session` (P0409), `branch_closed` (P0422).
- **Numeración fiscal (C-27)**: `rpc_emit_pending_cae(p_comprobante_type, p_total, p_client_id, p_point_of_sale_id)` reserva número vía `rpc_next_document_number` (lock corto, UPDATE-then-INSERT) e inserta `fiscal_documents` en estado `pending_cae` **sin tocar AFIP** (el CAE lo resuelve el relay pg_cron asíncrono). Resuelve PV efectivo; `P0422 ambiguous_point_of_sale` si hay >1 PV activo sin especificar.
- **Idempotencia (DEC-06)**: tabla `operation_idempotency` con UNIQUE `(user_id, operation_kind, idempotency_key)`; patrón `INSERT … ON CONFLICT DO NOTHING` + `GET DIAGNOSTICS ROW_COUNT` → replay si 0.
- **Outbox (DEC-20)**: tabla `events` existe pero hoy es un **stub CI-compat** (`id, company_id, title, created_at`) con 0 filas; C-25 outbox-activation (pendiente) la endurecerá. C-29 solo hace el INSERT del hecho; no depende de consumers activos.

El backend FastAPI sigue arquitectura 3 capas (routers→services→repositories), JWT-passthrough (`get_db_conn` inyecta los claims; RLS activa como red de seguridad), **nunca `service_role`**. El patrón de C-28 (`services/cash.py`, `repositories/cash_session_repository.py`, `routers/cash.py`) es el molde directo a replicar.

Última migración real en prod: `20260701000002`. El repo va adelantado en fechas — datar la nueva POR ENCIMA (ej. `20260702000001`), **no** con la fecha real `20260617…` (rompería el history).

## Goals / Non-Goals

**Goals:**
- `Quote` con ciclo de vida (`draft`/`sent`/`accept`/`expire`/`reject`) y `Quote.accept()` que crea un `SalesOrder` con los mismos ítems (sin tocar stock).
- `SalesOrder.confirm()` **transaccional y atómico** en un único RPC `SECURITY DEFINER`: stock (−) + caja (helper C-28 si efectivo) + numeración fiscal (C-27 si factura) + INSERT outbox, todo en un commit. Fallo a mitad → rollback total.
- `quickSale()` POS: crear + confirmar `SalesOrder` en una llamada idempotente.
- Retrocompat: las ventas legacy (`sales`/`sale_items`) siguen accesibles; `confirm()` también escribe la fila `sales`/`sale_items` para no romper listados/reportes/IA.
- Idempotencia de `confirm()` y `quickSale()` (DEC-06).
- Backend FastAPI completo (routers/services/repositories/schemas) + tests TDD.

**Non-Goals:**
- Cuentas corrientes / cobro a crédito (`CustomerAccount`) → C-30. En C-29 el pago es contado (efectivo o "otro"), no genera saldo deudor.
- Activar el consumer del outbox (C-25). C-29 solo inserta el evento.
- Migrar las ventas legacy a `sales_orders` (las viejas quedan en `sales`; las nuevas nacen en `sales_orders`).
- Llamar a AFIP en el hot path (el CAE es asíncrono por C-27 — `pending_cae`).
- UI rica de presupuestos/POS más allá de hooks + reuso del formulario de venta (puede diferirse en el apply).

## Decisions

### D1 — `confirm()`/`quickSale()` = un único RPC `SECURITY DEFINER`, NO orquestación en el service Python

**Decisión**: La transacción del hot path vive **íntegra en un RPC plpgsql `SECURITY DEFINER`** (`rpc_confirm_sales_order`, `rpc_quick_sale`). El service Python solo valida (Pydantic + `require_role`), arma el payload y lo invoca con una sola llamada; el repository hace `SELECT rpc_…(...)`.

**Por qué**: La atomicidad cross-módulo (stock + caja + numeración + outbox) exige una sola transacción de DB. Orquestar desde Python con asyncpg obligaría a abrir una transacción explícita en el repo y coordinar múltiples RPCs, multiplicando los puntos de fallo de red dentro de la ventana transaccional y dejando la consistencia a merced del backend. El proyecto ya resolvió esto así en `rpc_create_sale_operation` y C-28. El helper `c28_register_cash_movement` está diseñado precisamente para invocarse **dentro** de ese RPC.

**Alternativa descartada**: orquestación en el service con `async with conn.transaction():` y N RPCs. Rechazada: rompe el patrón establecido, alarga el hot path con round-trips, y un RPC `SECURITY DEFINER` puede invocar el helper `c28_*` (que está `REVOKE`-ado de PUBLIC) mientras que una llamada directa del rol `authenticated` no.

### D2 — Escritura por RPC `SECURITY DEFINER` ⇒ políticas RLS solo SELECT (gotcha #3 de C-28)

**Decisión**: Las 4 tablas nuevas (`quotes`, `quote_items`, `sales_orders`, `sales_order_items`) llevan RLS habilitada con **solo política SELECT** (más INSERT/UPDATE para `quotes`/`quote_items`, ver D3). Toda la escritura del hot path (`sales_orders`, `sales_order_items`, descuento de stock, caja, fiscal, outbox) pasa **exclusivamente por los RPCs `SECURITY DEFINER`**, que bypassan RLS pero aplican el guard `is_account_writer(account_id)` explícitamente.

**Por qué**: Es la corrección directa del 3er bug de C-28 (escrituras denegadas por falta de policy). Como el hot path va por RPC (D1) y NO por INSERT directo del repo como rol `authenticated`, **no se necesitan** políticas de INSERT/UPDATE en `sales_orders`/`sales_order_items`. Decisión consciente y documentada en la migración.

**Patrón RLS correcto (gotcha #2 de C-28)**: usar `account_id IN (SELECT current_account_ids())` — **NUNCA** `= ANY(current_account_ids())` (la función es SETOF → `0A000 set-returning functions not allowed in WHERE`). Tablas con `account_id` desnormalizado (patrón C-26/C-27) para RLS directa; los `*_items` resuelven `account_id` vía join al header o lo desnormalizan (se desnormaliza, igual que `sale_items.account_id`).

### D3 — Quote: escritura directa del repo (CRUD) ⇒ SÍ necesita políticas INSERT/UPDATE

**Decisión**: `quotes` y `quote_items` son CRUD comercial sin invariantes transaccionales caras (no tocan stock/caja). Su creación/edición puede ir por INSERT/UPDATE directo del repository como rol `authenticated`. Por lo tanto **SÍ** llevan políticas explícitas de INSERT (`WITH CHECK is_account_writer(account_id)`) y UPDATE (`USING … IN (SELECT current_account_ids()) WITH CHECK is_account_writer`), espejo de `fiscal_profiles`/`points_of_sale` de C-27.

**Excepción**: `Quote.accept()` SÍ va por RPC `SECURITY DEFINER` (`rpc_accept_quote`) porque debe (a) transicionar el estado del Quote y (b) crear el `SalesOrder` + ítems en una sola transacción atómica.

**Por qué**: separa la governance — el presupuesto es LOW/MEDIUM (catálogo comercial), la confirmación es el hot path. Evita un RPC por cada campo editable de un presupuesto.

### D4 — Estrategia de retrocompat con `sales` legacy: `confirm()` escribe también `sales`/`sale_items`

**Decisión**: `rpc_confirm_sales_order` / `rpc_quick_sale`, además de crear `sales_orders`/`sales_order_items`, inserta la fila `sales` + `sale_items` correspondiente (con `operation_id`, `branch_id`, `canal`) y registra el `stock_movements` con `reference_type = 'sale'`, **reusando la mecánica probada de `rpc_create_sale_operation_v2`**. Así los listados, reportes, Edge Functions de IA y el `delete`/`update` existentes siguen funcionando sin cambios. El `sales_orders` guarda `sale_operation_id` (FK al `operation_id` de la venta legacy generada) como puente.

**Por qué**: cero ruptura de los ~15 archivos frontend y las Edge Functions que leen `sales`/`sale_items`. RN-97 no se viola: `sales` NO está en retirada (la columna plana del header sí lo está y se evita; se escribe vía la ruta v2 que usa `sale_items`). Es la forma más barata de retrocompat: una vista puente sola no permitiría los `stock_movements` ni la idempotencia compartida.

**Alternativa descartada**: solo `sales_orders` + vista `v_sales_compat` que une legacy + nuevas. Rechazada para C-29: requeriría migrar las lecturas de stock/delete/update a la vista en el mismo change (scope creep); se reserva para cuando `sales_orders` sea la única fuente (post-C-30).

### D5 — Idempotencia compartida vía `operation_idempotency` (DEC-06)

**Decisión**: `confirm()` y `quickSale()` reciben `idempotency_key` (UUID del cliente) y reusan `operation_idempotency` con `operation_kind = 'sale'` (misma que la venta legacy, dado que confirm escribe `sales`). Patrón: `INSERT … ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING` + `GET DIAGNOSTICS v_inserted = ROW_COUNT`; si 0 → replay (devuelve el `sales_order_id`/`operation_id` existente sin re-descontar stock, re-mover caja ni re-numerar).

**Por qué**: doble-click / reintento de red en POS no debe duplicar venta, descuento de stock, movimiento de caja ni número fiscal. Reusar la tabla y el `operation_kind='sale'` mantiene una sola fuente de idempotencia para la operación comercial completa.

### D6 — Cómo se enchufa `c28_register_cash_movement`

**Decisión**: Dentro de `rpc_confirm_sales_order`, si el pago es `cash` y se pasó `p_cash_session_id`, tras descontar stock se invoca:
```
PERFORM public.c28_register_cash_movement(p_cash_session_id, v_total, 'sale', v_sales_order_id);
```
El helper valida que la sesión esté `open` (si no → `P0409 no_open_session`, que propaga el rollback de TODA la transacción) y que la branch esté activa. El monto es positivo (ingreso, convención de signo de C-28: ventas `+`). `reference_id = sales_order_id`.

**Por qué**: reusa la lógica de caja aprobada de C-28 sin reimplementarla. Como el helper corre en la transacción del RPC, su INSERT es parte del commit atómico: si algo posterior falla, el movimiento de caja también se revierte. Si el pago no es efectivo (`p_cash_session_id` NULL), se omite la llamada.

**Validación de coherencia (guard en el RPC)**: si `payment_method = 'cash'` pero `p_cash_session_id` es NULL → `P0400`. El RPC NO abre ni cierra sesiones (eso es C-28); exige una ya abierta.

### D7 — Numeración fiscal opcional dentro del hot path

**Decisión**: `confirm()`/`quickSale()` reciben un flag/tipo de comprobante (`p_comprobante_type` nullable). Si la operación factura, dentro de la transacción se invoca `rpc_emit_pending_cae(p_comprobante_type, v_total, p_client_id, p_point_of_sale_id)` que reserva número e inserta `fiscal_documents` en `pending_cae`. El `sales_orders` guarda `fiscal_document_id`. Si `p_comprobante_type` es NULL (venta sin comprobante / ticket interno), se omite.

**Por qué**: AFIP/CAE es asíncrono por diseño (C-27, DEC-22) — solo se reserva el número y se persiste `pending_cae` dentro del commit; el relay pg_cron resuelve el CAE después. El hot path nunca habla SOAP con AFIP (riesgo §8 del modelo V2). `rpc_emit_pending_cae` es `SECURITY DEFINER` e invocable desde otro RPC definer.

### D8 — INSERT al outbox best-effort, compatible con el stub actual

**Decisión**: Al final del commit, el RPC hace `INSERT INTO public.events (...) ` con el hecho `SaleConfirmed` (payload mínimo: `sales_order_id`, `account_id`, `total`). Dado que `events` hoy es un stub (`id, company_id, title, created_at`), el INSERT en C-29 usará las columnas existentes (ej. `title = 'SaleConfirmed'`, `company_id = account_id` como puente) **o** la migración de C-29 agrega columnas nullable (`event_type`, `aggregate_id`, `payload jsonb`, `account_id`) con `ADD COLUMN IF NOT EXISTS` sin romper el stub. **Decisión: agregar columnas nullable** para que el evento sea consumible por C-25 sin re-migrar, manteniendo el INSERT dentro del commit.

**Por qué**: DEC-20 manda el INSERT en la misma transacción. Hacerlo compatible-hacia-adelante evita que C-25 tenga que reprocesar. El INSERT no puede fallar la venta: las columnas nuevas son nullable y el INSERT es de forma fija.

### D9 — Validación Pydantic v2 + guards en el service (regla dura del proyecto)

**Decisión**: Schemas Pydantic v2 (`QuoteIn`, `QuoteOut`, `QuoteItemIn`, `SalesOrderIn`, `ConfirmIn`, `QuickSaleIn`, `SalesOrderOut`, …) validan todo payload antes de tocar DB. Enums para `quote_status`, `payment_method` (`cash`/`other`), `comprobante_type`. Los guards `require_role(auth, ["user","admin"])` viven en el service, **nunca en el router** ni en el repository. TS sin `any`; componentes React en PascalCase.

## Risks / Trade-offs

- **[Migración mal datada rompe el history]** → Ejecutar `ls supabase/migrations/ | sort | tail -1` y datar por encima de `20260701000002` (ej. `20260702000001`). Documentado en tasks.
- **[RLS con función SETOF]** → Usar `account_id IN (SELECT current_account_ids())`, nunca `= ANY(...)`. Gate en code review + smoke.
- **[Escrituras denegadas por falta de policy]** → El hot path va por RPC `SECURITY DEFINER` (sin INSERT directo en `sales_orders`/`sales_order_items` ⇒ no se necesita policy de escritura). `quotes`/`quote_items` SÍ tienen INSERT/UPDATE policy (escritura directa del repo). Smoke transaccional valida ambas rutas en prod.
- **[Rollback parcial del hot path]** → Toda la lógica en un solo RPC ⇒ una excepción en cualquier paso (stock insuficiente, sesión cerrada, numeración) aborta la transacción entera. El test obligatorio "confirm falla a mitad → cero efectos" lo verifica con un smoke `BEGIN…RAISE→ROLLBACK`.
- **[Doble escritura `sales_orders` + `sales` puede divergir]** → Ambas en el mismo RPC/commit; el `stock_movements` único (`reference_type='sale'`) evita doble descuento. Test de invariante `branch_stock` −2 por quickSale de 2 uds.
- **[`events` stub vs forma futura]** → `ADD COLUMN IF NOT EXISTS` nullable; el INSERT usa forma fija. C-25 endurece el resto.
- **[Hot path largo bajo concurrencia POS]** → Sin HTTP/IA/AFIP dentro (CAE async); locks cortos (`FOR UPDATE` sobre producto, sesión de caja, fila de secuencia). Riesgo aceptado y mitigado per modelo V2 §8.
- **[Governance MEDIO toca caja]** → Reusa el helper aprobado de C-28; no toca el webhook de pagos. Se implementa con checkpoints y se valida con smoke contra prod.

## Migration Plan

1. **Migración SQL** `20260702000001_c29_quote_salesorder.sql` (datar tras verificar el último timestamp real):
   - `ADD COLUMN IF NOT EXISTS` nullable a `events` (`event_type`, `aggregate_id`, `account_id`, `payload jsonb`).
   - Tablas `quotes`, `quote_items`, `sales_orders`, `sales_order_items` + índices + RLS (SELECT en las 4; INSERT/UPDATE en `quotes`/`quote_items`).
   - RPCs `SECURITY DEFINER`: `rpc_confirm_sales_order`, `rpc_quick_sale`, `rpc_accept_quote` (+ helpers CRUD de Quote si hace falta). `REVOKE … FROM PUBLIC, anon` + `GRANT EXECUTE … TO authenticated`.
   - Bloque `DO $$ … $$` con gates SQL (RED→GREEN) en SAVEPOINTs con ROLLBACK al final (patrón C-28 §1.9): tipo de comprobante inválido, payment cash sin sesión, etc.
2. **Backend FastAPI**: schemas → repositories → services → routers; registrar en `main.py`. TDD (pytest + pytest-asyncio), mocks de asyncpg como en `test_c28_cash_session.py`.
3. **Frontend** (opcional/diferible): hooks React Query + reuso del form de venta para quickSale.
4. **CI** aplica la migración y deploya en el merge a `main` (`.github/workflows/deploy.yml`).
5. **Smoke transaccional en prod** (BEGIN…RAISE→ROLLBACK contra `gxdhpxvdjjkmxhdkkwyb`): quickSale −2 stock; stock 0 → P0409; accept→SalesOrder; confirm a mitad → rollback total. Es el gate de validación clave.

**Rollback**: `DROP FUNCTION` de los 3 RPCs + `DROP TABLE` de las 4 tablas (orden inverso de FKs); las columnas nullable agregadas a `events` pueden quedar (inertes) o dropearse. Sin pérdida de datos: feature nueva, 0 filas en prod. Las ventas legacy quedan intactas.

## Resolved Decisions (PO sign-off 2026-06-17)

The following open questions were resolved by the PO before apply started.
Design sections above reflect these resolutions; they are locked for C-29.

- **OQ-1 — Forma del comprobante en quickSale — RESUELTO**: El tipo de comprobante es **explícito y NULLABLE**. `quickSale()` puede confirmar una venta SIN emitir comprobante fiscal en el acto (ticket interno / sin comprobante). El paso de numeración en `confirm()` solo corre cuando se pasa un `p_comprobante_type` no-nulo. El comprobante puede emitirse por separado.
- **OQ-2 — `payment_method` en C-29 — RESUELTO**: Solo `cash` | `other` en C-29. Crédito / cuenta corriente diferido a C-30. No hay path de crédito en este change.
- **OQ-3 — `branch_id` en `sales_orders` — RESUELTO**: **NOT NULL** a nivel de columna (DEC-19: todo documento operativo lleva `branch_id` obligatorio). El RPC resuelve la branch default ("Casa Central") cuando el cliente no la pasa (cuentas de una sola sucursal).
- **OQ-4 — Caducidad de `Quote` — RESUELTO**: Comando `expire()` + verificación defensiva on-read (un Quote con `valid_until < now()` se trata como expirado al leer). **Sin job pg_cron en C-29**.
- **OQ-5 — Outbox columnas — RESUELTO (scope expandido)**: C-29 **reshape la tabla stub** `events` (hoy solo `id, company_id, title, created_at`) agregando columnas nullable: `account_id uuid`, `event_type text`, `aggregate_type text`, `aggregate_id uuid`, `payload jsonb`, `occurred_at timestamptz default now()`, `processed_at timestamptz`. La migración usa `ADD COLUMN IF NOT EXISTS` para no romper el stub. C-25 solo añadirá el relay + consumers (no re-migra la tabla). El INSERT `SaleConfirmed` ocurre dentro de `confirm()` en el mismo commit. RLS SELECT por `account_id IN (SELECT current_account_ids())`.
