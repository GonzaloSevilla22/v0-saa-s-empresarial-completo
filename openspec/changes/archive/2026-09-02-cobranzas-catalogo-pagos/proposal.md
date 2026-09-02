## Why

El cobro de una cuenta corriente y el pago a un proveedor son los **dos últimos documentos operativos** del sistema que no usan el catálogo `payment_methods`. Sus RPCs reciben `p_payment_method text` y lo validan contra una taxonomía cerrada `{cash, transfer, card, check}` escrita a mano en el cuerpo de la función — ajena al catálogo que la venta, la compra, el gasto y el POS ya consumen por `payment_method_id` con el `kind` derivado en el servidor.

Las consecuencias están medidas contra producción (2026-09-02), no supuestas:

- **El usuario ve dos vocabularios distintos para la misma pregunta.** En `/ventas`, `/compras` y `/gastos` elige entre las **7** formas de pago de su catálogo, con los nombres que él mismo puso ("Santander", "Mercado Pago", "Naranja X"). En el modal de cobro elige entre **4 opciones fijas en inglés-traducido** que ningún tenant configuró y que ninguna pantalla más muestra. Renombrar "Transferencia bancaria" a "Banco Nación" en Configuración no cambia nada en el modal de cobro.
- **`wallet` no se puede cobrar.** Los 38 tenants tienen una forma de pago de `kind = 'wallet'` sembrada y activa. Cobrar una cuenta corriente por Mercado Pago hoy obliga a mentir eligiendo "Transferencia", y el `bank_movement` queda con una etiqueta que no corresponde. `wallet` **ya es un kind bancario en todo el resto del sistema** (`isBankPaymentKind`, `_pay_register_operation_bank_movement`, y el consumidor contable que lo rutea a `1110 Banco`): la cobranza es el único lugar que lo desconoce.
- **La forma de pago del cobro no se puede reportar.** `rpc_payment_method_report` agrupa por `payment_method_id`. Los cobros, que guardan texto plano, quedan estructuralmente fuera del único reporte de formas de pago del producto (`/reportes/formas-pago`).
- **La convergencia ya ocurrió en todas las demás tablas.** `sales`, `purchases`, `expenses` y `sales_orders` tienen **sólo** `payment_method_id`: su columna de texto fue **dropeada** por `limpiezas-pagos-admin`. `payments_received` y `payments_made` son las **dos últimas** que conservan `payment_method text` — y lo conservan desde anteayer, con **0 de 7 filas** pobladas.

Quedó declarado como Non-Goal explícito de `caja-compras-cobranzas` (*"Unificarlas es el espejo de `pos-catalogo-pagos` y merece su propio change"*) y sobrevivió intacto a `cobranzas-reverso`. El molde está probado **tres veces** (venta, compra, gasto) y la ventana es inmejorable: la columna de texto que habría que migrar está vacía.

## What Changes

- **Las dos RPCs cambian `p_payment_method text` por `p_payment_method_id uuid`** y derivan el `kind` del catálogo con un `SELECT` bajo el `account_id` del tenant. El `kind` **nunca** se acepta como texto del cliente — es la cláusula normativa que `payment-method` ya exige para todos los demás caminos y que estas dos funciones son las últimas en incumplir.
- **La taxonomía aceptada pasa de 4 a 6 de los 7 kinds**: se suman `wallet` (bancario, como en todo el resto del sistema) y `other` (etiqueta pura, sin efecto en ningún libro). **`credit` se rechaza con `P0400`**: cancelar una deuda con deuda no es un hecho económico que el modelo admita.
- **BREAKING (firma)**: las dos RPCs pasan de **7 a 7 argumentos con el 5.º cambiado de `text` a `uuid`**. Se aplican con `DROP FUNCTION` + `CREATE` de la firma anterior — nunca `CREATE OR REPLACE`, que dejaría un overload vivo (gotcha `42725`).
- **BREAKING (schema)**: `payments_received.payment_method text` y `payments_made.payment_method text` se **reemplazan** por `payment_method_id uuid NULL REFERENCES payment_methods(id)`. Las columnas de texto se dropean: tienen **0 filas pobladas** en producción y las otras cuatro tablas del sistema ya convergieron a la columna FK.
- **Los dos modales migran al `PaymentMethodSelect` existente**, con un contexto nuevo `"collection"` que cubre cobro y pago. El `<Select>` de 4 opciones hardcodeadas y su constante `PAYMENT_METHODS` local desaparecen de ambos archivos.
- **El opt-in de caja deriva su condición 1 del catálogo**: `useCashOptin` ya recibe un `PaymentMethodKind`; hoy los modales le pasan el valor del `<Select>` local, que coincide por accidente de nomenclatura. Pasa a recibir el `kind` resuelto del método elegido — el mismo dato que el servidor valida.
- **El historial de cuenta corriente muestra el nombre real de la forma de pago** (el que el usuario configuró), resuelto por `JOIN` a `payment_methods`, en lugar del texto plano.
- **Sin backfill** de los 7 documentos históricos: su columna de texto ya está en `NULL` (0/7). No hay dato que migrar — el "sin backfill" acá no es una renuncia, es una constatación.
- **La anulación de un cobro no se toca.** Verificado contra el cuerpo vivo de `rpc_reverse_payment_received`/`_made`: despachan **por existencia del movimiento**, nunca leyendo la columna. La spec `payment-reversal` ya lo declara normativo (*"nunca por su signo ni por la forma de pago declarada"*). Las dos RPCs de reverso **no cambian de firma ni de cuerpo**.

## Capabilities

### New Capabilities

Ninguna. Este change **unifica** dos superficies contra un catálogo y unas capabilities que ya existen; crear una capability nueva para eso contradiría la regla de reutilización.

### Modified Capabilities

- `payment-method`: el requirement del vocabulario cerrado afirma hoy que *"el CHECK de las RPCs de cobro/pago (`{cash, transfer, card, check}`) sigue siendo un subconjunto propio, sin tocar"* — deja de ser cierto. Se suma además el requirement de imputación de la forma de pago en cobros y pagos de cuenta corriente, espejo de los tres que ya existen para venta, compra y gasto, y se extiende el requirement de superficies con el contexto nuevo del selector.
- `customer-account`: el requirement de `PaymentReceived` pasa a recibir `payment_method_id` y a derivar el `kind`; el requirement de la superficie de cobro pasa a ofrecer el catálogo; el read-model del historial expone el nombre configurado en vez del texto plano.
- `supplier-account`: espejo exacto para `PaymentMade` y la superficie de pago a proveedor.
- `cash-session`: la condición 1 del opt-in de caja del cobro y del pago se enuncia hoy como *"el método de pago informado es efectivo"*; pasa a ser *"el `kind` derivado del catálogo es `cash`"*, que es lo que el servidor va a evaluar.
- `payment-reversal`: el requirement del disparo por existencia nombra la forma de pago declarada como algo en lo que la anulación **no** se apoya. Se refuerza declarando que esa independencia se mantiene bajo la columna nueva, con un escenario que lo ejercita — es la garantía de que este change no puede romper el reverso.

## Impact

**Base de datos** — migración `20261020000001` (correlativa verificada contra `origin/main` y contra `supabase_migrations.schema_migrations` en prod: ambos en `20261019000001`, 268 filas):
- `DROP FUNCTION` + `CREATE` de `rpc_register_payment_received` y `rpc_register_payment_made`, partiendo del `pg_get_functiondef` **vivo hasheado**.
- `ALTER TABLE` sobre `payments_received` y `payments_made`: `+ payment_method_id uuid NULL REFERENCES payment_methods(id)`, `− payment_method text`.
- `REVOKE` de `PUBLIC`, `anon` **y** `authenticated` + `GRANT` selectivo, en la misma migración (un `DROP`+`CREATE` resetea las ACLs).
- **Sin** ERRCODEs nuevos, **sin** tipos de evento nuevos, **sin** helpers SQL nuevos, **sin** ramas nuevas en `_journal_post_from_event`.

**Backend** — `backend/schemas/customer_accounts.py` y `supplier_accounts.py` (`PaymentReceivedIn`/`PaymentMadeIn`: el campo y sus tres validadores; `AccountMovementOut.payment_method` pasa a resolverse por `JOIN`), `backend/services/` y `backend/repositories/` de ambas cuentas.

**Frontend** — `RegisterPaymentForm.tsx` y `RegisterPaymentMadeForm.tsx` (los dos modales), `PaymentMethodSelect.tsx` (contexto nuevo + texto de apoyo), `CustomerAccountHistory.tsx` y `SupplierAccountHistory.tsx` (nombre de la forma de pago), `hooks/data/use-customer-account.ts` y `use-supplier-account.ts`.

**Gates** — `test_cuenta_corriente_party_guard.sql` (L887/L901) resuelve las dos firmas por `::regprocedure` y **se rompe por tercera vez** si no se actualiza en el mismo PR; `test_party_payment_cash.sql` y `test_cobranzas_reverso.sql` llaman a las RPCs con `p_payment_method => 'cash'` y hay que migrarlos. Los tres se tratan como parte del change, no como daño colateral.

**Riesgo de dominio**: las dos RPCs mueven **dinero real** (caja, banco, cuenta corriente y asiento contable). Governance **MEDIA**: cambian la firma de dos funciones con dinero, pero siguiendo un molde aplicado y verificado tres veces, sin inventar semántica nueva.

**Sin impacto** en: el POS, el reverso de cobros/pagos (firma y cuerpo intactos), `rpc_dashboard_kpi_summary`, el outbox y el consumidor contable.
