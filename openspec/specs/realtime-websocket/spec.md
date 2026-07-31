# realtime-websocket — Spec

## Purpose

Canal WebSocket para broadcast de eventos en tiempo real. Los clientes se suscriben a una "room" (por tenant/empresa) y reciben mensajes cuando ocurren eventos en el sistema.

## Requirements

### Requirement: Endpoint de conexión

El sistema SHALL exponer `WebSocket /ws/{room_id}`, donde `room_id` es el identificador de la room (ej: empresa UUID).

### Requirement: Autenticación obligatoria

La conexión SHALL fallar (close code 1008) si el query param `?token=` es inválido o ausente.

### Requirement: ConnectionManager por rooms

El `ConnectionManager` SHALL mantener un dict `{room_id: [WebSocket]}` y soportar `connect(room_id, ws)` (agrega ws a la room), `disconnect(room_id, ws)` (remueve ws; si la room queda vacía, limpia la key) y `broadcast(room_id, message: dict)` (envía a todos los ws de la room).

### Requirement: Broadcast no falla en room vacía

`broadcast` a un `room_id` sin clientes conectados SHALL NOT lanzar excepción.

### Requirement: Formato de mensaje

Los mensajes SHALL ser JSON con la forma `{"event": "string", "data": {}}`. El servidor SHALL validar que el mensaje sea JSON válido antes de procesar; los mensajes inválidos SHALL ser ignorados sin desconectar al cliente.

### Requirement: Reconexión transparente

El frontend SHALL poder reconectarse libremente, y el servidor SHALL tratar cada conexión como independiente (no hay estado de sesión persistente entre conexiones del mismo user).
