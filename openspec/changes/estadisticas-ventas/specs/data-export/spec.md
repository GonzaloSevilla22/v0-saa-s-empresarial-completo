## MODIFIED Requirements

### Requirement: Generación de CSV por entidad

El sistema SHALL permitir al usuario exportar sus datos en formato CSV (una entidad a la vez: ventas, compras, gastos, inventario o **ranking de productos vendidos**) siempre que tenga cuota disponible en su plan.

La exportación del ranking de productos SHALL derivar sus filas del **read-model canónico del ranking**, con el mismo período, orden y agrupación de variantes que la pantalla presenta — NUNCA de una agregación propia escrita en la capa de exportación. Un archivo que no coincide con la pantalla de la que se exportó es indistinguible de un archivo corrupto para quien lo recibe.

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

#### Scenario: Un tipo de exportación desconocido se rechaza
- **WHEN** se solicita una exportación con un tipo que no está entre los admitidos
- **THEN** la Edge Function la rechaza sin generar archivo ni consumir cuota
