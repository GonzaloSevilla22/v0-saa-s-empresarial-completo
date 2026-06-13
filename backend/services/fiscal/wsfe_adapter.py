"""
C-27 v21-fiscal-profile — WSFEAdapter: adaptador real WSAA + WSFEv1.

Implementa FiscalDocumentPort contra los web services de AFIP/ARCA.
Resuelve el ambiente (homologacion|produccion) desde el perfil de la cuenta (D2).
Lee el certificado del bucket privado afip-certs server-side (D7 — única excepción
de service_role en el proyecto: lectura del cert para firmar WSAA).

Dependencia: zeep (SOAP client). No incluido en requirements.txt de prod por defecto;
se activa cuando el usuario sube su certificado real (trámite del usuario, PA-22).

NOTA: Esta clase NO se carga en el gate de CI. Los tests con el SOAP mockeado
están en test_c27_wsfe_adapter.py; los de integración real van marcados con
@pytest.mark.integration y excluidos del gate (homologación intermitente).

Design refs: D4 (port/adapter ACL), D7 (cert server-side), PA-22 (homologación).
"""
from __future__ import annotations

import datetime
import logging

from backend.services.fiscal.fiscal_document_port import CAERequest, CAEResponse, FiscalDocumentPort

logger = logging.getLogger(__name__)

# URLs de AFIP/ARCA (ambiente resuelto desde el perfil)
_WSAA_URLS = {
    "homologacion": "https://wsaahomo.afip.gov.ar/ws/services/LoginCms?WSDL",
    "produccion":   "https://wsaa.afip.gov.ar/ws/services/LoginCms?WSDL",
}
_WSFEV1_URLS = {
    "homologacion": "https://wswhomo.afip.gov.ar/wsfev1/service.asmx?WSDL",
    "produccion":   "https://servicios1.afip.gov.ar/wsfev1/service.asmx?WSDL",
}

# Mapping de comprobante_type a código AFIP (CbteTipo)
_COMPROBANTE_AFIP_CODE = {
    "factura_a": 1,
    "factura_b": 6,
    "factura_c": 11,
    "nota_debito_a": 2,
    "nota_credito_a": 3,
    "nota_debito_b": 7,
    "nota_credito_b": 8,
}


class WSFEAdapter(FiscalDocumentPort):
    """Adaptador real WSAA + WSFEv1 para obtener el CAE de AFIP/ARCA.

    El ambiente (homologacion|produccion) se resuelve desde invoice_data.ambiente
    (que proviene de fiscal_profiles.ambiente de la cuenta), no de una env var global (D2).

    El certificado se lee desde el bucket privado afip-certs server-side (D7).
    La lectura usa el supabase client con service_role (única excepción del proyecto
    para job administrativo aislado — DEC-13).

    Para inyectar en tests: mockear el método _get_wsaa_token y _call_wsfe.
    """

    def __init__(self, supabase_service_client=None):
        """
        Args:
            supabase_service_client: cliente Supabase con service_role para leer el cert.
                Si es None, se crea lazily en el primer uso.
        """
        self._service_client = supabase_service_client

    async def request_cae(self, invoice_data: CAERequest) -> CAEResponse:
        """Solicita el CAE a AFIP vía WSAA + WSFEv1.

        Flujo:
          1. Leer el certificado del bucket privado (service_role, D7).
          2. Obtener el ticket de acceso WSAA (TA).
          3. Llamar WSFEv1.FECAESolicitar con los datos del comprobante.
          4. Retornar CAEResponse normalizado.
        """
        try:
            # 1. Obtener ticket de acceso WSAA
            token, sign = await self._get_wsaa_token(invoice_data)

            # 2. Llamar WSFEv1
            result = await self._call_wsfe(invoice_data, token, sign)
            return result

        except Exception as exc:
            logger.warning(
                "WSFEAdapter.request_cae error for doc %s: %s",
                invoice_data.fiscal_document_id,
                exc,
            )
            return CAEResponse(
                cae=None,
                cae_due_date=None,
                is_approved=False,
                error_code="WSFE_ERROR",
                error_detail=str(exc),
            )

    async def _get_wsaa_token(self, invoice_data: CAERequest) -> tuple[str, str]:
        """Obtiene el ticket de acceso WSAA (token + sign).

        Lee el certificado del bucket privado y firma la TRA (Ticket de Requerimiento
        de Acceso) con el servicio wsfe.

        Returns:
            (token, sign) — credenciales para autenticar en WSFEv1.

        Raises:
            ImportError: si zeep no está instalado.
            Exception: si el cert no existe o WSAA no responde.
        """
        try:
            # zeep es opcional — solo se instala cuando el usuario necesita el adapter real
            import zeep  # noqa: F401
        except ImportError as e:
            raise ImportError(
                "El paquete 'zeep' es requerido para el adaptador WSFE real. "
                "Instalalo con: pip install zeep"
            ) from e

        # Leer cert del bucket privado (D7 — service_role aislado)
        cert_path = f"{invoice_data.account_id}/afip.crt"
        key_path  = f"{invoice_data.account_id}/afip.key"

        cert_content = await self._read_cert_from_storage(cert_path)
        key_content  = await self._read_cert_from_storage(key_path)

        # Firmar TRA con el cert y obtener CMS
        cms = self._sign_tra(cert_content, key_content, invoice_data.ambiente)

        # Llamar WSAA
        wsaa_url = _WSAA_URLS[invoice_data.ambiente]
        token, sign = await self._call_wsaa(wsaa_url, cms)
        return token, sign

    async def _read_cert_from_storage(self, path: str) -> bytes:
        """Lee un objeto del bucket privado afip-certs usando service_role (D7)."""
        if self._service_client is None:
            raise RuntimeError(
                "WSFEAdapter requiere un cliente Supabase con service_role para leer el certificado."
            )
        # Supabase Storage download
        response = self._service_client.storage.from_("afip-certs").download(path)
        return response

    def _sign_tra(self, cert: bytes, key: bytes, ambiente: str) -> str:
        """Firma la TRA (CMS PKCS#7) con el certificado AFIP.

        Usa cryptography + OpenSSL para firmar. Retorna el CMS en base64.
        """
        from cryptography.hazmat.primitives import serialization, hashes
        from cryptography.hazmat.primitives.asymmetric import padding
        from cryptography.x509 import load_pem_x509_certificate
        from cryptography.hazmat.primitives.serialization import load_pem_private_key
        import base64
        import datetime as dt

        # Generar TRA XML
        now = dt.datetime.now(dt.timezone.utc)
        expiry = now + dt.timedelta(minutes=10)
        tra_xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<loginTicketRequest version="1.0">
  <header>
    <uniqueId>{int(now.timestamp())}</uniqueId>
    <generationTime>{now.isoformat()}</generationTime>
    <expirationTime>{expiry.isoformat()}</expirationTime>
  </header>
  <service>wsfe</service>
</loginTicketRequest>"""

        # Firmar con PKCS7
        from cryptography.hazmat.primitives.serialization.pkcs7 import (
            PKCS7SignatureBuilder,
        )
        from cryptography.hazmat.primitives.serialization import Encoding

        private_key = load_pem_private_key(key, password=None)
        certificate = load_pem_x509_certificate(cert)

        signed = (
            PKCS7SignatureBuilder()
            .set_data(tra_xml.encode())
            .add_signer(certificate, private_key, hashes.SHA256())
            .sign(Encoding.DER, [])
        )
        return base64.b64encode(signed).decode()

    async def _call_wsaa(self, wsaa_url: str, cms: str) -> tuple[str, str]:
        """Llama al web service WSAA para obtener el ticket de acceso."""
        import zeep

        client = zeep.Client(wsaa_url)
        response = client.service.loginCms(in0=cms)
        # Parsear el TA XML
        import xml.etree.ElementTree as ET
        root = ET.fromstring(response)
        credentials = root.find("credentials")
        token = credentials.find("token").text
        sign  = credentials.find("sign").text
        return token, sign

    async def _call_wsfe(
        self,
        invoice_data: CAERequest,
        token: str,
        sign: str,
    ) -> CAEResponse:
        """Llama a WSFEv1.FECAESolicitar y retorna CAEResponse normalizado."""
        import zeep

        wsfev1_url = _WSFEV1_URLS[invoice_data.ambiente]
        client = zeep.Client(wsfev1_url)

        cbte_tipo = _COMPROBANTE_AFIP_CODE.get(invoice_data.comprobante_type, 6)
        fecha = (invoice_data.fecha_comprobante or datetime.date.today()).strftime("%Y%m%d")

        auth = {
            "Token": token,
            "Sign": sign,
            "Cuit": int(invoice_data.cuit_emisor.replace("-", "")),
        }

        request_body = {
            "Auth": auth,
            "FeCAEReq": {
                "FeCabReq": {
                    "CantReg": 1,
                    "PtoVta": invoice_data.punto_de_venta,
                    "CbteTipo": cbte_tipo,
                },
                "FeDetReq": {
                    "FECAEDetRequest": [
                        {
                            "Concepto": 1,  # Productos
                            "DocTipo": 99,  # Sin identificar
                            "DocNro": int(invoice_data.cuit_receptor.replace("-", "")) if invoice_data.cuit_receptor else 0,
                            "CbteDesde": invoice_data.number,
                            "CbteHasta": invoice_data.number,
                            "CbteFch": fecha,
                            "ImpTotal": float(invoice_data.total),
                            "ImpTotConc": 0,
                            "ImpNeto": float(invoice_data.total),
                            "ImpOpEx": 0,
                            "ImpIVA": 0,
                            "ImpTrib": 0,
                            "MonId": "PES",
                            "MonCotiz": 1,
                        }
                    ]
                },
            },
        }

        result = client.service.FECAESolicitar(**request_body)

        # Parsear respuesta
        try:
            det = result.FeDetResp.FECAEDetResponse[0]
            if det.Resultado == "A":  # Aprobado
                return CAEResponse(
                    cae=det.CAE,
                    cae_due_date=datetime.datetime.strptime(det.CAEFchVto, "%Y%m%d").date(),
                    is_approved=True,
                )
            else:
                # Rechazado: extraer primer error
                obs = det.Observaciones.Obs[0] if det.Observaciones else None
                return CAEResponse(
                    cae=None,
                    cae_due_date=None,
                    is_approved=False,
                    error_code=str(obs.Code) if obs else "REJECTED",
                    error_detail=obs.Msg if obs else "Comprobante rechazado por AFIP",
                )
        except (AttributeError, IndexError, KeyError) as exc:
            raise RuntimeError(f"Error parseando respuesta AFIP: {exc}") from exc
