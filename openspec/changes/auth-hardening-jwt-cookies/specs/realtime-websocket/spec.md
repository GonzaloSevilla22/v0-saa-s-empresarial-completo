## ADDED Requirements

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

## REMOVED Requirements

### Requirement: Endpoint de conexión

**Reason**: El canal se retira. Autenticaba el handshake pero no autorizaba la sala —descartaba la identidad validada y nunca comparaba el identificador de sala contra la cuenta del portador—, recibía el token por parámetro de consulta (que queda escrito en los registros del proveedor de hosting) y validaba una sola vez para toda la vida de la conexión. No tenía productor ni consumidor: ningún archivo del frontend abría una conexión, el único emisor de difusión era el eco del propio cliente, la decisión DEC-16 lo declaraba fuera de producción y la spec de notificaciones en la aplicación prohibía usarlo.

**Migration**: No hay consumidor que migrar. El tiempo real ya ocurre por la integración de Realtime del proveedor. Se eliminan el router, el gestor de conexiones, su suite de tests y el registro del router en la aplicación.

### Requirement: Autenticación obligatoria

**Reason**: Se retira junto con el endpoint que la aplicaba. Además, autenticar sin autorizar la sala no era una garantía útil: cualquier usuario válido podía suscribirse a la sala de cualquier cuenta.

**Migration**: El control de acceso del tiempo real lo ejerce la seguridad a nivel de fila sobre las tablas publicadas, no un chequeo de handshake.

### Requirement: ConnectionManager por rooms

**Reason**: El gestor de conexiones se elimina junto con el canal. No tenía tope de vida ni de conexiones y su único uso era el eco del propio cliente.

**Migration**: Ninguna. No hay estado que preservar: el gestor sólo mantenía una lista de sockets activos en memoria del proceso.

### Requirement: Broadcast no falla en room vacía

**Reason**: Propiedad del gestor de conexiones eliminado.

**Migration**: Ninguna.

### Requirement: Formato de mensaje

**Reason**: Contrato de mensajes del canal eliminado. Ningún productor del sistema emitía mensajes con ese formato.

**Migration**: Ninguna. Los eventos de dominio que la interfaz consume viajan como cambios de fila por Realtime del proveedor, con el formato que define esa integración.

### Requirement: Reconexión transparente

**Reason**: Propiedad del canal eliminado. Su mitad de cliente nunca fue verificable, porque ningún archivo del frontend se conectaba a este canal.

**Migration**: La reconexión real de la interfaz ocurre contra Realtime del proveedor y ya está cubierta por la capacidad de notificaciones en la aplicación, que exige resincronizar al reconectar.
