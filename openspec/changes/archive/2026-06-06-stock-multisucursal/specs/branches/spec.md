## ADDED Requirements

### Requirement: Visualización del stock por sucursal en la página de sucursales

El sistema SHALL mostrar en `/sucursales` el stock total asignado a cada sucursal (suma de `branch_stock.quantity` de todos los productos de esa sucursal) como indicador de inventario.

#### Scenario: Card de sucursal muestra productos con stock asignado

- **GIVEN** una sucursal A con `branch_stock` para 4 productos (distintas cantidades)
- **WHEN** el owner navega a `/sucursales`
- **THEN** la card de la sucursal A muestra "4 productos con stock asignado" o equivalente

#### Scenario: Sucursal sin stock asignado muestra indicador vacío

- **GIVEN** una sucursal B recién creada sin ninguna fila en `branch_stock`
- **WHEN** el owner navega a `/sucursales`
- **THEN** la card de sucursal B muestra "Sin stock asignado" o "0 productos"

---

### Requirement: Acceso a inventario desde la gestión de sucursales

El sistema SHALL proveer en `/sucursales/:id` un enlace o botón "Ver stock" que navega a `/sucursales/:id/stock`.

#### Scenario: Owner accede al inventario desde la página de sucursal

- **GIVEN** el owner está en `/sucursales/:id` (detalle de una sucursal)
- **WHEN** hace clic en "Ver stock"
- **THEN** navega a `/sucursales/:id/stock` con el inventario de esa sucursal
