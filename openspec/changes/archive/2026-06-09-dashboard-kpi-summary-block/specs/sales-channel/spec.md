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
El sistema SHALL calcular el margen neto por canal del período como `(ingreso_canal − COGS_canal) / ingreso_canal`, donde `COGS_canal = SUM(producto.cost * venta.quantity)`, agregando solo datos de la cuenta del usuario.

#### Scenario: Margen por canal con múltiples canales
- **WHEN** el período tiene ventas en varios canales
- **THEN** el KPI "Margen por Canal" devuelve el margen porcentual por canal y resalta el canal líder (ej. "IG 34% / ML 18%")

#### Scenario: Canal sin ingresos en el período
- **WHEN** un canal no tiene ingresos en el período
- **THEN** no se divide por cero y ese canal se omite o se muestra como sin dato

#### Scenario: Tarjeta Margen por Canal sin tracking de canal activo
- **WHEN** el campo `canal` aún no fue desplegado/capturado
- **THEN** la tarjeta "Margen por Canal" muestra `—` (placeholder) sin romper el bloque
