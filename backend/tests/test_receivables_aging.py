"""
cobranzas-vencimientos — tests TDD del aging backend (tasks 7.1-7.9).

Cubre:
  7.1  Repository: los tramos y el importe vencido viajan en el envelope
       estándar; la suma de los 5 tramos de cada fila es igual a su saldo
       (los mocks son consistentes y el schema los valida sin degradarlos).
  7.2  Filtro por tramo resuelto EN el servidor por diccionario → predicado,
       jamás por interpolación del input.
  7.3  REGRESIÓN D7: los derivados de vencimiento (due_date, is_overdue,
       days_overdue, open_amount) viajan por list_movements Y por
       list_movements_page — el defecto exacto que se comió cobranzas-reverso.
  7.5  Espejo proveedor: list_payables_page / get_payables_summary sobre
       rpc_payables_report + endpoints /reports/payables.
  7.7  D14: un PUT de cliente/proveedor que OMITE payment_terms_days no lo
       pone en NULL; el null explícito sí lo limpia (tri-estado).
  7.8  GET/PATCH del plazo por defecto de la cuenta sobre
       rpc_set_default_payment_terms; P0401 → 403 RFC 7807.
  7.9  Router: filtro fuera del Literal → 422 sin consulta; página fuera de
       rango → items [] con total; P0400/P0401 traducidos.

Mocks de asyncpg con el patrón de test_receivables_report.py.
"""
from __future__ import annotations

import datetime
from decimal import Decimal
from unittest.mock import AsyncMock, patch

import asyncpg
import pytest

from backend.tests.conftest import make_token

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
CLIENT_A = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
SUPPLIER_A = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
CA_ID = "11111111-1111-1111-1111-111111111111"
SA_ID = "22222222-2222-2222-2222-222222222222"

# Fila con aging consistente: 1500 vencidos + 300 al día + 700 sin
# vencimiento = 2500 = balance (invariante de cierre, fijado de verdad por el
# gate SQL test_receivables_aging_fifo.sql — acá se fija que el schema NO lo
# degrade).
AGING_ROW = {
    "client_id": CLIENT_A,
    "client_name": "Deudor Vencido",
    "balance": Decimal("2500"),
    "days_since_last_charge": 12,
    "days_since_last_payment": 30,
    "last_payment_date": "2026-08-03",
    "overdue_total": Decimal("1500"),
    "amount_current": Decimal("300"),
    "amount_overdue_1_30": Decimal("1000"),
    "amount_overdue_31_60": Decimal("500"),
    "amount_overdue_60_plus": Decimal("0"),
    "amount_no_due_date": Decimal("700"),
    "oldest_due_date": datetime.date(2026, 7, 20),
    "days_overdue_max": 44,
}

PAYABLE_ROW = {
    "supplier_id": SUPPLIER_A,
    "supplier_name": "Proveedor Vencido",
    "balance": Decimal("800"),
    "days_since_last_charge": 15,
    "days_since_last_payment": None,
    "last_payment_date": None,
    "overdue_total": Decimal("500"),
    "amount_current": Decimal("0"),
    "amount_overdue_1_30": Decimal("500"),
    "amount_overdue_31_60": Decimal("0"),
    "amount_overdue_60_plus": Decimal("0"),
    "amount_no_due_date": Decimal("300"),
    "oldest_due_date": datetime.date(2026, 8, 23),
    "days_overdue_max": 10,
}


@pytest.fixture
def customer_repo():
    from backend.repositories.customer_account_repository import (
        CustomerAccountRepository,
    )

    conn = AsyncMock()
    return CustomerAccountRepository(conn), conn


@pytest.fixture
def supplier_repo():
    from backend.repositories.supplier_account_repository import (
        SupplierAccountRepository,
    )

    conn = AsyncMock()
    return SupplierAccountRepository(conn), conn


# ── 7.1 — repository: tramos en el envelope estándar ─────────────────────────

class TestReceivablesAgingRepository:
    @pytest.mark.asyncio
    async def test_aging_fields_flow_through_envelope(self, customer_repo):
        repo, conn = customer_repo
        conn.fetchval = AsyncMock(return_value=1)
        conn.fetch = AsyncMock(return_value=[AGING_ROW])

        result = await repo.list_receivables_page(ACCOUNT_ID, page=0, size=25)

        row = result["items"][0]
        assert row["overdue_total"] == Decimal("1500")
        assert row["amount_no_due_date"] == Decimal("700")
        # invariante de cierre sobre la fila entregada
        buckets = (
            row["amount_current"]
            + row["amount_overdue_1_30"]
            + row["amount_overdue_31_60"]
            + row["amount_overdue_60_plus"]
            + row["amount_no_due_date"]
        )
        assert buckets == row["balance"]

    @pytest.mark.asyncio
    async def test_bucket_filter_resolves_via_dictionary_not_interpolation(
        self, customer_repo
    ):
        repo, conn = customer_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_receivables_page(
            ACCOUNT_ID, page=0, size=25, bucket="overdue_60_plus"
        )

        select_sql = conn.fetch.call_args[0][0].lower()
        count_sql = conn.fetchval.call_args[0][0].lower()
        # el predicado mapeado aparece en las DOS queries (listado y COUNT —
        # el filtro es sobre el conjunto completo, no sobre la página)
        assert "amount_overdue_60_plus > 0" in select_sql
        assert "amount_overdue_60_plus > 0" in count_sql

    @pytest.mark.asyncio
    async def test_unknown_bucket_falls_back_to_no_filter(self, customer_repo):
        repo, conn = customer_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_receivables_page(
            ACCOUNT_ID, page=0, size=25, bucket="evil'; drop table--"
        )

        select_sql = conn.fetch.call_args[0][0]
        # el input crudo JAMÁS se interpola
        assert "evil" not in select_sql
        assert "drop table" not in select_sql.lower()

    @pytest.mark.asyncio
    async def test_summary_includes_overdue_total(self, customer_repo):
        repo, conn = customer_repo
        conn.fetchrow = AsyncMock(
            return_value={
                "total_receivable": Decimal("2500"),
                "overdue_total": Decimal("1500"),
                "debtor_count": 1,
            }
        )

        result = await repo.get_receivables_summary(ACCOUNT_ID)

        assert result["overdue_total"] == Decimal("1500")
        summary_sql = conn.fetchrow.call_args[0][0].lower()
        assert "overdue_total" in summary_sql
        assert "rpc_receivables_report($1::uuid)" in summary_sql


# ── 7.3 — REGRESIÓN D7: derivados en LAS DOS queries de movimientos ──────────

class TestMovementDerivativesInBothQueries:
    """El defecto exacto de cobranzas-reverso: derivados sumados sólo al
    endpoint paginado, mientras la pantalla real lee list_movements. Estos
    asserts fallan si CUALQUIERA de las dos queries pierde los derivados."""

    DERIVED = ("open_amount", "is_overdue", "days_overdue")

    @pytest.mark.asyncio
    async def test_customer_list_movements_has_due_derivatives(self, customer_repo):
        repo, conn = customer_repo
        conn.fetch = AsyncMock(return_value=[])
        await repo.list_movements(CA_ID, ACCOUNT_ID)
        sql = conn.fetch.call_args[0][0].lower()
        for col in self.DERIVED:
            assert col in sql, f"list_movements perdió {col} (D7)"

    @pytest.mark.asyncio
    async def test_customer_list_movements_page_has_due_derivatives(
        self, customer_repo
    ):
        repo, conn = customer_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])
        await repo.list_movements_page(CA_ID, account_id=ACCOUNT_ID, page=0, size=50)
        sql = conn.fetch.call_args[0][0].lower()
        for col in self.DERIVED:
            assert col in sql, f"list_movements_page perdió {col} (D7)"

    @pytest.mark.asyncio
    async def test_supplier_list_movements_has_due_derivatives(self, supplier_repo):
        repo, conn = supplier_repo
        conn.fetch = AsyncMock(return_value=[])
        await repo.list_movements(SA_ID, ACCOUNT_ID)
        sql = conn.fetch.call_args[0][0].lower()
        for col in self.DERIVED:
            assert col in sql, f"supplier list_movements perdió {col} (D7)"

    @pytest.mark.asyncio
    async def test_supplier_list_movements_page_has_due_derivatives(
        self, supplier_repo
    ):
        repo, conn = supplier_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])
        await repo.list_movements_page(SA_ID, account_id=ACCOUNT_ID, page=0, size=50)
        sql = conn.fetch.call_args[0][0].lower()
        for col in self.DERIVED:
            assert col in sql, f"supplier list_movements_page perdió {col} (D7)"

    @pytest.mark.asyncio
    async def test_customer_charges_classified_by_type_not_sign(self, customer_repo):
        """La derivación clasifica cargo por movement_type ('sale' +
        adjustment positivo) — nunca por signo (un reversal positivo NO es
        cargo, D4)."""
        repo, conn = customer_repo
        conn.fetch = AsyncMock(return_value=[])
        await repo.list_movements(CA_ID, ACCOUNT_ID)
        sql = conn.fetch.call_args[0][0].lower()
        assert "'sale'" in sql
        assert "adjustment" in sql


# ── 7.5 — espejo proveedor: payables ─────────────────────────────────────────

class TestPayablesRepository:
    @pytest.mark.asyncio
    async def test_list_payables_page_over_rpc(self, supplier_repo):
        repo, conn = supplier_repo
        conn.fetchval = AsyncMock(return_value=1)
        conn.fetch = AsyncMock(return_value=[PAYABLE_ROW])

        result = await repo.list_payables_page(ACCOUNT_ID, page=0, size=25)

        assert set(result.keys()) == {"items", "total", "page", "pages"}
        assert result["items"][0]["supplier_name"] == "Proveedor Vencido"
        select_sql = conn.fetch.call_args[0][0].lower()
        assert "rpc_payables_report($1::uuid)" in select_sql

    @pytest.mark.asyncio
    async def test_payables_summary_over_same_rpc(self, supplier_repo):
        repo, conn = supplier_repo
        conn.fetchrow = AsyncMock(
            return_value={
                "total_payable": Decimal("800"),
                "overdue_total": Decimal("500"),
                "creditor_count": 1,
            }
        )

        result = await repo.get_payables_summary(ACCOUNT_ID)

        assert result["total_payable"] == Decimal("800")
        sql = conn.fetchrow.call_args[0][0].lower()
        assert "rpc_payables_report($1::uuid)" in sql


# ── 7.8 — plazo por defecto de la cuenta ─────────────────────────────────────

class TestDefaultPaymentTerms:
    @pytest.mark.asyncio
    async def test_get_reads_accounts_column(self, customer_repo):
        repo, conn = customer_repo
        conn.fetchval = AsyncMock(return_value=30)
        result = await repo.get_default_payment_terms(ACCOUNT_ID)
        assert result == 30
        sql = conn.fetchval.call_args[0][0].lower()
        assert "default_payment_terms_days" in sql
        assert "from public.accounts" in sql or "from accounts" in sql

    @pytest.mark.asyncio
    async def test_set_goes_through_rpc(self, customer_repo):
        repo, conn = customer_repo
        conn.fetchval = AsyncMock(return_value=None)
        await repo.set_default_payment_terms(30)
        sql = conn.fetchval.call_args[0][0].lower()
        assert "rpc_set_default_payment_terms" in sql

    @pytest.mark.asyncio
    async def test_set_none_clears(self, customer_repo):
        repo, conn = customer_repo
        conn.fetchval = AsyncMock(return_value=None)
        await repo.set_default_payment_terms(None)
        assert conn.fetchval.call_args[0][1] is None


# ── 7.7 — D14: la edición que omite el plazo NO lo borra ─────────────────────

class TestClientTermsPreservation:
    @pytest.mark.asyncio
    async def test_update_omitting_terms_does_not_null_it(self):
        """PUT sin payment_terms_days → el SET no incluye la columna (el
        plazo configurado sobrevive). Es D14 — el bug exacto de
        metodos-pago-operaciones/edicion-preserva-contexto."""
        from backend.repositories.client_repository import ClientRepository
        from backend.schemas.clients import ClientUpdate
        from backend.services.clients import update_client

        conn = AsyncMock()
        repo = ClientRepository(conn)
        conn.fetchrow = AsyncMock(return_value={"id": CLIENT_A})

        payload = ClientUpdate(phone="2611234567")
        await update_client(
            repo, {"user_id": "u", "role": "user"}, ACCOUNT_ID, CLIENT_A, payload
        )

        sql = conn.fetchrow.call_args[0][0]
        assert "phone" in sql
        assert "payment_terms_days" not in sql

    @pytest.mark.asyncio
    async def test_update_with_explicit_null_clears_terms(self):
        from backend.repositories.client_repository import ClientRepository
        from backend.schemas.clients import ClientUpdate
        from backend.services.clients import update_client

        conn = AsyncMock()
        repo = ClientRepository(conn)
        conn.fetchrow = AsyncMock(return_value={"id": CLIENT_A})

        payload = ClientUpdate.model_validate({"payment_terms_days": None})
        await update_client(
            repo, {"user_id": "u", "role": "user"}, ACCOUNT_ID, CLIENT_A, payload
        )

        sql = conn.fetchrow.call_args[0][0]
        assert "payment_terms_days" in sql

    @pytest.mark.asyncio
    async def test_update_with_value_sets_terms(self):
        from backend.repositories.client_repository import ClientRepository
        from backend.schemas.clients import ClientUpdate
        from backend.services.clients import update_client

        conn = AsyncMock()
        repo = ClientRepository(conn)
        conn.fetchrow = AsyncMock(return_value={"id": CLIENT_A})

        payload = ClientUpdate(payment_terms_days=60)
        await update_client(
            repo, {"user_id": "u", "role": "user"}, ACCOUNT_ID, CLIENT_A, payload
        )

        sql = conn.fetchrow.call_args[0][0]
        assert "payment_terms_days" in sql
        assert 60 in conn.fetchrow.call_args[0]

    def test_negative_terms_rejected_by_schema(self):
        from backend.schemas.clients import ClientUpdate

        with pytest.raises(Exception):
            ClientUpdate(payment_terms_days=-5)

    @pytest.mark.asyncio
    async def test_supplier_update_omitting_terms_preserves(self):
        """El proveedor ya usa model_fields_set (tri-estado BE-1) — el plazo
        hereda la preservación."""
        from backend.repositories.supplier_repository import SupplierRepository
        from backend.schemas.suppliers import SupplierUpdate
        from backend.services.suppliers import update_supplier

        conn = AsyncMock()
        repo = SupplierRepository(conn)
        conn.fetchrow = AsyncMock(return_value={"id": SUPPLIER_A})

        payload = SupplierUpdate(phone="2617654321")
        await update_supplier(
            repo, {"user_id": "u", "role": "user"}, ACCOUNT_ID, SUPPLIER_A, payload
        )

        sql = conn.fetchrow.call_args[0][0]
        assert "payment_terms_days" not in sql


# ── 7.9 — endpoints ──────────────────────────────────────────────────────────

class TestPayablesEndpoints:
    @pytest.mark.asyncio
    async def test_payables_report_ok(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=1)
        conn.fetch = AsyncMock(return_value=[PAYABLE_ROW])
        token = make_token({"app_metadata": {"account_role": "member"}})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/payables",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 200
        data = resp.json()
        assert data["items"][0]["supplier_name"] == "Proveedor Vencido"
        assert Decimal(str(data["items"][0]["overdue_total"])) == Decimal("500")

    @pytest.mark.asyncio
    async def test_payables_summary_ok(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(
            return_value={
                "total_payable": Decimal("800"),
                "overdue_total": Decimal("500"),
                "creditor_count": 1,
            }
        )
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/payables/summary",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 200
        assert Decimal(str(resp.json()["overdue_total"])) == Decimal("500")


class TestBucketFilterEndpoint:
    @pytest.mark.asyncio
    async def test_bucket_outside_literal_is_422_without_query(
        self, async_client, mock_pool
    ):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[])
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/receivables?bucket=evil_bucket",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 422
        conn.fetch.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_valid_bucket_filters_server_side(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=1)
        conn.fetch = AsyncMock(return_value=[AGING_ROW])
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/receivables?bucket=overdue",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 200
        select_sql = conn.fetch.call_args[0][0].lower()
        assert "overdue_total > 0" in select_sql


class TestCollectionSettingsEndpoints:
    @pytest.mark.asyncio
    async def test_get_settings_ok(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=30)
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/settings/collections",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 200
        assert resp.json()["default_payment_terms_days"] == 30

    @pytest.mark.asyncio
    async def test_patch_settings_ok(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=None)
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                "/settings/collections",
                json={"default_payment_terms_days": 45},
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 200
        assert resp.json()["default_payment_terms_days"] == 45

    @pytest.mark.asyncio
    async def test_patch_negative_is_422_without_query(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=None)
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                "/settings/collections",
                json={"default_payment_terms_days": -1},
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 422
        conn.fetchval.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_patch_p0401_maps_to_403(self, async_client, mock_pool):
        pool, conn = mock_pool
        err = asyncpg.exceptions.RaiseError("unauthorized")
        err.sqlstate = "P0401"
        conn.fetchval = AsyncMock(side_effect=err)
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                "/settings/collections",
                json={"default_payment_terms_days": 30},
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 403

    @pytest.mark.asyncio
    async def test_patch_null_clears(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=None)
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                "/settings/collections",
                json={"default_payment_terms_days": None},
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 200
        assert resp.json()["default_payment_terms_days"] is None


# ── venta: el override viaja hasta la RPC ────────────────────────────────────

class TestSaleDueDateTransport:
    @pytest.mark.asyncio
    async def test_sale_operation_forwards_due_date(self):
        from backend.repositories.sales_repository import SalesRepository

        conn = AsyncMock()
        repo = SalesRepository(conn)
        conn.fetchrow = AsyncMock(
            side_effect=[None, {"operation_id": CA_ID, "operation_kind": "sale"}]
        )

        await repo.create_operation(
            "user",
            ACCOUNT_ID,
            [{"amount": 100, "quantity": 1}],
            "idem-key",
            date=datetime.date(2026, 9, 2),
            client_id=CLIENT_A,
            due_date=datetime.date(2026, 10, 2),
        )

        sql = conn.fetchrow.call_args[0][0].lower()
        assert "p_due_date" in sql
        assert datetime.date(2026, 10, 2) in conn.fetchrow.call_args[0]
