## Context

### El mapa real del POS (verificado en prod `gxdhpxvdjjkmxhdkkwyb`, 2026-08-19)

```
frontend/app/(dashboard)/ventas/pos/page.tsx
  └─ estado: paymentMethod: "cash" | "other"  (2 botones hardcodeados)
     └─ useQuickSale  (hooks/data/use-sales-orders.ts, PaymentMethod = "cash"|"other")
        └─ POST /sales-orders/quick-sale  (backend/routers/sales_orders.py)
           └─ services/sales_orders.quick_sale → repositories/sales_order_repository.quick_sale
              └─ SELECT public.rpc_quick_sale($1..$9)
                 ├─ INSERT sales_orders (status='draft', payment_method=<texto>)
                 ├─ record_status_transition(NULL→'draft')
                 ├─ INSERT sales_order_items
                 └─ public._c29_confirm_order_core(7 args)   ← el corazón
```

`_c29_confirm_order_core` (también invocado por `rpc_confirm_sales_order`, que es un wrapper de 10 líneas) hace, en **una** transacción:

| # | Bloque | Detalle verificado |
|---|--------|--------------------|
| 1 | Auth + guards | `auth.uid()`, `is_account_writer`, orden en `draft`, branch no `closed` |
| 2 | `cash_requires_session` | `cash` sin `p_cash_session_id` → P0400 |
| 3 | **Validación de vocabulario** | `IF p_payment_method NOT IN ('cash','other') THEN invalid_payment_method` |
| 4 | Idempotencia | `operation_idempotency` `(user_id, 'sale', key)` + return temprano `replayed=true` |
| 5 | Por línea | lock `products FOR UPDATE`, gate `branch_stock`, `c21_apply_branch_stock_delta`, `INSERT sales` (día ART vía `reporting_local_today()`), `INSERT sale_items` con snapshots (#255), `INSERT stock_movements` con `unit_cost_snapshot` |
| 6 | Caja (C-28) | `IF payment_method='cash' → c28_register_cash_movement(session, total, 'sale', order_id)` |
| 7 | Fiscal (C-27) | `IF p_comprobante_type IS NOT NULL → rpc_emit_pending_cae(...)` |
| 8 | Outbox | `INSERT events 'SaleConfirmed'` con `payment_method` **texto** en el payload |
| 9 | Historial | `record_status_transition('draft'→'confirmed')` |
| 10 | Cierre | `UPDATE sales_orders SET status, payment_method, total, sale_operation_id, fiscal_document_id` |

**Falta un bloque.** Entre el 6 y el 7 debería vivir el bloque `credit` de C-30. Lo agregó `20260720000001_c30_customer_supplier_accounts.sql` (líneas 1110-1290: guard `credit_requires_client`, validación ampliada a `('cash','other','credit')`, `c30_get_or_create_customer_account` + `c30_register_customer_account_movement` + evento `CustomerAccountCharged`) y lo borró **al día siguiente** `20260721000001_c29_write_sale_items.sql`, que reescribió la función entera desde una base previa. Las cuatro reescrituras posteriores (`20260806000001` snapshot, `20260807000001` status-history, `20260907000001` timezone, `20260928000001` payment-methods) copiaron la versión sin el bloque. Nadie lo notó porque **ninguna superficie ofrecía `credit`**: el error `invalid_payment_method` era inalcanzable.

### Estado numérico en prod

| Dato | Valor |
|------|-------|
| `MAX(version)` migraciones | `20260928000001` |
| `payment_methods` | 210 filas = 35 cuentas × 6 `kind` (`cash,transfer,card,wallet,credit,other`), todas activas |
| `payment_methods_kind_check` | `{cash,transfer,card,check,wallet,credit,other}` (7 — `check` sembrable, no sembrado) |
| `sales_orders_payment_method_check` | `{cash,transfer,card,other,credit}` (5) |
| `sales_orders` | 120 (63 `cash`, 57 `other`), **0 sin `sale_operation_id`** |
| `sales` con `payment_method_id` | 219 (backfill POS de #419) |
| `cash_movements` | 63 · `cash_sessions` 2 |
| `customer_account_movements` | **0** |

### Restricciones

- **RN-97 / precedente de convivencia**: el header plano de `sales`/`purchases` sigue vivo. Dropear columnas en el mismo change que reescribe RPCs de dinero es el patrón que este proyecto ya decidió no repetir.
- **v3-api-standards / DEC-24**: la unidad de trabajo es la RPC `SECURITY DEFINER`. Nada de multi-statement desde el cliente.
- **Regla del proyecto**: reutilización antes que repetición — `usePaymentMethods`, `useCustomerAccount`, `PaymentMethodSelect`, `c28_register_cash_movement`, `c30_*` ya existen y se consumen, no se reescriben.

## Goals / Non-Goals

**Goals**

1. El POS ofrece las formas de pago **del catálogo de la cuenta**, no un enum hardcodeado.
2. Un solo vocabulario: `sales_orders.payment_method` ⊆ `payment_methods.kind`, verificado por gate.
3. La venta a cuenta corriente **funciona de punta a punta**: se elige en el POS y postea el cargo en `customer_account_movements` en el mismo commit — restaurando lo que el spec `sales-order` ya exige.
4. La política de caja deja de ser accidental: queda escrita como regla de negocio con su fundamento.
5. Cero regresión en lo ya ganado: acarreo de líneas (#415), espejo de stock (#417), imputación en forms (#419), snapshots (#255), historial de estados, idempotencia, día ART.

**Non-Goals**

- Tocar el bloque fiscal/AFIP (C-27). Se copia sin modificar; cualquier cambio ahí sería un change aparte con sign-off.
- `bank_movements` / conciliación bancaria para `transfer`/`card` (OQ-A).
- Asiento contable por forma de pago (OQ-B).
- Que el form de venta común mueva caja (OQ-C) o postee cuenta corriente (OQ-D).
- Dropear `sales_orders.payment_method` TEXT (OQ-F).
- Formas de pago en compras/pagos a proveedor más allá de lo ya hecho en #419 (OQ-E).

## Decisions

### D1 — `payment_method_id` **convive** con el TEXT; el TEXT pasa a ser derivado

`sales_orders` gana `payment_method_id uuid NULL REFERENCES payment_methods(id) ON DELETE SET NULL`. El TEXT **no se dropea ni se deprecia a nivel storage**: pasa a ser una columna **derivada del `kind`**, escrita exclusivamente por la RPC.

*Por qué no migrar la columna*: el TEXT es (a) el discriminador sobre el que ramifica el hot path, (b) parte del payload del evento `SaleConfirmed` que ya está en `events` y que consumen el outbox y los consumidores de notificaciones, (c) la clave de la derivación de lectura D7 de #419 que sostiene el listado del histórico. Migrarlo obligaría a reescribir consumidores de outbox en el mismo change que toca las RPCs de dinero — exactamente el blast radius que el PO gateó.

*Por qué no basta el TEXT solo*: el `kind` no identifica la forma de pago. Dos métodos de la misma cuenta pueden compartir `kind` ("Mercado Pago" y "Ualá", ambos `wallet`); el reporte y el listado necesitan el `id`.

*Alternativa descartada*: columna generada (`GENERATED ALWAYS AS`) para el TEXT. No se puede: requiere una subconsulta a `payment_methods`, y las columnas generadas de Postgres son inmutables sobre la propia fila.

**Invariante**: cuando `payment_method_id IS NOT NULL`, `payment_method` SHALL ser igual al `kind` de esa forma de pago. Es la RPC quien lo garantiza (D2), y hay un gate que lo verifica sobre los datos.

### D2 — La RPC resuelve el `kind`; el cliente no elige la taxonomía

Firma nueva, parámetro **trailing** con default (nunca en el medio: rompería a los callers posicionales):

```
rpc_quick_sale(..., p_canal text DEFAULT NULL, p_payment_method_id uuid DEFAULT NULL)
rpc_confirm_sales_order(..., p_canal text DEFAULT NULL, p_payment_method_id uuid DEFAULT NULL)
_c29_confirm_order_core(..., p_canal text DEFAULT NULL, p_payment_method_id uuid DEFAULT NULL)
```

Resolución, en este orden:

1. `p_payment_method_id IS NOT NULL` → `SELECT kind INTO v_kind FROM payment_methods WHERE id = p_payment_method_id AND account_id = v_account_id AND deleted_at IS NULL`. Si no hay fila → `payment_method_not_found` (P0404). Se admite una forma de pago **inactiva** solo si ya estaba imputada (no aplica en el alta: en el alta debe estar activa → `payment_method_inactive`, P0400).
2. `p_payment_method IS NOT NULL` y difiere de `v_kind` → `payment_method_mismatch` (P0400). El cliente manda ambos (D6) y la RPC no le cree: re-deriva y compara.
3. `p_payment_method_id IS NULL` → camino legacy: `v_kind := COALESCE(p_payment_method, 'other')`, `payment_method_id` queda `NULL`. Mantiene vivos a `promote_legacy_sale_to_order` y a cualquier caller que no se actualice.

Efectos: `sales_orders.payment_method := v_kind`, `sales_orders.payment_method_id := p_payment_method_id`, y **cada fila legacy de `sales` de la operación** nace con `payment_method_id = p_payment_method_id`. Con eso las ventas nuevas del POS ya no dependen de la derivación de lectura.

*Sobre `DROP FUNCTION`*: las dos RPCs públicas tienen **todos** sus parámetros con `DEFAULT`. Agregar uno más sin dropear la firma vieja produce dos candidatas igualmente válidas para la misma invocación → `42725 function is not unique`. La migración hace `DROP FUNCTION IF EXISTS public.rpc_quick_sale(text,uuid,jsonb,text,uuid,text,uuid,uuid,text)` con la firma **exacta** antes del `CREATE`, y re-emite `REVOKE ALL ... FROM PUBLIC` + `GRANT EXECUTE ... TO authenticated` en el mismo archivo (el `DROP+CREATE` resetea las ACLs — gotcha ya vivido en el backlog de advisors 0028/0029).

### D3 — Restaurar el bloque `credit`, no inventarlo

El bloque se reconstruye **desde la migración `20260720000001` líneas 1110-1290**, que es su forma canónica y ya está reflejada en el spec `sales-order` con sus escenarios. Se inserta entre el bloque de caja (6) y el fiscal (7), y ramifica sobre `v_kind`, no sobre el texto crudo:

```
IF v_kind = 'credit' THEN
  v_customer_account_id := c30_get_or_create_customer_account(v_account_id, v_order.client_id);
  PERFORM c30_register_customer_account_movement(v_customer_account_id, v_total, 'sale', p_sales_order_id);
  INSERT INTO events (... 'CustomerAccountCharged' ...);
END IF;
```

Con el guard `credit_requires_client` (P0400) ubicado **antes** del descuento de stock, junto a los demás guards de entrada.

*Por qué esto no es "feature nueva encubierta"*: el requirement `SalesOrder.confirm() es transaccional y atómico` ya dice, palabra por palabra, «(c-bis) si `payment_method = 'credit'` … invoca `c30_register_customer_account_movement` … una venta a crédito SHALL exigir `client_id`», y tiene tres escenarios propios. Este change alinea el código con su spec.

*Por qué el riesgo de sorpresa es nulo*: hoy `credit` es inalcanzable desde toda superficie (el POS solo ofrece 2 botones; el form solo imputa etiqueta) **y** la RPC lo rechaza con `invalid_payment_method`. No hay historia que reinterpretar: `customer_account_movements` tiene 0 filas.

### D4 — Validación de vocabulario: del par cerrado al catálogo

`IF p_payment_method NOT IN ('cash','other')` pasa a validarse contra la misma lista del CHECK, es decir contra los 7 `kind`. Los `kind` sin cableado (`transfer`, `card`, `check`, `wallet`) siguen exactamente el camino que hoy sigue `other`: se persisten, no mueven caja, no postean cuenta corriente, **no** generan `bank_movements` ni asiento.

*Por qué no cablear `transfer`/`card` a `bank_movements` acá*: `_register_bank_movement` exige `bank_account_id`, un dato que el POS no tiene y que obligaría a otra decisión de UX (¿elegir cuenta bancaria en el mostrador?). Queda en OQ-A con recomendación de change propio, junto a la conciliación.

*Gate de vocabulario*: un test SQL exige que el conjunto enumerado por `sales_orders_payment_method_check` sea **idéntico** al de `payment_methods_kind_check`. Si alguien agrega un `kind` y olvida el CHECK, el gate falla en CI.

### D5 — Política de caja: la mueve el camino, no la etiqueta (resuelve OQ-3)

**Decisión: el POS exige sesión de caja abierta y genera `cash_movement` para `kind='cash'`. El form de venta común no lo hace, y eso queda escrito como regla de negocio.**

Lo primero ya es así y se conserva sin tocar: la RPC exige `cash_session_id` (P0400 `cash_requires_session`) y `c28_register_cash_movement` valida que la sesión esté `open` (P0409 `no_open_session`) y la sucursal activa. El POS además bloquea el submit en el cliente.

El fundamento de lo segundo — y por qué **no** conviene "unificar" haciendo que el form también mueva caja:

1. **El arqueo se rompería como señal.** `rpc_close_cash_session` calcula `expected_balance = opening_balance + Σ(cash_movements)` y materializa `difference = counted − expected`, que `v3-document-status-history` registra como `reason` del cierre y que RN-95 usa como señal antifraude. Inyectar en la sesión abierta el importe de una venta que nadie puso en el cajón convierte cada diferencia en ruido: el operador contaría bien y el sistema le marcaría faltante.
2. **No hay sesión correcta a la que atribuirla.** El form acepta `p_date` — se cargan ventas de días anteriores. Una `cash_session` es un objeto acotado a su apertura/cierre; no existe "la sesión de una venta del martes pasado" si ya cerró.
3. **El form no tiene sucursal-caja resuelta.** El POS resuelve `branch → cashbox → currentSession` explícitamente; el form ni siquiera pregunta por caja.
4. **Son dos actos distintos.** El POS es "cobré ahora en el mostrador". El form es "registro una venta que ocurrió". La etiqueta describe cómo se pagó; el camino describe si el dinero pasó por esta caja.

Por eso el spec pasa a decirlo en positivo (*"la caja se alimenta del camino del mostrador"*) en vez de dejarlo como una limitación del selector. Y el texto de apoyo de `PaymentMethodSupportText` se reescribe para **nombrar el POS**, no solo para negar:

> «Esta etiqueta registra cómo se cobró. El movimiento de caja lo genera la venta desde el POS, que exige una sesión abierta.» (con enlace a `/ventas/pos`)

El punto medio —un opt-in explícito en el form, habilitado solo con sesión abierta y fecha = hoy— queda en **OQ-C**, recomendado *no ahora*: agrega una decisión de UX y una revisión de arqueo que este change no necesita.

### D6 — El cliente manda `payment_method_id` **y** el `kind` que renderizó

El validador Pydantic vigente (`payment_method == 'cash' ⇒ cash_session_id requerido`) vive en el schema, sin acceso a la DB: no puede resolver el `kind` desde el `id`. Opciones: (a) mover la validación al servicio con un round-trip; (b) que el cliente envíe ambos y la RPC verifique.

Se elige **(b)**. El frontend ya tiene el `kind` en memoria (`usePaymentMethods` lo devuelve), así que enviarlo no cuesta un fetch; y la regla 2 de D2 hace que mentir sea imposible: la RPC re-deriva el `kind` desde el `id` y aborta con `payment_method_mismatch`. El schema conserva su validador tal cual, sin tocar la capa de servicios ni agregar latencia al hot path.

*Alternativa descartada*: resolver el `kind` en el service con un `SELECT` previo. Suma un round-trip al camino más caliente del sistema y duplica en Python una validación que la RPC igual tiene que hacer.

### D7 — Default y degradación del POS

El método preseleccionado es el activo de `kind='cash'` con menor `sort_order`; si la cuenta no tiene ninguno `cash`, el primero activo por `sort_order`. Si la cuenta **no tiene ningún método activo** (todos desactivados a mano), el POS cae al camino legacy de D2 regla 3 con `'other'` y muestra un aviso con enlace al gestor en `/configuracion` — degradar, no fallar: el mostrador nunca se queda sin poder cobrar por un catálogo mal configurado.

### D8 — UX de cuenta corriente en el POS (resuelve OQ-2)

Cuando el `kind` del método elegido es `credit`:

- **Cliente obligatorio**: el botón de cobro se deshabilita sin cliente, con el mismo lenguaje del guard de caja ya existente ("Elegí un cliente: una venta a cuenta corriente se le carga a alguien"). El backend sigue siendo la verdad (`credit_requires_client` P0400); la UI solo evita el viaje.
- **Saldo visible antes de cobrar**: `useCustomerAccount(clientId)` (C-30, ya existe) → "Saldo actual $X · Después de esta venta $X+total". Cobrar a cuenta sin ver la deuda acumulada es la forma más rápida de que la cuenta corriente vuelva a ser inútil.
- **Después**: el card de éxito enlaza a la cuenta corriente del cliente, no solo a `/ventas/ordenes`.
- **Sin caja**: elegir `credit` oculta el chip de sesión de caja y no exige sesión (el bloque 6 no corre).

### D9 — Backfill de las 120 órdenes: dentro de la migración

`UPDATE sales_orders so SET payment_method_id = pm.id FROM payment_methods pm WHERE pm.account_id = so.account_id AND pm.kind = so.payment_method AND pm.deleted_at IS NULL AND so.payment_method_id IS NULL`.

Va **en la migración** (a diferencia del backfill de #419, que fue script firmado): es una derivación dentro de la misma tabla, no cruza operaciones, no toca importes ni stock, es idempotente por el `IS NULL`, y toca 120 filas. El mapping es el mismo firmado por el PO en #419 (`cash`→Efectivo, `other`→Otro). Si una cuenta desactivó su método `cash`, esa orden queda `NULL` y la derivación de lectura la sigue mostrando — degradar, no fallar.

### D10 — La derivación de lectura D7 de #419 se conserva

`sales_repository.py` mantiene el `LEFT JOIN payment_methods pos_pm ON pos_pm.kind = so.payment_method`, ahora como **fallback del histórico**: la imputación explícita ya ganaba (`COALESCE(pm.id, pos_pm.id)`), y las ventas nuevas del POS traen `sales.payment_method_id` propio. No se borra código que sigue sosteniendo el listado de lo viejo.

## Risks / Trade-offs

| Riesgo | Mitigación |
|---|---|
| **Repetir la regresión de julio 2026**: reescribir `_c29_confirm_order_core` desde una base vieja y perder un bloque (fiscal, snapshots, status-history, día ART) | La migración parte de la **definición viva** obtenida con `pg_get_functiondef`, no de un archivo del repo. Gate SQL obligatorio: el cuerpo publicado debe contener `c28_register_cash_movement`, `c30_register_customer_account_movement`, `rpc_emit_pending_cae`, `record_status_transition`, `reporting_local_today`, `sale_items` y `unit_cost_snapshot`. Si falta uno, CI falla. |
| `42725 function is not unique` por overload | `DROP FUNCTION IF EXISTS` con la firma exacta de 9/8 args **antes** del `CREATE`; gate que cuenta `pg_proc` por `proname` y exige 1. |
| ACLs perdidas por el `DROP+CREATE` | `REVOKE ALL ... FROM PUBLIC` + `GRANT EXECUTE ... TO authenticated` re-emitidos en el mismo archivo; el gate `test_function_acl_gate.sql` ya existente los cubre. |
| El cargo de cuenta corriente restaurado sorprende a alguien | Imposible hoy: `credit` es inalcanzable desde toda superficie y la RPC lo rechaza. `customer_account_movements` = 0 filas. Aun así, el POS lo declara en pantalla antes de cobrar (D8). |
| Overpayment guard: `c30_register_customer_account_movement` lanza P0409 si el balance quedaría `< 0` | No aplica a un cargo (`amount > 0` siempre sube el saldo). Se documenta para que nadie lo reutilice al revés. |
| Doble fuente de verdad transitoria (TEXT + id) | Invariante D1 garantizada por la RPC + gate de datos (`payment_method_id IS NOT NULL ⇒ payment_method = kind`). El cierre definitivo es OQ-F. |
| El POS táctil se vuelve más lento de operar con N métodos | Grilla ordenada por `sort_order` con el default `cash` preseleccionado: el caso más común sigue siendo un tap. Targets ≥ 44px. |
| Idempotencia: un replay con distinta forma de pago | El return temprano de `operation_idempotency` ocurre **antes** de cualquier efecto y devuelve la operación original; la forma de pago del replay se ignora, igual que hoy se ignora el resto del payload. Sin cambio de comportamiento. |

## Migration Plan

1. **Migración única** `2026XXXX000001_pos_catalogo_pagos.sql`, base `20260928000001` (verificar `MAX(version)` en prod inmediatamente antes de fijar el timestamp — Supabase GitHub auto-aplica):
   1. `ALTER TABLE sales_orders ADD COLUMN IF NOT EXISTS payment_method_id uuid NULL REFERENCES payment_methods(id) ON DELETE SET NULL` + índice parcial `WHERE payment_method_id IS NOT NULL`.
   2. `DROP CONSTRAINT IF EXISTS sales_orders_payment_method_check` + `ADD CONSTRAINT` con los 7 `kind`.
   3. `CREATE OR REPLACE _c29_confirm_order_core(8 args)` — cuerpo vivo + resolución de `kind` + bloque `credit` + `payment_method_id` en `sales_orders` y en cada `INSERT INTO sales`.
   4. `DROP FUNCTION IF EXISTS` firmas exactas viejas de `rpc_quick_sale` y `rpc_confirm_sales_order` → `CREATE` con el arg trailing → `REVOKE`/`GRANT`.
   5. Backfill idempotente de las 120 órdenes (D9).
   6. `COMMENT ON COLUMN sales_orders.payment_method` declarando que es derivada del `kind` y que su fuente es `payment_method_id`.
2. **Backend**: schemas → repositories → services → routers, con pytest antes de cada capa.
3. **Frontend**: hook → POS → texto de apoyo del selector, con vitest antes de cada uno.
4. **Post-merge**: verificar en prod con SELECTs — conteo de firmas, invariante TEXT↔`kind`, 120 órdenes backfilleadas, ACLs.

**Rollback**: la migración es aditiva salvo el `DROP+CREATE` de firmas. Revertir = re-crear las firmas viejas desde `pg_get_functiondef` capturado antes del deploy (queda guardado en el PR). La columna y el CHECK ampliado pueden quedarse sin daño: el CHECK viejo era un subconjunto del nuevo.

## Open Questions

Ninguna bloquea la implementación. Todas van al PO con recomendación.

- **OQ-A — ¿`transfer`/`card` deben generar `bank_movements`?** *Recomendación: NO acá.* `_register_bank_movement` exige `bank_account_id`, dato que el POS no tiene; decidirlo obliga a una UX de "¿a qué cuenta entró?" en el mostrador. Change propio, junto a conciliación bancaria (`bank-reconciliation` ya está completa y sería su base natural).
- **OQ-B — ¿Asiento contable (`journal-entry-outbox`) discriminado por forma de pago?** *Recomendación: NO acá.* El outbox ya recibe `SaleConfirmed` con `payment_method`; el consumidor puede evolucionar sin tocar el hot path.
- **OQ-C — ¿Opt-in de caja en el form de venta común?** *Recomendación: NO ahora* (fundamento en D5). Si el PO lo quiere, la forma segura es un checkbox habilitado solo con sesión abierta **y** fecha = hoy, nunca automático.
- **OQ-D — ¿El form de venta con `kind='credit'` debe postear el cargo?** *Recomendación: NO ahora.* El form admite fechas pasadas y no tiene contrato de idempotencia con el ledger. Primero el POS; con datos reales en `customer_account_movements` se revisa.
- **OQ-E — ¿Compras/pagos a proveedor con el mismo tratamiento (`supplier_accounts`)?** *Recomendación: fuera de alcance.* Los helpers `c30_*_supplier_*` existen y son espejo exacto; sería mecánico si el PO lo pide.
- **OQ-F — ¿Cuándo se dropea `sales_orders.payment_method` TEXT?** *Recomendación: change aparte*, después de migrar los consumidores del payload de `SaleConfirmed`. Mientras tanto convive como columna derivada con su `COMMENT`.
- **OQ-G — ¿Se toca algo del bloque fiscal (C-27)?** **NO — gate de sign-off.** El bloque se copia sin modificar. Si durante el apply apareciera cualquier necesidad de tocarlo, la task se detiene y se escala al PO antes de escribir una línea.
- **OQ-H — ¿Sembrar el `kind='check'` (Cheque) en el catálogo?** El CHECK lo admite pero el seed de #419 no lo crea. *Recomendación: no sembrarlo automáticamente*; el usuario lo crea desde el gestor si lo usa. Ahora que el CHECK de `sales_orders` lo admite, funcionaría de punta a punta sin cambios.
