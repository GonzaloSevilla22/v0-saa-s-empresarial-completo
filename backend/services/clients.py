from __future__ import annotations

from fastapi import HTTPException

from backend.core.guards import require_role
from backend.repositories.client_repository import ClientRepository
from backend.repositories.plan_limits_repository import PlanLimitsRepository
from backend.schemas.clients import ClientCreate, ClientUpdate

_EMPTY_SUMMARY = {
    "purchase_count": 0,
    "total_spent": 0,
    "last_purchase_date": None,
    "days_since_last_purchase": None,
}


async def list_clients(repo: ClientRepository, account_id: str) -> list:
    return await repo.list_by_org(account_id)


async def get_client(repo: ClientRepository, account_id: str, client_id: str) -> dict:
    record = await repo.get_by_id(client_id, account_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Cliente no encontrado")
    return dict(record)


async def create_client(
    repo: ClientRepository,
    auth: dict,
    account_id: str,
    payload: ClientCreate,
    plan_limits_repo: PlanLimitsRepository,
) -> dict:
    require_role(auth, ["user", "admin"])
    plan = auth.get("plan", "pro")
    limits = await plan_limits_repo.get_limits(plan)
    limit = limits["max_clients"]
    current_count = await repo.count_by_org(account_id)
    if current_count >= limit:
        raise HTTPException(
            status_code=403,
            detail=f"Límite de clientes alcanzado para el plan {plan} ({limit} máx.). Borrá clientes existentes o subí de plan.",
        )
    record = await repo.create(auth["user_id"], account_id, payload.model_dump())
    if record is None:
        raise HTTPException(status_code=500, detail="Error al crear el cliente")
    return dict(record)


async def update_client(
    repo: ClientRepository, auth: dict, account_id: str, client_id: str, payload: ClientUpdate
) -> dict:
    require_role(auth, ["user", "admin"])
    patch = payload.model_dump(exclude_none=True)
    # cobranzas-vencimientos (D14): el plazo es tri-estado — solo viaja si el
    # caller lo informo (model_fields_set), incluido el None explicito para
    # limpiarlo (volver a heredar). Omitirlo en el PUT NUNCA lo borra: es el
    # bug exacto de metodos-pago-operaciones/edicion-preserva-contexto.
    if "payment_terms_days" in payload.model_fields_set:
        patch["payment_terms_days"] = payload.payment_terms_days
    record = await repo.update(client_id, account_id, patch)
    if record is None:
        raise HTTPException(status_code=404, detail="Cliente no encontrado")
    return dict(record)


async def delete_client(repo: ClientRepository, auth: dict, account_id: str, client_id: str) -> None:
    """v3-soft-delete-policy: borrado soft (RN-B1/RN-B2) — la fila persiste
    con deleted_at + deleted_by y sale de todas las lecturas por defecto."""
    require_role(auth, ["user", "admin"])
    existing = await repo.get_by_id(client_id, account_id)
    if existing is None:
        raise HTTPException(status_code=404, detail="Cliente no encontrado")
    await repo.soft_delete("clients", client_id, account_id, auth["user_id"])


# ── clientes-frecuentes-historial ────────────────────────────────────────────


async def list_client_activity(
    repo: ClientRepository,
    account_id: str,
    *,
    page: int,
    size: int,
    search: str | None = None,
    activity_status: str | None = None,
    sort: str = "last_purchase",
    sort_dir: str = "desc",
) -> dict:
    """client-activity §"Agregados de actividad por cliente": una sola
    consulta por página — el día de referencia se resuelve UNA vez acá vía
    `reporting_local_today()`, nunca con `now()`/huso del servidor."""
    today = await repo.get_reference_today()
    return await repo.list_activity_page(
        account_id,
        today=today,
        page=page,
        size=size,
        search=search,
        activity_status=activity_status,
        sort=sort,
        sort_dir=sort_dir,
    )


def _build_purchase_summary(row) -> dict:
    if row is None:
        return dict(_EMPTY_SUMMARY)
    data = dict(row)
    return {
        "purchase_count": data.get("purchase_count", 0),
        "total_spent": data.get("total_spent", 0),
        "last_purchase_date": data.get("last_purchase_date"),
        "days_since_last_purchase": data.get("days_since_last_purchase"),
    }


async def get_client_purchases(
    repo: ClientRepository,
    account_id: str,
    client_id: str,
    *,
    page: int,
    size: int,
) -> dict:
    """client-purchase-history §"Historial de compras del cliente" +
    §"Resumen acumulado": 404 RFC 7807 si el cliente no existe o es de otra
    organización (aislamiento). El resumen reutiliza `get_activity_for` — la
    misma definición de agregados que alimenta la lista — y se calcula sobre
    la totalidad de las operaciones, no sobre la página visible."""
    existing = await repo.get_by_id(client_id, account_id)
    if existing is None:
        raise HTTPException(status_code=404, detail="Cliente no encontrado")

    today = await repo.get_reference_today()
    summary_row = await repo.get_activity_for(client_id, account_id, today=today)
    page_result = await repo.list_purchases_page(client_id, account_id, page=page, size=size)
    return {**page_result, "summary": _build_purchase_summary(summary_row)}
