"""
fiscal-emision-segura (governance CRÍTICO) — candados de los tres hallazgos.

Contexto (por qué existe este archivo):
  El disparo inmediato de `POST /fiscal/documents/emit*` instanciaba el
  **stub** del adapter (`WSFEStubAdapter`), que devuelve `is_approved=True` con
  un CAE inventado. Lo único que lo desarmaba era un `AttributeError` de tipo
  (`uuid.UUID` no tiene `.encode()`). Si ese camino corriera, un CAE ficticio
  quedaría escrito en un comprobante de PRODUCCIÓN y el documento pasaría a
  `authorized`, que es estado terminal: el cron nunca lo volvería a mirar.

Grupos:
  G1 — se retiran los caminos de emisión que no se pueden defender:
       el disparo inmediato y `POST /fiscal/documents/process-pending`
       (4.º camino, con adapter REAL y sin `claim_pending`).
  G2 — defensa en profundidad: el stub se niega en `produccion` y el processor
       no llama a un adapter que no sea el real para un doc de producción.
       Ninguno de los dos delega en el otro ("un guard que delega no es guard").
  G3 — el número que ARCA autoriza se PERSISTE (hoy se descarta).
  G4 — un envío a ARCA no confirmado CONGELA el documento en vez de
       reintentarse a ciegas pidiendo un número nuevo (doble factura real).
  G5 — consumidor final (DocTipo 99) en el pago de suscripción.

El único camino de emisión que queda es el cron
(`POST /fiscal/documents/process-pending-cron`).
"""
from __future__ import annotations

import datetime
import json
import sys
import types
import uuid
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Stub fpdf BEFORE any import of backend.main (dep faltante pre-existente).
# Mismo patrón que test_c27_cae_relay_trigger.py / test_c28_cash_session.py.
# ---------------------------------------------------------------------------
try:
    import fpdf  # noqa: F401
except ImportError:
    _fpdf_stub = types.ModuleType("fpdf")
    _fpdf_stub.FPDF = MagicMock  # type: ignore[attr-defined]
    sys.modules["fpdf"] = _fpdf_stub

from backend.tests.conftest import TEST_ACCOUNT_ID, make_token  # noqa: E402

ACCOUNT_ID = str(TEST_ACCOUNT_ID)
DOC_ID = "dddddddd-dddd-dddd-dddd-dddddddddddd"


# ── Helpers ───────────────────────────────────────────────────────────────────

def make_pending_doc(**overrides) -> dict:
    """Doc `pending_cae` con la forma que devuelve rpc_fiscal_document_claim_pending."""
    base = {
        "id": DOC_ID,
        "account_id": ACCOUNT_ID,
        "fiscal_profile_id": "pppppppp-pppp-pppp-pppp-pppppppppppp",
        "point_of_sale_id": "vvvvvvvv-vvvv-vvvv-vvvv-vvvvvvvvvvvv",
        "comprobante_type": "factura_c",
        "punto_de_venta": 3,
        "number": 7,
        "total": 1500.0,
        "status": "pending_cae",
        "cae": None,
        "cae_due_date": None,
        "attempts": 0,
        "next_attempt_at": None,
        "last_error": None,
        "cuit": "20123456789",
        "ambiente": "homologacion",
        "cae_submit_unconfirmed_at": None,
        "arca_requested_number": None,
    }
    base.update(overrides)
    return base


def make_repo() -> MagicMock:
    repo = MagicMock()
    repo.update_authorized = AsyncMock()
    repo.update_rejected = AsyncMock()
    repo.update_retry = AsyncMock()
    repo.freeze_unconfirmed = AsyncMock()
    return repo


# ═══════════════════════════════════════════════════════════════════════════
# G1 — No queda ningún camino de emisión fuera del cron
# ═══════════════════════════════════════════════════════════════════════════

class TestNoHayDisparoInmediato:
    """1.1-1.3: ni `emit` ni `emit-subscription-payment` programan trabajo de
    fondo, y el 4.º camino de emisión (`process-pending`) ya no existe."""

    @pytest.mark.asyncio
    async def test_emit_no_programa_background_task(self, async_client, mock_pool):
        """POST /fiscal/documents/emit NO programa ninguna BackgroundTask.

        Falla antes de G1: routers/fiscal.py:279 hacía
        `background_tasks.add_task(process_doc_by_id_background, doc_id)`.
        """
        pool, conn = mock_pool
        emit_result = {
            "id": DOC_ID,
            "fiscal_document_id": DOC_ID,
            "status": "pending_cae",
            "comprobante_type": "factura_b",
            "number": 1,
        }
        conn.fetchrow = AsyncMock(return_value={"result": json.dumps(emit_result)})
        owner_token = make_token({"role": "user"})

        with (
            patch("backend.core.database.pool", pool),
            patch("starlette.background.BackgroundTasks.add_task") as add_task,
        ):
            resp = await async_client.post(
                "/fiscal/documents/emit",
                json={"comprobante_type": "factura_b", "total": 1500.0},
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 200, resp.text
        add_task.assert_not_called()

    @pytest.mark.asyncio
    async def test_emit_subscription_no_programa_background_task(self, async_client, mock_pool):
        """POST /fiscal/documents/emit-subscription-payment tampoco programa nada.

        Falla antes de G1: routers/fiscal.py:307.
        """
        pool, conn = mock_pool
        rpc_result = {
            "fiscal_document_id": DOC_ID,
            "status": "pending_cae",
            "comprobante_type": "factura_c",
            "number": 2,
            "total": 12000.0,
        }
        conn.fetchrow = AsyncMock(
            side_effect=[None, {"result": json.dumps(rpc_result)}]
        )
        conn.fetchval = AsyncMock(return_value="admin")
        admin_token = make_token({"role": "admin"})

        with (
            patch("backend.core.database.pool", pool),
            patch("starlette.background.BackgroundTasks.add_task") as add_task,
        ):
            resp = await async_client.post(
                "/fiscal/documents/emit-subscription-payment",
                json={
                    "receipt_id": "receipt-001",
                    "receptor_doc_tipo": 80,
                    "receptor_doc_nro": "20422662457",
                },
                headers={"Authorization": f"Bearer {admin_token}"},
            )

        assert resp.status_code == 201, resp.text
        add_task.assert_not_called()

    @pytest.mark.asyncio
    async def test_process_pending_endpoint_no_existe(self, async_client, mock_pool):
        """POST /fiscal/documents/process-pending → 404.

        Era el 4.º camino de emisión: construía el adapter REAL
        (build_cae_adapter_from_settings) y NO llamaba claim_pending. Sin caller
        en el frontend, pero expuesto a cualquier JWT válido.
        """
        pool, _conn = mock_pool
        token = make_token({"role": "user"})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/fiscal/documents/process-pending",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 404, (
            f"El endpoint sigue existiendo (status {resp.status_code}): {resp.text}"
        )

    def test_no_queda_sujeto_del_disparo_inmediato(self):
        """El helper del disparo inmediato y el del 4.º camino ya no existen.

        Candado estructural: sin esto, alguien podría dejar la función viva
        (y con el stub adentro) aunque ningún endpoint la llame hoy.
        """
        from backend.services.fiscal import fiscal_profile_service as svc

        assert not hasattr(svc, "process_doc_by_id_background"), (
            "process_doc_by_id_background sigue vivo: es el que instanciaba "
            "WSFEStubAdapter() a mano y podía escribir un CAE falso."
        )
        assert not hasattr(svc, "process_pending_documents"), (
            "process_pending_documents sigue vivo: emitía sin claim_pending."
        )

    def test_el_cron_sigue_siendo_el_camino_de_emision(self):
        """1.5 TRIANGULACIÓN: el batch cross-account del cron sigue intacto."""
        from backend.services.fiscal import fiscal_profile_service as svc

        assert hasattr(svc, "process_all_pending_documents"), (
            "process_all_pending_documents es el ÚNICO camino de emisión que "
            "debe quedar — no se toca."
        )
