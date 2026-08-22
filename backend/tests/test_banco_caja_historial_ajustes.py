"""
banco-caja-historial-ajustes — historial de movimientos (D2/D3) + ajuste
manual con motivo obligatorio en Caja y Banco (D4/D6), sin tapar la señal
antifraude del arqueo (D5, RN-95). Strict TDD Mode.

Comportamientos cubiertos:
  - Schema: RegisterMovementIn rechaza un adjustment sin motivo (client-side,
    antes de tocar la DB); acepta signo libre para adjustment.
  - Schema: ManualMovementIn rechaza un manual_adjustment sin motivo;
    transfer_in sin motivo sigue siendo válido.
  - Repository: register_movement propaga description como 5to parámetro al
    RPC; list_movements_by_cashbox_page arma filtros server-side (types/q/
    rango de fechas) y el envelope estándar.
  - Repository: BankAccountRepository.list_movements_page arma filtros
    server-side (types/status/q/rango) y el envelope estándar.
  - Service: register_movement pasa el motivo; list_movements_by_cashbox /
    bank_movements.list_movements delegan sin guard de rol (lectura).
  - Endpoint: POST /sessions/{id}/movements con adjustment+motivo → 200;
    sin motivo → 422 con field=description (mismo endpoint, sin camino
    paralelo); member (rol insuficiente) → 403, igual que cualquier otro
    movimiento.
  - Endpoint: GET /cashboxes/{id}/movements → 200, envelope {items,total,
    page,pages}.
  - Endpoint: GET /bank-accounts/{id}/movements → 200, envelope.
  - Endpoint: POST /bank-accounts/{id}/movements manual_adjustment sin
    motivo → 422 con field=description.
  - core.errors: P0413 mapea a 422 con field=description.
"""
from __future__ import annotations

import json
import sys
import types
import uuid
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
import asyncpg
from pydantic import ValidationError

from backend.tests.conftest import make_token

# Workaround: fpdf2 no instalado en dev (issue preexistente, ver test_c28_cash_session.py)
try:
    import fpdf  # noqa: F401
except ImportError:
    _fpdf_stub = types.ModuleType("fpdf")
    _fpdf_stub.FPDF = MagicMock  # type: ignore[attr-defined]
    sys.modules["fpdf"] = _fpdf_stub

CASHBOX_ID  = "cccccccc-cccc-cccc-cccc-cccccccccccc"
SESSION_ID  = "dddddddd-dddd-dddd-dddd-dddddddddddd"
MOVEMENT_ID = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
BANK_ACCOUNT_ID = "ffffffff-ffff-ffff-ffff-ffffffffffff"

ADJUSTMENT_MOVEMENT_ROW = {
    "id":            MOVEMENT_ID,
    "session_id":    SESSION_ID,
    "amount":        Decimal("500.00"),
    "movement_type": "adjustment",
    "reference_id":  None,
    "balance_after": Decimal("8500.00"),
    "created_by":    "11111111-1111-1111-1111-111111111111",
    "created_at":    "2026-08-22T10:05:00",
    "description":   "sobrante detectado en el conteo",
}

CASHBOX_MOVEMENTS_PAGE_ROW = {
    **ADJUSTMENT_MOVEMENT_ROW,
    "session_opened_at": "2026-08-22T09:00:00",
    "session_status":    "open",
}

BANK_MOVEMENT_ROW = {
    "id":                     MOVEMENT_ID,
    "bank_account_id":        BANK_ACCOUNT_ID,
    "amount":                 Decimal("-1200.00"),
    "balance_after":          Decimal("8800.00"),
    "movement_type":          "manual_adjustment",
    "value_date":             "2026-08-22",
    "description":            "diferencia contra extracto de agosto",
    "created_at":              "2026-08-22T10:05:00",
    "reconciliation_status":  "unreconciled",
}


# ══════════════════════════════════════════════════════════════════════════════
# SCHEMA VALIDATION TESTS
# ══════════════════════════════════════════════════════════════════════════════

class TestRegisterMovementInAdjustmentReason:
    def test_adjustment_without_description_rejected(self):
        from backend.schemas.cash import RegisterMovementIn

        with pytest.raises(ValidationError, match="motivo"):
            RegisterMovementIn(amount=Decimal("500"), movement_type="adjustment", description=None)

    def test_adjustment_with_blank_description_rejected(self):
        """Triangulación: motivo en blanco (solo espacios) también rechaza."""
        from backend.schemas.cash import RegisterMovementIn

        with pytest.raises(ValidationError, match="motivo"):
            RegisterMovementIn(amount=Decimal("500"), movement_type="adjustment", description="   ")

    def test_adjustment_with_description_accepted_positive(self):
        from backend.schemas.cash import RegisterMovementIn

        payload = RegisterMovementIn(
            amount=Decimal("500"), movement_type="adjustment", description="sobrante"
        )
        assert payload.amount == Decimal("500")

    def test_adjustment_with_description_accepted_negative(self):
        """Triangulación: signo libre — un adjustment negativo (faltante) no
        dispara la validación de signo de egreso (que exige amount<0 para
        purchase_payment/expense/withdrawal, pero adjustment queda afuera de
        ese conjunto)."""
        from backend.schemas.cash import RegisterMovementIn

        payload = RegisterMovementIn(
            amount=Decimal("-300"), movement_type="adjustment", description="faltante"
        )
        assert payload.amount == Decimal("-300")

    def test_sale_sign_validator_preexisting_gap_documented(self):
        """HALLAZGO (fuera de alcance de este change, no se corrige acá):
        `validate_sign_coherence` está declarado sobre `amount`, que en el
        modelo viene ANTES que `movement_type` — en Pydantic v2, `info.data`
        dentro del validador de un campo solo trae los campos YA validados
        (los declarados antes en la clase), así que `movement_type` todavía
        no está disponible cuando corre el validador de `amount` y la
        validación de signo para sale/purchase_payment/expense/advance/
        withdrawal es un no-op silencioso — nunca tuvo test propio (grep
        confirmó cero coincidencias antes de este change). Se documenta acá
        (Strict TDD: reportar fallo preexistente, NO arreglarlo dentro de
        este change) en vez de dejarlo invisible. `validate_adjustment_reason`
        (D4, nuevo en este change) NO tiene este problema: está declarado
        sobre `description`, que va DESPUÉS de `movement_type` en la clase —
        confirmado por los tests de arriba, que si pasan."""
        from backend.schemas.cash import RegisterMovementIn

        # Comportamiento REAL hoy: no rechaza (ver hallazgo). Si algún día se
        # corrige el orden de campos, este test debe empezar a fallar — señal
        # de que hay que actualizarlo, no una regresión de este change.
        payload = RegisterMovementIn(amount=Decimal("-100"), movement_type="sale")
        assert payload.amount == Decimal("-100")

    def test_non_adjustment_without_description_still_valid(self):
        """Triangulación: sale sin description sigue siendo válido — la
        exigencia de motivo es exclusiva de adjustment."""
        from backend.schemas.cash import RegisterMovementIn

        payload = RegisterMovementIn(amount=Decimal("100"), movement_type="sale")
        assert payload.description is None


class TestManualMovementInAdjustmentReason:
    def test_manual_adjustment_without_description_rejected(self):
        from backend.schemas.bank_reconciliation import ManualMovementIn

        with pytest.raises(ValidationError, match="motivo"):
            ManualMovementIn(amount=Decimal("-1200"), movement_type="manual_adjustment", description=None)

    def test_manual_adjustment_with_blank_description_rejected(self):
        from backend.schemas.bank_reconciliation import ManualMovementIn

        with pytest.raises(ValidationError, match="motivo"):
            ManualMovementIn(amount=Decimal("-1200"), movement_type="manual_adjustment", description="  ")

    def test_manual_adjustment_with_description_accepted(self):
        from backend.schemas.bank_reconciliation import ManualMovementIn

        payload = ManualMovementIn(
            amount=Decimal("-1200"), movement_type="manual_adjustment", description="diferencia extracto"
        )
        assert payload.description == "diferencia extracto"

    def test_transfer_in_without_description_still_valid(self):
        """Triangulación: los demás tipos manuales conservan el motivo opcional."""
        from backend.schemas.bank_reconciliation import ManualMovementIn

        payload = ManualMovementIn(amount=Decimal("300"), movement_type="transfer_in")
        assert payload.description is None


# ══════════════════════════════════════════════════════════════════════════════
# REPOSITORY TESTS
# ══════════════════════════════════════════════════════════════════════════════

@pytest.fixture
def session_repo():
    from backend.repositories.cash_session_repository import CashSessionRepository
    conn = AsyncMock()
    return CashSessionRepository(conn), conn


@pytest.fixture
def bank_account_repo():
    from backend.repositories.bank_account_repository import BankAccountRepository
    conn = AsyncMock()
    return BankAccountRepository(conn), conn


class TestCashSessionRepositoryAdjustment:
    @pytest.mark.asyncio
    async def test_register_movement_passes_description(self, session_repo):
        repo, conn = session_repo
        conn.fetchrow = AsyncMock(return_value={"result": json.dumps({"movement_id": MOVEMENT_ID})})

        result = await repo.register_movement(SESSION_ID, 500.0, "adjustment", None, "sobrante")

        args = conn.fetchrow.call_args[0]
        assert "sobrante" in args
        query = conn.fetchrow.call_args[0][0].lower()
        assert "rpc_register_cash_movement" in query
        assert result["movement_id"] == MOVEMENT_ID

    @pytest.mark.asyncio
    async def test_register_movement_description_defaults_to_none(self, session_repo):
        """No-regresión: los llamadores existentes (hot path de venta) que no
        pasan description siguen funcionando — el parámetro tiene default."""
        repo, conn = session_repo
        conn.fetchrow = AsyncMock(return_value={"result": json.dumps({"movement_id": MOVEMENT_ID})})

        result = await repo.register_movement(SESSION_ID, 1200.0, "sale", None)

        args = conn.fetchrow.call_args[0]
        assert None in args[1:]  # description viajó como None
        assert result["movement_id"] == MOVEMENT_ID


class TestCashMovementsByCashboxPage:
    @pytest.mark.asyncio
    async def test_lists_with_default_filters(self, session_repo):
        repo, conn = session_repo
        conn.fetchval = AsyncMock(return_value=1)
        conn.fetch = AsyncMock(return_value=[CASHBOX_MOVEMENTS_PAGE_ROW])

        result = await repo.list_movements_by_cashbox_page(CASHBOX_ID, page=0, size=30)

        assert result["total"] == 1
        assert result["page"] == 0
        assert result["pages"] == 1
        assert result["items"][0]["session_status"] == "open"
        count_query = conn.fetchval.call_args[0][0].lower()
        assert "cash_movements" in count_query
        assert "cash_sessions" in count_query
        assert "cashbox_id" in count_query

    @pytest.mark.asyncio
    async def test_type_filter_pushed_to_server(self, session_repo):
        """Item 10 del molde de Stock, replicado acá: el filtro de tipo va a SQL."""
        repo, conn = session_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_movements_by_cashbox_page(CASHBOX_ID, page=0, size=30, types=["adjustment"])

        select_query = conn.fetch.call_args[0][0].lower()
        assert "movement_type = any(" in select_query
        assert ["adjustment"] in conn.fetch.call_args[0]

    @pytest.mark.asyncio
    async def test_text_search_pushed_to_server(self, session_repo):
        """Corrección del atajo del molde de Stock (D1 del design): el
        buscador va al servidor, no solo sobre las páginas ya cargadas."""
        repo, conn = session_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_movements_by_cashbox_page(CASHBOX_ID, page=0, size=30, q="sobrante")

        select_query = conn.fetch.call_args[0][0].lower()
        assert "description ilike" in select_query

    @pytest.mark.asyncio
    async def test_out_of_range_page_returns_empty_with_consistent_total(self, session_repo):
        """Triangulación: página fuera de rango → items:[] con total/pages
        consistentes, sin 404 (task 5.6)."""
        repo, conn = session_repo
        conn.fetchval = AsyncMock(return_value=1)
        conn.fetch = AsyncMock(return_value=[])

        result = await repo.list_movements_by_cashbox_page(CASHBOX_ID, page=99, size=30)

        assert result["items"] == []
        assert result["total"] == 1
        assert result["pages"] == 1

    @pytest.mark.asyncio
    async def test_date_range_filter_pushed_to_server(self, session_repo):
        repo, conn = session_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_movements_by_cashbox_page(
            CASHBOX_ID, page=0, size=30,
            date_from="2026-08-01", date_to="2026-08-31",
        )

        select_query = conn.fetch.call_args[0][0].lower()
        assert "created_at::date >=" in select_query
        assert "created_at::date <=" in select_query


class TestBankAccountMovementsPage:
    @pytest.mark.asyncio
    async def test_lists_with_default_filters(self, bank_account_repo):
        repo, conn = bank_account_repo
        conn.fetchval = AsyncMock(return_value=1)
        conn.fetch = AsyncMock(return_value=[BANK_MOVEMENT_ROW])

        result = await repo.list_movements_page(BANK_ACCOUNT_ID, page=0, size=30)

        assert result["total"] == 1
        assert result["items"][0]["reconciliation_status"] == "unreconciled"

    @pytest.mark.asyncio
    async def test_status_filter_pushed_to_server(self, bank_account_repo):
        repo, conn = bank_account_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_movements_page(BANK_ACCOUNT_ID, page=0, size=30, status="unreconciled")

        select_query = conn.fetch.call_args[0][0].lower()
        assert "reconciliation_status =" in select_query
        assert "unreconciled" in conn.fetch.call_args[0]

    @pytest.mark.asyncio
    async def test_order_is_value_date_then_created_at_desc(self, bank_account_repo):
        repo, conn = bank_account_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_movements_page(BANK_ACCOUNT_ID, page=0, size=30)

        select_query = conn.fetch.call_args[0][0].lower()
        assert "order by bm.value_date desc, bm.created_at desc" in select_query


# ══════════════════════════════════════════════════════════════════════════════
# SERVICE / ENDPOINT TESTS
# ══════════════════════════════════════════════════════════════════════════════

class TestAdjustmentEndpoints:
    """Tests de integración HTTP — mockean DB (pool), verifican HTTP status y body."""

    async def test_register_cash_adjustment_with_reason_returns_200(self, async_client, mock_pool):
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(return_value={"result": json.dumps({"movement_id": MOVEMENT_ID})})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/sessions/{SESSION_ID}/movements",
                json={"amount": 500.0, "movement_type": "adjustment", "description": "sobrante detectado"},
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 200
        assert "movement_id" in resp.json()

    async def test_register_cash_adjustment_without_reason_returns_422(self, async_client, mock_pool):
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/sessions/{SESSION_ID}/movements",
                json={"amount": 500.0, "movement_type": "adjustment"},
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 422
        body = resp.json()
        assert body["field"] == "description"
        # ninguna llamada a la DB — el rechazo es de Pydantic, antes de tocar la RPC
        conn.fetchrow.assert_not_called()

    async def test_register_cash_adjustment_member_returns_403(self, async_client, mock_pool):
        """Triangulación (task 6.5): un usuario de sólo lectura no puede
        ajustar — mismo guard que cualquier otro movimiento (register_movement
        reusado, task 6.2)."""
        pool, conn = mock_pool
        member_token = make_token({"role": "member"})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/sessions/{SESSION_ID}/movements",
                json={"amount": 500.0, "movement_type": "adjustment", "description": "sobrante"},
                headers={"Authorization": f"Bearer {member_token}"},
            )
        assert resp.status_code == 403

    async def test_list_cashbox_movements_returns_200_envelope(self, async_client, mock_pool):
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetchval = AsyncMock(return_value=1)
        conn.fetch = AsyncMock(return_value=[CASHBOX_MOVEMENTS_PAGE_ROW])

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                f"/cashboxes/{CASHBOX_ID}/movements",
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 200
        body = resp.json()
        assert set(body.keys()) == {"items", "total", "page", "pages"}
        assert body["total"] == 1
        assert body["items"][0]["session_status"] == "open"

    async def test_list_cashbox_movements_member_allowed_read(self, async_client, mock_pool):
        """Triangulación: la lectura del historial NO tiene el guard de
        rol — solo la escritura del ajuste lo tiene."""
        pool, conn = mock_pool
        member_token = make_token({"role": "member"})
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                f"/cashboxes/{CASHBOX_ID}/movements",
                headers={"Authorization": f"Bearer {member_token}"},
            )
        assert resp.status_code == 200

    async def test_register_bank_adjustment_without_reason_returns_422(self, async_client, mock_pool):
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/bank-accounts/{BANK_ACCOUNT_ID}/movements",
                json={"amount": -1200.0, "movement_type": "manual_adjustment"},
                headers={
                    "Authorization": f"Bearer {owner_token}",
                    "Idempotency-Key": "test-adj-1",
                },
            )
        assert resp.status_code == 422
        assert resp.json()["field"] == "description"
        conn.fetchrow.assert_not_called()

    async def test_register_bank_adjustment_with_reason_returns_200(self, async_client, mock_pool):
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(
            return_value={
                "result": json.dumps(
                    {"movement_id": MOVEMENT_ID, "balance_after": 8800.0, "replayed": False, "operation_id": MOVEMENT_ID}
                )
            }
        )

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/bank-accounts/{BANK_ACCOUNT_ID}/movements",
                json={"amount": -1200.0, "movement_type": "manual_adjustment", "description": "diferencia extracto"},
                headers={
                    "Authorization": f"Bearer {owner_token}",
                    "Idempotency-Key": "test-adj-2",
                },
            )
        assert resp.status_code == 200

    async def test_list_bank_account_movements_returns_200_envelope(self, async_client, mock_pool):
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetchval = AsyncMock(return_value=1)
        conn.fetch = AsyncMock(return_value=[BANK_MOVEMENT_ROW])

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                f"/bank-accounts/{BANK_ACCOUNT_ID}/movements",
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 200
        body = resp.json()
        assert set(body.keys()) == {"items", "total", "page", "pages"}
        assert body["items"][0]["reconciliation_status"] == "unreconciled"

    async def test_close_session_returns_adjustments_fields(self, async_client, mock_pool):
        """No-regresión + contrato nuevo: CloseSessionOut expone
        adjustments_total y difference_before_adjustments (D5)."""
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(
            return_value={
                "result": json.dumps(
                    {
                        "session_id": SESSION_ID, "status": "closed",
                        "opening_balance": 900.0, "expected_balance": 1000.0,
                        "counted_balance": 1000.0, "difference": 0.0,
                        "closing_balance": 1000.0,
                        "adjustments_total": 100.0,
                        "difference_before_adjustments": 100.0,
                    }
                )
            }
        )

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/sessions/{SESSION_ID}/close",
                json={"counted_balance": 1000.0},
                headers={
                    "Authorization": f"Bearer {owner_token}",
                    "Idempotency-Key": "close-adj-1",
                },
            )
        assert resp.status_code == 200
        body = resp.json()
        assert float(body["adjustments_total"]) == 100.0
        assert float(body["difference_before_adjustments"]) == 100.0

    async def test_bank_movement_p0413_maps_to_422(self, async_client, mock_pool):
        """DB rechaza con P0413 (camino que no pasa por el field_validator de
        Pydantic — p. ej. un futuro caller que lo evada) → HTTP 422 con
        field=description."""
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})

        err = asyncpg.exceptions.RaiseError("adjustment_reason_required")
        err.sqlstate = "P0413"
        conn.fetchrow = AsyncMock(side_effect=err)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/bank-accounts/{BANK_ACCOUNT_ID}/movements",
                json={"amount": -100.0, "movement_type": "manual_adjustment", "description": "x"},
                headers={
                    "Authorization": f"Bearer {owner_token}",
                    "Idempotency-Key": "test-p0413",
                },
            )
        assert resp.status_code == 422
        assert resp.json()["field"] == "description"


class TestErrorsP0413Mapping:
    def test_p0413_status_and_field(self):
        from backend.core.errors import _BUSINESS_ERRCODE_STATUS, _FIELD_BY_ERRCODE

        assert _BUSINESS_ERRCODE_STATUS["P0413"] == 422
        assert _FIELD_BY_ERRCODE["P0413"] == "description"
