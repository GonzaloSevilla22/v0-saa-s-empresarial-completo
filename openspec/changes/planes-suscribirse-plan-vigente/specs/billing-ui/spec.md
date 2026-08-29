## MODIFIED Requirements

### Requirement: Page /planes con comparativo visual de planes

El sistema SHALL mostrar en `/planes` una tabla comparativa de los 4 planes con precios leídos desde `plan_limits`, features por plan, y CTA de contratación en los planes de pago.

El discriminante de si un tier de pago ofrece CTA de contratación SHALL ser la **existencia de una suscripción viva** para la cuenta, y NOT SHALL ser la igualdad entre ese tier y el plan efectivo. Tener acceso a un tier (por cortesía, por trial vigente o por un plan pago aún no vencido) NOT SHALL bloquear la posibilidad de contratar la suscripción recurrente de ese mismo tier: mientras la cuenta no tenga una suscripción viva, no hay nada que esa contratación duplique.

Toda contratación iniciada desde esta pantalla SHALL usar el flujo de suscripción del sistema, que registra la intención antes de derivar al proveedor de pagos, de modo que el cobro resultante pueda reconciliarse automáticamente con la cuenta. La pantalla NOT SHALL exponer al usuario una URL de checkout que no tenga una intención registrada detrás.

El badge que identifica el plan efectivo SHALL seguir mostrándose con independencia de si ese tier ofrece o no CTA — es información de acceso, no de facturación.

#### Scenario: Usuario ve todos los planes
- **WHEN** un usuario autenticado visita `/planes`
- **THEN** ve 4 columnas (Gratis / Inicial / Avanzado / PRO) con precios en ARS, tabla de features y CTA de contratación en los planes de pago

#### Scenario: Plan efectivo destacado
- **GIVEN** un usuario cuyo plan efectivo es `avanzado`
- **WHEN** visita `/planes`
- **THEN** la columna Avanzado aparece identificada como su plan actual

#### Scenario: Cuenta sin suscripción viva puede contratar el tier que ya usa
- **GIVEN** una cuenta cuyo plan efectivo es `pro` y que NO tiene ninguna suscripción viva (caso real: cortesía con vencimiento futuro, trial vigente, o plan pago por vencer)
- **WHEN** el usuario visita `/planes`
- **THEN** la columna PRO, además de estar identificada como su plan actual, ofrece un CTA de contratación habilitado

#### Scenario: Contratar el tier vigente pasa por el flujo normal de suscripción
- **GIVEN** una cuenta sin suscripción viva cuyo plan efectivo es `pro`
- **WHEN** el usuario activa el CTA de la columna PRO
- **THEN** el sistema registra la intención de suscripción para esa cuenta y recién entonces deriva al checkout del proveedor, de modo que el cobro se reconcilie automáticamente y no quede pendiente de resolución manual

#### Scenario: Cuenta con suscripción viva no puede recontratar su tier
- **GIVEN** una cuenta con una suscripción viva del tier `pro`
- **WHEN** el usuario visita `/planes`
- **THEN** la columna PRO no ofrece CTA de contratación, y la pantalla indica que ya existe una suscripción activa para ese plan

#### Scenario: La pantalla nunca ofrece una contratación que el sistema rechazaría
- **GIVEN** una cuenta con una suscripción viva
- **WHEN** el usuario recorre el comparativo
- **THEN** ningún CTA visible conduce a una contratación que el backend rechace por conflicto con la suscripción existente

#### Scenario: CTA de plan inferior no dispara una contratación silenciosa
- **GIVEN** un usuario cuyo plan efectivo es `pro`
- **WHEN** ve la columna del plan `inicial`
- **THEN** la acción ofrecida corresponde a lo que la etiqueta anuncia, y una etiqueta de baja de plan NOT SHALL iniciar la contratación de una suscripción nueva sin que el usuario lo haya entendido así

#### Scenario: El plan gratis nunca inicia un flujo de pago
- **WHEN** el usuario interactúa con la columna del plan Gratis
- **THEN** no se registra ninguna intención de suscripción ni se crea ninguna preferencia de pago

#### Scenario: Página de éxito post-pago
- **WHEN** el proveedor de pagos redirige de vuelta a `/planes/success?payment_id=X&status=approved`
- **THEN** la página muestra "¡Plan activado!" con el nombre del nuevo plan y un botón "Ir al dashboard"

#### Scenario: Página de pago fallido
- **WHEN** el proveedor de pagos redirige a `/planes/failure`
- **THEN** la página muestra mensaje de error amigable con opción de reintentar o contactar soporte

### Requirement: Componente PlanCard reutilizable

El sistema SHALL proveer un componente `<PlanCard />` que se use tanto en `/planes` como en modales de upgrade inline (CTAs de features bloqueadas).

El componente SHALL derivar el estado de su CTA de dos entradas independientes: el plan efectivo de la cuenta (que determina el destacado) y la disponibilidad de contratación (que determina si el CTA se ofrece y con qué etiqueta). Ambas NOT SHALL colapsarse en una sola condición.

#### Scenario: PlanCard en modal de upgrade inline
- **WHEN** un usuario con plan gratis intenta usar una feature bloqueada (ej: rentabilidad)
- **THEN** el modal de upgrade muestra PlanCards de los planes que incluyen esa feature, con CTA de contratar

#### Scenario: PlanCard identifica el plan efectivo sin suprimir su CTA
- **GIVEN** `currentPlan = 'pro'` y una cuenta sin suscripción viva
- **WHEN** se renderiza PlanCard para el plan `pro`
- **THEN** la tarjeta aparece destacada como plan actual y su CTA de contratación está habilitado

#### Scenario: PlanCard suprime el CTA cuando la contratación no está disponible
- **GIVEN** `currentPlan = 'pro'` y una cuenta con suscripción viva de ese tier
- **WHEN** se renderiza PlanCard para el plan `pro`
- **THEN** la tarjeta aparece destacada como plan actual y no ofrece CTA de contratación

## ADDED Requirements

### Requirement: Cuenta exenta de facturación no recibe ofertas de contratación

La pantalla `/planes` SHALL suprimir todos los CTA de contratación cuando la cuenta está exenta de facturación (`accounts.billing_exempt = true`), en todos los tiers y no solo en el que corresponde a su plan efectivo.

Una cuenta exenta tiene acceso otorgado por cortesía y sin contraprestación: ofrecerle contratar cualquier tier es una invitación a pagar por algo que ya tiene gratis. La pantalla SHALL seguir mostrando el comparativo completo de planes y features — la exención suprime la oferta de compra, no la información.

#### Scenario: Cuenta exenta no ve ningún CTA de pago
- **GIVEN** una cuenta con `billing_exempt = true`
- **WHEN** el usuario visita `/planes`
- **THEN** ve el comparativo completo de los 4 planes con sus precios y features, y ninguna columna ofrece un CTA de contratación

#### Scenario: La exención se comunica, no se disimula
- **GIVEN** una cuenta con `billing_exempt = true`
- **WHEN** el usuario visita `/planes`
- **THEN** la pantalla indica que su acceso está otorgado sin cargo, de modo que la ausencia de CTAs se lea como una decisión y no como una falla

#### Scenario: Una cuenta exenta no puede iniciar una contratación desde esta pantalla
- **GIVEN** una cuenta con `billing_exempt = true`
- **WHEN** se recorre el comparativo completo
- **THEN** no existe ninguna acción alcanzable que registre una intención de suscripción o cree una preferencia de pago
