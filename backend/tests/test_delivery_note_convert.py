"""
remitos-venta (tanda B, tareas 7.1-7.2) — conversión del remito en venta, 3 capas.

Strict TDD: este archivo se escribió ANTES de `DeliveryNoteConvertIn/Out`,
`DeliveryNoteRepository.convert_to_sale`, `services.delivery_notes.convert_delivery_note`
y `POST /delivery-notes/{id}/convert`. Cubre la mitad "con dobles" (schemas,
capacidad atada al catálogo, mapeo de errores, guard de rol, SQL del repositorio,
endpoint y read models de ventas/órdenes). La mitad que persiste de verdad (stock
idéntico, caja, cuenta corriente, borrado, edición bloqueada) está en
`test_delivery_note_convert_integration.py` (marcada `integration`); la evidencia
de CI del esquema es el gate SQL supabase/tests/test_remito_a_venta.sql.

Spec: openspec/changes/remitos-venta/specs/delivery-note/spec.md (conversión),
sales-order, operation-delete-compensation y operation-edit-context; design.md
D7, D9, D11, D13.
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

from backend.tests.conftest import account_roles_fetchval, effective_routes, make_token
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
SALES_ORDER_ID = "55555555-5555-5555-5555-555555555555"
OPERATION_ID = "66666666-6666-6666-6666-666666666666"
REPO_ROOT = Path(__file__).resolve().parents[2]
MIGRATION_B = "supabase/migrations/20261070000001_remitos_venta_conversion.sql"


def _migration_b() -> str:
    return (REPO_ROOT / MIGRATION_B).read_text(encoding="utf-8")


def _convert_in(**over):
    from backend.schemas.delivery_notes import DeliveryNoteConvertIn

    data = {"expected_revision": 2, "payment_method_id": PM_ID}
    data.update(over)
    return DeliveryNoteConvertIn(**data)


def _rpc_result(**over) -> dict:
    base = {
        "delivery_note_id": DN_ID,
        "delivery_note_number": 12,
        "sales_order_id": SALES_ORDER_ID,
        "operation_id": OPERATION_ID,
        "total": Decimal("1500.00"),
        "replayed": False,
    }
    base.update(over)
    return base


def _convert_repo(**returns) -> AsyncMock:
    repo = _repo()
    repo.convert_to_sale.return_value = _rpc_result()
    for name, value in returns.items():
        getattr(repo, name).return_value = value
    return repo


def _convert_body(**over) -> dict:
    data = {"expected_revision": 2, "payment_method_id": PM_ID}
    data.update(over)
    return data


# ══════════════════════════════════════════════════════════════════════════════
# 7.1 schemas
# ══════════════════════════════════════════════════════════════════════════════

class TestConvertSchemas:
    def test_the_minimum_is_the_revision_and_the_payment_method(self):
        payload = _convert_in()
        assert payload.expected_revision == 2
        assert str(payload.payment_method_id) == PM_ID
        assert payload.cash_session_id is None and payload.bank_account_id is None and payload.canal is None

    def test_optional_destinations_are_carried(self):
        payload = _convert_in(cash_session_id=CASH_ID, bank_account_id=BANK_ID, canal="mostrador")
        assert str(payload.cash_session_id) == CASH_ID
        assert str(payload.bank_account_id) == BANK_ID
        assert payload.canal == "mostrador"

    @pytest.mark.parametrize("missing", ["expected_revision", "payment_method_id"])
    def test_revision_and_payment_method_are_required(self, missing):
        from backend.schemas.delivery_notes import DeliveryNoteConvertIn

        data = {"expected_revision": 2, "payment_method_id": PM_ID}
        data.pop(missing)
        with pytest.raises(ValidationError):
            DeliveryNoteConvertIn(**data)

    @pytest.mark.parametrize("bad", [0, -1])
    def test_revision_is_at_least_one(self, bad):
        with pytest.raises(ValidationError):
            _convert_in(expected_revision=bad)

    def test_the_branch_is_not_an_input_because_it_is_the_notes_own(self):
        """La venta se imputa a la sucursal del remito (de donde salió el
        stock): no hay `branch_id` en el contrato de la conversión (D7)."""
        from backend.schemas.delivery_notes import DeliveryNoteConvertIn

        assert "branch_id" not in DeliveryNoteConvertIn.model_fields
        assert "idempotency_key" not in DeliveryNoteConvertIn.model_fields

    def test_canal_has_the_same_cap_as_the_sale_contract(self):
        _convert_in(canal="x" * 40)
        with pytest.raises(ValidationError):
            _convert_in(canal="x" * 41)

    def test_out_carries_the_note_the_order_the_operation_and_the_replay_flag(self):
        from backend.schemas.delivery_notes import DeliveryNoteConvertOut

        out = DeliveryNoteConvertOut(**_rpc_result(), delivery_note_number_label="R-00000012")
        assert str(out.delivery_note_id) == DN_ID and out.delivery_note_number == 12
        assert out.delivery_note_number_label == "R-00000012"
        assert str(out.sales_order_id) == SALES_ORDER_ID and str(out.operation_id) == OPERATION_ID
        assert out.total == Decimal("1500.00") and out.replayed is False

    def test_out_replayed_defaults_to_false(self):
        from backend.schemas.delivery_notes import DeliveryNoteConvertOut

        data = _rpc_result()
        data.pop("replayed")
        assert DeliveryNoteConvertOut(**data).replayed is False


# ══════════════════════════════════════════════════════════════════════════════
# 7.1 capacidad atada al catálogo de la FSM
# ══════════════════════════════════════════════════════════════════════════════

class TestConvertCapability:
    def test_the_conversion_uses_can_sell(self):
        from backend.core.rbac import CAN_SELL

        assert CAN_SELL == frozenset({"owner", "admin", "seller", "cashier"})

    def test_can_sell_is_the_issued_to_converted_row_of_the_catalog(self):
        """La capacidad no es una segunda política: la fila `issued -> converted`
        de `delivery_note_sale` que siembra la tanda B lista EXACTAMENTE los
        roles de CAN_SELL (el cajero y el vendedor convierten; el depósito no)."""
        from backend.core.rbac import CAN_SELL

        rows = re.findall(
            r"\('delivery_note_sale',\s*(NULL|'[a-z_]+'),\s*'([a-z_]+)',\s*(?:true|false),\s*(?:true|false),\s*ARRAY\[([^\]]*)\]",
            _migration_b(),
        )
        by_transition = {
            (frm.strip("'") if frm != "NULL" else None, to): frozenset(re.findall(r"'([a-z_]+)'", roles))
            for frm, to, roles in rows
        }
        assert by_transition.get(("issued", "converted")) == CAN_SELL

    def test_convert_is_not_a_sensitive_capability(self):
        """Convertir no devuelve stock ni anula: basta el claim, con el catálogo
        como autoridad en la RPC (control negativo de `anular`)."""
        from backend.core.rbac import CAN_SELL, CAN_VOID_DELIVERY_NOTE, is_sensitive_capability

        assert is_sensitive_capability(CAN_SELL) is False
        assert is_sensitive_capability(CAN_VOID_DELIVERY_NOTE) is True


# ══════════════════════════════════════════════════════════════════════════════
# 7.1 mapeo de errores: cada literal que la tanda B levanta tiene su caso
# ══════════════════════════════════════════════════════════════════════════════

CONVERT_LITERALS = [
    ("P0409", "delivery_note_changed: el remito cambió desde que lo abriste (versión 1 vs 2) — recargalo", 409, "delivery_note_changed"),
    ("P0409", "delivery_note_invalid_state: el remito está converted y no se puede convertir", 409, "delivery_note_invalid_state"),
    ("P0409", "idempotency_key_conflict: la clave ya se usó para otra operación", 409, "idempotency_key_conflict"),
    ("P0404", "delivery_note_not_found: dddd", 404, "delivery_note_not_found"),
    ("P0404", "delivery_note_client_unavailable: el cliente del remito fue dado de baja: editá el remito", 404, "delivery_note_client_unavailable"),
    ("P0422", "branch_closed: la sucursal del remito está desactivada o cerrada — reactivala para convertir el remito", 422, "branch_closed"),
    ("P0422", "delivery_note_branch_inactive: la sucursal del remito R-00000012 está desactivada o cerrada", 422, "delivery_note_branch_inactive"),
    ("P0400", "delivery_note_revision_required: falta la versión del remito que se convierte", 400, "delivery_note_revision_required"),
    ("P0400", "payment_method_required: la conversión exige una forma de pago del catálogo", 400, "payment_method_required"),
    ("P0400", "idempotency_key is required", 400, "idempotency_key"),
    ("P0403", "insufficient_role: tu rol no permite convertir remitos", 403, "insufficient_role"),
    ("P0401", "unauthorized", 403, "unauthorized"),
    # del núcleo del POS que la conversión reutiliza
    ("P0409", "delivery_note_order_mismatch: la orden no corresponde a un remito de venta pendiente", 409, "delivery_note_order_mismatch"),
    ("P0404", "payment_method_not_found: x no pertenece a la cuenta o no existe", 404, "payment_method_not_found"),
    ("P0404", "client_not_found: cccc", 404, "client_not_found"),
]

SALE_SIDE_LITERALS = [
    # editar la venta nacida de un remito (D9)
    ("P0423", "delivery_note_sale_locked: la venta nació del remito R-00000012: eliminá la venta", 409, "delivery_note_sale_locked"),
    # anular un remito convertido
    ("P0423", "delivery_note_locked_converted: el remito ya se convirtió en la venta", 409, "delivery_note_locked_converted"),
]


class TestConvertProblemMapping:
    @pytest.mark.parametrize("sqlstate,message,status,code", CONVERT_LITERALS + SALE_SIDE_LITERALS)
    def test_literal_code_and_status(self, sqlstate, message, status, code):
        from backend.core.errors import problem_from_pg_error

        problem = problem_from_pg_error(_pg_error(sqlstate, message))

        assert problem.status_code == status
        assert problem.code == code
        assert message in str(problem.detail)

    def test_every_literal_the_conversion_rpc_raises_has_a_case(self):
        """Control de completitud sobre el cuerpo de `rpc_convert_delivery_note_to_sale`
        de la migración B: si SQL suma un literal nuevo, este test obliga a mapearlo."""
        sql = _migration_b()
        start = sql.index("CREATE OR REPLACE FUNCTION public.rpc_convert_delivery_note_to_sale(")
        end = sql.index("REVOKE ALL ON FUNCTION public.rpc_convert_delivery_note_to_sale(")
        raised = set(re.findall(r"RAISE EXCEPTION '([a-z][a-z0-9_]*)[:'%\s]", sql[start:end]))
        raised -= {"Not"}  # 'Not authenticated' (42501, lo resuelve el handler global)
        covered = {code for _, _, _, code in CONVERT_LITERALS}
        assert raised <= covered, f"literales sin caso: {sorted(raised - covered)}"

    def test_the_two_sale_side_literals_are_raised_by_the_migration(self):
        sql = _migration_b()
        for _, _, _, code in SALE_SIDE_LITERALS:
            if code == "delivery_note_locked_converted":
                continue  # lo levanta la anulación de la tanda A
            assert f"RAISE EXCEPTION '{code}:" in sql, code


# ══════════════════════════════════════════════════════════════════════════════
# 7.2 service
# ══════════════════════════════════════════════════════════════════════════════

CONVERT_ROLES = {
    "allowed": ["cashier", "seller", "admin", "owner"],
    "denied": ["stock", "purchases", "accountant", "viewer"],
}


class TestConvertService:
    @pytest.mark.asyncio
    @pytest.mark.parametrize("role", CONVERT_ROLES["denied"])
    async def test_denied_roles_get_403_without_calling_the_rpc(self, role):
        from backend.services import delivery_notes as svc

        repo = _convert_repo()
        with pytest.raises(HTTPException) as info:
            await svc.convert_delivery_note(
                repo, _auth(role), ACCOUNT_ID, DN_ID, _convert_in(), IDEM_KEY, conn=_conn(role))

        assert info.value.status_code == 403
        assert getattr(info.value, "code", None) == "insufficient_role"
        repo.convert_to_sale.assert_not_awaited()

    @pytest.mark.asyncio
    @pytest.mark.parametrize("role", CONVERT_ROLES["allowed"])
    async def test_allowed_roles_reach_the_rpc(self, role):
        from backend.services import delivery_notes as svc

        repo = _convert_repo()
        await svc.convert_delivery_note(
            repo, _auth(role), ACCOUNT_ID, DN_ID, _convert_in(), IDEM_KEY, conn=_conn(role))

        repo.convert_to_sale.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_roles_are_a_set_union_not_the_first_role(self):
        """Un usuario con rol de depósito Y de vendedor convierte: se evalúa el
        conjunto, no el primero."""
        from backend.services import delivery_notes as svc

        repo = _convert_repo()
        await svc.convert_delivery_note(
            repo, _auth("stock", "seller"), ACCOUNT_ID, DN_ID, _convert_in(), IDEM_KEY, conn=_conn("stock", "seller"))
        repo.convert_to_sale.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_the_rpc_receives_exactly_what_the_user_chose_and_nothing_else(self):
        from backend.services import delivery_notes as svc

        repo = _convert_repo()
        await svc.convert_delivery_note(
            repo, _auth("cashier"), ACCOUNT_ID, DN_ID,
            _convert_in(expected_revision=5, cash_session_id=CASH_ID, bank_account_id=BANK_ID, canal="web"),
            IDEM_KEY, conn=_conn("cashier"))

        assert repo.convert_to_sale.await_args.args == (DN_ID,)
        assert repo.convert_to_sale.await_args.kwargs == {
            "idempotency_key": IDEM_KEY,
            "expected_revision": 5,
            "payment_method_id": PM_ID,
            "cash_session_id": CASH_ID,
            "bank_account_id": BANK_ID,
            "canal": "web",
        }

    @pytest.mark.asyncio
    async def test_optional_ids_travel_as_null_when_absent(self):
        from backend.services import delivery_notes as svc

        repo = _convert_repo()
        await svc.convert_delivery_note(
            repo, _auth("cashier"), ACCOUNT_ID, DN_ID, _convert_in(), IDEM_KEY, conn=_conn("cashier"))

        kwargs = repo.convert_to_sale.await_args.kwargs
        assert kwargs["cash_session_id"] is None and kwargs["bank_account_id"] is None and kwargs["canal"] is None

    @pytest.mark.asyncio
    async def test_the_result_adds_the_visible_number_of_the_note(self):
        from backend.services import delivery_notes as svc

        repo = _convert_repo()
        out = await svc.convert_delivery_note(
            repo, _auth("cashier"), ACCOUNT_ID, DN_ID, _convert_in(), IDEM_KEY, conn=_conn("cashier"))

        assert out["delivery_note_number_label"] == "R-00000012"
        assert out["sales_order_id"] == SALES_ORDER_ID and out["operation_id"] == OPERATION_ID
        assert out["replayed"] is False

    @pytest.mark.asyncio
    async def test_a_replay_keeps_its_flag(self):
        from backend.services import delivery_notes as svc

        repo = _convert_repo(convert_to_sale=_rpc_result(replayed=True))
        out = await svc.convert_delivery_note(
            repo, _auth("cashier"), ACCOUNT_ID, DN_ID, _convert_in(), IDEM_KEY, conn=_conn("cashier"))
        assert out["replayed"] is True

    @pytest.mark.asyncio
    async def test_without_a_resolved_key_it_is_a_wiring_bug_not_a_user_error(self):
        from backend.services import delivery_notes as svc

        repo = _convert_repo()
        with pytest.raises(ValueError):
            await svc.convert_delivery_note(
                repo, _auth("cashier"), ACCOUNT_ID, DN_ID, _convert_in(), "", conn=_conn("cashier"))
        repo.convert_to_sale.assert_not_awaited()

    @pytest.mark.asyncio
    @pytest.mark.parametrize("sqlstate,message,status,code", CONVERT_LITERALS)
    async def test_every_business_error_surfaces_as_a_stable_problem(self, sqlstate, message, status, code):
        from backend.core.errors import ProblemHTTPException
        from backend.services import delivery_notes as svc

        repo = _convert_repo()
        repo.convert_to_sale.side_effect = _pg_error(sqlstate, message)
        with pytest.raises(ProblemHTTPException) as info:
            await svc.convert_delivery_note(
                repo, _auth("cashier"), ACCOUNT_ID, DN_ID, _convert_in(), IDEM_KEY, conn=_conn("cashier"))

        assert info.value.status_code == status and info.value.code == code

    @pytest.mark.asyncio
    async def test_a_deadlock_is_a_409_concurrent_update_retry(self):
        from backend.core.errors import ProblemHTTPException
        from backend.services import delivery_notes as svc

        repo = _convert_repo()
        repo.convert_to_sale.side_effect = asyncpg.DeadlockDetectedError("deadlock detected")
        with pytest.raises(ProblemHTTPException) as info:
            await svc.convert_delivery_note(
                repo, _auth("cashier"), ACCOUNT_ID, DN_ID, _convert_in(), IDEM_KEY, conn=_conn("cashier"))

        assert info.value.status_code == 409 and info.value.code == "concurrent_update_retry"

    @pytest.mark.asyncio
    async def test_an_unmapped_sqlstate_still_propagates_for_the_global_500(self):
        from backend.services import delivery_notes as svc

        repo = _convert_repo()
        repo.convert_to_sale.side_effect = _pg_error("XX000", "boom")
        with pytest.raises(asyncpg.PostgresError):
            await svc.convert_delivery_note(
                repo, _auth("cashier"), ACCOUNT_ID, DN_ID, _convert_in(), IDEM_KEY, conn=_conn("cashier"))


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
        from backend.repositories.delivery_note_repository import DeliveryNoteRepository

        conn = _RecordingConn(answer={"delivery_note_id": DN_ID, "replayed": False})
        out = await DeliveryNoteRepository(conn).convert_to_sale(
            DN_ID, idempotency_key=IDEM_KEY, expected_revision=3, payment_method_id=PM_ID,
            cash_session_id=CASH_ID, bank_account_id=BANK_ID, canal="web")

        kind, sql, args = conn.calls[0]
        assert kind == "fetchval"
        assert "public.rpc_convert_delivery_note_to_sale(" in sql
        # molde de rpc_convert_quote_to_sale: la clave primero, luego el remito
        assert args == (IDEM_KEY, DN_ID, 3, PM_ID, CASH_ID, BANK_ID, "web")
        for cast in ("$1::text", "$2::uuid", "$3::integer", "$4::uuid", "$5::uuid", "$6::uuid", "$7::text"):
            assert cast in sql
        assert out == {"delivery_note_id": DN_ID, "replayed": False}

    @pytest.mark.asyncio
    async def test_it_decodes_a_jsonb_returned_as_text(self):
        from backend.repositories.delivery_note_repository import DeliveryNoteRepository

        conn = _RecordingConn(answer='{"delivery_note_id": "x", "replayed": true}')
        out = await DeliveryNoteRepository(conn).convert_to_sale(
            DN_ID, idempotency_key=IDEM_KEY, expected_revision=1, payment_method_id=PM_ID,
            cash_session_id=None, bank_account_id=None, canal=None)
        assert out == {"delivery_note_id": "x", "replayed": True}

    @pytest.mark.asyncio
    async def test_the_conversion_writes_nothing_directly(self):
        """Todo va por la RPC: ni INSERT/UPDATE/DELETE sobre el remito, las
        órdenes ni el ledger de stock desde el repositorio."""
        from backend.repositories.delivery_note_repository import DeliveryNoteRepository

        conn = _RecordingConn(answer={})
        await DeliveryNoteRepository(conn).convert_to_sale(
            DN_ID, idempotency_key=IDEM_KEY, expected_revision=1, payment_method_id=PM_ID,
            cash_session_id=None, bank_account_id=None, canal=None)
        for _, sql, _ in conn.calls:
            assert not re.search(r"\b(INSERT|UPDATE|DELETE)\b", sql, re.IGNORECASE), sql

    @pytest.mark.asyncio
    async def test_the_detail_derives_the_generated_sale_from_the_live_order(self):
        """La tanda A devolvía NULL fijo; desde la B se derivan de la orden VIVA
        del remito (no cancelada), con la cuenta en el JOIN, igual que
        `_delivery_note_payload`."""
        from backend.repositories.delivery_note_repository import DeliveryNoteRepository

        conn = _RecordingConn()
        await DeliveryNoteRepository(conn).get_delivery_note(DN_ID, ACCOUNT_ID)

        sql = " ".join(conn.calls[0][1].split())
        assert "NULL::uuid AS converted_sales_order_id" not in sql
        assert "NULL::uuid AS converted_operation_id" not in sql
        assert "AS converted_sales_order_id" in sql and "AS converted_operation_id" in sql
        assert "so.source_delivery_note_id = dn.id" in sql
        assert "so.account_id = dn.account_id" in sql
        assert "so.status <> 'canceled'" in sql


# ══════════════════════════════════════════════════════════════════════════════
# 7.1 endpoint
# ══════════════════════════════════════════════════════════════════════════════

class TestConvertEndpoint:
    async def test_the_route_exists_with_post(self):
        from backend.main import app

        routes = {(m, r.path) for r in effective_routes(app) for m in r.methods}
        assert ("POST", "/delivery-notes/{delivery_note_id}/convert") in routes

    async def test_convert_returns_200_with_the_sale_and_the_key_reaches_the_rpc(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        repo.convert_to_sale.return_value = _rpc_result()
        conn.fetchval = account_roles_fetchval(["cashier"])
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/delivery-notes/{DN_ID}/convert", json=_convert_body(), headers=_headers("cashier"))

        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["delivery_note_id"] == DN_ID and body["delivery_note_number_label"] == "R-00000012"
        assert body["sales_order_id"] == SALES_ORDER_ID and body["operation_id"] == OPERATION_ID
        assert body["total"] == "1500.00" and body["replayed"] is False
        assert repo.convert_to_sale.await_args.kwargs["idempotency_key"] == IDEM_KEY
        assert repo.convert_to_sale.await_args.kwargs["expected_revision"] == 2

    async def test_a_replay_is_200_with_replayed_true(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        repo.convert_to_sale.return_value = _rpc_result(replayed=True)
        conn.fetchval = account_roles_fetchval(["seller"])
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/delivery-notes/{DN_ID}/convert", json=_convert_body(), headers=_headers("seller"))

        assert resp.status_code == 200, resp.text
        assert resp.json()["replayed"] is True

    async def test_without_idempotency_key_it_is_rejected_before_the_rpc(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/delivery-notes/{DN_ID}/convert", json=_convert_body(), headers=_headers("cashier", key=None))

        assert resp.status_code == 422
        assert resp.headers["content-type"].startswith("application/problem+json")
        assert resp.json()["code"] == "idempotency_key_required"
        repo.convert_to_sale.assert_not_awaited()

    async def test_the_key_in_the_body_is_not_accepted(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/delivery-notes/{DN_ID}/convert",
                json=_convert_body(idempotency_key="from-body"),
                headers=_headers("cashier", key=None))

        assert resp.status_code == 422
        repo.convert_to_sale.assert_not_awaited()

    @pytest.mark.parametrize("role,status", [("stock", 403), ("viewer", 403), ("purchases", 403),
                                             ("cashier", 200), ("seller", 200), ("admin", 200), ("owner", 200)])
    async def test_roles_over_http(self, async_client, repo_override, role, status):
        repo, (pool, conn) = repo_override
        repo.convert_to_sale.return_value = _rpc_result()
        conn.fetchval = account_roles_fetchval([role])
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/delivery-notes/{DN_ID}/convert", json=_convert_body(), headers=_headers(role))

        assert resp.status_code == status, f"{role}: {resp.text}"
        if status == 403:
            assert resp.headers["content-type"].startswith("application/problem+json")
            assert resp.json()["code"] == "insufficient_role"
            repo.convert_to_sale.assert_not_awaited()
        else:
            repo.convert_to_sale.assert_awaited_once()

    @pytest.mark.parametrize("body", [
        {"payment_method_id": PM_ID},                        # sin versión
        {"expected_revision": 2},                            # sin forma de pago
        {"expected_revision": 0, "payment_method_id": PM_ID},
        {"expected_revision": 2, "payment_method_id": "no-es-uuid"},
        {"expected_revision": "dos", "payment_method_id": PM_ID},
        {"expected_revision": 2, "payment_method_id": PM_ID, "canal": "x" * 41},
    ])
    async def test_validation_happens_before_the_database(self, async_client, repo_override, body):
        repo, (pool, conn) = repo_override
        conn.fetchval = account_roles_fetchval(["cashier"])
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/delivery-notes/{DN_ID}/convert", json=body, headers=_headers("cashier"))

        assert resp.status_code == 422, body
        repo.convert_to_sale.assert_not_awaited()

    async def test_a_non_uuid_note_id_is_422(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/delivery-notes/not-a-uuid/convert", json=_convert_body(), headers=_headers("cashier"))
        assert resp.status_code == 422
        repo.convert_to_sale.assert_not_awaited()

    async def test_unauthenticated_is_401(self, async_client, repo_override):
        resp = await async_client.post(f"/delivery-notes/{DN_ID}/convert", json=_convert_body())
        assert resp.status_code == 401

    @pytest.mark.parametrize("sqlstate,message,status,code", CONVERT_LITERALS[:9])
    async def test_business_errors_are_problem_json_with_the_stable_code(
        self, async_client, repo_override, sqlstate, message, status, code
    ):
        repo, (pool, conn) = repo_override
        repo.convert_to_sale.side_effect = _pg_error(sqlstate, message)
        conn.fetchval = account_roles_fetchval(["cashier"])
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/delivery-notes/{DN_ID}/convert", json=_convert_body(), headers=_headers("cashier"))

        assert resp.status_code == status
        assert resp.headers["content-type"].startswith("application/problem+json")
        assert resp.json()["code"] == code
        assert message in resp.json()["detail"]

    async def test_a_cash_conversion_without_an_open_session_surfaces_the_core_literal(self, async_client, repo_override):
        """`cash_requires_session` lo levanta el núcleo del POS: el cliente
        recibe el literal estable para ofrecer abrir la caja."""
        repo, (pool, conn) = repo_override
        repo.convert_to_sale.side_effect = _pg_error(
            "P0400", "cash_requires_session: payment_method=cash exige cash_session_id")
        conn.fetchval = account_roles_fetchval(["cashier"])
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/delivery-notes/{DN_ID}/convert", json=_convert_body(), headers=_headers("cashier"))

        assert resp.status_code == 400
        assert resp.json()["code"] == "cash_requires_session"


# ══════════════════════════════════════════════════════════════════════════════
# 7.1 read models: la venta nacida de un remito
# ══════════════════════════════════════════════════════════════════════════════

def _normalized(sql: str) -> str:
    return " ".join(sql.split())


class TestSalesReadModel:
    async def test_the_sales_listing_derives_the_note_with_the_account_in_the_join(self, async_client, valid_token, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[])
        conn.fetchval = AsyncMock(return_value=0)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get("/sales", headers={"Authorization": f"Bearer {valid_token}"})
        assert resp.status_code == 200

        sql = _normalized(conn.fetch.await_args_list[-1].args[0])
        assert re.search(r"so\.source_delivery_note_id\s+AS source_delivery_note_id\b", sql)
        assert re.search(r"sdn\.number\s+AS source_delivery_note_number\b", sql)
        assert re.search(
            r"LEFT JOIN (public\.)?delivery_notes sdn ON sdn\.id = so\.source_delivery_note_id "
            r"AND sdn\.account_id = so\.account_id", sql)

    async def test_the_reason_for_not_editing_is_derived_from_the_origin(self, async_client, valid_token, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[])
        conn.fetchval = AsyncMock(return_value=0)
        with patch("backend.core.database.pool", pool):
            await async_client.get("/sales", headers={"Authorization": f"Bearer {valid_token}"})

        sql = _normalized(conn.fetch.await_args_list[-1].args[0])
        assert re.search(
            r"CASE WHEN so\.source_delivery_note_id IS NOT NULL THEN 'delivery_note_sale_locked' END\s+AS edit_locked_reason\b",
            sql)

    async def test_a_sale_from_a_note_exposes_origin_and_reason(self, async_client, valid_token, mock_pool):
        from backend.tests.test_factura_fiscal_read_models import _sale_row

        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[_sale_row(
            source_delivery_note_id=DN_ID, source_delivery_note_number=12,
            edit_locked_reason="delivery_note_sale_locked")])
        conn.fetchval = AsyncMock(return_value=1)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get("/sales", headers={"Authorization": f"Bearer {valid_token}"})

        item = resp.json()["items"][0]
        assert item["source_delivery_note_id"] == DN_ID
        assert item["source_delivery_note_number"] == 12
        assert item["edit_locked_reason"] == "delivery_note_sale_locked"

    async def test_a_plain_sale_invents_no_origin_and_no_reason(self, async_client, valid_token, mock_pool):
        from backend.tests.test_factura_fiscal_read_models import _sale_row

        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[_sale_row()])
        conn.fetchval = AsyncMock(return_value=1)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get("/sales", headers={"Authorization": f"Bearer {valid_token}"})

        item = resp.json()["items"][0]
        assert item["source_delivery_note_id"] is None
        assert item["source_delivery_note_number"] is None
        assert item["edit_locked_reason"] is None


class TestSalesOrdersReadModel:
    async def test_list_orders_brings_the_number_of_the_origin_note(self):
        from backend.repositories.sales_order_repository import SalesOrderRepository

        conn = AsyncMock()
        conn.fetch = AsyncMock(return_value=[])
        await SalesOrderRepository(conn).list_orders(ACCOUNT_ID)

        sql = _normalized(conn.fetch.await_args.args[0])
        assert re.search(r"sdn\.number\s+AS source_delivery_note_number\b", sql)
        assert re.search(
            r"LEFT JOIN public\.delivery_notes sdn ON sdn\.id = so\.source_delivery_note_id "
            r"AND sdn\.account_id = so\.account_id", sql)

    async def test_get_order_brings_the_number_of_the_origin_note(self):
        from backend.repositories.sales_order_repository import SalesOrderRepository

        conn = AsyncMock()
        conn.fetchrow = AsyncMock(return_value=None)
        await SalesOrderRepository(conn).get_order("44444444-4444-4444-4444-444444444444", ACCOUNT_ID)

        sql = _normalized(conn.fetchrow.await_args.args[0])
        assert re.search(r"sdn\.number\s+AS source_delivery_note_number\b", sql)
        assert "WHERE so.id = $1::uuid AND so.account_id = $2::uuid" in sql

    async def test_the_orders_endpoint_exposes_the_origin_note(self, async_client, valid_token, mock_pool):
        from backend.tests.test_factura_fiscal_read_models import _order_row

        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[_order_row(
            source_delivery_note_id=DN_ID, source_delivery_note_number=12)])
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get("/sales-orders", headers={"Authorization": f"Bearer {valid_token}"})

        assert resp.status_code == 200
        item = resp.json()[0] if isinstance(resp.json(), list) else resp.json()["items"][0]
        assert item["source_delivery_note_id"] == DN_ID
        assert item["source_delivery_note_number"] == 12

    async def test_an_order_without_a_note_has_no_origin(self, async_client, valid_token, mock_pool):
        from backend.tests.test_factura_fiscal_read_models import _order_row

        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[_order_row()])
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get("/sales-orders", headers={"Authorization": f"Bearer {valid_token}"})

        item = resp.json()[0] if isinstance(resp.json(), list) else resp.json()["items"][0]
        assert item["source_delivery_note_id"] is None and item["source_delivery_note_number"] is None


# ══════════════════════════════════════════════════════════════════════════════
# 7.1 la venta nacida de un remito: errores de editar y de borrar, como problem+json
# ══════════════════════════════════════════════════════════════════════════════

class TestSaleSideErrorsOverHttp:
    @pytest.mark.parametrize("sqlstate,message,status", [
        ("P0423", "delivery_note_sale_locked: la venta nació del remito R-00000012: eliminá la venta", 409),
    ])
    async def test_editing_a_sale_from_a_note_is_409_with_the_token(
        self, async_client, mock_pool, sqlstate, message, status
    ):
        from backend.tests.test_sales import UPDATE_PAYLOAD

        pool, conn = mock_pool
        conn.fetchval = AsyncMock(side_effect=_pg_error(sqlstate, message))
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                "/sales/operation", json=UPDATE_PAYLOAD,
                headers={"Authorization": f"Bearer {make_token({'role': 'user'})}"})

        assert resp.status_code == status
        assert resp.headers["content-type"].startswith("application/problem+json")
        body = resp.json()
        assert body["code"] == sqlstate
        assert "delivery_note_sale_locked" in body["detail"]

    async def test_deleting_a_sale_whose_note_branch_is_inactive_is_422_with_the_token(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(side_effect=_pg_error(
            "P0422", "delivery_note_branch_inactive: la sucursal del remito R-00000012 está desactivada"))
        with patch("backend.core.database.pool", pool):
            resp = await async_client.delete(
                f"/sales?operation_id={uuid.uuid4()}",
                headers={"Authorization": f"Bearer {make_token({'role': 'user'})}"})

        assert resp.status_code == 422
        assert resp.headers["content-type"].startswith("application/problem+json")
        assert "delivery_note_branch_inactive" in resp.json()["detail"]
