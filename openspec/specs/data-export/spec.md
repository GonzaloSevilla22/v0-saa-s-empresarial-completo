# data-export — Spec (export-module)

> Capability: **data-export** — exportación de datos del usuario en formatos CSV y XLSX, con gating de cuota por plan, historial de exportaciones y reset mensual automático.

## Requirements

### Requirement: Generación de CSV por entidad

El sistema SHALL permitir al usuario exportar sus datos en formato CSV (una entidad a la vez: ventas, compras, gastos o inventario) siempre que tenga cuota disponible en su plan.

#### Scenario: Usuario inicial exporta CSV de ventas con cuota disponible
- **WHEN** un usuario con plan 'inicial' (`exports_used = 1`, `max_exports_per_month = 3`) solicita exportar ventas
- **THEN** la Edge Function genera un CSV con las columnas de `sales` del período habilitado por su plan, guarda el archivo en Storage bajo `{user_id}/{export_id}.csv`, registra en `export_logs`, incrementa `exports_used` a 2, y retorna una URL firmada válida por 1 hora

#### Scenario: El CSV respeta el límite de historial del plan
- **WHEN** un usuario con plan 'gratis' (historial 30 días) solicita exportar gastos
- **THEN** el CSV incluye únicamente gastos de los últimos 30 días, alineado con `plan_limits.history_days`

#### Scenario: El CSV incluye las columnas relevantes por entidad
- **WHEN** el usuario exporta ventas
- **THEN** el CSV incluye al menos: fecha, cliente, producto, cantidad, precio_unitario, total, sucursal (si aplica)

### Requirement: Generación de reporte completo XLSX

El sistema SHALL permitir exportar un reporte consolidado en formato XLSX (una hoja por entidad: ventas, compras, gastos, inventario) para usuarios con cuota disponible.

#### Scenario: Usuario pro exporta reporte XLSX completo
- **WHEN** un usuario con plan 'pro' solicita el reporte completo
- **THEN** la Edge Function genera un XLSX con 4 hojas (Ventas, Compras, Gastos, Inventario), aplica el filtro de historial del plan, lo guarda en Storage y retorna URL firmada

#### Scenario: El XLSX consume 1 unidad de cuota
- **WHEN** el usuario exporta el reporte XLSX completo
- **THEN** `exports_used` se incrementa en 1 (igual que un CSV simple)

### Requirement: Gating de cuota de exportaciones

El sistema SHALL bloquear la exportación cuando el usuario alcanza su límite mensual o pertenece al plan gratis.

#### Scenario: Usuario gratis no puede exportar
- **WHEN** un usuario con plan 'gratis' intenta exportar cualquier archivo
- **THEN** la Edge Function retorna HTTP 403 `{ ok: false, error: 'export_not_allowed', plan: 'gratis' }` sin generar ningún archivo

#### Scenario: Usuario que agotó su cuota mensual es bloqueado
- **WHEN** un usuario con plan 'inicial' tiene `exports_used = 3` (límite = 3) e intenta exportar
- **THEN** la Edge Function retorna HTTP 429 `{ ok: false, error: 'quota_exceeded', resetAt: <primer_dia_mes_siguiente> }` sin generar ningún archivo

#### Scenario: La UI muestra la cuota antes de intentar exportar
- **WHEN** el usuario visita cualquier página con botón de exportación
- **THEN** el botón muestra el texto "Exportar CSV (X restantes)" donde X = `max_exports_per_month - exports_used`

#### Scenario: Plan gratis ve CTA de upgrade en lugar del botón
- **WHEN** un usuario con plan 'gratis' ve una página con opción de exportar
- **THEN** el botón está reemplazado por un componente `PlanGate` con CTA de upgrade y texto "Exportar requiere plan Inicial o superior"

### Requirement: Historial de exportaciones

El sistema SHALL mantener un registro de todas las exportaciones generadas y permitir al usuario acceder a las URL de descarga dentro del período de validez.

#### Scenario: El usuario consulta su historial en /exportaciones
- **WHEN** el usuario navega a `/exportaciones`
- **THEN** ve una tabla con las exportaciones del mes en curso: fecha, tipo, estado (disponible/vencida), enlace de descarga si sigue vigente

#### Scenario: Link de descarga vence después de 1 hora
- **WHEN** han pasado más de 60 minutos desde que se generó una exportación
- **THEN** el link aparece como "Vencido" en la tabla y no permite descarga (la URL firmada expiró)

#### Scenario: El usuario puede regenerar una exportación vencida
- **WHEN** el usuario hace clic en "Regenerar" en una exportación vencida y tiene cuota disponible
- **THEN** el sistema genera un nuevo archivo, actualiza `export_logs` con la nueva URL firmada e incrementa `exports_used`

### Requirement: Reset mensual de cuota de exportaciones

El sistema SHALL resetear `profiles.exports_used = 0` el primer día de cada mes para todos los perfiles.

#### Scenario: El counter se resetea automáticamente el 1ro del mes
- **WHEN** es el primer día de un nuevo mes
- **THEN** el pg_cron job `reset-export-counters` ejecuta `UPDATE profiles SET exports_used = 0` y el usuario vuelve a tener su cuota completa disponible

#### Scenario: Después del reset el usuario puede exportar nuevamente
- **WHEN** un usuario con plan 'inicial' tenía `exports_used = 3` el último día del mes
- **THEN** al día siguiente (1ro del mes) tiene `exports_used = 0` y puede hacer 3 exportaciones más
