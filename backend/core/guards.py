from __future__ import annotations

from fastapi import HTTPException


def require_role(auth: dict, allowed: list[str]) -> None:
    if auth.get("role") not in allowed:
        raise HTTPException(
            status_code=403,
            detail=f"Rol insuficiente: se requiere {' o '.join(allowed)}",
        )


def require_plan(auth: dict, allowed_plans: list[str]) -> None:
    plan = auth.get("plan", "gratis")
    if plan not in allowed_plans:
        raise HTTPException(status_code=403, detail="Límite de plan alcanzado")


async def require_platform_admin(conn, auth: dict) -> None:
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
