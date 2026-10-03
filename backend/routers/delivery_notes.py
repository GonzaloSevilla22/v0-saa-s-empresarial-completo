"""
Router del remito de venta (remitos-venta tanda A, D8/D13).

Routes:
  GET    /delivery-notes                    → listado paginado {items,total,page,pages} + summary
  POST   /delivery-notes                    → emisión: descuenta stock (Idempotency-Key obligatoria)
  GET    /delivery-notes/{id}               → detalle con líneas e historial
  PUT    /delivery-notes/{id}               → edición, reemplazo completo con `revision`
  POST   /delivery-notes/{id}/cancel        → anulación con motivo (repone stock; admin/owner)
  GET    /delivery-notes/{id}/pdf           → PDF (inline | attachment), sin precios por defecto

No hay `DELETE`: un remito nunca se borra, se anula. La conversión en venta
(`POST /delivery-notes/{id}/convert`) es de la tanda B.

Regla dura: routers hacen validación + DI únicamente. Toda la lógica de negocio
y los guards en services/delivery_notes.py.
"""
from __future__ import annotations

import uuid
from typing import Literal

import asyncpg
from fastapi import APIRouter, Depends, Query, Request, Response

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.core.deps import get_account_id
from backend.core.idempotency import require_idempotency_key
from backend.repositories.delivery_note_repository import DeliveryNoteRepository
from backend.schemas.delivery_notes import (
    DeliveryNoteCancelIn,
    DeliveryNoteCreateIn,
    DeliveryNoteOut,
    DeliveryNotePageOut,
    DeliveryNoteStatus,
    DeliveryNoteUpdateIn,
)
from backend.services import delivery_notes as delivery_notes_service

router = APIRouter(tags=["delivery-notes"])


# ── Dependency ────────────────────────────────────────────────────────────────

def get_delivery_note_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> DeliveryNoteRepository:
    return DeliveryNoteRepository(conn)


# ── Routes ────────────────────────────────────────────────────────────────────

@router.get("/delivery-notes", response_model=DeliveryNotePageOut)
async def list_delivery_notes(
    page: int = Query(0, ge=0),
    page_size: int = Query(25, ge=1, le=100),
    direction: Literal["sale", "purchase"] | None = Query(
        None, description="sentido del remito; sin él, trae los dos (lo usa el diálogo de baja de sucursal)"
    ),
    status: DeliveryNoteStatus | None = Query(None),
    client_id: uuid.UUID | None = Query(None),
    branch_id: uuid.UUID | None = Query(None),
    q: str | None = Query(None, max_length=100, description="nombre del cliente o número (R-12, 12, 00000012)"),
    auth: dict = Depends(get_current_user),
    repo: DeliveryNoteRepository = Depends(get_delivery_note_repo),
    account_id: uuid.UUID = Depends(get_account_id),
):
    """Listado paginado del recorte pedido, más `summary` con los remitos
    pendientes (`issued`) del mismo recorte sin importar el estado."""
    return await delivery_notes_service.list_delivery_notes(
        repo,
        str(account_id),
        page=page,
        page_size=page_size,
        direction=direction,
        status=status.value if status is not None else None,
        client_id=str(client_id) if client_id is not None else None,
        branch_id=str(branch_id) if branch_id is not None else None,
        q=q,
    )


@router.post("/delivery-notes", response_model=DeliveryNoteOut, status_code=201)
async def create_delivery_note(
    request: Request,
    response: Response,
    payload: DeliveryNoteCreateIn,
    auth: dict = Depends(get_current_user),
    repo: DeliveryNoteRepository = Depends(get_delivery_note_repo),
    conn: asyncpg.Connection = Depends(get_db_conn),
    account_id: uuid.UUID = Depends(get_account_id),
):
    """Emite el remito: lo numera, descuenta el stock de la sucursal y lo deja
    `issued`. Requiere `CAN_DELIVER_SALE`.

    La emisión mueve stock, así que es idempotente: `Idempotency-Key` por header,
    OBLIGATORIA (sin ella → 422 `idempotency_key_required`; el cuerpo no la
    acepta). Un reintento con la misma clave responde 200 con el mismo remito y
    `replayed: true`, sin escribir nada; la misma clave sobre otra operación → 409
    `idempotency_key_conflict`. Sin stock suficiente en la sucursal → 409
    `stock_insuficiente` sin efecto alguno.
    """
    key = await require_idempotency_key(request, None)
    record = await delivery_notes_service.create_delivery_note(
        repo, auth, str(account_id), payload, key, conn=conn
    )
    if record.get("replayed"):
        response.status_code = 200
    return record


@router.get("/delivery-notes/{delivery_note_id}", response_model=DeliveryNoteOut)
async def get_delivery_note(
    delivery_note_id: uuid.UUID,
    auth: dict = Depends(get_current_user),
    repo: DeliveryNoteRepository = Depends(get_delivery_note_repo),
    account_id: uuid.UUID = Depends(get_account_id),
):
    return await delivery_notes_service.get_delivery_note_detail(repo, str(account_id), str(delivery_note_id))


@router.put("/delivery-notes/{delivery_note_id}", response_model=DeliveryNoteOut)
async def update_delivery_note(
    delivery_note_id: uuid.UUID,
    payload: DeliveryNoteUpdateIn,
    auth: dict = Depends(get_current_user),
    repo: DeliveryNoteRepository = Depends(get_delivery_note_repo),
    conn: asyncpg.Connection = Depends(get_db_conn),
    account_id: uuid.UUID = Depends(get_account_id),
):
    """Edición (reemplazo completo) mientras el remito no esté convertido ni
    anulado. `revision` es la versión que el usuario vio: otra versión → 409
    `delivery_note_changed`. La edición no lleva `Idempotency-Key`: la protege la
    versión esperada (un reenvío llega con la versión vieja y rebota sin
    efectos)."""
    return await delivery_notes_service.update_delivery_note(
        repo, auth, str(account_id), str(delivery_note_id), payload, conn=conn
    )


@router.post("/delivery-notes/{delivery_note_id}/cancel", response_model=DeliveryNoteOut)
async def cancel_delivery_note(
    delivery_note_id: uuid.UUID,
    payload: DeliveryNoteCancelIn,
    auth: dict = Depends(get_current_user),
    repo: DeliveryNoteRepository = Depends(get_delivery_note_repo),
    conn: asyncpg.Connection = Depends(get_db_conn),
    account_id: uuid.UUID = Depends(get_account_id),
):
    """Anula el remito con motivo y repone al stock lo que retiene. Sólo
    admin/owner (`CAN_VOID_DELIVERY_NOTE`, sensible: decide la base). Tampoco
    lleva `Idempotency-Key`: la protege la versión esperada y el estado (una
    segunda anulación → 409 `delivery_note_invalid_state`)."""
    return await delivery_notes_service.cancel_delivery_note(
        repo, auth, str(account_id), str(delivery_note_id), payload, conn=conn
    )


@router.get("/delivery-notes/{delivery_note_id}/pdf")
async def get_delivery_note_pdf(
    delivery_note_id: uuid.UUID,
    disposition: Literal["inline", "attachment"] = "inline",
    show_prices: bool = False,
    auth: dict = Depends(get_current_user),
    repo: DeliveryNoteRepository = Depends(get_delivery_note_repo),
    account_id: uuid.UUID = Depends(get_account_id),
) -> Response:
    """PDF del remito (capability `commercial-document-pdf`): lectura de cualquier
    miembro, en cualquier estado, SIN precios salvo `show_prices=true`. 404
    idéntico para uno de otra cuenta y para uno inexistente; 422 con un parámetro
    inválido. `no-store`: lleva datos del cliente y no debe quedar en cachés
    compartidas."""
    pdf, filename = await delivery_notes_service.get_delivery_note_pdf(
        repo, str(account_id), str(delivery_note_id), show_prices=show_prices
    )
    return Response(
        content=pdf,
        media_type="application/pdf",
        headers={
            "Content-Disposition": f'{disposition}; filename="{filename}"',
            "Cache-Control": "private, no-store",
        },
    )
