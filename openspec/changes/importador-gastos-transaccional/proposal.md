## Why

El importador de gastos es **la única superficie de dinero del sistema que sigue emitiendo una llamada por fila sin ninguna transacción que abarque el lote**. Por esa limitación —y no por una decisión de producto— `gastos-forma-pago` le negó explícitamente la forma de pago (D13, 2026-08-30): *"con impacto en libros, importar 200 filas generaría 200 movimientos y, ante un fallo a mitad de camino, dejaría N gastos con movimiento y M sin"*.

La consecuencia se paga hoy en producción: **todo gasto importado nace sin forma de pago, sin sucursal y sin centro de costo**, o sea invisible para `/reportes/formas-pago`, para la conciliación bancaria y para el reporte por sucursal. Y la única salida que el propio importador ofrece es falsa por construcción: imputar la forma de pago después desde el listado es **sólo una etiqueta**, porque `rpc_update_expense` no postea movimientos (D11) y ni siquiera recibe `p_cash_session_id`/`p_bank_account_id`. El usuario que importa el mes de gastos desde su planilla no tiene ningún camino para que esos gastos lleguen a los libros salvo volver a cargarlos uno por uno desde el formulario.

El PO aprobó cerrarlo dentro del programa "cero candidatos" (2026-09-07, *"sí a todo"*). La pieza que faltaba —el lote transaccional— **ya existe como patrón probado en el repo**: `rpc_import_bank_statement` (C3, conciliación bancaria) es exactamente eso, una RPC `SECURITY DEFINER` que recibe las filas normalizadas en `jsonb`, valida el payload, consume `Idempotency-Key` contra `operation_idempotency` y deduplica por hash de archivo. Este change lo aplica al gasto.

## What Changes

- **Lote transaccional**: nace `rpc_import_expenses(...)` `SECURITY DEFINER` — la unidad de trabajo del importador pasa a ser **una sola transacción para todo el archivo** (DEC-24), con semántica **todo o nada** y **reporte de errores fila por fila** en la misma llamada.
- **Reutilización literal del alta, sin reescribirla**: la RPC de lote **invoca `rpc_create_expense` por fila**. No se copia una sola regla de negocio (kind derivado del catálogo, rechazo de `credit`, guard de cuenta bancaria `P0412`, sucursal efectiva, centro de costo, período conciliado `P0424`). `rpc_create_expense` **no se modifica**: sin `DROP FUNCTION`, sin riesgo de overload `42725`, sin re-emisión de ACLs.
- **La forma de pago entra al importador**: el template CSV gana la columna `Forma de pago`, resuelta **por nombre contra el catálogo `payment_methods` de la cuenta**, con un **default seleccionable en el diálogo** para las filas que la dejen vacía. Un nombre que no resuelve es **error de fila**, nunca un default silencioso.
- **Sucursal y centro de costo también**: dos columnas opcionales más, mismo resolutor por nombre y mismo default de diálogo. Cierra de paso el hueco que el importador arrastra desde siempre (hoy descarta ambas) y satisface RN-93 para las filas importadas.
- **Pata bancaria SÍ, pata de caja NO**: los gastos importados con `kind` bancario (`transfer`/`card`/`check`/`wallet`) **registran su movimiento en `bank_movements`** con fecha valor = fecha del gasto, vía el mismo helper compartido. El lote **NUNCA postea en caja**, con aviso explícito por fila: `cash_movements` es un libro append-only por sesión que se arquea y se firma, y postear un egreso retroactivo en la sesión abierta de hoy **inventa una diferencia de arqueo** (RN-95). La asimetría no es una preferencia: es la forma de los dos libros.
- **Cuenta bancaria destino**: selector a nivel diálogo que actúa como **respaldo**, no como override — el default por forma de pago (`payment_methods.bank_account_id`, ya poblado por `bank-default-destination` en las cuentas con un solo banco) conserva la precedencia. Sin ninguna de las dos y con bancos activos en la organización, la fila se rechaza con el motivo `P0412` que ya existe.
- **Idempotencia y dedupe de archivo**: el endpoint acepta `Idempotency-Key` por header (v3-api-standards §3). Nace la tabla `public.expense_imports` (espejo mínimo de `bank_statement_imports`) y la columna `expenses.import_id`: dan el `operation_id` que el `CHECK` de `operation_idempotency` exige, el dedupe de dominio por `(account_id, file_hash)` —que protege contra el modo de falla más probable, volver a subir el mismo archivo— y la trazabilidad de qué gastos vinieron de qué importación.
- **Tope de filas por lote**: 500, con **rechazo** por encima. No se trocea: trocear es justamente lo que rompe la atomicidad que este change viene a dar.
- **Superficie** (`/gastos` → "Importar CSV", ruta y menú ya existentes): el paso 2 del diálogo deja de ser una validación sólo de cliente y pasa a ser una **vista previa validada por el servidor** (misma RPC en modo simulación, que ejecuta todo y deshace), con selectores de forma de pago / sucursal / centro de costo / cuenta bancaria por defecto, resumen de avisos y errores por fila **antes** de escribir, y un paso 3 que informa el resultado del lote. Desktop + mobile, claro + oscuro.
- **Nuevo endpoint** `POST /expenses/import` en las tres capas (router → service → repository), con envelope de error RFC 7807 y `errors[]` por fila.
- **BREAKING de spec (interno, sancionado)**: se **retira** el requirement *"El importador de gastos no imputa forma de pago"* de `expense-operation`. Su motivo declarado —la ausencia de transacción de lote— deja de existir con este change.
- Los tres tests que fijan hoy el comportamiento viejo (`expense-import-dialog-no-payment-method.test.tsx`, `-invalidation.test.tsx`, `-parse-and-validate.test.ts`) se reescriben; cada aserción que cambie queda justificada por escrito.

## Capabilities

### New Capabilities
- `expense-import`: importación de gastos por archivo como **operación de lote atómica**: contrato de la fila normalizada, todo-o-nada con reporte de errores por fila, resolución de forma de pago / sucursal / centro de costo por nombre contra los catálogos de la cuenta, política de libros del lote (banco sí, caja no), tope de filas, idempotencia por clave y dedupe por archivo, y superficie del diálogo de importación.

### Modified Capabilities
- `expense-operation`: se retira el requirement que prohíbe imputar forma de pago en el importador (y su cláusula de ayuda derivada), porque el motivo que lo sostenía —la ausencia de transacción de lote— lo cierra este change. El resto de la capability (opt-in de caja, pata bancaria, inmutabilidad, tri-estado) **no cambia**; lo que este change agrega vive en `expense-import`.

## Impact

**Base de datos** (migración nueva, la que corresponda tras `20261039000001`)
- `public.expense_imports` (tabla nueva) + RLS de `SELECT` por cuenta + `GRANT` sin escritura para `authenticated` (escritura sólo por la RPC `SECURITY DEFINER`), espejo de `bank_statement_imports`.
- `public.expenses.import_id uuid NULL` + FK a `expense_imports` + índice.
- `operation_idempotency`: el `CHECK` de `operation_kind` suma `'expense_import'`.
- `public.rpc_import_expenses(...)` (función nueva) + ACLs explícitas en el mismo archivo.
- **No se toca** `rpc_create_expense`, `rpc_update_expense`, `rpc_delete_expense`, `c28_register_cash_movement` ni `_pay_register_operation_bank_movement`.

**Backend**
- `backend/routers/expenses.py` (endpoint nuevo), `backend/services/expenses.py`, `backend/repositories/expense_repository.py`, `backend/schemas/expenses.py` (schemas del lote), `backend/core/errors.py` (los ERRCODEs nuevos del lote).

**Frontend**
- `frontend/components/gastos/expense-import-dialog.tsx` (reescritura de los pasos 2 y 3 y del template), `frontend/hooks/data/use-expenses-query.ts` (`useBulkAddExpense` se retira o se reconvierte en la mutación de lote), `frontend/lib/types.ts`, y el reuso de `PaymentMethodSelect` / `BankAccountDestinationSelect` / `BranchSelect` / `CostCenterSelect` y de `hashFileSHA256` (`lib/bank-statement-parser.ts`).

**CI / verificación**
- Gate SQL nuevo cableado en `.github/workflows/KPI_Validation.yml`.
- `openspec validate --specs --strict`: 98 → **99** capabilities.

**Riesgo de dominio**: gobernanza **MEDIA con tramo ALTO** — el lote escribe dinero real en `bank_movements` desde una RPC `SECURITY DEFINER`.
