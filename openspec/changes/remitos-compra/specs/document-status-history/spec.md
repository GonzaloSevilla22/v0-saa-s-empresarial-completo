## ADDED Requirements

### Requirement: El remito de compra es un documento con máquina de estados en el catálogo
El sistema SHALL admitir el tipo de documento `delivery_note_purchase` en el historial de estados y en el catálogo de transiciones, con estas transiciones: `NULL → issued` (roles `stock`, `admin`, `owner`), `issued → canceled` (roles `admin`, `owner`, con motivo obligatorio y terminal), `issued → converted` (roles `purchases`, `admin`, `owner`) y `converted → issued` (de sistema, sin rol, disparada sólo por el borrado de la compra nacida del remito). Cada transición SHALL sembrarse en la misma entrega que trae la operación que la produce. Los disparadores de creación y de cumplimiento de la máquina de estados del remito de compra SHALL aplicar sólo a las filas con sentido compra y SHALL NOT alterar los del remito de venta.

#### Scenario: Creación registrada
- **WHEN** un usuario con rol `stock` emite un remito de compra
- **THEN** el historial registra `NULL → issued` con el tipo `delivery_note_purchase` y ese usuario

#### Scenario: Transición fuera del catálogo
- **WHEN** un camino cualquiera intenta pasar un remito de compra de `canceled` a `issued`
- **THEN** la base lo rechaza y el remito sigue `canceled`
