## ADDED Requirements

### Requirement: Campana accionable — descartar, ir a la alerta y cierre automático
El panel de la campana de notificaciones SHALL listar las notificaciones no leídas visibles para el usuario (las más recientes primero, hasta un tope), y el badge SHALL mostrar la cantidad exacta de no leídas visibles, no la cantidad entre las filas traídas. Cada notificación del panel SHALL tener un botón de descartar con nombre accesible propio y un cuerpo que, al activarse, navega al destino de la alerta. Tanto descartar como navegar SHALL marcar la notificación como leída con la semántica de «Mark-as-read semantics» (sin estado nuevo en la tabla) y SHALL quitarla del panel y bajar el badge en el acto, sin esperar un resync; si la escritura falla, la notificación SHALL volver al panel y el usuario SHALL ver un aviso. Al navegar, el panel SHALL cerrarse solo. El destino SHALL derivarse del `type` y del `payload` con un único mapeo del frontend: `StockBelowMinimum` → `/stock?product=<product_id>`, `CashSessionClosed` → `/caja?branch=<branch_id>`, `FiscalDocumentRejected` → `/ventas`, `QuoteAccepted` → `/presupuestos/<quote_id>`, `TransferDispatched` → `/stock`, `PlanLimitExceeded` → `/planes`, `SubscriptionPaymentFailed` y `SubscriptionExpiringSoon` → `/facturacion`, `ReceivablesOverdueDigest` → `/cobranzas`, `PayablesOverdueDigest` → `/cobranzas` con la pestaña «Por pagar» abierta. Un identificador del `payload` que no sea un UUID válido NOT SHALL interpolarse en la ruta (se usa el destino sin parámetro), y un `type` sin destino conocido SHALL poder descartarse pero NOT SHALL navegar. El panel SHALL ofrecer «Marcar todas como leídas», que marca leídas todas las no leídas visibles de la cuenta activa.

#### Scenario: Descartar una notificación
- **WHEN** el usuario toca el botón de descartar de una notificación no leída
- **THEN** la notificación desaparece del panel, el badge baja en uno y la fila queda con `read = true` y `read_at` seteado

#### Scenario: Ir a la alerta de stock
- **GIVEN** una notificación `StockBelowMinimum` con `payload.product_id = <id>`
- **WHEN** el usuario toca el cuerpo de la notificación
- **THEN** la aplicación navega a `/stock?product=<id>`, el panel se cierra y la notificación queda leída

#### Scenario: Ir a la deuda con proveedores
- **WHEN** el usuario toca una notificación `PayablesOverdueDigest`
- **THEN** se abre `/cobranzas` con la pestaña «Por pagar» seleccionada

#### Scenario: Payload malformado
- **GIVEN** una notificación `QuoteAccepted` cuyo `payload.quote_id` no es un UUID
- **WHEN** el usuario toca el cuerpo
- **THEN** la aplicación navega a `/presupuestos` sin interpolar el valor

#### Scenario: Tipo sin destino
- **GIVEN** una notificación de un `type` que el frontend no conoce
- **THEN** se muestra con su `type` como rótulo, se puede descartar y su cuerpo no navega

#### Scenario: La escritura falla
- **WHEN** el `UPDATE` de marcar leída falla
- **THEN** la notificación vuelve al panel, el badge recupera su valor y se muestra un aviso de error

#### Scenario: Badge exacto con muchas no leídas
- **GIVEN** 270 notificaciones no leídas visibles para el usuario
- **THEN** el badge muestra «9+» y el encabezado del panel dice «270 sin leer», aunque el panel liste sólo las más recientes

#### Scenario: Marcar todas
- **WHEN** el usuario toca «Marcar todas como leídas»
- **THEN** todas las no leídas visibles de la cuenta activa quedan leídas, el panel queda vacío con «Sin notificaciones» y el badge desaparece
