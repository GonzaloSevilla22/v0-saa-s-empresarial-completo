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
    """Gating de rol de TENANT, evaluando el CONJUNTO de roles activos del
    actor (v3-rbac-multirole Parte B, D10) — autoriza si INTERSECA `allowed`
    con al menos un rol.

    Orden de resolución (D10, task 10.2 — nunca concede sin ninguna de las
    tres vías):
      1. Claim del CONJUNTO `account_roles` del JWT (D8) — si la clave está
         PRESENTE (aunque sea `[]`), es la fuente de verdad: un conjunto
         vacío ya resuelto por el hook NO cae al fallback (D9: el claim
         gana sobre la DB).
      2. Si el claim del conjunto está AUSENTE (token emitido antes de que
         el hook emita `account_roles`), el claim SINGULAR `account_role`
         legacy como conjunto de uno (compatibilidad, D8/D19).
      3. Si TAMPOCO el singular viaja, resuelve contra la BASE las
         asignaciones VIGENTES del pivot (R6 — nunca la columna singular
         `account_members.role`) vía `rpc_my_active_account_roles()`
         (SECURITY DEFINER sin parámetro: resuelve auth.uid() internamente,
         nunca un member_id arbitrario — D3/D10 de la Parte A, "si se
         expone, con su propio guard de tenencia, nunca un GRANT desnudo").

    Sin ninguna de las tres vías (o con roles resueltos que no intersecan
    `allowed`) → 403. La ausencia de información NUNCA se resuelve
    concediendo un rol permisivo — mismo principio que `require_platform_admin`
    aplica para el rol de plataforma cuando ese claim tampoco viaja en el
    token.
    """
    account_roles = auth.get("account_roles")

    # Ronda 1 adversarial (nit 8): el claim `account_roles` debe ser una
    # LISTA -- un valor con otra forma (dict, str, int) nunca es una fuente
    # de verdad válida. Sin este chequeo, `any(role in allowed for role in
    # account_roles)` itera lo que sea que el claim traiga: un dict itera sus
    # CLAVES (podría autorizar por coincidencia de texto), un str itera sus
    # CARACTERES (idem), y un int no es iterable (TypeError -> 500 en vez de
    # 403). Tratar cualquier forma no-lista como "claim ausente" es
    # fail-closed y cae al resto del orden de resolución (singular -> DB),
    # nunca a una autorización ni a un 500.
    if account_roles is not None and not isinstance(account_roles, list):
        account_roles = None

    if account_roles is None:
        single = auth.get("account_role")
        account_roles = [single] if single is not None else None

    if account_roles is None:
        row = await conn.fetchval("SELECT public.rpc_my_active_account_roles()")
        account_roles = list(row) if row else []

    if not any(role in allowed for role in account_roles):
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
