import pytest
from unittest.mock import AsyncMock
from backend.core.ws_manager import ConnectionManager


@pytest.mark.asyncio
async def test_connect_disconnect_leaves_room_empty():
    manager = ConnectionManager()
    ws = AsyncMock()
    ws.accept = AsyncMock()
    await manager.connect("room-1", ws)
    assert "room-1" in manager.active
    manager.disconnect("room-1", ws)
    assert "room-1" not in manager.active


@pytest.mark.asyncio
async def test_broadcast_sends_to_connected_client():
    manager = ConnectionManager()
    ws = AsyncMock()
    ws.accept = AsyncMock()
    await manager.connect("room-1", ws)
    await manager.broadcast("room-1", {"event": "test", "data": {}})
    ws.send_json.assert_called_once_with({"event": "test", "data": {}})


# T-15 [TRIANGULATE] — broadcast to empty room does not raise
@pytest.mark.asyncio
async def test_broadcast_to_empty_room_does_not_raise():
    manager = ConnectionManager()
    await manager.broadcast("nonexistent-room", {"event": "test", "data": {}})
    # No exception raised
