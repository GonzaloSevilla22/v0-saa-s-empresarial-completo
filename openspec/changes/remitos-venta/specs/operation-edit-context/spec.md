## ADDED Requirements

### Requirement: La venta nacida de un remito es inmutable
El sistema SHALL rechazar con `P0423 delivery_note_sale_locked` toda edición de una venta cuya orden nació de un remito.

El rechazo SHALL evaluarse inmediatamente después de tomar las filas de la operación y antes de cualquier otro efecto: la anulación de un comprobante pendiente, la reversa o la aplicación de stock, y los libros. El bloqueo SHALL alcanzar a la operación entera, también a la cabecera, porque la edición de ventas reemplaza siempre las líneas y volvería a descontar stock.

El listado de ventas SHALL exponer el motivo para que la interfaz deshabilite "Editar" con la explicación: eliminar la venta, corregir el remito y volver a convertirlo.

#### Scenario: Edición rechazada sin efectos
- **GIVEN** una venta nacida de un remito, con un comprobante fiscal pendiente que todavía no salió hacia ARCA
- **WHEN** se intenta editarla
- **THEN** la operación falla con `P0423 delivery_note_sale_locked`, el comprobante sigue pendiente y el stock, la caja y las líneas no cambian

#### Scenario: Botón deshabilitado con motivo
- **WHEN** el listado de ventas muestra una venta nacida de un remito
- **THEN** "Editar" aparece deshabilitado con el motivo y el número del remito
