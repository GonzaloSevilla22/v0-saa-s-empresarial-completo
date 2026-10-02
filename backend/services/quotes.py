"""
Service del presupuesto (C-29 v21-quote-salesorder; reescrito por
presupuestos-modulo D2/D11/D12).

Regla dura: NO lógica de negocio en routers. Acá viven los guards de rol y la
traducción de errores; las reglas de dominio (tenencia, estados, versión,
snapshots, numeración) viven en las RPCs `SECURITY DEFINER` y se invocan desde
el repositorio.

  - Crear, editar, enviar/rechazar y eliminar exigen `CAN_QUOTE` evaluado sobre
    el CONJUNTO de roles activos (`require_account_role`): un cajero recibe 403
    sin llegar a la RPC. La RPC lo vuelve a verificar antes de escribir (defensa
    en profundidad). Leer, ver el detalle y descargar el PDF es de cualquier
    miembro de la cuenta.
  - La validez por defecto es configuración de la cuenta: `CAN_CONFIGURE`, una
    capacidad sensible (la base es la autoridad del rol, no el claim).
  - Todo error de negocio de las RPCs sale como RFC 7807 con `code` = literal
    estable del RAISE (`quote_locked_converted`, `quote_changed`,
    `quote_not_deletable`, `insufficient_role`, …): es lo que el frontend
    traduce de forma accionable. Un sqlstate fuera del mapa no se disfraza: se
    re-lanza y el handler global lo resuelve como 500 genérico.
  - Se retiró `_VALID_TRANSITIONS`: la política de transiciones vive en el
    catálogo `document_status_transitions`, no duplicada en Python (el dict
    anterior contradecía al catálogo: no admitía `draft → rejected`).
  - Se retiró el pre-chequeo `client_belongs_to_account`: la tenencia del
    cliente la resuelve `rpc_create_quote` con `P0404 client_not_found`.
"""
from __future__ import annotations

import contextlib
import datetime
import logging
import uuid
from collections.abc import Collection

import asyncpg
from fastapi import HTTPException

from backend.core.errors import ProblemHTTPException, problem_from_pg_error
from backend.core.guards import require_account_role
from backend.core.rbac import CAN_CONFIGURE, CAN_QUOTE
from backend.core.timezone import today_in_argentina
from backend.repositories.quote_repository import QuoteRepository
from backend.schemas.quotes import (
    QuoteConvertIn,
    QuoteIn,
    QuoteItemIn,
    QuoteSettingsIn,
    QuoteTransitionIn,
    QuoteUpdateIn,
)
from backend.services.commercial_documents.issuer import resolve_commercial_issuer
from backend.services.commercial_documents.numbering import (
    format_internal_document_number,
    parse_internal_document_number_query,
)
from backend.services.commercial_documents.pdf import build_commercial_document_pdf
from backend.services.commercial_documents.view import build_quote_view

logger = logging.getLogger(__name__)

# Acción del contrato HTTP -> estado destino que admite `rpc_transition_quote`.
_ACTION_TO_STATUS = {"send": "sent", "reject": "rejected"}


# ── Guards y traducción de errores ───────────────────────────────────────────

async def _require_capability(conn, auth: dict, capability: Collection[str]) -> None:
    """Guard de rol de cuenta con el 403 como RFC 7807 y `code` estable.

    `require_account_role` levanta un `HTTPException` plano (que el handler
    global aplanaría a `code="http_error"`): acá se re-emite con
    `insufficient_role`, el mismo literal que usa la RPC cuando es ella quien
    rechaza por rol.
    """
    try:
        await require_account_role(conn, auth, capability)
    except HTTPException as exc:
        if exc.status_code == 403 and not isinstance(exc, ProblemHTTPException):
            raise ProblemHTTPException(
                status_code=403, detail=str(exc.detail), code="insufficient_role"
            ) from exc
        raise


@contextlib.contextmanager
def _pg_errors_as_problems():
    """Traduce los errores de negocio de las RPCs a RFC 7807 en un solo lugar."""
    try:
        yield
    except asyncpg.PostgresError as exc:
        problem = problem_from_pg_error(exc)
        if problem is None:
            raise
        raise problem from exc


def _uid(value: uuid.UUID | None) -> str | None:
    return str(value) if value is not None else None


def _present(record: dict) -> dict:
    """Agrega la etiqueta visible del número (`P-00000012`) a un registro."""
    return {**record, "number_label": format_internal_document_number("quote", record.get("number"))}


def _serialize_items(items: list[QuoteItemIn]) -> list[dict]:
    """Líneas del contrato HTTP -> `p_items` de las RPCs. Los importes viajan
    como texto exacto (sin pasar por float): el precio por unidad no se
    redondea (RN-24-bis)."""
    return [
        {
            "product_id": _uid(item.product_id),
            "unit_id": _uid(item.unit_id),
            "quantity": str(item.quantity),
            "price": str(item.price),
            "subtotal": str(item.subtotal),
            "description": item.description,
        }
        for item in items
    ]


async def _reload(repo: QuoteRepository, written: dict, fallback_account_id: str) -> dict:
    """Relee el presupuesto completo (cliente, líneas, historial) tras una
    escritura. La cuenta es la que devolvió la RPC —con varias cuentas, la del
    cliente es la que manda—, no la que se supuso."""
    account_id = str(written.get("account_id") or fallback_account_id)
    record = await repo.get_quote(str(written["id"]), account_id)
    if record is None:
        raise ProblemHTTPException(
            status_code=500,
            detail="El presupuesto se guardó pero no pudo leerse",
            code="quote_read_failed",
        )
    return _present(record)


# ── Escrituras ────────────────────────────────────────────────────────────────

async def create_quote(
    repo: QuoteRepository,
    auth: dict,
    account_id: str,
    payload: QuoteIn,
    *,
    conn,
) -> dict:
    """Alta en `draft`. Guard: `CAN_QUOTE`."""
    await _require_capability(conn, auth, CAN_QUOTE)
    with _pg_errors_as_problems():
        written = await repo.create_quote(
            client_id=str(payload.client_id),
            branch_id=_uid(payload.branch_id),
            valid_until=payload.valid_until,
            notes=payload.notes,
            items=_serialize_items(payload.items),
        )
    return await _reload(repo, written, account_id)


async def update_quote(
    repo: QuoteRepository,
    auth: dict,
    account_id: str,
    quote_id: str,
    payload: QuoteUpdateIn,
    *,
    conn,
) -> dict:
    """Edición (reemplazo completo) con la versión que se editó. Guard:
    `CAN_QUOTE`. `quote_changed` (409) si otro la modificó; `P0423
    quote_locked_converted` (409) si ya se convirtió en venta."""
    await _require_capability(conn, auth, CAN_QUOTE)
    with _pg_errors_as_problems():
        written = await repo.update_quote(
            quote_id,
            expected_revision=payload.revision,
            client_id=str(payload.client_id),
            branch_id=_uid(payload.branch_id),
            valid_until=payload.valid_until,
            notes=payload.notes,
            items=_serialize_items(payload.items),
        )
    return await _reload(repo, written, account_id)


async def transition_quote(
    repo: QuoteRepository,
    auth: dict,
    account_id: str,
    quote_id: str,
    payload: QuoteTransitionIn,
    *,
    conn,
) -> dict:
    """Marcar como enviado (`send`) o rechazar (`reject`, con motivo opcional).
    Guard: `CAN_QUOTE`. `accepted` y `expired` no se piden por acá (el schema
    ya los rechaza con 422)."""
    await _require_capability(conn, auth, CAN_QUOTE)
    with _pg_errors_as_problems():
        written = await repo.transition_quote(quote_id, _ACTION_TO_STATUS[payload.action], payload.reason)
    return await _reload(repo, written, account_id)


async def delete_quote(
    repo: QuoteRepository,
    auth: dict,
    account_id: str,
    quote_id: str,
    *,
    conn,
) -> None:
    """Borra un borrador nunca enviado. Guard: `CAN_QUOTE`. Cualquier otro
    estado -> 409 `quote_not_deletable`."""
    await _require_capability(conn, auth, CAN_QUOTE)
    with _pg_errors_as_problems():
        await repo.delete_quote(quote_id)


async def convert_quote(
    repo: QuoteRepository,
    auth: dict,
    account_id: str,
    quote_id: str,
    payload: QuoteConvertIn,
    *,
    conn,
) -> dict:
    """Convierte el presupuesto en venta, atómicamente (`rpc_convert_quote_to_sale`).

    Guard: `CAN_QUOTE`. Es la ÚNICA vía a `accepted` (el endpoint `accept` se
    retiró). Todo lo demás lo decide la RPC bajo el lock del presupuesto:
    tenencia de cada id del payload, estado, vencimiento, versión
    (`quote_changed`), convertibilidad (`quote_product_unavailable`,
    `quote_client_unavailable`, `product_is_parent`), stock (`stock_insuficiente`)
    e idempotencia (`idempotency_key_conflict` si la clave ya convirtió OTRO
    documento). Cualquier fallo revierte la aceptación y la orden: no queda un
    presupuesto `accepted` sin venta. Nada se pre-valida acá para no abrir una
    ventana entre el chequeo y el lock.

    `payload.idempotency_key` ya llega resuelto por el router (header > body).
    Un `ValueError` si no llegó es un bug de cableado, no un error del usuario:
    sin clave la conversión no es reintentable y se corta antes de la base.
    """
    if not payload.idempotency_key:
        raise ValueError("convert_quote: falta la clave de idempotencia resuelta por el router")
    await _require_capability(conn, auth, CAN_QUOTE)
    with _pg_errors_as_problems():
        result = await repo.convert_to_sale(
            quote_id,
            idempotency_key=payload.idempotency_key,
            expected_revision=payload.expected_revision,
            payment_method_id=str(payload.payment_method_id),
            branch_id=_uid(payload.branch_id),
            cash_session_id=_uid(payload.cash_session_id),
            bank_account_id=_uid(payload.bank_account_id),
            canal=payload.canal,
        )
    return {
        **result,
        "quote_number_label": format_internal_document_number("quote", result.get("quote_number")),
    }


# ── Lecturas ──────────────────────────────────────────────────────────────────

async def get_quote(repo: QuoteRepository, account_id: str, quote_id: str) -> dict:
    """Detalle scopeado a la cuenta del caller. Mismo 404 RFC 7807 para un id
    inexistente y para uno de otra cuenta (no revela si existe en otro tenant)."""
    record = await repo.get_quote(quote_id, account_id)
    if record is None:
        raise ProblemHTTPException(
            status_code=404, detail="Presupuesto no encontrado", code="quote_not_found"
        )
    return _present(record)


async def get_quote_detail(repo: QuoteRepository, account_id: str, quote_id: str) -> dict:
    """Detalle para `GET /quotes/{id}`: el presupuesto más `issuer_name`, el
    nombre del emisor ya resuelto por la MISMA cascada y la MISMA RPC que el
    encabezado del PDF (`resolve_commercial_issuer`). Es lo que firma el texto de
    WhatsApp: el perfil del usuario que comparte no sirve (un vendedor que no es
    el dueño no tiene negocio propio y el del dueño con nombre de fantasía fiscal
    difiere del que imprime el PDF). Adorno, no dato del documento: si la RPC
    falla el presupuesto se lee igual y el texto sale sin firma."""
    record = await get_quote(repo, account_id, quote_id)
    try:
        issuer = await resolve_commercial_issuer(repo, account_id)
        issuer_name: str | None = issuer.name
    except asyncpg.PostgresError:
        logger.warning("quote %s: no se pudo resolver el emisor para el texto compartido", quote_id, exc_info=True)
        issuer_name = None
    return {**record, "issuer_name": issuer_name}


async def list_quotes(
    repo: QuoteRepository,
    account_id: str,
    *,
    page: int,
    page_size: int,
    status: str | None,
    client_id: str | None,
    q: str | None,
) -> dict:
    """Envelope estándar `{items,total,page,pages}` (v3-api-standards §2).

    El texto del buscador se usa para el nombre del cliente y, si es un número
    de documento ("P-12", "12", "00000012"), también para el número.
    """
    rows, total = await repo.list_quotes(
        account_id,
        page=page,
        page_size=page_size,
        status=status,
        client_id=client_id,
        text=q,
        number=parse_internal_document_number_query(q),
    )
    pages = -(-total // page_size) if total > 0 else 0
    return {"items": [_present(r) for r in rows], "total": total, "page": page, "pages": pages}


async def get_quote_pdf(
    repo: QuoteRepository,
    account_id: str,
    quote_id: str,
    *,
    today: datetime.date | None = None,
) -> tuple[bytes, str]:
    """PDF del presupuesto (`GET /quotes/{id}/pdf`) y su nombre de archivo.

    Lectura de cualquier miembro, para cualquier estado (un presupuesto
    rechazado o vencido se puede volver a descargar, con su sello). El
    contenido sale de la base por la cuenta del caller —nunca del request—, con
    el mismo 404 para un id ajeno que para uno inexistente. El emisor se resuelve
    sin bloquear y siempre por `rpc_commercial_issuer` (ver
    `commercial_documents/issuer.py`). `today` es el día de negocio argentino;
    se inyecta sólo para fijarlo en los tests.
    """
    record = await get_quote(repo, account_id, quote_id)
    with _pg_errors_as_problems():
        issuer = await resolve_commercial_issuer(repo, account_id)
    view = build_quote_view(
        record,
        record["items"],
        {"name": record.get("client_name"), "tax_id": record.get("client_tax_id"), "phone": record.get("client_phone")},
        issuer,
        today or today_in_argentina(),
    )
    label = record["number_label"] or str(record["id"])[:8]
    return build_commercial_document_pdf(view), f"presupuesto-{label}.pdf"


# ── Configuración de la cuenta ────────────────────────────────────────────────

async def get_quote_settings(repo: QuoteRepository, account_id: str) -> dict:
    """Validez por defecto de los presupuestos. Lectura para todo miembro."""
    days = await repo.get_default_validity_days(account_id)
    if days is None:
        raise ProblemHTTPException(
            status_code=404, detail="Cuenta no encontrada", code="account_not_found"
        )
    return {"default_quote_validity_days": days}


async def set_quote_settings(
    repo: QuoteRepository,
    auth: dict,
    account_id: str,
    payload: QuoteSettingsIn,
    *,
    conn,
) -> dict:
    """Fija la validez por defecto de la cuenta del header (la misma que lee
    `get_quote_settings`). Sólo owner/admin (`CAN_CONFIGURE`, capacidad sensible:
    la base decide, no el claim). El rango 1..365 ya lo validó el schema (422)
    antes de la base; la RPC lo vuelve a validar."""
    await _require_capability(conn, auth, CAN_CONFIGURE)
    with _pg_errors_as_problems():
        days = await repo.set_default_validity_days(account_id, payload.default_quote_validity_days)
    return {"default_quote_validity_days": days}
