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

    Production: uses JWKS (ES256/RS256) when supabase_url is configured.
    Dev/test: falls back to HS256 with supabase_jwt_secret when supabase_url is absent.
    verify_aud disabled: Supabase emits aud="authenticated" (non-URL string).
    """
    if not token:
        raise HTTPException(status_code=401, detail="Invalid token")
    try:
        supabase_url = settings.supabase_url
        if isinstance(supabase_url, str) and supabase_url.startswith("http"):
            client = get_jwks_client()
            signing_key = client.get_signing_key_from_jwt(token)
            payload = pyjwt.decode(
                token,
                signing_key,
                algorithms=["ES256", "RS256"],
                options={"verify_aud": False},
            )
        else:
            # Test/dev fallback: HS256 with shared secret
            payload = pyjwt.decode(
                token,
                settings.supabase_jwt_secret,
                algorithms=["HS256"],
                options={"verify_aud": False},
            )
    except (PyJWTError, PyJWKClientError):
        raise HTTPException(status_code=401, detail="Invalid token")

    # Supabase JWTs always carry role="authenticated" (the Postgres role).
    # App-level role lives in app_metadata (set via custom access token hook),
    # or falls back to "user" for standard authenticated users.
    jwt_role = payload.get("role", "authenticated")
    app_role = (
        (payload.get("app_metadata") or {}).get("role")
        or ("user" if jwt_role == "authenticated" else jwt_role)
    )
    app_plan = (payload.get("app_metadata") or {}).get("plan", "pro")

    return {
        "user_id": payload["sub"],
        "role": app_role,
        "plan": app_plan,
    }
