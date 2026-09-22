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

    # fiscal-emision-segura (G2, 2026-09-22): capa 1 del guard de ambiente.
    _PRODUCTION_REFUSAL_CODE = "STUB_FORBIDDEN_IN_PRODUCTION"

    async def request_cae(self, invoice_data: CAERequest) -> CAEResponse:
        """Retorna un CAEResponse ficticio determinístico.

        El CAE se deriva del fiscal_document_id vía SHA-256 (los primeros 14 dígitos).
        La fecha de vencimiento es 10 días a partir de hoy (convención del stub).

        fiscal-emision-segura (G2): si el comprobante es de ambiente
        `produccion`, el stub se NIEGA — nunca devuelve un CAE. Un CAE ficticio
        en un comprobante real es el error que el dominio no puede cometer, y
        `authorized` es estado terminal: nadie lo corrige después. Esta capa
        cubre cualquier CALLER futuro que construya el stub a mano (como hacía
        el disparo inmediato que G1 retiró) y NO delega en el guard del
        processor — la capa 2 cubre cualquier ADAPTER futuro, y ninguna de las
        dos se apoya en la otra.
        """
        if invoice_data.ambiente == "produccion":
            return CAEResponse(
                cae=None,
                cae_due_date=None,
                is_approved=False,
                error_code=self._PRODUCTION_REFUSAL_CODE,
                error_detail=(
                    "El stub del adapter WSFE se niega a responder por un comprobante "
                    "de ambiente 'produccion': devolvería un CAE inventado y el "
                    "documento quedaría 'authorized' (estado terminal) sin existir en "
                    "ARCA. Configurá el certificado de plataforma "
                    "(AFIP_PLATFORM_CERT/KEY/CUIT) para que el relay use el adapter real."
                ),
            )

        fake_cae = self._derive_cae(invoice_data.fiscal_document_id)
        due_date = datetime.date.today() + datetime.timedelta(days=10)

        return CAEResponse(
            cae=fake_cae,
            cae_due_date=due_date,
            is_approved=True,
            error_code=None,
            error_detail=None,
            # G3: el stub nunca diverge del número local (no habla con ARCA, así
            # que no tiene otro número que informar).
            number=invoice_data.number,
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
