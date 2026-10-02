## ADDED Requirements

### Requirement: El remito es un documento con máquina de estados en el catálogo
El sistema SHALL admitir `delivery_note` como tipo de documento en el historial de estados y en el catálogo de transiciones, sumándolo de forma aditiva a sus dos conjuntos cerrados. El catálogo SHALL contener, para `delivery_note`, exactamente estas transiciones, cada una sembrada por el cambio que trae la operación que la produce:

| Transición | Roles permitidos | Motivo | Terminal |
|---|---|---|---|
| `NULL → issued` (emisión) | vendedor, stock, administrador, dueño | — | — |
| `issued → canceled` (anulación) | administrador, dueño | **obligatorio** | **sí** |
| `issued → converted` (conversión en venta) | vendedor, cajero, administrador, dueño | — | — |
| `converted → issued` (borrado de la venta nacida del remito) | transición de sistema, sin rol | — | — |

La creación SHALL registrar la primera entrada (`NULL → issued`) con el creador, en la misma transacción y validando su rol. Un disparador de enforcement sobre la tabla de remitos SHALL rechazar cualquier cambio de estado no catalogado, venga de donde venga. Editar un remito NO SHALL registrar historial de estados.

#### Scenario: Emisión registra la primera entrada
- **WHEN** un vendedor emite un remito
- **THEN** el historial tiene una entrada `NULL → issued` con el vendedor como actor

#### Scenario: Anulación exige motivo
- **WHEN** un administrador intenta pasar un remito de `issued` a `canceled` sin motivo
- **THEN** la transición es rechazada y el remito sigue `issued`

#### Scenario: Cambio de estado no catalogado
- **WHEN** cualquier escritor intenta pasar un remito de `canceled` a `issued`
- **THEN** el enforcement lo rechaza

#### Scenario: El borrado de la venta reabre el remito sin rol propio
- **GIVEN** un remito `converted` y un usuario que puede borrar la venta nacida de él pero no tiene ningún rol del remito
- **WHEN** borra la venta
- **THEN** el remito pasa a `issued` y el historial registra al usuario y el motivo del borrado
