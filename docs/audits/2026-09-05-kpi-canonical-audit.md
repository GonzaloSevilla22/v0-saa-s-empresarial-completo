# Auditoría canónica de KPIs — 2026-09-05

## Resumen ejecutivo

**Resultado sobre `origin/main`: NO CONFORME antes de las correcciones.** La base de datos contiene read-models canónicos claros para los principales KPIs, pero cinco consumidores activos alteraban su semántica o su unidad al presentar los datos:

1. `ai-resumen` volvía a sumar ventas locales y omitía notas de crédito en “Ventas totales”.
2. El resumen IA secundario del Tablero recalculaba stock bajo desde el catálogo agregado y no respetaba la sucursal seleccionada.
3. Copilot y `ai-insights` inferían productos críticos desde stock total agregado y un mínimo local por defecto, ocultando faltantes por sucursal y cambiando el significado de `min_stock = 0`.
4. El gráfico admin de retención mezclaba cohortes maduras con cohortes todavía censuradas.
5. El detalle admin contaba filas como operaciones en ventas/compras, incluía productos/clientes borrados y presentaba conteos como importes monetarios.

**Resultado de la rama propuesta: CONFORME para los consumidores inspeccionados, con reservas operativas.** Las cinco divergencias activas quedaron corregidas en `codex/kpi-canonicalization` y se eliminó una implementación dormida que conservaba fórmulas viejas. Se agregaron pruebas de regresión, un gate SQL y contratos OpenSpec actualizados. La migración correctiva no se aplicó a ninguna base.

La paridad entre las migraciones de Git y los objetos realmente desplegados **no fue verificada**: esta ejecución no recibió una conexión de base de datos de QA ni autorización para consultar producción. Por lo tanto, “conforme” significa conforme al estado completo del código versionado, no una certificación del runtime productivo.

## Identificación y alcance

| Campo | Valor |
|---|---|
| Repositorio | `GonzaloSevilla22/v0-saa-s-empresarial-completo` |
| Rama base remota | `origin/main` |
| Commit auditado | `fde2140ba88185eab6aba9c979d0e638a8d27aad` |
| Fecha del commit base | `2026-09-05T10:33:28-03:00` |
| Rama de corrección | `codex/kpi-canonicalization` |
| Modalidad | Análisis estático + pruebas locales; sin consultas productivas |
| Superficies | Frontend Next.js, backend FastAPI, Edge Functions, migraciones SQL, tests, specs y KB |

El árbol de `main` contiene migraciones con nombres fechados hasta `20261029000001`. La auditoría tomó **todo el estado de la rama** como fuente solicitada y resolvió las definiciones por el último `CREATE OR REPLACE` versionado; no asumió que la fecha nominal de una migración prueba que ya esté desplegada.

## Qué significa “fuente canónica” en este proyecto

No existe —ni conviene crear— una única RPC universal para todos los indicadores. La arquitectura canónica es una familia pequeña de read-models SQL por dominio, junto con adaptadores compartidos que impiden que cada consumidor reconstruya la fórmula.

```text
tablas transaccionales + RLS/account scope
                  │
                  ▼
       read-model/RPC canónica por KPI
                  │
          ┌───────┼────────┐
          ▼       ▼        ▼
       Tablero  Reportes   IA/Admin
          │       │        │
          └──── sin re-agregar ni redefinir ────┘
```

### Catálogo de fuentes canónicas

| Familia | Fuente canónica versionada | Invariantes relevantes | Consumidores activos |
|---|---|---|---|
| Finanzas del Tablero | `get_dashboard_financials` | cuenta autenticada, sucursal opcional, facturado/cobrado separados | `/dashboard` |
| Resumen financiero comparable | `rpc_dashboard_kpi_summary` | ventas canceladas fuera, NC por fecha de emisión, línea `COALESCE(total, amount)`, operación distinta, período previo | hooks de reporting, Copilot, `ai-resumen`, `ai-simulador`, `ai-prediccion`, `ai-insights` |
| Stock crítico | `get_dashboard_critical_stock(p_branch_id)` | `branch_stock`, producto distinto, `min_stock > 0`, criticidad por sucursal, soft-delete y tipo de control | tarjeta del Tablero, resumen IA, Copilot, `ai-insights` |
| Rentabilidad por producto | `rpc_product_profitability` | ventas por línea, costo canónico y notas de crédito según contrato | pantalla/hook de rentabilidad, `ai-rentabilidad` |
| Reporte por sucursal | `rpc_branch_report` | scope de cuenta, período y sucursal; facturación y operaciones comparables | `/reportes/sucursal` |
| Estadísticas de ventas | `rpc_sales_evolution`, `rpc_product_ranking`, `rpc_sales_breakdown` (sobre el helper `reporting_sales_lines_in_window`) | agregación SQL única; service/repository no recalculan | FastAPI `statistics` (`get_sales_evolution` es el método del service, no la fuente), pantallas de estadísticas |
| KPIs admin | `rpc_admin_kpi_overview`, `rpc_admin_retention_30d`, `rpc_admin_module_stats`, `rpc_admin_business_kpis` | guard admin, usuarios distintos, cobertura, cohortes censuradas, unidad declarada | `/admin/analytics`, `/admin/metricas/*` y, bajo `isAdmin`, el panel `ModuleMetricsWrapper` montado en `/ventas`, `/compras`, `/gastos`, `/clientes`, `/productos` y `/stock` |
| Plan efectivo / MRR | `get_effective_plan` + motor de billing dentro de `rpc_admin_business_kpis` | cuenta paga, trial y exención separados; ARS explícito | panel estratégico admin |

## Matriz de invariantes

| Dimensión | Definición canónica encontrada | Estado tras la corrección |
|---|---|---|
| Tenancy | identidad derivada de `auth.uid()` y scope por `account_id`; filtros no aportan identidad | Conforme en las RPC inspeccionadas |
| Sucursal | filtro opcional explícito; sin filtro significa agregado consciente de sucursal | Conforme en Tablero y stock crítico |
| Zona horaria | día de negocio de Mendoza/Argentina; fin de rango exclusivo donde lo exige el contrato | Conforme en helpers y read-models inspeccionados |
| Venta válida | operaciones canceladas excluidas | Conforme en read-models financieros |
| Notas de crédito | restan por fecha de emisión; la atribución por sucursal sigue la regla versionada | Conforme en el resumen financiero y ahora en `ai-resumen` |
| Ingreso por línea | `COALESCE(total, amount)`; no sumar precio unitario como si fuera total | Conforme en helpers frontend/Deno |
| Cantidad de ventas/compras | operación distinta mediante `COUNT(DISTINCT COALESCE(operation_id,id))`, no cantidad de líneas | Conforme en KPI summary y en la migración correctiva del detalle admin |
| Facturado vs cobrado | métricas distintas; cobrado puede ser `NULL` con filtro de sucursal | Conforme; no se encontró mezcla activa |
| Stock crítico | `branch_stock.min_stock > 0 AND quantity <= min_stock`, producto distinto | Conforme en consumidores activos corregidos |
| Retención | operación entre día 30 y fin del horizonte común; sólo cohortes maduras son comparables | Conforme en cabecera y gráfico corregido |
| Unidad | dinero se muestra como dinero; personas/eventos/operaciones como conteos | Conforme tras corregir `ModuleAnalytics` |

## Hallazgos y resolución

### KPI-01 — `ai-resumen` alteraba ventas netas

- **Severidad:** alta.
- **Estado en `main`:** confirmado, activo.
- **Causa:** el Edge Function consultaba `rpc_dashboard_kpi_summary` sólo para ganancia, pero construía “Ventas totales” sumando filas locales. Esa suma no incorporaba notas de crédito.
- **Resolución:** usa `summary.invoicedRevenue`; `sumLineRevenue` queda únicamente como degradación explícita si falla el read-model.
- **Prueba:** regresión estática en `edge-reporting-canon.test.ts` y tests del adaptador Deno.

### KPI-02 — el resumen secundario del Tablero ignoraba sucursal y ledger

- **Severidad:** media.
- **Estado en `main`:** confirmado, activo.
- **Causa:** `AiSummaryCard` filtraba productos agregados con helpers locales. El selector de sucursal del Tablero no llegaba al componente.
- **Resolución:** recibe `branchId` y reutiliza `useCriticalStock(branchId)`, el mismo acceso a la RPC canónica de la tarjeta principal.
- **Prueba:** el test verifica que la sucursal activa llega al hook y que el valor presentado es el de la RPC.

### KPI-03 — Copilot y `ai-insights` reconstruían stock crítico

- **Severidad:** alta.
- **Estado en `main`:** confirmado, activo.
- **Causa:** ambos filtraban `v_products_with_stock.stock <= min_stock`, con fallback local `min_stock ?? 5`. El stock agregado puede parecer sano aunque una sucursal esté agotada; además, el contrato establece que cero significa “sin umbral”.
- **Resolución:** ambos consultan `get_dashboard_critical_stock(null)`. Como la RPC devuelve un conteo, la IA informa sólo ese conteo y deja de inventar nombres/días restantes desde otra población.
- **Prueba:** tests funcionales de snapshot, tests del adaptador Deno y gates estáticos contra la reintroducción del predicado local.

### KPI-04 — cohortes inmaduras incluidas en el gráfico admin

- **Severidad:** media.
- **Estado en `main`:** confirmado, activo.
- **Causa:** la cabecera seleccionaba una cohorte madura, pero el gráfico recibía el array completo, incluyendo `is_mature=false`.
- **Resolución:** `selectMatureCohorts` aplica el indicador declarado por la RPC; no replica aritmética de fechas.
- **Prueba:** caso maduro/no maduro en `adminAnalytics.test.ts`.

### KPI-05 — divergencias de población, operación y unidad en módulos admin

- **Severidad:** alta.
- **Estado en `main`:** confirmado, activo.
- **Causa:** `rpc_admin_module_stats` usaba `COUNT(*)` en tablas multilínea, incluía productos/clientes soft-deleted y `ModuleAnalytics` aplicaba `formatMoney` al resultado en ventas, compras y gastos. Una operación de dos líneas contaba dos veces y luego se mostraba como dinero.
- **Resolución:** la nueva migración usa `COUNT(DISTINCT COALESCE(operation_id,id))` en resumen y serie para ventas/compras y excluye maestros borrados; la UI conserva la unidad numérica, y stock se rotula como productos.
- **Prueba:** gate SQL sintético con una operación de dos líneas más una fila legacy; `ModuleAnalytics.test.tsx` verifica que 12 operaciones se presentan como `12`, sin `$` ni `ARS`.

### KPI-06 — implementación antigua sin consumidores

- **Severidad:** baja mientras permanecía dormida; alta si se reactivaba.
- **Estado en `main`:** deuda confirmada, no activa. **Resuelta en la rama.**
- **Evidencia:** `aiCopilotService.getBusinessDataContext` sólo es referenciada por su test. La ruta productiva usa `buildBusinessSnapshot`.
- **Riesgo:** esa función antigua suma `sales.amount`, calcula ganancia local y reconstruye stock crítico desde el catálogo agregado.
- **Resolución:** se eliminó el método muerto y su único test específico. `analyzePricingInQuestion`, historial y persistencia de conversaciones permanecen intactos; el Copilot productivo continúa usando `buildBusinessSnapshot`.

### KPI-07 — paridad de runtime no certificada

- **Severidad:** operativa media.
- **Estado:** no verificable en esta ejecución.
- **Causa:** los dos chequeos de referencias contra catálogo requieren `--dsn`; no se proporcionó una base local/QA y no se consultó producción.
- **Impacto:** no puede afirmarse que la firma, ACL y cuerpo desplegados sean idénticos al último estado de migraciones.
- **Acción recomendada:** ejecutar en QA, con credenciales read-only, los tests SQL de KPI y los scripts `check_frontend_table_refs.py` / `check_backend_table_refs.py`; comparar `pg_get_functiondef`, firmas y ACLs de las RPCs del catálogo anterior.

### KPI-08 — documentación histórica

- **Severidad:** baja.
- **Estado:** informativo.
- **Evidencia:** algunos documentos de KB conservan rutas o descripciones históricas, mientras OpenSpec y las migraciones más recientes reflejan la arquitectura vigente.
- **Decisión:** no se reescribió documentación general no normativa en este PR; el contrato actualizado queda en OpenSpec y este informe deja la trazabilidad.

## Cambios incluidos

- `ai-resumen`: facturación desde KPI summary, fallback compartido y explícito.
- `AiSummaryCard`: stock canónico y filtro de sucursal.
- Copilot y `ai-insights`: conteo canónico de stock crítico, sin detalle inferido.
- Analítica admin: gráfico sólo con cohortes maduras.
- Detalle admin: conteos y promedios conservan unidad de operaciones.
- Migración idempotente de `rpc_admin_module_stats` para contar operaciones multilínea una sola vez y excluir maestros borrados, con ACLs restauradas y gate de introspección.
- Tipos explícitos para el payload de métricas por módulo.
- Eliminación de `getBusinessDataContext`, duplicación dormida y sin llamadores productivos.
- Contratos OpenSpec ampliados para consumidores de stock y unidades admin.
- Pruebas de regresión focalizadas.

No se incluyeron cambios de RLS, deploy, merge ni acceso a datos reales. La migración propuesta no fue aplicada.

## Validación ejecutada

| Validación | Resultado |
|---|---|
| Suite focalizada KPI | **56/56 tests pasan**, 6 archivos |
| Suite frontend completa | **2114/2115 tests pasan**, 255/256 archivos |
| Fallo restante | `useCapabilityGate.test.ts`, caso WebGL/SSR no relacionado; también falla ejecutado en aislamiento y no toca archivos de este PR |
| TypeScript global | Los archivos modificados no reportan errores; el comando global sigue fallando por errores preexistentes en tests ajenos (`LedgerMovementsPanel`, page sizes, payment methods, `use-critical-stock` y un fixture de revenue) |
| Sincronización de instrucciones | `check_docs_sync.py`: OK |
| Integridad de diff | `git diff --check`: OK |
| Chequeos contra catálogo DB | No ejecutados: requieren `--dsn` |
| Gate SQL agregado | Fixture en `test_admin_kpis.sql` para venta/compra multilínea; no ejecutado localmente por falta de base Supabase configurada |
| Tests SQL / paridad desplegada | No ejecutados: no hubo base local/QA configurada ni consulta productiva autorizada |

## Gates sugeridos para la auditoría quincenal

1. Actualizar `origin/main` y crear un worktree aislado desde su SHA exacto.
2. Resolver por orden de migración la definición final de cada RPC del catálogo.
3. Buscar consumidores y clasificar cada uno como activo, test-only, dormido o histórico.
4. Fallar el gate si un consumidor activo:
   - suma `amount` para un KPI ya servido por `rpc_dashboard_kpi_summary`;
   - compara stock agregado contra `min_stock` para declarar criticidad;
   - calcula ratios/cohortes en el cliente cuando la RPC ya los declara;
   - transforma un conteo en importe o mezcla facturado con cobrado;
   - recibe identidad de tenant como dato confiable del cliente.
5. Ejecutar tests frontend, backend y SQL contra una base efímera o QA.
6. Comparar firmas, ACLs y `pg_get_functiondef` del runtime con Git.
7. Generar informe, rama y PR; nunca mergear ni desplegar automáticamente.

## Dictamen

- **Antes del PR:** no todos los módulos activos respetaban las definiciones canónicas.
- **Con este PR:** los consumidores activos inspeccionados quedan alineados con los read-models canónicos versionados.
- **Condición para cierre total:** validar en QA que las migraciones desplegadas, firmas y ACLs coinciden con Git.
- **Condición preventiva:** cualquier nuevo contexto de IA debe reutilizar `buildBusinessSnapshot` o los adaptadores canónicos, no reconstruir estas métricas.

## Addendum — revisión independiente 2026-09-06

- La migración `20261030000001` se aplicó dos veces en una base local reseteada (idempotente).
- Los 6 gates SQL pasaron: `test_admin_kpis`, `test_function_acl_gate`, `test_kpis`, `test_kpis_edge_cases`, `test_errcode_5char_gate`, `test_analytics_events`.
- ACL final idéntica a prod (`{postgres,authenticated,service_role}`), sin overload.
- El cuerpo pre-PR de `rpc_admin_module_stats` coincide con el vivo de prod (md5 `71c0abc7fc5396e3d1a48417a08eb95f`).
- Las 4 RPC no tocadas (`get_dashboard_critical_stock`, `get_dashboard_financials`, `rpc_dashboard_kpi_summary`, `rpc_admin_retention_30d`) coinciden con Git línea por línea salvo el encabezado normalizado y los `USING ERRCODE` inyectados por `20261003000001`.
- `supabase migration list --linked`: 278/278.
- Vitest: 39/39 en los tres archivos de test que toca el PR (`ai/buildBusinessSnapshot`, `reporting/critical-stock`, `reporting/edge-reporting-canon`) y 26/26 en los tres que toca esta revisión (`adminAnalytics`, `components/CohortRetentionChart`, `reporting/critical-stock`).
- `tsc`: sin errores nuevos.
- `deno check` de `ai-insights`/`ai-resumen`/`_shared`: 7 errores preexistentes en `main` y 8 en el PR; el nuevo es `CriticalStockClient` en `ai-insights/index.ts:125`, mismo patrón que los 7 (interfaces `Promise<>` vs. builders thenables de `supabase-js`; el deploy de Supabase no tipa). Candidato: declarar esas interfaces con `PromiseLike<>`.
- KPI-07 queda cerrado por esta verificación; la migración se aplicó en QA local, no en producción.
