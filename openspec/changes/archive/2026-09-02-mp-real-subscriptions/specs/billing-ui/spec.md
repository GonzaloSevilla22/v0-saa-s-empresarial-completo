## MODIFIED Requirements

### Requirement: Page /facturacion con historial y gestión de suscripción

El sistema SHALL mostrar en `/facturacion` el plan actual, el estado real de la suscripción, los `billing_events` del usuario, y controles para cancelar la suscripción.

Cuando la cuenta tiene una suscripción viva, la página SHALL mostrar la **fecha del próximo cobro** informada por el proveedor de pagos y el estado de la suscripción. Cuando hay un cobro en reintento, SHALL indicarlo de forma visible junto con la acción que el usuario puede tomar. Las fechas mostradas NOT SHALL ser estimaciones calculadas por el frontend.

#### Scenario: Usuario ve su plan actual
- **WHEN** un usuario visita `/facturacion`
- **THEN** ve su plan actual, fecha de inicio (`plan_started_at`), y si aplica la fecha de vencimiento (`plan_expires_at`)

#### Scenario: Usuario con suscripción activa ve su próximo cobro
- **GIVEN** una cuenta con una suscripción autorizada
- **WHEN** el usuario visita `/facturacion`
- **THEN** ve la fecha del próximo cobro y el estado de la suscripción

#### Scenario: Cobro en reintento visible
- **GIVEN** una cuenta cuya suscripción tiene un cobro rechazado en reintento
- **WHEN** el usuario visita `/facturacion`
- **THEN** ve un aviso de que el último cobro falló y qué puede hacer al respecto

#### Scenario: Historial de billing_events
- **WHEN** el usuario visita `/facturacion`
- **THEN** ve una tabla cronológica de sus `billing_events` con columnas: fecha, evento, monto, plan anterior → plan nuevo

#### Scenario: Botón cancelar suscripción visible para planes de pago
- **GIVEN** un usuario con `billing_plan != 'gratis'`
- **WHEN** visita `/facturacion`
- **THEN** ve un botón "Cancelar suscripción" que abre un modal de confirmación con la fecha de degradación

#### Scenario: Usuario en plan gratis no ve opción de cancelar
- **GIVEN** un usuario con `billing_plan = 'gratis'`
- **WHEN** visita `/facturacion`
- **THEN** no hay botón de cancelar; solo ve opción de "Mejorar plan" con link a `/planes`

#### Scenario: Confirmación de cancelación con fecha de vencimiento
- **WHEN** el usuario confirma la cancelación en el modal
- **THEN** el modal muestra "Tu plan se mantendrá activo hasta [fecha]" antes de confirmar, con la fecha proveniente del período realmente pagado

#### Scenario: La fecha de degradación no se estima en el cliente
- **WHEN** se muestra cualquier fecha de vencimiento o de próximo cobro
- **THEN** proviene del estado persistido de la suscripción y no de un intervalo calculado en el navegador
