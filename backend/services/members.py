from __future__ import annotations

from fastapi import HTTPException

from backend.core.errors import ProblemHTTPException
from backend.core.guards import require_account_role
from backend.core.rbac import CAN_CONFIGURE
from backend.repositories.member_repository import MemberRepository


async def list_members(repo: MemberRepository, auth: dict, account_id: str) -> list[dict]:
    """Lista los miembros de la cuenta con sus roles. Disponible a CUALQUIER
    miembro (account-membership-roles: "la lectura no se restringe por
    rol") — el guard de tenencia lo hace el propio rpc_list_account_members,
    no hay guard de capacidad acá."""
    return await repo.list_members(account_id)


async def assign_role(
    repo: MemberRepository,
    auth: dict,
    account_id: str,
    target_user_id: str,
    role: str,
    expires_at,
    *,
    conn,
) -> dict:
    """Asigna un rol del catálogo a un miembro. Requiere CAN_CONFIGURE
    (owner/admin de TENANT) como primer filtro barato en el backend — la
    distinción MÁS FINA (un admin nunca otorga owner/admin, tenencia,
    catálogo, owner sin vencimiento) la hace rpc_assign_member_role del lado
    de la base, propagando su propio P04xx si corresponde."""
    await require_account_role(conn, auth, CAN_CONFIGURE)
    return await repo.assign_role(account_id, target_user_id, role, expires_at)


async def revoke_role(
    repo: MemberRepository,
    auth: dict,
    account_id: str,
    target_user_id: str,
    role: str,
    *,
    conn,
) -> dict:
    """Revoca un rol de un miembro. Mismo criterio de guard que assign_role."""
    await require_account_role(conn, auth, CAN_CONFIGURE)
    return await repo.revoke_role(account_id, target_user_id, role)


async def remove_member(
    repo: MemberRepository,
    auth: dict,
    account_id: str,
    target_user_id: str,
    *,
    conn,
) -> dict:
    """Quita a un miembro por completo de la cuenta (rpc_remove_member,
    Parte A, sin cambios). Ese RPC usa el contrato LEGACY {ok}|{error} (no
    lanza excepción) -- se traduce acá a un HTTPException 403 para que el
    resto del pipeline de errores (RFC 7807) lo maneje igual que cualquier
    otro rechazo de autorización.

    Ronda 1 adversarial (finding MINOR): `rpc_remove_member` hace un DELETE
    sin verificar tenencia -- para un `target_user_id` que NO es miembro de
    esta cuenta devolvía `{ok:true}` (0 filas afectadas, sin señal), un 200
    que miente. `assign_role`/`revoke_role` (mismo router) SÍ devuelven
    404/P0404 para el mismo caso -- se pre-chequea la tenencia acá para
    quedar consistente, sin tocar la RPC de la Parte A."""
    await require_account_role(conn, auth, CAN_CONFIGURE)
    if not await repo.member_exists(account_id, target_user_id):
        raise ProblemHTTPException(
            status_code=404,
            detail="El usuario no es miembro de esta cuenta",
            code="P0404",
        )
    result = await repo.remove_member(account_id, target_user_id)
    if result.get("error"):
        raise HTTPException(status_code=403, detail=result["error"])
    return result
