"""
Router para C-29 v21-quote-salesorder — Quote endpoints.

Routes:
  GET  /quotes                    → listar presupuestos de la cuenta
  POST /quotes                    → crear presupuesto (status='draft')
  GET  /quotes/{id}               → obtener presupuesto por id
  POST /quotes/{id}/transition    → transicionar estado (send/reject/expire)
  POST /quotes/{id}/accept        → aceptar: crea SalesOrder con mismos ítems

Regla dura: routers hacen validación + DI únicamente.
Toda la lógica de negocio y guards en services/quotes.py.
"""
from __future__ import annotations

import uuid

import asyncpg
from fastapi import APIRouter, Depends

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.core.deps import get_account_id
from backend.repositories.quote_repository import QuoteRepository
from backend.schemas.quotes import QuoteIn, QuoteOut, QuoteTransitionIn
from backend.schemas.sales_orders import AcceptQuoteOut
from backend.services import quotes as quotes_service

router = APIRouter(tags=["quotes"])


# ── Dependency ────────────────────────────────────────────────────────────────

def get_quote_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> QuoteRepository:
    return QuoteRepository(conn)


# ── Routes ────────────────────────────────────────────────────────────────────

@router.get("/quotes", response_model=list[QuoteOut])
async def list_quotes(
    auth: dict = Depends(get_current_user),
    repo: QuoteRepository = Depends(get_quote_repo),
    account_id: uuid.UUID = Depends(get_account_id),
):
    return await quotes_service.list_quotes(repo, str(account_id))


@router.post("/quotes", response_model=QuoteOut, status_code=201)
async def create_quote(
    payload: QuoteIn,
    auth: dict = Depends(get_current_user),
    repo: QuoteRepository = Depends(get_quote_repo),
    account_id: uuid.UUID = Depends(get_account_id),
):
    return await quotes_service.create_quote(
        repo=repo,
        auth=auth,
        payload=payload,
        created_by=auth.get("sub", ""),
        account_id=str(account_id),
    )


@router.get("/quotes/{quote_id}", response_model=QuoteOut)
async def get_quote(
    quote_id: str,
    auth: dict = Depends(get_current_user),
    repo: QuoteRepository = Depends(get_quote_repo),
):
    return await quotes_service.get_quote(repo, quote_id)


@router.post("/quotes/{quote_id}/transition", response_model=QuoteOut)
async def transition_quote(
    quote_id: str,
    payload: QuoteTransitionIn,
    auth: dict = Depends(get_current_user),
    repo: QuoteRepository = Depends(get_quote_repo),
):
    return await quotes_service.transition_quote(repo, auth, quote_id, payload)


@router.post("/quotes/{quote_id}/accept", response_model=AcceptQuoteOut)
async def accept_quote(
    quote_id: str,
    auth: dict = Depends(get_current_user),
    repo: QuoteRepository = Depends(get_quote_repo),
):
    return await quotes_service.accept_quote(repo, auth, quote_id)
