## ADDED Requirements

### Requirement: Canal de venta en las ventas
El sistema SHALL permitir asociar un canal de venta (ej. instagram, mercadolibre, whatsapp, local, otro) a cada operación de venta, persistido en la tabla `sales` con scope por cuenta.

#### Scenario: Registrar una venta con canal
- **WHEN** el usuario crea una venta seleccionando un canal en el formulario
- **THEN** la operación se persiste con ese `canal` en todas sus líneas

#### Scenario: Venta sin canal especificado
- **WHEN** el usuario crea una venta sin elegir canal
- **THEN** la venta se persiste con `canal` nulo y se agrupa como "Sin canal" en los reportes

#### Scenario: Ventas previas a la introducción del canal
- **WHEN** se consultan ventas creadas antes de existir el campo `canal`
- **THEN** se tratan como "Sin canal" sin error (no hay backfill histórico)

### Requirement: Margen neto por canal
El sistema SHALL calcular el margen neto por canal del período como `(ingreso_canal − COGS_canal) / ingreso_canal`, donde `COGS_canal = SUM(producto.cost * cantidad_de_línea)`, agregando solo datos de la cuenta del usuario. La cantidad y el producto de cada línea SHALL obtenerse desde la línea de venta (`sale_items` o la vista de compatibilidad `v_sales_flat`), NO desde columnas planas del header `sales` (que son retiradas por C-20). El `canal` sigue viviendo en el header `sales`.

#### Scenario: Margen por canal con múltiples canales
- **WHEN** el período tiene ventas en varios canales
- **THEN** el KPI "Margen por Canal" devuelve el margen porcentual por canal y resalta el canal líder (ej. "IG 34% / ML 18%")

#### Scenario: Canal sin ingresos en el período
- **WHEN** un canal no tiene ingresos en el período
- **THEN** no se divide por cero y ese canal se omite o se muestra como sin dato

#### Scenario: Tarjeta Margen por Canal sin tracking de canal activo
- **WHEN** el campo `canal` aún no fue desplegado/capturado
- **THEN** la tarjeta "Margen por Canal" muestra `—` (placeholder) sin romper el bloque

#### Scenario: el cálculo de margen no depende de columnas planas del header
- **WHEN** C-20 retira `sales.product_id`/`quantity` del header y se calcula el margen por canal
- **THEN** `producto` y `cantidad` se resuelven vía la línea de venta (`sale_items`/`v_sales_flat`) y el KPI sigue devolviendo valores correctos
