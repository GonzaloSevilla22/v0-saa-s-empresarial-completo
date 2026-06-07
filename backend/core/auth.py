from fastapi import HTTPException, Depends
from fastapi.security import OAuth2PasswordBearer
import jwt as pyjwt
from jwt import PyJWKClient, PyJWTError
from jwt.exceptions import PyJWKClientError
from backend.core.config import settings

_jwks_client: PyJWKClient | None = None


def get_jwks_client() -> PyJWKClient:
    global _jwks_client
    if _jwks_client is None:
        jwks_url = f"{settings.supabase_url}/auth/v1/.well-known/jwks.json"
        _jwks_client = PyJWKClient(jwks_url, cache_keys=True)
    return _jwks_client


oauth2_scheme = OAuth2PasswordBearer(tokenUrl="token", auto_error=False)


async def get_current_user(token: str = Depends(oauth2_scheme)) -> dict:
    """Validate a Supabase-issued JWT and extract user_id + role.

    Uses JWKS endpoint — supports ES256/RS256 (asymmetric signing).
    verify_aud disabled: Supabase emits aud="authenticated" (non-URL string).
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
    except (PyJWTError, PyJWKClientError):
        raise HTTPException(status_code=401, detail="Invalid token")
