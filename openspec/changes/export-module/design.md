## Context

EmprendeSmart tiene datos de ventas, compras, gastos e inventario que los usuarios no pueden extraer. El plan de exportaciones (RN-03) define cuotas mensuales por plan: gratis=0, inicial=3, avanzado=15, pro=50. El sistema de gating (C-02) ya existe con `plan_limits` y `usePlanLimits()`; solo necesita la columna `max_exports_per_month`. El backend usa Supabase Storage para archivos (bucket `avatars` ya existe como referencia).

## Goals / Non-Goals

**Goals:**
- Generar y descargar CSV de ventas, compras, gastos e inventario desde el frontend
- Generar XLSX de reporte completo (todas las entidades juntas)
- Trackear cuota mensual de exportaciones en `profiles.exports_used`
- URL firmada de descarga válida 1 hora (seguridad: el archivo no es público)
- Historial de exportaciones en `/exportaciones`
- Resetear cuota el primer día de cada mes vía pg_cron

**Non-Goals:**
- Exportación de datos de IA o insights
- Programación automática de exportaciones (cron de exportación por usuario)
- Formatos distintos de CSV y XLSX
- Email con adjunto del archivo exportado

## Decisions

### D-01: Edge Function vs API Route para generación

**Decisión**: Edge Function `generate-export` en Deno.

**Rationale**: La generación requiere leer múltiples tablas con permisos del usuario (RLS), escribir a Storage y retornar URL firmada. Las Edge Functions ya tienen el patrón establecido para esto (ai-insights, copiloto-ia). Las API Routes de Next.js corren en Node.js/Vercel y tendrían que usar la service_role key para escribir al Storage, lo que viola el principio de menor privilegio.

**Alternativa descartada**: API Route Next.js → requiere `SUPABASE_SERVICE_ROLE_KEY` en el servidor Next.js para escribir a Storage, lo que amplía la superficie de ataque.

### D-02: Storage bucket `exports` — estructura de paths

**Decisión**: Path `{user_id}/{export_id}.{csv|xlsx}` dentro del bucket privado `exports`.

**Rationale**: Permite RLS a nivel de bucket (el usuario solo puede leer sus propios archivos) usando policy `auth.uid()::text = (storage.foldername(name))[1]`. La URL firmada dura 1 hora; el archivo en Storage se puede limpiar con un job separado o TTL del bucket.

### D-03: Generación de CSV — librería en Deno

**Decisión**: Generar CSV manualmente en Deno (sin dependencia externa).

**Rationale**: Los CSV de este dominio son simples (filas y columnas planas, sin nesting). Una librería externa agregaría peso al bundle de la Edge Function. Para XLSX se usa la librería `xlsx` (SheetJS) disponible en npm/esm.sh.

### D-04: Contador `exports_used` — columna en `profiles` vs tabla aparte

**Decisión**: Columna `exports_used INTEGER DEFAULT 0` en `profiles`, igual que `ai_queries_used`.

**Rationale**: Consistencia con el patrón ya establecido. El reset mensual se hace con el mismo pg_cron job `reset-ai-counters` extendido (o un job separado análogo).

### D-05: Trigger vs contador en Edge Function

**Decisión**: La Edge Function hace `UPDATE profiles SET exports_used = exports_used + 1` después de guardar el archivo exitosamente.

**Rationale**: El trigger de DB agregaría complejidad innecesaria. La EF ya tiene el `user_id` de la sesión y puede hacer el UPDATE directamente. Si la EF falla después del INSERT en Storage pero antes del UPDATE, el contador queda bajo (favorece al usuario), que es el comportamiento correcto.

## Risks / Trade-offs

- **Archivos huérfanos en Storage** → Los archivos generados se quedan en el bucket si el usuario no los descarga. Mitigación: documentar en PRD un job de limpieza futuro (> 7 días); el bucket tiene costo mínimo en Supabase.
- **Generación lenta para datasets grandes** → Edge Functions tienen timeout de 60s. Mitigación: limitar queries con historial por plan (el mismo filtro de `plan_limits.history_days` que ya usa el gating).
- **Concurrencia de exports** → Dos requests simultáneos podrían sobrepasar la cuota. Mitigación: verificar cuota con `SELECT exports_used FROM profiles WHERE id = auth.uid() FOR UPDATE` al inicio de la EF (row-level lock).

## Migration Plan

1. Aplicar migración SQL: tabla `export_logs`, columna `profiles.exports_used`, seed `plan_limits.max_exports_per_month`, bucket `exports`, RLS del bucket
2. Crear Edge Function `generate-export` y deployar
3. Agregar pg_cron job `reset-export-counters`
4. Agregar botones en UI (ventas, compras, gastos, stock)
5. Crear page `/exportaciones`
6. Actualizar `usePlanLimits()` con `maxExportsPerMonth` y `exportsUsed`

**Rollback**: La migración es additive (columna nullable inicialmente, tabla nueva, seed). Las páginas existentes no se modifican estructuralmente. La EF puede eliminarse sin impacto en el resto del sistema.

## Open Questions

- ¿El bucket `exports` debe tener TTL automático de Supabase (si está disponible en el plan actual)? → Dejar para iteración futura.
- ¿El reset mensual de `exports_used` debe ser el mismo job que `reset-ai-counters` (extendido) o un job separado? → Implementar como job separado para mayor claridad de logs.
