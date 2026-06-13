"""
C-27 v21-fiscal-profile — CAE relay processor (TDD idempotente).

TDD RED→GREEN:
  2.6 RED: proceso de background idempotente:
       - pending_cae + CAE válido → authorized
       - error transitorio → attempts++ + next_attempt_at backoff
       - rechazo → rejected + last_error
       - reproceso de authorized → sin cambio (idempotente)
  2.7 GREEN: relay/endpoint de procesamiento con backoff e idempotencia.

Spec ref: afip-fiscal-document/spec.md §"Obtención del CAE en background"
Design ref: D5/D6 (OQ-1=A, cola + relay idempotente)
"""
from __future__ import annotations

import datetime
from unittest.mock import AsyncMock, MagicMock

import pytest

from backend.services.fiscal.fiscal_document_port import CAERequest, CAEResponse
from backend.services.fiscal.cae_relay_processor import CAERelayProcessor


ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
DOC_ID = "dddddddd-dddd-dddd-dddd-dddddddddddd"


def make_pending_doc(**overrides):
    """Fábrica de documentos pending_cae para los tests."""
    base = {
        "id": DOC_ID,
        "account_id": ACCOUNT_ID,
        "fiscal_profile_id": "pppppppp-pppp-pppp-pppp-pppppppppppp",
        "point_of_sale_id": "vvvvvvvv-vvvv-vvvv-vvvv-vvvvvvvvvvvv",
        "comprobante_type": "factura_b",
        "punto_de_venta": 1,
        "number": 42,
        "total": 1500.0,
        "status": "pending_cae",
        "cae": None,
        "cae_due_date": None,
        "attempts": 0,
        "next_attempt_at": None,
        "last_error": None,
        "cuit": "20123456789",
        "ambiente": "homologacion",
    }
    base.update(overrides)
    return base


class TestCAERelayProcessor:
    """2.6 RED → 2.7 GREEN: relay idempotente con backoff."""

    @pytest.fixture
    def stub_adapter(self):
        from backend.services.fiscal.wsfe_stub_adapter import WSFEStubAdapter
        return WSFEStubAdapter()

    @pytest.fixture
    def mock_repo(self):
        """Repository mockeado para fiscal_documents."""
        repo = MagicMock()
        repo.update_authorized = AsyncMock()
        repo.update_rejected = AsyncMock()
        repo.update_retry = AsyncMock()
        return repo

    @pytest.fixture
    def processor(self, stub_adapter, mock_repo):
        return CAERelayProcessor(adapter=stub_adapter, repo=mock_repo)

    # ── Scenario: authorized ──────────────────────────────────────────────────

    @pytest.mark.asyncio
    async def test_pending_cae_gets_authorized_on_success(self, processor, mock_repo, stub_adapter):
        """pending_cae + CAE válido del adapter → el doc se actualiza a authorized."""
        doc = make_pending_doc()

        await processor.process_document(doc)

        mock_repo.update_authorized.assert_called_once()
        call_kwargs = mock_repo.update_authorized.call_args[1]
        assert call_kwargs["doc_id"] == DOC_ID
        assert call_kwargs["cae"] is not None
        assert call_kwargs["cae_due_date"] is not None

    @pytest.mark.asyncio
    async def test_authorized_doc_is_idempotent(self, processor, mock_repo):
        """Un doc ya authorized no se modifica (idempotencia)."""
        doc = make_pending_doc(status="authorized", cae="12345678901234")

        await processor.process_document(doc)

        mock_repo.update_authorized.assert_not_called()
        mock_repo.update_rejected.assert_not_called()
        mock_repo.update_retry.assert_not_called()

    # ── Scenario: error transitorio → retry ──────────────────────────────────

    @pytest.mark.asyncio
    async def test_transient_error_increments_attempts_and_sets_backoff(
        self, stub_adapter, mock_repo
    ):
        """Error transitorio del adapter → attempts++ + next_attempt_at con backoff."""
        # Crear adapter que lanza error transitorio
        failing_adapter = MagicMock()
        failing_adapter.request_cae = AsyncMock(
            return_value=CAEResponse(
                cae=None,
                cae_due_date=None,
                is_approved=False,
                error_code="TRANSIENT",
                error_detail="Timeout AFIP",
            )
        )
        processor = CAERelayProcessor(adapter=failing_adapter, repo=mock_repo)
        doc = make_pending_doc(attempts=2)

        await processor.process_document(doc)

        mock_repo.update_retry.assert_called_once()
        call_kwargs = mock_repo.update_retry.call_args[1]
        assert call_kwargs["doc_id"] == DOC_ID
        assert call_kwargs["attempts"] == 3  # 2 + 1
        assert call_kwargs["next_attempt_at"] > datetime.datetime.now(datetime.timezone.utc)
        assert "Timeout AFIP" in call_kwargs["last_error"]

    @pytest.mark.asyncio
    async def test_backoff_increases_with_attempts(self, mock_repo):
        """El backoff aumenta con los intentos (exponencial o lineal)."""
        failing_adapter = MagicMock()
        failing_adapter.request_cae = AsyncMock(
            return_value=CAEResponse(cae=None, cae_due_date=None, is_approved=False, error_code="ERR", error_detail="err")
        )

        processor = CAERelayProcessor(adapter=failing_adapter, repo=mock_repo)

        # Attempt 0 → corto backoff
        doc_0 = make_pending_doc(attempts=0)
        await processor.process_document(doc_0)
        next_0 = mock_repo.update_retry.call_args[1]["next_attempt_at"]

        mock_repo.update_retry.reset_mock()

        # Attempt 5 → mayor backoff
        doc_5 = make_pending_doc(attempts=5)
        await processor.process_document(doc_5)
        next_5 = mock_repo.update_retry.call_args[1]["next_attempt_at"]

        assert next_5 > next_0, "backoff should increase with more attempts"

    # ── Scenario: rechazo definitivo → rejected ───────────────────────────────

    @pytest.mark.asyncio
    async def test_definitive_rejection_sets_rejected_status(self, mock_repo):
        """Rechazo definitivo de AFIP → status='rejected' + last_error guardado."""
        rejecting_adapter = MagicMock()
        rejecting_adapter.request_cae = AsyncMock(
            return_value=CAEResponse(
                cae=None,
                cae_due_date=None,
                is_approved=False,
                error_code="10016",
                error_detail="CUIT no autorizado en WSFE",
            )
        )

        # Con attempts = MAX_ATTEMPTS para indicar rechazo definitivo
        processor = CAERelayProcessor(adapter=rejecting_adapter, repo=mock_repo, max_attempts=3)
        doc = make_pending_doc(attempts=3)  # ya en el límite

        await processor.process_document(doc)

        mock_repo.update_rejected.assert_called_once()
        call_kwargs = mock_repo.update_rejected.call_args[1]
        assert call_kwargs["doc_id"] == DOC_ID
        assert "CUIT no autorizado" in call_kwargs["last_error"]

    # ── Idempotencia: rejected no se retoca ──────────────────────────────────

    @pytest.mark.asyncio
    async def test_rejected_doc_is_idempotent(self, processor, mock_repo):
        """Un doc ya rejected no se modifica (idempotencia)."""
        doc = make_pending_doc(status="rejected", last_error="prev error")

        await processor.process_document(doc)

        mock_repo.update_authorized.assert_not_called()
        mock_repo.update_rejected.assert_not_called()
        mock_repo.update_retry.assert_not_called()
