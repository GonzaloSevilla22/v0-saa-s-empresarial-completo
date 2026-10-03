"""
remitos-venta (tanda A, grupo 2) — remitos de venta sobre RPC, 3 capas.

Strict TDD: este archivo se escribió ANTES que `schemas/delivery_notes.py`,
`repositories/delivery_note_repository.py`, `services/delivery_notes.py` y
`routers/delivery_notes.py`. Cubre la mitad "con dobles" del contrato (schemas,
rbac atado al catálogo, mapeo de errores, guards de rol, SQL que emite el
repositorio, endpoints). La mitad que persiste de verdad (stock real, número
real, idempotencia real) está en `test_delivery_notes_module_integration.py`
(marcada `integration`); la evidencia de CI del esquema es el gate SQL
supabase/tests/test_remitos_venta.sql.

Spec: openspec/changes/remitos-venta/specs/delivery-note/spec.md (escritura sólo
por RPC, permisos atados al catálogo, errores estables, PDF) y design.md D4,
D5, D8, D13.
"""
from __future__ import annotations

import datetime
import json
import re
import uuid
from decimal import Decimal
from pathlib import Path
from unittest.mock import AsyncMock, patch

import asyncpg
import pytest
from fastapi import HTTPException
from pydantic import ValidationError

from backend.tests.conftest import (
    TEST_ACCOUNT_ID,
    TEST_USER_ID,
    account_roles_fetchval,
    make_token,
)

ACCOUNT_ID = str(TEST_ACCOUNT_ID)
DN_ID = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
CLIENT_ID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
BRANCH_ID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
PRODUCT_ID = "22222222-2222-2222-2222-222222222222"
UNIT_ID = "44444444-4444-4444-4444-444444444444"
IDEM_KEY = "dn-create-0001"
REPO_ROOT = Path(__file__).resolve().parents[2]


def _pg_error(sqlstate: str, message: str) -> asyncpg.PostgresError:
    err = asyncpg.PostgresError(message)
    err.sqlstate = sqlstate
    return err


def _auth(*roles: str) -> dict:
    """Auth ya decodificado, con el CONJUNTO de roles del claim."""
    return {
        "user_id": TEST_USER_ID,
        "sub": TEST_USER_ID,
        "role": "user",
        "account_roles": list(roles),
    }


def _item_in(**over) -> dict:
    base = {"product_id": PRODUCT_ID, "quantity": "2", "price": "750", "subtotal": "1500"}
    base.update(over)
    return base


def _dn_record(**over) -> dict:
    base = {
        "id": DN_ID,
        "account_id": ACCOUNT_ID,
        "direction": "sale",
        "branch_id": BRANCH_ID,
        "branch_name": "Sucursal Centro",
        "client_id": CLIENT_ID,
        "client_name": "Ana Pérez",
        "client_phone": "2615550000",
        "client_tax_id": None,
        "client_deleted": False,
        "supplier_id": None,
        "supplier_reference": None,
        "number": 12,
        "status": "issued",
        "issued_on": datetime.date(2026, 10, 2),
        "delivery_address": "San Martín 123",
        "notes": None,
        "total": Decimal("1500.00"),
        "revision": 1,
        "created_by": TEST_USER_ID,
        "created_at": datetime.datetime(2026, 10, 2, 12, 0, tzinfo=datetime.timezone.utc),
        "updated_by": None,
        "updated_at": None,
        "converted_sales_order_id": None,
        "converted_operation_id": None,
        "items": [],
        "history": [],
    }
    base.update(over)
    return base


def _payload_create(**over):
    from backend.schemas.delivery_notes import DeliveryNoteCreateIn

    data = {
        "client_id": CLIENT_ID,
        "branch_id": BRANCH_ID,
        "delivery_address": "San Martín 123",
        "notes": "Entrega en 48 hs",
        "items": [
            _item_in(unit_id=UNIT_ID, price="750.50", subtotal="1501"),
            _item_in(quantity="1", price="300", subtotal="300"),
        ],
    }
    data.update(over)
    return DeliveryNoteCreateIn(**data)


def _payload_update(**over):
    from backend.schemas.delivery_notes import DeliveryNoteUpdateIn

    data = {
        "revision": 3,
        "client_id": CLIENT_ID,
        "branch_id": BRANCH_ID,
        "delivery_address": None,
        "notes": None,
        "items": [_item_in()],
    }
    data.update(over)
    return DeliveryNoteUpdateIn(**data)


def _payload_cancel(**over):
    from backend.schemas.delivery_notes import DeliveryNoteCancelIn

    data = {"revision": 2, "reason": "Se devolvió la mercadería"}
    data.update(over)
    return DeliveryNoteCancelIn(**data)


def _conn(*roles: str) -> AsyncMock:
    """Conexión doble cuya base dice que el usuario tiene EXACTAMENTE `roles`.
    Anular es una capacidad sensible: el guard consulta la base aunque el claim
    ya traiga los roles."""
    conn = AsyncMock()
    conn.fetchval = account_roles_fetchval(list(roles))
    return conn


def _repo(**returns) -> AsyncMock:
    repo = AsyncMock()
    repo.create_delivery_note.return_value = {**_dn_record(), "replayed": False}
    repo.update_delivery_note.return_value = {"id": DN_ID, "account_id": ACCOUNT_ID}
    repo.cancel_delivery_note.return_value = {"id": DN_ID, "account_id": ACCOUNT_ID}
    repo.get_delivery_note.return_value = _dn_record()
    repo.list_delivery_notes.return_value = ([], 0)
    repo.pending_summary.return_value = {"pending_count": 0, "pending_total": Decimal("0")}
    repo.get_commercial_issuer.return_value = {
        "nombre_fantasia": "Sumar", "razon_social": "PEREZ MARIA LAURA", "business_name": "Almacén Don José",
    }
    for name, value in returns.items():
        getattr(repo, name).return_value = value
    return repo


# ══════════════════════════════════════════════════════════════════════════════
# 2.1 schemas
# ══════════════════════════════════════════════════════════════════════════════

class TestSchemas:
    def test_direction_is_sale_only(self):
        from backend.schemas.delivery_notes import DeliveryNoteCreateIn

        base = {"client_id": CLIENT_ID, "branch_id": BRANCH_ID, "items": [_item_in()]}
        assert DeliveryNoteCreateIn(**base).direction == "sale"
        assert DeliveryNoteCreateIn(**base, direction="sale").direction == "sale"
        with pytest.raises(ValidationError):
            DeliveryNoteCreateIn(**base, direction="purchase")

    def test_product_id_is_required_on_every_line(self):
        from backend.schemas.delivery_notes import DeliveryNoteItemIn

        with pytest.raises(ValidationError):
            DeliveryNoteItemIn(quantity="1", price="100", subtotal="100")
        with pytest.raises(ValidationError):
            DeliveryNoteItemIn(product_id=None, quantity="1", price="100", subtotal="100")
        assert DeliveryNoteItemIn(**_item_in()).product_id == uuid.UUID(PRODUCT_ID)

    @pytest.mark.parametrize("field,bad", [("quantity", "0"), ("quantity", "-1"), ("price", "-0.01"), ("subtotal", "-1")])
    def test_amounts_are_validated_before_the_database(self, field, bad):
        from backend.schemas.delivery_notes import DeliveryNoteItemIn

        with pytest.raises(ValidationError):
            DeliveryNoteItemIn(**_item_in(**{field: bad}))

    def test_zero_price_and_subtotal_are_valid(self):
        from backend.schemas.delivery_notes import DeliveryNoteItemIn

        line = DeliveryNoteItemIn(**_item_in(price="0", subtotal="0"))
        assert line.price == 0 and line.subtotal == 0

    def test_client_and_branch_are_required(self):
        from backend.schemas.delivery_notes import DeliveryNoteCreateIn

        with pytest.raises(ValidationError):
            DeliveryNoteCreateIn(branch_id=BRANCH_ID, items=[_item_in()])
        with pytest.raises(ValidationError):
            DeliveryNoteCreateIn(client_id=CLIENT_ID, items=[_item_in()])

    def test_items_bounds(self):
        from backend.schemas.delivery_notes import DeliveryNoteCreateIn

        base = {"client_id": CLIENT_ID, "branch_id": BRANCH_ID}
        with pytest.raises(ValidationError):
            DeliveryNoteCreateIn(**base, items=[])
        DeliveryNoteCreateIn(**base, items=[_item_in()] * 500)
        with pytest.raises(ValidationError):
            DeliveryNoteCreateIn(**base, items=[_item_in()] * 501)

    def test_text_limits(self):
        from backend.schemas.delivery_notes import DeliveryNoteCreateIn

        base = {"client_id": CLIENT_ID, "branch_id": BRANCH_ID, "items": [_item_in()]}
        DeliveryNoteCreateIn(**base, notes="n" * 2000, delivery_address="d" * 500)
        with pytest.raises(ValidationError):
            DeliveryNoteCreateIn(**base, notes="n" * 2001)
        with pytest.raises(ValidationError):
            DeliveryNoteCreateIn(**base, delivery_address="d" * 501)

    def test_update_is_a_full_replacement_with_revision(self):
        from backend.schemas.delivery_notes import DeliveryNoteUpdateIn

        base = {
            "revision": 3, "client_id": CLIENT_ID, "branch_id": BRANCH_ID,
            "delivery_address": None, "notes": None, "items": [_item_in()],
        }
        ok = DeliveryNoteUpdateIn(**base)
        assert ok.revision == 3
        # un reemplazo completo: ningún campo se omite en silencio
        for field in ("revision", "client_id", "branch_id", "delivery_address", "notes", "items"):
            incomplete = {k: v for k, v in base.items() if k != field}
            with pytest.raises(ValidationError):
                DeliveryNoteUpdateIn(**incomplete)
        with pytest.raises(ValidationError):
            DeliveryNoteUpdateIn(**{**base, "revision": 0})
        with pytest.raises(ValidationError):
            DeliveryNoteUpdateIn(**{**base, "branch_id": None})

    def test_cancel_needs_a_reason_between_3_and_500_and_the_revision(self):
        from backend.schemas.delivery_notes import DeliveryNoteCancelIn

        assert DeliveryNoteCancelIn(revision=1, reason="  Error de carga  ").reason == "Error de carga"
        for bad in ("", "  ", "ab", "x" * 501):
            with pytest.raises(ValidationError):
                DeliveryNoteCancelIn(revision=1, reason=bad)
        DeliveryNoteCancelIn(revision=1, reason="x" * 500)
        with pytest.raises(ValidationError):
            DeliveryNoteCancelIn(reason="Error de carga")
        with pytest.raises(ValidationError):
            DeliveryNoteCancelIn(revision=0, reason="Error de carga")

    def test_status_enum_has_the_three_states(self):
        from backend.schemas.delivery_notes import DeliveryNoteStatus

        assert {s.value for s in DeliveryNoteStatus} == {"issued", "converted", "canceled"}

    def test_out_carries_what_the_screens_need(self):
        from backend.schemas.delivery_notes import DeliveryNoteListItemOut, DeliveryNoteOut

        assert {
            "id", "direction", "branch_id", "branch_name", "client_id", "client_name", "client_phone",
            "client_deleted", "number", "number_label", "status", "issued_on", "delivery_address", "notes",
            "total", "revision", "created_at", "updated_at", "converted_sales_order_id", "issuer_name",
            "replayed", "items", "history",
        } <= set(DeliveryNoteOut.model_fields)
        assert {
            "id", "direction", "branch_id", "branch_name", "client_id", "client_name", "status", "issued_on",
            "total", "number", "number_label", "revision", "item_count",
        } <= set(DeliveryNoteListItemOut.model_fields)

    def test_list_page_keeps_the_standard_envelope_and_adds_the_summary(self):
        from backend.schemas.delivery_notes import DeliveryNotePageOut

        assert {"items", "total", "page", "pages", "summary"} == set(DeliveryNotePageOut.model_fields)


# ══════════════════════════════════════════════════════════════════════════════
# 2.2 capacidades atadas al catálogo de la FSM
# ══════════════════════════════════════════════════════════════════════════════

def _migration_sql() -> str:
    return (REPO_ROOT / "supabase/migrations/20261069000001_remitos_venta.sql").read_text(encoding="utf-8")


class TestCapabilities:
    def test_values(self):
        from backend.core.rbac import CAN_DELIVER_SALE, CAN_VOID_DELIVERY_NOTE

        assert CAN_DELIVER_SALE == frozenset({"owner", "admin", "seller", "stock"})
        assert CAN_VOID_DELIVERY_NOTE == frozenset({"owner", "admin"})
        assert isinstance(CAN_DELIVER_SALE, frozenset) and isinstance(CAN_VOID_DELIVERY_NOTE, frozenset)

    def test_void_is_a_sensitive_capability_so_the_database_decides(self):
        """Anular devuelve stock: la autoridad es la base, no el claim. Su
        contenido coincide con CAN_CONFIGURE, que ya es una capacidad
        sensible; el error queda del lado seguro (D13)."""
        from backend.core.rbac import (
            CAN_DELIVER_SALE,
            CAN_VOID_DELIVERY_NOTE,
            is_sensitive_capability,
        )

        assert is_sensitive_capability(CAN_VOID_DELIVERY_NOTE) is True
        # control negativo: emitir NO es sensible (basta el claim)
        assert is_sensitive_capability(CAN_DELIVER_SALE) is False

    def test_roles_are_the_ones_of_the_delivery_note_sale_catalog_rows(self):
        """Atado al catálogo: lo que la migración siembra en
        `document_status_transitions` para `delivery_note_sale` es EXACTAMENTE
        lo que declaran las capacidades. Si divergen, este test falla."""
        from backend.core.rbac import CAN_DELIVER_SALE, CAN_VOID_DELIVERY_NOTE

        sql = _migration_sql()
        rows = re.findall(
            r"\('delivery_note_sale',\s*(NULL|'[a-z_]+'),\s*'([a-z_]+)',\s*(?:true|false),\s*(?:true|false),\s*ARRAY\[([^\]]*)\]",
            sql,
        )
        by_transition = {
            (frm.strip("'") if frm != "NULL" else None, to): frozenset(re.findall(r"'([a-z_]+)'", roles))
            for frm, to, roles in rows
        }
        assert by_transition.get((None, "issued")) == CAN_DELIVER_SALE
        assert by_transition.get(("issued", "canceled")) == CAN_VOID_DELIVERY_NOTE

    def test_the_issue_role_check_of_the_rpcs_reads_the_same_catalog_rows(self):
        """La capacidad del backend no es una segunda política: la RPC lee los
        roles de la misma fila del catálogo (`_delivery_note_assert_role`)."""
        sql = _migration_sql()
        assert "_delivery_note_assert_role" in sql
        assert re.search(r"document_status_transitions", sql)


# ══════════════════════════════════════════════════════════════════════════════
# core.errors.problem_from_pg_error — código estable = literal del RAISE
# ══════════════════════════════════════════════════════════════════════════════

# Todo literal que las RPCs de la tanda A levantan con ERRCODE de negocio y su
# estado HTTP. Fuente: supabase/migrations/20261069000001_remitos_venta.sql.
SQL_LITERALS = [
    ("P0400", "delivery_note_client_required: el remito necesita un cliente", 400, "delivery_note_client_required"),
    ("P0400", "delivery_note_branch_required: el remito necesita una sucursal", 400, "delivery_note_branch_required"),
    ("P0400", "delivery_note_items_required: el remito necesita al menos una línea", 400, "delivery_note_items_required"),
    ("P0400", "delivery_note_too_many_items: máximo 500 líneas por remito", 400, "delivery_note_too_many_items"),
    ("P0400", "delivery_note_line_invalid: cada línea debe ser un objeto", 400, "delivery_note_line_invalid"),
    ("P0400", "delivery_note_line_invalid_quantity: la cantidad debe ser mayor que 0", 400, "delivery_note_line_invalid_quantity"),
    ("P0400", "delivery_note_line_invalid_price: el precio no puede ser negativo", 400, "delivery_note_line_invalid_price"),
    ("P0400", "delivery_note_line_invalid_subtotal: el subtotal no puede ser negativo", 400, "delivery_note_line_invalid_subtotal"),
    ("P0400", "delivery_note_product_required: cada línea necesita un producto", 400, "delivery_note_product_required"),
    ("P0400", "delivery_note_product_unavailable: el producto fue dado de baja", 400, "delivery_note_product_unavailable"),
    ("P0400", "delivery_note_revision_required: falta la versión del remito", 400, "delivery_note_revision_required"),
    ("P0400", "delivery_note_address_too_long: el domicilio admite hasta 500 caracteres", 400, "delivery_note_address_too_long"),
    ("P0400", "delivery_note_notes_too_long: las notas admiten hasta 2.000 caracteres", 400, "delivery_note_notes_too_long"),
    ("P0400", "delivery_note_cancel_reason_required: anular un remito exige un motivo", 400, "delivery_note_cancel_reason_required"),
    ("P0400", "delivery_note_cancel_reason_too_long: el motivo admite hasta 500 caracteres", 400, "delivery_note_cancel_reason_too_long"),
    ("P0400", "idempotency_key_required: la emisión necesita una clave", 400, "idempotency_key_required"),
    ("P0400", "product_is_parent: \"Remera\" se vende a través de sus variantes", 400, "product_is_parent"),
    ("P0403", "insufficient_role: tu rol no permite anular remitos", 403, "insufficient_role"),
    ("P0401", "unauthorized", 403, "unauthorized"),
    ("P0404", "delivery_note_not_found: dddd", 404, "delivery_note_not_found"),
    ("P0404", "client_not_found: cccc", 404, "client_not_found"),
    ("P0404", "product_not_found: 2222", 404, "product_not_found"),
    ("P0404", "branch_not_found or not active for this account", 404, "branch_not_found"),
    ("P0409", "delivery_note_changed: el remito cambió (versión 3 -> 4)", 409, "delivery_note_changed"),
    ("P0409", "delivery_note_invalid_state: el remito está anulado", 409, "delivery_note_invalid_state"),
    ("P0409", "stock_insuficiente para producto X: disponible 1, solicitado 3", 409, "stock_insuficiente"),
    ("P0409", "idempotency_key_conflict: la clave ya se usó para otra operación", 409, "idempotency_key_conflict"),
    ("P0423", "delivery_note_locked_converted: el remito ya se convirtió en la venta", 409, "delivery_note_locked_converted"),
    ("P0422", "branch_closed: la sucursal está cerrada", 422, "branch_closed"),
    ("P0422", "delivery_note_branch_inactive: reactivá la sucursal para anular el remito", 422, "delivery_note_branch_inactive"),
]


class TestProblemFromPgError:
    @pytest.mark.parametrize("sqlstate,message,status,code", SQL_LITERALS)
    def test_literal_code_and_status(self, sqlstate, message, status, code):
        from backend.core.errors import problem_from_pg_error

        problem = problem_from_pg_error(_pg_error(sqlstate, message))

        assert problem.status_code == status
        assert problem.code == code
        assert message in str(problem.detail)

    def test_every_literal_of_the_migration_has_a_case(self):
        """Control de completitud: cada literal estable que la migración de la
        tanda A levanta para las RPCs públicas del remito aparece en la tabla
        de arriba (si SQL suma uno nuevo, este test obliga a mapearlo)."""
        sql = _migration_sql()
        raised = set(
            re.findall(
                r"RAISE EXCEPTION '(delivery_note_[a-z_]+|idempotency_key_[a-z_]+)[:'%\s]",
                sql,
            )
        )
        # Internos: el modo `convert` del guard de rol sólo lo llama la tanda B
        # (responde P0409 hasta que sembre `issued -> converted`), y los otros dos
        # son aserciones de programación de helpers que ninguna entrada de usuario
        # alcanza.
        raised -= {
            "delivery_note_role_mode_invalid",
            "delivery_note_reverse_invalid_reference",
            "delivery_note_role_mode_unavailable",
        }
        covered = {code for _, _, _, code in SQL_LITERALS}
        assert raised <= covered, f"literales sin caso: {sorted(raised - covered)}"


# ══════════════════════════════════════════════════════════════════════════════
# 2.1 servicio — guards de rol
# ══════════════════════════════════════════════════════════════════════════════

WRITE_CALLS = {
    "create": lambda svc, repo, auth, conn: svc.create_delivery_note(
        repo, auth, ACCOUNT_ID, _payload_create(), IDEM_KEY, conn=conn),
    "update": lambda svc, repo, auth, conn: svc.update_delivery_note(
        repo, auth, ACCOUNT_ID, DN_ID, _payload_update(), conn=conn),
    "cancel": lambda svc, repo, auth, conn: svc.cancel_delivery_note(
        repo, auth, ACCOUNT_ID, DN_ID, _payload_cancel(), conn=conn),
}
REPO_WRITE_METHOD = {"create": "create_delivery_note", "update": "update_delivery_note", "cancel": "cancel_delivery_note"}
ROLES_BY_OP = {
    "create": {"allowed": ["seller", "stock", "admin", "owner"], "denied": ["cashier", "purchases", "accountant", "viewer"]},
    "update": {"allowed": ["seller", "stock", "admin", "owner"], "denied": ["cashier", "purchases", "accountant", "viewer"]},
    "cancel": {"allowed": ["admin", "owner"], "denied": ["seller", "stock", "cashier", "purchases", "viewer"]},
}


def _cases(kind: str):
    return [(op, role) for op in sorted(ROLES_BY_OP) for role in ROLES_BY_OP[op][kind]]


class TestServiceRoleGuard:
    @pytest.mark.asyncio
    @pytest.mark.parametrize("op,role", _cases("denied"))
    async def test_denied_roles_get_403_without_calling_the_rpc(self, op, role):
        from backend.services import delivery_notes as svc

        repo = _repo()
        with pytest.raises(HTTPException) as info:
            await WRITE_CALLS[op](svc, repo, _auth(role), _conn(role))

        assert info.value.status_code == 403
        assert getattr(info.value, "code", None) == "insufficient_role"
        getattr(repo, REPO_WRITE_METHOD[op]).assert_not_awaited()

    @pytest.mark.asyncio
    @pytest.mark.parametrize("op,role", _cases("allowed"))
    async def test_allowed_roles_reach_the_rpc(self, op, role):
        from backend.services import delivery_notes as svc

        repo = _repo()
        await WRITE_CALLS[op](svc, repo, _auth(role), _conn(role))

        getattr(repo, REPO_WRITE_METHOD[op]).assert_awaited_once()

    @pytest.mark.asyncio
    async def test_a_seller_cannot_cancel_but_the_stock_role_can_issue(self):
        """La asimetría que pide la spec: stock emite y edita pero no anula."""
        from backend.services import delivery_notes as svc

        repo = _repo()
        await svc.create_delivery_note(repo, _auth("stock"), ACCOUNT_ID, _payload_create(), IDEM_KEY, conn=AsyncMock())
        await svc.update_delivery_note(repo, _auth("stock"), ACCOUNT_ID, DN_ID, _payload_update(), conn=AsyncMock())
        with pytest.raises(HTTPException) as info:
            await svc.cancel_delivery_note(repo, _auth("stock"), ACCOUNT_ID, DN_ID, _payload_cancel(), conn=_conn("stock"))
        assert info.value.status_code == 403
        repo.cancel_delivery_note.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_roles_are_a_set_union_not_the_first_role(self):
        """Un usuario con `cashier` + `seller` emite: el guard evalúa el
        CONJUNTO de roles activos."""
        from backend.services import delivery_notes as svc

        repo = _repo()
        await svc.create_delivery_note(
            repo, _auth("cashier", "seller"), ACCOUNT_ID, _payload_create(), IDEM_KEY, conn=AsyncMock())
        repo.create_delivery_note.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_roles_resolved_from_the_database_when_the_claim_is_absent(self):
        """Sin claim `account_roles` el guard consulta el pivot. Anular es una
        capacidad sensible: consulta SIEMPRE la base, aunque el claim diga
        owner (la base es la autoridad)."""
        from backend.services import delivery_notes as svc

        auth = {"user_id": TEST_USER_ID, "sub": TEST_USER_ID, "role": "user"}
        conn = AsyncMock()
        conn.fetchval = account_roles_fetchval(["seller"])
        repo = _repo()
        with pytest.raises(HTTPException) as info:
            await svc.cancel_delivery_note(repo, auth, ACCOUNT_ID, DN_ID, _payload_cancel(), conn=conn)
        assert info.value.status_code == 403
        repo.cancel_delivery_note.assert_not_awaited()

        conn.fetchval = account_roles_fetchval(["admin"])
        await svc.cancel_delivery_note(repo, auth, ACCOUNT_ID, DN_ID, _payload_cancel(), conn=conn)
        repo.cancel_delivery_note.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_a_stale_owner_claim_does_not_authorize_a_cancel(self):
        """El claim `account_roles` dice owner pero la base ya no lo tiene:
        anular es sensible, así que la base manda y el claim no alcanza."""
        from backend.services import delivery_notes as svc

        conn = AsyncMock()
        conn.fetchval = account_roles_fetchval(["viewer"])
        repo = _repo()
        with pytest.raises(HTTPException) as info:
            await svc.cancel_delivery_note(repo, _auth("owner"), ACCOUNT_ID, DN_ID, _payload_cancel(), conn=conn)
        assert info.value.status_code == 403
        repo.cancel_delivery_note.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_legacy_role_user_is_not_enough(self):
        from backend.services import delivery_notes as svc

        auth = {"user_id": TEST_USER_ID, "sub": TEST_USER_ID, "role": "user", "account_roles": ["viewer"]}
        with pytest.raises(HTTPException) as info:
            await svc.create_delivery_note(_repo(), auth, ACCOUNT_ID, _payload_create(), IDEM_KEY, conn=AsyncMock())
        assert info.value.status_code == 403


# ══════════════════════════════════════════════════════════════════════════════
# servicio — comportamiento
# ══════════════════════════════════════════════════════════════════════════════

class TestServiceBehavior:
    @pytest.mark.asyncio
    async def test_create_serializes_lines_as_exact_text_and_forwards_the_key(self):
        from backend.services import delivery_notes as svc

        repo = _repo()
        result = await svc.create_delivery_note(
            repo, _auth("seller"), ACCOUNT_ID, _payload_create(), IDEM_KEY, conn=AsyncMock())

        kwargs = repo.create_delivery_note.await_args.kwargs
        assert kwargs["idempotency_key"] == IDEM_KEY
        assert kwargs["client_id"] == CLIENT_ID and kwargs["branch_id"] == BRANCH_ID
        assert kwargs["delivery_address"] == "San Martín 123" and kwargs["notes"] == "Entrega en 48 hs"
        assert kwargs["items"] == [
            {"product_id": PRODUCT_ID, "unit_id": UNIT_ID, "quantity": "2", "price": "750.50", "subtotal": "1501"},
            {"product_id": PRODUCT_ID, "unit_id": None, "quantity": "1", "price": "300", "subtotal": "300"},
        ]
        assert result["number_label"] == "R-00000012"
        assert result["revision"] == 1

    @pytest.mark.asyncio
    async def test_create_returns_the_replayed_flag_from_the_rpc(self):
        from backend.services import delivery_notes as svc

        repo = _repo(create_delivery_note={**_dn_record(), "replayed": True})
        replay = await svc.create_delivery_note(
            repo, _auth("seller"), ACCOUNT_ID, _payload_create(), IDEM_KEY, conn=AsyncMock())
        assert replay["replayed"] is True

        fresh = await svc.create_delivery_note(
            _repo(), _auth("seller"), ACCOUNT_ID, _payload_create(), IDEM_KEY, conn=AsyncMock())
        assert fresh["replayed"] is False

    @pytest.mark.asyncio
    async def test_create_without_a_resolved_key_is_a_wiring_bug_not_a_user_error(self):
        from backend.services import delivery_notes as svc

        repo = _repo()
        with pytest.raises(ValueError):
            await svc.create_delivery_note(repo, _auth("seller"), ACCOUNT_ID, _payload_create(), "", conn=AsyncMock())
        repo.create_delivery_note.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_update_forwards_the_expected_revision_and_reads_back(self):
        from backend.services import delivery_notes as svc

        repo = _repo()
        result = await svc.update_delivery_note(
            repo, _auth("owner"), ACCOUNT_ID, DN_ID, _payload_update(revision=7), conn=AsyncMock())

        args = repo.update_delivery_note.await_args
        assert args.args == (DN_ID,)
        assert args.kwargs["expected_revision"] == 7
        assert args.kwargs["branch_id"] == BRANCH_ID
        repo.get_delivery_note.assert_awaited_once_with(DN_ID, ACCOUNT_ID)
        assert result["number_label"] == "R-00000012"

    @pytest.mark.asyncio
    async def test_cancel_forwards_revision_and_reason_and_reads_back(self):
        from backend.services import delivery_notes as svc

        repo = _repo()
        await svc.cancel_delivery_note(repo, _auth("admin"), ACCOUNT_ID, DN_ID, _payload_cancel(), conn=_conn("admin"))

        args = repo.cancel_delivery_note.await_args
        assert args.args == (DN_ID,)
        assert args.kwargs == {"expected_revision": 2, "reason": "Se devolvió la mercadería"}
        repo.get_delivery_note.assert_awaited_once_with(DN_ID, ACCOUNT_ID)

    @pytest.mark.asyncio
    @pytest.mark.parametrize("op", ["create", "update", "cancel"])
    @pytest.mark.parametrize("sqlstate,message,status,code", SQL_LITERALS)
    async def test_every_business_error_surfaces_as_a_stable_problem(self, op, sqlstate, message, status, code):
        from backend.services import delivery_notes as svc

        repo = _repo()
        getattr(repo, REPO_WRITE_METHOD[op]).side_effect = _pg_error(sqlstate, message)

        with pytest.raises(HTTPException) as info:
            await WRITE_CALLS[op](svc, repo, _auth("owner"), _conn("owner"))

        assert info.value.status_code == status
        assert info.value.code == code

    @pytest.mark.asyncio
    @pytest.mark.parametrize("op", ["create", "update", "cancel"])
    async def test_deadlock_is_a_409_concurrent_update_retry(self, op):
        """40P01: la transacción revirtió entera y la emisión es idempotente,
        así que reintentar es seguro. Un 500 genérico no le dice eso al
        usuario."""
        from backend.services import delivery_notes as svc

        repo = _repo()
        getattr(repo, REPO_WRITE_METHOD[op]).side_effect = asyncpg.DeadlockDetectedError("deadlock detected")

        with pytest.raises(HTTPException) as info:
            await WRITE_CALLS[op](svc, repo, _auth("owner"), _conn("owner"))

        assert info.value.status_code == 409
        assert info.value.code == "concurrent_update_retry"
        assert "Volvé a intentarlo" in str(info.value.detail)

    @pytest.mark.asyncio
    async def test_unmapped_sqlstate_still_propagates_for_the_global_500(self):
        """CONTROL NEGATIVO del mapeo: lo desconocido no se disfraza."""
        from backend.services import delivery_notes as svc

        repo = _repo()
        repo.create_delivery_note.side_effect = _pg_error("XX999", "boom")
        with pytest.raises(asyncpg.PostgresError):
            await svc.create_delivery_note(
                repo, _auth("owner"), ACCOUNT_ID, _payload_create(), IDEM_KEY, conn=AsyncMock())

    @pytest.mark.asyncio
    async def test_write_that_cannot_be_read_back_is_a_500_with_a_stable_code(self):
        from backend.services import delivery_notes as svc

        repo = _repo(get_delivery_note=None)
        with pytest.raises(HTTPException) as info:
            await svc.update_delivery_note(
                repo, _auth("owner"), ACCOUNT_ID, DN_ID, _payload_update(), conn=AsyncMock())
        assert info.value.status_code == 500
        assert info.value.code == "delivery_note_read_failed"


class TestServiceReads:
    @pytest.mark.asyncio
    async def test_get_is_scoped_and_labelled(self):
        from backend.services import delivery_notes as svc

        repo = _repo()
        record = await svc.get_delivery_note(repo, ACCOUNT_ID, DN_ID)

        repo.get_delivery_note.assert_awaited_once_with(DN_ID, ACCOUNT_ID)
        assert record["number_label"] == "R-00000012"

    @pytest.mark.asyncio
    async def test_missing_and_foreign_are_the_same_404(self):
        from backend.services import delivery_notes as svc

        repo = _repo(get_delivery_note=None)
        with pytest.raises(HTTPException) as info:
            await svc.get_delivery_note(repo, ACCOUNT_ID, DN_ID)
        assert info.value.status_code == 404
        assert info.value.code == "delivery_note_not_found"
        assert info.value.detail == "Remito no encontrado"

    @pytest.mark.asyncio
    async def test_detail_adds_the_issuer_name_resolved_like_the_pdf(self):
        from backend.services import delivery_notes as svc

        detail = await svc.get_delivery_note_detail(_repo(), ACCOUNT_ID, DN_ID)
        assert detail["issuer_name"] == "Sumar"

    @pytest.mark.asyncio
    async def test_detail_survives_an_issuer_failure(self):
        from backend.services import delivery_notes as svc

        repo = _repo()
        repo.get_commercial_issuer.side_effect = asyncpg.PostgresError("boom")
        detail = await svc.get_delivery_note_detail(repo, ACCOUNT_ID, DN_ID)
        assert detail["issuer_name"] is None
        assert detail["id"] == DN_ID

    @pytest.mark.asyncio
    async def test_list_builds_the_standard_envelope_with_the_pending_summary(self):
        from backend.services import delivery_notes as svc

        row = {k: v for k, v in _dn_record().items() if k not in ("items", "history")}
        row["item_count"] = 2
        repo = _repo(
            list_delivery_notes=([row], 51),
            pending_summary={"pending_count": 4, "pending_total": Decimal("6000.00")},
        )

        page = await svc.list_delivery_notes(
            repo, ACCOUNT_ID, page=1, page_size=25, direction="sale", status="issued",
            client_id=CLIENT_ID, branch_id=BRANCH_ID, q="R-12",
        )

        assert page["total"] == 51 and page["page"] == 1 and page["pages"] == 3
        assert page["items"][0]["number_label"] == "R-00000012"
        assert page["summary"] == {"pending_count": 4, "pending_total": Decimal("6000.00")}
        repo.list_delivery_notes.assert_awaited_once_with(
            ACCOUNT_ID, page=1, page_size=25, direction="sale", status="issued",
            client_id=CLIENT_ID, branch_id=BRANCH_ID, text="R-12", number=12,
        )

    @pytest.mark.asyncio
    async def test_summary_ignores_the_status_filter_but_keeps_the_others(self):
        """El resumen de pendientes no puede depender de la pestaña elegida:
        con `status=canceled` igual cuenta los pendientes del mismo recorte
        (sentido, cliente, sucursal, búsqueda)."""
        from backend.services import delivery_notes as svc

        repo = _repo()
        await svc.list_delivery_notes(
            repo, ACCOUNT_ID, page=0, page_size=25, direction=None, status="canceled",
            client_id=None, branch_id=BRANCH_ID, q="Ana",
        )
        repo.pending_summary.assert_awaited_once_with(
            ACCOUNT_ID, direction=None, client_id=None, branch_id=BRANCH_ID, text="Ana", number=None,
        )

    @pytest.mark.asyncio
    @pytest.mark.parametrize("total,size,pages", [(0, 25, 0), (1, 25, 1), (25, 25, 1), (26, 25, 2)])
    async def test_pages_is_a_ceiling_with_zero_for_empty(self, total, size, pages):
        from backend.services import delivery_notes as svc

        repo = _repo(list_delivery_notes=([], total))
        page = await svc.list_delivery_notes(
            repo, ACCOUNT_ID, page=0, page_size=size, direction=None, status=None,
            client_id=None, branch_id=None, q=None,
        )
        assert page["pages"] == pages

    @pytest.mark.asyncio
    @pytest.mark.parametrize(
        "q,number,text",
        [("R-12", 12, "R-12"), ("12", 12, "12"), ("00000012", 12, "00000012"), ("r-00000012", 12, "r-00000012"),
         ("Ana", None, "Ana"), ("P-12", 12, "P-12")],
    )
    async def test_search_formats(self, q, number, text):
        """Cada formato de búsqueda: el número del remito (R-12, 12,
        00000012) o el nombre del cliente. Como en la definición de TypeScript,
        el buscador reconoce cualquier prefijo conocido (P-12 también es el
        número 12): qué documento se busca lo decide el listado."""
        from backend.services import delivery_notes as svc

        repo = _repo()
        await svc.list_delivery_notes(
            repo, ACCOUNT_ID, page=0, page_size=25, direction=None, status=None,
            client_id=None, branch_id=None, q=q,
        )
        kwargs = repo.list_delivery_notes.await_args.kwargs
        assert kwargs["number"] == number and kwargs["text"] == text


class TestPdfService:
    @pytest.mark.asyncio
    async def test_pdf_is_priceless_by_default_and_named_after_the_number(self):
        from backend.services import delivery_notes as svc

        pdf, filename = await svc.get_delivery_note_pdf(_repo(), ACCOUNT_ID, DN_ID, today=datetime.date(2026, 10, 2))
        assert pdf.startswith(b"%PDF")
        assert filename == "remito-R-00000012.pdf"

    @pytest.mark.asyncio
    async def test_pdf_with_prices_is_named_differently(self):
        from backend.services import delivery_notes as svc

        pdf, filename = await svc.get_delivery_note_pdf(
            _repo(), ACCOUNT_ID, DN_ID, show_prices=True, today=datetime.date(2026, 10, 2))
        assert pdf.startswith(b"%PDF")
        assert filename == "remito-R-00000012-con-precios.pdf"

    @pytest.mark.asyncio
    async def test_pdf_of_a_missing_or_foreign_note_is_404(self):
        from backend.services import delivery_notes as svc

        with pytest.raises(HTTPException) as info:
            await svc.get_delivery_note_pdf(_repo(get_delivery_note=None), ACCOUNT_ID, DN_ID)
        assert info.value.status_code == 404 and info.value.code == "delivery_note_not_found"


# ══════════════════════════════════════════════════════════════════════════════
# repositorio — sólo RPC en las escrituras, tenencia en las lecturas
# ══════════════════════════════════════════════════════════════════════════════

class _RecordingConn:
    """Conexión que anota cada consulta y responde con lo mínimo."""

    def __init__(self):
        self.queries: list[tuple[str, tuple]] = []

    async def _answer(self, query, args, default):
        self.queries.append((query, args))
        return default

    async def fetchval(self, query, *args):
        return await self._answer(query, args, json.dumps({"id": DN_ID, "account_id": ACCOUNT_ID, "items": []}))

    async def fetchrow(self, query, *args):
        return await self._answer(query, args, None)

    async def fetch(self, query, *args):
        return await self._answer(query, args, [])

    async def execute(self, query, *args):
        return await self._answer(query, args, "OK")


DIRECT_WRITE = re.compile(r"(INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+(public\.)?delivery_note(s|_items)\b", re.I)
STOCK_WRITE = re.compile(r"(INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+(public\.)?(stock_movements|branch_stock)\b", re.I)


class TestRepositoryUsesRpcOnly:
    @pytest.mark.asyncio
    async def test_no_method_writes_the_document_or_the_ledger_directly(self):
        from backend.repositories.delivery_note_repository import DeliveryNoteRepository

        conn = _RecordingConn()
        repo = DeliveryNoteRepository(conn)
        await repo.create_delivery_note(
            idempotency_key=IDEM_KEY, client_id=CLIENT_ID, branch_id=BRANCH_ID,
            delivery_address=None, notes=None, items=[_item_in()])
        await repo.update_delivery_note(
            DN_ID, expected_revision=1, client_id=CLIENT_ID, branch_id=BRANCH_ID,
            delivery_address=None, notes=None, items=[_item_in()])
        await repo.cancel_delivery_note(DN_ID, expected_revision=1, reason="Error de carga")
        await repo.get_delivery_note(DN_ID, ACCOUNT_ID)
        await repo.list_delivery_notes(
            ACCOUNT_ID, page=0, page_size=25, direction=None, status=None,
            client_id=None, branch_id=None, text=None, number=None)
        await repo.pending_summary(ACCOUNT_ID, direction=None, client_id=None, branch_id=None, text=None, number=None)
        await repo.get_commercial_issuer(ACCOUNT_ID)

        assert conn.queries, "el repositorio no emitió ninguna consulta"
        for query, _ in conn.queries:
            assert not DIRECT_WRITE.search(query), f"escritura directa sobre remitos: {query[:90]}"
            assert not STOCK_WRITE.search(query), f"el repositorio toca el ledger de stock: {query[:90]}"

    def test_the_module_source_has_no_direct_write_either(self):
        source = (REPO_ROOT / "backend/repositories/delivery_note_repository.py").read_text(encoding="utf-8")
        assert not DIRECT_WRITE.search(source)
        assert not STOCK_WRITE.search(source)

    @pytest.mark.asyncio
    async def test_writes_go_through_the_named_rpcs(self):
        from backend.repositories.delivery_note_repository import DeliveryNoteRepository

        conn = _RecordingConn()
        repo = DeliveryNoteRepository(conn)
        await repo.create_delivery_note(
            idempotency_key=IDEM_KEY, client_id=CLIENT_ID, branch_id=BRANCH_ID,
            delivery_address=None, notes=None, items=[_item_in()])
        await repo.update_delivery_note(
            DN_ID, expected_revision=4, client_id=CLIENT_ID, branch_id=BRANCH_ID,
            delivery_address="x", notes="n", items=[_item_in()])
        await repo.cancel_delivery_note(DN_ID, expected_revision=4, reason="Error de carga")
        await repo.get_commercial_issuer(ACCOUNT_ID)

        called = " ".join(q for q, _ in conn.queries)
        for rpc in ("rpc_create_sale_delivery_note", "rpc_update_delivery_note",
                    "rpc_cancel_delivery_note", "rpc_commercial_issuer"):
            assert rpc in called, f"falta la llamada a {rpc}"

    @pytest.mark.asyncio
    async def test_create_sends_key_first_and_lines_as_jsonb(self):
        from backend.repositories.delivery_note_repository import DeliveryNoteRepository

        conn = _RecordingConn()
        created = await DeliveryNoteRepository(conn).create_delivery_note(
            idempotency_key=IDEM_KEY, client_id=CLIENT_ID, branch_id=BRANCH_ID,
            delivery_address="San Martín 123", notes="n",
            items=[{"product_id": PRODUCT_ID, "quantity": "2", "price": "750.50", "subtotal": "1501", "unit_id": None}],
        )

        query, args = conn.queries[0]
        assert "rpc_create_sale_delivery_note($1::text, $2::uuid, $3::uuid, $4::text, $5::text, $6::jsonb)" in query
        assert args[:5] == (IDEM_KEY, CLIENT_ID, BRANCH_ID, "San Martín 123", "n")
        assert json.loads(args[5])[0]["price"] == "750.50"
        assert created["id"] == DN_ID

    @pytest.mark.asyncio
    async def test_update_ships_the_expected_revision(self):
        from backend.repositories.delivery_note_repository import DeliveryNoteRepository

        conn = _RecordingConn()
        await DeliveryNoteRepository(conn).update_delivery_note(
            DN_ID, expected_revision=4, client_id=CLIENT_ID, branch_id=BRANCH_ID,
            delivery_address=None, notes=None, items=[_item_in()],
        )
        query, args = conn.queries[0]
        assert "rpc_update_delivery_note($1::uuid, $2::integer, $3::uuid, $4::uuid, $5::text, $6::text, $7::jsonb)" in query
        assert args[0] == DN_ID and args[1] == 4

    @pytest.mark.asyncio
    async def test_cancel_ships_revision_and_reason(self):
        from backend.repositories.delivery_note_repository import DeliveryNoteRepository

        conn = _RecordingConn()
        await DeliveryNoteRepository(conn).cancel_delivery_note(DN_ID, expected_revision=5, reason="Error de carga")
        query, args = conn.queries[0]
        assert "rpc_cancel_delivery_note($1::uuid, $2::integer, $3::text)" in query
        assert args == (DN_ID, 5, "Error de carga")


class TestRepositoryReads:
    @pytest.mark.asyncio
    async def test_get_is_scoped_by_account_in_every_query_and_returns_items_and_history(self):
        from backend.repositories.delivery_note_repository import DeliveryNoteRepository

        conn = AsyncMock()
        conn.fetchrow.return_value = {"id": DN_ID, "account_id": ACCOUNT_ID, "direction": "sale", "number": 3}
        conn.fetch.side_effect = [
            [{"id": "i1", "line_no": 1, "product_id": PRODUCT_ID, "unit_symbol": "kg", "product_deleted": False}],
            [{"from_status": None, "to_status": "issued", "performed_by": TEST_USER_ID,
              "reason": None, "occurred_at": datetime.datetime(2026, 10, 2, tzinfo=datetime.timezone.utc)}],
        ]

        record = await DeliveryNoteRepository(conn).get_delivery_note(DN_ID, ACCOUNT_ID)

        assert record["items"][0]["unit_symbol"] == "kg"
        assert record["history"][0]["to_status"] == "issued"
        header_sql = conn.fetchrow.await_args.args[0]
        assert "dn.account_id = $2::uuid" in header_sql
        for call in conn.fetch.await_args_list:
            sql = call.args[0]
            assert "account_id = $2::uuid" in sql, "cada lectura filtra por account_id explícito"
        history_sql = conn.fetch.await_args_list[1].args[0]
        assert "document_status_history" in history_sql
        assert "'delivery_note_' || " in history_sql or "delivery_note_sale" in history_sql

    @pytest.mark.asyncio
    async def test_get_of_a_foreign_note_is_none_and_skips_the_detail_queries(self):
        from backend.repositories.delivery_note_repository import DeliveryNoteRepository

        conn = AsyncMock()
        conn.fetchrow.return_value = None
        assert await DeliveryNoteRepository(conn).get_delivery_note(DN_ID, ACCOUNT_ID) is None
        conn.fetch.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_list_count_and_page_share_the_same_filters_and_args(self):
        from backend.repositories.delivery_note_repository import DeliveryNoteRepository

        conn = AsyncMock()
        conn.fetchval.return_value = 7
        conn.fetch.return_value = []
        rows, total = await DeliveryNoteRepository(conn).list_delivery_notes(
            ACCOUNT_ID, page=2, page_size=10, direction="sale", status="issued",
            client_id=CLIENT_ID, branch_id=BRANCH_ID, text="50%_ana", number=12,
        )

        assert rows == [] and total == 7
        count_sql, *count_args = conn.fetchval.await_args.args
        page_sql, *page_args = conn.fetch.await_args.args
        assert count_args == page_args[:-2]
        assert page_args[-2:] == [10, 20]
        assert "dn.account_id = $1::uuid" in count_sql and "dn.account_id = $1::uuid" in page_sql
        # los comodines de LIKE del texto del usuario se escapan
        # (cuenta, sentido, cliente, sucursal, texto, número, estado)
        assert count_args[4] == "%50\\%\\_ana%"
        assert count_args[5] == 12
        assert count_args[6] == "issued"
        # orden estable y reciente primero
        assert "ORDER BY" in page_sql and "dn.id" in page_sql.split("ORDER BY")[1]

    @pytest.mark.asyncio
    async def test_summary_counts_only_issued_with_the_same_non_status_filters(self):
        from backend.repositories.delivery_note_repository import DeliveryNoteRepository

        conn = AsyncMock()
        conn.fetchrow.return_value = {"pending_count": 3, "pending_total": Decimal("4500.00")}
        summary = await DeliveryNoteRepository(conn).pending_summary(
            ACCOUNT_ID, direction="sale", client_id=None, branch_id=BRANCH_ID, text=None, number=None)

        assert summary == {"pending_count": 3, "pending_total": Decimal("4500.00")}
        sql = conn.fetchrow.await_args.args[0]
        assert "dn.status = 'issued'" in sql
        assert "dn.account_id = $1::uuid" in sql

    @pytest.mark.asyncio
    async def test_summary_of_an_empty_result_is_zero_not_none(self):
        from backend.repositories.delivery_note_repository import DeliveryNoteRepository

        conn = AsyncMock()
        conn.fetchrow.return_value = None
        summary = await DeliveryNoteRepository(conn).pending_summary(
            ACCOUNT_ID, direction=None, client_id=None, branch_id=None, text=None, number=None)
        assert summary == {"pending_count": 0, "pending_total": Decimal("0")}


# ══════════════════════════════════════════════════════════════════════════════
# endpoints HTTP
# ══════════════════════════════════════════════════════════════════════════════

@pytest.fixture
def repo_override(mock_pool):
    from backend.main import app
    from backend.routers.delivery_notes import get_delivery_note_repo

    repo = _repo()
    app.dependency_overrides[get_delivery_note_repo] = lambda: repo
    try:
        yield repo, mock_pool
    finally:
        app.dependency_overrides.pop(get_delivery_note_repo, None)


def _headers(*roles: str, key: str | None = IDEM_KEY) -> dict:
    headers = {"Authorization": f"Bearer {make_token({'app_metadata': {'account_roles': list(roles)}})}"}
    if key is not None:
        headers["Idempotency-Key"] = key
    return headers


def _body(**over) -> dict:
    data = {
        "client_id": CLIENT_ID,
        "branch_id": BRANCH_ID,
        "delivery_address": "San Martín 123",
        "items": [_item_in()],
    }
    data.update(over)
    return data


def _update_body(**over) -> dict:
    data = {
        "revision": 1, "client_id": CLIENT_ID, "branch_id": BRANCH_ID,
        "delivery_address": None, "notes": None, "items": [_item_in()],
    }
    data.update(over)
    return data


class TestEndpoints:
    async def test_create_returns_201_with_the_full_note_and_the_key_reaches_the_rpc(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post("/delivery-notes", json=_body(), headers=_headers("seller"))

        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert body["id"] == DN_ID and body["number_label"] == "R-00000012" and body["revision"] == 1
        assert body["replayed"] is False
        assert repo.create_delivery_note.await_args.kwargs["idempotency_key"] == IDEM_KEY

    async def test_a_replay_is_200_with_replayed_true(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        repo.create_delivery_note.return_value = {**_dn_record(), "replayed": True}
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post("/delivery-notes", json=_body(), headers=_headers("seller"))

        assert resp.status_code == 200, resp.text
        assert resp.json()["replayed"] is True

    async def test_create_without_idempotency_key_is_rejected_before_the_rpc(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post("/delivery-notes", json=_body(), headers=_headers("seller", key=None))

        assert resp.status_code == 422
        assert resp.headers["content-type"].startswith("application/problem+json")
        assert resp.json()["code"] == "idempotency_key_required"
        repo.create_delivery_note.assert_not_awaited()

    async def test_the_key_in_the_body_is_not_accepted(self, async_client, repo_override):
        """El remito nace con el contrato nuevo: la clave viaja SIEMPRE por el
        header (sin el fallback deprecado del body)."""
        repo, (pool, conn) = repo_override
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/delivery-notes", json=_body(idempotency_key="from-body"), headers=_headers("seller", key=None))

        assert resp.status_code == 422
        repo.create_delivery_note.assert_not_awaited()

    async def test_roles_over_http(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        cancel = (f"/delivery-notes/{DN_ID}/cancel", {"revision": 1, "reason": "Error de carga"})
        calls = [
            ("post", "/delivery-notes", _body()),
            ("put", f"/delivery-notes/{DN_ID}", _update_body()),
            ("post", *cancel),
        ]
        with patch("backend.core.database.pool", pool):
            # el cajero no emite, no edita ni anula
            conn.fetchval = account_roles_fetchval(["cashier"])
            for verb, url, body in calls:
                resp = await getattr(async_client, verb)(url, json=body, headers=_headers("cashier"))
                assert resp.status_code == 403, f"{verb} {url}: {resp.status_code}"
                assert resp.headers["content-type"].startswith("application/problem+json")
                assert resp.json()["code"] == "insufficient_role"
            # el vendedor emite y edita, pero no anula
            conn.fetchval = account_roles_fetchval(["seller"])
            for verb, url, body in calls[:2]:
                resp = await getattr(async_client, verb)(url, json=body, headers=_headers("seller"))
                assert resp.status_code in (200, 201), f"{verb} {url}: {resp.text}"
            denied = await async_client.post(*cancel[:1], json=cancel[1], headers=_headers("seller"))
            assert denied.status_code == 403
            repo.cancel_delivery_note.assert_not_awaited()
            # el administrador anula
            conn.fetchval = account_roles_fetchval(["admin"])
            allowed = await async_client.post(*cancel[:1], json=cancel[1], headers=_headers("admin"))
            assert allowed.status_code == 200, allowed.text

        repo.cancel_delivery_note.assert_awaited_once()

    async def test_every_member_can_read(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        with patch("backend.core.database.pool", pool):
            for role in ("cashier", "viewer", "purchases"):
                listing = await async_client.get("/delivery-notes", headers=_headers(role))
                detail = await async_client.get(f"/delivery-notes/{DN_ID}", headers=_headers(role))
                pdf = await async_client.get(f"/delivery-notes/{DN_ID}/pdf", headers=_headers(role))
                assert (listing.status_code, detail.status_code, pdf.status_code) == (200, 200, 200), role

    async def test_list_envelope_and_query_params(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        row = {k: v for k, v in _dn_record().items() if k not in ("items", "history")}
        row["item_count"] = 2
        repo.list_delivery_notes.return_value = ([row], 1)
        repo.pending_summary.return_value = {"pending_count": 1, "pending_total": Decimal("1500.00")}
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                f"/delivery-notes?direction=sale&status=issued&client_id={CLIENT_ID}&branch_id={BRANCH_ID}"
                "&q=R-12&page=0&page_size=10",
                headers=_headers("seller", key=None),
            )

        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert set(body) == {"items", "total", "page", "pages", "summary"}
        assert body["items"][0]["number_label"] == "R-00000012" and body["items"][0]["item_count"] == 2
        assert body["summary"] == {"pending_count": 1, "pending_total": "1500.00"}
        repo.list_delivery_notes.assert_awaited_once_with(
            ACCOUNT_ID, page=0, page_size=10, direction="sale", status="issued",
            client_id=CLIENT_ID, branch_id=BRANCH_ID, text="R-12", number=12,
        )

    @pytest.mark.parametrize("query", ["status=draft", "direction=other", "page_size=0", "page_size=101", "page=-1"])
    async def test_list_rejects_invalid_filters(self, async_client, repo_override, query):
        repo, (pool, conn) = repo_override
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(f"/delivery-notes?{query}", headers=_headers("seller"))
        assert resp.status_code == 422
        repo.list_delivery_notes.assert_not_awaited()

    async def test_create_validation_happens_before_the_database(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        bad_bodies = [
            _body(direction="purchase"),
            {k: v for k, v in _body().items() if k != "client_id"},
            {k: v for k, v in _body().items() if k != "branch_id"},
            _body(items=[]),
            _body(items=[{"quantity": "1", "price": "10", "subtotal": "10"}]),  # línea sin producto
        ]
        with patch("backend.core.database.pool", pool):
            for body in bad_bodies:
                resp = await async_client.post("/delivery-notes", json=body, headers=_headers("seller"))
                assert resp.status_code == 422, body
        repo.create_delivery_note.assert_not_awaited()

    async def test_update_conflict_is_409_problem_with_code(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        repo.update_delivery_note.side_effect = _pg_error("P0409", "delivery_note_changed: versión 1 -> 2")
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(f"/delivery-notes/{DN_ID}", json=_update_body(), headers=_headers("seller"))

        assert resp.status_code == 409
        assert resp.headers["content-type"].startswith("application/problem+json")
        assert resp.json()["code"] == "delivery_note_changed"

    async def test_stock_shortage_is_a_409_with_the_literal(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        repo.create_delivery_note.side_effect = _pg_error(
            "P0409", "stock_insuficiente para producto Remera: disponible 1, solicitado 3")
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post("/delivery-notes", json=_body(), headers=_headers("seller"))

        assert resp.status_code == 409
        assert resp.json()["code"] == "stock_insuficiente"
        assert "disponible 1" in resp.json()["detail"]

    async def test_cancel_requires_a_reason(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        conn.fetchval = account_roles_fetchval(["admin"])
        with patch("backend.core.database.pool", pool):
            for body in ({"revision": 1}, {"revision": 1, "reason": ""}, {"revision": 1, "reason": "ab"}):
                resp = await async_client.post(f"/delivery-notes/{DN_ID}/cancel", json=body, headers=_headers("admin"))
                assert resp.status_code == 422, body
        repo.cancel_delivery_note.assert_not_awaited()

    async def test_get_detail_exposes_issuer_name_and_history(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        repo.get_delivery_note.return_value = _dn_record(history=[{
            "from_status": None, "to_status": "issued", "performed_by": TEST_USER_ID,
            "reason": None, "occurred_at": datetime.datetime(2026, 10, 2, tzinfo=datetime.timezone.utc),
        }])
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(f"/delivery-notes/{DN_ID}", headers=_headers("seller"))

        assert resp.status_code == 200
        body = resp.json()
        assert body["issuer_name"] == "Sumar"
        assert body["history"][0]["to_status"] == "issued"
        assert body["converted_sales_order_id"] is None

    async def test_write_responses_do_not_resolve_the_issuer(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post("/delivery-notes", json=_body(), headers=_headers("seller"))
        assert resp.status_code == 201
        assert resp.json()["issuer_name"] is None
        repo.get_commercial_issuer.assert_not_awaited()

    async def test_get_missing_note_is_404_problem(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        repo.get_delivery_note.return_value = None
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(f"/delivery-notes/{DN_ID}", headers=_headers("seller"))

        assert resp.status_code == 404
        assert resp.headers["content-type"].startswith("application/problem+json")
        assert resp.json()["code"] == "delivery_note_not_found"

    async def test_a_foreign_note_answers_exactly_like_a_missing_one(self, async_client, repo_override):
        """Tenencia: el repositorio devuelve None para un id de otra cuenta
        (filtra por la cuenta del header), así que la respuesta es la misma
        que la de un id inexistente."""
        repo, (pool, conn) = repo_override
        repo.get_delivery_note.return_value = None
        with patch("backend.core.database.pool", pool):
            foreign = await async_client.get(f"/delivery-notes/{uuid.uuid4()}", headers=_headers("seller"))
            missing = await async_client.get(f"/delivery-notes/{uuid.uuid4()}", headers=_headers("seller"))
        assert foreign.status_code == missing.status_code == 404
        assert foreign.json() == missing.json()

    async def test_a_non_uuid_id_is_422(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get("/delivery-notes/not-a-uuid", headers=_headers("seller"))
        assert resp.status_code == 422

    async def test_unauthenticated_is_401(self, async_client, repo_override):
        for url in ("/delivery-notes", f"/delivery-notes/{DN_ID}", f"/delivery-notes/{DN_ID}/pdf"):
            assert (await async_client.get(url)).status_code == 401, url
        assert (await async_client.post("/delivery-notes", json=_body())).status_code == 401


class TestPdfEndpoint:
    async def test_default_download_is_priceless_inline_with_the_number_in_the_filename(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(f"/delivery-notes/{DN_ID}/pdf", headers=_headers("seller"))

        assert resp.status_code == 200
        assert resp.headers["content-type"] == "application/pdf"
        assert resp.headers["content-disposition"] == 'inline; filename="remito-R-00000012.pdf"'
        assert resp.headers["cache-control"] == "private, no-store"
        assert resp.content.startswith(b"%PDF")

    async def test_attachment_with_prices(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                f"/delivery-notes/{DN_ID}/pdf?disposition=attachment&show_prices=true", headers=_headers("seller"))

        assert resp.status_code == 200
        assert resp.headers["content-disposition"] == 'attachment; filename="remito-R-00000012-con-precios.pdf"'

    @pytest.mark.parametrize("query", ["disposition=download", "show_prices=quizas", "show_prices=2"])
    async def test_invalid_parameters_are_422(self, async_client, repo_override, query):
        repo, (pool, conn) = repo_override
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(f"/delivery-notes/{DN_ID}/pdf?{query}", headers=_headers("seller"))
        assert resp.status_code == 422

    async def test_pdf_of_a_missing_or_foreign_note_is_404(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        repo.get_delivery_note.return_value = None
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(f"/delivery-notes/{DN_ID}/pdf", headers=_headers("seller"))
        assert resp.status_code == 404 and resp.json()["code"] == "delivery_note_not_found"

    @pytest.mark.parametrize("status", ["issued", "converted", "canceled"])
    async def test_pdf_is_served_in_every_state(self, async_client, repo_override, status):
        repo, (pool, conn) = repo_override
        repo.get_delivery_note.return_value = _dn_record(status=status)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(f"/delivery-notes/{DN_ID}/pdf", headers=_headers("seller"))
        assert resp.status_code == 200, status


class TestRouterIsRegistered:
    def test_the_routes_exist_with_the_agreed_verbs(self):
        from backend.main import app

        routes = {(m, r.path) for r in app.routes if hasattr(r, "methods") for m in r.methods}
        assert ("GET", "/delivery-notes") in routes
        assert ("POST", "/delivery-notes") in routes
        assert ("GET", "/delivery-notes/{delivery_note_id}") in routes
        assert ("PUT", "/delivery-notes/{delivery_note_id}") in routes
        assert ("POST", "/delivery-notes/{delivery_note_id}/cancel") in routes
        assert ("GET", "/delivery-notes/{delivery_note_id}/pdf") in routes
        # la conversión es de la tanda B
        assert ("POST", "/delivery-notes/{delivery_note_id}/convert") not in routes
        # sin borrado: un remito nunca se borra, se anula
        assert ("DELETE", "/delivery-notes/{delivery_note_id}") not in routes
