## ADDED Requirements

### Requirement: La corrección por edición de un efectivo ya registrado no es un opt-in nuevo
El sistema SHALL distinguir, al editar una venta, una compra o un gasto, entre **registrar por primera vez** su efectivo en una caja y **corregir** un efectivo que la operación ya tenía registrado en una caja.

- **Registrar por primera vez** (la operación no tenía huella de caja): SHALL exigir las mismas tres condiciones del opt-in del alta (forma de pago de efectivo, sesión abierta de la sucursal efectiva y fecha de hoy), con la misma función de validación.
- **Corregir** (la operación ya tenía huella de caja): SHALL exigir la forma de pago de efectivo y una sesión abierta de la sucursal efectiva, pero NO SHALL exigir la fecha de hoy. El guard de fecha existe para no atribuir a la caja de hoy el efectivo de un documento retroactivo que nunca pasó por una caja; en la corrección ese efectivo ya fue atribuido a una caja, y su corrección se registra en el período abierto porque las sesiones cerradas son intocables.

La validación del opt-in SHALL tener una sola definición, compartida por el alta y la edición de venta, de compra y de gasto, con los mismos códigos y tokens de error que el alta usa hoy.

#### Scenario: Agregar a la caja una venta retroactiva es rechazado
- **GIVEN** una venta en efectivo de ayer sin movimiento de caja
- **WHEN** se edita pidiendo registrarla en la sesión abierta de hoy
- **THEN** la edición falla con `P0422 cash_optin_requires_today`

#### Scenario: Corregir el efectivo de una venta de ayer se permite
- **GIVEN** una venta en efectivo de ayer con su movimiento de caja en una sesión cerrada, y una sesión abierta hoy en la misma caja
- **WHEN** se edita su importe
- **THEN** la corrección se registra en la sesión de hoy sin rechazo por la fecha

#### Scenario: El alta conserva sus tres condiciones
- **WHEN** se registra una venta, una compra o un gasto con opt-in de caja después de este cambio
- **THEN** las tres condiciones y sus mensajes de error son los mismos que antes, verificados por la misma función que usa la edición
