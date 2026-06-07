import json
from fastapi import APIRouter, WebSocket, WebSocketDisconnect, Query
from fastapi import HTTPException
import jwt as pyjwt
from jwt import PyJWTError
from backend.core.auth import get_jwks_client
from backend.core.ws_manager import manager

router = APIRouter()


async def _validate_ws_token(token: str | None) -> dict:
    """Validate a JWT passed as a WebSocket query param.

    WebSocket handshake does not support Authorization headers in browsers,
    so authentication is done via ?token= query param (REQ-BA-05).
    """
    if not token:
        raise HTTPException(status_code=401, detail="Invalid token")
    try:
        client = get_jwks_client()
        signing_key = client.get_signing_key_from_jwt(token)
        payload = pyjwt.decode(
            token,
            signing_key,
            algorithms=["ES256", "RS256"],
            options={"verify_aud": False},
        )
        return {
            "user_id": payload["sub"],
            "role": payload.get("role", "authenticated"),
        }
    except PyJWTError:
        raise HTTPException(status_code=401, detail="Invalid token")


@router.websocket("/ws/{room_id}")
async def websocket_endpoint(
    websocket: WebSocket,
    room_id: str,
    token: str = Query(default=None),
):
    """WebSocket endpoint for real-time broadcast per room.

    Auth: JWT passed as ?token= query param (close 1008 if invalid/absent).
    Messages: JSON objects { "event": str, "data": {} }. Invalid JSON is ignored.
    """
    try:
        await _validate_ws_token(token)
    except HTTPException:
        await websocket.close(code=1008)
        return

    await manager.connect(room_id, websocket)
    try:
        while True:
            data = await websocket.receive_text()
            try:
                msg = json.loads(data)
                await manager.broadcast(room_id, msg)
            except json.JSONDecodeError:
                pass  # invalid JSON ignored — client stays connected (REQ-WS-05)
    except WebSocketDisconnect:
        manager.disconnect(room_id, websocket)
