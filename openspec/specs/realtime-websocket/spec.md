# realtime-websocket — Spec

## Purpose

Canal WebSocket para broadcast de eventos en tiempo real. Los clientes se suscriben a una "room" (por tenant/empresa) y reciben mensajes cuando ocurren eventos en el sistema.

## Requirements

### Requirement: Endpoint de conexión

El sistema SHALL exponer `WebSocket /ws/{room_id}`, donde `room_id` es el identificador de la room (ej: empresa UUID).

#### Scenario: El backend declara el endpoint WebSocket parametrizado por room

- **WHEN** se inspecciona `backend/routers/ws.py`
- **THEN** el router declara `@router.websocket("/ws/{room_id}")` recibiendo `room_id` como parámetro de path y `token` como query param opcional, y `backend/main.py` registra `ws.router` en el startup de la app

> Nota de alcance: este canal está scaffoldeado y con tests unitarios, pero según DEC-16 (`knowledge-base/09_decisiones_y_supuestos.md`) NO se usa en producción — el frontend recibe eventos en tiempo real vía Supabase Realtime directo (`supabase.channel(...).on('postgres_changes')`), no vía este WebSocket. Ningún archivo bajo `frontend/` referencia `/ws/{room_id}`.

### Requirement: Autenticación obligatoria

La conexión SHALL fallar (close code 1008) si el query param `?token=` es inválido o ausente.

#### Scenario: Token ausente o inválido cierra la conexión con code 1008

- **WHEN** un cliente abre `WebSocket /ws/{room_id}` sin `?token=` o con un token que `_validate_ws_token` no puede verificar (JWKS, `PyJWTError`)
- **THEN** `websocket_endpoint` captura la `HTTPException` de `_validate_ws_token` y llama a `websocket.close(code=1008)` antes de registrar la conexión en el `ConnectionManager`

### Requirement: ConnectionManager por rooms

El `ConnectionManager` SHALL mantener un dict `{room_id: [WebSocket]}` y soportar `connect(room_id, ws)` (agrega ws a la room), `disconnect(room_id, ws)` (remueve ws; si la room queda vacía, limpia la key) y `broadcast(room_id, message: dict)` (envía a todos los ws de la room).

#### Scenario: connect agrega el ws a la room y disconnect limpia la key cuando queda vacía

- **WHEN** se llama `manager.connect("room-1", ws)` y luego `manager.disconnect("room-1", ws)` sobre `backend/core/ws_manager.py`
- **THEN** tras `connect`, `"room-1"` existe en `manager.active` con `ws` en su lista; tras `disconnect`, `"room-1"` ya no es una key de `manager.active` porque la lista quedó vacía — verificado por `test_connect_disconnect_leaves_room_empty` en `backend/tests/test_ws.py`

#### Scenario: broadcast envía el mensaje a todos los clientes conectados de la room

- **WHEN** se llama `manager.broadcast("room-1", {"event": "test", "data": {}})` con un ws conectado a `"room-1"`
- **THEN** ese ws recibe el mensaje vía `send_json`, verificado por `test_broadcast_sends_to_connected_client`

### Requirement: Broadcast no falla en room vacía

`broadcast` a un `room_id` sin clientes conectados SHALL NOT lanzar excepción.

#### Scenario: broadcast a una room inexistente no lanza excepción

- **WHEN** se llama `manager.broadcast("nonexistent-room", {"event": "test", "data": {}})` sin que esa room tenga clientes registrados
- **THEN** `self.active.get(room_id, [])` retorna una lista vacía y el `for` no itera nada, así que la llamada retorna sin lanzar excepción — verificado por `test_broadcast_to_empty_room_does_not_raise`

### Requirement: Formato de mensaje

Los mensajes SHALL ser JSON con la forma `{"event": "string", "data": {}}`. El servidor SHALL validar que el mensaje sea JSON válido antes de procesar; los mensajes inválidos SHALL ser ignorados sin desconectar al cliente.

#### Scenario: JSON inválido se ignora sin cerrar la conexión

- **WHEN** un cliente conectado a `/ws/{room_id}` envía un frame de texto que no parsea como JSON (`json.JSONDecodeError`)
- **THEN** `websocket_endpoint` captura la excepción, no reenvía nada (`pass`), y el `while True` sigue esperando el próximo mensaje sin cerrar el WebSocket

#### Scenario: JSON válido se reenvía a la room vía broadcast

- **WHEN** un cliente conectado envía `{"event": "stock_updated", "data": {"product_id": "abc"}}`
- **THEN** `json.loads` lo parsea correctamente y `websocket_endpoint` llama a `manager.broadcast(room_id, msg)`, reenviando el mensaje a todos los clientes de esa room

### Requirement: Reconexión transparente

El frontend SHALL poder reconectarse libremente, y el servidor SHALL tratar cada conexión como independiente (no hay estado de sesión persistente entre conexiones del mismo user).

#### Scenario: El servidor no persiste estado de sesión entre conexiones

- **WHEN** un cliente se conecta, se desconecta, y vuelve a conectar a la misma room con un nuevo token
- **THEN** `websocket_endpoint` vuelve a ejecutar `_validate_ws_token` desde cero (no hay cache de sesión ni de identidad entre llamadas) y `ConnectionManager` solo trackea la lista de sockets activos por `room_id` — sin ninguna estructura que asocie `user_id` a conexiones previas —, por lo que cada conexión es independiente de la anterior

> Nota de alcance: la mitad "el frontend SHALL poder reconectarse" no es verificable hoy — según DEC-16 el frontend de este repo no consume `/ws/{room_id}` en ningún punto (no hay `new WebSocket` ni referencia a esta ruta bajo `frontend/`); toda reconexión real de UI ocurre contra Supabase Realtime, fuera de este canal. El scenario de arriba documenta la propiedad de statelessness del lado servidor, que sí es real y verificable en `backend/core/ws_manager.py` y `backend/routers/ws.py`.
