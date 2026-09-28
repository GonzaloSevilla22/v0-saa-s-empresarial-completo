"""
balanza-etiquetas-pos — grupo 3: configuración de la balanza (`scale_settings`)
en 3 capas (tasks 3.1 RED, 3.2 GREEN).

Criterio de aceptación: spec `scale-label-integration`, requirements
"Configuración de la balanza por cuenta" y "Validación del formato de
etiqueta" (reglas D4 del design).

El esquema D4 está duplicado deliberadamente en dos lenguajes (Pydantic acá,
zod en `frontend/lib/scale-layout.ts`); el contrato lo sostienen los casos
compartidos de `backend/tests/fixtures/scale_layout_cases.json`, que este
archivo LEE (no los copia) y que vitest lee también.

Run: python -m pytest backend/tests/test_scale_settings.py -q -p no:cacheprovider
"""
from __future__ import annotations

import copy
import json
from pathlib import Path
from unittest.mock import AsyncMock, patch

import pytest
from pydantic import ValidationError

from backend.tests.conftest import TEST_ACCOUNT_ID, TEST_USER_ID, account_roles_fetchval, make_token

CASES_FILE = Path(__file__).parent / "fixtures" / "scale_layout_cases.json"
_CASES = json.loads(CASES_FILE.read_text(encoding="utf-8"))["cases"]

WEIGHED_FACTORY = {
    "kind": "weighed", "enabled": True,
    "segments": [
        {"field": "fixed", "digits": 2, "value": "20"},
        {"field": "plu", "digits": 4},
        {"field": "amount", "digits": 6, "decimals": 2},
    ],
}
UNIT_FACTORY = {
    "kind": "unit", "enabled": True,
    "segments": [
        {"field": "fixed", "digits": 2, "value": "21"},
        {"field": "plu", "digits": 4},
        {"field": "amount", "digits": 6, "decimals": 2},
    ],
}
MULTI_FACTORY = {
    "kind": "multi", "enabled": True,
    "segments": [
        {"field": "fixed", "digits": 2, "value": "22"},
        {"field": "ignored", "digits": 2},
        {"field": "ignored", "digits": 8},
    ],
}
VALID_SETTINGS = {"enabled": True, "layouts": [WEIGHED_FACTORY, UNIT_FACTORY, MULTI_FACTORY]}

STORED_ROW = {
    "account_id": str(TEST_ACCOUNT_ID),
    "enabled": True,
    "layouts": json.dumps(VALID_SETTINGS["layouts"]),
    "updated_at": "2026-09-28T12:00:00+00:00",
    "updated_by": TEST_USER_ID,
}


def _token(role: str) -> str:
    return make_token({"role": "user", "app_metadata": {"account_role": role}})


def _upsert_call(conn):
    for call in conn.fetchrow.call_args_list:
        if "INSERT INTO scale_settings" in call.args[0] or "INSERT INTO public.scale_settings" in call.args[0]:
            return call
    return None


# ── Esquema D4: casos compartidos con vitest ────────────────────────────────

def _error_code(exc: ValidationError) -> str:
    return exc.errors()[0]["ctx"]["error_code"]


class TestSharedLayoutCases:
    def test_fixture_has_cases(self):
        assert len(_CASES) >= 10

    @pytest.mark.parametrize("case", _CASES, ids=[c["name"] for c in _CASES])
    def test_case_matches_contract(self, case):
        from backend.schemas.scale_settings import ScaleSettingsIn

        if case["valid"]:
            ScaleSettingsIn.model_validate(case["settings"])
        else:
            with pytest.raises(ValidationError) as info:
                ScaleSettingsIn.model_validate(case["settings"])
            # Código de error interno: coincide con el del fixture (descriptivo).
            assert _error_code(info.value) == case["error_code"]


class TestLayoutRulesD4:
    def _with_weighed(self, segments, **extra):
        from backend.schemas.scale_settings import ScaleSettingsIn

        settings = copy.deepcopy(VALID_SETTINGS)
        settings["layouts"][0] = {"kind": "weighed", "enabled": True, "segments": segments, **extra}
        return ScaleSettingsIn.model_validate(settings)

    def test_factory_is_valid(self):
        from backend.schemas.scale_settings import ScaleSettingsIn

        parsed = ScaleSettingsIn.model_validate(VALID_SETTINGS)
        assert [layout.kind for layout in parsed.layouts] == ["weighed", "unit", "multi"]

    def test_zero_digit_ignored_field_is_allowed(self):
        self._with_weighed([
            {"field": "fixed", "digits": 2, "value": "20"},
            {"field": "plu", "digits": 4},
            {"field": "amount", "digits": 6, "decimals": 2},
            {"field": "ignored", "digits": 0},
        ])

    def test_amount_before_plu_is_allowed(self):
        """La balanza deja elegir el orden de los campos (pág. 135)."""
        self._with_weighed([
            {"field": "fixed", "digits": 2, "value": "20"},
            {"field": "amount", "digits": 6, "decimals": 2},
            {"field": "plu", "digits": 4},
        ])

    def test_more_than_four_segments_rejected(self):
        with pytest.raises(ValidationError):
            self._with_weighed([
                {"field": "fixed", "digits": 2, "value": "20"},
                {"field": "plu", "digits": 2},
                {"field": "ignored", "digits": 2},
                {"field": "amount", "digits": 4, "decimals": 2},
                {"field": "ignored", "digits": 2},
            ])

    def test_value_length_must_match_digits(self):
        with pytest.raises(ValidationError) as info:
            self._with_weighed([
                {"field": "fixed", "digits": 2, "value": "2"},
                {"field": "plu", "digits": 4},
                {"field": "amount", "digits": 6, "decimals": 2},
            ])
        assert _error_code(info.value) == "header_length_invalid"

    def test_non_numeric_header_rejected(self):
        with pytest.raises(ValidationError):
            self._with_weighed([
                {"field": "fixed", "digits": 2, "value": "2A"},
                {"field": "plu", "digits": 4},
                {"field": "amount", "digits": 6, "decimals": 2},
            ])

    def test_weighed_quantity_with_three_decimals_is_valid(self):
        self._with_weighed([
            {"field": "fixed", "digits": 2, "value": "20"},
            {"field": "plu", "digits": 4},
            {"field": "quantity", "digits": 6, "decimals": 3},
        ])

    def test_multi_with_plu_rejected(self):
        from backend.schemas.scale_settings import ScaleSettingsIn

        settings = copy.deepcopy(VALID_SETTINGS)
        settings["layouts"][2]["segments"] = [
            {"field": "fixed", "digits": 2, "value": "22"},
            {"field": "plu", "digits": 4},
            {"field": "ignored", "digits": 6},
        ]
        with pytest.raises(ValidationError):
            ScaleSettingsIn.model_validate(settings)

    def test_same_header_twice_is_a_prefix_conflict(self):
        from backend.schemas.scale_settings import ScaleSettingsIn

        settings = copy.deepcopy(VALID_SETTINGS)
        settings["layouts"][1]["segments"][0]["value"] = "20"
        with pytest.raises(ValidationError) as info:
            ScaleSettingsIn.model_validate(settings)
        assert _error_code(info.value) == "header_prefix_conflict"

    def test_layouts_must_be_three_in_order(self):
        from backend.schemas.scale_settings import ScaleSettingsIn

        with pytest.raises(ValidationError):
            ScaleSettingsIn.model_validate({"enabled": True, "layouts": [WEIGHED_FACTORY, UNIT_FACTORY]})
        with pytest.raises(ValidationError):
            ScaleSettingsIn.model_validate({"enabled": True, "layouts": [UNIT_FACTORY, WEIGHED_FACTORY, MULTI_FACTORY]})

    def test_factory_constant_is_disabled_and_valid(self):
        from backend.schemas.scale_settings import FACTORY_SCALE_SETTINGS, ScaleSettingsIn

        assert FACTORY_SCALE_SETTINGS["enabled"] is False
        parsed = ScaleSettingsIn.model_validate(FACTORY_SCALE_SETTINGS)
        weighed = parsed.layouts[0]
        assert [(s.field, s.digits, s.value) for s in weighed.segments] == [
            ("fixed", 2, "20"), ("plu", 4, None), ("amount", 6, None),
        ]
        assert weighed.segments[2].decimals == 2
        assert parsed.layouts[1].segments[0].value == "21"
        assert parsed.layouts[2].segments[0].value == "22"


# ── Repository ──────────────────────────────────────────────────────────────

class TestScaleSettingsRepository:
    async def test_get_filters_by_account(self):
        from backend.repositories.scale_settings_repository import ScaleSettingsRepository

        conn = AsyncMock()
        conn.fetchrow = AsyncMock(return_value=None)
        repo = ScaleSettingsRepository(conn)

        assert await repo.get(str(TEST_ACCOUNT_ID)) is None
        sql, *args = conn.fetchrow.call_args.args
        assert "FROM scale_settings" in sql and "account_id = $1" in sql
        assert args == [str(TEST_ACCOUNT_ID)]

    async def test_upsert_on_conflict_filtered_by_account(self):
        from backend.repositories.scale_settings_repository import ScaleSettingsRepository

        conn = AsyncMock()
        conn.fetchrow = AsyncMock(return_value=STORED_ROW)
        repo = ScaleSettingsRepository(conn)

        row = await repo.upsert(str(TEST_ACCOUNT_ID), True, VALID_SETTINGS["layouts"], TEST_USER_ID)

        sql, *args = conn.fetchrow.call_args.args
        assert "INSERT INTO scale_settings" in sql
        assert "ON CONFLICT (account_id)" in sql
        assert "WHERE scale_settings.account_id = $1" in sql
        assert args[0] == str(TEST_ACCOUNT_ID)
        assert args[1] is True
        assert json.loads(args[2]) == VALID_SETTINGS["layouts"]
        assert args[3] == TEST_USER_ID
        assert row["enabled"] is True
        assert isinstance(row["layouts"], list)


# ── Router + service ────────────────────────────────────────────────────────

class TestGetScaleSettings:
    async def test_without_row_returns_factory_disabled(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=None)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get("/scale-settings", headers={"Authorization": f"Bearer {_token('seller')}"})
        assert resp.status_code == 200
        body = resp.json()
        assert body["enabled"] is False
        assert body["is_default"] is True
        assert [layout["kind"] for layout in body["layouts"]] == ["weighed", "unit", "multi"]
        weighed = body["layouts"][0]["segments"]
        # Sin claves nulas: `value`/`decimals` son opcionales en el contrato.
        assert weighed[0] == {"field": "fixed", "digits": 2, "value": "20"}
        assert "updated_at" not in body
        assert weighed[1]["field"] == "plu" and weighed[1]["digits"] == 4
        assert weighed[2]["field"] == "amount" and weighed[2]["digits"] == 6 and weighed[2]["decimals"] == 2

    async def test_with_row_returns_it(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=STORED_ROW)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get("/scale-settings", headers={"Authorization": f"Bearer {_token('member')}"})
        assert resp.status_code == 200
        body = resp.json()
        assert body["enabled"] is True
        assert body["is_default"] is False
        assert body["layouts"][1]["segments"][0]["value"] == "21"
        sql, *args = conn.fetchrow.call_args.args
        assert args == [str(TEST_ACCOUNT_ID)]


class TestPutScaleSettings:
    async def test_owner_upserts_filtered_by_account(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = account_roles_fetchval(["owner"])
        conn.fetchrow = AsyncMock(return_value=STORED_ROW)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                "/scale-settings", json=VALID_SETTINGS, headers={"Authorization": f"Bearer {_token('owner')}"},
            )
        assert resp.status_code == 200
        call = _upsert_call(conn)
        assert call is not None
        assert call.args[1] == str(TEST_ACCOUNT_ID)
        assert json.loads(call.args[3]) == VALID_SETTINGS["layouts"]
        assert resp.json()["enabled"] is True

    async def test_admin_can_save(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = account_roles_fetchval(["admin"])
        conn.fetchrow = AsyncMock(return_value=STORED_ROW)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                "/scale-settings", json=VALID_SETTINGS, headers={"Authorization": f"Bearer {_token('admin')}"},
            )
        assert resp.status_code == 200

    @pytest.mark.parametrize("role", ["seller", "member"])
    async def test_non_owner_is_403_without_writing(self, async_client, mock_pool, role):
        pool, conn = mock_pool
        conn.fetchval = account_roles_fetchval([role])
        conn.fetchrow = AsyncMock(return_value=STORED_ROW)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                "/scale-settings", json=VALID_SETTINGS, headers={"Authorization": f"Bearer {_token(role)}"},
            )
        assert resp.status_code == 403
        assert _upsert_call(conn) is None

    async def test_token_says_owner_but_db_says_seller_is_403(self, async_client, mock_pool):
        """CAN_CONFIGURE es capacidad sensible: la base es la autoridad."""
        pool, conn = mock_pool
        conn.fetchval = account_roles_fetchval(["seller"])
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                "/scale-settings", json=VALID_SETTINGS, headers={"Authorization": f"Bearer {_token('owner')}"},
            )
        assert resp.status_code == 403
        assert _upsert_call(conn) is None

    async def test_invalid_layout_is_422_naming_format_and_field(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = account_roles_fetchval(["owner"])
        settings = copy.deepcopy(VALID_SETTINGS)
        settings["layouts"][0]["segments"][2]["digits"] = 5  # 2 + 4 + 5 = 11
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                "/scale-settings", json=settings, headers={"Authorization": f"Bearer {_token('owner')}"},
            )
        assert resp.status_code == 422
        body = resp.json()
        assert "12" in body["detail"]
        assert "Venta por peso" in body["detail"]
        assert body["code"] == "scale_layout_invalid"
        assert body["field"] == "layouts"
        assert _upsert_call(conn) is None

    async def test_invalid_header_is_422_naming_field_a(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = account_roles_fetchval(["owner"])
        settings = copy.deepcopy(VALID_SETTINGS)
        settings["layouts"][1]["segments"][0]["value"] = "77"
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                "/scale-settings", json=settings, headers={"Authorization": f"Bearer {_token('owner')}"},
            )
        assert resp.status_code == 422
        detail = resp.json()["detail"]
        assert "Venta por unidad" in detail and "campo A" in detail
