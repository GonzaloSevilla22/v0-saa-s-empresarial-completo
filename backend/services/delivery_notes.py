"""
Service del remito de venta (remitos-venta tanda A, D4/D5/D13) y del de compra
(remitos-compra tanda A, D4-D6/D12/D13).

Regla dura: NO lógica de negocio en routers. Acá viven los guards de rol y la
traducción de errores; las reglas de dominio (tenencia, estados, versión,
stock, snapshots, numeración, idempotencia) viven en las RPCs `SECURITY
DEFINER` y se invocan desde el repositorio.

  - Emitir y editar exigen `CAN_DELIVER_SALE` (venta) o `CAN_RECEIVE_PURCHASE`
    (compra: el vendedor NO recibe mercadería), anular exige
    `CAN_VOID_DELIVERY_NOTE` en los dos sentidos y convertir en venta exige
    `CAN_SELL` (el cajero convierte pero no emite; el depósito emite pero no
    convierte), todas evaluadas sobre el CONJUNTO de roles activos
    (`require_account_role`): un cajero recibe 403 sin llegar a la RPC. Anular es
    una capacidad SENSIBLE (devuelve stock): la base manda y el claim no alcanza.
    La RPC vuelve a verificar el rol antes de escribir (defensa en profundidad,
    contra el mismo catálogo de la FSM). Leer, ver el detalle y descargar el PDF
    es de cualquier miembro de la cuenta.
  - Todo error de negocio de las RPCs sale como RFC 7807 con `code` = literal
    estable del RAISE (`delivery_note_changed`, `stock_insuficiente`,
    `delivery_note_locked_converted`, `insufficient_role`, …): es lo que el
    frontend traduce de forma accionable. Un sqlstate fuera del mapa no se
    disfraza: se re-lanza y el handler global lo resuelve como 500 genérico.
  - Un interbloqueo (`40P01`) con una venta o un remito concurrente sobre los
    mismos productos sale como 409 `concurrent_update_retry` (D4): la
    transacción revirtió entera y la emisión es idempotente, así que reintentar
    es seguro. Ningún código del backend reintenta solo.
  - Un `PUT` cuyo cuerpo es de un sentido distinto del que el remito tiene
    guardado sale como 409 `delivery_note_direction_mismatch`. La RPC de cada
    sentido sólo ve remitos del suyo y responde "no encontrado" al otro, y no se
    puede distinguir DESPUÉS: el error de una RPC aborta la transacción del
    request y cualquier lectura posterior falla con `InFailedSQLTransaction`. Por
    eso el sentido guardado se lee ANTES de llamar a la RPC (una lectura mínima,
    con la cuenta del caller y después del guard de rol). Es sólo diagnóstico: el
    sentido de un remito no cambia nunca, así que no hay ventana contra el lock
    de la RPC, que sigue siendo la autoridad. Un remito ajeno o inexistente no
    tiene sentido guardado: la RPC responde su 404 de siempre.
  - El estado del remito NO se pre-valida acá (ni la tenencia del cliente, la
    sucursal o los productos): lo decide la RPC bajo el lock del remito, para no
    abrir una ventana entre el chequeo y el lock.
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
from backend.core.rbac import CAN_DELIVER_SALE, CAN_RECEIVE_PURCHASE, CAN_SELL, CAN_VOID_DELIVERY_NOTE
from backend.core.timezone import today_in_argentina
from backend.repositories.delivery_note_repository import DeliveryNoteRepository
from backend.schemas.delivery_notes import (
    DeliveryNoteCancelIn,
    DeliveryNoteConvertIn,
    DeliveryNoteCreateBody,
    DeliveryNoteItemIn,
    DeliveryNoteUpdateBody,
    PurchaseDeliveryNoteCreateIn,
    PurchaseDeliveryNoteUpdateIn,
)
from backend.services.commercial_documents.issuer import resolve_commercial_issuer
from backend.services.commercial_documents.numbering import (
    format_internal_document_number,
    parse_internal_document_number_query,
)
from backend.services.commercial_documents.pdf import build_commercial_document_pdf
from backend.services.commercial_documents.view import build_delivery_note_view

logger = logging.getLogger(__name__)

DIRECTION_MISMATCH_CODE = "delivery_note_direction_mismatch"

CONCURRENT_UPDATE_RETRY_CODE = "concurrent_update_retry"
_CONCURRENT_UPDATE_RETRY_DETAIL = (
    "Otra operación tocó los mismos productos al mismo tiempo. Volvé a intentarlo."
)


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
    """Traduce los errores de negocio de las RPCs a RFC 7807 en un solo lugar,
    y el interbloqueo (`40P01`) a un 409 reintentable."""
    try:
        yield
    except asyncpg.DeadlockDetectedError as exc:
        raise ProblemHTTPException(
            status_code=409,
            detail=_CONCURRENT_UPDATE_RETRY_DETAIL,
            code=CONCURRENT_UPDATE_RETRY_CODE,
        ) from exc
    except asyncpg.PostgresError as exc:
        problem = problem_from_pg_error(exc)
        if problem is None:
            raise
        raise problem from exc


_DIRECTION_LABEL = {"sale": "venta", "purchase": "compra"}


def _uid(value: uuid.UUID | None) -> str | None:
    return str(value) if value is not None else None


def _present(record: dict) -> dict:
    """Agrega la etiqueta visible del número (`R-00000012`) a un registro. El
    prefijo sale del TIPO DE SECUENCIA del sentido, nunca de un literal fijo."""
    document_type = f"delivery_note_{record.get('direction') or 'sale'}"
    return {**record, "number_label": format_internal_document_number(document_type, record.get("number"))}


def _serialize_items(items: list[DeliveryNoteItemIn]) -> list[dict]:
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
        }
        for item in items
    ]


async def _reload(repo: DeliveryNoteRepository, written: dict, fallback_account_id: str) -> dict:
    """Relee el remito completo (cliente, líneas, historial) tras una escritura.
    La cuenta es la que devolvió la RPC —con varias cuentas, la del cliente es la
    que manda—, no la que se supuso."""
    account_id = str(written.get("account_id") or fallback_account_id)
    record = await repo.get_delivery_note(str(written["id"]), account_id)
    if record is None:
        raise ProblemHTTPException(
            status_code=500,
            detail="El remito se guardó pero no pudo leerse",
            code="delivery_note_read_failed",
        )
    return _present(record)


# ── Escrituras ────────────────────────────────────────────────────────────────

async def create_delivery_note(
    repo: DeliveryNoteRepository,
    auth: dict,
    account_id: str,
    payload: DeliveryNoteCreateBody,
    idempotency_key: str,
    *,
    conn,
) -> dict:
    """Emite el remito, despachado por el sentido del cuerpo.

    Venta: lo numera (R), descuenta el stock de la sucursal (mismo camino que la
    venta) y es idempotente. Guard: `CAN_DELIVER_SALE`. Compra: lo numera (RC),
    SUMA el stock de la sucursal de destino y es idempotente. Guard:
    `CAN_RECEIVE_PURCHASE`.

    `idempotency_key` ya llega resuelto por el router (header obligatorio). Un
    `ValueError` si no llegó es un bug de cableado, no un error del usuario: sin
    clave la emisión no es reintentable y se corta antes de la base. Un reintento
    con la misma clave devuelve el MISMO remito con `replayed = true`, sin
    efectos.
    """
    if not idempotency_key:
        raise ValueError("create_delivery_note: falta la clave de idempotencia resuelta por el router")
    if isinstance(payload, PurchaseDeliveryNoteCreateIn):
        await _require_capability(conn, auth, CAN_RECEIVE_PURCHASE)
        with _pg_errors_as_problems():
            written = await repo.create_purchase_delivery_note(
                idempotency_key=idempotency_key,
                supplier_id=str(payload.supplier_id),
                branch_id=str(payload.branch_id),
                supplier_reference=payload.supplier_reference,
                notes=payload.notes,
                items=_serialize_items(payload.items),
            )
    else:
        await _require_capability(conn, auth, CAN_DELIVER_SALE)
        with _pg_errors_as_problems():
            written = await repo.create_delivery_note(
                idempotency_key=idempotency_key,
                client_id=str(payload.client_id),
                branch_id=str(payload.branch_id),
                delivery_address=payload.delivery_address,
                notes=payload.notes,
                items=_serialize_items(payload.items),
            )
    record = await _reload(repo, written, account_id)
    return {**record, "replayed": bool(written.get("replayed", False))}


async def update_delivery_note(
    repo: DeliveryNoteRepository,
    auth: dict,
    account_id: str,
    delivery_note_id: str,
    payload: DeliveryNoteUpdateBody,
    *,
    conn,
) -> dict:
    """Edición (reemplazo completo) con la versión que se editó, despachada por
    el sentido del cuerpo. Guard: `CAN_DELIVER_SALE` (venta) o
    `CAN_RECEIVE_PURCHASE` (compra). `delivery_note_changed` (409) si otro la
    modificó; `P0423 delivery_note_locked_converted` (409) si ya se convirtió;
    en venta `stock_insuficiente` (409) si el aumento no alcanza sobre el neto y
    en compra `delivery_note_stock_consumed` (409) si la baja es menor que lo ya
    salido del depósito. Un cuerpo de otro sentido que el guardado → 409
    `delivery_note_direction_mismatch`."""
    purchase = isinstance(payload, PurchaseDeliveryNoteUpdateIn)
    await _require_capability(conn, auth, CAN_RECEIVE_PURCHASE if purchase else CAN_DELIVER_SALE)
    body_direction = "purchase" if purchase else "sale"
    stored_direction = await repo.get_direction(delivery_note_id, account_id)
    if stored_direction is not None and stored_direction != body_direction:
        raise ProblemHTTPException(
            status_code=409,
            detail=(
                f"El remito es de {_DIRECTION_LABEL.get(stored_direction, stored_direction)} y el cuerpo de "
                f"la edición es de {_DIRECTION_LABEL.get(body_direction, body_direction)}"
            ),
            code=DIRECTION_MISMATCH_CODE,
        )
    with _pg_errors_as_problems():
        if isinstance(payload, PurchaseDeliveryNoteUpdateIn):
            written = await repo.update_purchase_delivery_note(
                delivery_note_id,
                expected_revision=payload.revision,
                supplier_id=str(payload.supplier_id),
                branch_id=str(payload.branch_id),
                supplier_reference=payload.supplier_reference,
                notes=payload.notes,
                items=_serialize_items(payload.items),
            )
        else:
            written = await repo.update_delivery_note(
                delivery_note_id,
                expected_revision=payload.revision,
                client_id=str(payload.client_id),
                branch_id=str(payload.branch_id),
                delivery_address=payload.delivery_address,
                notes=payload.notes,
                items=_serialize_items(payload.items),
            )
    return await _reload(repo, written, account_id)


async def cancel_delivery_note(
    repo: DeliveryNoteRepository,
    auth: dict,
    account_id: str,
    delivery_note_id: str,
    payload: DeliveryNoteCancelIn,
    *,
    conn,
) -> dict:
    """Anula con motivo y revierte el stock que el remito movió, en los dos
    sentidos: en venta lo repone, en compra lo resta (y responde 409
    `delivery_note_stock_consumed` si la mercadería ya se consumió, sin ningún
    efecto). Guard: `CAN_VOID_DELIVERY_NOTE` (sensible: la base decide, no el
    claim). Un remito convertido responde 409 `delivery_note_locked_converted`;
    uno ya anulado, 409 `delivery_note_invalid_state`."""
    await _require_capability(conn, auth, CAN_VOID_DELIVERY_NOTE)
    with _pg_errors_as_problems():
        written = await repo.cancel_delivery_note(
            delivery_note_id, expected_revision=payload.revision, reason=payload.reason
        )
    return await _reload(repo, written, account_id)


async def convert_delivery_note(
    repo: DeliveryNoteRepository,
    auth: dict,
    account_id: str,
    delivery_note_id: str,
    payload: DeliveryNoteConvertIn,
    idempotency_key: str,
    *,
    conn,
) -> dict:
    """Convierte el remito en venta, atómicamente (`rpc_convert_delivery_note_to_sale`).

    Guard: `CAN_SELL`. La venta NO vuelve a mover stock (el remito ya lo
    descontó al emitirse) y eso lo decide la base por el origen persistido de la
    orden, no un parámetro de este contrato. Todo lo demás lo decide la RPC bajo
    el lock del remito: tenencia de cada id del payload, estado
    (`delivery_note_invalid_state`), versión (`delivery_note_changed`), cliente
    vivo (`delivery_note_client_unavailable`), sucursal del remito activa
    (`branch_closed`, 422), caja y forma de pago, e idempotencia
    (`idempotency_key_conflict` si la clave ya convirtió OTRO documento).
    Cualquier fallo revierte la orden y la transición: no queda un remito
    `converted` sin venta. Nada se pre-valida acá para no abrir una ventana entre
    el chequeo y el lock.

    `idempotency_key` ya llega resuelto por el router (header obligatorio). Un
    `ValueError` si no llegó es un bug de cableado, no un error del usuario: sin
    clave la conversión no es reintentable y se corta antes de la base.
    """
    if not idempotency_key:
        raise ValueError("convert_delivery_note: falta la clave de idempotencia resuelta por el router")
    await _require_capability(conn, auth, CAN_SELL)
    with _pg_errors_as_problems():
        result = await repo.convert_to_sale(
            delivery_note_id,
            idempotency_key=idempotency_key,
            expected_revision=payload.expected_revision,
            payment_method_id=str(payload.payment_method_id),
            cash_session_id=_uid(payload.cash_session_id),
            bank_account_id=_uid(payload.bank_account_id),
            canal=payload.canal,
        )
    return {
        **result,
        "delivery_note_number_label": format_internal_document_number(
            "delivery_note_sale", result.get("delivery_note_number")
        ),
    }


# ── Lecturas ──────────────────────────────────────────────────────────────────

async def get_delivery_note(repo: DeliveryNoteRepository, account_id: str, delivery_note_id: str) -> dict:
    """Detalle scopeado a la cuenta del caller. Mismo 404 RFC 7807 para un id
    inexistente y para uno de otra cuenta (no revela si existe en otro tenant)."""
    record = await repo.get_delivery_note(delivery_note_id, account_id)
    if record is None:
        raise ProblemHTTPException(
            status_code=404, detail="Remito no encontrado", code="delivery_note_not_found"
        )
    return _present(record)


async def get_delivery_note_detail(repo: DeliveryNoteRepository, account_id: str, delivery_note_id: str) -> dict:
    """Detalle para `GET /delivery-notes/{id}`: el remito más `issuer_name`, el
    nombre del emisor ya resuelto por la MISMA cascada y la MISMA RPC que el
    encabezado del PDF (`resolve_commercial_issuer`). Es lo que firma el texto de
    WhatsApp. Adorno, no dato del documento: si la RPC falla el remito se lee
    igual y el texto sale sin firma."""
    record = await get_delivery_note(repo, account_id, delivery_note_id)
    try:
        issuer = await resolve_commercial_issuer(repo, account_id)
        issuer_name: str | None = issuer.name
    except asyncpg.PostgresError:
        logger.warning(
            "delivery note %s: no se pudo resolver el emisor para el texto compartido",
            delivery_note_id,
            exc_info=True,
        )
        issuer_name = None
    return {**record, "issuer_name": issuer_name}


async def list_delivery_notes(
    repo: DeliveryNoteRepository,
    account_id: str,
    *,
    page: int,
    page_size: int,
    direction: str | None,
    status: str | None,
    client_id: str | None,
    branch_id: str | None,
    q: str | None,
    supplier_id: str | None = None,
) -> dict:
    """Envelope estándar `{items,total,page,pages}` (v3-api-standards §2) más el
    resumen de pendientes.

    El texto del buscador se usa para el nombre del cliente o del proveedor, el
    número del remito del proveedor y, si es un número de remito, también para el
    número: en la pestaña de compra "RC-12", "12" o "00000012"; en la de venta (y
    sin sentido) "R-12", "12" o "00000012". El prefijo del otro sentido es texto.
    El resumen cuenta los `issued` del MISMO recorte (sentido, cliente, proveedor,
    sucursal, búsqueda) sin importar el estado pedido: el encabezado no cambia al
    cambiar de pestaña. El filtro de proveedor sólo viaja cuando se pide, así la
    consulta de venta no gana argumentos.
    """
    number = parse_internal_document_number_query(
        q, "delivery_note_purchase" if direction == "purchase" else "delivery_note_sale"
    )
    supplier_filter = {"supplier_id": supplier_id} if supplier_id is not None else {}
    rows, total = await repo.list_delivery_notes(
        account_id,
        page=page,
        page_size=page_size,
        direction=direction,
        status=status,
        client_id=client_id,
        branch_id=branch_id,
        text=q,
        number=number,
        **supplier_filter,
    )
    summary = await repo.pending_summary(
        account_id,
        direction=direction,
        client_id=client_id,
        branch_id=branch_id,
        text=q,
        number=number,
        **supplier_filter,
    )
    pages = -(-total // page_size) if total > 0 else 0
    return {
        "items": [_present(r) for r in rows],
        "total": total,
        "page": page,
        "pages": pages,
        "summary": summary,
    }


async def get_delivery_note_pdf(
    repo: DeliveryNoteRepository,
    account_id: str,
    delivery_note_id: str,
    *,
    show_prices: bool = False,
    today: datetime.date | None = None,
) -> tuple[bytes, str]:
    """PDF del remito (`GET /delivery-notes/{id}/pdf`) y su nombre de archivo.

    Lectura de cualquier miembro, para cualquier estado (un remito anulado o
    convertido se puede volver a descargar, con su sello). El contenido sale de
    la base por la cuenta del caller —nunca del request—, con el mismo 404 para un
    id ajeno que para uno inexistente. Por defecto SIN precios (el documento que
    viaja con la mercadería no los muestra); `show_prices` los incluye y cambia el
    nombre del archivo (`remito-R-….pdf` / `remito-R-…-con-precios.pdf`; en compra
    `remito-compra-RC-….pdf` / `…-con-precios.pdf`) para que las dos variantes no
    se confundan. La contraparte de la vista es el cliente (venta) o el proveedor,
    con su CUIT (compra). El emisor se resuelve sin bloquear y siempre
    por `rpc_commercial_issuer`. `today` se inyecta sólo para fijarlo en los tests.
    """
    record = await get_delivery_note(repo, account_id, delivery_note_id)
    with _pg_errors_as_problems():
        issuer = await resolve_commercial_issuer(repo, account_id)
    purchase = record.get("direction") == "purchase"
    counterparty = (
        {"name": record.get("supplier_name"), "tax_id": record.get("supplier_tax_id"), "phone": record.get("supplier_phone")}
        if purchase
        else {"name": record.get("client_name"), "tax_id": record.get("client_tax_id"), "phone": record.get("client_phone")}
    )
    view = build_delivery_note_view(
        record,
        record["items"],
        counterparty,
        {"name": record.get("branch_name")},
        issuer,
        show_prices,
        today or today_in_argentina(),
    )
    label = record["number_label"] or str(record["id"])[:8]
    suffix = "-con-precios" if show_prices else ""
    prefix = "remito-compra" if purchase else "remito"
    return build_commercial_document_pdf(view), f"{prefix}-{label}{suffix}.pdf"
