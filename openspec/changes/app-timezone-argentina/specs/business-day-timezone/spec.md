# business-day-timezone — Delta Spec

## ADDED Requirements

### Requirement: Huso canónico de negocio
El sistema SHALL computar todo día calendario de negocio (fecha de operaciones, ventanas de reporting, filtros de "hoy") en la zona horaria `America/Argentina/Mendoza`, con independencia del huso del servidor y del huso del dispositivo del usuario.

#### Scenario: Franja nocturna 21:00–24:00
- **WHEN** son las 22:00 hora argentina del día D (01:00 UTC del día D+1)
- **THEN** todo cómputo de "hoy" en frontend, Edge Functions, backend y SQL resuelve al día D

#### Scenario: Browser en otro huso
- **WHEN** un usuario opera con su dispositivo configurado en un huso distinto de ART
- **THEN** los días de negocio se computan igual en hora argentina

### Requirement: Fecha por defecto en el alta de operaciones
Los formularios de alta de ventas, compras y gastos SHALL usar el día calendario argentino como fecha por defecto del registro y como fecha máxima seleccionable.

#### Scenario: Venta cargada de noche
- **WHEN** un usuario abre el formulario de venta a las 22:00 hora argentina del día D
- **THEN** la fecha por defecto es D y el selector no permite fechas posteriores a D

#### Scenario: Edición conserva la fecha original
- **WHEN** un usuario edita una operación existente
- **THEN** la fecha mostrada es la registrada, sin recomputar

### Requirement: Ventanas de lectura ancladas al día argentino
Los helpers de rangos (`frontend/lib/date-range.ts`, `supabase/functions/_shared/argentina-time.ts`) SHALL derivar el día/mes calendario del día argentino y materializar las ventanas a medianoche UTC, conservando el esquema de almacenamiento vigente.

#### Scenario: Ventana "hoy" del dashboard en la franja nocturna
- **WHEN** el dashboard consulta "ventas hoy" a las 23:00 hora argentina del día D
- **THEN** la ventana enviada es [D 00:00:00Z, D 23:59:59.999Z]

#### Scenario: Fallback de ventana en Edge Function
- **WHEN** una Edge Function IA recibe una petición sin `dateFrom`/`dateTo` a las 22:00 hora argentina del día D
- **THEN** la ventana rolling se ancla al día argentino D, no al día UTC D+1

### Requirement: Paridad entre helpers de runtimes
Los helpers de día argentino de frontend y Edge Functions SHALL producir resultados idénticos sobre una tabla compartida de casos de prueba, verificada en CI.

#### Scenario: Divergencia detectada
- **WHEN** una edición hace que ambos helpers difieran para algún caso de la tabla (bordes de día, de mes y de año en la franja 21:00–24:00)
- **THEN** la suite de CI falla

### Requirement: Día de negocio en SQL
Las funciones SQL vigentes que computen el día de negocio SHALL usar `reporting_local_today()` en lugar de `CURRENT_DATE` o `now()::date`, salvo los sitios con semántica deliberadamente distinta (vencimientos, crons), que quedan documentados.

#### Scenario: RPC de reporting en la franja nocturna
- **WHEN** una RPC calcula una ventana relativa a "hoy" a las 22:00 hora argentina del día D
- **THEN** ancla en el día D según `reporting_local_today()`

### Requirement: Exclusión de fechas fiscales
El cómputo de fechas de comprobantes AFIP/WSFE SHALL quedar fuera de este canon y seguir las reglas de ARCA.

#### Scenario: Emisión de comprobante
- **WHEN** se emite un comprobante fiscal
- **THEN** su fecha se determina por las reglas AFIP vigentes, sin pasar por los helpers de día de negocio
