from typing import TypedDict

from fastapi import HTTPException, Depends
from fastapi.security import OAuth2PasswordBearer
import jwt as pyjwt
from jwt import PyJWKClient, PyJWTError
from jwt.exceptions import PyJWKClientError
from backend.core.config import settings


class AuthContext(TypedDict):
    """Contrato tipado del contexto que produce `get_current_user`.

    Declaración normativa: cualquier clave que el dependency produzca debe
    estar acá, y cualquier clave declarada acá debe ser producida por el
    dependency (verificado por el test de contrato anti-deriva en
    backend/tests/test_auth.py). Las cuatro claves están siempre presentes:
    `user_id` viene de `payload["sub"]` (obligatorio en cualquier JWT de
    Supabase), y `role`/`plan` tienen fallback incondicional — por eso
    `total=True` (default) y no `NotRequired`.

    `role` (plataforma, profiles.role) y `account_role` (tenant,
    account_members.role) son DOS espacios de nombres separados —
    v31-authz-token-hook D1. Un guard NUNCA debe comparar uno contra los
    valores del otro. `account_role` es `str | None`: a diferencia de
    `role`/`plan`, no tiene un fallback permisivo — su ausencia (token sin
    el claim, o usuario sin membresía) se resuelve en el guard
    (`require_account_role`, backend/core/guards.py), nunca acá con un
    default optimista.

    `account_roles` (v3-rbac-multirole Parte B, D8): el CONJUNTO de roles de
    TENANT activos (vencidos ya excluidos por el hook al momento de emitir
    el token) — mismo namespace que `account_role`, del que es el superset.
    `list[str] | None`: `None` significa "el claim no viaja en este token"
    (token emitido antes de este change, o usuario sin membresía resuelta
    por el hook) y dispara el fallback en `require_account_role`; una lista
    VACÍA presente SÍ es una respuesta válida (sin roles activos) y NO cae
    al fallback — distinción deliberada, ver `require_account_role`.
    """

    user_id: str
    role: str
    account_role: str | None
    account_roles: list[str] | None
    plan: str


_jwks_client: PyJWKClient | None = None


def get_jwks_client() -> PyJWKClient:
    global _jwks_client
    if _jwks_client is None:
        jwks_url = f"{settings.supabase_url}/auth/v1/.well-known/jwks.json"
        _jwks_client = PyJWKClient(jwks_url, cache_keys=True)
    return _jwks_client


oauth2_scheme = OAuth2PasswordBearer(tokenUrl="token", auto_error=False)


def _decode_supabase_jwt(token: str) -> dict:
    """Valida y decodifica un JWT emitido por Supabase. Compartido por
    `get_current_user` y `get_claims_status` (v31-authz-token-hook D8) para
    que ambos caminos verifiquen el token EXACTAMENTE igual — dos
    implementaciones de decode divergirían silenciosamente.

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
    return payload


async def get_current_user(token: str = Depends(oauth2_scheme)) -> AuthContext:
    """Validate a Supabase-issued JWT and extract user_id + role."""
    payload = _decode_supabase_jwt(token)

    # Supabase JWTs always carry role="authenticated" (the Postgres role).
    # App-level role lives in app_metadata (set via custom access token hook),
    # or falls back to "user" for standard authenticated users.
    jwt_role = payload.get("role", "authenticated")
    app_metadata = payload.get("app_metadata") or {}
    app_role = app_metadata.get("role") or (
        "user" if jwt_role == "authenticated" else jwt_role
    )
    # v31-authz-token-hook D6: `plan` conserva el default "pro" SOLO como
    # valor de TRANSICIÓN mientras convivan tokens sin el claim (emitidos
    # antes de habilitar el hook, ~1h de ventana o hasta re-login) — ver
    # capability plan-gating. NO es la política definitiva: la ausencia de
    # información de plan NOT SHALL resolverse concediendo el plan más alto
    # de forma permanente. Este default se elimina cuando se cierre la
    # ventana de convivencia (post-activación + purga de tokens viejos).
    app_plan = app_metadata.get("plan", "pro")
    # account_role (tenant, D1): a diferencia de role/plan, SIN fallback
    # permisivo acá — su ausencia se resuelve en require_account_role
    # (DB fallback o 403), nunca con un default optimista en este punto.
    app_account_role = app_metadata.get("account_role")
    # account_roles (v3-rbac-multirole Parte B, D8): el CONJUNTO, si el hook
    # ya lo emite. `.get(...)` sin default: ausente -> None (dispara
    # fallback en el guard); presente -> la lista tal cual llegó del JWT
    # (jwt.decode ya la deserializa como list[str] desde el array JSON),
    # incluida una lista vacía real (sin roles activos).
    app_account_roles = app_metadata.get("account_roles")

    return {
        "user_id": payload["sub"],
        "role": app_role,
        "account_role": app_account_role,
        "account_roles": app_account_roles,
        "plan": app_plan,
    }


async def get_claims_status(token: str = Depends(oauth2_scheme)) -> dict:
    """Diagnóstico de presencia de claims (v31-authz-token-hook D8) — soporte
    de `GET /auth/claims-status`.

    Distingue "el claim viene en el JWT" de "el valor efectivo que el
    backend termina usando" (que puede venir de un fallback, D6). Es la
    única forma de verificar la activación del hook sin caer en la trampa
    documentada: el hook NUNCA escribe `auth.users.raw_app_metadata`, así
    que inspeccionar esa columna da SIEMPRE `false`, con o sin el hook
    activo — la única fuente de verdad es el JWT ya emitido, que es
    exactamente lo que este endpoint mira.

    SOLO para el usuario que llama — nunca se acepta un identificador de
    otro usuario, y nunca se devuelve el token ni su payload crudo.
    """
    payload = _decode_supabase_jwt(token)
    app_metadata = payload.get("app_metadata") or {}

    role_present = "role" in app_metadata
    account_role_present = "account_role" in app_metadata
    plan_present = "plan" in app_metadata
    # v3-rbac-multirole Parte B, ronda 1 adversarial (minor 4): el claim
    # nuevo del CONJUNTO (D8) — sin esto, la task 13.6 (verificar post-merge
    # que "el claim nuevo está presente") no tenía ningún instrumento de
    # primera mano: auth_logs sólo dice que el hook CORRIÓ, no qué claims
    # emitió, que es exactamente la distinción para la que se construyó este
    # endpoint (v31-authz-token-hook D8). NO se suma a `source` -- ese
    # cálculo se queda igual que antes (basado en los 3 claims legacy), para
    # no cambiar su semántica con tokens viejos que nunca van a tener
    # `account_roles`.
    account_roles_present = "account_roles" in app_metadata

    jwt_role = payload.get("role", "authenticated")
    effective_role = app_metadata.get("role") or (
        "user" if jwt_role == "authenticated" else jwt_role
    )
    effective_plan = app_metadata.get("plan", "pro")
    effective_account_role = app_metadata.get("account_role")
    effective_account_roles = app_metadata.get("account_roles")

    return {
        "role_claim_present": role_present,
        "account_role_claim_present": account_role_present,
        "account_roles_claim_present": account_roles_present,
        "plan_claim_present": plan_present,
        "effective_role": effective_role,
        "effective_account_role": effective_account_role,
        "effective_account_roles": effective_account_roles,
        "effective_plan": effective_plan,
        # "token": los tres claims viajan en el JWT (hook activo para este
        # usuario). "fallback": al menos uno se resolvió sin el claim — token
        # viejo (ventana de transición, D6) o hook todavía sin activar.
        "source": "token" if (role_present and account_role_present and plan_present) else "fallback",
    }
