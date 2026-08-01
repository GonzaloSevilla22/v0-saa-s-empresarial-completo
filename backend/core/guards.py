from __future__ import annotations

from fastapi import HTTPException

from backend.core.auth import AuthContext


def require_role(auth: AuthContext, allowed: list[str]) -> None:
    if auth.get("role") not in allowed:
        raise HTTPException(
            status_code=403,
            detail=f"Rol insuficiente: se requiere {' o '.join(allowed)}",
        )


def require_plan(auth: AuthContext, allowed_plans: list[str]) -> None:
    plan = auth.get("plan", "gratis")
    if plan not in allowed_plans:
        raise HTTPException(status_code=403, detail="Límite de plan alcanzado")


async def require_account_role(conn, auth: AuthContext, allowed: list[str]) -> None:
    """Gating de rol de TENANT (account_members.role), con fallback a la DB
    durante la ventana de transición (v31-authz-token-hook D6).

    Prefiere el claim `account_role` del JWT — namespace de TENANT, separado
    del rol de plataforma que vive en `auth['role']` (D1). Si el claim está
    ausente (token emitido antes de habilitar el custom access token hook,
    todavía vigente hasta su refresh o re-login), resuelve contra la base
    con el MISMO criterio determinístico que `get_account_id`
    (backend/core/deps.py, D4): la membresía más antigua del usuario,
    desempatada por PK. Sin membresía resoluble por ninguna vía → 403.
    La ausencia de información NUNCA se resuelve concediendo un rol
    permisivo — mismo principio que `require_platform_admin` aplica para el
    rol de plataforma cuando ese claim tampoco viaja en el token.
    """
    account_role = auth.get("account_role")
    if account_role is None:
        account_role = await conn.fetchval(
            "SELECT role FROM account_members WHERE user_id = auth.uid() "
            "ORDER BY created_at, id LIMIT 1"
        )
    if account_role not in allowed:
        raise HTTPException(
            status_code=403,
            detail=f"Rol de cuenta insuficiente: se requiere {' o '.join(allowed)}",
        )


async def require_platform_admin(conn, auth: AuthContext) -> None:
    """Gating de admin de PLATAFORMA verificado contra la DB (profiles.role = 'admin').

    El rol app-level NO viaja en el JWT (no existe custom access token hook), así que
    auth['role'] siempre cae al fallback 'user' y `require_role(auth, ['admin'])`
    nunca puede pasar — ni siquiera para el admin real. El admin de plataforma vive
    en profiles.role, así que se verifica contra la DB, igual que payments.require_admin.

    (Opción A del fix v22: usar la fuente de verdad correcta. La Opción B —un hook que
    copie profiles.role al JWT— queda como follow-up porque exige re-login.)
    """
    role = await conn.fetchval(
        "SELECT role FROM profiles WHERE id = $1::uuid", auth["user_id"]
    )
    if role != "admin":
        raise HTTPException(
            status_code=403, detail="Rol insuficiente: se requiere admin"
        )
