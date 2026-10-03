"""
Router del remito de venta (remitos-venta tanda A, D8/D13) y del de compra
(remitos-compra tanda A, D13): una sola ruta por operación que despacha por el
`direction` del cuerpo (un cuerpo sin `direction` es de venta).

Routes:
  GET    /delivery-notes                    → listado paginado {items,total,page,pages} + summary
  POST   /delivery-notes                    → emisión: descuenta stock (venta) o suma stock (compra) (Idempotency-Key obligatoria)
  GET    /delivery-notes/{id}               → detalle con líneas e historial
  PUT    /delivery-notes/{id}               → edición, reemplazo completo con `revision` (otro sentido que el guardado → 409)
  POST   /delivery-notes/{id}/cancel        → anulación con motivo (repone stock en venta, lo resta en compra; admin/owner)
  POST   /delivery-notes/{id}/convert       → conversión atómica en venta, sin volver a mover stock (Idempotency-Key)
  GET    /delivery-notes/{id}/pdf           → PDF (inline | attachment), sin precios por defecto

No hay `DELETE`: un remito nunca se borra, se anula.

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
    DeliveryNoteConvertIn,
    DeliveryNoteConvertOut,
    DeliveryNoteCreateBody,
    DeliveryNoteOut,
    DeliveryNotePageOut,
    DeliveryNoteStatus,
    DeliveryNoteUpdateBody,
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
    supplier_id: uuid.UUID | None = Query(None, description="sólo los remitos de compra de este proveedor"),
    branch_id: uuid.UUID | None = Query(None),
    q: str | None = Query(
        None,
        max_length=100,
        description="cliente o proveedor, número del remito del proveedor, o número (R-12 / RC-12, 12, 00000012)",
    ),
    auth: dict = Depends(get_current_user),
    repo: DeliveryNoteRepository = Depends(get_delivery_note_repo),
    account_id: uuid.UUID = Depends(get_account_id),
):
    """Listado paginado del recorte pedido, más `summary` con los remitos
    pendientes (`issued`) del mismo recorte sin importar el estado. En el sentido
    compra el resumen suma `pending_missing_price_count`."""
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
        supplier_id=str(supplier_id) if supplier_id is not None else None,
    )


@router.post("/delivery-notes", response_model=DeliveryNoteOut, status_code=201)
async def create_delivery_note(
    request: Request,
    response: Response,
    payload: DeliveryNoteCreateBody,
    auth: dict = Depends(get_current_user),
    repo: DeliveryNoteRepository = Depends(get_delivery_note_repo),
    conn: asyncpg.Connection = Depends(get_db_conn),
    account_id: uuid.UUID = Depends(get_account_id),
):
    """Emite el remito: lo numera y lo deja `issued`. En venta (cuerpo sin
    `direction`, o `direction: "sale"`) descuenta el stock de la sucursal y requiere
    `CAN_DELIVER_SALE`; en compra (`direction: "purchase"`) SUMA el stock de la
    sucursal de destino y requiere `CAN_RECEIVE_PURCHASE`.

    La emisión mueve stock, así que es idempotente: `Idempotency-Key` por header,
    OBLIGATORIA (sin ella → 422 `idempotency_key_required`; el cuerpo no la
    acepta). Un reintento con la misma clave responde 200 con el mismo remito y
    `replayed: true`, sin escribir nada; la misma clave sobre otra operación → 409
    `idempotency_key_conflict`. En venta, sin stock suficiente en la sucursal →
    409 `stock_insuficiente` sin efecto alguno.
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
    payload: DeliveryNoteUpdateBody,
    auth: dict = Depends(get_current_user),
    repo: DeliveryNoteRepository = Depends(get_delivery_note_repo),
    conn: asyncpg.Connection = Depends(get_db_conn),
    account_id: uuid.UUID = Depends(get_account_id),
):
    """Edición (reemplazo completo) mientras el remito no esté convertido ni
    anulado. El sentido del cuerpo tiene que ser el del remito guardado (otro → 409
    `delivery_note_direction_mismatch`). `revision` es la versión que el usuario
    vio: otra versión → 409 `delivery_note_changed`. La edición no lleva `Idempotency-Key`: la protege la
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
    """Anula el remito con motivo y revierte lo que movió: repone al stock lo que
    retiene (venta) o resta lo que aportó (compra, y si ya se consumió → 409
    `delivery_note_stock_consumed` sin efectos). Sólo admin/owner
    (`CAN_VOID_DELIVERY_NOTE`, sensible: decide la base). Tampoco
    lleva `Idempotency-Key`: la protege la versión esperada y el estado (una
    segunda anulación → 409 `delivery_note_invalid_state`)."""
    return await delivery_notes_service.cancel_delivery_note(
        repo, auth, str(account_id), str(delivery_note_id), payload, conn=conn
    )


@router.post("/delivery-notes/{delivery_note_id}/convert", response_model=DeliveryNoteConvertOut)
async def convert_delivery_note(
    delivery_note_id: uuid.UUID,
    request: Request,
    payload: DeliveryNoteConvertIn,
    auth: dict = Depends(get_current_user),
    repo: DeliveryNoteRepository = Depends(get_delivery_note_repo),
    conn: asyncpg.Connection = Depends(get_db_conn),
    account_id: uuid.UUID = Depends(get_account_id),
):
    """Convierte el remito en venta en UNA transacción: crea la orden en la
    sucursal del remito y la confirma con los mismos efectos de caja, cuenta
    corriente, banco y eventos del POS, pero SIN volver a descontar stock (el
    remito ya lo retiró al emitirse). Requiere `CAN_SELL`. `expected_revision` es
    la versión que el usuario vio: otra versión → 409 `delivery_note_changed`.

    La conversión escribe dinero, así que es idempotente: `Idempotency-Key` por
    header, OBLIGATORIA (sin ella → 422 `idempotency_key_required`; el cuerpo no
    la acepta). Un reintento con la misma clave sobre el mismo remito responde
    200 con `replayed: true` y no escribe nada; la misma clave sobre otro
    documento → 409 `idempotency_key_conflict`. Un remito ya convertido o anulado
    → 409 `delivery_note_invalid_state`.
    """
    key = await require_idempotency_key(request, None)
    return await delivery_notes_service.convert_delivery_note(
        repo, auth, str(account_id), str(delivery_note_id), payload, key, conn=conn
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
