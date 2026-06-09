## 1. Fase A — RPC agregador de KPIs (4 KPIs, sin gate)

- [x] 1.1 Escribir migración `rpc_dashboard_kpi_summary(p_from timestamptz, p_to timestamptz, p_prev_from timestamptz, p_prev_to timestamptz, p_branch_id uuid DEFAULT NULL)` — `SECURITY DEFINER`, `search_path=public`, gate `auth.uid()`, scope `account_id IN (SELECT current_account_ids())`, `SUM(COALESCE(total, amount))`. Devuelve por período actual y anterior: net_profit, avg_ticket, cost_per_sale, stagnant_stock_value, stagnant_stock_count. (Margen por canal = NULL en Fase A.)
- [x] 1.2 Verificar el RPC con SQL read-only contra prod (`gxdhpxvdjjkmxhdkkwyb`): comparar net_profit vs `get_dashboard_financials` para un mes conocido; sanity-check de ticket/costo/stock.
- [x] 1.3 `supabase db push` (Fase A es solo lectura — sin gate de aprobación).

## 2. Fase A — Lógica de fechas y badge (TDD, frontend puro)

- [x] 2.1 (RED) Tests de `kpiBadgeTone(deltaPct, polarity)` en `frontend/__tests__/`: favorable→verde, desfavorable→rojo, polaridad invertida (`up_bad`), `|Δ|<umbral`→amarillo, baseline nulo/0→amarillo.
- [x] 2.2 (GREEN) Implementar `frontend/lib/kpi-format.ts` con `kpiBadgeTone` + `formatKpiDelta` + tipos de polaridad. Reusar `utcMonthRange`/`utcPrevMonthRange` de `lib/date-range.ts`.
- [x] 2.3 (REFACTOR) Limpiar y confirmar verde.

## 3. Fase A — Hook de datos

- [x] 3.1 `frontend/hooks/data/use-dashboard-kpi-summary.ts`: TanStack Query sobre `rpc_dashboard_kpi_summary`, deriva los rangos con `utcMonthRange(periodDate)` + `utcPrevMonthRange(periodDate)`, pasa `p_branch_id`, `staleTime ~5min`, `enabled: !!user`.
- [x] 3.2 Test del hook (mock de supabase.rpc) siguiendo el patrón de `__tests__/hooks/*`.

## 4. Fase A — Componentes UI

- [x] 4.1 `frontend/components/dashboard/KpiSummaryCard.tsx`: ícono color arriba-izq, valor grande negrita, etiqueta muted, badge de variación arriba-der (fondo semi-transparente, color por `tone`), estado `—` sin dato. Tokens del tema + hex del spec para el badge.
- [x] 4.2 `frontend/components/dashboard/KpiSummaryBlock.tsx`: grilla `grid-cols-2` (5ta `col-span-2`) → `md:grid-cols-3` → `xl:grid-cols-5`; mapea los 5 KPIs (Margen por Canal = `—` en Fase A) con su polaridad e ícono.
- [x] 4.3 Tests del bloque (vitest + Testing Library): render de 5 tarjetas, clases responsive, `—` cuando no hay datos, color del badge según polaridad.

## 5. Fase A — Selector de período + integración en el Tablero

- [x] 5.1 `frontend/components/dashboard/PeriodFilter.tsx`: opciones "Mes en curso" / "Mes anterior", refleja la selección en `?period=YYYY-MM` (patrón de `BranchFilter` con `?branch=`), default mes en curso.
- [x] 5.2 Integrar en `frontend/app/(dashboard)/dashboard/page.tsx`: leer `?period` + `?branch`, renderizar `<KpiSummaryBlock>` ARRIBA de `<AiSummaryCard>`, sin tocar las secciones existentes.
- [x] 5.3 Verificación local (preview): bloque arriba de Consejos IA, responsive 2/3/5 col, badges con color correcto, `—` sin datos.

## 6. Fase A — Cierre

- [x] 6.1 `vitest run` completo verde + commit en rama `feat/dashboard-kpi-block` + PR a main.

## 7. Fase B — Canal de venta (GOVERNANCE HIGH — requiere aprobación humana explícita antes de escribir/aplicar la migración)

- [ ] 7.1 **[GATE]** Confirmar aprobación del usuario para tocar el modelo de datos financiero (`sales.canal`).
- [ ] 7.2 Migración: `ALTER TABLE public.sales ADD COLUMN IF NOT EXISTS canal text;` + índice `(account_id, canal)`. Idempotente. (NO aplicar sin 7.1.)
- [ ] 7.3 Actualizar `rpc_create_sale_operation` para aceptar `p_canal text` y sellarlo en cada `INSERT INTO sales` (canal por operación). Mantener idempotencia y firma compatible.
- [ ] 7.4 Captura de canal en el form de creación de venta (select con valores sugeridos + "Otro"); pasar `p_canal` al RPC. Test del form.
- [ ] 7.5 `rpc_dashboard_channel_margin(p_from, p_to, p_branch_id)` (o extender el agregador) devolviendo margen por canal (`jsonb`) + canal líder; scope account, COGS = `SUM(products.cost * sales.quantity)`.
- [ ] 7.6 Cablear la tarjeta "Margen por Canal" al dato real (reemplaza el `—`); test del render con varios canales.
- [ ] 7.7 `supabase db push` + deploy + verificación; PR a main.

## 8. Documentación

- [ ] 8.1 Marcar el avance y, al archivar, sincronizar specs (`/opsx:archive`). Actualizar CHANGES.md si corresponde.
