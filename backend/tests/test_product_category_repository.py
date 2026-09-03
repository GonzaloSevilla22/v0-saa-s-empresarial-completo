"""
productos-categorias-sku — ProductCategoryRepository TDD tests (tasks 8.1 RED, 8.6).

Espejo de test_payment_method_repository.py (sin `kind`). Ningún acceso real a
la DB — el SQL se verifica por call_args sobre un asyncpg mock.
"""
from __future__ import annotations

from unittest.mock import AsyncMock

import pytest

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
CAT_ID = "cccccccc-cccc-cccc-cccc-cccccccccccc"

CAT_ROW_ACTIVE = {
    "id": CAT_ID,
    "account_id": ACCOUNT_ID,
    "name": "Ropa",
    "is_active": True,
    "sort_order": 2,
    "created_at": "2026-09-03T10:00:00+00:00",
}

CAT_ROW_INACTIVE = {
    "id": "dddddddd-dddd-dddd-dddd-dddddddddddd",
    "account_id": ACCOUNT_ID,
    "name": "Salud",
    "is_active": False,
    "sort_order": 5,
    "created_at": "2026-09-01T08:00:00+00:00",
}


@pytest.fixture
def category_repo():
    from backend.repositories.product_category_repository import ProductCategoryRepository

    conn = AsyncMock()
    return ProductCategoryRepository(conn), conn


# ── 8.1 RED: list_by_account ──────────────────────────────────────────────────

class TestProductCategoryRepositoryList:
    @pytest.mark.asyncio
    async def test_list_active_only_by_default(self, category_repo):
        repo, conn = category_repo
        conn.fetch = AsyncMock(return_value=[CAT_ROW_ACTIVE])

        result = await repo.list_by_account(ACCOUNT_ID, active_only=True)

        assert len(result) == 1
        sql = conn.fetch.call_args[0][0].lower()
        assert "is_active" in sql
        assert "deleted_at is null" in sql
        assert result[0]["name"] == "Ropa"

    @pytest.mark.asyncio
    async def test_list_all_when_active_only_false_still_excludes_deleted(self, category_repo):
        """RN-B1: include_inactive muestra las DESACTIVADAS, nunca las borradas."""
        repo, conn = category_repo
        conn.fetch = AsyncMock(return_value=[CAT_ROW_ACTIVE, CAT_ROW_INACTIVE])

        result = await repo.list_by_account(ACCOUNT_ID, active_only=False)

        assert len(result) == 2
        sql = conn.fetch.call_args[0][0].lower()
        assert "is_active = true" not in sql
        assert "deleted_at is null" in sql
        assert ACCOUNT_ID in conn.fetch.call_args[0]

    @pytest.mark.asyncio
    async def test_list_orders_by_sort_order_then_name(self, category_repo):
        repo, conn = category_repo
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_by_account(ACCOUNT_ID, active_only=True)

        assert "ORDER BY sort_order" in conn.fetch.call_args[0][0]

    @pytest.mark.asyncio
    async def test_list_scopes_by_account_id(self, category_repo):
        """Aislamiento por cuenta: el filtro explícito por account_id es el
        guard (regla dura del proyecto), la RLS es red."""
        repo, conn = category_repo
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_by_account(ACCOUNT_ID, active_only=False)

        sql = conn.fetch.call_args[0][0].lower()
        assert "account_id = $1" in sql


# ── 8.1 RED: get_by_id / get_active_by_id ─────────────────────────────────────

class TestProductCategoryRepositoryGet:
    @pytest.mark.asyncio
    async def test_get_by_id_scopes_account_and_excludes_deleted(self, category_repo):
        repo, conn = category_repo
        conn.fetchrow = AsyncMock(return_value=CAT_ROW_ACTIVE)

        result = await repo.get_by_id(CAT_ID, ACCOUNT_ID)

        assert result is not None
        sql = conn.fetchrow.call_args[0][0].lower()
        assert "account_id = $2" in sql
        assert "deleted_at is null" in sql
        assert ACCOUNT_ID in conn.fetchrow.call_args[0]

    @pytest.mark.asyncio
    async def test_get_by_id_returns_none_when_missing(self, category_repo):
        repo, conn = category_repo
        conn.fetchrow = AsyncMock(return_value=None)

        assert await repo.get_by_id("nonexistent", ACCOUNT_ID) is None

    @pytest.mark.asyncio
    async def test_get_active_by_id_requires_active_and_live(self, category_repo):
        """D14: la categoría destino del lote debe estar viva Y activa."""
        repo, conn = category_repo
        conn.fetchrow = AsyncMock(return_value=CAT_ROW_ACTIVE)

        await repo.get_active_by_id(CAT_ID, ACCOUNT_ID)

        sql = conn.fetchrow.call_args[0][0].lower()
        assert "is_active = true" in sql
        assert "deleted_at is null" in sql
        assert "account_id = $2" in sql


# ── 8.1 RED: create ────────────────────────────────────────────────────────────

class TestProductCategoryRepositoryCreate:
    @pytest.mark.asyncio
    async def test_create_returns_new_row(self, category_repo):
        repo, conn = category_repo
        conn.fetchrow = AsyncMock(return_value=CAT_ROW_ACTIVE)

        result = await repo.create(ACCOUNT_ID, name="Ropa", sort_order=2)

        assert result is not None
        sql = conn.fetchrow.call_args[0][0].upper()
        assert "INSERT INTO PRODUCT_CATEGORIES" in sql
        assert "RETURNING" in sql
        assert 2 in conn.fetchrow.call_args[0]

    @pytest.mark.asyncio
    async def test_create_without_sort_order_appends_at_end(self, category_repo):
        """sort_order ausente → la categoría nace al FINAL (MAX + 1), no en 0
        (en 0 se colaría delante de las 7 sembradas)."""
        repo, conn = category_repo
        conn.fetchrow = AsyncMock(return_value=CAT_ROW_ACTIVE)

        await repo.create(ACCOUNT_ID, name="Ferretería", sort_order=None)

        sql = conn.fetchrow.call_args[0][0].lower()
        assert "max(sort_order)" in sql
        assert None in conn.fetchrow.call_args[0]

    @pytest.mark.asyncio
    async def test_create_has_no_kind_column(self, category_repo):
        repo, conn = category_repo
        conn.fetchrow = AsyncMock(return_value=CAT_ROW_ACTIVE)

        await repo.create(ACCOUNT_ID, name="Ropa", sort_order=1)

        assert "kind" not in conn.fetchrow.call_args[0][0].lower()


# ── 8.1 RED: update (rename / reorder / reactivate) ───────────────────────────

class TestProductCategoryRepositoryUpdate:
    @pytest.mark.asyncio
    async def test_update_name_only_preserves_the_rest(self, category_repo):
        """Campos ausentes conservan (COALESCE) — renombrar no reordena ni
        cambia is_active."""
        repo, conn = category_repo
        conn.fetchrow = AsyncMock(return_value={**CAT_ROW_ACTIVE, "name": "Indumentaria"})

        result = await repo.update(CAT_ID, ACCOUNT_ID, name="Indumentaria", sort_order=None, is_active=None)

        assert result["name"] == "Indumentaria"
        sql = conn.fetchrow.call_args[0][0]
        assert "COALESCE($3, name)" in sql
        assert "COALESCE($4, sort_order)" in sql
        assert "COALESCE($5, is_active)" in sql
        assert "deleted_at IS NULL" in sql

    @pytest.mark.asyncio
    async def test_update_reorder_passes_sort_order(self, category_repo):
        repo, conn = category_repo
        conn.fetchrow = AsyncMock(return_value={**CAT_ROW_ACTIVE, "sort_order": 9})

        await repo.update(CAT_ID, ACCOUNT_ID, name=None, sort_order=9, is_active=None)

        assert 9 in conn.fetchrow.call_args[0]

    @pytest.mark.asyncio
    async def test_update_reactivate_passes_is_active_true(self, category_repo):
        repo, conn = category_repo
        conn.fetchrow = AsyncMock(return_value={**CAT_ROW_INACTIVE, "is_active": True})

        result = await repo.update(CAT_ROW_INACTIVE["id"], ACCOUNT_ID, name=None, sort_order=None, is_active=True)

        assert result["is_active"] is True
        assert True in conn.fetchrow.call_args[0]

    @pytest.mark.asyncio
    async def test_update_not_found_returns_none(self, category_repo):
        repo, conn = category_repo
        conn.fetchrow = AsyncMock(return_value=None)

        assert await repo.update("nonexistent", ACCOUNT_ID, name="X", sort_order=None, is_active=None) is None


# ── 8.1 RED: deactivate ────────────────────────────────────────────────────────

class TestProductCategoryRepositoryDeactivate:
    @pytest.mark.asyncio
    async def test_deactivate_sets_is_active_false_never_deletes(self, category_repo):
        repo, conn = category_repo
        conn.fetchrow = AsyncMock(return_value={**CAT_ROW_ACTIVE, "is_active": False})

        result = await repo.deactivate(CAT_ID, ACCOUNT_ID)

        assert result["is_active"] is False
        sql = conn.fetchrow.call_args[0][0]
        assert "is_active = FALSE" in sql
        assert "DELETE FROM" not in sql.upper()
        assert "account_id = $2" in sql

    @pytest.mark.asyncio
    async def test_deactivate_returns_none_if_not_found(self, category_repo):
        repo, conn = category_repo
        conn.fetchrow = AsyncMock(return_value=None)

        assert await repo.deactivate("nonexistent", ACCOUNT_ID) is None


# ── soft-delete-policy: product_categories entra a la allowlist ───────────────

class TestProductCategorySoftDeleteAllowlist:
    @pytest.mark.asyncio
    async def test_soft_delete_accepts_product_categories(self, category_repo):
        repo, conn = category_repo
        conn.execute = AsyncMock(return_value="UPDATE 1")

        ok = await repo.soft_delete("product_categories", CAT_ID, ACCOUNT_ID, "11111111-1111-1111-1111-111111111111")

        assert ok is True
        sql = conn.execute.call_args[0][0]
        assert "UPDATE product_categories SET deleted_at = now(), deleted_by = $3" in sql
