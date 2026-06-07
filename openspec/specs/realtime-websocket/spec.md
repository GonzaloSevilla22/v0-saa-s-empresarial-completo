# Spec: realtime-websocket

## Overview

Canal WebSocket para broadcast de eventos en tiempo real. Los clientes se suscriben a una "room" (por tenant/empresa) y reciben mensajes cuando ocurren eventos en el sistema.

## Requirements

### REQ-WS-01: Endpoint de conexión
`WebSocket /ws/{room_id}` donde `room_id` es el identificador de la room (ej: empresa UUID).

### REQ-WS-02: Autenticación obligatoria
La conexión debe fallar (close code 1008) si el query param `?token=` es inválido o ausente.

### REQ-WS-03: ConnectionManager por rooms
El `ConnectionManager` debe mantener un dict `{room_id: [WebSocket]}` y soportar:
- `connect(room_id, ws)` — agrega ws a la room
- `disconnect(room_id, ws)` — remueve ws; si la room queda vacía, limpia la key
- `broadcast(room_id, message: dict)` — envía a todos los ws de la room

### REQ-WS-04: Broadcast no falla en room vacía
`broadcast` a un `room_id` sin clientes conectados no debe lanzar excepción.

### REQ-WS-05: Formato de mensaje
Mensajes son JSON:
```json
{"event": "string", "data": {}}
```
El servidor valida que el mensaje sea JSON válido antes de procesar. Mensajes inválidos son ignorados (sin desconectar al cliente).

### REQ-WS-06: Reconexión transparente
El frontend puede reconectarse libremente. El servidor trata cada conexión como independiente (no hay estado de sesión persistente entre conexiones del mismo user).
