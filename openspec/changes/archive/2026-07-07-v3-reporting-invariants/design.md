# Design: v3-reporting-invariants

## Context

El Modelo V3 (`modelo-dominio-aliadata-v3.md` §8) define cinco invariantes de reporting (RN-D1..D5). Este change es **audit-then-fix**: la auditoría se ejecutó durante el propose (read-only, 2026-07-06) sobre los cuerpos de migración Y las definiciones vivas en prod (`pg_get_functiondef` vía MCP en `gxdhpxvdjjkmxhdkkwyb` — sin drift detectado entre migraciones y prod para los RPCs auditados). Las tasks corrigen **solo** las violaciones probadas.

### Inventario de RPCs de reporting auditados

Definiciones vigentes: `rpc_dashboard_kpi_summary` y `rpc_dashboard_channel_margin` (última versión en `20260806000001_v3_snapshot_pattern.sql` §5.2), `rpc_product_profitability` (ídem §5.1), `rpc_period_comparison` (`20260606120000`), `rpc_branch_report` (C-07, verificado en vivo), `rpc_admin_*` (5 RPCs de métricas de plataforma).

### Hechos de datos relevantes (prod, 2026-07-06)

| Hecho | Valor | Implicación |
|---|---|---|
| `SUM(sales.amount)` vs `SUM(COALESCE(total, amount))` | $7.905.976 vs $9.291.711 (revenue **subvaluado 17,53 %**) | El fix SUBE los números visibles ~+17,5 % agregado |
| Filas de venta con `total ≠ amount` (`quantity > 1`) | 45/279 | Margen de `/rentabilidad` falso en esas líneas |
| `sales`/`purchases` con hora ≠ 00:00 UTC | 43 / 27 | El borde `DATE` de comparativo/sucursal las excluye en el último día |
| Ventas legacy sin `operation_id` | 18 | `rpc_branch_report` no las cuenta como operación |
| NC (`customer_account_movements` tipo `credit_note`) / cta cte / `payments_received` | **0 / 0 / 0 filas** | Los fixes RN-D1/RN-D3 no mueven ningún número actual |
| `sales_orders.status='canceled'` | 0 filas (y sin RPC que transicione a ese estado — RN-A4) | CANCELED no contamina reportes hoy |
| Columna `mp_status` | no existe en ninguna tabla | Rama MP de RN-D3 sin fuente de datos → N/A |
| `sales` (tabla) | sin columna de estado; la "anulación" es DELETE físico con reposición de stock (PR #201) | RN-D1 para `sales` se cumple por construcción |

## Tabla de hallazgos — RPC × RN-D

Veredictos: ✅ cumple · ❌ violación (con defecto exacto) · ◽ N/A.

| RPC | RN-D1 cancelados/NC | RN-D2 snapshots | RN-D3 percibido/devengado | RN-D4 NUMERIC | RN-D5 fecha local |
|---|---|---|---|---|---|
| `rpc_dashboard_kpi_summary` | ❌ **latente**: no resta NC (las NC viven en cta cte/journal, jamás tocan `sales`; revenue queda bruto). Cancelados: ✅ por construcción | ✅ COGS = `COALESCE(si.unit_cost_snapshot, pr.cost, 0)` (gate q de `20260806000001`) | ❌ **gap**: solo muestra facturado; no existe métrica de cobrado | ✅ | ✅ params `timestamptz` + convención `date-range.ts` (fix 2026-06-08) |
| `rpc_dashboard_channel_margin` | ❌ latente: ídem NC (afecta el margen % del canal solo cuando existan NC) | ✅ gate p | ◽ (métrica de margen, no de cobro) | ✅ | ✅ ídem dashboard |
| `rpc_product_profitability` | ✅ por construcción (lee `sales`; DELETE físico) | ✅ costo = `COALESCE(si.unit_cost_snapshot, pr2.cost) * s.quantity` (gates i/o) — **pero** revenue = `SUM(s.amount)` = precio unitario: margen inconsistente (costo × cantidad vs revenue unitario) → ❌ **defecto de fórmula** | ◽ | ✅ | ❌ `v_since_date := CURRENT_DATE − N` usa fecha UTC del servidor: de 21:00 a 00:00 hora AR la ventana corre un día |
| `rpc_period_comparison` | ❌ latente: no resta NC | ◽ (no calcula márgenes) | ◽ | ✅ | ❌ `s.date BETWEEN p_a_start AND p_a_end` con `DATE`→`timestamptz` castea el fin a medianoche UTC: excluye las 43/27 filas con hora real cuando caen el último día |
| — ídem, defectos extra | revenue = `SUM(s.amount)` (unitario, −14,9 %) → ❌ · `operations` = `COUNT(*)` filas, no operaciones (venta multi-línea cuenta N veces; inconsistente con dashboard) → ❌ | | | | |
| `rpc_branch_report` | ✅ por construcción | ◽ | ◽ | ✅ | ❌ mismo borde `DATE` a medianoche UTC |
| — ídem, defectos extra | revenue = `SUM(s.amount)` → ❌ · `COUNT(DISTINCT s.operation_id)` ignora NULL: 18 ventas legacy no cuentan (dashboard usa `COALESCE(operation_id, id)`) → ❌ · nota: recibe `p_account_id` como parámetro (chequea membership — seguro, pero desvía del patrón `current_account_ids()`; se difiere a `v3-api-standards`) | | | | |
| `rpc_admin_*` (5) | ◽ métricas de plataforma (`analytics_events`, `profiles`) — sin documentos financieros | ◽ | ◽ | ✅ | ◽ aceptado: métricas admin en UTC (audiencia = PO) |

**Ya cumplido por trabajo previo (NO rehacer)**: RN-D2 completo en los tres RPCs de margen (`v3-snapshot-pattern`, gates i/o/p/q); RN-D5 en el dashboard (`utcMonthRange`/`utcPrevMonthRange` del fix 2026-06-08); RN-D4 en todos (columnas y retornos NUMERIC); exclusión de CANCELED por construcción en todos los RPCs que leen `sales`.

## Goals / Non-Goals

**Goals:**
- Corregir las violaciones probadas de la tabla: revenue = total de línea; resta de NC; métricas percibido/devengado; bordes de período en fecha local; conteo de operaciones consistente.
- Formalizar RN-D1..D5 como spec transversal (`reporting-invariants`) para que todo read-model futuro nazca cumpliéndolas.
- Cero regresión de contrato: mismas firmas de entrada; los callers actuales (hooks frontend, Edge Functions IA) siguen funcionando sin cambios salvo el wiring mínimo del dashboard.

**Non-Goals:**
- NO tocar write paths (ventas, compras, NC, pagos) — governance BAJO-MEDIO se mantiene.
- NO cambiar los RPCs admin (plataforma, no financieros) ni `rpc_dashboard_channel_margin` más allá de la resta de NC si el PO la aprueba allí (D6: se difiere).
- NO crear pasarela de cobro MP a clientes finales (la rama `mp_status` de RN-D3 queda documentada N/A).
- NO backfill de datos (no hay datos que corregir: el defecto es de lectura, no de escritura).
- NO UI nueva más allá de la línea secundaria en la tarjeta Ganancia Neta.

## Decisions

### D1 — Revenue = `COALESCE(total, amount)` en los tres RPCs desviados (cambio de números visibles)
`sales.amount` es precio unitario; `total = amount × quantity` (escrito por todos los write paths desde C-05). La convención correcta ya existe en el dashboard. **Consecuencia visible**: `/rentabilidad` (revenue y margen por producto suben; margen deja de poder dar negativo falso), `/reportes/comparativo` y `/reportes/sucursal` (revenue sube ~+17,5 % agregado). *Justificación*: los números actuales están mal — entienden menos revenue del real; mantenerlos es mentirle al usuario. *Alternativa rechazada*: mantener `SUM(amount)` por continuidad — perpetúa un margen matemáticamente inconsistente (costo × cantidad vs revenue unitario). **Requiere visto del PO en el sign-off del proposal (es el mayor shift de números).**

### D2 — RN-D1: las NC restan vía `customer_account_movements`, no vía `sales`
Las NC nunca escriben `sales` (registran movimiento en cta cte + asiento reverso en journal). Restarlas en los RPCs = `revenue − Σ cam.amount WHERE movement_type='credit_note' AND created_at ∈ período`. Alcance: `rpc_dashboard_kpi_summary` (net_profit e invoiced/collected) y `rpc_period_comparison` (revenue por período). *Alternativa rechazada*: insertar filas negativas en `sales` al emitir NC — toca write path (fuera de governance) y rompe la inmutabilidad RN-100. **Hoy 0 NC en prod → cero shift al desplegar**; el invariante queda listo para cuando se usen.

### D3 — RN-D3: fórmulas exactas de percibido vs devengado
- `invoiced_revenue` (devengado) `= Σ COALESCE(s.total, s.amount)` del período **− Σ NC del período** (coherente con D2).
- `collected_revenue` (percibido) `= invoiced_revenue − Σ cargos a cta cte del período (cam.movement_type='charge') + Σ cobros del período (payments_received.created_at ∈ período)`.

Racional: en Aliadata la única venta no-cobrada es la que va a cuenta corriente; todo lo demás (POS cash/other, ventas manuales) se cobra al confirmar. Un cargo a cta cte difiere el cobro; un `payment_received` lo percibe (aunque sea de una venta de otro período — semántica de caja). La rama `mp_status = approved` del texto V3 queda **N/A documentada**: no existe columna `mp_status` en ninguna tabla; MercadoPago solo procesa billing de suscripciones de la plataforma, no cobros de los tenants. *Alternativa rechazada*: derivar percibido de `sales_orders.payment_method` — no cubre ventas manuales legacy y duplica la fuente de verdad que ya es cta cte. **Hoy cta cte sin movimientos → `collected == invoiced` en todas las cuentas: el rollout no muestra diferencia hasta que alguien use cta cte.**

### D4 — Extensión del RETURNS TABLE del dashboard via DROP+CREATE (única firma tocada)
`rpc_dashboard_kpi_summary` suma 4 columnas de salida (`invoiced_revenue`, `prev_invoiced_revenue`, `collected_revenue`, `prev_collected_revenue`). `CREATE OR REPLACE` no puede cambiar columnas OUT → `DROP FUNCTION IF EXISTS` + `CREATE` en la misma migración (transaccional, sin ventana). Los parámetros de entrada NO cambian; el cliente JS (supabase-js) ignora columnas extra → los callers existentes no se rompen ni siquiera entre deploy de DB y deploy de frontend. Los otros tres RPCs conservan firma y columnas exactas (`CREATE OR REPLACE` simple). *Alternativa rechazada*: RPC nuevo `rpc_dashboard_kpi_summary_v2` — fragmenta el contrato y deja el viejo mintiendo (sin resta de NC).

### D5 — RN-D5: fecha local vía constante de plataforma, no timezone por organización
Los bordes correctos son los del día calendario **local del tenant**. Hoy no existe `organizations.timezone` y el 100 % de los tenants está en Argentina (UTC-3, sin DST). Decisión KISS: función helper SQL `reporting_local_today()` → `(now() AT TIME ZONE 'America/Argentina/Mendoza')::date`, usada por `rpc_product_profitability` para anclar `v_since_date`; y borde superior de rangos `DATE` materializado como `p_end::timestamptz + interval '1 day'` con comparación `<` (semánticamente "hasta fin del día", robusto para las 43/27 filas con hora real). La spec transversal fija la regla; migrar a timezone por organización es un change futuro si aparece un tenant fuera de AR. *Alternativa rechazada*: agregar `organizations.timezone` ahora — schema nuevo sin caso de uso (YAGNI).

### D6 — Alcance de la resta de NC: dashboard + comparativo; canal se difiere
`rpc_dashboard_channel_margin` necesitaría atribuir la NC a un canal — las NC (jsonless, monto global por orden) no tienen canal. Restarlas del margen por canal exigiría prorrateo especulativo. Se difiere hasta que existan NC reales y el PO defina la atribución. Documentado como limitación en la spec.

### D7 — Conteo de operaciones unificado: `COUNT(DISTINCT COALESCE(operation_id, id))`
Se adopta la definición del dashboard en `rpc_period_comparison` (hoy `COUNT(*)`: una venta de 3 líneas cuenta 3) y `rpc_branch_report` (hoy `COUNT(DISTINCT operation_id)`: 18 ventas legacy con NULL no cuentan). **Consecuencia visible**: "operaciones" del comparativo baja para ventas multi-línea; sucursal suma las legacy. Para gastos y compras en el comparativo se mantiene `COUNT(*)` en gastos (no tienen operation_id) y pasa a `DISTINCT COALESCE(operation_id, id)` en compras (sí lo tienen). *Justificación*: "operación" debe significar lo mismo en toda la app; el dashboard ya fijó la definición.

### D8 — UI mínima (RN-D3 IN, con degradación)
La tarjeta **Ganancia Neta** del bloque KPI muestra una línea secundaria "Cobrado: $X" solo cuando `collected_revenue ≠ invoiced_revenue` (es decir, solo para cuentas que usan cta cte). Sin tarjeta nueva, sin cambio de grilla responsive, sin ruta nueva. *Alternativa rechazada*: sexta tarjeta KPI — rompe la spec de layout 5-columnas y agrega ruido a la mayoría (que no usa cta cte).

### D9 — Migración idempotente + gates auto-limpiantes (lecciones 07-04/07-06)
Timestamp `20260814000001` (> `20260813000001`). La migración es both-worlds-safe (la integración GitHub de Supabase la auto-aplica al merge ANTES del `db push` de Actions): `DROP FUNCTION IF EXISTS` + `CREATE`, sin DDL de tablas, re-ejecutable. Gates TDD patrón C2/C3: introspección corre siempre (verifica que cada cuerpo nuevo contenga los predicados clave); comportamiento solo en DB vacía (CI) con anchor sintético vía `handle_new_user` — el cleanup hijo→padre por email del anchor DEBE cubrir `branch_stock`/`cashboxes`/`branches` (desde `20260812000001` el signup siembra branch+caja) además de ventas/movimientos/NC de prueba; NOTICE-degrade en prod; `accounts=0` al final. Los gates de comportamiento cubren: revenue con `quantity>1`, resta de NC, collected vs invoiced con cargo+cobro de cta cte, borde de fin de día con fila a las 15:00 UTC, conteo de operaciones multi-línea.

## Risks / Trade-offs

- **[Shift de números visibles]** Usuarios de prod ven subir revenue/margen en 3 pantallas de un día para otro → Mitigación: D1 exige visto del PO; el PR/nota de release explicita "corrección de cálculo: el revenue ahora suma el total de línea"; los deltas % contra período anterior se recalculan con la misma fórmula en ambos períodos (comparación interna consistente, sin salto artificial en badges).
- **[Ventana DB→frontend]** Entre migración y deploy del frontend, el dashboard recibe 4 columnas extra → Mitigación: supabase-js las ignora; el hook viejo sigue funcionando (verificado por diseño del mapeo explícito campo a campo).
- **[`sales` legacy con `total` NULL]** El fallback `COALESCE(total, amount)` asume que en filas legacy `amount` ES el total de línea (convención documentada en `20260611000000`) → Mitigación: misma suposición que el dashboard usa hace un mes sin reclamos; gate de introspección lo documenta.
- **[Percibido con cobros de períodos anteriores]** Un `payment_received` de una venta vieja suma al percibido del mes del cobro (semántica de caja) → es la semántica correcta de "percibido" (RN-D3); documentado en spec para que nadie lo "arregle".
- **[Timezone hardcodeada]** Tenants fuera de AR verían bordes corridos → aceptado (D5): no existen hoy; la spec deja el punto de extensión definido.
- **[Prorrateo de NC por canal ausente]** El margen por canal seguirá bruto de NC (D6) → aceptado y documentado; 0 NC hoy.

## Migration Plan

1. Migración `20260814000001_v3_reporting_invariants.sql`: helper `reporting_local_today()` + `CREATE OR REPLACE` × 3 + `DROP+CREATE` dashboard + gates (introspección siempre; comportamiento solo CI con cleanup completo).
2. Frontend: mapeo de 4 campos en `use-dashboard-kpi-summary.ts` + línea condicional en la tarjeta Ganancia Neta + tests.
3. Deploy: merge a main → CI aplica migración y deploya Vercel (pipeline existente). Sin pasos manuales.
4. Rollback: restaurar cuerpos previos (dashboard: `20260806000001` §5.2b; profitability: ídem §5.1; comparison: `20260606120000`; branch_report: cuerpo C-07 vigente citado en la migración) — el DROP+CREATE inverso repone el RETURNS TABLE original; el frontend viejo es compatible con ambos.

## Open Questions

- **OQ1 (PO, bloquea apply)**: ✅ **APROBADO 2026-07-06** — visto al shift de números de D1/D7. Decisión de comunicación: es corrección de bug, no cambio de criterio → sin aviso in-app especial, alcanza la nota de release del PR.
- **OQ2 (PO, no bloquea)**: ✅ **APROBADO 2026-07-06** — la línea "Cobrado" (D8) alcanza. No se pide vista de cobranzas separada por ahora.
- **OQ3 (PO, no bloquea)**: sigue abierto — cuando existan NC reales, definir atribución por canal para levantar D6.
