from fastapi import HTTPException, Depends
from fastapi.security import OAuth2PasswordBearer
from jose import JWTError, jwt
from backend.core.config import settings

# T-12 [REFACTOR] — algorithm extracted as constant
ALGORITHM = "HS256"

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="token", auto_error=False)


async def get_current_user(token: str = Depends(oauth2_scheme)) -> dict:
    """Validate a Supabase-issued JWT and extract user_id + role.

    - Supports Bearer tokens (HTTP) and direct token string (WebSocket via query param).
    - verify_aud disabled: Supabase emits aud="authenticated" (non-URL string).
    """
    if not token:
        raise HTTPException(status_code=401, detail="Invalid token")
    try:
        payload = jwt.decode(
            token,
            settings.supabase_jwt_secret,
            algorithms=[ALGORITHM],
            options={"verify_aud": False},
        )
        return {
            "user_id": payload["sub"],
            "role": payload.get("role", "authenticated"),
        }
    except JWTError:
        raise HTTPException(status_code=401, detail="Invalid token")
