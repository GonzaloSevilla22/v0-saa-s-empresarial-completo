"""
fiscal-receptor-iva-relay — emit_pending_cae propaga receptor + IVA a la RPC.

TDD RED->GREEN->TRIANGULATE: el service debe pasar receptor_doc_tipo/nro + neto/iva
a rpc_emit_pending_cae. Hoy solo pasa comprobante_type/total/client_id/point_of_sale_id.

Gate CI: python -m pytest backend/tests -m "not integration"
Spec ref: openspec/changes/fiscal-receptor-iva-relay/specs/afip-fiscal-document/spec.md
  Scenario: La emisión persiste receptor e IVA
Design ref: D1
"""
from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock

import pytest

from backend.schemas.fiscal import EmitPendingCAERequest
from backend.services.fiscal.fiscal_profile_service import emit_pending_cae


def _conn():
    conn = MagicMock()
    conn.fetchrow = AsyncMock(
        return_value={"result": {"fiscal_document_id": "x", "status": "pending_cae"}}
    )
    return conn


class TestEmitPendingCaeThreadsReceptor:
    @pytest.mark.asyncio
    async def test_threads_receptor_and_iva_to_rpc(self):
        conn = _conn()
        payload = EmitPendingCAERequest(
            comprobante_type="factura_b",
            total=1210.0,
            receptor_doc_tipo=80,
            receptor_doc_nro="20999999996",
            neto=1000.0,
            iva_amount=210.0,
            iva_alicuota_id=5,
        )

        await emit_pending_cae(conn, {"role": "user"}, "acc-id", payload)

        params = conn.fetchrow.call_args[0][1:]  # [0] es el SQL
        assert 80 in params, "receptor_doc_tipo debe viajar a la RPC"
        assert "20999999996" in params, "receptor_doc_nro debe viajar a la RPC"
        assert 1000.0 in params, "neto debe viajar a la RPC"
        assert 210.0 in params, "iva_amount debe viajar a la RPC"
        assert 5 in params, "iva_alicuota_id debe viajar a la RPC"

    @pytest.mark.asyncio
    async def test_without_receptor_still_emits(self):
        """TRIANGULATE: sin receptor (consumidor final) sigue funcionando."""
        conn = _conn()
        payload = EmitPendingCAERequest(comprobante_type="factura_c", total=1000.0)

        result = await emit_pending_cae(conn, {"role": "user"}, "acc-id", payload)

        assert result["status"] == "pending_cae"
