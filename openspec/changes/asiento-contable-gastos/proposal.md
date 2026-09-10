## Why

El gasto es **el único documento operativo que mueve dinero y no deja rastro en el libro diario**. La venta (por formulario y por POS), la compra, el cobro de cuenta corriente y el pago a proveedor postean su asiento de partida doble por el outbox desde `journal-entry-outbox`, `asiento-venta-formulario`, `delete-guard-ledgers` y `cobranzas-reverso`. El gasto no: `_journal_post_from_event` no tiene rama de gasto, `public.events` no recibe ningún evento de gasto, y la spec `journal-entry` nombra hoy `ExpenseRegistered` en la lista explícita de tipos **fuera de alcance**.

La consecuencia no es cosmética. Un gasto en efectivo descuenta de la caja (`cash_movements`) y uno por transferencia descuenta del banco (`bank_movements`) desde `gastos-forma-pago`, pero **el resultado del período que sale del libro diario ignora esos egresos**: el diario acumula ventas (4100) y compras (5100) contra sus contrapartidas de caja y banco, y la plata que salió por gastos aparece en los subledgers de dinero sin ninguna cuenta de resultado que la explique. El libro diario y los libros de dinero divergen por construcción, y `5300 Gastos` figura desde `journal-entry-outbox` en el plan de cuentas del sistema con la anotación literal **"(reservado)"** — la cuenta existe y nunca se usó.

`gastos-forma-pago` (D10) difirió esto a V2.6 de forma deliberada y dejó puesto exactamente lo que faltaba: la forma de pago del gasto, que es el dato del que depende elegir la contrapartida. Ese dato ya está en producción desde 2026-08-30. El PO aprobó cerrar el candidato en el programa "cero candidatos" (2026-09-07).

## What Changes

- **Tres eventos nuevos de gasto al outbox**, emitidos con `INSERT` plano en la misma transacción que la mutación (sin manejador de excepciones, como exige la spec para los productores contables): `ExpenseCreated` en `rpc_create_expense`, `ExpenseAdjusted` en `rpc_update_expense` y `ExpenseDeleted` en `rpc_delete_expense`. El importador (`rpc_import_expenses`) **no se toca**: delega fila por fila en `rpc_create_expense` y hereda el productor sin una segunda definición.
- **Rama contable de gasto** en `_journal_post_from_event`: débito `5300 Gastos` por el total, con el `cost_center_id` del gasto en la línea (mismo trato analítico que `5100` en la compra); crédito por la contrapartida derivada del `kind` de la forma de pago mediante un helper `_journal_expense_credit_account(kind)` nuevo, **espejo exacto** del `_journal_sale_debit_account(kind)` ya vivo, menos el caso `credit` que el gasto rechaza en la puerta.
- **Contra-asiento por edición y por borrado**, moldeados byte a byte sobre `SaleOperationAdjusted` y `PurchaseDeleted`. Esto preserva la cláusula normativa vigente *"un gasto sin movimientos asociados SHALL seguir siendo plenamente editable"*: el asiento posteado **no** congela el documento, la edición produce el par contra-asiento/asiento nuevo. Es el mismo criterio que el PO ya firmó para la venta el 2026-08-20.
- **El conjunto canónico del consumidor contable pasa de 11 a 14 tipos**, en los dos filtros que la spec obliga a mantener idénticos (`_journal_post_from_event` y el Consumer 3 de `rpc_process_outbox_dispatch`).
- **El gate del invariante canónico pasa a correr en CI.** Hoy vive en `supabase/tests/test_cobranzas_reverso.sql`, un archivo que **nunca se cableó a `KPI_Validation.yml`** (candidato heredado, verificado en este propose): el invariante que la spec declara *"verificado por un gate automático"* no lo verifica nadie. Sin esto, extender 11→14 dejaría el gate igual de inerte que ahora.
- **Superficie frontend** (regla PO 2026-08-02): el estado contable del gasto se vuelve visible en `/gastos` (escritorio y móvil) y el libro diario deja de ser un endpoint sin puerta de entrada — `GET /journal-entries` existe desde `journal-entry-outbox` con **cero consumidores en el frontend**, exactamente el anti-patrón que `CLAUDE.md` cita como origen de la regla.
- **Sin backfill de los gastos históricos** en esta versión (ver OQ-3 del design, con las mediciones de producción que la decisión requiere).

**No hay BREAKING de API ni de firma**: las tres RPC de gasto y el helper contable se reescriben con `CREATE OR REPLACE` conservando su firma y sus ACLs. Sí hay un **cambio de dominio declarado**: un gasto pasa a producir asientos, y por lo tanto un gasto borrado o editado deja rastro contable donde antes no dejaba ninguno.

## Capabilities

### New Capabilities
- `expense-journal-entry`: el asiento contable del gasto — cuándo se postea, qué cuentas debita y acredita según la forma de pago, cómo se fecha, y cómo se corrige por edición y por borrado.

### Modified Capabilities
- `journal-entry`: se retira `ExpenseRegistered` de la enumeración de tipos fuera de alcance y se incorporan las tres ramas de gasto al helper de posteo; la enumeración canónica de once tipos pasa a catorce; el camino de lectura de asientos suma filtros por período, documento y estado sin dar lugar a un endpoint paralelo; y la cláusula de preservación de ramas existentes se generaliza para cubrir también la incorporación de las ramas de gasto.
- `transactional-outbox`: el conjunto canónico del Consumer 3 pasa a catorce tipos; se declaran los tres productores de gasto y se exige que el gate del invariante corra en integración continua.
- `expense-operation`: el gasto declara su rastro contable como parte de su contrato de operación atómica, y su edición pasa a ajustar el asiento en lugar de dejarlo obsoleto.

## Impact

**Base de datos** — una migración idempotente que reescribe `rpc_create_expense`, `rpc_update_expense`, `rpc_delete_expense`, `_journal_post_from_event` y `rpc_process_outbox_dispatch` (todas `CREATE OR REPLACE`, todas partiendo del cuerpo **vivo** hasheado en el design), y crea `_journal_expense_credit_account`. Sin cambios de esquema: `public.events.event_type` no tiene `CHECK`, y `journal_entries`/`journal_lines` ya soportan todo lo que el gasto necesita.

**Backend** — `ExpenseOut` suma los derivados del rastro contable, calculados en SQL en `expense_repository.py` con el mismo patrón que `is_payment_locked`. `GET /journal-entries` suma filtros de fecha, tipo de documento y estado para que la pantalla del libro diario sea usable.

**Frontend** — `/gastos` (escritorio y móvil) y una pantalla de libro diario en el grupo Reportes del `app-sidebar`.

**Gates** — un gate SQL nuevo para las tres ramas de gasto, el cableado a `KPI_Validation.yml` del archivo que hoy queda fuera, y el gate de integridad de función sobre los cuerpos vivos reescritos.

**Riesgo** — governance MEDIA con un tramo ALTO: se escriben registros contables sobre datos reales de usuarios por un camino asíncrono. El relay corre cada minuto en lotes de 100; un fallo de posteo deja el evento `pending` para reintento sin abortar el lote, que es el modo de degradación que las once ramas vivas ya usan.
