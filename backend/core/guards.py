from __future__ import annotations

import hmac
from typing import Collection

from fastapi import HTTPException, Request

from backend.core import config
from backend.core.auth import AuthContext
from backend.core.errors import ProblemHTTPException
from backend.core.rbac import is_sensitive_capability


_BEARER = "Bearer "


def require_relay_secret(request: Request) -> None:
    """Dependencia de los endpoints de MÁQUINA que dispara `pg_cron` vía
    `pg_net` (relay del CAE `POST /fiscal/documents/process-pending-cron` y
    barrido de suscripciones `POST /payments/subscriptions/reconcile-cron`).

    Autenticación sólo por secreto compartido — `Authorization: Bearer
    <RELAY_SECRET>`, el mismo valor que Vault guarda como `cae_relay_secret`
    — nunca por JWT. Fail-closed: sin `RELAY_SECRET` configurado (None o
    vacío) se rechaza TODO, sin cabecera o con un secreto distinto → 401.
    Comparación en tiempo constante (`hmac.compare_digest`).

    mp-cuota-acreditacion-resiliente D5 / OQ-2 (a): extraída del inline de
    `routers/fiscal.py` para que los dos endpoints compartan UNA sola
    verificación. `settings` se lee de `config` en cada llamada (no se
    importa el nombre): así un `patch("backend.core.config.settings")`
    alcanza a esta función igual que antes alcanzaba al router."""
    configured_secret = config.settings.relay_secret
    if not configured_secret:
        raise HTTPException(status_code=401, detail="Relay secret not configured")

    auth_header = request.headers.get("Authorization", "") or ""
    if not auth_header.startswith(_BEARER):
        raise HTTPException(status_code=401, detail="Missing Authorization header")

    # bytes y no str: `compare_digest` con un str no-ASCII lanza TypeError
    # (→ 500) en vez de rechazar; una cabecera arbitraria nunca debe dar 5xx.
    provided_secret = auth_header[len(_BEARER):].encode("utf-8")
    if not hmac.compare_digest(provided_secret, configured_secret.encode("utf-8")):
        raise HTTPException(status_code=401, detail="Invalid relay secret")


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


async def require_account_role(conn, auth: AuthContext, allowed: Collection[str]) -> None:
    """Gating de rol de TENANT, evaluando el CONJUNTO de roles activos del
    actor (v3-rbac-multirole Parte B, D10) — autoriza si INTERSECA `allowed`
    con al menos un rol.

    Orden de resolución (D10, task 10.2 — nunca concede sin ninguna de las
    tres vías):
      0. multiusuario-operativo (D4): los claims de rol SÓLO valen si el token
         DECLARA la cuenta que describen (`account_id` en el contexto). Un token
         sin él —emitido antes del deploy, vive a lo sumo 15 minutos— trae claims
         de la membresía más antigua, que bajo multi-membresía puede no ser la
         cuenta sobre la que SQL va a operar: autorizar con ellos sería autorizar
         sobre una cuenta y escribir en otra. Sin `account_id` se saltean (1) y (2)
         y se resuelve contra la base (3), cuyo `rpc_my_active_account_roles()` ya
         devuelve los roles en la cuenta ACTIVA.
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

    EXCEPCIÓN — acciones de configuración (auth-hardening-jwt-cookies D12):
    cuando `allowed` es una capacidad SENSIBLE declarada en
    `backend/core/rbac.py::SENSITIVE_CAPABILITIES`, el orden de arriba NO
    aplica: se consulta la base AUNQUE el claim esté presente, y se decide
    con lo que devuelve la base. Para esas acciones el claim es un caché y la
    base es la autoridad, así que un rol revocado o vencido deja de autorizar
    sin esperar a la próxima emisión de token.

    Por qué sólo ahí (OQ-4): consultar siempre sería más seguro y más caro —
    una query por request en el hot path del POS para cerrar una ventana que
    el PO ya aceptó con sign-off para el resto de las superficies. Las
    acciones de configuración son pocas, poco frecuentes y las de mayor daño.

    Sin ninguna de las tres vías (o con roles resueltos que no intersecan
    `allowed`) → 403. La ausencia de información NUNCA se resuelve
    concediendo un rol permisivo — mismo principio que `require_platform_admin`
    aplica para el rol de plataforma cuando ese claim tampoco viaja en el
    token.
    """
    if is_sensitive_capability(allowed):
        row = await conn.fetchval("SELECT public.rpc_my_active_account_roles()")
        account_roles = list(row) if row else []
        _assert_intersects(account_roles, allowed)
        return

    # (0) Los claims de rol sólo describen la cuenta activa si el token la declara.
    token_declares_account = bool(auth.get("account_id"))
    account_roles = auth.get("account_roles") if token_declares_account else None

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

    if account_roles is None and token_declares_account:
        single = auth.get("account_role")
        account_roles = [single] if single is not None else None

    if account_roles is None:
        row = await conn.fetchval("SELECT public.rpc_my_active_account_roles()")
        account_roles = list(row) if row else []

    _assert_intersects(account_roles, allowed)


async def require_account_capability(conn, auth: AuthContext, allowed: Collection[str]) -> None:
    """`require_account_role` con el 403 como RFC 7807 y `code` estable `insufficient_role`.

    `require_account_role` levanta un `HTTPException` plano, que el handler global aplanaría a
    `code="http_error"`. Los endpoints que además llaman una RPC con su propio guard de rol (la RPC
    lanza `P0403 insufficient_role`) usan ésta, así el 403 del servicio y el de la base son el MISMO
    problema para el frontend. Tercera copia de este envoltorio (`services/quotes.py` y
    `services/delivery_notes.py` tienen la suya, sin migrar: candidato de limpieza)."""
    try:
        await require_account_role(conn, auth, allowed)
    except HTTPException as exc:
        if exc.status_code == 403 and not isinstance(exc, ProblemHTTPException):
            raise ProblemHTTPException(
                status_code=403, detail=str(exc.detail), code="insufficient_role"
            ) from exc
        raise


async def has_account_role(conn, auth: AuthContext, allowed: Collection[str]) -> bool:
    """¿El actor tiene alguna de las capacidades `allowed` en la cuenta activa? La misma resolución que
    `require_account_role` (mismas tres vías, y la base como autoridad para las capacidades sensibles) pero devolviendo un
    booleano en vez de lanzar 403: para los guards que DECIDEN según el rol en vez de cortar (edicion-operaciones-con-dinero,
    OQ-4)."""
    try:
        await require_account_role(conn, auth, allowed)
    except HTTPException as exc:
        if exc.status_code == 403:
            return False
        raise
    return True


def _assert_intersects(account_roles: list[str], allowed: Collection[str]) -> None:
    """Decisión final compartida por los dos caminos de `require_account_role`.

    Existe para que el camino sensible (D12) y el normal no puedan divergir en
    *cómo deciden* — sólo difieren en de dónde sacan `account_roles`.

    `sorted(allowed)`: las capacidades son `frozenset` desde D12 y el orden de
    iteración de un conjunto no es estable entre procesos. Sin ordenar, el
    mensaje que ve el usuario cambiaría de una corrida a otra.
    """
    if not any(role in allowed for role in account_roles):
        raise HTTPException(
            status_code=403,
            detail=f"Rol de cuenta insuficiente: se requiere {' o '.join(sorted(allowed))}",
        )


async def require_platform_admin(conn, auth: AuthContext) -> None:
    """Gating de admin de PLATAFORMA verificado contra la DB (profiles.role = 'admin').

    auth-hardening-jwt-cookies D12 (task 6.5) — este docstring estaba
    ENVEJECIDO y afirmaba lo contrario del código vivo. Decía "no existe
    custom access token hook", y el hook existe y está activo en producción:
    copia `profiles.role` a `app_metadata.role`
    (`20260827000001:151-153`), verificado en `auth_logs` desde el
    2026-08-01. La "Opción B" que este texto daba por pendiente YA ocurrió.

    Por qué el guard sigue consultando la base de todas formas, que es la
    parte que sí sigue siendo verdad y el motivo de que no se borre este
    texto: es el mismo principio de D12 llevado al rol de plataforma — el
    claim es un caché y la base es la autoridad para la decisión de mayor
    daño del sistema. Un `profiles.role` degradado deja de autorizar de
    inmediato, sin esperar a que venza el token que todavía lo declara.
    """
    role = await conn.fetchval(
        "SELECT role FROM profiles WHERE id = $1::uuid", auth["user_id"]
    )
    if role != "admin":
        raise HTTPException(
            status_code=403, detail="Rol insuficiente: se requiere admin"
        )
