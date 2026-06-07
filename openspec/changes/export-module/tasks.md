## 1. Migración de Base de Datos

- [x] 1.1 Crear migración SQL: tabla `export_logs` con campos `id UUID PK`, `user_id UUID`, `org_id UUID`, `export_type TEXT`, `file_path TEXT`, `signed_url TEXT`, `signed_url_expires_at TIMESTAMPTZ`, `status TEXT DEFAULT 'generated'`, `created_at TIMESTAMPTZ DEFAULT now()`
- [x] 1.2 Crear migración SQL: columna `exports_used INTEGER DEFAULT 0` en `profiles`
- [x] 1.3 Crear migración SQL: columna `max_exports_per_month INTEGER` en `plan_limits` + seed con valores `0/3/15/50` para `gratis/inicial/avanzado/pro`
- [x] 1.4 Crear migración SQL: bucket `exports` en Supabase Storage (privado) + RLS policy `auth.uid()::text = (storage.foldername(name))[1]`
- [x] 1.5 Crear migración SQL: RLS en `export_logs` — SELECT/INSERT para `user_id = auth.uid()`
- [x] 1.6 Crear migración SQL: pg_cron job `reset-export-counters` — primer día de cada mes, `UPDATE profiles SET exports_used = 0`
- [x] 1.7 Aplicar migración con `npx supabase db push` y verificar que no hay errores

## 2. Edge Function `generate-export`

- [x] 2.1 Crear `supabase/functions/generate-export/index.ts` con estructura base (CORS, auth check, validación de body)
- [x] 2.2 Implementar verificación de cuota: `SELECT exports_used, ... FROM profiles WHERE id = auth.uid() FOR UPDATE`; retornar 403 si plan='gratis', 429 si cuota agotada
- [x] 2.3 Implementar generación de CSV para tipo `sales_csv`: consulta `sales` + `clients` + `products` filtrada por `history_days` del plan
- [x] 2.4 Implementar generación de CSV para tipos `purchases_csv`, `expenses_csv`, `stock_csv` con columnas relevantes por entidad
- [x] 2.5 Implementar generación de XLSX (`full_report_xlsx`) usando librería SheetJS vía esm.sh: 4 hojas (Ventas, Compras, Gastos, Inventario)
- [x] 2.6 Implementar upload al bucket `exports` con path `{user_id}/{uuid}.{csv|xlsx}` y retorno de URL firmada (1 hora)
- [x] 2.7 Implementar INSERT en `export_logs` y UPDATE `profiles.exports_used += 1` tras upload exitoso
- [x] 2.8 Deployar con `npx supabase functions deploy generate-export` y verificar en Supabase Dashboard

## 3. Hook y Gating

- [x] 3.1 Actualizar `usePlanLimits()` en `hooks/usePlanLimits.ts`: incluir `maxExportsPerMonth`, `exportsUsed`, `exportsRemaining = max - used`
- [x] 3.2 Agregar función helper `canExport()` en `usePlanLimits()` que retorna `{ allowed: boolean, reason: 'plan_gratis' | 'quota_exceeded' | null }`

## 4. UI — Botones de Exportación

- [x] 4.1 Crear componente `ExportButton.tsx` en `components/export/`: recibe `exportType` prop, usa `usePlanLimits()` para mostrar estado, llama a la Edge Function y descarga el archivo
- [x] 4.2 Agregar `<ExportButton exportType="sales_csv" />` a la página de ventas (`app/(dashboard)/ventas/page.tsx`)
- [x] 4.3 Agregar `<ExportButton exportType="purchases_csv" />` a la página de compras
- [x] 4.4 Agregar `<ExportButton exportType="expenses_csv" />` a la página de gastos
- [x] 4.5 Agregar `<ExportButton exportType="stock_csv" />` a la página de inventario/stock
- [x] 4.6 Agregar `<ExportButton exportType="full_report_xlsx" />` en `/exportaciones` (reporte completo)

## 5. Page `/exportaciones`

- [x] 5.1 Crear `app/(dashboard)/exportaciones/page.tsx` con layout base y metadatos
- [x] 5.2 Implementar tabla de historial de exportaciones del mes en curso (query a `export_logs` del mes actual)
- [x] 5.3 Implementar columnas de tabla: fecha, tipo, link de descarga (si `signed_url_expires_at > now()`), badge estado (Disponible/Vencido)
- [x] 5.4 Implementar acción "Regenerar" en filas vencidas: llama a Edge Function con el mismo `export_type`, actualiza fila en `export_logs`
- [x] 5.5 Agregar indicador de cuota mensual: "X exportaciones usadas de Y disponibles" con progress bar
- [x] 5.6 Agregar link a `/exportaciones` en el sidebar de navegación

## 6. Tipos TypeScript

- [x] 6.1 Agregar tipo `ExportType = 'sales_csv' | 'purchases_csv' | 'expenses_csv' | 'stock_csv' | 'full_report_xlsx'` en `lib/types.ts`
- [x] 6.2 Agregar tipo `ExportLog` correspondiente a la tabla `export_logs` en `lib/types.ts`
- [x] 6.3 Regenerar tipos Supabase con `npx supabase gen types typescript` y actualizar `lib/database.types.ts`

## 7. Tests

- [x] 7.1 Test unitario: `ExportButton` con plan 'gratis' renderiza `PlanGate` en lugar del botón
- [x] 7.2 Test unitario: `ExportButton` con cuota agotada muestra "0 restantes" y deshabilita el botón
- [x] 7.3 Test de integración (Supabase): exportar CSV de ventas con 3 filas, verificar que el archivo se genera en Storage y la URL firmada es válida
- [x] 7.4 Test de integración: plan gratis recibe error 403 de la Edge Function
- [x] 7.5 Test de integración: después de N exportaciones iguales al límite, la N+1 retorna 429
- [x] 7.6 Test de integración: `exports_used` se incrementa correctamente tras cada exportación exitosa
