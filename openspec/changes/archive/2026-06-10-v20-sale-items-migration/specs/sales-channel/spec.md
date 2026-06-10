# sales-channel

## MODIFIED Requirements

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
