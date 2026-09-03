"""
productos-categorias-sku — ProductCategoryService TDD tests (tasks 8.3 RED, 8.6).

Espejo de test_payment_method_service.py: create/update/deactivate/delete
gatean contra require_account_role (TENANT owner/admin); list es abierto a
cualquier miembro. Repository mockeado.
"""
from __future__ import annotations

from unittest.mock import AsyncMock

import asyncpg
import pytest
from fastapi import HTTPException

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
CAT_ID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
USER_ID = "11111111-1111-1111-1111-111111111111"

CAT_ROW = {
    "id": CAT_ID,
    "account_id": ACCOUNT_ID,
    "name": "Ropa",
    "is_active": True,
    "sort_order": 2,
    "created_at": "2026-09-03T10:00:00+00:00",
}


def _make_auth(account_role: str | None) -> dict:
    return {"user_id": USER_ID, "role": "user", "account_role": account_role, "plan": "pro"}


def _make_conn(fallback_role: object = "__unset__") -> AsyncMock:
    conn = AsyncMock()
    if fallback_role != "__unset__":
        conn.fetchval = AsyncMock(return_value=fallback_role)
    return conn


_SENTINEL = object()


def _make_repo(
    *,
    list_result=_SENTINEL,
    create_result=_SENTINEL,
    update_result=_SENTINEL,
    deactivate_result=_SENTINEL,
    soft_delete_result=_SENTINEL,
):
    repo = AsyncMock()
    repo.list_by_account = AsyncMock(return_value=[CAT_ROW] if list_result is _SENTINEL else list_result)
    repo.create = AsyncMock(return_value=CAT_ROW if create_result is _SENTINEL else create_result)
    repo.update = AsyncMock(return_value=CAT_ROW if update_result is _SENTINEL else update_result)
    repo.deactivate = AsyncMock(
        return_value={**CAT_ROW, "is_active": False} if deactivate_result is _SENTINEL else deactivate_result
    )
    repo.soft_delete = AsyncMock(return_value=True if soft_delete_result is _SENTINEL else soft_delete_result)
    return repo


# ── normalización del nombre (task 5.8: UN helper, espejo Python del SQL) ────

class TestNormalizeCategoryName:
    def test_trims_and_collapses_internal_spaces(self):
        from backend.services.product_categories import normalize_category_name

        assert normalize_category_name("  Ropa   de   trabajo ") == "Ropa de trabajo"

    def test_blank_becomes_none(self):
        from backend.services.product_categories import normalize_category_name

        assert normalize_category_name("   ") is None
        assert normalize_category_name(None) is None


# ── list: cualquier miembro ───────────────────────────────────────────────────

class TestProductCategoryServiceList:
    @pytest.mark.asyncio
    async def test_list_permitted_for_member(self):
        from backend.services.product_categories import list_product_categories

        repo = _make_repo()
        result = await list_product_categories(repo, _make_auth("member"), ACCOUNT_ID, active_only=True)

        assert isinstance(result, list)
        repo.list_by_account.assert_awaited_once_with(ACCOUNT_ID, active_only=True)


# ── create: owner/admin ───────────────────────────────────────────────────────

class TestProductCategoryServiceCreate:
    @pytest.mark.asyncio
    async def test_create_member_raises_403_without_touching_repo(self):
        from backend.services.product_categories import create_product_category

        repo = _make_repo()
        with pytest.raises(HTTPException) as exc_info:
            await create_product_category(repo, _make_auth("member"), ACCOUNT_ID, name="Ferretería", sort_order=None, conn=_make_conn())

        assert exc_info.value.status_code == 403
        repo.create.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_create_owner_ok_and_normalizes_name(self):
        from backend.services.product_categories import create_product_category

        repo = _make_repo(create_result={**CAT_ROW, "name": "Ferretería"})
        result = await create_product_category(
            repo, _make_auth("owner"), ACCOUNT_ID, name="  Ferretería  ", sort_order=None, conn=_make_conn()
        )

        assert result["name"] == "Ferretería"
        repo.create.assert_awaited_once_with(ACCOUNT_ID, name="Ferretería", sort_order=None)

    @pytest.mark.asyncio
    async def test_create_admin_ok(self):
        from backend.services.product_categories import create_product_category

        repo = _make_repo()
        result = await create_product_category(repo, _make_auth("admin"), ACCOUNT_ID, name="Ropa", sort_order=1, conn=_make_conn())

        assert result is not None

    @pytest.mark.asyncio
    async def test_create_blank_name_raises_422(self):
        from backend.services.product_categories import create_product_category

        repo = _make_repo()
        with pytest.raises(HTTPException) as exc_info:
            await create_product_category(repo, _make_auth("owner"), ACCOUNT_ID, name="   ", sort_order=None, conn=_make_conn())

        assert exc_info.value.status_code == 422
        repo.create.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_create_duplicate_name_raises_409_readable(self):
        """El unique de la DB es la fuente de verdad; el service sólo traduce
        el 23505 a un 409 legible que nombra la categoría."""
        from backend.services.product_categories import create_product_category

        repo = _make_repo()
        repo.create = AsyncMock(side_effect=asyncpg.UniqueViolationError("duplicate key"))

        with pytest.raises(HTTPException) as exc_info:
            await create_product_category(repo, _make_auth("owner"), ACCOUNT_ID, name="ropa", sort_order=None, conn=_make_conn())

        assert exc_info.value.status_code == 409
        assert "ropa" in exc_info.value.detail.lower()

    @pytest.mark.asyncio
    async def test_create_claim_absent_falls_back_to_db_owner(self):
        from backend.services.product_categories import create_product_category

        repo = _make_repo()
        conn = _make_conn(fallback_role="owner")
        result = await create_product_category(repo, _make_auth(None), ACCOUNT_ID, name="Ropa", sort_order=None, conn=conn)

        assert result is not None
        conn.fetchval.assert_awaited_once()


# ── update: owner/admin ───────────────────────────────────────────────────────

class TestProductCategoryServiceUpdate:
    @pytest.mark.asyncio
    async def test_update_member_raises_403(self):
        from backend.services.product_categories import update_product_category

        repo = _make_repo()
        with pytest.raises(HTTPException) as exc_info:
            await update_product_category(repo, _make_auth("member"), ACCOUNT_ID, CAT_ID, name="X", sort_order=None, is_active=None, conn=_make_conn())

        assert exc_info.value.status_code == 403
        repo.update.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_update_rename_normalizes(self):
        from backend.services.product_categories import update_product_category

        repo = _make_repo(update_result={**CAT_ROW, "name": "Indumentaria"})
        result = await update_product_category(
            repo, _make_auth("owner"), ACCOUNT_ID, CAT_ID, name=" Indumentaria ", sort_order=None, is_active=None, conn=_make_conn()
        )

        assert result["name"] == "Indumentaria"
        repo.update.assert_awaited_once_with(CAT_ID, ACCOUNT_ID, name="Indumentaria", sort_order=None, is_active=None)

    @pytest.mark.asyncio
    async def test_update_blank_name_raises_422(self):
        from backend.services.product_categories import update_product_category

        repo = _make_repo()
        with pytest.raises(HTTPException) as exc_info:
            await update_product_category(repo, _make_auth("owner"), ACCOUNT_ID, CAT_ID, name="  ", sort_order=None, is_active=None, conn=_make_conn())

        assert exc_info.value.status_code == 422

    @pytest.mark.asyncio
    async def test_update_reactivate(self):
        from backend.services.product_categories import update_product_category

        repo = _make_repo(update_result={**CAT_ROW, "is_active": True})
        result = await update_product_category(
            repo, _make_auth("admin"), ACCOUNT_ID, CAT_ID, name=None, sort_order=None, is_active=True, conn=_make_conn()
        )

        assert result["is_active"] is True
        repo.update.assert_awaited_once_with(CAT_ID, ACCOUNT_ID, name=None, sort_order=None, is_active=True)

    @pytest.mark.asyncio
    async def test_update_not_found_or_other_account_raises_404(self):
        """Categoría de otra cuenta → el repo (scoped) devuelve None → 404
        sin revelar si existe en otra cuenta."""
        from backend.services.product_categories import update_product_category

        repo = _make_repo(update_result=None)
        with pytest.raises(HTTPException) as exc_info:
            await update_product_category(repo, _make_auth("owner"), ACCOUNT_ID, "other-tenant-id", name="X", sort_order=None, is_active=None, conn=_make_conn())

        assert exc_info.value.status_code == 404
        assert "otra cuenta" not in exc_info.value.detail.lower()

    @pytest.mark.asyncio
    async def test_update_duplicate_name_raises_409(self):
        from backend.services.product_categories import update_product_category

        repo = _make_repo()
        repo.update = AsyncMock(side_effect=asyncpg.UniqueViolationError("duplicate key"))
        with pytest.raises(HTTPException) as exc_info:
            await update_product_category(repo, _make_auth("owner"), ACCOUNT_ID, CAT_ID, name="Hogar", sort_order=None, is_active=None, conn=_make_conn())

        assert exc_info.value.status_code == 409


# ── deactivate / delete: owner/admin ──────────────────────────────────────────

class TestProductCategoryServiceDeactivateDelete:
    @pytest.mark.asyncio
    async def test_deactivate_member_raises_403(self):
        from backend.services.product_categories import deactivate_product_category

        repo = _make_repo()
        with pytest.raises(HTTPException) as exc_info:
            await deactivate_product_category(repo, _make_auth("member"), ACCOUNT_ID, CAT_ID, conn=_make_conn())

        assert exc_info.value.status_code == 403

    @pytest.mark.asyncio
    async def test_deactivate_owner_ok(self):
        from backend.services.product_categories import deactivate_product_category

        repo = _make_repo()
        result = await deactivate_product_category(repo, _make_auth("owner"), ACCOUNT_ID, CAT_ID, conn=_make_conn())

        assert result["is_active"] is False
        repo.deactivate.assert_awaited_once_with(CAT_ID, ACCOUNT_ID)

    @pytest.mark.asyncio
    async def test_deactivate_not_found_raises_404(self):
        from backend.services.product_categories import deactivate_product_category

        repo = _make_repo(deactivate_result=None)
        with pytest.raises(HTTPException) as exc_info:
            await deactivate_product_category(repo, _make_auth("admin"), ACCOUNT_ID, "nonexistent", conn=_make_conn())

        assert exc_info.value.status_code == 404

    @pytest.mark.asyncio
    async def test_soft_delete_owner_records_author(self):
        """soft-delete-policy: la baja como maestro registra deleted_at/deleted_by
        vía el helper centralizado sobre la tabla product_categories."""
        from backend.services.product_categories import delete_product_category

        repo = _make_repo()
        await delete_product_category(repo, _make_auth("owner"), ACCOUNT_ID, CAT_ID, conn=_make_conn())

        repo.soft_delete.assert_awaited_once_with("product_categories", CAT_ID, ACCOUNT_ID, USER_ID)

    @pytest.mark.asyncio
    async def test_soft_delete_not_found_raises_404(self):
        from backend.services.product_categories import delete_product_category

        repo = _make_repo(soft_delete_result=False)
        with pytest.raises(HTTPException) as exc_info:
            await delete_product_category(repo, _make_auth("owner"), ACCOUNT_ID, "nonexistent", conn=_make_conn())

        assert exc_info.value.status_code == 404

    @pytest.mark.asyncio
    async def test_soft_delete_member_raises_403(self):
        from backend.services.product_categories import delete_product_category

        repo = _make_repo()
        with pytest.raises(HTTPException) as exc_info:
            await delete_product_category(repo, _make_auth("member"), ACCOUNT_ID, CAT_ID, conn=_make_conn())

        assert exc_info.value.status_code == 403
        repo.soft_delete.assert_not_awaited()
