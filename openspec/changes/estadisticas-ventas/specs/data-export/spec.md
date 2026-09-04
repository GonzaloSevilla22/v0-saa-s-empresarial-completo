## MODIFIED Requirements

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
