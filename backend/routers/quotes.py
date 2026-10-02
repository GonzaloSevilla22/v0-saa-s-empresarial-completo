"""
Router del presupuesto (C-29 v21-quote-salesorder; reescrito por
presupuestos-modulo D2/D12).

Routes:
  GET    /quotes                    → listado paginado {items,total,page,pages}
  POST   /quotes                    → alta en `draft` (rpc_create_quote)
  GET    /quotes/{id}               → detalle con líneas e historial
  PUT    /quotes/{id}               → edición, reemplazo completo (rpc_update_quote)
  DELETE /quotes/{id}               → borra un borrador nunca enviado
  POST   /quotes/{id}/transition    → marcar enviado / rechazar
  GET    /quotes/{id}/pdf           → PDF (inline | attachment), cualquier estado
  GET    /settings/quotes           → validez por defecto de la cuenta
  PATCH  /settings/quotes           → fijarla (owner/admin); `PUT` es un alias

Se retiró `POST /quotes/{id}/accept` (D12): no tenía consumidores y dejaría un
presupuesto `accepted` —que en la interfaz significa "convertido en venta"—
con una orden `draft` que ninguna pantalla muestra. La única vía a `accepted` es
la conversión a venta.

Regla dura: routers hacen validación + DI únicamente. Toda la lógica de negocio
y los guards en services/quotes.py.
"""
from __future__ import annotations

import uuid
from typing import Literal

import asyncpg
from fastapi import APIRouter, Depends, Query, Response

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.core.deps import get_account_id
from backend.repositories.quote_repository import QuoteRepository
from backend.schemas.quotes import (
    QuoteIn,
    QuoteOut,
    QuotePageOut,
    QuoteSettingsIn,
    QuoteSettingsOut,
    QuoteStatus,
    QuoteTransitionIn,
    QuoteUpdateIn,
)
from backend.services import quotes as quotes_service

router = APIRouter(tags=["quotes"])
# Política comercial de la cuenta: hogar canónico en /settings/* (molde:
# /settings/collections).
settings_router = APIRouter(prefix="/settings/quotes", tags=["quotes"])


# ── Dependency ────────────────────────────────────────────────────────────────

def get_quote_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> QuoteRepository:
    return QuoteRepository(conn)


# ── Routes ────────────────────────────────────────────────────────────────────

@router.get("/quotes", response_model=QuotePageOut)
async def list_quotes(
    page: int = Query(0, ge=0),
    page_size: int = Query(25, ge=1, le=100),
    status: QuoteStatus | None = Query(
        None, description="estado efectivo: `expired` incluye los abiertos ya vencidos"
    ),
    client_id: uuid.UUID | None = Query(None),
    q: str | None = Query(None, max_length=100, description="nombre del cliente o número (P-12, 12, 00000012)"),
    auth: dict = Depends(get_current_user),
    repo: QuoteRepository = Depends(get_quote_repo),
    account_id: uuid.UUID = Depends(get_account_id),
):
    return await quotes_service.list_quotes(
        repo,
        str(account_id),
        page=page,
        page_size=page_size,
        status=status.value if status is not None else None,
        client_id=str(client_id) if client_id is not None else None,
        q=q,
    )


@router.post("/quotes", response_model=QuoteOut, status_code=201)
async def create_quote(
    payload: QuoteIn,
    auth: dict = Depends(get_current_user),
    repo: QuoteRepository = Depends(get_quote_repo),
    conn: asyncpg.Connection = Depends(get_db_conn),
    account_id: uuid.UUID = Depends(get_account_id),
):
    return await quotes_service.create_quote(repo, auth, str(account_id), payload, conn=conn)


@router.get("/quotes/{quote_id}", response_model=QuoteOut)
async def get_quote(
    quote_id: uuid.UUID,
    auth: dict = Depends(get_current_user),
    repo: QuoteRepository = Depends(get_quote_repo),
    account_id: uuid.UUID = Depends(get_account_id),
):
    return await quotes_service.get_quote_detail(repo, str(account_id), str(quote_id))


@router.put("/quotes/{quote_id}", response_model=QuoteOut)
async def update_quote(
    quote_id: uuid.UUID,
    payload: QuoteUpdateIn,
    auth: dict = Depends(get_current_user),
    repo: QuoteRepository = Depends(get_quote_repo),
    conn: asyncpg.Connection = Depends(get_db_conn),
    account_id: uuid.UUID = Depends(get_account_id),
):
    return await quotes_service.update_quote(
        repo, auth, str(account_id), str(quote_id), payload, conn=conn
    )


@router.delete("/quotes/{quote_id}", status_code=204)
async def delete_quote(
    quote_id: uuid.UUID,
    auth: dict = Depends(get_current_user),
    repo: QuoteRepository = Depends(get_quote_repo),
    conn: asyncpg.Connection = Depends(get_db_conn),
    account_id: uuid.UUID = Depends(get_account_id),
) -> Response:
    await quotes_service.delete_quote(repo, auth, str(account_id), str(quote_id), conn=conn)
    return Response(status_code=204)


@router.post("/quotes/{quote_id}/transition", response_model=QuoteOut)
async def transition_quote(
    quote_id: uuid.UUID,
    payload: QuoteTransitionIn,
    auth: dict = Depends(get_current_user),
    repo: QuoteRepository = Depends(get_quote_repo),
    conn: asyncpg.Connection = Depends(get_db_conn),
    account_id: uuid.UUID = Depends(get_account_id),
):
    return await quotes_service.transition_quote(
        repo, auth, str(account_id), str(quote_id), payload, conn=conn
    )


@router.get("/quotes/{quote_id}/pdf")
async def get_quote_pdf(
    quote_id: uuid.UUID,
    disposition: Literal["inline", "attachment"] = "inline",
    auth: dict = Depends(get_current_user),
    repo: QuoteRepository = Depends(get_quote_repo),
    account_id: uuid.UUID = Depends(get_account_id),
) -> Response:
    """PDF del presupuesto (capability `commercial-document-pdf`): lectura de
    cualquier miembro, en cualquier estado. 404 idéntico para uno de otra cuenta
    y para uno inexistente; 422 con `disposition` inválido. `no-store`: lleva
    datos del cliente y no debe quedar en cachés compartidas."""
    pdf, filename = await quotes_service.get_quote_pdf(repo, str(account_id), str(quote_id))
    return Response(
        content=pdf,
        media_type="application/pdf",
        headers={
            "Content-Disposition": f'{disposition}; filename="{filename}"',
            "Cache-Control": "private, no-store",
        },
    )


# ── Configuración: validez por defecto ───────────────────────────────────────

@settings_router.get("", response_model=QuoteSettingsOut)
async def get_quote_settings(
    auth: dict = Depends(get_current_user),
    repo: QuoteRepository = Depends(get_quote_repo),
    account_id: uuid.UUID = Depends(get_account_id),
):
    """Validez por defecto de los presupuestos de la cuenta (1..365 días)."""
    return await quotes_service.get_quote_settings(repo, str(account_id))


@settings_router.put("", response_model=QuoteSettingsOut, include_in_schema=False)
@settings_router.patch("", response_model=QuoteSettingsOut)
async def set_quote_settings(
    payload: QuoteSettingsIn,
    auth: dict = Depends(get_current_user),
    repo: QuoteRepository = Depends(get_quote_repo),
    conn: asyncpg.Connection = Depends(get_db_conn),
):
    """Fija la validez por defecto vía `rpc_set_default_quote_validity`. Sólo
    owner/admin. Fuera de 1..365 → 422 en el schema, sin tocar la base. `PATCH`
    es el verbo del molde (`/settings/collections`); `PUT` responde igual."""
    return await quotes_service.set_quote_settings(repo, auth, payload, conn=conn)
