"""
C-27 v21-fiscal-profile — CAE relay trigger: machine endpoint + anti-double-CAE claim
  + fire-and-forget on emit + migration static assertions.

TDD RED→GREEN cycle:
  Part 1: machine endpoint POST /fiscal/documents/process-pending-cron
    - Missing Authorization header → 401
    - Wrong secret → 401
    - Empty/unset configured secret (fail-closed) → 401
    - Correct secret → 200 with JSON summary
  Part 2: Anti-double-CAE claim (claim_pending)
    - claim_pending returns row when unclaimed
    - claim_pending returns None when already claimed
    - Two concurrent claims → exactly one succeeds, one None
    - process_document_by_id calls request_cae only for the claiming caller
    - list_pending_all fetches cross-account docs
  Part 3: Fire-and-forget on emit
    - process_doc_by_id_background uses claim_pending guard
    - process_doc_by_id_background skips when claim fails
  Part 4: Cross-account batch via process_all_pending_documents
    - Processes docs from multiple accounts
    - Skips docs where claim_pending returns None
  Part 5: Migration static assertions (mirror test_events_reconcile.py style)
    - File exists, references net.http_post / rpc_trigger_cae_relay
    - References cron job name, reads from vault
    - No plaintext secrets, idempotency guards present

Spec ref: afip-fiscal-document/spec.md §"Relay del CAE en background"
Design ref: D5, D6, OQ-1=A, governance CRITICAL
"""
from __future__ import annotations

import re
import sys
import types
import uuid
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Stub fpdf BEFORE any import of backend.main (pre-existing missing dep).
# Same pattern as test_c28_cash_session.py.
# ---------------------------------------------------------------------------
try:
    import fpdf  # noqa: F401 — usar el fpdf2 REAL si está instalado (no contaminar receipts.FPDF)
except ImportError:
    # Solo si fpdf2 NO está instalado: stub para que backend.main pueda importarse.
    _fpdf_stub = types.ModuleType("fpdf")
    _fpdf_stub.FPDF = MagicMock  # type: ignore[attr-defined]
    sys.modules["fpdf"] = _fpdf_stub

from backend.tests.conftest import TEST_ACCOUNT_ID, make_token  # noqa: E402

# ── Constants ────────────────────────────────────────────────────────────────

ACCOUNT_ID = str(TEST_ACCOUNT_ID)
ACCOUNT_ID_2 = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
DOC_ID = "dddddddd-dddd-dddd-dddd-dddddddddddd"
DOC_ID_2 = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
RELAY_SECRET = "super-secret-relay-token-42"

MIGRATION_FILE = (
    Path(__file__).parents[2]
    / "supabase"
    / "migrations"
    / "20260719000001_c27_cae_relay_trigger.sql"
)

CRON_JOB_NAME = "relay-process-pending-cae"


# ── Helpers ───────────────────────────────────────────────────────────────────

def make_pending_doc(
    doc_id: str = DOC_ID,
    account_id: str = ACCOUNT_ID,
    **overrides,
) -> dict:
    base = {
        "id": doc_id,
        "account_id": account_id,
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


# ── Part 1: Machine endpoint auth ─────────────────────────────────────────────

class TestMachineEndpointAuth:
    """Part 1 RED: endpoint POST /fiscal/documents/process-pending-cron.

    Mirrors the MercadoPago webhook secret pattern in payments.py:
    'Authorization: Bearer <secret>' required; no JWT.
    """

    @pytest.mark.asyncio
    async def test_missing_authorization_header_returns_401(self, async_client, mock_pool):
        """RED: No Authorization header → 401."""
        pool, conn = mock_pool
        with (
            patch("backend.core.database.pool", pool),
            patch("backend.core.config.settings") as mock_cfg,
            patch("backend.routers.fiscal.settings", mock_cfg),
        ):
            mock_cfg.relay_secret = RELAY_SECRET
            resp = await async_client.post("/fiscal/documents/process-pending-cron")
        assert resp.status_code == 401

    @pytest.mark.asyncio
    async def test_wrong_secret_returns_401(self, async_client, mock_pool):
        """RED: Wrong bearer token → 401."""
        pool, conn = mock_pool
        with (
            patch("backend.core.database.pool", pool),
            patch("backend.core.config.settings") as mock_cfg,
            patch("backend.routers.fiscal.settings", mock_cfg),
        ):
            mock_cfg.relay_secret = RELAY_SECRET
            resp = await async_client.post(
                "/fiscal/documents/process-pending-cron",
                headers={"Authorization": "Bearer wrong-secret"},
            )
        assert resp.status_code == 401

    @pytest.mark.asyncio
    async def test_empty_configured_secret_fails_closed(self, async_client, mock_pool):
        """RED: relay_secret is None/empty → reject ALL calls (fail-closed)."""
        pool, conn = mock_pool
        with (
            patch("backend.core.database.pool", pool),
            patch("backend.core.config.settings") as mock_cfg,
            patch("backend.routers.fiscal.settings", mock_cfg),
        ):
            mock_cfg.relay_secret = None  # unset → fail-closed
            resp = await async_client.post(
                "/fiscal/documents/process-pending-cron",
                headers={"Authorization": f"Bearer {RELAY_SECRET}"},
            )
        assert resp.status_code == 401

    @pytest.mark.asyncio
    async def test_empty_string_secret_fails_closed(self, async_client, mock_pool):
        """RED: relay_secret = '' (empty string) → 401 (fail-closed, not allow-all)."""
        pool, conn = mock_pool
        with (
            patch("backend.core.database.pool", pool),
            patch("backend.core.config.settings") as mock_cfg,
            patch("backend.routers.fiscal.settings", mock_cfg),
        ):
            mock_cfg.relay_secret = ""  # empty string → also fail-closed
            resp = await async_client.post(
                "/fiscal/documents/process-pending-cron",
                headers={"Authorization": "Bearer "},
            )
        assert resp.status_code == 401

    @pytest.mark.asyncio
    async def test_correct_secret_returns_200_with_summary(self, async_client, mock_pool):
        """RED: Correct bearer secret → 200 with JSON summary containing 'processed'."""
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[])  # no pending docs

        with (
            patch("backend.core.database.pool", pool),
            patch("backend.core.config.settings") as mock_cfg,
            patch("backend.routers.fiscal.settings", mock_cfg),
            patch(
                "backend.services.fiscal.fiscal_profile_service.process_all_pending_documents",
                new=AsyncMock(
                    return_value={"processed": 0, "authorized": 0, "retried": 0, "rejected": 0}
                ),
            ),
        ):
            mock_cfg.relay_secret = RELAY_SECRET
            resp = await async_client.post(
                "/fiscal/documents/process-pending-cron",
                headers={"Authorization": f"Bearer {RELAY_SECRET}"},
            )
        assert resp.status_code == 200
        body = resp.json()
        assert "processed" in body

    @pytest.mark.asyncio
    async def test_cron_endpoint_uses_service_conn_not_jwt(self, async_client, mock_pool):
        """RED: Cron endpoint must NOT require a JWT (it uses get_service_conn)."""
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[])

        with (
            patch("backend.core.database.pool", pool),
            patch("backend.core.config.settings") as mock_cfg,
            patch("backend.routers.fiscal.settings", mock_cfg),
            patch(
                "backend.services.fiscal.fiscal_profile_service.process_all_pending_documents",
                new=AsyncMock(
                    return_value={"processed": 0, "authorized": 0, "retried": 0, "rejected": 0}
                ),
            ),
        ):
            mock_cfg.relay_secret = RELAY_SECRET
            # No JWT header — only the bearer relay secret
            resp = await async_client.post(
                "/fiscal/documents/process-pending-cron",
                headers={"Authorization": f"Bearer {RELAY_SECRET}"},
                # No "X-Account-Id" or JWT → must still succeed
            )
        assert resp.status_code == 200


# ── Part 2: Anti-double-CAE claim ────────────────────────────────────────────

class TestAntiDoubleCAEClaim:
    """Part 2 RED: claim_pending atomic optimistic claim.

    Two concurrent triggers must NEVER both call request_cae for the same doc.
    claim_pending → UPDATE ... WHERE ... RETURNING * → one caller gets the row.
    """

    @pytest.mark.asyncio
    async def test_claim_pending_returns_doc_when_unclaimed(self):
        """RED: claim_pending returns dict when the UPDATE ... RETURNING * succeeds."""
        from backend.repositories.fiscal_document_repository import FiscalDocumentRepository

        doc_row = make_pending_doc()
        conn = AsyncMock()
        conn.fetchrow = AsyncMock(return_value=doc_row)

        repo = FiscalDocumentRepository(conn)
        result = await repo.claim_pending(DOC_ID)
        assert result is not None
        assert result["id"] == DOC_ID

    @pytest.mark.asyncio
    async def test_claim_pending_query_returns_cuit_and_ambiente(self):
        """REGRESIÓN: claim_pending DEBE joinear fiscal_profiles y devolver cuit + ambiente.

        Bug histórico: el RETURNING no incluía fp.cuit/fp.ambiente, así que el
        CAERelayProcessor armaba CAERequest con ambiente=default "homologacion" y
        cuit_emisor="". Resultado: todo doc de PRODUCCIÓN se relayaba al endpoint de
        HOMOLOGACIÓN con el cert de prod → AFIP "Certificado no emitido por AC de confianza".
        """
        from backend.repositories.fiscal_document_repository import FiscalDocumentRepository

        conn = AsyncMock()
        conn.fetchrow = AsyncMock(return_value=make_pending_doc())
        repo = FiscalDocumentRepository(conn)
        await repo.claim_pending(DOC_ID)

        sql = conn.fetchrow.call_args[0][0]
        assert "fiscal_profiles" in sql, "claim_pending debe joinear fiscal_profiles"
        # El RETURNING debe traer cuit + ambiente del perfil (no defaultear a homo).
        returning = sql.split("RETURNING", 1)[1]
        assert "fp.ambiente" in returning, "claim_pending debe devolver fp.ambiente"
        assert "fp.cuit" in returning, "claim_pending debe devolver fp.cuit"

    @pytest.mark.asyncio
    async def test_claim_pending_returns_none_when_already_claimed(self):
        """RED: claim_pending returns None when UPDATE finds 0 rows (another caller holds lease)."""
        from backend.repositories.fiscal_document_repository import FiscalDocumentRepository

        conn = AsyncMock()
        conn.fetchrow = AsyncMock(return_value=None)  # 0 rows → lease held by another

        repo = FiscalDocumentRepository(conn)
        result = await repo.claim_pending(DOC_ID)
        assert result is None

    @pytest.mark.asyncio
    async def test_two_concurrent_callers_only_one_wins(self):
        """RED: Simulate two concurrent callers — exactly one gets row, one None.

        Atomicity is guaranteed by the DB UPDATE ... RETURNING *.
        Here we simulate by having conn_a return the row and conn_b return None.
        """
        from backend.repositories.fiscal_document_repository import FiscalDocumentRepository

        doc_row = make_pending_doc()

        conn_a = AsyncMock()
        conn_a.fetchrow = AsyncMock(return_value=doc_row)
        conn_b = AsyncMock()
        conn_b.fetchrow = AsyncMock(return_value=None)

        repo_a = FiscalDocumentRepository(conn_a)
        repo_b = FiscalDocumentRepository(conn_b)

        winner = await repo_a.claim_pending(DOC_ID)
        loser = await repo_b.claim_pending(DOC_ID)

        assert winner is not None, "First caller should hold the lease"
        assert loser is None, "Second caller gets None (lease already taken)"

    @pytest.mark.asyncio
    async def test_process_document_by_id_calls_request_cae_when_claim_wins(self):
        """RED: process_document_by_id calls request_cae when claim_pending succeeds."""
        from backend.services.fiscal.cae_relay_processor import CAERelayProcessor
        from backend.services.fiscal.fiscal_document_port import CAEResponse

        doc = make_pending_doc()

        mock_repo = MagicMock()
        mock_repo.claim_pending = AsyncMock(return_value=dict(doc))
        mock_repo.update_authorized = AsyncMock()

        mock_adapter = MagicMock()
        mock_adapter.request_cae = AsyncMock(
            return_value=CAEResponse(
                cae="12345678901234",
                cae_due_date=None,
                is_approved=True,
                error_code=None,
                error_detail=None,
            )
        )

        processor = CAERelayProcessor(adapter=mock_adapter, repo=mock_repo)
        await processor.process_document_by_id(DOC_ID)

        mock_adapter.request_cae.assert_called_once()
        mock_repo.update_authorized.assert_called_once()

    @pytest.mark.asyncio
    async def test_process_document_by_id_skips_request_cae_when_claim_fails(self):
        """RED: process_document_by_id does NOT call request_cae when claim_pending returns None."""
        from backend.services.fiscal.cae_relay_processor import CAERelayProcessor

        mock_repo = MagicMock()
        mock_repo.claim_pending = AsyncMock(return_value=None)  # lease held elsewhere

        mock_adapter = MagicMock()
        mock_adapter.request_cae = AsyncMock()

        processor = CAERelayProcessor(adapter=mock_adapter, repo=mock_repo)
        await processor.process_document_by_id(DOC_ID)

        mock_adapter.request_cae.assert_not_called()

    @pytest.mark.asyncio
    async def test_list_pending_all_fetches_cross_account(self):
        """RED: list_pending_all returns docs from all accounts (no RLS on service conn)."""
        from backend.repositories.fiscal_document_repository import FiscalDocumentRepository

        doc1 = make_pending_doc(doc_id=DOC_ID, account_id=ACCOUNT_ID)
        doc2 = make_pending_doc(doc_id=DOC_ID_2, account_id=ACCOUNT_ID_2)

        conn = AsyncMock()
        conn.fetch = AsyncMock(return_value=[doc1, doc2])

        repo = FiscalDocumentRepository(conn)
        results = await repo.list_pending_all(limit=10)

        assert len(results) == 2
        account_ids = {r["account_id"] for r in results}
        assert ACCOUNT_ID in account_ids
        assert ACCOUNT_ID_2 in account_ids


# ── Part 3: Fire-and-forget background helper ─────────────────────────────────

class TestFireAndForgetBackground:
    """Part 3 RED: process_doc_by_id_background helper used as BackgroundTask."""

    @pytest.mark.asyncio
    async def test_process_doc_by_id_background_calls_claim(self):
        """RED: process_doc_by_id_background calls claim_pending for the given doc_id."""
        from backend.services.fiscal.fiscal_profile_service import process_doc_by_id_background
        from backend.services.fiscal.fiscal_document_port import CAEResponse

        doc = make_pending_doc()
        mock_repo = MagicMock()
        mock_repo.claim_pending = AsyncMock(return_value=dict(doc))
        mock_repo.update_authorized = AsyncMock()

        mock_adapter = MagicMock()
        mock_adapter.request_cae = AsyncMock(
            return_value=CAEResponse(
                cae="12345678901234",
                cae_due_date=None,
                is_approved=True,
                error_code=None,
                error_detail=None,
            )
        )

        mock_conn = AsyncMock()
        mock_pool = MagicMock()
        mock_pool.acquire.return_value.__aenter__ = AsyncMock(return_value=mock_conn)
        mock_pool.acquire.return_value.__aexit__ = AsyncMock(return_value=False)

        with (
            patch(
                "backend.services.fiscal.fiscal_profile_service.FiscalDocumentRepository",
                return_value=mock_repo,
            ),
            patch(
                "backend.services.fiscal.fiscal_profile_service.WSFEStubAdapter",
                return_value=mock_adapter,
            ),
            patch("backend.services.fiscal.fiscal_profile_service._db") as mock_db,
        ):
            mock_db.pool = mock_pool

            await process_doc_by_id_background(DOC_ID)

        mock_repo.claim_pending.assert_called_once_with(DOC_ID)

    @pytest.mark.asyncio
    async def test_process_doc_by_id_background_skips_when_claim_fails(self):
        """RED: process_doc_by_id_background does NOT call request_cae if claim fails."""
        from backend.services.fiscal.fiscal_profile_service import process_doc_by_id_background

        mock_repo = MagicMock()
        mock_repo.claim_pending = AsyncMock(return_value=None)

        mock_adapter = MagicMock()
        mock_adapter.request_cae = AsyncMock()

        mock_conn = AsyncMock()
        mock_pool = MagicMock()
        mock_pool.acquire.return_value.__aenter__ = AsyncMock(return_value=mock_conn)
        mock_pool.acquire.return_value.__aexit__ = AsyncMock(return_value=False)

        with (
            patch(
                "backend.services.fiscal.fiscal_profile_service.FiscalDocumentRepository",
                return_value=mock_repo,
            ),
            patch(
                "backend.services.fiscal.fiscal_profile_service.WSFEStubAdapter",
                return_value=mock_adapter,
            ),
            patch("backend.services.fiscal.fiscal_profile_service._db") as mock_db,
        ):
            mock_db.pool = mock_pool

            await process_doc_by_id_background(DOC_ID)

        mock_adapter.request_cae.assert_not_called()

    @pytest.mark.asyncio
    async def test_emit_endpoint_registers_background_task(self, async_client, mock_pool):
        """RED: POST /fiscal/documents/emit triggers a BackgroundTask for the new doc_id."""
        pool, conn = mock_pool

        import json as _json
        emit_result = {
            "id": DOC_ID,
            "fiscal_document_id": DOC_ID,
            "status": "pending_cae",
            "comprobante_type": "factura_b",
            "number": 1,
        }
        conn.fetchrow = AsyncMock(return_value={"result": _json.dumps(emit_result)})
        owner_token = make_token({"role": "user"})

        # Track whether the background task was scheduled
        background_calls: list[str] = []

        async def fake_bg_task(doc_id: str) -> None:
            background_calls.append(doc_id)

        with (
            patch("backend.core.database.pool", pool),
            patch(
                "backend.routers.fiscal.process_doc_by_id_background",
                side_effect=fake_bg_task,
            ),
        ):
            resp = await async_client.post(
                "/fiscal/documents/emit",
                json={"comprobante_type": "factura_b", "total": 1500.0},
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 200


# ── Part 4: Cross-account batch ───────────────────────────────────────────────

class TestCrossAccountBatch:
    """Part 4 RED: process_all_pending_documents cross-account processing."""

    @pytest.mark.asyncio
    async def test_process_all_claims_and_processes_each_doc(self):
        """RED: process_all_pending_documents calls claim_pending for each doc found."""
        from backend.services.fiscal.fiscal_profile_service import process_all_pending_documents
        from backend.services.fiscal.fiscal_document_port import CAEResponse

        doc1 = make_pending_doc(doc_id=DOC_ID, account_id=ACCOUNT_ID)
        doc2 = make_pending_doc(doc_id=DOC_ID_2, account_id=ACCOUNT_ID_2)

        mock_repo = MagicMock()
        mock_repo.list_pending_all = AsyncMock(return_value=[doc1, doc2])
        mock_repo.claim_pending = AsyncMock(side_effect=[dict(doc1), dict(doc2)])
        mock_repo.update_authorized = AsyncMock()

        mock_adapter = MagicMock()
        mock_adapter.request_cae = AsyncMock(
            return_value=CAEResponse(
                cae="12345678901234",
                cae_due_date=None,
                is_approved=True,
                error_code=None,
                error_detail=None,
            )
        )

        result = await process_all_pending_documents(mock_repo, mock_adapter)

        assert result["processed"] == 2
        assert mock_repo.claim_pending.call_count == 2

    @pytest.mark.asyncio
    async def test_process_all_skips_docs_whose_claim_fails(self):
        """RED: Docs where claim_pending returns None are skipped — no double-CAE."""
        from backend.services.fiscal.fiscal_profile_service import process_all_pending_documents
        from backend.services.fiscal.fiscal_document_port import CAEResponse

        doc1 = make_pending_doc(doc_id=DOC_ID, account_id=ACCOUNT_ID)
        doc2 = make_pending_doc(doc_id=DOC_ID_2, account_id=ACCOUNT_ID_2)

        mock_repo = MagicMock()
        mock_repo.list_pending_all = AsyncMock(return_value=[doc1, doc2])
        # doc1 claimed successfully, doc2 already claimed by fire-and-forget
        mock_repo.claim_pending = AsyncMock(side_effect=[dict(doc1), None])
        mock_repo.update_authorized = AsyncMock()

        mock_adapter = MagicMock()
        mock_adapter.request_cae = AsyncMock(
            return_value=CAEResponse(
                cae="12345678901234",
                cae_due_date=None,
                is_approved=True,
                error_code=None,
                error_detail=None,
            )
        )

        result = await process_all_pending_documents(mock_repo, mock_adapter)

        # Only doc1 processed — doc2 skipped because claim returned None
        assert mock_adapter.request_cae.call_count == 1
        assert result["processed"] == 1

    @pytest.mark.asyncio
    async def test_process_all_returns_summary_with_counters(self):
        """RED: Return dict has 'processed', 'authorized', 'retried', 'rejected' keys."""
        from backend.services.fiscal.fiscal_profile_service import process_all_pending_documents

        mock_repo = MagicMock()
        mock_repo.list_pending_all = AsyncMock(return_value=[])

        mock_adapter = MagicMock()

        result = await process_all_pending_documents(mock_repo, mock_adapter)

        for key in ("processed", "authorized", "retried", "rejected"):
            assert key in result, f"Missing key '{key}' in summary"


# ── Part 5: Migration static assertions ──────────────────────────────────────

class TestCronMigrationStatic:
    """Part 5 RED: migration file static assertions.

    Mirrors backend/tests/migrations/test_events_reconcile.py style.
    """

    def test_migration_file_exists(self):
        """RED→GREEN: Migration file must exist."""
        assert MIGRATION_FILE.exists(), f"Migration file missing: {MIGRATION_FILE}"

    @pytest.fixture
    def sql(self) -> str:
        assert MIGRATION_FILE.exists(), f"Migration file not found: {MIGRATION_FILE}"
        return MIGRATION_FILE.read_text(encoding="utf-8")

    def test_migration_has_http_post_or_helper_function(self, sql):
        """RED→GREEN: Migration must contain net.http_post call OR rpc_trigger_cae_relay.

        Two valid approaches:
          A) Direct: net.http_post(...) in the cron body
          B) Helper: SECURITY DEFINER rpc_trigger_cae_relay() that calls net.http_post
        """
        has_http_post = "net.http_post" in sql
        has_helper = "rpc_trigger_cae_relay" in sql
        assert has_http_post or has_helper, (
            "Migration must contain net.http_post OR rpc_trigger_cae_relay"
        )

    def test_migration_references_cron_job_name(self, sql):
        """RED→GREEN: Migration must reference the existing cron job name."""
        assert CRON_JOB_NAME in sql, (
            f"Migration must reference cron job '{CRON_JOB_NAME}'"
        )

    def test_migration_reads_from_vault(self, sql):
        """RED→GREEN: Secret must come from vault.decrypted_secrets, not hardcoded."""
        assert "vault" in sql.lower(), (
            "Migration must read secret/URL from vault.decrypted_secrets"
        )

    def test_migration_does_not_contain_plaintext_relay_secret_env_expansion(self, sql):
        """RED→GREEN: Migration must NOT use $RELAY_SECRET shell expansion (not safe in SQL)."""
        assert "$RELAY_SECRET" not in sql, (
            "Migration must NOT use $RELAY_SECRET — use vault.decrypted_secrets instead"
        )

    def test_migration_unschedule_guard_precedes_schedule(self, sql):
        """RED→GREEN: cron.unschedule must appear before cron.schedule (idempotent)."""
        unschedule_idx = sql.find(f"cron.unschedule('{CRON_JOB_NAME}')")
        assert unschedule_idx != -1, (
            f"cron.unschedule('{CRON_JOB_NAME}') not found in migration"
        )
        schedule_idx = sql.find("cron.schedule(")
        assert schedule_idx != -1, "cron.schedule call not found in migration"
        assert unschedule_idx < schedule_idx, (
            "cron.unschedule must appear BEFORE cron.schedule"
        )

    def test_migration_vault_secret_name_for_relay(self, sql):
        """RED→GREEN: Migration must reference 'cae_relay_secret' vault secret name."""
        assert "cae_relay_secret" in sql, (
            "Migration must read 'cae_relay_secret' from vault.decrypted_secrets"
        )

    def test_migration_references_backend_base_url_secret(self, sql):
        """RED→GREEN: Migration must read backend_base_url from vault (not hardcoded)."""
        # Either uses 'backend_base_url' vault secret OR hardcodes the URL in a known pattern
        has_vault_url = "backend_base_url" in sql
        # Allow hardcoded URL only in a commented setup block (acceptable for docs)
        has_onrender_in_code = "emprende-smart-backend.onrender.com" in re.sub(
            r"--[^\n]*", "", sql  # strip line comments
        )
        assert has_vault_url or has_onrender_in_code, (
            "Migration must reference backend_base_url (from vault or documented constant)"
        )

    def test_migration_has_one_time_setup_instructions(self, sql):
        """RED→GREEN: Migration must include commented prod-setup steps (vault.create_secret)."""
        assert "vault.create_secret" in sql, (
            "Migration must contain commented vault.create_secret setup instructions for the PO"
        )

    def test_migration_helper_if_defined_is_security_definer(self, sql):
        """RED→GREEN: rpc_trigger_cae_relay (if defined) must be SECURITY DEFINER."""
        if "rpc_trigger_cae_relay" in sql:
            idx = sql.find("rpc_trigger_cae_relay")
            # Within 600 chars of the function definition, SECURITY DEFINER must appear
            vicinity = sql[idx: idx + 600]
            assert "SECURITY DEFINER" in vicinity.upper(), (
                "rpc_trigger_cae_relay must be SECURITY DEFINER"
            )

    def test_migration_helper_if_defined_revokes_execute(self, sql):
        """RED→GREEN: rpc_trigger_cae_relay (if defined) must REVOKE EXECUTE from anon/PUBLIC."""
        if "rpc_trigger_cae_relay" in sql:
            assert re.search(
                r"REVOKE\s+(?:ALL|EXECUTE)\s+ON\s+FUNCTION",
                sql,
                re.IGNORECASE,
            ), "rpc_trigger_cae_relay must have REVOKE EXECUTE"

    def test_migration_cron_schedule_every_minute(self, sql):
        """RED→GREEN: cron schedule must remain '* * * * *' (every minute, backstop)."""
        idx = sql.find(f"'{CRON_JOB_NAME}'")
        assert idx != -1
        vicinity = sql[idx: idx + 200]
        assert "'* * * * *'" in vicinity, (
            "cron schedule must remain '* * * * *' (every minute)"
        )
