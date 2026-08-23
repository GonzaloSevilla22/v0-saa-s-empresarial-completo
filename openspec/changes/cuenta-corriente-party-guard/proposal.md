## Why

Las RPCs de cuenta corriente resuelven el tenant desde la sesión (`current_account_ids()` + `is_account_writer`), pero **nunca validan que el cliente o el proveedor que reciben por parámetro pertenezca a ese tenant**. La auditoría de `pg_get_functiondef` que acompañó al hotfix de seguridad #446 (2026-08-22) lo dejó a la vista: `rpc_register_payment_received`, `rpc_register_payment_made` y `rpc_register_supplier_charge` pasan `p_client_id` / `p_supplier_id` directo a `c30_get_or_create_customer_account` / `c30_get_or_create_supplier_account`, que hacen `INSERT ... ON CONFLICT DO NOTHING` sin más preguntas. El FK `client_id REFERENCES clients(id)` no está scopeado por tenant, así que la fila entra.

El contraste está en el mismo archivo de migración: `rpc_create_customer_account` y `rpc_create_supplier_account` (C-30, `20260720000001` L509-612) **sí** validan —`SELECT id FROM clients WHERE id = p_client_id AND account_id = v_account_id` → `P0404 client_not_found`— y quedaron confirmadas como seguras en esa misma auditoría. El guard existe, está probado y simplemente no se replicó en las RPCs que mueven dinero.

Las consecuencias, en orden de gravedad:

1. **Escritura cross-tenant real (severidad alta, hallazgo nuevo de este propose).** `_pay_register_party_charge(p_account_id, p_party_kind, p_party_id, ...)` es `SECURITY DEFINER`, recibe el `account_id` **como parámetro** —sin resolverlo de la sesión ni validar `is_account_writer`— y tiene `GRANT EXECUTE ... TO authenticated` (`20261001000001` L137). Es decir: es invocable por PostgREST (`POST /rest/v1/rpc/_pay_register_party_charge`) por cualquier usuario autenticado, con el `account_id` de **otro** tenant. Eso no corrompe una fila propia: escribe un movimiento en la cuenta corriente **real** de la víctima, emite su `CustomerAccountCharged` y le postea el asiento contable. `_journal_post_from_event(events)` tiene el mismo problema, agravado: nació con `REVOKE ... FROM authenticated` (`20260803000001` L517, reafirmado en `20260804000007`) y lo **perdió** en `20261001000001` L1914, donde el "patrón uniforme" de REVOKE+GRANT lo convirtió en un `GRANT`. Permite forjar un evento y postear un asiento arbitrario en cualquier `account_id`. Ninguno de los dos tiene caller del lado app: no aparecen en `frontend/` ni en `backend/` salvo en comentarios y en `database.types.ts` generado —justamente la prueba de que PostgREST los expone.
2. **Dato corrupto en el libro propio (el hallazgo original).** Un writer del tenant A que use el UUID de un cliente del tenant B crea una fila en `customer_accounts` con `account_id = A` y `client_id` de B, con su saldo, sus movimientos, su `payments_received` y su asiento contable. No es fuga de datos de B —su cuenta corriente queda intacta, es una fila separada—, pero A termina con deuda, cobros y partida doble contra una entidad que **jamás va a ver en sus listas** (esas sí filtran por `account_id`). Saldo huérfano, imposible de conciliar desde la UI.
3. **El agujero está abierto en el camino de más volumen, no solo en el manual.** Los callers de `_pay_register_party_charge` —`rpc_create_sale_operation_v2` (formulario), `rpc_create_sale_operation`, `_c29_confirm_order_core` (POS)— reciben `p_client_id` del payload y **tampoco** validan tenencia: no hay una sola ocurrencia de `FROM public.clients` en `20261002000001`, `20261003000001` ni `20261004000001`. La única validación es `IF v_kind = 'credit' AND p_client_id IS NULL`. Un guard puesto solo en las tres RPCs de pago dejaría el hueco intacto justo donde pasa la venta a crédito.

No hay ningún trigger ni CHECK que cubra esto: el `grep` sobre las 200+ migraciones devuelve exactamente **dos** `client_not_found`/`supplier_not_found` en todo el repo, los dos de C-30.

## What Changes

### 1. Guard de pertenencia en el choke point (cubre todos los caminos, presentes y futuros)

- `c30_get_or_create_customer_account(p_account_id, p_client_id)` y `c30_get_or_create_supplier_account(p_account_id, p_supplier_id)` validan, **antes** del `INSERT ... ON CONFLICT`, que la parte exista en `clients`/`suppliers` con ese `account_id`. Si no, `RAISE ... USING ERRCODE = 'P0404'` con los mensajes ya canónicos `client_not_found: %` / `supplier_not_found: %`.
- Una sola redefinición cubre **todos** los llamadores: las 3 RPCs de pago, `_pay_register_party_charge` (y con él POS, formulario de venta y el alta de compra que `compras-proveedor-cuenta-corriente` va a cablear), `rpc_create_customer_account`/`rpc_create_supplier_account` (que ya validaban — el guard queda redundante ahí, a propósito).
- **Sin helper nuevo**: el predicado se copia del patrón canónico de `rpc_create_customer_account`. No se acuñan ERRCODEs nuevos.

### 2. Guard explícito en las tres RPCs de pago (defensa en profundidad + mensaje temprano)

- `rpc_register_payment_received`, `rpc_register_payment_made` y `rpc_register_supplier_charge` validan la parte **antes** del `INSERT` de idempotencia, para que un `p_client_id` inválido no consuma la `idempotency_key` y para que el error sea del dominio del llamador y no del helper.
- Las tres firmas quedan **idénticas**: `CREATE OR REPLACE` sin `DROP`, sin riesgo de overload 42725.

### 3. Cierre de la primitiva de escritura cross-tenant (lo más grave)

- **BREAKING (superficie pública de PostgREST)**: `REVOKE EXECUTE ... FROM authenticated` sobre `_pay_register_party_charge` y `_journal_post_from_event`. Ambos son helpers internos, invocados únicamente desde funciones `SECURITY DEFINER` (el `PERFORM` corre como el definer, así que el revoke no los afecta) y sin ningún caller del lado app. Restaura el estado que `_journal_post_from_event` tenía antes de `20261001000001` y lo alinea con `_pay_reverse_party_charge`, que sí nació bien (`REVOKE ALL ... FROM PUBLIC, anon, authenticated`).
- **Gate permanente en CI**: `test_function_acl_gate.sql` hoy solo mira `anon` en su chequeo (2) —por eso esto pasó desapercibido—. Suma un chequeo (3): ninguna función `SECURITY DEFINER` de nombre interno (prefijo `_`, `c28_`, `c29_`, `c30_`) puede quedar `EXECUTE`-able por `authenticated` fuera de una allowlist justificada. Es la red que impide que el "patrón uniforme" de REVOKE+GRANT vuelva a regalar un helper, que es exactamente cómo se rompió `_journal_post_from_event`.
- La auditoría de ACLs de la task correspondiente se corre **contra prod**, no solo contra local: el hallazgo post-merge de #432 (`asiento-venta-formulario`) documentó que el proyecto hospedado otorga `EXECUTE` a `anon`/`authenticated` **directamente**, no vía el pseudo-rol `PUBLIC`, así que un `REVOKE ... FROM PUBLIC` que se ve limpio en el stack local puede estar abierto en producción.

### 4. Medición del daño histórico (sin reparación automática)

- Auditoría **read-only** en prod: filas de `customer_accounts`/`supplier_accounts` cuya parte pertenece a otro tenant, y sus `payments_received`/`payments_made`/movimientos/eventos asociados. Lo esperable es **0** —el vector exige conocer un UUID ajeno—, pero se mide, no se supone.
- Si hay filas, la reparación es un **checkpoint 🛑 firmado por el PO**, con script propio fuera de `supabase/migrations/` (mismo criterio que el backfill de `delete-guard-ledgers`). Nunca automática dentro de la migración.

### Sin superficie frontend

Change **sin superficie frontend** (regla PO 2026-08-02, excepción declarada): no hay pantalla, ruta ni entrada de menú nueva. El único efecto observable por un usuario legítimo es un `404` en lugar de un `500`/éxito silencioso, y ese camino ya está construido: `P0404 → 404` está mapeado en `backend/core/errors.py` (`_BUSINESS_ERRCODE_STATUS`, handler global de `asyncpg.PostgresError` registrado en `main.py:68`) y además explícitamente en los services de `customer_accounts`, `supplier_accounts`, `sales`, `sales_orders` y `quotes`. Ningún formulario permite elegir una parte ajena: los selectores de cliente y proveedor listan filtrando por `account_id`. Un usuario legítimo **no puede** disparar este error desde la UI; el guard existe para el que no pasa por la UI.

## Capabilities

### New Capabilities

Ninguna. El change endurece capabilities existentes; no introduce dominio nuevo.

### Modified Capabilities

- `customer-account`: el cobro y la creación/resolución de la cuenta corriente exigen que el cliente pertenezca al tenant; se especifica el rechazo `P0404` sin efectos parciales.
- `supplier-account`: espejo exacto para pago a proveedor y cargo manual de proveedor.
- `party-account-charge`: el helper compartido deja de aceptar combinaciones `(cuenta, parte)` incoherentes, y deja de ser invocable directamente por el rol de aplicación.
- `account-tenancy`: invariante nuevo de plataforma — las funciones `SECURITY DEFINER` que reciben el tenant por parámetro no son ejecutables por los roles de aplicación, con gate permanente en CI.

## Impact

**DB (una migración, `CREATE OR REPLACE` sin `DROP` — ninguna firma cambia)**

- `c30_get_or_create_customer_account`, `c30_get_or_create_supplier_account` — guard nuevo. Siguen `REVOKE ALL FROM PUBLIC` sin `GRANT` (son internos).
- `rpc_register_payment_received`, `rpc_register_payment_made`, `rpc_register_supplier_charge` — guard nuevo, reescritas desde el `pg_get_functiondef` **vivo** (gate de integridad de función; ver checkpoint 🛑 en tasks 1.4).
- `_pay_register_party_charge`, `_journal_post_from_event` — solo ACL, sin tocar el cuerpo.

**CI**

- `.github/workflows/KPI_Validation.yml`: la migración nueva se suma como último eslabón de la cadena de reapply, y un step nuevo corre `supabase/tests/test_cuenta_corriente_party_guard.sql`.
- `supabase/tests/test_function_acl_gate.sql`: chequeo (3) nuevo.
- Gates que deben seguir verdes sin cambios: `test_function_acl_gate.sql`, `test_errcode_5char_gate.sql`, `test_idempotency.sql`, `test_pagos_cableados_restantes.sql`, `test_delete_guard_ledgers.sql`, `test_asiento_venta_formulario.sql`.

**Backend Python**

- Sin cambios de código. Tests nuevos que asserten la propagación `P0404 → 404` en los tres services de cuenta corriente (mock de `asyncpg`, molde de `backend/tests/test_c30_customer_supplier_accounts.py`). Baseline actual: 1495/1495.

**Frontend**

- Sin cambios. `frontend/lib/database.types.ts` se regenera si el pipeline de tipos corre después del revoke (las dos funciones dejan de aparecer bajo el rol `authenticated`) — es consecuencia, no objetivo.

**Relación con otros changes**

- `compras-proveedor-cuenta-corriente` (propuesta 2026-08-22, apply pendiente): **independiente y anterior recomendado**. Ese change activa `_pay_register_party_charge(..., 'supplier', ...)` desde el alta de compra; el guard tiene que existir antes de que empiece a postear cargos a proveedores reales. No hay conflicto de archivos: este change no toca `suppliers`, ni el formulario de compra, ni `rpc_create_purchase_operation`. Si `compras-*` se aplica primero, este change lo cubre igual sin cambios (el guard está en el choke point).
- Consume el mismo patrón de gate permanente que `test_errcode_5char_gate.sql` (`limpiezas-pagos-admin` G3) y `test_function_acl_gate.sql` (advisors 0028/0029).
