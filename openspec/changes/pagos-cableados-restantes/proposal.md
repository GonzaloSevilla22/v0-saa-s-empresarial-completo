## Why

La saga de pagos (#419 catálogo → #421 POS unificado → #423 edición con acarreo) dejó el catálogo `payment_methods` **imputado pero no cableado**: hoy la forma de pago se guarda como etiqueta en `sales`/`purchases` y no mueve nada. Los datos vivos de producción (capturados 2026-08-20, `MAX(version) = 20260930000001`) muestran el costo real de esa desconexión:

| Evidencia en prod | Valor | Lectura |
|---|---|---|
| `customer_accounts` / `customer_account_movements` | **0 / 0 filas** | El bloque `credit` restaurado por #421 sigue **sin ejercitarse**: las 120 `sales_orders` son 63 `cash` + 57 `other`, la última del 2026-08-15 (anterior al merge). La cuenta corriente de cliente existe en el schema y en la UI, y nunca recibió un cargo. |
| Operaciones de venta totales vs. POS | **343 vs. 120** | **223 operaciones de venta nacieron del formulario** — el camino mayoritario. |
| `events` por tipo | 120 `SaleConfirmed`, 38 `PurchaseCreated` | `SaleConfirmed` = exactamente las 120 del POS. **El formulario de venta no emite ningún evento**: `rpc_create_sale_operation_v2` (la ruta viva, flag `sale_items_rpc_v2` default `true`) no tiene un solo `INSERT INTO public.events`. |
| `journal_entries` | **158** = 120 + 38 | Confirmado por aritmética: **las 223 ventas del formulario no tienen asiento contable ninguno**. |
| `payload->>'payment_method'` en `PurchaseCreated` | literal `'credit'` **hardcodeado** | Las 38 compras postearon a `2100 Proveedores` sin importar cómo se pagaron — aunque `rpc_create_purchase_operation` ya **recibe** `p_payment_method_id`. Es un error de imputación contable en vivo. |
| `suppliers` / `purchases.supplier_id` | **0 filas / 0 de 427 no-nulos** | No hay proveedor a quien cargarle nada: el formulario de compra **no tiene selector de proveedor**. |

El PO ordenó (2026-08-20) cerrar las 4 Open Questions que `pos-catalogo-pagos` dejó explícitamente fuera de alcance (OQ-B, OQ-C, OQ-D, OQ-E). Este change las consume conectando el catálogo a los tres sistemas que ya existen y están esperando —caja (C-28), cuentas corrientes (C-30) y partida doble (V2.5)— **sin construir ninguno de ellos de nuevo**.

## What Changes

### OQ-D — Venta a cuenta corriente desde el formulario (el corazón del change)

- Un **único helper SQL compartido** `_pay_register_party_charge(...)` concentra el cargo en cuenta corriente y despacha por tipo de parte (`customer` / `supplier`) sobre los helpers C-30 ya existentes (`c30_get_or_create_*_account` + `c30_register_*_account_movement`) y emite el evento `CustomerAccountCharged` / `SupplierAccountCharged`.
- `_c29_confirm_order_core` (POS) **deja de tener el bloque inline** y pasa a llamar al helper — misma semántica, una sola definición. El bloque fiscal (C-27) y el de caja siguen intactos.
- `rpc_create_sale_operation_v2` gana el guard `credit_requires_client` y postea el cargo por el mismo helper.
- Formulario de venta: elegir una forma de pago `kind='credit'` vuelve **obligatorio** el cliente y muestra saldo actual y proyectado vía el hook `useCustomerAccount` existente.

### OQ-C — Opt-in de caja en el formulario de venta

- **BREAKING (regla de negocio)**: se **enmienda** la regla de `cash-session` "sólo el camino del mostrador alimenta el arqueo". El formulario podrá optar-in explícitamente, pero el arqueo queda protegido por tres condiciones **verificadas en el servidor**, no en la UI: `kind='cash'` **AND** sesión de caja abierta en la sucursal efectiva **AND** fecha de la venta = hoy en `America/Argentina/Mendoza`.
- `rpc_create_sale_operation` / `_v2` reciben `p_cash_session_id` (trailing) y reutilizan `c28_register_cash_movement` — el mismo helper intra-transacción del POS.
- Formulario: checkbox "Registrar en caja" que aparece **sólo** cuando las tres condiciones se cumplen, con el motivo explícito cuando no.

### OQ-E — Lado proveedor (alcance recortado por evidencia)

- **Entra**: `rpc_create_purchase_operation` deja de hardcodear `'payment_method', 'credit'` y emite el **kind real** derivado de `p_payment_method_id`. Corrige la imputación contable de todas las compras futuras.
- **Entra**: el helper compartido queda listo para `supplier` y se ejercita por tests con el parámetro de proveedor.
- **NO entra — change aparte `compras-proveedor-cuenta-corriente`**: el cargo real en `supplier_accounts` desde el formulario de compra es **inalcanzable hoy** (0 proveedores, sin selector, sin ABM). Construir esa superficie es un change propio, no una task de éste.

### OQ-B — Asiento contable discriminado por forma de pago

- **Hallazgo que reduce el trabajo**: el consumidor `_journal_post_from_event` **ya discrimina por kind** desde `bank-payment-routing` C2 (`credit`→`1300`, `transfer|card|check`→`1110`, `cash|other|NULL`→`1100`). No hay que construirlo.
- **Entra**: `wallet` se incorpora al predicado bancario (`1110`), hoy cae en `1100 Caja` por omisión — el único de los 7 `kind` sin ruteo deliberado.
- **Entra**: el productor de compras pasa a mandar el kind real (arriba), que es lo que le faltaba al consumidor para hacer su trabajo.
- **NO entra — change aparte `asiento-venta-formulario`**: que la venta del formulario emita `SaleConfirmed`. La rama `SaleConfirmed` del consumidor es **de forma `sales_orders`** (`source_doc_type='SalesOrder'`, `source_doc_ref = sales_order_id`, y el neto/IVA sale de `JOIN sales_orders → fiscal_documents`). Una venta del formulario no tiene `sales_orders`: emitir el evento tal cual produciría un asiento con referencia colgada y neto/IVA `NULL`, violando el invariante Σdébito = Σcrédito. Cerrarlo pide un evento de forma operación + rama nueva en el consumidor + backfill de 223 operaciones. **Gap documentado, no tapado.**

## Capabilities

### New Capabilities

- `party-account-charge`: el helper único de cargo en cuenta corriente compartido por venta y compra — despacho por tipo de parte, idempotencia, evento emitido y la regla de que ningún camino puede duplicar la lógica C-30.

### Modified Capabilities

- `cash-session`: enmienda de la regla "sólo el camino del mostrador alimenta el arqueo" → el formulario puede optar-in explícito bajo las tres condiciones verificadas en servidor (kind cash + sesión abierta + fecha de hoy en ART).
- `customer-account`: el cargo por venta a crédito deja de ser exclusivo del POS y pasa a ser propiedad de todo camino de alta de venta; cliente obligatorio con `kind='credit'`.
- `journal-entry`: `wallet` se rutea a `1110 Banco`; `PurchaseCreated` transporta el `payment_method` real en vez del literal `credit`.
- `payment-method`: el `kind` deja de ser una etiqueta de reporte y pasa a tener **efectos** declarados (caja, cuenta corriente, contrapartida contable).
- `operation-edit-context`: regla de inmutabilidad para operaciones que ya postearon cargo de cuenta corriente o movimiento de caja (ver design D6).

## Impact

- **DB (migración `20261001000001`, idempotente)**: helper nuevo `_pay_register_party_charge`; `DROP`+`CREATE` de `rpc_create_sale_operation`, `rpc_create_sale_operation_v2`, `rpc_create_purchase_operation` (cambia la firma → riesgo 42725) y `CREATE OR REPLACE` de `_c29_confirm_order_core` y `_journal_post_from_event` (firma estable). `REVOKE EXECUTE ... FROM anon` explícito en cada una (gotcha `ALTER DEFAULT PRIVILEGES`, documentado 3 veces).
- **Gate de CI `supabase/tests/test_confirm_core_integrity.sql`**: hoy exige por substring que el cuerpo de `_c29_confirm_order_core` contenga `c30_get_or_create_customer_account` y `c30_register_customer_account_movement`. Al extraer el bloque al helper el gate iría RED — se **extiende a verificación transitiva** (confirm-core llama al helper **y** el helper contiene los C-30), preservando la protección anti-regresión de julio en vez de debilitarla.
- **Backend FastAPI**: `backend/schemas/sales.py` (+`cash_session_id`), `backend/services/sales.py`, `backend/services/purchases.py`, routers correspondientes.
- **Frontend**: `frontend/components/forms/sale-form.tsx` (checkbox de caja + cliente obligatorio en credit + saldo), `frontend/components/forms/purchase-form.tsx`. Desktop + mobile, tema claro + oscuro.
- **Sin tocar**: el bloque fiscal C-27 de `_c29_confirm_order_core` (gate OQ-G de `pos-catalogo-pagos`), `rpc_quick_sale`, `rpc_confirm_sales_order`, y las RPCs de edición salvo por el guard de D6.
- **Governance MEDIUM**: toca dinero, pero íntegramente sobre helpers ya en producción; no crea aritmética financiera nueva.
