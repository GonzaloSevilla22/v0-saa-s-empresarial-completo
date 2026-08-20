"""
bank-account-crud — Tests TDD (Strict TDD Mode).

Expone el alta de cuentas bancarias (POST /bank-accounts) sobre la RPC ya
existente `rpc_create_bank_account` (bank-account-ledger C1, migración
20260804000002). Sin migraciones nuevas.

Comportamientos cubiertos:
  ── Schema Pydantic (1.1-1.3) ──────────────────────────────────────────────────
  - BankAccountCreate rechaza name vacío/blank y cbu no-22-dígitos
  - BankAccountCreate acepta payload mínimo (name solo) y payload completo
  - currency default 'ARS'; opening_balance negativo rechazado; cbu 22 dígitos OK

  ── Repository (2.1-2.3) ────────────────────────────────────────────────────────
  - create() invoca rpc_create_bank_account con los 7 params en orden
  - re-SELECT por bank_account_id para el shape completo de BankAccountOut
  - cbu=NULL y campos opcionales provistos se pasan correctamente

  ── Service (3.1-3.3) ────────────────────────────────────────────────────────────
  - create_bank_account aplica require_role(["user","admin"]) antes de tocar el repo
  - ERRCODEs de la RPC (P0400/P0401/P0403/P0411) ya mapeados en errors.py

  ── Router (4.1-4.3) ─────────────────────────────────────────────────────────────
  - POST /bank-accounts 200/201 con payload válido; 403 sin permiso; 422 inválido

Run: python -m pytest backend/tests/test_bank_account_crud.py
"""
from __future__ import annotations

import uuid
from decimal import Decimal
from unittest.mock import AsyncMock, patch

import pytest
from fastapi import HTTPException
from pydantic import ValidationError

from backend.tests.conftest import make_token

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
BANK_ACCOUNT_ID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
VALID_CBU = "0" * 22

BANK_ACCOUNT_ROW = {
    "id": BANK_ACCOUNT_ID,
    "account_id": ACCOUNT_ID,
    "name": "Cuenta corriente Galicia",
    "bank_name": "Banco Galicia",
    "cbu": VALID_CBU,
    "alias": "galicia.cuenta",
    "currency": "ARS",
    "is_active": True,
}


# ═══════════════════════════════════════════════════════════════════════════════
# 1. Schema Pydantic v2 — BankAccountCreate (1.1 RED / 1.2 GREEN / 1.3 TRIANGULATE)
# ═══════════════════════════════════════════════════════════════════════════════

class TestBankAccountCreateSchema:
    def test_accepts_minimal_payload_name_only(self):
        """Payload mínimo: solo name (requerido) — el resto usa sus defaults."""
        from backend.schemas.bank_accounts import BankAccountCreate

        payload = BankAccountCreate(name="Cuenta Ahorro")

        assert payload.name == "Cuenta Ahorro"
        assert payload.currency == "ARS"
        assert payload.opening_balance == Decimal("0")
        assert payload.cbu is None
        assert payload.bank_name is None
        assert payload.alias is None
        assert payload.opening_date is None

    def test_accepts_full_payload(self):
        """Payload completo con todos los campos opcionales provistos."""
        from backend.schemas.bank_accounts import BankAccountCreate

        payload = BankAccountCreate(
            name="Cuenta corriente Galicia",
            bank_name="Banco Galicia",
            cbu=VALID_CBU,
            alias="galicia.cuenta",
            currency="USD",
            opening_balance=Decimal("10000"),
            opening_date="2026-07-01",
        )

        assert payload.name == "Cuenta corriente Galicia"
        assert payload.bank_name == "Banco Galicia"
        assert payload.cbu == VALID_CBU
        assert payload.alias == "galicia.cuenta"
        assert payload.currency == "USD"
        assert payload.opening_balance == Decimal("10000")
        assert str(payload.opening_date) == "2026-07-01"

    def test_rejects_empty_name(self):
        """name vacío es rechazado por Pydantic (feedback temprano, 422)."""
        from backend.schemas.bank_accounts import BankAccountCreate

        with pytest.raises(ValidationError):
            BankAccountCreate(name="")

    def test_rejects_blank_name(self):
        """name de solo espacios es rechazado (strip antes de min_length)."""
        from backend.schemas.bank_accounts import BankAccountCreate

        with pytest.raises(ValidationError):
            BankAccountCreate(name="   ")

    def test_rejects_cbu_not_22_digits(self):
        """cbu con cantidad de dígitos incorrecta es rechazado."""
        from backend.schemas.bank_accounts import BankAccountCreate

        with pytest.raises(ValidationError):
            BankAccountCreate(name="Cuenta X", cbu="12345")

    # ── 1.3 TRIANGULATE ──────────────────────────────────────────────────────────

    def test_currency_defaults_to_ars_when_omitted(self):
        """TRIANGULATE: currency se omite → default 'ARS'."""
        from backend.schemas.bank_accounts import BankAccountCreate

        payload = BankAccountCreate(name="Cuenta X")

        assert payload.currency == "ARS"

    def test_negative_opening_balance_rejected(self):
        """TRIANGULATE: opening_balance negativo viola ge=0."""
        from backend.schemas.bank_accounts import BankAccountCreate

        with pytest.raises(ValidationError):
            BankAccountCreate(name="Cuenta X", opening_balance=Decimal("-100"))

    def test_valid_22_digit_cbu_accepted(self):
        """TRIANGULATE: cbu de exactamente 22 dígitos numéricos es aceptado."""
        from backend.schemas.bank_accounts import BankAccountCreate

        payload = BankAccountCreate(name="Cuenta X", cbu=VALID_CBU)

        assert payload.cbu == VALID_CBU

    def test_cbu_with_letters_rejected(self):
        """TRIANGULATE: cbu con letras (no numérico) es rechazado."""
        from backend.schemas.bank_accounts import BankAccountCreate

        with pytest.raises(ValidationError):
            BankAccountCreate(name="Cuenta X", cbu="123456789012345678901A"[:22])


# ═══════════════════════════════════════════════════════════════════════════════
# 2. Repository — BankAccountRepository.create (2.1 RED / 2.2 GREEN / 2.3 TRIANGULATE)
# ═══════════════════════════════════════════════════════════════════════════════

@pytest.fixture
def bank_account_repo():
    from backend.repositories.bank_account_repository import BankAccountRepository

    conn = AsyncMock()
    return BankAccountRepository(conn), conn


class TestBankAccountRepositoryCreate:
    @pytest.mark.asyncio
    async def test_create_invokes_rpc_with_7_params_in_order(self, bank_account_repo):
        """create() invoca rpc_create_bank_account posicionalmente con los 7 params."""
        repo, conn = bank_account_repo
        conn.fetchrow = AsyncMock(
            side_effect=[
                {"result": {"bank_account_id": BANK_ACCOUNT_ID}},  # RPC call (jsonb result)
                BANK_ACCOUNT_ROW,  # re-SELECT
            ]
        )

        result = await repo.create(
            name="Cuenta corriente Galicia",
            bank_name="Banco Galicia",
            cbu=VALID_CBU,
            alias="galicia.cuenta",
            currency="ARS",
            opening_balance=Decimal("10000"),
            opening_date=None,
        )

        assert result is not None
        assert result["name"] == "Cuenta corriente Galicia"
        # First call = the RPC invocation
        first_call_sql = conn.fetchrow.call_args_list[0][0][0]
        assert "rpc_create_bank_account" in first_call_sql
        first_call_args = conn.fetchrow.call_args_list[0][0][1:]
        assert first_call_args == (
            "Cuenta corriente Galicia",
            "Banco Galicia",
            VALID_CBU,
            "galicia.cuenta",
            "ARS",
            Decimal("10000"),
            None,
        )

    @pytest.mark.asyncio
    async def test_create_reselects_row_by_id_for_full_shape(self, bank_account_repo):
        """create() hace un re-SELECT por bank_account_id (shape completo de BankAccountOut)."""
        repo, conn = bank_account_repo
        conn.fetchrow = AsyncMock(
            side_effect=[
                {"result": {"bank_account_id": BANK_ACCOUNT_ID}},
                BANK_ACCOUNT_ROW,
            ]
        )

        result = await repo.create(
            name="Cuenta corriente Galicia",
            bank_name=None,
            cbu=None,
            alias=None,
            currency="ARS",
            opening_balance=Decimal("0"),
            opening_date=None,
        )

        assert result["id"] == BANK_ACCOUNT_ID
        # Second call = the re-SELECT
        second_call_sql = conn.fetchrow.call_args_list[1][0][0].upper()
        assert "SELECT" in second_call_sql
        assert "BANK_ACCOUNTS" in second_call_sql
        second_call_args = conn.fetchrow.call_args_list[1][0][1:]
        assert BANK_ACCOUNT_ID in second_call_args

    @pytest.mark.asyncio
    async def test_create_parses_jsonb_string_result(self, bank_account_repo):
        """Regresión prod 2026-08-20: asyncpg SIN type codec entrega el jsonb de la
        RPC como STRING JSON, no como dict. El código tomaba el string entero como
        si fuera el UUID y el re-SELECT explotaba con `invalid UUID ... got 202`.
        El mock replica el comportamiento real de asyncpg (str), no el idealizado."""
        import json as _json

        repo, conn = bank_account_repo
        jsonb_as_string = _json.dumps(
            {
                "name": "Mercado Pago",
                "currency": "ARS",
                "is_active": True,
                "account_id": "c4145451-7eee-46c1-854e-896735e35e25",
                "bank_account_id": BANK_ACCOUNT_ID,
                "opening_balance": 160000,
            }
        )
        conn.fetchrow = AsyncMock(
            side_effect=[
                {"result": jsonb_as_string},  # asyncpg real: jsonb → str
                BANK_ACCOUNT_ROW,
            ]
        )

        result = await repo.create(
            name="Mercado Pago",
            bank_name=None,
            cbu=None,
            alias=None,
            currency="ARS",
            opening_balance=Decimal("160000"),
            opening_date=None,
        )

        assert result is not None
        # El re-SELECT debe recibir el UUID limpio, no el JSON de 202 caracteres
        second_call_args = conn.fetchrow.call_args_list[1][0][1:]
        assert second_call_args == (BANK_ACCOUNT_ID,)

    # ── 2.3 TRIANGULATE ──────────────────────────────────────────────────────────

    @pytest.mark.asyncio
    async def test_create_with_cbu_none_passes_null(self, bank_account_repo):
        """TRIANGULATE: cbu omitido (None) se pasa como NULL a la RPC."""
        repo, conn = bank_account_repo
        conn.fetchrow = AsyncMock(
            side_effect=[
                {"result": {"bank_account_id": BANK_ACCOUNT_ID}},
                {**BANK_ACCOUNT_ROW, "cbu": None},
            ]
        )

        result = await repo.create(
            name="Cuenta sin CBU",
            bank_name=None,
            cbu=None,
            alias=None,
            currency="ARS",
            opening_balance=Decimal("0"),
            opening_date=None,
        )

        first_call_args = conn.fetchrow.call_args_list[0][0][1:]
        assert first_call_args[2] is None  # cbu positional slot
        assert result["cbu"] is None

    @pytest.mark.asyncio
    async def test_create_with_optional_fields_provided(self, bank_account_repo):
        """TRIANGULATE: bank_name/alias/opening_date provistos se pasan correctamente."""
        repo, conn = bank_account_repo
        conn.fetchrow = AsyncMock(
            side_effect=[
                {"result": {"bank_account_id": BANK_ACCOUNT_ID}},
                BANK_ACCOUNT_ROW,
            ]
        )

        await repo.create(
            name="Cuenta corriente Galicia",
            bank_name="Banco Galicia",
            cbu=VALID_CBU,
            alias="galicia.cuenta",
            currency="ARS",
            opening_balance=Decimal("10000"),
            opening_date="2026-07-01",
        )

        first_call_args = conn.fetchrow.call_args_list[0][0][1:]
        assert first_call_args[1] == "Banco Galicia"
        assert first_call_args[3] == "galicia.cuenta"
        assert first_call_args[6] == "2026-07-01"


# ═══════════════════════════════════════════════════════════════════════════════
# 3. Service layer — create_bank_account (3.1 RED / 3.2 GREEN / 3.3 TRIANGULATE)
# ═══════════════════════════════════════════════════════════════════════════════

def _make_auth(role: str) -> dict:
    return {"user_id": "11111111-1111-1111-1111-111111111111", "role": role}


def _make_repo(create_result=None):
    from unittest.mock import AsyncMock as _AsyncMock

    repo = _AsyncMock()
    repo.create = _AsyncMock(return_value=create_result or BANK_ACCOUNT_ROW)
    return repo


class TestCreateBankAccountService:
    @pytest.mark.asyncio
    async def test_no_write_role_raises_guard_before_repo_call(self):
        """Sin rol de escritura, el guard levanta ANTES de llamar al repo."""
        from backend.services.bank_accounts import create_bank_account
        from backend.schemas.bank_accounts import BankAccountCreate

        repo = _make_repo()
        auth = _make_auth("readonly")
        payload = BankAccountCreate(name="Cuenta X")

        with pytest.raises(HTTPException) as exc_info:
            await create_bank_account(repo, auth, payload)

        assert exc_info.value.status_code == 403
        repo.create.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_valid_role_delegates_to_repo(self):
        """Con rol válido (user/admin), delega al repo."""
        from backend.services.bank_accounts import create_bank_account
        from backend.schemas.bank_accounts import BankAccountCreate

        repo = _make_repo()
        auth = _make_auth("user")
        payload = BankAccountCreate(name="Cuenta corriente Galicia")

        result = await create_bank_account(repo, auth, payload)

        assert result["name"] == "Cuenta corriente Galicia"
        repo.create.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_admin_role_delegates_to_repo(self):
        """admin también puede crear."""
        from backend.services.bank_accounts import create_bank_account
        from backend.schemas.bank_accounts import BankAccountCreate

        repo = _make_repo()
        auth = _make_auth("admin")
        payload = BankAccountCreate(name="Cuenta corriente Galicia")

        result = await create_bank_account(repo, auth, payload)

        assert result is not None
        repo.create.assert_awaited_once()

    # ── 3.3 TRIANGULATE: mapeo de ERRCODEs (errors.py ya los mapea) ──────────────

    def test_errcode_p0401_mapped_to_403(self):
        """TRIANGULATE: P0401 (no autorizado) está mapeado a HTTP 403."""
        from backend.core.errors import _BUSINESS_ERRCODE_STATUS

        assert _BUSINESS_ERRCODE_STATUS["P0401"] == 403

    def test_errcode_p0411_mapped_to_422(self):
        """TRIANGULATE: P0411 (CBU inválido) está mapeado a HTTP 422."""
        from backend.core.errors import _BUSINESS_ERRCODE_STATUS

        assert _BUSINESS_ERRCODE_STATUS["P0411"] == 422

    def test_errcode_p0400_mapped_to_422_for_bank_account_create(self):
        """TRIANGULATE: P0400 (name requerido) mapeado a HTTP 422 específicamente
        para POST /bank-accounts (validación de payload), sin tocar el mapeo
        global de P0400 (usado por otras RPCs como bad-request genérico)."""
        from backend.core.errors import BANK_ACCOUNT_CREATE_ERRCODE_STATUS

        assert BANK_ACCOUNT_CREATE_ERRCODE_STATUS["P0400"] == 422

    def test_errcode_p0403_mapped(self):
        """TRIANGULATE: P0403 (sin cuenta activa) está mapeado."""
        from backend.core.errors import _BUSINESS_ERRCODE_STATUS

        assert _BUSINESS_ERRCODE_STATUS["P0403"] == 403


# ═══════════════════════════════════════════════════════════════════════════════
# 4. Router — POST /bank-accounts (4.1 RED / 4.2 GREEN / 4.3 REFACTOR)
# ═══════════════════════════════════════════════════════════════════════════════

class TestCreateBankAccountEndpoint:
    @pytest.mark.asyncio
    async def test_post_valid_payload_returns_2xx(self, async_client, mock_pool):
        """POST /bank-accounts con payload válido devuelve 200/201."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(
            side_effect=[
                {"result": {"bank_account_id": BANK_ACCOUNT_ID}},
                BANK_ACCOUNT_ROW,
            ]
        )
        user_token = make_token({"app_metadata": {"role": "user"}})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/bank-accounts",
                json={"name": "Cuenta corriente Galicia", "bank_name": "Banco Galicia"},
                headers={"Authorization": f"Bearer {user_token}"},
            )

        assert resp.status_code in (200, 201)
        data = resp.json()
        assert data["name"] == "Cuenta corriente Galicia"

    @pytest.mark.asyncio
    async def test_post_without_write_permission_returns_403(self, async_client, mock_pool):
        """Usuario sin rol de escritura → 403, sin insertar fila."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock()
        readonly_token = make_token({"app_metadata": {"role": "readonly"}})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/bank-accounts",
                json={"name": "Cuenta corriente Galicia"},
                headers={"Authorization": f"Bearer {readonly_token}"},
            )

        assert resp.status_code == 403
        conn.fetchrow.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_post_empty_name_returns_422(self, async_client, mock_pool):
        """name vacío → 422 (validación Pydantic, sin tocar la DB)."""
        pool, conn = mock_pool
        user_token = make_token({"app_metadata": {"role": "user"}})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/bank-accounts",
                json={"name": ""},
                headers={"Authorization": f"Bearer {user_token}"},
            )

        assert resp.status_code == 422

    @pytest.mark.asyncio
    async def test_post_invalid_cbu_returns_422(self, async_client, mock_pool):
        """cbu inválido (no 22 dígitos) → 422 (validación Pydantic)."""
        pool, conn = mock_pool
        user_token = make_token({"app_metadata": {"role": "user"}})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/bank-accounts",
                json={"name": "Cuenta X", "cbu": "12345"},
                headers={"Authorization": f"Bearer {user_token}"},
            )

        assert resp.status_code == 422

    # ── 4.3 REFACTOR / TRIANGULATE ────────────────────────────────────────────────

    @pytest.mark.asyncio
    async def test_post_without_cbu_creates_account(self, async_client, mock_pool):
        """POST sin cbu crea la cuenta correctamente con cbu=NULL."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(
            side_effect=[
                {"result": {"bank_account_id": BANK_ACCOUNT_ID}},
                {**BANK_ACCOUNT_ROW, "cbu": None},
            ]
        )
        user_token = make_token({"app_metadata": {"role": "user"}})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/bank-accounts",
                json={"name": "Cuenta sin CBU"},
                headers={"Authorization": f"Bearer {user_token}"},
            )

        assert resp.status_code in (200, 201)
        assert resp.json()["cbu"] is None

    @pytest.mark.asyncio
    async def test_post_unauthenticated_returns_401(self, async_client, mock_pool):
        """Sin token → 401."""
        pool, conn = mock_pool

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/bank-accounts",
                json={"name": "Cuenta X"},
            )

        assert resp.status_code == 401


# ═══════════════════════════════════════════════════════════════════════════════
# v3-soft-delete-policy (5.4): list_active filtra deleted_at; soft delete real
# ═══════════════════════════════════════════════════════════════════════════════

class TestBankAccountSoftDelete:
    @pytest.mark.asyncio
    async def test_list_active_filters_is_active_and_not_deleted(self, bank_account_repo):
        """list_active mantiene is_active=true (baja logica reversible, D1) y
        ahora tambien excluye borrados (deleted_at IS NULL, RN-B1)."""
        repo, conn = bank_account_repo
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_active()

        sql = conn.fetch.call_args.args[0]
        assert "is_active = true" in sql
        assert "deleted_at IS NULL" in sql

    @pytest.mark.asyncio
    async def test_soft_delete_bank_accounts_allowed_and_marks_row(self, bank_account_repo):
        """"bank_accounts" esta en la allowlist — el borrado real es soft
        (deleted_at + deleted_by), distinto de la baja logica is_active."""
        repo, conn = bank_account_repo
        conn.execute = AsyncMock(return_value="UPDATE 1")

        affected = await repo.soft_delete(
            "bank_accounts",
            "55555555-5555-5555-5555-555555555555",
            "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "11111111-1111-1111-1111-111111111111",
        )

        assert affected is True
        sql = conn.execute.call_args.args[0]
        assert "UPDATE bank_accounts" in sql
        assert "deleted_at = now()" in sql
