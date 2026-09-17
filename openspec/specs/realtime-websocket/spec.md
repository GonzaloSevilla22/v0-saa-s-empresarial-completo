# realtime-websocket — Spec

## Purpose

Canal WebSocket para broadcast de eventos en tiempo real. Los clientes se suscriben a una "room" (por tenant/empresa) y reciben mensajes cuando ocurren eventos en el sistema.
## Requirements
### Requirement: El backend no expone un canal WebSocket propio

El backend NOT SHALL exponer ningún endpoint WebSocket, NOT SHALL registrar un router de WebSocket en la aplicación y NOT SHALL mantener un gestor de conexiones por salas.

El tiempo real de la aplicación SHALL resolverse exclusivamente por la integración de Realtime del proveedor sobre tablas con seguridad a nivel de fila, que es el mecanismo que la aplicación usa realmente y el que exigen las capacidades de notificaciones y de comprobantes fiscales. Cualquier necesidad futura de un canal propio SHALL modelarse en un change propio, con autorización de sala vinculada a la cuenta del portador, transporte del token fuera del parámetro de consulta, revalidación durante la vida de la conexión y su propia spec.

#### Scenario: No existe ninguna ruta WebSocket en la superficie del backend

- **WHEN** se inspecciona el documento de OpenAPI de la aplicación y el registro de routers
- **THEN** no existe ninguna ruta WebSocket ni ningún router de WebSocket registrado

#### Scenario: No existe gestor de conexiones ni su suite

- **WHEN** se inspecciona el árbol del backend
- **THEN** no existen el módulo del gestor de conexiones por salas ni su suite de tests

#### Scenario: El tiempo real llega por la integración del proveedor

- **WHEN** ocurre un evento que la interfaz debe reflejar sin recargar
- **THEN** el cliente lo recibe por la suscripción de Realtime del proveedor sobre la tabla correspondiente, con el alcance impuesto por la seguridad a nivel de fila

