## Context

El Tablero (`frontend/app/(dashboard)/dashboard/page.tsx`, client component) hoy muestra KPIs de **hoy** vía `get_dashboard_financials` y secciones de IA/actividad. Lee RPCs de Supabase directo (el backend FastAPI está a medio migrar y no se usa para esto). Las filas `sales/expenses/purchases` guardan `date` a **medianoche UTC** (date-granular), con `total` = línea (`amount*quantity`) y `amount` = precio unitario; el scoping correcto es `account_id IN (SELECT current_account_ids())` (RLS account-based, C-05). Ya existe `frontend/lib/date-range.ts` con `utcMonthRange`/`utcPrevMonthRange` (UTC desde la fecha de calendario local — evita el bug de desfase horario ya corregido). **No existe** el concepto de "canal de venta" en el modelo de datos.

## Goals / Non-Goals

**Goals:**
- Bloque de 5 tarjetas KPI **mensuales** en el tope del Tablero, arriba de "Consejos IA", sin tocar lo existente.
- Valores reales del backend para el período activo + comparación contra el mes anterior (badge de variación con color por polaridad).
- Selector de período en el Tablero (mes en curso por defecto) que afecta el bloque.
- Responsive: 2 col mobile (5ta full width) / 3 col tablet / 5 col web; sin truncamiento ni scroll horizontal en mobile.
- Habilitar "Margen por Canal" agregando el campo `canal` a ventas (con gate de governance).

**Non-Goals:**
- No migrar estos cálculos al backend FastAPI (DEC: se quedan como RPCs Supabase, consistente con el Tablero actual).
- No tocar ni reordenar las secciones existentes del Tablero.
- No agregar "meta" configurable por KPI (el Word la menciona para Ticket; se difiere — sin tabla de metas hoy).
- No backfill histórico de `canal` (las ventas previas quedan como "Sin canal").

## Decisions

### D1 — Cálculo en RPCs Supabase `SECURITY DEFINER`, no en el frontend ni FastAPI
Un RPC agregador `rpc_dashboard_kpi_summary` devuelve los 5 KPIs del período **actual y anterior** en una sola llamada (menos round-trips, números consistentes). Scope `account_id IN (SELECT current_account_ids())`, `SUM(COALESCE(total, amount))`, gate `auth.uid()` — mismo patrón que el `get_dashboard_financials` recién corregido. *Alternativa descartada*: calcular en el cliente trayendo filas crudas (filtra mal con RLS, pesado, duplica lógica).

### D2 — Fórmulas de los 5 KPIs (período = [p_from, p_to], comparación = mes anterior)
- **Ganancia Neta** = `SUM(sales.total) − (SUM(expenses.amount) + SUM(purchases.total))`. Polaridad: subir = **positivo**.
- **Ticket Promedio** = `SUM(sales.total) / COUNT(DISTINCT sales.operation_id)` (valor promedio por transacción/operación, no por línea). Polaridad: subir = positivo.
- **Costo por Venta** = `SUM(products.cost * sales.quantity) / NULLIF(COUNT(DISTINCT sales.operation_id), 0)` — **COGS** (costo de mercadería vendida) promedio por venta cerrada. Polaridad: subir = **negativo**. *(Decisión del usuario 2026-06-08: COGS, no costo operativo. Depende de que `products.cost` esté cargado; productos sin costo cuentan como 0 en el COGS.)*
- **Stock sin Rotación** = productos del account **sin ventas** en el período: `valor = SUM(products.stock * products.cost)`, `count = COUNT(*)` de esos productos (excluye `untracked`/`variant_only`). Polaridad: subir = negativo.
- **Margen por Canal** = por cada `canal`: `(ingreso_canal − COGS_canal) / NULLIF(ingreso_canal,0)` donde `COGS_canal = SUM(products.cost * sales.quantity)`. Devuelve top canales como `jsonb` (ej. `[{canal:'instagram', margin_pct:34}, {canal:'mercadolibre', margin_pct:18}]`) + el canal líder. **Bloqueado** hasta tener `canal` (ver D4).

### D3 — Variación y color del badge (cliente, función pura testeable)
`deltaPct = (curr − prev) / NULLIF(prev, 0) * 100`. `kpiBadgeTone(deltaPct, polarity)`:
- `prev` nulo/0 → sin baseline → **amarillo** (`#FBBF24`, "—" o "nuevo").
- `|deltaPct| < 5%` → amarillo (sin variación significativa).
- Si la dirección es favorable según `polarity` → **verde** (`#34D399`); si desfavorable → **rojo** (`#F87171`).
- `polarity`: `up_good` (Ganancia, Margen, Ticket) | `up_bad` (Costo por Venta, Stock sin Rotación).

### D4 — `canal` en ventas + **GATE de governance HIGH**
- Columna `sales.canal text NULL` + índice `(account_id, canal)`. Valores sugeridos (no enum duro): `instagram`, `mercadolibre`, `whatsapp`, `local`, `otro`; NULL se agrupa como "Sin canal".
- Captura: `select` de canal en el form de creación de venta; se pasa por `rpc_create_sale_operation` (nuevo parámetro `p_canal text` — canal por operación, no por ítem).
- **La migración del schema de ventas (dato financiero) es HIGH → se escribe y aplica SOLO con aprobación humana explícita.** Hasta entonces la tarjeta "Margen por Canal" muestra `—`.

### D5 — Entrega en 2 fases (de-risk + valor temprano)
- **Fase A (MEDIUM, sin gate)**: RPC agregador con 4 KPIs (Ganancia, Ticket, Costo/Venta, Stock sin Rotación) + selector de período + `KpiSummaryBlock` UI; "Margen por Canal" como `—`. Shippable de inmediato.
- **Fase B (HIGH, con gate)**: migración `canal` + captura en form + RPC margen por canal + cablear la 5ta tarjeta.

### D6 — Selector de período vía URL searchParam (consistente con `BranchFilter`)
`BranchFilter` ya usa `?branch=`. El selector usa `?period=YYYY-MM` (default: mes en curso). El bloque deriva `utcMonthRange(periodDate)` y `utcPrevMonthRange(periodDate)`. Convive con `?branch=` (ambos se pasan al RPC). Opciones iniciales: "Mes en curso", "Mes anterior" (extensible a histórico/custom luego).

### D7 — Componente y datos
- `frontend/components/dashboard/KpiSummaryBlock.tsx` (bloque) + tarjeta del nuevo diseño (`KpiSummaryCard`), separada de la `kpi-card.tsx` actual (otro layout/estilo). Grilla: `grid-cols-2` mobile con la 5ta `col-span-2`; `md:grid-cols-3`; `xl:grid-cols-5`.
- Hook `useDashboardKpiSummary(periodDate, branchId)` con TanStack Query sobre el RPC (`staleTime` ~5 min, como los hooks existentes).
- Tokens: usar tokens del tema dark donde matchean (`bg-card`, `text-muted-foreground`); los colores del **badge** usan los hex exactos del spec. Respetar contraste/accesibilidad (web-design-guidelines).

## Risks / Trade-offs

- **`canal` sin histórico** → "Margen por Canal" solo refleja ventas nuevas. → Mitigación: agrupar NULL como "Sin canal"; comunicar en la tarjeta que arranca al activar el tracking.
- **Definición de "Costo por Venta" ambigua** (D2) → se eligió una computable; → si el usuario espera COGS puro, se ajusta el RPC sin tocar la UI.
- **Performance de "Stock sin Rotación"** (productos sin ventas en el período) → usar `NOT EXISTS` sobre `sales(account_id, product_id, date)`; agregar índice si hace falta.
- **Migración HIGH sobre dato financiero** → gate de aprobación + `CREATE OR REPLACE`/`ADD COLUMN IF NOT EXISTS` idempotente; rollback = drop de columna sin pérdida (nullable).
- **Doble fuente de KPIs** (este bloque mensual vs. la fila "hoy") → se mantienen separados a propósito (distinta pregunta); no se toca la fila de hoy.

## Migration Plan

1. **Fase A**: migración con `rpc_dashboard_kpi_summary` (solo lectura) → `supabase db push`. Frontend: selector + bloque + hook, Margen = `—`. PR + verificación (vitest + chequeo SQL en prod read-only).
2. **Fase B** (tras aprobación HIGH): migración `ALTER TABLE sales ADD COLUMN canal` + índice + `rpc_create_sale_operation` con `p_canal` + `rpc_dashboard_channel_margin`. Form de venta con select de canal. `supabase db push` + deploy.
3. **Rollback**: Fase A — `DROP FUNCTION rpc_dashboard_kpi_summary`. Fase B — `ALTER TABLE sales DROP COLUMN canal` (nullable, sin pérdida) + revertir RPC de creación.

## Open Questions

- ~~¿"Costo por Venta" operativo o COGS?~~ **RESUELTO (2026-06-08): COGS** = `SUM(products.cost * quantity) / nº ventas` (ver D2).
- Canales: ¿lista fija sugerida o texto libre? (D4 propone sugeridos + "Otro".)
- ¿El selector de período necesita más rango que "mes en curso / mes anterior" en v1? (D6 arranca con esos dos.)
