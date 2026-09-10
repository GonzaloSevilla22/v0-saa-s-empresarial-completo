"""
asiento-contable-gastos — Grupo 8: backend Python (derivados del gasto,
filtros del libro diario).

Strict TDD: este archivo cubre lo que `gastos-forma-pago`/`journal-entry-
outbox` no tenían todavía.

Qué cubre, por task:

  8.2/8.3/8.5 — `ExpenseOut.has_journal_entry`/`journal_pending`
    · defaults seguros (False/False) cuando el servidor no manda el derivado
      (lectura vieja) — un gasto "sin asiento" nunca aparenta "asentado";
    · mapeo cuando el servidor SÍ los manda, en los tres estados posibles
      (asentado / pendiente / sin asiento) sin confundirlos entre sí.

  8.3 — `_EXPENSE_PROJECTION` — una sola definición, compartida por
    `get_by_id` y `list_paginated` (D11): los dos `EXISTS` nuevos aparecen
    literalmente una sola vez en el archivo del repositorio.

  8.6/8.7/8.9 — `GET /journal-entries` con filtros
    · los cinco filtros (rango de fechas, tipo de documento, referencia,
      estado) llegan al `WHERE` de `JournalEntryRepository`, nunca se
      evalúan en Python;
    · sin filtros, la llamada se comporta EXACTAMENTE igual que antes
      (mismo envelope, mismo orden — cubierto también en
      test_journal_entries_endpoint.py);
    · ninguna combinación de filtros cruza cuentas (account_id sigue siendo
      el primer parámetro, inmutable).

  8.8 — el filtro se empuja al `_fetch_entries` COMPARTIDO y al `COUNT(*)`
    de la paginada (lección de `cobranzas-reverso`): se assertea que las DOS
    consultas de `list_by_account_page` (COUNT y SELECT) llevan los mismos
    valores de filtro.

  8.10 — el endpoint sigue siendo de sólo lectura: ningún camino de
    escritura ni `get_service_conn` en el diff (grep sobre el router).

Run: python -m pytest backend/tests/test_asiento_contable_gastos.py -q
"""
from __future__ import annotations

import datetime
import uuid
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock

import pytest

from backend.repositories.expense_repository import ExpenseRepository
from backend.repositories.journal_entry_repository import JournalEntryRepository
from backend.schemas.expenses import ExpenseOut
from backend.services import journal_entries as je_service

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
OTHER_ACCOUNT_ID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
EXPENSE_ID = "55555555-5555-5555-5555-555555555555"
USER_ID = "11111111-1111-1111-1111-111111111111"

_EXPENSE_ROW = {
    "id": EXPENSE_ID,
    "user_id": USER_ID,
    "category": "Servicios",
    "amount": Decimal("1500.00"),
    "description": "gasto de prueba",
    "date": datetime.date(2026, 9, 5),
    "created_at": datetime.datetime(2026, 9, 5, 10, 0, 0),
    "cost_center_id": None,
    "branch_id": None,
    "payment_method_id": None,
    "payment_method_name": None,
    "payment_method_kind": None,
    "is_payment_locked": False,
    "has_cash_movement": False,
    "has_bank_movement": False,
    "is_delete_blocked": False,
}


# ── 8.2/8.5: ExpenseOut expone el rastro contable ─────────────────────────────

class TestExpenseOutJournalTrail:
    def test_defaults_to_no_journal_entry(self):
        """8.2: sin el derivado del servidor (lectura vieja), un gasto se
        muestra 'sin asiento' — nunca 'asentado' por accidente."""
        out = ExpenseOut(**_EXPENSE_ROW)
        assert out.has_journal_entry is False
        assert out.journal_pending is False

    def test_asentado(self):
        """8.5: estado 'asentado' — has_journal_entry=True, journal_pending=False."""
        out = ExpenseOut(**{**_EXPENSE_ROW, "has_journal_entry": True, "journal_pending": False})
        assert out.has_journal_entry is True
        assert out.journal_pending is False

    def test_pendiente(self):
        """8.5: estado 'pendiente' — evento emitido, todavía sin procesar."""
        out = ExpenseOut(**{**_EXPENSE_ROW, "has_journal_entry": False, "journal_pending": True})
        assert out.has_journal_entry is False
        assert out.journal_pending is True

    def test_sin_asiento_no_se_confunde_con_pendiente(self):
        """8.5: los dos estados 'no asentado' (histórico vs. pendiente) no se
        confunden — son mutuamente distinguibles, no un solo booleano."""
        historico = ExpenseOut(**{**_EXPENSE_ROW, "has_journal_entry": False, "journal_pending": False})
        pendiente = ExpenseOut(**{**_EXPENSE_ROW, "has_journal_entry": False, "journal_pending": True})
        assert historico.journal_pending != pendiente.journal_pending


class TestExpenseProjectionSingleDefinition:
    def test_journal_derivatives_appear_exactly_once(self):
        """8.3/D11: `_EXPENSE_PROJECTION` es la única definición — no hay una
        segunda consulta que calcule el mismo derivado en otro lugar."""
        import backend.repositories.expense_repository as repo_mod

        src = repo_mod.__file__
        text = open(src, encoding="utf-8").read()
        assert text.count("AS has_journal_entry") == 1
        assert text.count("AS journal_pending") == 1
        # Los dos viven DENTRO de _EXPENSE_PROJECTION, no en una query aparte.
        proj_start = text.index("_EXPENSE_PROJECTION = ")
        proj_end = text.index('"""', text.index('"""', proj_start) + 3)
        projection_block = text[proj_start:proj_end]
        assert "has_journal_entry" in projection_block
        assert "journal_pending" in projection_block

    @pytest.mark.asyncio
    async def test_get_by_id_and_list_paginated_share_the_projection(self):
        """8.3: get_by_id y list_paginated corren el MISMO SQL de proyección
        (mismas cláusulas EXISTS), no dos definiciones divergentes."""
        conn = AsyncMock()
        conn.fetchrow = AsyncMock(return_value=_EXPENSE_ROW)
        conn.fetch = AsyncMock(return_value=[_EXPENSE_ROW])
        conn.fetchval = AsyncMock(return_value=1)
        repo = ExpenseRepository(conn)

        await repo.get_by_id(EXPENSE_ID, ACCOUNT_ID)
        await repo.list_paginated(ACCOUNT_ID, page=0, page_size=10)

        sql_get_by_id = conn.fetchrow.call_args_list[0].args[0]
        sql_list = conn.fetch.call_args_list[0].args[0]
        assert "has_journal_entry" in sql_get_by_id
        assert "journal_pending" in sql_get_by_id
        assert "has_journal_entry" in sql_list
        assert "journal_pending" in sql_list


# ── 8.6/8.7/8.9: filtros de GET /journal-entries ──────────────────────────────

def _je_conn():
    conn = AsyncMock()
    conn.fetch = AsyncMock(return_value=[])
    conn.fetchval = AsyncMock(return_value=0)
    return conn


class TestJournalEntryRepositoryFilters:
    @pytest.mark.asyncio
    async def test_filters_reach_the_where_clause(self):
        """8.6/8.7: los cinco filtros viajan como parámetros posicionales al
        SELECT — nunca se filtran en Python."""
        conn = _je_conn()
        repo = JournalEntryRepository(conn)
        ref = str(uuid.uuid4())

        await repo.list_by_account(
            ACCOUNT_ID,
            date_from=datetime.date(2026, 9, 1),
            date_to=datetime.date(2026, 9, 30),
            source_doc_type="Expense",
            source_doc_ref=ref,
            status="posted",
        )

        call = conn.fetch.call_args_list[0]
        sql, *args = call.args
        assert "source_doc_type" in sql
        assert "source_doc_ref" in sql
        assert "status" in sql
        assert datetime.date(2026, 9, 1) in args
        assert datetime.date(2026, 9, 30) in args
        assert "Expense" in args
        assert ref in args
        assert "posted" in args

    @pytest.mark.asyncio
    async def test_unfiltered_call_is_unchanged(self):
        """8.9: sin filtros, el SELECT corre con los cinco parámetros en None
        — mismo comportamiento observable que antes de este change."""
        conn = _je_conn()
        repo = JournalEntryRepository(conn)

        await repo.list_by_account(ACCOUNT_ID)

        call = conn.fetch.call_args_list[0]
        sql, account_id_arg, *rest = call.args
        assert account_id_arg == ACCOUNT_ID
        # Los cinco filtros viajan como None — la cláusula SQL los neutraliza
        # (`$N::date IS NULL OR ...`), así que el resultado no cambia.
        assert rest.count(None) >= 5

    @pytest.mark.asyncio
    async def test_page_count_and_select_use_the_same_filters(self):
        """8.8: list_by_account_page empuja el filtro al COUNT y al SELECT —
        antes el COUNT no tenía ningún filtro; con filtros nuevos sin tocar
        el COUNT, `total` mentiría (lección de cobranzas-reverso)."""
        conn = _je_conn()
        repo = JournalEntryRepository(conn)

        await repo.list_by_account_page(
            ACCOUNT_ID, page=0, size=50, source_doc_type="Expense", status="posted",
        )

        count_call = conn.fetchval.call_args_list[0]
        select_call = conn.fetch.call_args_list[0]
        # El COUNT lleva los mismos valores de filtro que el SELECT (salvo
        # limit/offset, que el COUNT no necesita).
        count_args = count_call.args[1:]
        select_args = select_call.args[1:-2]  # sin limit/offset finales
        assert count_args == select_args
        assert "Expense" in count_args
        assert "posted" in count_args

    @pytest.mark.asyncio
    async def test_page_envelope_reflects_the_filtered_total(self):
        """8.7: `total` del envelope viene del COUNT filtrado, no del total sin filtrar."""
        conn = _je_conn()
        conn.fetchval = AsyncMock(return_value=3)
        repo = JournalEntryRepository(conn)

        result = await repo.list_by_account_page(ACCOUNT_ID, page=0, size=50, status="posted")
        assert result["total"] == 3

    @pytest.mark.asyncio
    async def test_no_filter_combination_crosses_accounts(self):
        """8.9: cualquier combinación de filtros conserva account_id como
        primer parámetro — no hay forma de que un filtro sustituya la
        tenencia."""
        conn = _je_conn()
        repo = JournalEntryRepository(conn)

        await repo.list_by_account(ACCOUNT_ID, source_doc_type="Expense")
        await repo.list_by_account(OTHER_ACCOUNT_ID, source_doc_type="Expense")

        first_account_arg = conn.fetch.call_args_list[0].args[1]
        second_account_arg = conn.fetch.call_args_list[1].args[1]
        assert first_account_arg == ACCOUNT_ID
        assert second_account_arg == OTHER_ACCOUNT_ID
        assert first_account_arg != second_account_arg


class TestJournalEntryRepositoryTimezone:
    def test_date_range_filter_uses_business_timezone(self):
        """Finding revisor ronda 1 (minor): el filtro de período comparaba
        `posted_at` (timestamptz, un instante) contra un `date` pelado, así
        que el corte se resolvía en la zona de la SESIÓN del pool (UTC) y no
        en hora argentina — contra la regla que el propio proyecto fijó en
        estadisticas-ventas (`::date` pelado sólo para fechas de negocio;
        `AT TIME ZONE` para instantes). Un contra-asiento hecho entre las
        21:00 y las 24:00 ART caía al día siguiente en UTC y desaparecía del
        filtro "hasta hoy" que el usuario eligió en /reportes/libro-diario."""
        import backend.repositories.journal_entry_repository as repo_mod

        assert (
            "(posted_at AT TIME ZONE 'America/Argentina/Mendoza')::date >= $2::date"
            in repo_mod._FILTERS
        )
        assert (
            "(posted_at AT TIME ZONE 'America/Argentina/Mendoza')::date <= $3::date"
            in repo_mod._FILTERS
        )


class TestJournalEntriesRouterReadOnly:
    def test_router_has_no_write_verbs(self):
        """8.10: el endpoint sigue siendo de sólo lectura — sin POST/PUT/
        PATCH/DELETE."""
        from backend.routers.journal_entries import router

        methods = {m for r in router.routes for m in getattr(r, "methods", set())}
        assert methods == {"GET"}

    def test_router_never_uses_service_conn(self):
        """8.10: ningún camino de escritura ni get_service_conn en el diff.

        (El comentario del archivo SÍ nombra 'service_role' para declarar su
        ausencia — se busca la función `get_service_conn`, que es el símbolo
        real que importaría un camino de escritura, nunca la palabra suelta.)
        """
        from pathlib import Path

        src = Path(__file__).parents[1] / "routers" / "journal_entries.py"
        text = src.read_text(encoding="utf-8")
        assert "get_service_conn" not in text
        assert "import get_service_conn" not in text


class TestJournalEntriesServiceFiltersEndToEnd:
    @pytest.mark.asyncio
    async def test_service_page_forwards_all_filters(self):
        """8.6/8.7: list_journal_entries_page reenvía los cinco filtros tal
        cual al repositorio."""
        repo = MagicMock()
        repo.list_by_account_page = AsyncMock(return_value={"items": [], "total": 0, "page": 0, "pages": 0})
        ref = str(uuid.uuid4())

        await je_service.list_journal_entries_page(
            repo, ACCOUNT_ID,
            date_from=datetime.date(2026, 9, 1), date_to=datetime.date(2026, 9, 30),
            source_doc_type="Expense", source_doc_ref=ref, status="posted",
        )
        repo.list_by_account_page.assert_called_once_with(
            ACCOUNT_ID, page=0, size=100,
            date_from=datetime.date(2026, 9, 1), date_to=datetime.date(2026, 9, 30),
            source_doc_type="Expense", source_doc_ref=ref, status="posted",
        )
