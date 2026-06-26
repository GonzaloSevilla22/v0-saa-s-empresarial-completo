"""
fiscal-receptor-iva-relay — CAERelayProcessor propaga receptor + IVA al CAERequest.

TDD RED->GREEN->TRIANGULATE: hoy process_document arma el CAERequest sin receptor
ni desglose de IVA; este test verifica que esos campos viajen desde el doc al request.

Gate CI: python -m pytest backend/tests -m "not integration"
Spec ref: openspec/changes/fiscal-receptor-iva-relay/specs/afip-fiscal-document/spec.md
  Scenario: El relay propaga los campos al CAERequest
Design ref: D1 (resolver en emisión, propagar en relay)
"""
from __future__ import annotations

import datetime
from unittest.mock import AsyncMock, MagicMock

import pytest

from backend.services.fiscal.fiscal_document_port import CAEResponse
from backend.services.fiscal.cae_relay_processor import CAERelayProcessor


ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
DOC_ID = "dddddddd-dddd-dddd-dddd-dddddddddddd"


def _make_doc(**overrides):
    base = {
        "id": DOC_ID,
        "account_id": ACCOUNT_ID,
        "fiscal_profile_id": "pppppppp-pppp-pppp-pppp-pppppppppppp",
        "point_of_sale_id": "vvvvvvvv-vvvv-vvvv-vvvv-vvvvvvvvvvvv",
        "comprobante_type": "factura_b",
        "punto_de_venta": 1,
        "number": 42,
        "total": 1210.0,
        "status": "pending_cae",
        "attempts": 0,
        "next_attempt_at": None,
        "cuit": "20123456789",
        "ambiente": "homologacion",
    }
    base.update(overrides)
    return base


def _capturing_adapter():
    adapter = MagicMock()
    adapter.request_cae = AsyncMock(
        return_value=CAEResponse(cae="123", cae_due_date=datetime.date.today(), is_approved=True)
    )
    return adapter


def _repo():
    repo = MagicMock()
    repo.update_authorized = AsyncMock()
    repo.update_rejected = AsyncMock()
    repo.update_retry = AsyncMock()
    return repo


class TestRelayPropagatesReceptorAndIva:
    @pytest.mark.asyncio
    async def test_relay_threads_receptor_and_iva(self):
        adapter = _capturing_adapter()
        processor = CAERelayProcessor(adapter=adapter, repo=_repo())
        doc = _make_doc(
            receptor_doc_tipo=80,
            receptor_doc_nro="20999999996",
            receptor_iva_condition="responsable_inscripto",
            neto=1000.0,
            iva_amount=210.0,
            iva_alicuota_id=5,
        )

        await processor.process_document(doc)

        req = adapter.request_cae.call_args[0][0]
        assert req.receptor_doc_tipo == 80
        assert req.receptor_doc_nro == "20999999996"
        assert req.receptor_iva_condition == "responsable_inscripto"
        assert req.neto == 1000.0
        assert req.iva_amount == 210.0
        assert req.iva_alicuota_id == 5

    @pytest.mark.asyncio
    async def test_relay_defaults_when_doc_has_no_receptor(self):
        """TRIANGULATE: doc histórico sin esos campos → CAERequest con None (comportamiento actual)."""
        adapter = _capturing_adapter()
        processor = CAERelayProcessor(adapter=adapter, repo=_repo())
        doc = _make_doc(comprobante_type="factura_c", total=1000.0)

        await processor.process_document(doc)

        req = adapter.request_cae.call_args[0][0]
        assert req.receptor_doc_tipo is None
        assert req.receptor_doc_nro is None
        assert req.neto is None
        assert req.iva_amount is None
