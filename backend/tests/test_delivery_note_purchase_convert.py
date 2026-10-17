"""
remitos-compra (tanda B, tareas 7.1-7.2) — conversión del remito de compra en
compra, 3 capas.

Strict TDD: este archivo se escribió ANTES de `PurchaseDeliveryNoteConvertIn/Out`,
`DeliveryNoteRepository.convert_to_purchase`,
`services.delivery_notes.convert_delivery_note_to_purchase` y
`POST /delivery-notes/{id}/convert-to-purchase`. Cubre la mitad "con dobles"
(schemas, capacidad atada al catálogo, mapeo de errores, guard de rol, SQL del
repositorio, endpoint y read models de compras y de remitos). La mitad que
persiste de verdad (stock idéntico, caja, cuenta corriente, borrado, edición
bloqueada) está en `test_delivery_note_purchase_convert_integration.py` (marcada
`integration`); la evidencia de CI del esquema es el gate SQL
supabase/tests/test_remito_a_compra.sql.

Spec: openspec/changes/remitos-compra/specs/delivery-note/spec.md (conversión),
purchase-operation, operation-delete-compensation y operation-edit-context;
design.md D8, D9, D11, D12, D13.
"""
from __future__ import annotations

import re
import uuid
from decimal import Decimal
from pathlib import Path
from unittest.mock import AsyncMock, patch

import asyncpg
import pytest
from fastapi import HTTPException
from pydantic import ValidationError

from backend.tests.conftest import account_roles_fetchval, effective_routes, make_token, tenant_token
from backend.tests.test_delivery_notes_module import (
    ACCOUNT_ID,
    BRANCH_ID,
    DN_ID,
    IDEM_KEY,
    _auth,
    _conn,
    _dn_record,
    _headers,
    _pg_error,
    _repo,
    repo_override,  # noqa: F401  (fixture reutilizada)
)

PM_ID = "99999999-9999-9999-9999-999999999999"
CASH_ID = "88888888-8888-8888-8888-888888888888"
BANK_ID = "77777777-7777-7777-7777-777777777777"
CC_ID = "33333333-3333-3333-3333-333333333333"
OPERATION_ID = "66666666-6666-6666-6666-666666666666"
SUPPLIER_ID = "dddddddd-dddd-dddd-dddd-dddddddddddd"
PURCHASE_ID = "11111111-1111-1111-1111-111111111111"
REPO_ROOT = Path(__file__).resolve().parents[2]
MIGRATION_B = "supabase/migrations/20261081000001_remitos_compra_conversion.sql"


def _migration_b() -> str:
    return (REPO_ROOT / MIGRATION_B).read_text(encoding="utf-8")


def _normalized(sql: str) -> str:
    return " ".join(sql.split())


def _convert_in(**over):
    from backend.schemas.delivery_notes import PurchaseDeliveryNoteConvertIn

    data = {"expected_revision": 2, "payment_method_id": PM_ID}
    data.update(over)
    return PurchaseDeliveryNoteConvertIn(**data)


def _rpc_result(**over) -> dict:
    base = {
        "delivery_note_id": DN_ID,
        "delivery_note_number": 12,
        "operation_id": OPERATION_ID,
        "total": Decimal("1500.00"),
        "replayed": False,
    }
    base.update(over)
    return base


def _convert_repo(**returns) -> AsyncMock:
    repo = _repo()
    repo.convert_to_purchase.return_value = _rpc_result()
    for name, value in returns.items():
        getattr(repo, name).return_value = value
    return repo


def _convert_body(**over) -> dict:
    data = {"expected_revision": 2, "payment_method_id": PM_ID}
    data.update(over)
    return data


ROUTE = f"/delivery-notes/{DN_ID}/convert-to-purchase"


# ══════════════════════════════════════════════════════════════════════════════
# 7.1 schemas
# ══════════════════════════════════════════════════════════════════════════════

class TestConvertSchemas:
    def test_the_minimum_is_the_revision_and_the_payment_method(self):
        payload = _convert_in()
        assert payload.expected_revision == 2
        assert str(payload.payment_method_id) == PM_ID
        for optional in ("date", "cash_session_id", "bank_account_id", "cost_center_id", "due_date", "description"):
            assert getattr(payload, optional) is None, optional

    def test_the_closing_fields_are_carried(self):
        payload = _convert_in(
            date="2026-10-15", cash_session_id=CASH_ID, bank_account_id=BANK_ID,
            cost_center_id=CC_ID, due_date="2026-11-14", description="Factura A 0001-00001234")
        assert str(payload.date) == "2026-10-15" and str(payload.due_date) == "2026-11-14"
        assert str(payload.cash_session_id) == CASH_ID and str(payload.bank_account_id) == BANK_ID
        assert str(payload.cost_center_id) == CC_ID and payload.description == "Factura A 0001-00001234"

    @pytest.mark.parametrize("missing", ["expected_revision", "payment_method_id"])
    def test_revision_and_payment_method_are_required(self, missing):
        """OQ-RC4: la compra nacida del remito exige forma de pago (la directa no)."""
        from backend.schemas.delivery_notes import PurchaseDeliveryNoteConvertIn

        data = {"expected_revision": 2, "payment_method_id": PM_ID}
        data.pop(missing)
        with pytest.raises(ValidationError):
            PurchaseDeliveryNoteConvertIn(**data)

    @pytest.mark.parametrize("bad", [0, -1])
    def test_revision_is_at_least_one(self, bad):
        with pytest.raises(ValidationError):
            _convert_in(expected_revision=bad)

    def test_the_supplier_and_the_branch_are_not_inputs_because_they_are_the_notes_own(self):
        """La compra se imputa al proveedor y a la sucursal del remito (D8): la
        mercadería entró ahí y la deuda es con ese proveedor. Tampoco hay
        `idempotency_key` (viaja por header) ni un origen de remito (lo toma la
        RPC del remito que ella misma bloqueó)."""
        from backend.schemas.delivery_notes import PurchaseDeliveryNoteConvertIn

        fields = set(PurchaseDeliveryNoteConvertIn.model_fields)
        assert not ({"branch_id", "supplier_id", "idempotency_key", "source_delivery_note_id", "items"} & fields)

    def test_the_description_has_a_cap(self):
        _convert_in(description="x" * 500)
        with pytest.raises(ValidationError):
            _convert_in(description="x" * 501)

    def test_out_carries_the_note_the_operation_and_the_replay_flag(self):
        from backend.schemas.delivery_notes import PurchaseDeliveryNoteConvertOut

        out = PurchaseDeliveryNoteConvertOut(**_rpc_result(), delivery_note_number_label="RC-00000012")
        assert str(out.delivery_note_id) == DN_ID and out.delivery_note_number == 12
        assert out.delivery_note_number_label == "RC-00000012"
        assert str(out.operation_id) == OPERATION_ID
        assert out.total == Decimal("1500.00") and out.replayed is False
        assert not hasattr(out, "sales_order_id")

    def test_out_replayed_defaults_to_false(self):
        from backend.schemas.delivery_notes import PurchaseDeliveryNoteConvertOut

        data = _rpc_result()
        data.pop("replayed")
        assert PurchaseDeliveryNoteConvertOut(**data).replayed is False


# ══════════════════════════════════════════════════════════════════════════════
# 7.1 capacidad atada al catálogo de la FSM
# ══════════════════════════════════════════════════════════════════════════════

def _catalog_rows(sql: str) -> dict:
    rows = re.findall(
        r"\('delivery_note_purchase',\s*(NULL|'[a-z_]+'),\s*'([a-z_]+)',\s*(?:true|false),\s*(?:true|false),\s*(ARRAY\[[^\]]*\]|NULL)",
        sql,
    )
    return {
        (frm.strip("'") if frm != "NULL" else None, to): (
            None if roles == "NULL" else frozenset(re.findall(r"'([a-z_]+)'", roles))
        )
        for frm, to, roles in rows
    }


class TestConvertCapability:
    def test_the_conversion_uses_the_dedicated_capability(self):
        from backend.core.rbac import CAN_CONVERT_PURCHASE_DELIVERY_NOTE

        assert CAN_CONVERT_PURCHASE_DELIVERY_NOTE == frozenset({"owner", "admin", "purchases", "stock"})

    def test_it_is_the_issued_to_converted_row_of_the_catalog(self):
        """La capacidad no es una segunda política: la fila `issued -> converted`
        de `delivery_note_purchase` que siembra la tanda B lista EXACTAMENTE los
        roles de la capacidad (OQ-RC6: `stock` y `purchases` convierten)."""
        from backend.core.rbac import CAN_CONVERT_PURCHASE_DELIVERY_NOTE

        by_transition = _catalog_rows(_migration_b())
        assert by_transition.get(("issued", "converted")) == CAN_CONVERT_PURCHASE_DELIVERY_NOTE
        # control negativo del propio test: una transición inexistente no matchea
        assert by_transition.get(("issued", "no_existe")) is None

    def test_the_way_back_has_no_role_because_the_delete_already_demanded_one(self):
        """`converted -> issued` es de sistema (allowed_role NULL): la dispara sólo
        el borrado de la compra, que exige administrador o dueño antes de cualquier
        efecto (`CAN_VOID_DELIVERY_NOTE`)."""
        by_transition = _catalog_rows(_migration_b())
        assert ("converted", "issued") in by_transition and by_transition[("converted", "issued")] is None

    def test_convert_is_not_a_sensitive_capability(self):
        from backend.core.rbac import (
            CAN_CONVERT_PURCHASE_DELIVERY_NOTE,
            CAN_VOID_DELIVERY_NOTE,
            is_sensitive_capability,
        )

        assert is_sensitive_capability(CAN_CONVERT_PURCHASE_DELIVERY_NOTE) is False
        assert is_sensitive_capability(CAN_VOID_DELIVERY_NOTE) is True

    def test_deleting_a_purchase_of_a_note_needs_the_void_capability(self):
        """D9: el borrado de la compra de un remito exige el rol de ANULAR el
        remito (admin/owner), no el de convertir."""
        from backend.core.rbac import CAN_CONVERT_PURCHASE_DELIVERY_NOTE, CAN_VOID_DELIVERY_NOTE

        assert CAN_VOID_DELIVERY_NOTE < CAN_CONVERT_PURCHASE_DELIVERY_NOTE


# ══════════════════════════════════════════════════════════════════════════════
# 7.1 mapeo de errores: cada literal que la tanda B levanta tiene su caso
# ══════════════════════════════════════════════════════════════════════════════

CONVERT_LITERALS = [
    ("P0409", "delivery_note_changed: el remito cambió desde que lo abriste (versión 1 vs 2) — recargalo", 409, "delivery_note_changed"),
    ("P0409", "delivery_note_invalid_state: el remito está converted y no se puede convertir", 409, "delivery_note_invalid_state"),
    ("P0409", "idempotency_key_conflict: la clave ya se usó para otra operación", 409, "idempotency_key_conflict"),
    ("P0409", "delivery_note_purchase_mismatch: el origen x no es un remito de compra pendiente de esta cuenta", 409, "delivery_note_purchase_mismatch"),
    ("P0404", "delivery_note_not_found: dddd", 404, "delivery_note_not_found"),
    ("P0404", "delivery_note_supplier_unavailable: el proveedor del remito fue dado de baja: editá el remito", 404, "delivery_note_supplier_unavailable"),
    ("P0404", "supplier_not_found or not active for this account", 404, "supplier_not_found"),
    ("P0404", "payment_method_not_found or not active for this account", 404, "payment_method_not_found"),
    ("P0422", "branch_closed: la sucursal del remito está desactivada o cerrada — reactivala para convertir el remito", 422, "branch_closed"),
    ("P0422", "no_branch_found: la cuenta no tiene una sucursal operativa a la cual asignar la compra", 422, "no_branch_found"),
    ("P0422", "cash_optin_requires_open_session: la sesión de caja debe estar abierta y pertenecer a la sucursal efectiva de la compra", 422, "cash_optin_requires_open_session"),
    ("P0422", "cash_optin_requires_today: sólo se puede registrar en caja una compra fechada hoy (2026-10-15)", 422, "cash_optin_requires_today"),
    ("P0422", "cash_optin_requires_cash_kind: p_cash_session_id sólo aplica si el kind derivado es cash (recibido: transfer)", 422, "cash_optin_requires_cash_kind"),
    ("P0400", "delivery_note_price_required: cargá el precio de compra de todas las líneas antes de convertir el remito en compra", 400, "delivery_note_price_required"),
    ("P0400", "delivery_note_purchase_date_before_receipt: la compra no puede ser anterior a la fecha de recepción del remito (2026-10-14)", 400, "delivery_note_purchase_date_before_receipt"),
    ("P0400", "delivery_note_items_from_source: las líneas de una compra con origen de remito salen del remito, no del request", 400, "delivery_note_items_from_source"),
    ("P0400", "delivery_note_revision_required: falta la versión del remito que se convierte", 400, "delivery_note_revision_required"),
    ("P0400", "payment_method_required: la conversión exige una forma de pago del catálogo", 400, "payment_method_required"),
    ("P0400", "credit_requires_supplier: una compra a crédito necesita un proveedor identificado", 400, "credit_requires_supplier"),
    ("P0400", "idempotency_key is required", 400, "idempotency_key"),
    ("P0403", "insufficient_role: tu rol no permite convertir remitos de compra", 403, "insufficient_role"),
    ("P0401", "unauthorized", 403, "unauthorized"),
]

# Lo que la compra nacida de un remito levanta al editarla o borrarla, y la
# protección del puente (disparador): llegan por los endpoints de /purchases.
PURCHASE_SIDE_LITERALS = [
    ("P0423", "delivery_note_purchase_locked: la compra nació del remito RC-00000012: para corregirla, eliminá la compra", 409, "delivery_note_purchase_locked"),
    ("P0423", "delivery_note_locked_converted: el remito ya se convirtió en la compra", 409, "delivery_note_locked_converted"),
    ("P0403", "delivery_note_purchase_delete_forbidden: borrar esta compra reabre el remito RC-00000012 y lo deja anulable: requiere administrador o dueño", 403, "delivery_note_purchase_delete_forbidden"),
    ("P0422", "delivery_note_branch_inactive: la sucursal del remito RC-00000012 está desactivada o cerrada — reactivala antes de eliminar la compra", 422, "delivery_note_branch_inactive"),
    ("P0403", "delivery_note_source_protected: el origen de remito de una compra lo escribe sólo la conversión del remito", 403, "delivery_note_source_protected"),
]


class TestConvertProblemMapping:
    @pytest.mark.parametrize("sqlstate,message,status,code", CONVERT_LITERALS + PURCHASE_SIDE_LITERALS)
    def test_literal_code_and_status(self, sqlstate, message, status, code):
        from backend.core.errors import problem_from_pg_error

        problem = problem_from_pg_error(_pg_error(sqlstate, message))

        assert problem.status_code == status
        assert problem.code == code
        assert message in str(problem.detail)

    @staticmethod
    def _body(sql: str, name: str) -> str:
        start = sql.index(f"CREATE OR REPLACE FUNCTION public.{name}(")
        end = sql.index("\n$function$;", start)
        return sql[start:end]

    def test_every_literal_the_conversion_and_the_core_raise_has_a_case(self):
        """Control de completitud sobre `rpc_convert_delivery_note_to_purchase` y
        `_purchase_operation_core` de la migración B: si SQL suma un literal nuevo,
        este test obliga a mapearlo."""
        sql = _migration_b()
        raised: set[str] = set()
        for name in ("rpc_convert_delivery_note_to_purchase", "_purchase_operation_core"):
            raised |= set(re.findall(r"RAISE EXCEPTION '([a-z][a-z0-9_]*)[:'%\s]", self._body(sql, name)))
        raised -= {"Not", "Usuario", "Product", "Quantity", "Amount", "Too", "p_items", "branch_not_found",
                   "cost_center_not_found", "idempotency_key"}  # mensajes del núcleo de la compra directa, sin token estable
        covered = {code for _, _, _, code in CONVERT_LITERALS}
        assert raised <= covered, f"literales sin caso: {sorted(raised - covered)}"

    def test_the_purchase_side_literals_are_raised_by_the_migration(self):
        sql = _migration_b()
        for _, _, _, code in PURCHASE_SIDE_LITERALS:
            if code == "delivery_note_locked_converted":
                continue  # lo levanta la anulación de la tanda A
            assert f"{code}:" in sql, code


# ══════════════════════════════════════════════════════════════════════════════
# 7.2 service
# ══════════════════════════════════════════════════════════════════════════════

CONVERT_ROLES = {
    "allowed": ["stock", "purchases", "admin", "owner"],
    "denied": ["seller", "cashier", "accountant", "viewer"],
}


class TestConvertService:
    @pytest.mark.asyncio
    @pytest.mark.parametrize("role", CONVERT_ROLES["denied"])
    async def test_denied_roles_get_403_without_calling_the_rpc(self, role):
        from backend.services import delivery_notes as svc

        repo = _convert_repo()
        with pytest.raises(HTTPException) as info:
            await svc.convert_delivery_note_to_purchase(
                repo, _auth(role), ACCOUNT_ID, DN_ID, _convert_in(), IDEM_KEY, conn=_conn(role))

        assert info.value.status_code == 403
        assert getattr(info.value, "code", None) == "insufficient_role"
        repo.convert_to_purchase.assert_not_awaited()

    @pytest.mark.asyncio
    @pytest.mark.parametrize("role", CONVERT_ROLES["allowed"])
    async def test_allowed_roles_reach_the_rpc(self, role):
        from backend.services import delivery_notes as svc

        repo = _convert_repo()
        await svc.convert_delivery_note_to_purchase(
            repo, _auth(role), ACCOUNT_ID, DN_ID, _convert_in(), IDEM_KEY, conn=_conn(role))

        repo.convert_to_purchase.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_roles_are_a_set_union_not_the_first_role(self):
        """Un usuario vendedor Y de depósito convierte: se evalúa el conjunto."""
        from backend.services import delivery_notes as svc

        repo = _convert_repo()
        await svc.convert_delivery_note_to_purchase(
            repo, _auth("seller", "stock"), ACCOUNT_ID, DN_ID, _convert_in(), IDEM_KEY, conn=_conn("seller", "stock"))
        repo.convert_to_purchase.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_the_rpc_receives_exactly_what_the_user_chose_and_nothing_else(self):
        from backend.services import delivery_notes as svc

        repo = _convert_repo()
        await svc.convert_delivery_note_to_purchase(
            repo, _auth("purchases"), ACCOUNT_ID, DN_ID,
            _convert_in(expected_revision=5, date="2026-10-15", cash_session_id=CASH_ID, bank_account_id=BANK_ID,
                        cost_center_id=CC_ID, due_date="2026-11-14", description="Factura 1234"),
            IDEM_KEY, conn=_conn("purchases"))

        assert repo.convert_to_purchase.await_args.args == (DN_ID,)
        kwargs = repo.convert_to_purchase.await_args.kwargs
        assert kwargs == {
            "idempotency_key": IDEM_KEY,
            "expected_revision": 5,
            "payment_method_id": PM_ID,
            "date": kwargs["date"],
            "cash_session_id": CASH_ID,
            "bank_account_id": BANK_ID,
            "cost_center_id": CC_ID,
            "due_date": kwargs["due_date"],
            "description": "Factura 1234",
        }
        assert str(kwargs["date"]) == "2026-10-15" and str(kwargs["due_date"]) == "2026-11-14"

    @pytest.mark.asyncio
    async def test_optional_ids_travel_as_null_when_absent(self):
        from backend.services import delivery_notes as svc

        repo = _convert_repo()
        await svc.convert_delivery_note_to_purchase(
            repo, _auth("stock"), ACCOUNT_ID, DN_ID, _convert_in(), IDEM_KEY, conn=_conn("stock"))

        kwargs = repo.convert_to_purchase.await_args.kwargs
        for name in ("date", "cash_session_id", "bank_account_id", "cost_center_id", "due_date", "description"):
            assert kwargs[name] is None, name

    @pytest.mark.asyncio
    async def test_the_result_adds_the_visible_rc_number_of_the_note(self):
        from backend.services import delivery_notes as svc

        repo = _convert_repo()
        out = await svc.convert_delivery_note_to_purchase(
            repo, _auth("stock"), ACCOUNT_ID, DN_ID, _convert_in(), IDEM_KEY, conn=_conn("stock"))

        assert out["delivery_note_number_label"] == "RC-00000012"
        assert out["operation_id"] == OPERATION_ID and out["replayed"] is False

    @pytest.mark.asyncio
    async def test_a_replay_keeps_its_flag(self):
        from backend.services import delivery_notes as svc

        repo = _convert_repo(convert_to_purchase=_rpc_result(replayed=True))
        out = await svc.convert_delivery_note_to_purchase(
            repo, _auth("stock"), ACCOUNT_ID, DN_ID, _convert_in(), IDEM_KEY, conn=_conn("stock"))
        assert out["replayed"] is True

    @pytest.mark.asyncio
    async def test_without_a_resolved_key_it_is_a_wiring_bug_not_a_user_error(self):
        from backend.services import delivery_notes as svc

        repo = _convert_repo()
        with pytest.raises(ValueError):
            await svc.convert_delivery_note_to_purchase(
                repo, _auth("stock"), ACCOUNT_ID, DN_ID, _convert_in(), "", conn=_conn("stock"))
        repo.convert_to_purchase.assert_not_awaited()

    @pytest.mark.asyncio
    @pytest.mark.parametrize("sqlstate,message,status,code", CONVERT_LITERALS)
    async def test_every_business_error_surfaces_as_a_stable_problem(self, sqlstate, message, status, code):
        from backend.core.errors import ProblemHTTPException
        from backend.services import delivery_notes as svc

        repo = _convert_repo()
        repo.convert_to_purchase.side_effect = _pg_error(sqlstate, message)
        with pytest.raises(ProblemHTTPException) as info:
            await svc.convert_delivery_note_to_purchase(
                repo, _auth("stock"), ACCOUNT_ID, DN_ID, _convert_in(), IDEM_KEY, conn=_conn("stock"))

        assert info.value.status_code == status and info.value.code == code

    @pytest.mark.asyncio
    async def test_a_deadlock_is_a_409_concurrent_update_retry(self):
        from backend.core.errors import ProblemHTTPException
        from backend.services import delivery_notes as svc

        repo = _convert_repo()
        repo.convert_to_purchase.side_effect = asyncpg.DeadlockDetectedError("deadlock detected")
        with pytest.raises(ProblemHTTPException) as info:
            await svc.convert_delivery_note_to_purchase(
                repo, _auth("stock"), ACCOUNT_ID, DN_ID, _convert_in(), IDEM_KEY, conn=_conn("stock"))

        assert info.value.status_code == 409 and info.value.code == "concurrent_update_retry"

    @pytest.mark.asyncio
    async def test_an_unmapped_sqlstate_still_propagates_for_the_global_500(self):
        from backend.services import delivery_notes as svc

        repo = _convert_repo()
        repo.convert_to_purchase.side_effect = _pg_error("XX000", "boom")
        with pytest.raises(asyncpg.PostgresError):
            await svc.convert_delivery_note_to_purchase(
                repo, _auth("stock"), ACCOUNT_ID, DN_ID, _convert_in(), IDEM_KEY, conn=_conn("stock"))


# ══════════════════════════════════════════════════════════════════════════════
# 7.2 repository
# ══════════════════════════════════════════════════════════════════════════════

class _RecordingConn:
    def __init__(self, answer=None):
        self.calls: list[tuple[str, str, tuple]] = []
        self._answer = answer

    async def fetchval(self, query, *args):
        self.calls.append(("fetchval", query, args))
        return self._answer

    async def fetchrow(self, query, *args):
        self.calls.append(("fetchrow", query, args))
        return None

    async def fetch(self, query, *args):
        self.calls.append(("fetch", query, args))
        return []

    async def execute(self, query, *args):
        self.calls.append(("execute", query, args))


class TestConvertRepository:
    @pytest.mark.asyncio
    async def test_it_calls_the_rpc_with_the_agreed_argument_order_and_types(self):
        import datetime

        from backend.repositories.delivery_note_repository import DeliveryNoteRepository

        conn = _RecordingConn(answer={"delivery_note_id": DN_ID, "replayed": False})
        out = await DeliveryNoteRepository(conn).convert_to_purchase(
            DN_ID, idempotency_key=IDEM_KEY, expected_revision=3, payment_method_id=PM_ID,
            date=datetime.date(2026, 10, 15), cash_session_id=CASH_ID, bank_account_id=BANK_ID,
            cost_center_id=CC_ID, due_date=datetime.date(2026, 11, 14), description="Factura 1234")

        kind, sql, args = conn.calls[0]
        assert kind == "fetchval"
        assert "public.rpc_convert_delivery_note_to_purchase(" in sql
        # molde de rpc_convert_delivery_note_to_sale: la clave primero, luego el remito
        assert args == (IDEM_KEY, DN_ID, 3, PM_ID, datetime.date(2026, 10, 15), CASH_ID, BANK_ID, CC_ID,
                        datetime.date(2026, 11, 14), "Factura 1234")
        for cast in ("$1::text", "$2::uuid", "$3::integer", "$4::uuid", "$5::date", "$6::uuid", "$7::uuid",
                     "$8::uuid", "$9::date", "$10::text"):
            assert cast in sql
        assert out == {"delivery_note_id": DN_ID, "replayed": False}

    @pytest.mark.asyncio
    async def test_it_decodes_a_jsonb_returned_as_text(self):
        from backend.repositories.delivery_note_repository import DeliveryNoteRepository

        conn = _RecordingConn(answer='{"delivery_note_id": "x", "replayed": true}')
        out = await DeliveryNoteRepository(conn).convert_to_purchase(
            DN_ID, idempotency_key=IDEM_KEY, expected_revision=1, payment_method_id=PM_ID,
            date=None, cash_session_id=None, bank_account_id=None, cost_center_id=None, due_date=None,
            description=None)
        assert out == {"delivery_note_id": "x", "replayed": True}

    @pytest.mark.asyncio
    async def test_the_conversion_writes_nothing_directly(self):
        """Todo va por la RPC: ni INSERT/UPDATE/DELETE sobre el remito, las
        compras ni el ledger de stock desde el repositorio."""
        from backend.repositories.delivery_note_repository import DeliveryNoteRepository

        conn = _RecordingConn(answer={})
        await DeliveryNoteRepository(conn).convert_to_purchase(
            DN_ID, idempotency_key=IDEM_KEY, expected_revision=1, payment_method_id=PM_ID,
            date=None, cash_session_id=None, bank_account_id=None, cost_center_id=None, due_date=None,
            description=None)
        for _, sql, _ in conn.calls:
            assert not re.search(r"\b(INSERT|UPDATE|DELETE)\b", sql, re.IGNORECASE), sql

    @pytest.mark.asyncio
    async def test_the_detail_derives_the_generated_purchase_from_the_bridge_with_the_account(self):
        """`converted_operation_id` es el campo genérico existente: en compra se
        completa con la operación de `purchases.source_delivery_note_id` (con la
        cuenta en el cruce), igual que `_delivery_note_payload`; sin campo paralelo."""
        from backend.repositories.delivery_note_repository import DeliveryNoteRepository

        conn = _RecordingConn()
        await DeliveryNoteRepository(conn).get_delivery_note(DN_ID, ACCOUNT_ID)

        sql = _normalized(conn.calls[0][1])
        assert "AS converted_operation_id" in sql and "AS converted_sales_order_id" in sql
        assert re.search(r"pu\.source_delivery_note_id = dn\.id", sql)
        assert re.search(r"pu\.account_id = dn\.account_id", sql)
        assert "converted_purchase" not in sql
        # el sentido venta sigue derivando de la orden VIVA
        assert "so.source_delivery_note_id = dn.id" in sql and "so.status <> 'canceled'" in sql


# ══════════════════════════════════════════════════════════════════════════════
# 7.1 endpoint
# ══════════════════════════════════════════════════════════════════════════════

class TestConvertEndpoint:
    async def test_the_route_exists_with_post_and_the_sale_one_is_untouched(self):
        from backend.main import app

        routes = {(m, r.path) for r in effective_routes(app) for m in r.methods}
        assert ("POST", "/delivery-notes/{delivery_note_id}/convert-to-purchase") in routes
        assert ("POST", "/delivery-notes/{delivery_note_id}/convert") in routes

    async def test_convert_returns_200_with_the_purchase_and_the_key_reaches_the_rpc(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        repo.convert_to_purchase.return_value = _rpc_result()
        conn.fetchval = account_roles_fetchval(["stock"])
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(ROUTE, json=_convert_body(), headers=_headers("stock"))

        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["delivery_note_id"] == DN_ID and body["delivery_note_number_label"] == "RC-00000012"
        assert body["operation_id"] == OPERATION_ID and body["total"] == "1500.00" and body["replayed"] is False
        assert "sales_order_id" not in body
        assert repo.convert_to_purchase.await_args.kwargs["idempotency_key"] == IDEM_KEY
        assert repo.convert_to_purchase.await_args.kwargs["expected_revision"] == 2

    async def test_a_replay_is_200_with_replayed_true(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        repo.convert_to_purchase.return_value = _rpc_result(replayed=True)
        conn.fetchval = account_roles_fetchval(["purchases"])
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(ROUTE, json=_convert_body(), headers=_headers("purchases"))

        assert resp.status_code == 200, resp.text
        assert resp.json()["replayed"] is True

    async def test_without_idempotency_key_it_is_rejected_before_the_rpc(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(ROUTE, json=_convert_body(), headers=_headers("stock", key=None))

        assert resp.status_code == 422
        assert resp.headers["content-type"].startswith("application/problem+json")
        assert resp.json()["code"] == "idempotency_key_required"
        repo.convert_to_purchase.assert_not_awaited()

    async def test_the_key_in_the_body_is_not_accepted(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                ROUTE, json=_convert_body(idempotency_key="from-body"), headers=_headers("stock", key=None))

        assert resp.status_code == 422
        repo.convert_to_purchase.assert_not_awaited()

    @pytest.mark.parametrize("role,status", [("seller", 403), ("cashier", 403), ("accountant", 403), ("viewer", 403),
                                             ("stock", 200), ("purchases", 200), ("admin", 200), ("owner", 200)])
    async def test_roles_over_http(self, async_client, repo_override, role, status):
        repo, (pool, conn) = repo_override
        repo.convert_to_purchase.return_value = _rpc_result()
        conn.fetchval = account_roles_fetchval([role])
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(ROUTE, json=_convert_body(), headers=_headers(role))

        assert resp.status_code == status, f"{role}: {resp.text}"
        if status == 403:
            assert resp.headers["content-type"].startswith("application/problem+json")
            assert resp.json()["code"] == "insufficient_role"
            repo.convert_to_purchase.assert_not_awaited()
        else:
            repo.convert_to_purchase.assert_awaited_once()

    @pytest.mark.parametrize("body", [
        {"payment_method_id": PM_ID},                        # sin versión
        {"expected_revision": 2},                            # sin forma de pago (OQ-RC4)
        {"expected_revision": 0, "payment_method_id": PM_ID},
        {"expected_revision": 2, "payment_method_id": "no-es-uuid"},
        {"expected_revision": "dos", "payment_method_id": PM_ID},
        {"expected_revision": 2, "payment_method_id": PM_ID, "date": "15/10/2026"},
        {"expected_revision": 2, "payment_method_id": PM_ID, "due_date": "mañana"},
        {"expected_revision": 2, "payment_method_id": PM_ID, "description": "x" * 501},
    ])
    async def test_validation_happens_before_the_database(self, async_client, repo_override, body):
        repo, (pool, conn) = repo_override
        conn.fetchval = account_roles_fetchval(["stock"])
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(ROUTE, json=body, headers=_headers("stock"))

        assert resp.status_code == 422, body
        repo.convert_to_purchase.assert_not_awaited()

    async def test_a_non_uuid_note_id_is_422(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/delivery-notes/not-a-uuid/convert-to-purchase", json=_convert_body(), headers=_headers("stock"))
        assert resp.status_code == 422
        repo.convert_to_purchase.assert_not_awaited()

    async def test_unauthenticated_is_401(self, async_client, repo_override):
        resp = await async_client.post(ROUTE, json=_convert_body())
        assert resp.status_code == 401

    @pytest.mark.parametrize("sqlstate,message,status,code", CONVERT_LITERALS[:14])
    async def test_business_errors_are_problem_json_with_the_stable_code(
        self, async_client, repo_override, sqlstate, message, status, code
    ):
        repo, (pool, conn) = repo_override
        repo.convert_to_purchase.side_effect = _pg_error(sqlstate, message)
        conn.fetchval = account_roles_fetchval(["stock"])
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(ROUTE, json=_convert_body(), headers=_headers("stock"))

        assert resp.status_code == status
        assert resp.headers["content-type"].startswith("application/problem+json")
        assert resp.json()["code"] == code
        assert message in resp.json()["detail"]


# ══════════════════════════════════════════════════════════════════════════════
# 7.1 read model de compras: la compra nacida de un remito
# ══════════════════════════════════════════════════════════════════════════════

def _purchase_row(**extra) -> dict:
    row = {
        "id": PURCHASE_ID, "date": "2026-10-15", "operation_id": OPERATION_ID,
        "description": "Remito RC-00000012", "product_id": None, "quantity": "1",
        "amount": "100.00", "total": "100.00", "product_name": None,
        "cost_center_id": None, "cost_center_name": None,
        "payment_method_id": None, "payment_method_name": None, "payment_method_kind": None,
        "is_payment_locked": False,
    }
    row.update(extra)
    return row


class TestPurchasesReadModel:
    async def test_the_listing_derives_the_note_with_the_account_in_the_join(self, async_client, valid_token, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[])
        conn.fetchval = AsyncMock(return_value=0)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get("/purchases", headers={"Authorization": f"Bearer {valid_token}"})
        assert resp.status_code == 200

        sql = _normalized(conn.fetch.await_args_list[-1].args[0])
        assert re.search(r"p\.source_delivery_note_id\s+AS source_delivery_note_id\b", sql)
        assert re.search(r"sdn\.number\s+AS source_delivery_note_number\b", sql)
        assert re.search(
            r"LEFT JOIN (public\.)?delivery_notes sdn ON sdn\.id = p\.source_delivery_note_id "
            r"AND sdn\.account_id = p\.account_id AND sdn\.direction = 'purchase'", sql)

    async def test_the_branch_of_the_note_is_active_with_the_predicate_of_the_delete(self, async_client, valid_token, mock_pool):
        """`source_delivery_note_branch_active` usa el MISMO predicado que el borrado
        (sucursal del remito activa y no cerrada, con la cuenta en el cruce): el
        listado deshabilita "Eliminar" con su motivo antes del P0422."""
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[])
        conn.fetchval = AsyncMock(return_value=0)
        with patch("backend.core.database.pool", pool):
            await async_client.get("/purchases", headers={"Authorization": f"Bearer {valid_token}"})

        sql = _normalized(conn.fetch.await_args_list[-1].args[0])
        assert "AS source_delivery_note_branch_active" in sql
        assert re.search(r"LEFT JOIN (public\.)?branches sdb ON sdb\.id = sdn\.branch_id AND sdb\.account_id = sdn\.account_id", sql)
        assert "sdb.is_active = TRUE" in sql and "sdb.status IS DISTINCT FROM 'closed'" in sql

    async def test_the_reason_for_not_editing_is_derived_from_the_origin(self, async_client, valid_token, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[])
        conn.fetchval = AsyncMock(return_value=0)
        with patch("backend.core.database.pool", pool):
            await async_client.get("/purchases", headers={"Authorization": f"Bearer {valid_token}"})

        sql = _normalized(conn.fetch.await_args_list[-1].args[0])
        assert re.search(
            r"CASE WHEN p\.source_delivery_note_id IS NOT NULL THEN 'delivery_note_purchase_locked' END\s+AS edit_locked_reason\b",
            sql)

    async def test_a_purchase_from_a_note_exposes_origin_reason_and_branch_flag(self, async_client, valid_token, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[_purchase_row(
            source_delivery_note_id=DN_ID, source_delivery_note_number=12,
            source_delivery_note_branch_active=False, edit_locked_reason="delivery_note_purchase_locked")])
        conn.fetchval = AsyncMock(return_value=1)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get("/purchases", headers={"Authorization": f"Bearer {valid_token}"})

        item = resp.json()["items"][0]
        assert item["source_delivery_note_id"] == DN_ID
        assert item["source_delivery_note_number"] == 12
        assert item["source_delivery_note_branch_active"] is False
        assert item["edit_locked_reason"] == "delivery_note_purchase_locked"

    async def test_a_plain_purchase_invents_no_origin_and_no_reason(self, async_client, valid_token, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[_purchase_row()])
        conn.fetchval = AsyncMock(return_value=1)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get("/purchases", headers={"Authorization": f"Bearer {valid_token}"})

        item = resp.json()["items"][0]
        assert item["source_delivery_note_id"] is None
        assert item["source_delivery_note_number"] is None
        assert item["source_delivery_note_branch_active"] is None
        assert item["edit_locked_reason"] is None


# ══════════════════════════════════════════════════════════════════════════════
# 7.1 la compra nacida de un remito: errores de editar y de borrar, como problem+json
# ══════════════════════════════════════════════════════════════════════════════

class TestPurchaseSideErrorsOverHttp:
    async def test_editing_a_purchase_from_a_note_is_409_with_the_token(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.execute = AsyncMock(side_effect=_pg_error(
            "P0423", "delivery_note_purchase_locked: la compra nació del remito RC-00000012: para corregirla, eliminá la compra"))
        payload = {
            "purchase_ids": [PURCHASE_ID], "date": "2026-10-15", "description": None,
            "items": [{"product_id": "22222222-2222-2222-2222-222222222222", "quantity": 1, "amount": 100}],
        }
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                "/purchases/operation", json=payload,
                headers={"Authorization": f"Bearer {tenant_token(['owner'])}"})

        assert resp.status_code == 409
        assert resp.headers["content-type"].startswith("application/problem+json")
        body = resp.json()
        assert body["code"] == "P0423"
        assert "delivery_note_purchase_locked" in body["detail"]

    @pytest.mark.parametrize("sqlstate,message,status,token", [
        ("P0403", "delivery_note_purchase_delete_forbidden: borrar esta compra reabre el remito RC-00000012", 403,
         "delivery_note_purchase_delete_forbidden"),
        ("P0422", "delivery_note_branch_inactive: la sucursal del remito RC-00000012 está desactivada o cerrada", 422,
         "delivery_note_branch_inactive"),
        ("P0403", "delivery_note_source_protected: el origen de remito de una compra lo escribe sólo la conversión", 403,
         "delivery_note_source_protected"),
        ("P0409", "delivery_note_purchase_mismatch: el origen x no es un remito de compra de esta cuenta", 409,
         "delivery_note_purchase_mismatch"),
    ])
    async def test_deleting_a_purchase_from_a_note_surfaces_the_token(
        self, async_client, mock_pool, sqlstate, message, status, token
    ):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(side_effect=_pg_error(sqlstate, message))
        with patch("backend.core.database.pool", pool):
            resp = await async_client.delete(
                f"/purchases?operation_id={uuid.uuid4()}",
                headers={"Authorization": f"Bearer {tenant_token(['owner'])}"})

        assert resp.status_code == status
        assert resp.headers["content-type"].startswith("application/problem+json")
        assert token in resp.json()["detail"]
