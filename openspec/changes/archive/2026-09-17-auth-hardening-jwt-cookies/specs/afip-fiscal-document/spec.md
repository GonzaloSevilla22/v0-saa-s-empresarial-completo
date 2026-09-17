## ADDED Requirements

### Requirement: El cambio de estado del comprobante llega a la interfaz en tiempo real

La tabla de comprobantes fiscales SHALL formar parte de la publicación de tiempo real del proveedor, de modo que la transición desde `pending_cae` hacia `authorized` o `rejected` —que ocurre en un proceso de background, fuera del request que emitió el comprobante— alcance a la interfaz sin recargar y sin sondeo periódico.

El alcance de esa entrega SHALL quedar impuesto por la seguridad a nivel de fila ya declarada sobre la tabla: el filtro que declare el cliente en su suscripción SHALL considerarse una optimización de red, NOT el límite de seguridad.

La incorporación a la publicación SHALL ser idempotente: aplicarla sobre un entorno donde la tabla ya pertenece a la publicación NOT SHALL fallar.

#### Scenario: El comprobante autorizado actualiza la interfaz sin recargar

- **GIVEN** una venta con un comprobante en `pending_cae` visible en pantalla
- **WHEN** el proceso de background obtiene el CAE y la fila pasa a `authorized`
- **THEN** la interfaz refleja el cambio de estado sin que el usuario recargue la página ni exista un sondeo periódico

#### Scenario: Un comprobante de otra cuenta no llega al cliente

- **GIVEN** dos cuentas distintas con comprobantes en `pending_cae`
- **WHEN** el comprobante de una de ellas cambia de estado
- **THEN** el cliente de la otra cuenta no recibe ese cambio, porque la seguridad a nivel de fila filtra el flujo

#### Scenario: La incorporación a la publicación es idempotente

- **WHEN** la migración que incorpora la tabla a la publicación se aplica sobre un entorno donde ya pertenece a ella
- **THEN** la aplicación se completa sin error y la publicación queda con la tabla una sola vez
