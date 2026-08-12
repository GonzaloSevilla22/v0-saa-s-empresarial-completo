## Context

Dos read-models financieros conviven en el Tablero sobre los mismos datos:

| | RPC | Definición vigente | Ventana típica | Scope de cuenta |
|---|---|---|---|---|
| Diario | `get_dashboard_financials(p_date_from, p_date_to, p_branch_id)` | `20260610000001` | día de negocio (Mendoza, PR #379) | `account_id IN (SELECT current_account_ids())` |
| Mensual | `rpc_dashboard_kpi_summary(p_from, p_to, p_prev_from, p_prev_to, p_branch_id)` | `20260814000001` (verificado: ninguna migración posterior la redefine) | mes en curso + mes previo | `current_account_ids() LIMIT 1` |

Estado verificado del código (2026-08-11):

- **F3a** — en el mensual, `sales_agg`, `expenses_agg` y `purchases_agg` filtran `p_branch_id`; `nc_agg`, `charges_agg`, `payments_agg` y `stagnant_curr`/`stagnant_prev` **no**. Con sucursal seleccionada, `net_profit` e `invoiced_revenue` restan las NC de **toda la cuenta**, `collected_revenue` mezcla cargos y cobros de toda la cuenta con un devengado de una sucursal, y "Stock sin Rotación" valoriza el stock agregado de todas las sucursales.
- **F3b** — en el diario, las tres CTEs filtran sucursal y suman `COALESCE(total, amount)` correctamente, pero `net_profit = ingresos − (gastos + compras)`: no resta NC. Diario y mensual disienten sobre la misma ventana.

Esquema real relevante (leído de `20260720000001_c30_customer_supplier_accounts.sql`):

- `customer_account_movements` **no tiene `branch_id`**. Tiene `reference_id uuid` (sin FK) cuyo contenido depende del `movement_type`, según los escritores vigentes:
  - `'sale'` (cargo a cta cte) → `sales_orders.id` (`20260720000001:1264`)
  - `'credit_note'` → `sales_orders.id` de la orden original (`20260906000001:186`, versión reparada de `rpc_issue_credit_note`)
  - `'payment_received'` → `payments_received.id` (`20260907000001:602`) — **no** un documento de venta
  - `'adjustment'` → está en el CHECK pero **no tiene escritor** en todo el repo
- `sales_orders.branch_id` es **NOT NULL** (`20260702000001:172`, DEC-19) → el join `reference_id → sales_orders.branch_id` resuelve siempre para `'sale'` y `'credit_note'`.
- `payments_received` **no tiene `branch_id`**; tiene `reference_sale_id uuid` **nullable y sin FK**, que el único caller de frontend pasa como `referenceSaleId ?? null` (`frontend/hooks/data/use-customer-account.ts:156`) y los tests del backend pasan como `None`.

Datos de producción (consulta de solo lectura, 2026-08-11): `customer_account_movements = 0`, `payments_received = 0`, `customer_accounts = 0`, `sales_orders = 102`, `sales = 581` (de las cuales 145 con `branch_id`, es decir **75,0% legacy sin sucursal**), `branches = 36`, y **una sola cuenta con más de una sucursal**. El ledger de cuenta corriente nunca se usó: la decisión de OQ-1 no requiere backfill ni tiene efecto retroactivo, pero fija la semántica antes de que existan datos.

## Goals / Non-Goals

**Goals:**

- Que `p_branch_id` signifique lo mismo para **todos** los términos de un read-model, o que el término que no puede filtrarse lo declare explícitamente en vez de colarse sin filtrar.
- Que diario y mensual den el mismo número sobre la misma ventana, y que un gate de CI lo impida volver a romper.
- Que la regla de NC exista **una sola vez** en la DB, no copiada en dos RPCs (regla PO "reutilización antes que repetición").

**Non-Goals:**

- No se toca `rpc_dashboard_channel_margin` (excepción documentada: NC sin canal atribuible) ni el margen de catálogo.
- No se cambia ninguna firma de RPC, ni se agregan columnas de salida.
- No se corrige la asimetría de scope de cuenta entre ambos RPCs (`IN (SELECT current_account_ids())` vs `LIMIT 1`) — ver Riesgos.
- No se toca frontend: los contratos de columnas quedan idénticos.
- No se hace backfill de nada (no hay datos de cta cte que migrar).

## Decisions

### D1 — La nota de crédito hereda la sucursal de su documento origen (rama recomendada de OQ-1)

`nc_agg` pasa a `LEFT JOIN public.sales_orders so ON so.id = cam.reference_id` y filtra `(p_branch_id IS NULL OR so.branch_id = p_branch_id)`.

Fundamento: la NC es un contra-documento de una venta que **sí** está filtrada por sucursal. Dejarla global mientras el revenue es por sucursal no es "neutro": produce un sesgo **negativo y sistemático** — las NC de toda la cuenta se restan del revenue de una sola sucursal, y la suma de las sucursales deja de reconciliar con el total. El error de atribución posible (la NC se imputa a la sucursal de la venta original, no a la sucursal donde se gestionó la devolución) es de segundo orden frente a eso, y el join siempre resuelve porque `sales_orders.branch_id` es NOT NULL.

**Fail-closed sobre lo no atribuible**: una NC cuyo `reference_id` no resuelve a una `sales_order` (hoy: ninguna) no resta en **ninguna** sucursal cuando hay filtro, y sí resta en la vista sin filtro. Es exactamente cómo ya se comportan las 436 filas legacy de `sales` con `branch_id NULL`: cuando se selecciona una sucursal, quedan fuera. Alternativa descartada: restar la NC no atribuible en todas las sucursales (fail-open) — rompe la aditividad mucho peor, porque el mismo monto se restaría N veces.

### D2 — El par de caja (cargos + cobros) queda a nivel cuenta, y `collected_revenue` es NULL bajo filtro de sucursal

`charges_agg` y `payments_agg` **no** se filtran por sucursal. Cuando `p_branch_id IS NOT NULL`, `collected_revenue` y `prev_collected_revenue` se devuelven **NULL**.

Fundamento: `collected_revenue = devengado − cargos + cobros` es una identidad; sus tres términos tienen que vivir en el mismo universo. Los cargos **sí** son atribuibles (`reference_id → sales_orders.branch_id`), pero los cobros **no**: `payments_received.reference_sale_id` es nullable, opcional y en la práctica se manda `null`. Filtrar solo los cargos daría un percibido aritméticamente incoherente (devengado de una sucursal − cargos de una sucursal + cobros de toda la cuenta), y filtrar los cobros es imposible sin inventar una atribución. Entre devolver un número mezclado y declarar que la métrica no es computable por sucursal, se elige lo segundo: `NULL` es la respuesta honesta.

Costo cero en frontend: `KpiSummaryBlock.tsx:47-52` solo renderiza la línea "Cobrado" cuando `collectedRevenue != null && invoicedRevenue != null && son distintos`, y `frontend/lib/reporting/kpi-summary.ts:32-35` ya tipa ambos campos como `number | null`. Al filtrar sucursal la línea simplemente no aparece.

Alternativa descartada: filtrar cargos y dejar cobros globales (incoherencia aritmética). Alternativa descartada: agregar `branch_id` a `payments_received` y exigirlo en el alta — es un cambio de modelo y de UI de cobranza, fuera del alcance de un change de consistencia de KPIs; queda anotado como evolución futura si el PO elige la rama A completa.

### D3 — Stock sin rotación se calcula sobre `branch_stock`, no sobre el agregado

`stagnant_curr`/`stagnant_prev` dejan de leer `v_products_with_stock` (que agrega `SUM(bs.quantity)` de todas las sucursales) y pasan a `branch_stock bs JOIN products p`:

- valor = `SUM(bs.quantity * COALESCE(p.cost, 0))` sobre las filas de la sucursal filtrada (o de todas si `p_branch_id IS NULL`, que reproduce el total de hoy);
- conteo = `COUNT(DISTINCT bs.product_id)` — mismo criterio D2 de `20260913000001` (un producto sin rotación en dos sucursales cuenta una vez en la vista agregada);
- se agrega `p.deleted_at IS NULL` y se conserva la exclusión `stock_control_type NOT IN ('untracked','variant_only')` con `COALESCE(..., 'tracked')` (fail-open sobre valores desconocidos, espejo de `holdsOwnStock` en `frontend/lib/product-stock.ts`). Que hoy un producto soft-deleted con stock cuente como "sin rotación" es un defecto latente del CTE vigente; se corrige acá porque el CTE se reescribe igual y porque `20260913000001` ya fijó ese criterio para stock crítico.

Esto es el mismo movimiento que `kpi-critical-stock-dashboard` hizo con `get_dashboard_critical_stock`: la definición operativa de stock vive por sucursal.

### D4 — La evidencia de rotación es fail-**open** sobre ventas sin sucursal (asimetría deliberada con D1)

El `NOT EXISTS` que descarta productos con ventas en la ventana usa, cuando hay filtro de sucursal, `(sx.branch_id = p_branch_id OR sx.branch_id IS NULL)`.

Fundamento: D1 y D4 responden a preguntas distintas. D1 **suma dinero** y ahí un fail-open duplicaría montos entre sucursales. D4 evalúa **existencia de evidencia** de que el producto rota; una venta legacy sin sucursal es evidencia real de rotación y no se puede duplicar (es un `EXISTS`, no una suma). Con 75% de las filas de `sales` en `branch_id NULL`, un fail-closed marcaría como "sin rotación" a casi todo el catálogo apenas se selecciona una sucursal: un falso positivo masivo en una tarjeta que el usuario usa para decidir liquidaciones.

### D5 — La regla de NC vive en un helper SQL único, consumido por los dos RPCs

Se crea `public.reporting_credit_notes_in_window(p_account_id uuid, p_from timestamptz, p_to timestamptz, p_branch_id uuid) RETURNS numeric`, `LANGUAGE sql STABLE`, que encapsula: `movement_type = 'credit_note'`, imputación por `created_at`, `ABS(amount)` (el ledger guarda el delta firmado y la NC vive negativa) y la regla de sucursal de D1. Ambos RPCs la llaman.

Fundamento: es la causa raíz del bug. Hoy la fórmula de NC existe copiada en el mensual y ausente en el diario; si se la copia una segunda vez al diario, la próxima corrección volverá a divergir. Con el helper, la rama que elija OQ-1 se implementa en **un** lugar y el gate de CI verifica que los dos consumidores sigan de acuerdo. Es la aplicación literal de la regla "reutilización antes que repetición" y del requirement de enforcement de consumo de `reporting-invariants`.

ACLs del helper: `REVOKE ALL FROM PUBLIC` + `REVOKE EXECUTE FROM anon, authenticated`. Es interno — solo lo llaman funciones `SECURITY DEFINER`, que se ejecutan como su owner y conservan EXECUTE aunque el rol del caller sea `authenticated` (Paso 2 de `v31-tenancy-pool-rls` hace `SET LOCAL ROLE authenticated`, y eso no afecta al cuerpo de una definer). No es callable por REST porque nadie la expone. Esto evita que aparezca en el backlog de advisors 0028 y mantiene verde `test_function_acl_gate.sql`.

### D6 — El diario devuelve `total_income` **neto** de NC, no bruto

`get_dashboard_financials` pasa a `total_income = Σ COALESCE(total, amount) − NC(ventana, sucursal)` y `net_profit = total_income − (gastos + compras)`.

Fundamento: si solo `net_profit` restara las NC, la tarjeta diaria dejaría de reconciliar a ojo (ingresos − gastos − compras ≠ ganancia mostrada) y el gate de CI solo podría comparar una de las dos columnas. Con `total_income` neto, el diario replica exactamente la semántica de `invoiced_revenue` del mensual (devengado neto de NC, RN-D3) y el gate compara **dos** identidades en vez de una. Alternativa descartada: dejar `total_income` bruto y agregar una columna `credit_notes` — obliga a `DROP FUNCTION` + `CREATE` (cambio de `RETURNS TABLE`), toca el contrato y el frontend, y no aporta nada que el mensual no exponga ya.

Consecuencia visible: cuando existan NC, el número de "Ingresos" del día baja. Es la misma corrección que el PO ya firmó para el mensual en `v3-reporting-invariants` (donde el delta medido fue +17,53% de revenue subvaluado por otra causa); hoy el efecto es cero porque no hay NC en producción.

### D7 — `CREATE OR REPLACE` puro: ninguna firma cambia

Verificado: ni los parámetros de entrada ni las columnas de `RETURNS TABLE` de los dos RPCs cambian (D2 usa NULL en columnas que ya existen y ya son nullable del lado del frontend). Por lo tanto **no** aplica el gotcha 42725 de `20260913000001` (agregar un parámetro con `CREATE OR REPLACE` crea un segundo overload) y **no** hace falta `DROP FUNCTION`. `CREATE OR REPLACE` preserva ACLs; aun así la migración re-aplica `REVOKE`/`GRANT` explícitos de forma idempotente, por disciplina del backlog de advisors 0028. La migración es idempotente de punta a punta porque la integración GitHub de Supabase la auto-aplica al mergear y Actions puede re-aplicarla con `db push`.

### D8 — El gate de CI compara comportamiento, no firmas

Va en `supabase/tests/test_kpis_edge_cases.sql` (comportamiento con fixture), no en `test_kpis.sql` (firmas/ACLs). Reutiliza el patrón ya probado por `kpi-critical-stock-dashboard`: usuarios sintéticos en `auth.users` (el trigger `handle_new_user` provisiona cuenta y sucursal "Casa Central"), `set_config('request.jwt.claims', …, true)` para que `auth.uid()` resuelva, y `RAISE EXCEPTION` en cada assert fallido (el workflow ya corre `psql -v ON_ERROR_STOP=1`). Las NC del seed se insertan directo en `customer_account_movements` con `balance_after` explícito, como ya hace el gate embebido de `20260814000001:806`.

Asserts, sobre la misma ventana y el mismo seed:

1. sin sucursal: `financials.total_income = summary.invoiced_revenue` y `financials.net_profit = summary.net_profit`;
2. con `p_branch_id = branch_a`: las dos mismas igualdades;
3. una NC de la sucursal B no altera los números de la sucursal A (assert directo de D1, condicional a OQ-1);
4. el stock sin rotación de la sucursal A no incluye el stock de la sucursal B (assert de D3).

## Risks / Trade-offs

- **[La atribución de NC por documento origen puede no coincidir con la sucursal donde se gestionó la devolución]** → Se documenta en la spec como la regla elegida (la NC pertenece al período de su emisión pero a la sucursal de su venta). Si el negocio necesitara la otra semántica, el cambio es local al helper D5.
- **[`collected_revenue = NULL` bajo filtro de sucursal puede leerse como "sin datos" en vez de "no computable"]** → El frontend ya oculta la línea en vez de mostrar "$0", así que no aparece un cero falso; la spec deja explícito el motivo. Si el PO quiere que se vea la razón, es un texto en la tarjeta y no un cambio de contrato.
- **[Asimetría de scope de cuenta: el diario usa `IN (SELECT current_account_ids())` y el mensual `LIMIT 1`]** → Hoy son equivalentes (tenancy única desde C-19) y el gate seedea un usuario de una sola cuenta, que es el invariante real. Si `current_account_ids()` alguna vez devolviera más de una cuenta, los dos RPCs divergirían y **el gate lo haría fallar en CI**, que es el comportamiento deseado: se enteraría el equipo antes que el usuario. No se unifica acá para no cambiar el scope de un RPC vivo dentro de un change de consistencia.
- **[D6 cambia un número visible sin que el PO lo pida explícitamente]** → Queda anunciado en el proposal (§What Changes e §Impact) y su efecto hoy es cero (0 NC en producción). Si el PO lo objeta, revertirlo es quitar un término del `SELECT` final.
- **[El seed del gate escribe en `auth.users` y `customer_account_movements` de la base local de CI]** → Mismo patrón y mismo riesgo que los gates ya existentes; las filas usan prefijos `__gate_*` y viven solo en el contenedor efímero de `supabase start`.
- **[REVOKE del helper sobre `authenticated`]** → Riesgo conocido del backlog de advisors (revocar `authenticated` rompió cosas cuando la función la llamaba el backend con `SET LOCAL ROLE authenticated`). Acá no aplica: el helper no tiene callers fuera de funciones `SECURITY DEFINER`, cuyo cuerpo corre como owner. Se verifica en el mismo gate (las llamadas a ambos RPCs pasan por el helper y fallarían con 42501 si el REVOKE fuera incorrecto).

## Migration Plan

1. Migración única `supabase/migrations/20260914000001_kpi_branch_consistency.sql`, idempotente: helper `reporting_credit_notes_in_window` (`CREATE OR REPLACE`) + `CREATE OR REPLACE` de los dos RPCs + `REVOKE`/`GRANT` explícitos de los tres objetos.
2. Los asserts nuevos de `test_kpis_edge_cases.sql` se escriben **antes** (RED) y deben fallar contra las definiciones vigentes.
3. Merge a main → GitHub Actions hace `db push` (y la integración GitHub de Supabase puede auto-aplicar antes; por eso todo el archivo es idempotente).
4. **Rollback**: re-aplicar el cuerpo vigente de `20260814000001` §5 y de `20260610000001` con `CREATE OR REPLACE`. No hay cambio de datos ni de esquema — el rollback es puramente de definiciones de función.
5. La Parte A (D1/D2) se implementa en la misma migración **solo si OQ-1 ya está firmada**. Si no, se mergea la migración sin esos dos términos y la Parte A entra como `20260915000001` reemplazando únicamente el cuerpo del helper y `nc_agg`.

## Open Questions

### OQ-1 (BLOQUEA la Parte A) — ¿cómo se atribuye a una sucursal lo que no la tiene?

Ni `customer_account_movements` ni `payments_received` tienen `branch_id`. Las dos opciones que el plan de remediación pide evaluar, con su costo real medido contra el esquema:

**Opción A — atribuir por el documento origen.** Join `reference_id → sales_orders.branch_id`.
- Factible y barato para `credit_note` y `sale` (cargo): `sales_orders.branch_id` es NOT NULL, el join siempre resuelve, es un `LEFT JOIN` y un predicado más por CTE.
- **No factible para los cobros**: `payments_received.reference_sale_id` es nullable, opcional y hoy se manda `null`. Hacer A "completa" exige agregar `branch_id` a `payments_received` (o volver obligatorio `reference_sale_id`), tocar `rpc_register_payment_received`, el repositorio y el formulario de cobranza — un change de modelo, no de reporting.
- Riesgo semántico: la devolución gestionada en otra sucursal se imputa a la sucursal de la venta original.

**Opción B — declararlos "ajustes a nivel cuenta", excluidos del filtro de sucursal.** Precedente directo: `rpc_dashboard_channel_margin` no resta NC porque las NC no tienen canal (D6 de `v3-reporting-invariants`), y la excepción está documentada en la spec.
- Costo cero de implementación, pero deja vivo el sesgo de F3a en `net_profit`/`invoiced_revenue`: las NC de toda la cuenta seguirían restándose del revenue de una sola sucursal. Es el defecto que este change vino a corregir.

**Recomendación (híbrida, y es la que el resto del change asume): A para las notas de crédito, B para el par de caja.** Las NC restan del revenue, y el revenue **ya** está filtrado por sucursal: dejarlas globales no es una omisión neutra sino un sesgo negativo sistemático, y su atribución es exacta y gratuita (`sales_orders.branch_id` NOT NULL). Los cobros no son atribuibles sin cambiar el modelo, y como `percibido = devengado − cargos + cobros` es una identidad, se mantiene el par completo a nivel cuenta y se devuelve `collected_revenue = NULL` bajo filtro de sucursal en lugar de publicar una mezcla. Que el ledger de cta cte esté **vacío en producción** (0 movimientos, 0 cobros, medido 2026-08-11) hace que esta decisión no tenga costo de migración ni efecto retroactivo: se está eligiendo la semántica antes de que existan datos, que es el momento más barato para hacerlo.

Si el PO elige **B pura**, se cae D1 y con él las tasks del grupo 5; el resto del change (Parte B diario, stock por sucursal, gate CI) queda idéntico, y el helper D5 nace sin el parámetro de sucursal. Si el PO elige **A completa** (incluyendo cobros), este change entrega la mitad de NC y se abre un change aparte para `branch_id` en `payments_received`.

### OQ-2 (no bloqueante) — ¿se unifica el scope de cuenta de los dos RPCs?

`get_dashboard_financials` agrega sobre todas las cuentas de `current_account_ids()`; `rpc_dashboard_kpi_summary` toma la primera. Hoy da lo mismo (tenancy única) y el gate lo cubre. Unificarlo es un change propio con su propio análisis de tenancy; se deja anotado, no se toca acá.
