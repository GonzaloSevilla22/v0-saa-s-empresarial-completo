from fastapi import WebSocket


class ConnectionManager:
    """Manages active WebSocket connections grouped by room_id.

    Rooms are cleaned up automatically when the last client disconnects.
    """

    def __init__(self):
        self.active: dict[str, list[WebSocket]] = {}

    async def connect(self, room_id: str, ws: WebSocket) -> None:
        """Accept and register a WebSocket connection in the given room."""
        await ws.accept()
        self.active.setdefault(room_id, []).append(ws)

    def disconnect(self, room_id: str, ws: WebSocket) -> None:
        """Remove a WebSocket from its room; purge the room key if empty."""
        room = self.active.get(room_id, [])
        if ws in room:
            room.remove(ws)
        if not room:
            self.active.pop(room_id, None)

    async def broadcast(self, room_id: str, message: dict) -> None:
        """Send a JSON message to all clients in a room.

        Does nothing (no exception) if the room does not exist or is empty.
        """
        for ws in self.active.get(room_id, []):
            await ws.send_json(message)


manager = ConnectionManager()
