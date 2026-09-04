# data-export — Spec (export-module)

## Purpose

Exportación de datos del usuario en formatos CSV y XLSX, con gating de cuota por plan, historial de exportaciones y reset mensual automático.

## Requirements

### Requirement: Generación de CSV por entidad

El sistema SHALL permitir al usuario exportar sus datos en formato CSV (una entidad a la vez: ventas, compras, gastos, inventario o **ranking de productos vendidos**) siempre que tenga cuota disponible en su plan.

La exportación del ranking de productos SHALL derivar sus filas del **read-model canónico del ranking**, con el mismo período, orden y agrupación de variantes que la pantalla presenta — NUNCA de una agregación propia escrita en la capa de exportación. Un archivo que no coincide con la pantalla de la que se exportó es indistinguible de un archivo corrupto para quien lo recibe.

Todo CSV generado por `generate-export` SHALL usar `;` (punto y coma) como separador de columnas, no coma — la misma convención que ya usa el export local `frontend/lib/excel.ts` (`exportToCSV`). Excel con configuración regional en español (Argentina) usa `;` como separador de listas; un CSV separado por comas se abre con todas las columnas apiladas en A. El archivo SHALL llevar BOM UTF-8 al inicio para que Excel detecte la codificación. Un campo que contenga `;`, `"` o un salto de línea SHALL ir entre comillas dobles, con las comillas internas dobladas (RFC 4180); un campo con coma también SHALL entrecomillarse aunque la coma ya no sea el separador (más seguro, y Excel evalúa el tipo del contenido igual esté o no entrecomillado).

Las columnas numéricas del **ranking de productos** (unidades, importe, costo, margen, margen_pct, cobertura_costo_pct) SHALL usar coma como separador decimal (p.ej. `"1234,56"`) — los numerics de Postgres llegan con punto decimal, que Excel es-AR interpreta como texto o separador de miles, no como número, impidiendo sumar la columna. Los enteros (puesto, variantes, operaciones) y la fecha (`ultima_venta`, ISO `YYYY-MM-DD`) NOT SHALL convertirse. Los otros cuatro CSV (ventas, compras, gastos, inventario) NOT SHALL convertir sus columnas numéricas a decimal-coma: alimentan el ida y vuelta exportar→editar→importar, y una conversión ahí arriesgaría que un importador que parsea con `parseFloat` trunque el valor en silencio.

#### Scenario: Usuario inicial exporta CSV de ventas con cuota disponible
- **WHEN** un usuario con plan 'inicial' (`exports_used = 1`, `max_exports_per_month = 3`) solicita exportar ventas
- **THEN** la Edge Function genera un CSV con las columnas de `sales` del período habilitado por su plan, guarda el archivo en Storage bajo `{user_id}/{export_id}.csv`, registra en `export_logs`, incrementa `exports_used` a 2, y retorna una URL firmada válida por 1 hora

#### Scenario: El CSV respeta el límite de historial del plan
- **WHEN** un usuario con plan 'gratis' (historial 30 días) solicita exportar gastos
- **THEN** el CSV incluye únicamente gastos de los últimos 30 días, alineado con `plan_limits.history_days`

#### Scenario: El CSV incluye las columnas relevantes por entidad
- **WHEN** el usuario exporta ventas
- **THEN** el CSV incluye al menos: fecha, cliente, producto, cantidad, precio_unitario, total, sucursal (si aplica)

#### Scenario: Exportación del ranking de productos
- **WHEN** un usuario con cuota disponible solicita exportar el ranking de productos vendidos
- **THEN** la Edge Function genera un CSV con una fila por producto del ranking, incluyendo al menos: producto, unidades vendidas, importe facturado y operaciones
- **AND** consume 1 unidad de cuota, igual que cualquier otro CSV

#### Scenario: El archivo del ranking coincide con la pantalla
- **GIVEN** un ranking mostrado para un período, un ordenamiento y una agrupación de variantes determinados
- **WHEN** el usuario lo exporta
- **THEN** las filas del archivo son las mismas que la pantalla informa, en el mismo orden

#### Scenario: El CSV se abre correctamente en Excel con configuración regional es-AR
- **GIVEN** cualquiera de los seis tipos de exportación CSV (ventas, compras, gastos, inventario o ranking de productos)
- **WHEN** el usuario abre el archivo con Excel configurado en español (Argentina)
- **THEN** cada columna aparece en su propia celda (el separador es `;`, no coma) y los acentos se ven correctamente (BOM UTF-8)

#### Scenario: Los importes del ranking se pueden sumar directamente en Excel
- **GIVEN** un CSV del ranking de productos con columnas de importe, costo y margen
- **WHEN** el usuario lo abre con Excel configurado en español (Argentina) y selecciona la columna de importe
- **THEN** Excel reconoce los valores como números (coma decimal) y la suma automática (autosuma / barra de estado) funciona, sin necesidad de reformatear la columna

#### Scenario: Un tipo de exportación desconocido se rechaza
- **WHEN** se solicita una exportación con un tipo que no está entre los admitidos
- **THEN** la Edge Function la rechaza sin generar archivo ni consumir cuota

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

### Requirement: La superficie de exportación informa el resultado por el sistema de toast canónico

El sistema SHALL comunicar al usuario el resultado de toda exportación disparada desde un `ExportButton` — éxito (con la referencia a `/exportaciones`), cuota agotada, o error — mediante el sistema de toast montado y canónico de la app (`sonner`). Ninguna rama de resultado del botón SHALL emitirse por un sistema de toast cuyo componente de render no esté montado en el layout. La app SHALL mantener un único sistema de toast montado.

#### Scenario: Éxito visible

- **GIVEN** una exportación que la Edge Function acepta
- **WHEN** la generación se dispara correctamente
- **THEN** el usuario ve un toast de confirmación

#### Scenario: Error visible

- **GIVEN** la Edge Function de exportación no disponible
- **WHEN** el usuario toca "Exportar … CSV"
- **THEN** el usuario ve un toast de error, nunca un silencio

#### Scenario: Cuota agotada visible

- **GIVEN** una cuenta con la cuota mensual de exportaciones agotada
- **WHEN** el usuario intenta exportar
- **THEN** el usuario ve el aviso de cuota con el CTA de upgrade que corresponda

