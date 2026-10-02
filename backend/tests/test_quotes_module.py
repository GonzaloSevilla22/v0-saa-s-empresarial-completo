"""
presupuestos-modulo (tanda A, grupo 2) — presupuestos sobre RPC, 3 capas.

Strict TDD: este archivo se escribió ANTES que `schemas/quotes.py`,
`repositories/quote_repository.py`, `services/quotes.py` y `routers/quotes.py`
nuevos. Cubre la mitad "con dobles" del contrato (schemas, rbac, mapeo de
errores, guards de rol, SQL que emite el repositorio, endpoints); la mitad que
persiste de verdad contra Postgres está en `test_quotes_module_integration.py`
(marcada `integration`, la evidencia de CI del esquema es el gate SQL
supabase/tests/test_presupuestos_modulo.sql).

Spec: openspec/changes/presupuestos-modulo/specs/quote/spec.md (escritura sólo
por RPC, edición con versión, permisos CAN_QUOTE, errores estables).
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
QUOTE_ID = "dddddddd-dddd-dddd-dddd-dddddddddddd"
CLIENT_ID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
PRODUCT_ID = "22222222-2222-2222-2222-222222222222"
UNIT_ID = "44444444-4444-4444-4444-444444444444"
REPO_ROOT = Path(__file__).resolve().parents[2]


def _pg_error(sqlstate: str, message: str) -> asyncpg.PostgresError:
    err = asyncpg.PostgresError(message)
    err.sqlstate = sqlstate
    return err


def _auth(*roles: str) -> dict:
    """Auth ya decodificado, con el CONJUNTO de roles del claim (D8)."""
    return {
        "user_id": TEST_USER_ID,
        "sub": TEST_USER_ID,
        "role": "user",
        "account_roles": list(roles),
    }


def _quote_record(**over) -> dict:
    base = {
        "id": QUOTE_ID,
        "account_id": ACCOUNT_ID,
        "branch_id": None,
        "client_id": CLIENT_ID,
        "status": "draft",
        "valid_until": datetime.date(2026, 10, 16),
        "total": Decimal("1500.00"),
        "created_by": TEST_USER_ID,
        "created_at": datetime.datetime(2026, 10, 1, 12, 0, tzinfo=datetime.timezone.utc),
        "number": 12,
        "notes": None,
        "sent_at": None,
        "updated_at": None,
        "updated_by": None,
        "revision": 1,
        "is_expired": False,
        "client_name": "Ana Pérez",
        "client_phone": "2615550000",
        "client_tax_id": None,
        "sales_order_id": None,
        "items": [],
        "history": [],
    }
    base.update(over)
    return base


def _item_in(**over) -> dict:
    base = {"product_id": PRODUCT_ID, "quantity": "2", "price": "750", "subtotal": "1500"}
    base.update(over)
    return base


# ══════════════════════════════════════════════════════════════════════════════
# 2.1 schemas
# ══════════════════════════════════════════════════════════════════════════════

class TestSchemas:
    def test_client_is_required(self):
        from backend.schemas.quotes import QuoteIn

        with pytest.raises(ValidationError):
            QuoteIn(items=[_item_in()])
        # control positivo: con cliente es válido
        assert QuoteIn(client_id=CLIENT_ID, items=[_item_in()]).client_id == uuid.UUID(CLIENT_ID)

    def test_service_line_needs_description(self):
        from backend.schemas.quotes import QuoteItemIn

        with pytest.raises(ValidationError):
            QuoteItemIn(quantity="1", price="100", subtotal="100")
        with pytest.raises(ValidationError):
            QuoteItemIn(quantity="1", price="100", subtotal="100", description="   ")
        ok = QuoteItemIn(quantity="1", price="100", subtotal="100", description=" Instalación ")
        assert ok.description == "Instalación"

    def test_product_line_does_not_need_description(self):
        from backend.schemas.quotes import QuoteItemIn

        line = QuoteItemIn(**_item_in())
        assert line.description is None

    def test_description_max_200(self):
        from backend.schemas.quotes import QuoteItemIn

        QuoteItemIn(quantity="1", price="1", subtotal="1", description="x" * 200)
        with pytest.raises(ValidationError):
            QuoteItemIn(quantity="1", price="1", subtotal="1", description="x" * 201)

    def test_notes_max_2000(self):
        from backend.schemas.quotes import QuoteIn

        QuoteIn(client_id=CLIENT_ID, items=[_item_in()], notes="n" * 2000)
        with pytest.raises(ValidationError):
            QuoteIn(client_id=CLIENT_ID, items=[_item_in()], notes="n" * 2001)

    def test_transition_actions_are_send_and_reject_only(self):
        from backend.schemas.quotes import QuoteTransitionIn

        assert QuoteTransitionIn(action="send").action == "send"
        assert QuoteTransitionIn(action="reject", reason="precio alto").reason == "precio alto"
        for bad in ("expire", "accept", "sent"):
            with pytest.raises(ValidationError):
                QuoteTransitionIn(action=bad)
        with pytest.raises(ValidationError):
            QuoteTransitionIn(action="reject", reason="r" * 501)

    def test_update_requires_valid_until_not_null_and_revision(self):
        from backend.schemas.quotes import QuoteUpdateIn

        base = {
            "revision": 3, "client_id": CLIENT_ID, "branch_id": None,
            "valid_until": "2026-10-20", "notes": None, "items": [_item_in()],
        }
        ok = QuoteUpdateIn(**base)
        assert ok.revision == 3 and ok.valid_until == datetime.date(2026, 10, 20)
        for field in ("valid_until", "revision", "branch_id", "notes"):
            incomplete = {k: v for k, v in base.items() if k != field}
            with pytest.raises(ValidationError):
                QuoteUpdateIn(**incomplete)
        with pytest.raises(ValidationError):
            QuoteUpdateIn(**{**base, "valid_until": None})
        with pytest.raises(ValidationError):
            QuoteUpdateIn(**{**base, "revision": 0})

    def test_out_carries_revision_and_label(self):
        from backend.schemas.quotes import QuoteOut

        assert {"revision", "number", "number_label", "is_expired", "client_name",
                "client_phone", "sales_order_id", "items", "history", "notes",
                "sent_at", "updated_at"} <= set(QuoteOut.model_fields)

    @pytest.mark.parametrize("days,valid", [(1, True), (365, True), (0, False), (366, False), (-5, False)])
    def test_settings_range_is_validated_before_the_database(self, days, valid):
        from backend.schemas.quotes import QuoteSettingsIn

        if valid:
            assert QuoteSettingsIn(default_quote_validity_days=days).default_quote_validity_days == days
        else:
            with pytest.raises(ValidationError):
                QuoteSettingsIn(default_quote_validity_days=days)


# ══════════════════════════════════════════════════════════════════════════════
# 2.2 CAN_QUOTE espeja el catálogo de la FSM
# ══════════════════════════════════════════════════════════════════════════════

class TestCanQuote:
    def test_value(self):
        from backend.core.rbac import CAN_QUOTE

        assert CAN_QUOTE == frozenset({"owner", "admin", "seller"})

    def test_matches_quote_rows_of_the_seed(self):
        """Atado al catálogo: la unión de los `allowed_role` de las filas de
        `quote` que NO son de sistema (seed de v3-rbac-multirole + las dos
        filas de reapertura de esta migración) es exactamente CAN_QUOTE, y
        cada fila declara el mismo conjunto."""
        from backend.core.rbac import CAN_QUOTE

        seeds = list((REPO_ROOT / "supabase/migrations").glob("20261048000001*.sql"))
        assert len(seeds) == 1, "no se encontró la migración del seed de allowed_role"
        seed_sql = seeds[0].read_text(encoding="utf-8")
        update_roles = re.findall(
            r"allowed_role\s*=\s*ARRAY\[([^\]]*)\]\s+WHERE\s+document_type\s*=\s*'quote'",
            seed_sql,
        )
        migration_sql = (
            REPO_ROOT / "supabase/migrations/20261067000001_presupuestos_modulo.sql"
        ).read_text(encoding="utf-8")
        insert_roles = re.findall(r"\('quote',\s*'(?:expired|rejected)',\s*'draft',[^)]*ARRAY\[([^\]]*)\]", migration_sql)

        assert len(update_roles) == 6, "el seed declara 6 filas de quote con rol"
        assert len(insert_roles) == 2, "la migración agrega 2 filas de reapertura"
        for raw in update_roles + insert_roles:
            roles = frozenset(re.findall(r"'([a-z_]+)'", raw))
            assert roles == CAN_QUOTE


# ══════════════════════════════════════════════════════════════════════════════
# core.errors.problem_from_pg_error — código estable = literal del RAISE
# ══════════════════════════════════════════════════════════════════════════════

class TestProblemFromPgError:
    @pytest.mark.parametrize(
        "sqlstate,message,status,code",
        [
            ("P0423", "quote_locked_converted: el presupuesto ya se convirtió en venta", 409, "quote_locked_converted"),
            ("P0409", "quote_changed: el presupuesto cambió (versión 3 -> 4): revisalo", 409, "quote_changed"),
            ("P0409", "quote_not_deletable: sólo se elimina un borrador", 409, "quote_not_deletable"),
            ("P0403", "insufficient_role: tu rol no permite gestionar presupuestos", 403, "insufficient_role"),
            ("P0401", "unauthorized", 403, "unauthorized"),
            ("P0404", "client_not_found: cccccccc", 404, "client_not_found"),
            ("P0404", "product_not_found: 2222", 404, "product_not_found"),
            ("P0404", "quote_not_found: dddd", 404, "quote_not_found"),
            ("P0404", "branch_not_found or not active for this account", 404, "branch_not_found"),
            ("P0400", "quote_valid_until_required: la edición exige la fecha", 400, "quote_valid_until_required"),
            ("P0400", "product_is_parent: \"Remera\" se vende a través de sus variantes", 400, "product_is_parent"),
            ("P0422", "branch_closed: la sucursal está cerrada", 422, "branch_closed"),
        ],
    )
    def test_literal_code_and_status(self, sqlstate, message, status, code):
        from backend.core.errors import problem_from_pg_error

        problem = problem_from_pg_error(_pg_error(sqlstate, message))

        assert problem.status_code == status
        assert problem.code == code
        assert message in str(problem.detail)

    def test_message_without_literal_falls_back_to_sqlstate(self):
        from backend.core.errors import problem_from_pg_error

        problem = problem_from_pg_error(_pg_error("P0404", "Unit of measure not found: 4444"))

        assert problem.status_code == 404
        assert problem.code == "P0404"

    def test_unmapped_sqlstate_is_not_swallowed(self):
        """CONTROL NEGATIVO: lo que el mapa no conoce vuelve `None`, para que
        el handler global lo resuelva como 500 sin filtrar internals."""
        from backend.core.errors import problem_from_pg_error

        assert problem_from_pg_error(_pg_error("P0999", "errcode inventado")) is None
        assert problem_from_pg_error(_pg_error("42501", "Not authenticated")) is None


# ══════════════════════════════════════════════════════════════════════════════
# 2.1 service — guards de rol y mapeo de errores
# ══════════════════════════════════════════════════════════════════════════════

def _payload_in():
    from backend.schemas.quotes import QuoteIn, QuoteItemIn

    return QuoteIn(
        client_id=CLIENT_ID,
        valid_until="2026-10-20",
        notes="Entrega en 48 hs",
        items=[
            QuoteItemIn(product_id=PRODUCT_ID, unit_id=UNIT_ID, quantity="2", price="750.50", subtotal="1501"),
            QuoteItemIn(quantity="1", price="300", subtotal="300", description="Instalación"),
        ],
    )


def _payload_update(**over):
    from backend.schemas.quotes import QuoteUpdateIn, QuoteItemIn

    data = {
        "revision": 2, "client_id": CLIENT_ID, "branch_id": None,
        "valid_until": "2026-10-25", "notes": None,
        "items": [QuoteItemIn(**_item_in())],
    }
    data.update(over)
    return QuoteUpdateIn(**data)


def _repo(**returns) -> AsyncMock:
    repo = AsyncMock()
    repo.create_quote.return_value = {"id": QUOTE_ID, "account_id": ACCOUNT_ID}
    repo.update_quote.return_value = {"id": QUOTE_ID, "account_id": ACCOUNT_ID}
    repo.transition_quote.return_value = {"id": QUOTE_ID, "account_id": ACCOUNT_ID}
    repo.delete_quote.return_value = None
    repo.get_quote.return_value = _quote_record()
    for name, value in returns.items():
        getattr(repo, name).return_value = value
    return repo


WRITE_CALLS = {
    "create": lambda svc, repo, auth, conn: svc.create_quote(repo, auth, ACCOUNT_ID, _payload_in(), conn=conn),
    "update": lambda svc, repo, auth, conn: svc.update_quote(repo, auth, ACCOUNT_ID, QUOTE_ID, _payload_update(), conn=conn),
    "transition": lambda svc, repo, auth, conn: svc.transition_quote(
        repo, auth, ACCOUNT_ID, QUOTE_ID, __import__("backend.schemas.quotes", fromlist=["x"]).QuoteTransitionIn(action="send"), conn=conn),
    "delete": lambda svc, repo, auth, conn: svc.delete_quote(repo, auth, ACCOUNT_ID, QUOTE_ID, conn=conn),
}
REPO_WRITE_METHOD = {
    "create": "create_quote", "update": "update_quote",
    "transition": "transition_quote", "delete": "delete_quote",
}


class TestServiceRoleGuard:
    @pytest.mark.asyncio
    @pytest.mark.parametrize("op", sorted(WRITE_CALLS))
    async def test_cashier_gets_403_without_calling_the_rpc(self, op):
        from backend.services import quotes as svc

        repo = _repo()
        with pytest.raises(HTTPException) as info:
            await WRITE_CALLS[op](svc, repo, _auth("cashier"), AsyncMock())

        assert info.value.status_code == 403
        assert getattr(info.value, "code", None) == "insufficient_role"
        getattr(repo, REPO_WRITE_METHOD[op]).assert_not_awaited()

    @pytest.mark.asyncio
    @pytest.mark.parametrize("op", sorted(WRITE_CALLS))
    @pytest.mark.parametrize("role", ["seller", "admin", "owner"])
    async def test_can_quote_roles_reach_the_rpc(self, op, role):
        from backend.services import quotes as svc

        repo = _repo()
        await WRITE_CALLS[op](svc, repo, _auth(role), AsyncMock())

        getattr(repo, REPO_WRITE_METHOD[op]).assert_awaited_once()

    @pytest.mark.asyncio
    async def test_roles_resolved_from_the_database_when_the_claim_is_absent(self):
        """Sin claim `account_roles` el guard consulta el pivot (D10): un
        vendedor pasa y un cajero no, también por ese camino."""
        from backend.services import quotes as svc

        auth = {"user_id": TEST_USER_ID, "sub": TEST_USER_ID, "role": "user"}
        conn = AsyncMock()
        conn.fetchval = account_roles_fetchval(["cashier"])
        repo = _repo()
        with pytest.raises(HTTPException) as info:
            await svc.delete_quote(repo, auth, ACCOUNT_ID, QUOTE_ID, conn=conn)
        assert info.value.status_code == 403
        repo.delete_quote.assert_not_awaited()

        conn.fetchval = account_roles_fetchval(["seller"])
        await svc.delete_quote(repo, auth, ACCOUNT_ID, QUOTE_ID, conn=conn)
        repo.delete_quote.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_legacy_role_user_is_not_enough(self):
        """Se retira `require_role(["user","admin"])`: el rol de plataforma
        `user` por sí solo ya no autoriza escribir presupuestos."""
        from backend.services import quotes as svc

        auth = {"user_id": TEST_USER_ID, "sub": TEST_USER_ID, "role": "user", "account_roles": ["viewer"]}
        with pytest.raises(HTTPException) as info:
            await svc.create_quote(_repo(), auth, ACCOUNT_ID, _payload_in(), conn=AsyncMock())
        assert info.value.status_code == 403


class TestServiceBehavior:
    @pytest.mark.asyncio
    async def test_create_serializes_lines_and_returns_the_full_quote(self):
        from backend.services import quotes as svc

        repo = _repo()
        result = await svc.create_quote(repo, _auth("seller"), ACCOUNT_ID, _payload_in(), conn=AsyncMock())

        kwargs = repo.create_quote.await_args.kwargs
        assert kwargs["client_id"] == CLIENT_ID
        assert kwargs["branch_id"] is None
        assert kwargs["valid_until"] == datetime.date(2026, 10, 20)
        assert kwargs["notes"] == "Entrega en 48 hs"
        assert kwargs["items"] == [
            {"product_id": PRODUCT_ID, "unit_id": UNIT_ID, "quantity": "2",
             "price": "750.50", "subtotal": "1501", "description": None},
            {"product_id": None, "unit_id": None, "quantity": "1",
             "price": "300", "subtotal": "300", "description": "Instalación"},
        ]
        # la lectura de vuelta es por la cuenta que devolvió la RPC, no por una
        # supuesta: con varias cuentas la del cliente es la que manda
        repo.get_quote.assert_awaited_once_with(QUOTE_ID, ACCOUNT_ID)
        assert result["number_label"] == "P-00000012"
        assert result["revision"] == 1

    @pytest.mark.asyncio
    async def test_create_reads_back_from_the_account_the_rpc_resolved(self):
        from backend.services import quotes as svc

        other = "99999999-9999-9999-9999-999999999999"
        repo = _repo(create_quote={"id": QUOTE_ID, "account_id": other})
        await svc.create_quote(repo, _auth("owner"), ACCOUNT_ID, _payload_in(), conn=AsyncMock())

        repo.get_quote.assert_awaited_once_with(QUOTE_ID, other)

    @pytest.mark.asyncio
    async def test_foreign_client_surfaces_client_not_found_from_the_rpc(self):
        """El pre-chequeo Python `client_belongs_to_account` se retiró: un
        `client_id` ajeno responde `client_not_found` ahora desde la RPC."""
        from backend.services import quotes as svc

        repo = _repo()
        repo.create_quote.side_effect = _pg_error("P0404", f"client_not_found: {CLIENT_ID}")

        with pytest.raises(HTTPException) as info:
            await svc.create_quote(repo, _auth("seller"), ACCOUNT_ID, _payload_in(), conn=AsyncMock())

        assert info.value.status_code == 404
        assert info.value.code == "client_not_found"
        assert not hasattr(repo, "client_belongs_to_account") or not repo.client_belongs_to_account.await_count

    @pytest.mark.asyncio
    async def test_unmapped_sqlstate_still_propagates_for_the_global_500(self):
        """CONTROL NEGATIVO del mapeo: lo desconocido no se disfraza."""
        from backend.services import quotes as svc

        repo = _repo()
        repo.create_quote.side_effect = _pg_error("P0999", "errcode inventado que nadie mapea")

        with pytest.raises(asyncpg.PostgresError):
            await svc.create_quote(repo, _auth("seller"), ACCOUNT_ID, _payload_in(), conn=AsyncMock())

    @pytest.mark.asyncio
    @pytest.mark.parametrize(
        "sqlstate,message,status,code",
        [
            ("P0423", "quote_locked_converted: ya se convirtió", 409, "quote_locked_converted"),
            ("P0409", "quote_changed: versión 2 -> 3", 409, "quote_changed"),
            ("P0400", "quote_valid_until_in_past: la validez no puede ser anterior a hoy", 400, "quote_valid_until_in_past"),
            ("P0404", "quote_not_found: x", 404, "quote_not_found"),
            ("P0403", "insufficient_role: tu rol no permite", 403, "insufficient_role"),
            ("P0401", "unauthorized", 403, "unauthorized"),
        ],
    )
    async def test_update_maps_typed_errors_to_problem_7807(self, sqlstate, message, status, code):
        from backend.services import quotes as svc

        repo = _repo()
        repo.update_quote.side_effect = _pg_error(sqlstate, message)

        with pytest.raises(HTTPException) as info:
            await svc.update_quote(repo, _auth("seller"), ACCOUNT_ID, QUOTE_ID, _payload_update(), conn=AsyncMock())

        assert info.value.status_code == status
        assert info.value.code == code
        assert type(info.value) is not HTTPException  # ProblemHTTPException, nunca un HTTPException crudo

    @pytest.mark.asyncio
    async def test_update_passes_the_expected_revision_and_full_replacement(self):
        from backend.services import quotes as svc

        repo = _repo()
        await svc.update_quote(repo, _auth("seller"), ACCOUNT_ID, QUOTE_ID, _payload_update(revision=7), conn=AsyncMock())

        kwargs = repo.update_quote.await_args.kwargs
        assert repo.update_quote.await_args.args == (QUOTE_ID,)
        assert kwargs["expected_revision"] == 7
        assert kwargs["valid_until"] == datetime.date(2026, 10, 25)
        assert kwargs["branch_id"] is None and kwargs["notes"] is None
        repo.get_quote.assert_awaited_once_with(QUOTE_ID, ACCOUNT_ID)

    @pytest.mark.asyncio
    @pytest.mark.parametrize("action,to_status,reason", [("send", "sent", None), ("reject", "rejected", "precio alto")])
    async def test_transition_maps_the_action(self, action, to_status, reason):
        from backend.schemas.quotes import QuoteTransitionIn
        from backend.services import quotes as svc

        repo = _repo()
        await svc.transition_quote(
            repo, _auth("seller"), ACCOUNT_ID, QUOTE_ID,
            QuoteTransitionIn(action=action, reason=reason), conn=AsyncMock(),
        )

        repo.transition_quote.assert_awaited_once_with(QUOTE_ID, to_status, reason)

    @pytest.mark.asyncio
    @pytest.mark.parametrize("op", ["transition", "delete"])
    async def test_foreign_or_missing_quote_is_404_quote_not_found(self, op):
        """Write-IDOR: transicionar o borrar el presupuesto de OTRA cuenta
        responde igual que uno inexistente (la RPC no lo ve), 404 con código
        estable — y no revela si el id existe en otro tenant."""
        from backend.services import quotes as svc

        repo = _repo()
        getattr(repo, REPO_WRITE_METHOD[op]).side_effect = _pg_error("P0404", f"quote_not_found: {QUOTE_ID}")

        with pytest.raises(HTTPException) as info:
            await WRITE_CALLS[op](svc, repo, _auth("seller"), AsyncMock())

        assert (info.value.status_code, info.value.code) == (404, "quote_not_found")

    @pytest.mark.asyncio
    async def test_transition_from_a_closed_state_is_409_quote_invalid_state(self):
        from backend.schemas.quotes import QuoteTransitionIn
        from backend.services import quotes as svc

        repo = _repo()
        repo.transition_quote.side_effect = _pg_error(
            "P0409", "quote_invalid_state: un presupuesto en rejected no admite pasar a sent")

        with pytest.raises(HTTPException) as info:
            await svc.transition_quote(
                repo, _auth("seller"), ACCOUNT_ID, QUOTE_ID, QuoteTransitionIn(action="send"), conn=AsyncMock())

        assert (info.value.status_code, info.value.code) == (409, "quote_invalid_state")

    @pytest.mark.asyncio
    async def test_delete_not_deletable_is_409_with_stable_code(self):
        from backend.services import quotes as svc

        repo = _repo()
        repo.delete_quote.side_effect = _pg_error("P0409", "quote_not_deletable: sólo se elimina un borrador")

        with pytest.raises(HTTPException) as info:
            await svc.delete_quote(repo, _auth("owner"), ACCOUNT_ID, QUOTE_ID, conn=AsyncMock())

        assert (info.value.status_code, info.value.code) == (409, "quote_not_deletable")

    @pytest.mark.asyncio
    async def test_get_quote_404_problem_is_the_same_for_foreign_and_missing(self):
        from backend.services import quotes as svc

        repo = _repo()
        repo.get_quote.return_value = None

        with pytest.raises(HTTPException) as info:
            await svc.get_quote(repo, ACCOUNT_ID, QUOTE_ID)

        assert info.value.status_code == 404
        assert info.value.code == "quote_not_found"
        repo.get_quote.assert_awaited_once_with(QUOTE_ID, ACCOUNT_ID)

    @pytest.mark.asyncio
    async def test_get_quote_without_number_has_no_label(self):
        from backend.services import quotes as svc

        repo = _repo(get_quote=_quote_record(number=None))
        assert (await svc.get_quote(repo, ACCOUNT_ID, QUOTE_ID))["number_label"] is None


class TestServiceListing:
    @pytest.mark.asyncio
    async def test_envelope_and_filters(self):
        from backend.services import quotes as svc

        repo = AsyncMock()
        row = {k: v for k, v in _quote_record().items() if k not in ("items", "history")}
        repo.list_quotes.return_value = ([row, dict(row, id="eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee", number=13)], 52)

        page = await svc.list_quotes(
            repo, ACCOUNT_ID, page=1, page_size=25, status="sent", client_id=CLIENT_ID, q="P-12",
        )

        repo.list_quotes.assert_awaited_once_with(
            ACCOUNT_ID, page=1, page_size=25, status="sent", client_id=CLIENT_ID, text="P-12", number=12,
        )
        assert (page["total"], page["page"], page["pages"]) == (52, 1, 3)
        assert [i["number_label"] for i in page["items"]] == ["P-00000012", "P-00000013"]

    @pytest.mark.asyncio
    async def test_empty_listing_has_zero_pages(self):
        from backend.services import quotes as svc

        repo = AsyncMock()
        repo.list_quotes.return_value = ([], 0)

        page = await svc.list_quotes(repo, ACCOUNT_ID, page=0, page_size=25, status=None, client_id=None, q=None)

        assert page == {"items": [], "total": 0, "page": 0, "pages": 0}


class TestServiceSettings:
    @pytest.mark.asyncio
    async def test_get_is_open_to_any_member(self):
        from backend.services import quotes as svc

        repo = AsyncMock()
        repo.get_default_validity_days.return_value = 15

        assert await svc.get_quote_settings(repo, ACCOUNT_ID) == {"default_quote_validity_days": 15}
        repo.get_default_validity_days.assert_awaited_once_with(ACCOUNT_ID)

    @pytest.mark.asyncio
    async def test_set_requires_owner_or_admin_checked_against_the_database(self):
        """CAN_CONFIGURE es capacidad sensible: la base es la autoridad aunque
        el claim diga otra cosa (D12 de auth-hardening)."""
        from backend.schemas.quotes import QuoteSettingsIn
        from backend.services import quotes as svc

        repo = AsyncMock()
        repo.set_default_validity_days.return_value = 30
        conn = AsyncMock()
        conn.fetchval = account_roles_fetchval(["seller"])

        with pytest.raises(HTTPException) as info:
            await svc.set_quote_settings(
                repo, _auth("owner"), QuoteSettingsIn(default_quote_validity_days=30), conn=conn,
            )
        assert info.value.status_code == 403
        repo.set_default_validity_days.assert_not_awaited()

        conn.fetchval = account_roles_fetchval(["admin"])
        out = await svc.set_quote_settings(
            repo, _auth("seller"), QuoteSettingsIn(default_quote_validity_days=30), conn=conn,
        )
        assert out == {"default_quote_validity_days": 30}
        repo.set_default_validity_days.assert_awaited_once_with(30)

    @pytest.mark.asyncio
    async def test_set_maps_the_rpc_range_error(self):
        from backend.schemas.quotes import QuoteSettingsIn
        from backend.services import quotes as svc

        repo = AsyncMock()
        repo.set_default_validity_days.side_effect = _pg_error("P0400", "quote_validity_out_of_range: 1 a 365")
        conn = AsyncMock()
        conn.fetchval = account_roles_fetchval(["owner"])

        with pytest.raises(HTTPException) as info:
            await svc.set_quote_settings(
                repo, _auth("owner"), QuoteSettingsIn(default_quote_validity_days=30), conn=conn,
            )
        assert info.value.code == "quote_validity_out_of_range"


# ══════════════════════════════════════════════════════════════════════════════
# 2.1 repositorio — sólo RPC o SELECT con account_id explícito
# ══════════════════════════════════════════════════════════════════════════════

class _RecordingConn:
    """Conexión que anota cada consulta y responde con lo mínimo."""

    def __init__(self):
        self.queries: list[tuple[str, tuple]] = []

    async def _answer(self, query, args, default):
        self.queries.append((query, args))
        return default

    async def fetchval(self, query, *args):
        return await self._answer(query, args, json.dumps({"id": QUOTE_ID, "account_id": ACCOUNT_ID, "items": []}))

    async def fetchrow(self, query, *args):
        return await self._answer(query, args, None)

    async def fetch(self, query, *args):
        return await self._answer(query, args, [])

    async def execute(self, query, *args):
        return await self._answer(query, args, "OK")


DIRECT_WRITE = re.compile(r"(INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+(public\.)?quote(s|_items)\b", re.I)


class TestRepositoryUsesRpcOnly:
    @pytest.mark.asyncio
    async def test_no_method_writes_quotes_or_quote_items_directly(self):
        from backend.repositories.quote_repository import QuoteRepository

        conn = _RecordingConn()
        repo = QuoteRepository(conn)
        await repo.create_quote(client_id=CLIENT_ID, branch_id=None, valid_until=None, notes=None, items=[_item_in()])
        await repo.update_quote(QUOTE_ID, expected_revision=1, client_id=CLIENT_ID, branch_id=None,
                                valid_until=datetime.date(2026, 10, 20), notes=None, items=[_item_in()])
        await repo.transition_quote(QUOTE_ID, "sent", None)
        await repo.delete_quote(QUOTE_ID)
        await repo.get_quote(QUOTE_ID, ACCOUNT_ID)
        await repo.list_quotes(ACCOUNT_ID, page=0, page_size=25, status=None, client_id=None, text=None, number=None)
        await repo.get_default_validity_days(ACCOUNT_ID)
        await repo.set_default_validity_days(15)
        await repo.get_commercial_issuer(ACCOUNT_ID)

        assert conn.queries, "el repositorio no emitió ninguna consulta"
        for query, _ in conn.queries:
            assert not DIRECT_WRITE.search(query), f"escritura directa sobre quotes: {query[:90]}"

    @pytest.mark.asyncio
    async def test_writes_go_through_the_named_rpcs(self):
        from backend.repositories.quote_repository import QuoteRepository

        conn = _RecordingConn()
        repo = QuoteRepository(conn)
        await repo.create_quote(client_id=CLIENT_ID, branch_id=None, valid_until=None, notes=None, items=[_item_in()])
        await repo.update_quote(QUOTE_ID, expected_revision=4, client_id=CLIENT_ID, branch_id=None,
                                valid_until=datetime.date(2026, 10, 20), notes="n", items=[_item_in()])
        await repo.transition_quote(QUOTE_ID, "rejected", "precio alto")
        await repo.delete_quote(QUOTE_ID)
        await repo.set_default_validity_days(30)
        await repo.get_commercial_issuer(ACCOUNT_ID)

        called = " ".join(q for q, _ in conn.queries)
        for rpc in ("rpc_create_quote", "rpc_update_quote", "rpc_transition_quote",
                    "rpc_delete_quote", "rpc_set_default_quote_validity", "rpc_commercial_issuer"):
            assert rpc in called, f"falta la llamada a {rpc}"

    @pytest.mark.asyncio
    async def test_create_ships_lines_as_jsonb_and_returns_the_parsed_payload(self):
        from backend.repositories.quote_repository import QuoteRepository

        conn = _RecordingConn()
        repo = QuoteRepository(conn)
        created = await repo.create_quote(
            client_id=CLIENT_ID, branch_id=None, valid_until=datetime.date(2026, 10, 20), notes="n",
            items=[{"product_id": PRODUCT_ID, "quantity": "2", "price": "750.50", "subtotal": "1501",
                    "description": None, "unit_id": None}],
        )

        query, args = conn.queries[0]
        assert "::jsonb" in query
        assert args[0] == CLIENT_ID and args[1] is None and args[2] == datetime.date(2026, 10, 20) and args[3] == "n"
        assert json.loads(args[4])[0]["price"] == "750.50"
        assert created["id"] == QUOTE_ID

    @pytest.mark.asyncio
    async def test_update_ships_the_expected_revision(self):
        from backend.repositories.quote_repository import QuoteRepository

        conn = _RecordingConn()
        await QuoteRepository(conn).update_quote(
            QUOTE_ID, expected_revision=4, client_id=CLIENT_ID, branch_id=None,
            valid_until=datetime.date(2026, 10, 20), notes=None, items=[_item_in()],
        )

        _, args = conn.queries[0]
        assert args[0] == QUOTE_ID and args[1] == 4


class TestRepositoryReads:
    @pytest.mark.asyncio
    async def test_get_quote_is_scoped_to_the_account_and_returns_items_and_history(self):
        from backend.repositories.quote_repository import QuoteRepository

        header = {k: v for k, v in _quote_record().items() if k not in ("items", "history")}
        line = {"id": uuid.uuid4(), "quote_id": QUOTE_ID, "account_id": ACCOUNT_ID, "product_id": PRODUCT_ID,
                "unit_id": None, "unit_symbol": None, "quantity": Decimal("2"), "price": Decimal("750"),
                "subtotal": Decimal("1500"), "name_snapshot": "Tornillo", "line_no": 1}
        event = {"from_status": None, "to_status": "draft", "performed_by": TEST_USER_ID,
                 "reason": None, "occurred_at": datetime.datetime(2026, 10, 1, tzinfo=datetime.timezone.utc)}

        seen: list[tuple[str, tuple]] = []

        class Conn:
            async def fetchrow(self, query, *args):
                seen.append((query, args))
                return header

            async def fetch(self, query, *args):
                seen.append((query, args))
                return [line] if "quote_items" in query else [event]

        got = await QuoteRepository(Conn()).get_quote(QUOTE_ID, ACCOUNT_ID)

        assert got["items"] == [line] and got["history"] == [event]
        assert got["client_name"] == "Ana Pérez"
        assert len(seen) == 3
        for query, args in seen:
            assert re.search(r"account_id\s*=\s*\$\d", query), f"consulta sin account_id explícito: {query[:80]}"
            assert ACCOUNT_ID in args and QUOTE_ID in args

    @pytest.mark.asyncio
    async def test_get_quote_missing_returns_none_without_reading_children(self):
        from backend.repositories.quote_repository import QuoteRepository

        conn = AsyncMock()
        conn.fetchrow.return_value = None

        assert await QuoteRepository(conn).get_quote(QUOTE_ID, ACCOUNT_ID) is None
        conn.fetch.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_list_uses_the_same_filters_for_count_and_page(self):
        from backend.repositories.quote_repository import QuoteRepository

        conn = AsyncMock()
        conn.fetchval.return_value = 7
        conn.fetch.return_value = [{"id": QUOTE_ID}]

        rows, total = await QuoteRepository(conn).list_quotes(
            ACCOUNT_ID, page=2, page_size=5, status="expired", client_id=CLIENT_ID, text="P-12", number=12,
        )

        assert total == 7 and rows == [{"id": QUOTE_ID}]
        count_sql, *count_args = conn.fetchval.await_args.args
        page_sql, *page_args = conn.fetch.await_args.args
        assert "q.account_id = $1::uuid" in count_sql and "q.account_id = $1::uuid" in page_sql
        assert count_args == page_args[:-2], "COUNT y página deben compartir exactamente los mismos filtros"
        assert page_args[-2:] == [5, 10]  # LIMIT page_size OFFSET page*page_size
        assert count_args[0] == ACCOUNT_ID
        assert count_args[-1] == 12 and count_args[-2] == "%P-12%"
        assert "reporting_local_today()" in count_sql  # is_expired con el día ART

    @pytest.mark.asyncio
    async def test_list_text_search_escapes_like_wildcards(self):
        from backend.repositories.quote_repository import QuoteRepository

        conn = AsyncMock()
        conn.fetchval.return_value = 0
        conn.fetch.return_value = []

        await QuoteRepository(conn).list_quotes(
            ACCOUNT_ID, page=0, page_size=25, status=None, client_id=None, text="50%_off", number=None,
        )

        _, *args = conn.fetchval.await_args.args
        patterns = [a for a in args if isinstance(a, str) and "off" in a]
        assert patterns == ["%50\\%\\_off%"]

    @pytest.mark.asyncio
    async def test_commercial_issuer_comes_only_from_the_rpc(self):
        from backend.repositories.quote_repository import QuoteRepository

        conn = AsyncMock()
        conn.fetchval.return_value = json.dumps({"business_name": "Almacén Don José", "phone": "2615550000"})

        issuer = await QuoteRepository(conn).get_commercial_issuer(ACCOUNT_ID)

        assert issuer["business_name"] == "Almacén Don José"
        query = conn.fetchval.await_args.args[0]
        assert "rpc_commercial_issuer" in query
        assert not re.search(r"\bprofiles\b", query), "el emisor no se lee de profiles por la conexión del request"


# ══════════════════════════════════════════════════════════════════════════════
# 2.3 / 2.4 endpoints HTTP
# ══════════════════════════════════════════════════════════════════════════════

@pytest.fixture
def repo_override(mock_pool):
    """Reemplaza el repositorio del router por un doble; la conexión (para el
    guard de rol) sigue siendo la del pool de prueba."""
    from backend.main import app
    from backend.routers.quotes import get_quote_repo

    repo = _repo()
    app.dependency_overrides[get_quote_repo] = lambda: repo
    try:
        yield repo, mock_pool
    finally:
        app.dependency_overrides.pop(get_quote_repo, None)


def _headers(*roles: str) -> dict:
    # El hook de auth deja el CONJUNTO de roles en app_metadata.account_roles (D8).
    return {"Authorization": f"Bearer {make_token({'app_metadata': {'account_roles': list(roles)}})}"}


def _body(**over) -> dict:
    data = {"client_id": CLIENT_ID, "valid_until": "2026-10-20", "items": [_item_in()]}
    data.update(over)
    return data


class TestEndpoints:
    async def test_create_returns_201_with_the_full_quote(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post("/quotes", json=_body(), headers=_headers("seller"))

        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert body["id"] == QUOTE_ID and body["number_label"] == "P-00000012" and body["revision"] == 1
        repo.create_quote.assert_awaited_once()

    async def test_cashier_cannot_create_update_transition_or_delete(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        calls = [
            ("post", "/quotes", _body()),
            ("put", f"/quotes/{QUOTE_ID}", {"revision": 1, "client_id": CLIENT_ID, "branch_id": None,
                                            "valid_until": "2026-10-20", "notes": None, "items": [_item_in()]}),
            ("post", f"/quotes/{QUOTE_ID}/transition", {"action": "send"}),
            ("delete", f"/quotes/{QUOTE_ID}", None),
        ]
        with patch("backend.core.database.pool", pool):
            for verb, url, body in calls:
                kwargs = {"headers": _headers("cashier")}
                if body is not None:
                    kwargs["json"] = body
                resp = await getattr(async_client, verb)(url, **kwargs)
                assert resp.status_code == 403, f"{verb} {url}: {resp.status_code}"
                assert resp.headers["content-type"].startswith("application/problem+json")
                assert resp.json()["code"] == "insufficient_role"

        for method in ("create_quote", "update_quote", "transition_quote", "delete_quote"):
            getattr(repo, method).assert_not_awaited()

    async def test_cashier_can_read(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        repo.list_quotes.return_value = ([], 0)
        with patch("backend.core.database.pool", pool):
            listing = await async_client.get("/quotes", headers=_headers("cashier"))
            detail = await async_client.get(f"/quotes/{QUOTE_ID}", headers=_headers("cashier"))

        assert listing.status_code == 200 and detail.status_code == 200

    async def test_list_envelope_and_query_params(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        row = {k: v for k, v in _quote_record().items() if k not in ("items", "history")}
        repo.list_quotes.return_value = ([row], 1)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                f"/quotes?status=sent&client_id={CLIENT_ID}&q=P-12&page=0&page_size=10",
                headers=_headers("seller"),
            )

        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert set(body) == {"items", "total", "page", "pages"}
        assert body["items"][0]["number_label"] == "P-00000012"
        repo.list_quotes.assert_awaited_once_with(
            ACCOUNT_ID, page=0, page_size=10, status="sent", client_id=CLIENT_ID, text="P-12", number=12,
        )

    async def test_list_rejects_an_unknown_status(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get("/quotes?status=converted", headers=_headers("seller"))
        assert resp.status_code == 422
        repo.list_quotes.assert_not_awaited()

    async def test_create_without_client_is_422_before_the_database(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/quotes", json={"items": [_item_in()]}, headers=_headers("seller"),
            )
        assert resp.status_code == 422
        repo.create_quote.assert_not_awaited()

    async def test_update_and_delete_roundtrip(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        body = {"revision": 1, "client_id": CLIENT_ID, "branch_id": None, "valid_until": "2026-10-20",
                "notes": None, "items": [_item_in()]}
        with patch("backend.core.database.pool", pool):
            put = await async_client.put(f"/quotes/{QUOTE_ID}", json=body, headers=_headers("seller"))
            delete = await async_client.delete(f"/quotes/{QUOTE_ID}", headers=_headers("seller"))

        assert put.status_code == 200, put.text
        assert delete.status_code == 204
        repo.delete_quote.assert_awaited_once_with(QUOTE_ID)

    async def test_update_conflict_is_409_problem_with_code(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        repo.update_quote.side_effect = _pg_error("P0409", "quote_changed: versión 1 -> 2")
        body = {"revision": 1, "client_id": CLIENT_ID, "branch_id": None, "valid_until": "2026-10-20",
                "notes": None, "items": [_item_in()]}
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(f"/quotes/{QUOTE_ID}", json=body, headers=_headers("seller"))

        assert resp.status_code == 409
        assert resp.headers["content-type"].startswith("application/problem+json")
        assert resp.json()["code"] == "quote_changed"

    async def test_transition_rejects_expire_and_accept_actions(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        with patch("backend.core.database.pool", pool):
            for action in ("expire", "accept"):
                resp = await async_client.post(
                    f"/quotes/{QUOTE_ID}/transition", json={"action": action}, headers=_headers("seller"),
                )
                assert resp.status_code == 422, action
        repo.transition_quote.assert_not_awaited()

    async def test_transition_send_and_reject(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        with patch("backend.core.database.pool", pool):
            sent = await async_client.post(
                f"/quotes/{QUOTE_ID}/transition", json={"action": "send"}, headers=_headers("seller"))
            rejected = await async_client.post(
                f"/quotes/{QUOTE_ID}/transition", json={"action": "reject", "reason": "precio alto"},
                headers=_headers("seller"))

        assert sent.status_code == 200 and rejected.status_code == 200
        assert [c.args for c in repo.transition_quote.await_args_list] == [
            (QUOTE_ID, "sent", None), (QUOTE_ID, "rejected", "precio alto"),
        ]

    async def test_get_missing_quote_is_404_problem(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        repo.get_quote.return_value = None
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(f"/quotes/{QUOTE_ID}", headers=_headers("seller"))

        assert resp.status_code == 404
        assert resp.json()["code"] == "quote_not_found"

    async def test_accept_endpoint_is_gone(self, async_client, repo_override):
        """POST /quotes/{id}/accept se retiró (D12): la única vía a `accepted`
        es la conversión a venta."""
        repo, (pool, conn) = repo_override
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(f"/quotes/{QUOTE_ID}/accept", headers=_headers("owner"))
        assert resp.status_code in (404, 405)

    async def test_unauthenticated_is_401(self, async_client, repo_override):
        resp = await async_client.get("/quotes")
        assert resp.status_code == 401


class TestSettingsEndpoints:
    async def test_get_settings_is_open_to_members(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        repo.get_default_validity_days.return_value = 15
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get("/settings/quotes", headers=_headers("cashier"))

        assert resp.status_code == 200
        assert resp.json() == {"default_quote_validity_days": 15}

    @pytest.mark.parametrize("verb", ["patch", "put"])
    async def test_owner_updates(self, async_client, repo_override, verb):
        repo, (pool, conn) = repo_override
        conn.fetchval = account_roles_fetchval(["owner"])
        repo.set_default_validity_days.return_value = 30
        with patch("backend.core.database.pool", pool):
            resp = await getattr(async_client, verb)(
                "/settings/quotes", json={"default_quote_validity_days": 30}, headers=_headers("owner"),
            )

        assert resp.status_code == 200, resp.text
        assert resp.json() == {"default_quote_validity_days": 30}

    async def test_seller_cannot_update(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        conn.fetchval = account_roles_fetchval(["seller"])
        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                "/settings/quotes", json={"default_quote_validity_days": 30}, headers=_headers("seller"),
            )
        assert resp.status_code == 403
        repo.set_default_validity_days.assert_not_awaited()

    @pytest.mark.parametrize("days", [0, 366])
    async def test_out_of_range_is_422_before_the_database(self, async_client, repo_override, days):
        repo, (pool, conn) = repo_override
        conn.fetchval = account_roles_fetchval(["owner"])
        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                "/settings/quotes", json={"default_quote_validity_days": days}, headers=_headers("owner"),
            )
        assert resp.status_code == 422
        repo.set_default_validity_days.assert_not_awaited()
