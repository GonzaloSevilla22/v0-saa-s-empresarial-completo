## MODIFIED Requirements

### Requirement: Campo plan_expires_at en accounts

El sistema SHALL usar `accounts.plan_expires_at TIMESTAMPTZ` para representar **el fin del período efectivamente pagado** de una cuenta, y NOT SHALL dejarlo nulo tras acreditar un cobro de suscripción.

El valor SHALL derivarse de la fecha de próximo cobro que informa la suscripción, más el período de gracia definido por el sistema. Un valor nulo SHALL significar "sin período de pago en curso": es el caso de las cuentas gratuitas y el de las cuentas provisionadas fuera del circuito de suscripción.

Este campo SHALL ser autoritativo para el vencimiento del plan pago: la capability `billing-trial-lifecycle` lo consume desde la definición normativa del plan efectivo.

#### Scenario: Cobro de suscripción acreditado deja un vencimiento real
- **WHEN** se acredita un cobro de suscripción
- **THEN** `accounts.plan_expires_at` queda en la fecha de próximo cobro más el período de gracia, y nunca en NULL

#### Scenario: plan_expires_at seteado al cancelar
- **WHEN** un usuario cancela su suscripción mensual
- **THEN** `accounts.plan_expires_at` queda en la fecha de vencimiento del período actual

#### Scenario: plan_expires_at NULL en plan gratis
- **GIVEN** un usuario en plan `gratis` sin historial de pago
- **WHEN** se consulta `accounts.plan_expires_at`
- **THEN** el valor es NULL (sin período de pago activo)

#### Scenario: Cada renovación corre el vencimiento
- **GIVEN** una cuenta con un `plan_expires_at` vigente
- **WHEN** se acredita el cobro del mes siguiente
- **THEN** `plan_expires_at` avanza y nunca retrocede

## ADDED Requirements

### Requirement: La auditoría de facturación distingue los hitos del ciclo de suscripción

El sistema SHALL registrar en `billing_events` un evento propio para cada hito del ciclo de suscripción: alta, renovación mensual acreditada, cobro fallido, cancelación solicitada y cancelación por impago.

El historial de una cuenta debe permitir reconstruir por qué tiene el plan que tiene y por qué lo perdió, sin recurrir a los logs del proveedor de pagos.

#### Scenario: La renovación queda auditada
- **WHEN** se acredita un cobro mensual de suscripción
- **THEN** se inserta una fila en `billing_events` que identifica el hito como una renovación, con el identificador del pago de MercadoPago y el monto

#### Scenario: El cobro fallido queda auditado
- **WHEN** un cobro mensual resulta rechazado
- **THEN** se inserta una fila en `billing_events` que identifica el hito como cobro fallido

#### Scenario: El motivo de la baja es reconstruible
- **GIVEN** una cuenta que perdió su plan pago
- **WHEN** se consulta su historial de `billing_events`
- **THEN** puede determinarse si la baja fue solicitada por el usuario o causada por cobros fallidos

#### Scenario: La idempotencia por identificador de pago se conserva
- **GIVEN** un cobro de suscripción ya auditado
- **WHEN** vuelve a procesarse una notificación con el mismo `mercadopago_payment_id`
- **THEN** no se inserta una segunda fila
