"""
presupuestos-modulo (task 2.5, D3) — etiqueta visible del número interno.

Una sola definición por lenguaje (`backend/services/commercial_documents/
numbering.py` y `frontend/lib/internal-document-number.ts`) contra el MISMO
fixture de casos, `backend/tests/fixtures/internal_document_number_cases.json`,
que lee también vitest (patrón de `scale_layout_cases.json`).
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest

FIXTURE = json.loads(
    (Path(__file__).parent / "fixtures" / "internal_document_number_cases.json").read_text(encoding="utf-8")
)


@pytest.mark.parametrize("case", FIXTURE["format_cases"], ids=lambda c: c["name"])
def test_format_matches_the_shared_fixture(case):
    from backend.services.commercial_documents.numbering import format_internal_document_number

    assert format_internal_document_number(case["document_type"], case["number"]) == case["expected"]


@pytest.mark.parametrize("case", FIXTURE["query_cases"], ids=lambda c: c["name"])
def test_query_parsing_matches_the_shared_fixture(case):
    from backend.services.commercial_documents.numbering import parse_internal_document_number_query

    assert parse_internal_document_number_query(case["query"], case["document_type"]) == case["expected"]


def test_fixture_is_not_empty_and_covers_the_three_search_formats():
    queries = {c["query"] for c in FIXTURE["query_cases"]}
    assert {"P-12", "12", "00000012"} <= queries
    assert len(FIXTURE["format_cases"]) >= 4


def test_unknown_document_type_is_rejected():
    from backend.services.commercial_documents.numbering import format_internal_document_number

    with pytest.raises(ValueError):
        format_internal_document_number("remito", 1)


def test_a_foreign_prefix_is_text_not_a_number():
    # Revisión adversarial F4: "R-12" en /presupuestos no puede traer P-00000012.
    from backend.services.commercial_documents.numbering import parse_internal_document_number_query

    assert parse_internal_document_number_query("R-12", "quote") is None
    assert parse_internal_document_number_query("P-12", "delivery_note_sale") is None
    assert parse_internal_document_number_query("R-12", "delivery_note_sale") == 12
    assert parse_internal_document_number_query("P-12", "quote") == 12


def test_query_for_an_unknown_document_type_is_rejected():
    from backend.services.commercial_documents.numbering import parse_internal_document_number_query

    with pytest.raises(ValueError):
        parse_internal_document_number_query("12", "remito")


def test_none_number_has_no_label():
    from backend.services.commercial_documents.numbering import format_internal_document_number

    assert format_internal_document_number("quote", None) is None
