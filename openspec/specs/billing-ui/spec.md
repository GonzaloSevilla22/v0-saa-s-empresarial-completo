# billing-ui Specification

## Purpose
UI de planes y facturación — page /planes con comparativo de los 4 planes, Checkout Pro de MercadoPago, y page /facturacion con historial de billing_events y cancelación de suscripción. Implementado en C-10.

## Requirements

### Requirement: Page /planes con comparativo visual de planes

El sistema SHALL mostrar en `/planes` una tabla comparativa de los 4 planes con precios leídos desde `plan_limits`, features por plan, y CTA de compra que inicia el flujo MercadoPago.

#### Scenario: Usuario ve todos los planes
- **WHEN** un usuario autenticado visita `/planes`
- **THEN** ve 4 columnas (Gratis / Inicial / Avanzado / PRO) con precios en ARS, tabla de features y CTA de "Contratar" en los planes de pago

#### Scenario: Plan actual destacado
- **GIVEN** un usuario con `billing_plan = 'avanzado'`
- **WHEN** visita `/planes`
- **THEN** la columna Avanzado muestra "Tu plan actual" en lugar del botón de contratar

#### Scenario: CTA de downgrade a plan inferior deshabilitado
- **GIVEN** un usuario con plan `avanzado`
- **WHEN** ve la columna del plan `inicial`
- **THEN** el botón de contratar está deshabilitado o muestra "Bajar de plan" con link a `/facturacion`

#### Scenario: Redirect a Checkout Pro de MercadoPago
- **WHEN** el usuario hace click en "Contratar" de un plan de pago
- **THEN** el frontend hace POST a `/api/billing/preferences`, recibe `initPoint`, y redirige al Checkout Pro de MP en nueva pestaña

#### Scenario: Página de éxito post-pago
- **WHEN** MercadoPago redirige de vuelta a `/planes/success?payment_id=X&status=approved`
- **THEN** la página muestra "¡Plan activado!" con el nombre del nuevo plan y un botón "Ir al dashboard"

#### Scenario: Página de pago fallido
- **WHEN** MercadoPago redirige a `/planes/failure`
- **THEN** la página muestra mensaje de error amigable con opción de reintentar o contactar soporte

### Requirement: Page /facturacion con historial y gestión de suscripción

El sistema SHALL mostrar en `/facturacion` el plan actual, los `billing_events` del usuario, y controles para cancelar la suscripción.

#### Scenario: Usuario ve su plan actual
- **WHEN** un usuario visita `/facturacion`
- **THEN** ve su plan actual, fecha de inicio (`plan_started_at`), y si aplica la fecha de vencimiento (`plan_expires_at`)

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
- **THEN** el modal muestra "Tu plan se mantendrá activo hasta [fecha]" antes de confirmar

### Requirement: Componente PlanCard reutilizable

El sistema SHALL proveer un componente `<PlanCard />` que se use tanto en `/planes` como en modales de upgrade inline (CTAs de features bloqueadas).

#### Scenario: PlanCard en modal de upgrade inline
- **WHEN** un usuario con plan gratis intenta usar una feature bloqueada (ej: rentabilidad)
- **THEN** el modal de upgrade muestra PlanCards de los planes que incluyen esa feature, con CTA de contratar

#### Scenario: PlanCard respeta el plan actual del usuario
- **GIVEN** `currentPlan = 'avanzado'`
- **WHEN** se renderiza PlanCard para el plan `inicial`
- **THEN** el CTA muestra "Bajar de plan" (no "Contratar") y está secundarizado visualmente

### Requirement: Bloque de contacto Empresa en /planes
La pantalla `/planes` SHALL presentar, debajo del comparativo de los cuatro planes, un bloque de contacto para el tier Empresa que no participa del flujo de compra.

El bloque MUST montarse como hermano del comparativo y NOT dentro de él, de modo que el comparativo conserve sus cuatro columnas, su orden y su lógica de compra sin modificación. El bloque MUST NOT mostrarse nunca como "tu plan actual", MUST NOT ofrecer contratar, subir ni bajar de plan, y su acción MUST NOT invocar la creación de preferencias de pago ni de suscripciones.

#### Scenario: Usuario ve el bloque debajo del comparativo
- **WHEN** un usuario autenticado visita `/planes` con el canal de contacto configurado
- **THEN** ve las cuatro columnas de planes y, debajo, el bloque de contacto del tier Empresa

#### Scenario: El comparativo no cambia
- **WHEN** se renderiza `/planes` con el bloque presente
- **THEN** el comparativo sigue mostrando exactamente los planes Gratis, Inicial, Avanzado y PRO, con su plan actual destacado y sus CTA de compra intactos

#### Scenario: La acción del bloque no dispara pagos
- **WHEN** el usuario activa la acción del bloque de contacto Empresa
- **THEN** no se hace ninguna llamada de creación de preferencia ni de suscripción, y el plan de la cuenta permanece igual

#### Scenario: Sin canal de contacto configurado
- **WHEN** el número de contacto no está configurado y el usuario visita `/planes`
- **THEN** el bloque de contacto Empresa no se renderiza y el comparativo de los cuatro planes se muestra con normalidad
