## MODIFIED Requirements

### Requirement: Gating de cuota de exportaciones

El sistema SHALL bloquear la exportación cuando el usuario alcanza su límite mensual o pertenece al plan gratis.

El plan contra el que se resuelven `plan_limits.max_exports_per_month` y `plan_limits.history_days` SHALL ser el **plan efectivo de la cuenta**, obtenido de la definición normativa de la base de datos. La Edge Function `generate-export` NOT SHALL derivar el plan de `public.profiles` ni reimplementar la regla de trial o de exención.

#### Scenario: Usuario gratis no puede exportar
- **WHEN** un usuario con plan efectivo 'gratis' intenta exportar cualquier archivo
- **THEN** la Edge Function retorna HTTP 403 `{ ok: false, error: 'export_not_allowed', plan: 'gratis' }` sin generar ningún archivo

#### Scenario: Usuario que agotó su cuota mensual es bloqueado
- **WHEN** un usuario con plan efectivo 'inicial' tiene `exports_used = 3` (límite = 3) e intenta exportar
- **THEN** la Edge Function retorna HTTP 429 `{ ok: false, error: 'quota_exceeded', resetAt: <primer_dia_mes_siguiente> }` sin generar ningún archivo

#### Scenario: La UI muestra la cuota antes de intentar exportar
- **WHEN** el usuario visita cualquier página con botón de exportación
- **THEN** el botón muestra el texto "Exportar CSV (X restantes)" donde X = `max_exports_per_month - exports_used`

#### Scenario: Plan gratis ve CTA de upgrade en lugar del botón
- **WHEN** un usuario con plan efectivo 'gratis' ve una página con opción de exportar
- **THEN** el botón está reemplazado por un componente `PlanGate` con CTA de upgrade y texto "Exportar requiere plan Inicial o superior"

#### Scenario: La cuenta que pagó puede exportar
- **GIVEN** una cuenta con `accounts.billing_plan = 'pro'` cuyo registro en `profiles` conserva el valor por defecto `'gratis'`
- **WHEN** un miembro invoca `generate-export`
- **THEN** la exportación se genera, comparando el uso contra el límite de `'pro'` y no contra el de `'gratis'`

#### Scenario: La cuenta exenta puede exportar
- **GIVEN** una cuenta con `accounts.billing_exempt = true` y `billing_plan = 'gratis'`
- **WHEN** un miembro invoca `generate-export`
- **THEN** la exportación se genera, porque el plan efectivo es `'pro'`

#### Scenario: La ventana de historial corresponde al plan efectivo
- **GIVEN** una cuenta cuyo plan efectivo es `'avanzado'` (`history_days = 730`)
- **WHEN** un miembro exporta un CSV de ventas
- **THEN** el archivo incluye las ventas de los últimos 730 días, y no las de la ventana de `'gratis'` (30 días)
