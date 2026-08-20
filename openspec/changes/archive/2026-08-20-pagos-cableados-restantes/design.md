## Context

Estado vivo capturado en prod (`gxdhpxvdjjkmxhdkkwyb`, 2026-08-20, sólo SELECT + `pg_get_functiondef`). `MAX(supabase_migrations.schema_migrations.version) = 20260930000001` → la migración de este change es **`20261001000001`**.

**Mapa de los dos caminos de alta de venta** (la asimetría que este change corrige):

| | POS | Formulario |
|---|---|---|
| RPC de entrada | `rpc_quick_sale` / `rpc_confirm_sales_order` → `_c29_confirm_order_core` | `rpc_create_sale_operation` → `rpc_create_sale_operation_v2` (flag `sale_items_rpc_v2`, default `true` cuando **no hay fila** — G1/D1 de `deudas-menores-agosto`) |
| Operaciones en prod | 120 | **223** (343 totales − 120) |
| Movimiento de caja | ✅ `c28_register_cash_movement` si `v_kind='cash'` | ❌ nada |
| Cargo cuenta corriente | ✅ bloque `credit` inline (restaurado por #421) | ❌ nada |
| Evento al outbox | ✅ `SaleConfirmed` (+ `CustomerAccountCharged`) | ❌ **cero `INSERT INTO public.events`** |
| Asiento contable | ✅ | ❌ |

Helpers ya existentes y verificados por firma en prod — **todo lo que hace falta ya está construido**:

```
c28_register_cash_movement(p_session_id uuid, p_amount numeric, p_type text, p_reference_id uuid)
c30_get_or_create_customer_account(p_account_id uuid, p_client_id uuid)
c30_register_customer_account_movement(p_account_id uuid, p_amount numeric, p_type text, p_reference_id uuid)
c30_get_or_create_supplier_account(p_account_id uuid, p_supplier_id uuid)
c30_register_supplier_account_movement(p_account_id uuid, p_amount numeric, p_type text, p_reference_id uuid)
```

Los pares `customer`/`supplier` son **estructuralmente idénticos** (mismo orden y tipo de argumentos), lo que hace que un despacho por tipo de parte sea trivial y honesto, no una abstracción forzada.

**Restricción heredada dura**: el gate `supabase/tests/test_confirm_core_integrity.sql` corre en CI y falla si el cuerpo publicado de `_c29_confirm_order_core` no contiene los substrings `c28_register_cash_movement`, `c30_register_customer_account_movement`, `c30_get_or_create_customer_account`, `credit_requires_client`. Nació de la regresión de julio 2026 (el bloque `credit` borrado en silencio por una reescritura desde base vieja) y **no puede simplemente relajarse**.

## Goals / Non-Goals

**Goals:**

- Una sola definición de "cargar una venta/compra a cuenta corriente", compartida por los dos caminos.
- Reutilizar `c28_register_cash_movement` para la caja del formulario, sin escribir aritmética de caja nueva.
- Que el arqueo siga siendo una señal antifraude confiable pese al opt-in nuevo.
- Que el `kind` del catálogo tenga efectos observables y verificables por gate, no sólo presencia en reportes.
- Preservar (y de hecho **fortalecer**) la protección anti-regresión sobre `_c29_confirm_order_core`.

**Non-Goals:**

- Construir el ABM de proveedores ni el selector de proveedor en el formulario de compra → change `compras-proveedor-cuenta-corriente`.
- Que la venta del formulario emita `SaleConfirmed` / genere asiento → change `asiento-venta-formulario` (ver D7).
- Tocar el bloque fiscal C-27 de `_c29_confirm_order_core` (gate OQ-G de `pos-catalogo-pagos`).
- `bank_movements` para `transfer`/`card` (OQ-A de `pos-catalogo-pagos`, sigue abierta).
- Backfill de las 223 ventas del formulario sin asiento (pertenece al change de D7).
- Dropear `sales_orders.payment_method` TEXT (OQ-F, sigue abierta).

## Decisions

### D1 — El helper compartido despacha por tipo de parte, no por tabla

```sql
_pay_register_party_charge(
  p_account_id   uuid,     -- cuenta (tenant)
  p_party_kind   text,     -- 'customer' | 'supplier'
  p_party_id     uuid,     -- client_id | supplier_id
  p_amount       numeric,  -- positivo: aumenta la deuda de la parte
  p_reference_id uuid,     -- sales_order_id | operation_id
  p_operation_id uuid      -- para el payload del evento
) RETURNS uuid              -- el *_account_id afectado
```

Adentro: un `CASE` sobre `p_party_kind` que elige el par de helpers C-30 y el `event_type` (`CustomerAccountCharged` / `SupplierAccountCharged`), y un `RAISE EXCEPTION 'invalid_party_kind'` en el `ELSE`.

**Alternativa descartada**: dos helpers separados (`_pay_register_customer_charge` / `_pay_register_supplier_charge`). Se descartó porque el cuerpo sería idéntico salvo dos identificadores — exactamente la duplicación que la regla del PO (2026-08-02, "reutilización antes que repetición") prohíbe, y el vector por el que la lógica diverge en silencio.

**Alternativa descartada**: que el helper reciba la tabla por `format()`/SQL dinámico. Se descartó por ser innecesariamente peligroso (inyección, plan cache) para un vocabulario cerrado de dos valores.

`SECURITY DEFINER` + `SET search_path = public, pg_temp`, patrón C-25, igual que los helpers que envuelve.

### D2 — `_c29_confirm_order_core` pierde el bloque inline y llama al helper

Es la decisión que el brief pide explícitamente ("no dupliques") y la que tiene el costo más visible: **rompe el gate de integridad tal como está escrito**. La respuesta correcta no es exceptuar el gate sino hacerlo transitivo (D3). El bloque `credit` se traslada verbatim en semántica: mismo `v_total` positivo, mismo `'sale'`, misma referencia `p_sales_order_id`, mismo payload de evento.

**Alternativa descartada**: dejar el inline en el POS y que sólo el formulario use el helper. Produciría dos autoridades para la misma regla — la causa raíz literal del incidente de julio que el gate existe para prevenir.

### D3 — El gate de integridad pasa de literal a transitivo

`test_confirm_core_integrity.sql` se reescribe para verificar la **cadena completa**:

1. `_c29_confirm_order_core` existe **y** su cuerpo contiene `_pay_register_party_charge` y `c28_register_cash_movement` y `credit_requires_client`.
2. `_pay_register_party_charge` existe **y** su cuerpo contiene `c30_get_or_create_customer_account`, `c30_register_customer_account_movement`, `c30_get_or_create_supplier_account`, `c30_register_supplier_account_movement`.
3. `rpc_create_sale_operation_v2` existe **y** su cuerpo contiene `_pay_register_party_charge` y `credit_requires_client` — extensión nueva: el camino del formulario queda igual de protegido que el del POS, que hasta hoy no lo estaba en absoluto.

El gate termina cubriendo **más** superficie que antes. Se verifica RED real (contra la definición viva actual) antes de aplicar la migración, como se hizo en `pos-catalogo-pagos`.

### D4 — Las tres condiciones del opt-in de caja se validan en el servidor

La UI decide si **muestra** el checkbox; la RPC decide si **honra** el `p_cash_session_id`. Un cliente que mande el parámetro sin cumplir las condiciones recibe error, no un movimiento espurio:

| Condición | Verificación en la RPC |
|---|---|
| `kind = 'cash'` | `JOIN payment_methods` por `p_payment_method_id` — el kind se **deriva**, nunca se acepta del cliente (D1 de `pos-catalogo-pagos`) |
| Sesión abierta | `cash_sessions.status='open'` **y** su `cashbox → branch` = la sucursal efectiva de la venta |
| Fecha = hoy | `p_date = (now() AT TIME ZONE 'America/Argentina/Mendoza')::date` — canon `business-day-timezone` |

Fallo → `ERRCODE 'P0422'` con mensaje distinguible por condición (`cash_optin_requires_cash_kind` / `cash_optin_requires_open_session` / `cash_optin_requires_today`).

**Por qué esto no destruye el arqueo**: la objeción original del spec era que el formulario admite fechas pasadas y que un importe que nadie puso en el cajón convierte toda `difference` en ruido. La primera se neutraliza con el guard de fecha; la segunda con el opt-in **explícito** — el usuario afirma que el efectivo entró a esa caja. `expected_balance` sigue siendo "lo que la caja debería tener según lo que alguien declaró haber recibido".

**Alternativa descartada**: que el formulario mueva la caja automáticamente cuando el kind es cash. Es lo que el spec de `pos-catalogo-pagos` prohibió con razón: silenciosamente convertiría toda venta retroactiva en una diferencia de arqueo.

### D5 — `p_cash_session_id` es opt-in, `credit` es obligatorio

Asimetría deliberada:

- **Caja**: sin `p_cash_session_id` no pasa nada. Ausencia = no registrar. Compatible hacia atrás con los 223 registros históricos y con cualquier cliente que no mande el parámetro.
- **Crédito**: si el kind derivado es `credit`, el cargo **siempre** se postea y el cliente es obligatorio (`credit_requires_client`, `ERRCODE 'P0422'`). No hay "vender a cuenta corriente sin anotarlo": eso es precisamente el estado roto que #421 encontró y que este change extiende al formulario.

### D6 — Operación con cargo de cuenta corriente o movimiento de caja: inmutable (estilo P0423)

La recomendación fundada que el brief pide. **Bloquear**, no ajustar.

Al editar, `rpc_atomic_update_sale_operation` verifica si la operación tiene un `customer_account_movements` o un `cash_movements` asociado por `reference_id`. Si lo tiene → `ERRCODE 'P0423'` (el mismo que `edicion-preserva-contexto` F2 usa para el bloqueo fiscal, ya mapeado a HTTP 409 por el handler global RFC 7807 — cero trabajo de plomería nuevo).

Razones para bloquear en vez de ajustar el movimiento espejo:

1. **`customer_account_movements` es append-only por diseño C-30.** "Ajustar" significa postear un contra-movimiento, que es una operación contable con semántica propia (nota de crédito / ajuste de saldo), no un efecto colateral silencioso de editar un renglón.
2. **El arqueo es una señal antifraude (RN-95).** Mutar retroactivamente un `cash_movement` de una sesión ya cerrada corrompe una diferencia ya firmada por alguien.
3. **Precedente vivo y aceptado**: `edicion-preserva-contexto` ya resolvió el caso análogo (comprobante fiscal emitido) bloqueando, y el PO lo aprobó. Coherencia sobre novedad.
4. **Reversible hacia arriba**: si mañana existe el flujo de ajuste, se relaja el guard. Al revés —desandar ajustes automáticos mal posteados— no hay vuelta.

**Alcance del bloqueo**: la operación entera, no sólo monto/método. Editar la fecha de una venta cuyo cargo ya está posteado desplazaría la referencia temporal del movimiento; media medida es peor que ninguna. El mensaje de error nombra la causa y sugiere la nota de crédito.

**Alternativa descartada**: bloquear sólo cambios de monto/método. Deja abierta la edición de fecha/sucursal, que también descuadra la atribución del movimiento.

### D7 — OQ-B: se corrige el productor de compras; el asiento del formulario de venta se documenta como gap

El consumidor `_journal_post_from_event` no necesita casi nada — `bank-payment-routing` C2 ya lo dejó ruteando por kind. Lo que entra:

- **Compras**: `rpc_create_purchase_operation` reemplaza `'payment_method', 'credit'` (literal) por el kind derivado de `p_payment_method_id`, con `COALESCE(..., 'credit')` para preservar el comportamiento actual cuando no hay forma de pago imputada. Sin este arreglo el catálogo en compras es puramente decorativo a efectos contables.
- **`wallet` → `1110 Banco`**: se agrega al predicado `v_is_bank` en las cuatro ramas que lo usan (`SaleConfirmed`, `PurchaseCreated`, `PaymentReceived`, `PaymentMade`). Hoy cae en `1100 Caja` por omisión, no por decisión: una billetera virtual no es efectivo en el cajón y su conciliación se parece a la bancaria.

Lo que **no** entra y por qué (el gap documentado que el brief pide decidir):

> La rama `SaleConfirmed` del consumidor es de forma `sales_orders`: escribe `source_doc_type='SalesOrder'`, `source_doc_ref = (payload->>'sales_order_id')::uuid`, y obtiene neto/IVA con `FROM sales_orders so LEFT JOIN fiscal_documents fd ON fd.id = so.fiscal_document_id`. Una venta del formulario **no tiene fila en `sales_orders`**. Emitir `SaleConfirmed` desde `rpc_create_sale_operation_v2` produciría un asiento con `source_doc_ref` apuntando a nada y `v_neto`/`v_iva` en `NULL` — que no sólo es incorrecto sino que **viola el invariante Σdébito = Σcrédito** (`ASSERT`, `ERRCODE P0450`) y haría fallar el consumidor en producción.

Cerrarlo bien requiere un `event_type` de forma operación (p. ej. `SaleOperationConfirmed`), una rama nueva en el consumidor con su propio lookup de neto/IVA, y backfill de 223 operaciones históricas. Eso es un change, no una task. **Queda registrado como `asiento-venta-formulario`** en las Open Questions, con la evidencia numérica ya levantada. Fabricar una `sales_orders` sintética por cada venta del formulario sólo para alimentar el consumidor se consideró y se descartó: contamina el agregado del POS y rompe el conteo de 120 que hoy es una invariante verificable.

### D8 — El formulario de venta muestra saldo, no lo calcula

El bloque `credit` del formulario reutiliza `useCustomerAccount` (`frontend/hooks/data/use-customer-account.ts`), el mismo hook que ya usan `/ventas/pos` y `/clientes/[id]/cuenta`. Saldo actual y proyectado (`saldo + total`) se renderizan con el patrón visual ya establecido en el POS por `pos-catalogo-pagos`, para que el usuario no encuentre dos lenguajes distintos para el mismo concepto.

### D9 — Firmas: `DROP` + `CREATE` y `REVOKE` explícito

`rpc_create_sale_operation`, `rpc_create_sale_operation_v2` y `rpc_create_purchase_operation` cambian de firma (parámetro nuevo) → `DROP FUNCTION IF EXISTS` con la lista de tipos **exacta capturada de prod** y luego `CREATE`, para evitar `42725` (ambiguous function). `_c29_confirm_order_core` y `_journal_post_from_event` conservan firma → `CREATE OR REPLACE`.

En **cada** función tocada, después del `CREATE`:

```sql
REVOKE ALL ON FUNCTION public.<fn>(<args>) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.<fn>(<args>) FROM anon;
GRANT EXECUTE ON FUNCTION public.<fn>(<args>) TO authenticated;
```

El `REVOKE ... FROM anon` explícito **no es redundante**: el proyecto tiene `ALTER DEFAULT PRIVILEGES` otorgando `EXECUTE` a `anon` sobre toda función nueva, y `REVOKE FROM PUBLIC` solo no lo neutraliza. Es el mismo gotcha que apareció en #420, #421 y #423 — tres veces documentado, y las tres se descubrió en CI, no localmente.

## Risks / Trade-offs

- **[El gate de integridad va RED al extraer el bloque del POS]** → Es esperado y es la señal de que el gate funciona. Se reescribe a verificación transitiva (D3) **en el mismo commit** que la migración, y se corre RED-antes/GREEN-después como evidencia explícita en tasks.
- **[La extracción del bloque `credit` repite el patrón que causó la regresión de julio]** → Mitigación en tres capas: el bloque se traslada desde la **definición viva capturada con `pg_get_functiondef`** (no desde el repo — el error de julio fue exactamente reescribir desde una base vieja del repo); el gate transitivo queda verde; y un test de comportamiento postea un cargo real por ambos caminos y compara el resultado.
- **[El opt-in de caja se convierte en un vector para inflar el arqueo]** → Las tres condiciones son de servidor (D4), la sesión debe ser de la sucursal efectiva, y `cash_movements` conserva `reference_id` → la venta es auditable hasta el renglón. El opt-in es más trazable que el estado actual, donde el efectivo del formulario simplemente no existe para la caja.
- **[D6 bloquea ediciones que hoy funcionan]** → Sólo alcanza operaciones **con cargo o movimiento posteado**. En prod hoy hay **0 `customer_account_movements`** y los 63 `cash_movements` pertenecen todos al POS, que ya no se edita por esta vía: **el impacto retroactivo es cero**. Aplica únicamente a operaciones nuevas creadas después de este change, cuando el usuario ya sabe que optó.
- **[`wallet` → `1110` puede no ser lo que el PO quiere]** → Es una decisión contable con dueño; se declara como Open Question con recomendación fundada y default explícito, reversible con un one-liner.
- **[La migración `20261001000001` colisiona si otro trabajo mergea antes]** → Se re-verifica `MAX(version)` en prod inmediatamente antes de abrir el PR (regla del proyecto; el valor de hoy, `20260930000001`, ya se confirmó).
- **[Auto-apply de Supabase GitHub]** → La migración es idempotente extremo a extremo (`IF NOT EXISTS`, `DROP ... IF EXISTS`, `CREATE OR REPLACE`) y re-ejecutable sin efectos.

## Migration Plan

1. Capturar `pg_get_functiondef` de las 5 funciones a tocar y archivarlo en el change (línea base anti-regresión).
2. Correr el gate transitivo nuevo contra prod → **debe fallar** (evidencia RED real).
3. Migración `20261001000001_pagos_cableados_restantes.sql` en un solo archivo: helper → confirm-core → RPCs de venta → RPC de compra → consumidor → `REVOKE`/`GRANT`.
4. Backend y frontend en el mismo PR (el parámetro nuevo es opcional, así que no hay ventana de incompatibilidad).
5. Merge → CI aplica la migración (pipeline automático del proyecto).
6. Verificación post-merge en prod, sólo SELECT: una venta a crédito produce fila en `customer_account_movements` (hoy 0), una compra produce `PurchaseCreated` con el kind real (hoy siempre `'credit'`).

**Rollback**: la migración inversa restaura las definiciones desde la línea base del paso 1. No hay cambio de schema destructivo — sólo cuerpos de función y una columna de parámetro opcional; ningún dato se pierde.

## Open Questions

- **OQ-1 — `wallet` a `1110 Banco`**: recomendación fundada; requiere confirmación del PO (decisión contable, no técnica). Default aplicado: `1110`.
- **OQ-2 — D6 bloquea la operación entera** (no sólo monto/método) cuando hay cargo o movimiento de caja posteado. Impacto retroactivo cero. Confirmación del PO.
- **OQ-3 — `asiento-venta-formulario`**: 223 operaciones de venta sin asiento contable. Change propio; ¿se prioriza antes o después de `compras-proveedor-cuenta-corriente`?
- **OQ-4 — `compras-proveedor-cuenta-corriente`**: ABM de proveedores + selector en el formulario de compra + cargo en `supplier_accounts`. Hoy hay 0 proveedores y la página `/proveedores/[id]/cuenta` no es alcanzable desde ninguna navegación.
- **OQ-5 — `other` sigue ruteando a `1100 Caja`** por herencia de `bank-payment-routing` C2. Con el catálogo ya operativo, `other` es un cajón de sastre que quizá merezca una cuenta puente propia. Fuera de alcance; se anota.
