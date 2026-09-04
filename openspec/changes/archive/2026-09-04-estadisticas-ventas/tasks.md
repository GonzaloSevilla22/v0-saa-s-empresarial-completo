> **Governance por grupo**: LOW los grupos 5-9 y 12-14 (lectura pura, superficie nueva). **MEDIUM** los grupos 2 y 3 — el 2 reescribe el cuerpo de `rpc_product_profitability`, que alimenta una pantalla viva (`/rentabilidad`) y la Edge Function `ai-rentabilidad`; el 3 introduce el enforcement de plan en servidor. **Este change no escribe ninguna fila de negocio**: todas las RPCs nuevas son de sólo lectura.
>
> **TDD estricto**: cada grupo con código sigue el ciclo SAFETY NET → RED → GREEN → TRIANGULATE → REFACTOR. Los tests van antes que la implementación, y ninguna task de implementación se marca sin su test ejecutado en verde.

## 1. Checkpoints de verdad viva (antes de escribir una línea)

- [x] 1.1 Capturar el `pg_get_functiondef` **vivo en producción** de `rpc_product_profitability` a un archivo del scratchpad y hashearlo — la reescritura del grupo 2 parte de ahí, nunca del archivo de migración (precedente registrado: un cuerpo vivo divergía del último archivo por una reescritura in-place)
- [x] 1.2 Confirmar que existe **una sola** definición de `rpc_product_profitability` (`SELECT count(*) FROM pg_proc`) y anotar sus ACLs vivas, para restaurarlas idénticas
- [x] 1.3 Registrar el baseline del defecto de `last_sale_date`: conteo de productos cuyo día convertido de zona difiere del día real de negocio (medido 2026-09-03: **218/218**) — es la métrica de aceptación del fix
- [x] 1.4 SAFETY NET backend: correr `pytest` completo y anotar el conteo de tests en verde. Cualquier fallo previo se reporta como pre-existente, NO se arregla en este change
- [x] 1.5 SAFETY NET frontend: correr `vitest run` completo y anotar el conteo. Ídem con los fallos pre-existentes (`AdminSegurosPage.test.tsx` es flaky conocido bajo carga)
- [x] 1.6 Barrer los callers reales de `rpc_product_profitability` por `pg_get_functiondef` y por grep en `frontend/`, `backend/` y `supabase/functions/` — confirmar que son exactamente `/rentabilidad` y `ai-rentabilidad` antes de tocar su cuerpo
- [x] 1.7 Confirmar en producción que `sales.date` sigue sin hora en la ventana vigente (líneas de los últimos 90 días cuya hora no es medianoche) — si dejó de ser cierto, OQ-1 cambia de respuesta y hay que avisar antes de seguir

## 2. E1 — Base de datos: helper canónico, ranking, evolución (MEDIUM)

- [x] 2.1 RED: escribir el gate SQL `supabase/tests/test_estadisticas_ventas.sql` con los casos que aún no pasan — revenue de línea con la fórmula canónica, borde del día final incluido completo, día de negocio sin corrimiento de zona, y operación multi-línea contando 1
- [x] 2.2 Crear el helper `reporting_sales_lines_in_window(p_account_id, p_start, p_end, p_branch_id, p_canal)` que resuelve en un solo lugar: revenue de línea, bordes RN-D5, filtro de cuenta y filtros opcionales aplicados uniformemente
- [x] 2.3 Crear `rpc_product_ranking(p_start, p_end, p_order_by, p_group_variants, p_branch_id, p_canal, p_limit, p_offset)` sobre el helper: agrupa por el padre cuando la agrupación está activa, expone la cantidad de variantes, excluye las líneas sin producto y devuelve su importe como agregado aparte
- [x] 2.4 Añadir a `rpc_product_ranking` el margen con la cascada de costo canónica (snapshot de línea, con fallback al costo de catálogo) más la **proporción de cobertura de costo** del grupo; margen nulo cuando ninguna línea tiene costo (D11)
- [x] 2.5 Crear `rpc_sales_evolution(p_start, p_end, p_bucket, p_branch_id, p_canal)` con buckets día/semana/mes sobre la fecha de negocio casteada directamente (semana ISO, lunes) y la fila del período anterior de igual longitud
- [x] 2.6 Hacer que `rpc_sales_evolution` reste notas de crédito vía `reporting_credit_notes_in_window` — el helper compartido existente, sin reimplementar la regla (D7)
- [x] 2.7 Implementar el clamp de plan (D8) en las RPCs con ventana: plan efectivo resuelto contra la base, historial del plan, recorte del inicio del rango y devolución de la ventana aplicada. Fail-closed al plan más restrictivo
- [x] 2.8 Reescribir el cuerpo de `rpc_product_profitability` para consumir el helper de 2.2, **conservando firma y columnas de salida**, partiendo del cuerpo capturado en 1.1
- [x] 2.9 Corregir `last_sale_date` a un casteo directo de la fecha de negocio, sin conversión de zona, conservando el tipo `date` que motivó el cast original (evita reintroducir el `42804`)
- [x] 2.10 `REVOKE`/`GRANT` explícitos de todas las funciones nuevas y de la reescrita, en el mismo archivo de migración (un `DROP`+`CREATE` resetea ACLs; las capturadas en 1.2 son la referencia)
- [x] 2.11 Crear el índice `idx_sales_account_date` sobre `(account_id, date DESC)` con `IF NOT EXISTS`, sin `CONCURRENTLY` (las migraciones corren en transacción)
- [x] 2.12 GREEN + TRIANGULATE: ejecutar el gate de 2.1 y ampliarlo hasta cubrir cada escenario de las specs `sales-statistics` y `product-ranking`, incluido el caso de variante huérfana (padre borrado, referencia quedó nula) agrupando bajo sí misma
- [x] 2.13 Verificar con `EXPLAIN` que el planner **elige** el índice de 2.11 en las consultas de los agregados nuevos; si no lo elige, retirarlo en este mismo apply en vez de dejarlo como peso muerto (D10)
- [x] 2.14 Verificar que la migración es idempotente: `supabase db reset` local limpio y segunda aplicación sin error
- [x] 2.15 Confirmar el fix de 2.9 contra el baseline de 1.3: el conteo de productos con día corrido pasa de 218 a **0**

## 3. E1 — Backend: read-models detrás de la API (MEDIUM)

- [x] 3.1 RED: tests de `backend/tests/test_statistics.py` para el contrato del endpoint — 422 cuando el fin es anterior al inicio, 422 ante dimensión u orden fuera de dominio, envelope de paginación del ranking, y la ventana aplicada viajando en la respuesta
- [x] 3.2 Crear `backend/repositories/statistics_repository.py` sobre las RPCs nuevas, siguiendo `BaseRepository`
- [x] 3.3 Crear `backend/services/statistics.py` con la validación de rango y la resolución de orden por diccionario (nunca interpolando el parámetro en SQL)
- [x] 3.4 Crear `backend/routers/statistics.py` con `report_router` prefijo `/reports/statistics`: ranking paginado y evolución, con parámetros `Literal` para orden y bucket
- [x] 3.5 Crear los schemas Pydantic v2 de entrada y salida — ningún payload ni respuesta sin schema
- [x] 3.6 Registrar el router en la app y verificar que aparece en el OpenAPI
- [x] 3.7 GREEN + TRIANGULATE: los tests de 3.1 en verde, más casos de borde (página fuera de rango, rango de un solo día, cuenta sin ventas)

## 4. E1 — Frontend: ranking y evolución

- [x] 4.1 Extraer `components/charts/ReportBarChart.tsx` y `components/charts/ReportTimeSeriesChart.tsx` sobre `REPORT_SERIES_COLORS`, con sus tests de render (D13 — los consume sólo la superficie nueva)
- [x] 4.2 Crear `frontend/lib/sales-statistics.ts` con los mapeos de fila y los sumadores, tipados explícitos (prohibido `any`)
- [x] 4.3 Crear los hooks de React Query del módulo con sus claves en `lib/query-keys.ts`
- [x] 4.4 Crear `frontend/app/(dashboard)/estadisticas/page.tsx` con selector de rango (`DateButton`), granularidad, gráfico de evolución y comparación contra el período anterior
- [x] 4.5 Añadir la tabla del ranking con conmutación unidades/importe y alternancia de agrupación de variantes, en `overflow-x-auto` con `min-w-0` en la cadena de flex
- [x] 4.6 Mostrar el margen con su marca de cobertura y "—" cuando no hay costo (D11) — nunca cero
- [x] 4.7 Añadir la nota al pie declarando lo excluido: importe de líneas de servicio fuera del ranking, y que los desgloses no restan notas de crédito
- [x] 4.8 Mostrar el aviso de recorte de historial cuando la ventana aplicada difiere de la solicitada (D8)
- [x] 4.9 Añadir la entrada al grupo "Inteligencia" de `components/app-sidebar.tsx`, sin gate de plan
- [x] 4.10 Estados vacío y de error visibles y distinguibles entre sí
- [x] 4.11 Tests de la pantalla: orden por unidades distinto del orden por importe, agrupación activada y desactivada, margen ausente como "—", aviso de recorte

## 5. E2 — Dimensiones: canal, sucursal, día de semana, horario

- [x] 5.1 RED: casos del gate SQL para las cuatro dimensiones, incluido el tramo "Sin canal"/"Sin sucursal" y la identidad suma de tramos igual al total del período
- [x] 5.2 Crear `rpc_sales_breakdown(p_start, p_end, p_dimension, p_branch_id, p_canal)` — una sola RPC para las cuatro dimensiones, que comparten forma de salida (D1)
- [x] 5.3 Implementar la dimensión horaria sobre el **instante de registro** convertido a zona local, devolviendo la hora cruda 0-23 (D5) — **nunca** sobre la fecha de negocio
- [x] 5.4 Implementar día de la semana sobre la fecha de negocio casteada directamente (D3), devolviendo los siete días aunque alguno esté en cero
- [x] 5.5 Crear `rpc_sales_top_clients(p_start, p_end, p_branch_id, p_limit)` excluyendo del ranking las ventas sin cliente y devolviendo su importe aparte (OQ-2)
- [x] 5.6 GREEN + TRIANGULATE: gate ampliado, incluido el caso de una venta de lunes que debe informarse como lunes

## 6. E2 — Backend de dimensiones

- [x] 6.1 RED: tests del endpoint de desgloses y del top de clientes
- [x] 6.2 Añadir los endpoints de desglose y de top de clientes bajo `/reports/statistics`, con la dimensión como `Literal`
- [x] 6.3 GREEN + TRIANGULATE

## 7. E2 — Frontend de dimensiones

- [x] 7.1 Añadir a `/estadisticas` los desgloses por canal y por sucursal, con su tramo "Sin canal"/"Sin sucursal" visible
- [x] 7.2 Añadir el patrón por día de la semana
- [x] 7.3 Añadir la vista de horarios, **rotulada como horario de carga de la operación**, con la salvedad visible (OQ-1) y la conmutación hora / franja resuelta en el cliente
- [x] 7.4 Añadir el top de clientes, declarando el importe de las ventas sin cliente
- [x] 7.5 Tests de las cuatro superficies, incluido que el rótulo de horarios no promete horario de venta

## 8. E3 — Exportación del ranking

- [x] 8.1 RED: test del tipo de exportación nuevo, incluido el rechazo de un tipo desconocido
- [x] 8.2 Añadir `product_ranking_csv` a `ExportType` en `frontend/lib/types.ts`
- [x] 8.3 Añadir el tipo a `supabase/functions/generate-export/index.ts` — la unión de tipos **y** el array de tipos válidos están duplicados en el archivo; cambiar uno solo lo deja roto
- [x] 8.4 Generar las filas del CSV desde `rpc_product_ranking`, con el mismo período, orden y agrupación que la pantalla — nunca reagregando en Deno
- [x] 8.5 Añadir la opción a `frontend/app/(dashboard)/exportaciones/page.tsx` y el botón de exportar en `/estadisticas`
- [x] 8.6 GREEN: verificar que el archivo generado coincide fila a fila con la pantalla de la que se exportó

## 9. E3 — Detalle por producto

- [x] 9.1 RED: tests del RPC de detalle y de la ruta
- [x] 9.2 Crear `rpc_product_sales_evolution(p_product_id, p_start, p_end, p_bucket)` con el desglose por variante cuando el producto agrupa
- [x] 9.3 Añadir el endpoint de detalle por producto al backend
- [x] 9.4 Crear `frontend/app/(dashboard)/estadisticas/productos/[id]/page.tsx` (D12 — **no** `/productos/[id]`), con enlace al producto en el catálogo
- [x] 9.5 Hacer navegable la fila del ranking hacia el detalle
- [x] 9.6 GREEN + TRIANGULATE, incluido el caso de producto con variantes y el de producto sin ventas en el período

## 10. E3 — Análisis con IA

- [x] 10.1 Crear `supabase/functions/ai-estadisticas/index.ts` con el molde de `ai-rentabilidad`: verificación de cuota con los helpers compartidos, `gpt-4o-mini`, timeout de 25 s con fallback
- [x] 10.2 Construir el contexto del prompt desde las RPCs del módulo — nunca agregando ventas en la Edge Function (invariante de consumo)
- [x] 10.3 Persistir el resultado en la tabla `insights` con tipo propio del módulo (la tabla canónica es `insights`, no `ai_insights`)
- [x] 10.4 Verificar que el contador de uso se incrementa **sólo** cuando el insight se generó, y no en el camino de fallback
- [x] 10.5 Añadir el botón "Analizar con IA" a `/estadisticas` con su estado de carga y el panel del último insight
- [x] 10.6 Tests: cuota disponible, cuota agotada, y timeout devolviendo fallback sin persistir ni incrementar

## 11. Gates de CI

- [x] 11.1 Cablear `supabase/tests/test_estadisticas_ventas.sql` como step propio en `.github/workflows/KPI_Validation.yml` con `psql -v ON_ERROR_STOP=1` (sin él, un gate que falla pasa en silencio)
- [x] 11.2 Añadir al gate el chequeo de introspección: el cuerpo vivo de cada RPC nueva **llama** al helper canónico, y ninguna aplica conversión de zona horaria sobre la fecha de negocio de `sales`
- [x] 11.3 Añadir el gate de consistencia: la facturación del módulo coincide con `rpc_dashboard_kpi_summary` sobre la misma ventana y cuenta
- [x] 11.4 Verificar que los gates genéricos (ACLs, ERRCODE de 5 caracteres, referencias a tablas backend/frontend) siguen en verde con las funciones nuevas

## 12. Verificación integral

- [x] 12.1 `pytest` completo sin regresiones contra el baseline de 1.4, con cobertura sobre el umbral de CI
- [x] 12.2 `vitest run` completo sin regresiones contra el baseline de 1.5
- [x] 12.3 `tsc` sin errores nuevos
- [x] 12.4 Pasada visual real de `/estadisticas` y del detalle en las 4 combinaciones (claro/oscuro × escritorio/móvil), verificando que ninguna tabla desborda el shell
- [x] 12.5 Revisión de accesibilidad de la superficie nueva: foco visible, rótulos de los controles de rango y de conmutación, y gráficos con alternativa textual en la tabla que los acompaña
- [x] 12.6 Verificado en producción (2026-09-04, re-confirmado en el archive conjunto): `MAX(version) = 20261026000001` sobre 275 migraciones; las cinco funciones del módulo (`rpc_sales_evolution`, `rpc_product_ranking`, `rpc_sales_breakdown`, `rpc_sales_top_clients`, `rpc_product_sales_evolution`) tienen una sola definición cada una, `SECURITY DEFINER`, `proacl = {postgres=X, authenticated=X, service_role=X}` — sin `EXECUTE` para `anon`. `CHECK export_logs_type_values` incluye `product_ranking_csv`. Edge Function `ai-estadisticas` ACTIVE v2, `generate-export` v64

## 13. Documentación y specs

- [x] 13.1 Corregir `CHANGES.md` L351: afirma que `rpc_period_comparison` trae "top productos" y es falso — nunca se implementó
- [x] 13.2 Añadir la entrada del change a `CHANGES.md` con sus decisiones, hallazgos y candidatos
- [x] 13.3 Actualizar `CLAUDE.md` (roadmap y puntero de próximo change) y correr `python scripts/ci/check_docs_sync.py --fix` en el mismo PR para regenerar `AGENTS.md`
- [x] 13.4 Dejar anotados como candidatos declarados: migrar las dos copias JS de "top productos" al agregado canónico, y migrar los 3 reportes existentes a los componentes de gráfico extraídos

## 14. Cierre con el PO

- [x] 14.1 OQ-1 (horario de carga vs. horario de venta) resuelta durante el apply de E2 (migración `20261025000001`, D5): la vista rotula la métrica como **horario de carga de la operación** (derivada de `created_at` en Mendoza), con la salvedad explícita en la pantalla; el PO no pidió otra cosa en el humo del 2026-09-04.
- [x] 14.2 OQ-2 (ventas sin cliente fuera del ranking) y OQ-4 (margen con cobertura parcial) confirmadas contra lo implementado: `rpc_sales_top_clients` excluye las ventas sin cliente del ranking y las devuelve en fila `unassigned` aparte (E2); `rpc_product_ranking` informa `cost_coverage_pct` y margen ausente (nunca cero) cuando ninguna línea tiene costo (E1, D11). Ambas verificadas en el gate SQL y en la pasada visual de 12.4.
- [x] 14.3 Demo real en producción (2026-09-04): el PO recorrió los 11 puntos del módulo conjunto (categorías/SKU de `productos-categorias-sku` + evolución, ranking por unidades e importe, desgloses con tramo "Sin canal"/"Sin sucursal"/"Sin categoría", detalle por producto, export CSV, IA con clave real de OpenAI, y la fecha de última venta corregida en `/rentabilidad`) y respondió "funciona todo bien"; el único defecto real (CSV ilegible en Excel es-AR, punto 9) se corrigió en el PR #508 y el PO confirmó después "se ve bien el excel".
