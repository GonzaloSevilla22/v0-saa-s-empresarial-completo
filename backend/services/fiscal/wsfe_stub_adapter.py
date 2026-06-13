"""
C-27 v21-fiscal-profile — WSFEStubAdapter: implementación ficticia del port WSFE.

Retorna un CAE determinístico basado en el fiscal_document_id.
Sin I/O, sin red, sin SOAP. Usada en todos los tests de la suite y en dev.

Design ref: D4 — stub inyectable por DI.
"""
from __future__ import annotations

import datetime
import hashlib


from backend.services.fiscal.fiscal_document_port import CAERequest, CAEResponse, FiscalDocumentPort


class WSFEStubAdapter(FiscalDocumentPort):
    """Stub del adaptador WSFE.

    Devuelve un CAE ficticio pero determinístico (mismo fiscal_document_id → mismo CAE).
    No toca la red. Usado en:
      - tests (unit y de endpoint)
      - entorno de desarrollo local
      - relay processor cuando el adaptador real no está configurado
    """

    _CAE_LENGTH = 14  # AFIP CAE real tiene 14 dígitos

    async def request_cae(self, invoice_data: CAERequest) -> CAEResponse:
        """Retorna un CAEResponse ficticio determinístico.

        El CAE se deriva del fiscal_document_id vía SHA-256 (los primeros 14 dígitos).
        La fecha de vencimiento es 10 días a partir de hoy (convención del stub).
        """
        fake_cae = self._derive_cae(invoice_data.fiscal_document_id)
        due_date = datetime.date.today() + datetime.timedelta(days=10)

        return CAEResponse(
            cae=fake_cae,
            cae_due_date=due_date,
            is_approved=True,
            error_code=None,
            error_detail=None,
        )

    @staticmethod
    def _derive_cae(document_id: str) -> str:
        """Deriva un CAE ficticio de 14 dígitos determinístico a partir del document_id."""
        digest = hashlib.sha256(document_id.encode()).hexdigest()
        # Extraer 14 dígitos numéricos del digest (tomando los primeros chars hex y convirtiendo)
        numeric = "".join(c for c in digest if c.isdigit())
        # Si hay menos de 14 dígitos numéricos, rellenar con dígitos del hash int
        if len(numeric) < WSFEStubAdapter._CAE_LENGTH:
            hash_int = int(digest, 16)
            numeric = str(hash_int)
        return numeric[: WSFEStubAdapter._CAE_LENGTH]
