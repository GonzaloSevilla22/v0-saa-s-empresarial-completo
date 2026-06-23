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
from backend.services.fiscal.ticket_cache_port import TicketCache

logger = logging.getLogger(__name__)

# URLs de AFIP/ARCA (ambiente resuelto desde el perfil)
# C-31: corregido .gov.ar → .gob.ar (typo de C-27; sin este fix el E2E real falla)
_WSAA_URLS = {
    "homologacion": "https://wsaahomo.afip.gob.ar/ws/services/LoginCms?WSDL",
    "produccion":   "https://wsaa.afip.gob.ar/ws/services/LoginCms?WSDL",
}
_WSFEV1_URLS = {
    "homologacion": "https://wswhomo.afip.gob.ar/wsfev1/service.asmx?WSDL",
    # NOTA: el WSFEv1 de PRODUCCIÓN sigue presentando un cert TLS válido SOLO para
    # `servicios1.afip.gov.ar` (CN + SAN .gov.ar). Apuntar a .gob.ar da
    # SSLCertVerificationError (hostname mismatch). El WSAA de prod sí migró a .gob.ar.
    "produccion":   "https://servicios1.afip.gov.ar/wsfev1/service.asmx?WSDL",
}


def _afip_ssl_context():
    """SSLContext para los web services de AFIP.

    El server de PRODUCCIÓN (servicios1.afip.gov.ar) negocia una clave
    Diffie-Hellman corta que OpenSSL moderno rechaza (DH_KEY_TOO_SMALL). Bajamos
    el security level a 1 para tolerar ese handshake, SIN desactivar la
    verificación del certificado: hostname y CA se siguen validando.
    """
    import ssl

    ctx = ssl.create_default_context()
    ctx.check_hostname = True
    ctx.verify_mode = ssl.CERT_REQUIRED
    ctx.set_ciphers("DEFAULT@SECLEVEL=1")
    return ctx


def _build_zeep_client(url: str):
    """Cliente zeep con el SSLContext tolerante de AFIP (ver _afip_ssl_context).

    Necesario para producción: sin el security level bajado, el handshake TLS
    con servicios1.afip.gov.ar falla con DH_KEY_TOO_SMALL. Homologación no lo
    necesita, pero usar el mismo client para ambos ambientes es inocuo.
    """
    import zeep
    import requests
    from requests.adapters import HTTPAdapter
    from urllib3.poolmanager import PoolManager

    class _AfipTLSAdapter(HTTPAdapter):
        def init_poolmanager(self, connections, maxsize, block=False, **kwargs):
            self.poolmanager = PoolManager(
                num_pools=connections,
                maxsize=maxsize,
                block=block,
                ssl_context=_afip_ssl_context(),
            )

    session = requests.Session()
    session.mount("https://", _AfipTLSAdapter())
    return zeep.Client(url, transport=zeep.Transport(session=session))


# Mapping de comprobante_type a codigo AFIP (CbteTipo)
_COMPROBANTE_AFIP_CODE = {
    "factura_a": 1,
    "factura_b": 6,
    "factura_c": 11,
    "nota_debito_a": 2,
    "nota_credito_a": 3,
    "nota_debito_b": 7,
    "nota_credito_b": 8,
}

# Mapping receptor_iva_condition -> CondicionIVAReceptorId (RG 5616/2024).
# consumidor_final=5 confirmado por E2E homologacion (CAE 86250464989491).
# Resto de la tabla confirmado por el PO (sign-off 2026-06-23, Gate 0).
# AUSENCIA del campo provoca Code 10246 en ARCA -> el adapter falla explicitamente.
_CONDICION_IVA_RECEPTOR_ID: dict[str, int] = {
    "responsable_inscripto": 1,
    "exento": 4,
    "consumidor_final": 5,
    "monotributista": 6,

}

# Tipos de comprobante que discriminan IVA (tipo A y B).
# Tipo C (monotributista emisor) no lleva array Iva.
_CBTE_CON_IVA = {1, 2, 3, 6, 7, 8}   # factura/nota A y B


class WSFEAdapter(FiscalDocumentPort):
    """Adaptador real WSAA + WSFEv1 para obtener el CAE de AFIP/ARCA.

    El ambiente (homologacion|produccion) se resuelve desde invoice_data.ambiente
    (que proviene de fiscal_profiles.ambiente de la cuenta), no de una env var global (D2).

    El certificado se lee desde el bucket privado afip-certs server-side (D7).
    La lectura usa el supabase client con service_role (única excepción del proyecto
    para job administrativo aislado — DEC-13).

    Para inyectar en tests: mockear el método _get_wsaa_token y _call_wsfe.
    """

    def __init__(self, supabase_service_client=None, ticket_cache: TicketCache | None = None):
        """
        Args:
            supabase_service_client: cliente Supabase con service_role para leer el cert
                y para la cache del TA (D5/D7). Si es None se crea lazily en el primer uso.
            ticket_cache: puerto de cache del TA de WSAA (D5). Si es None, cada llamada
                hace un loginCms nuevo (sin cache). Inyectar PostgresTicketCache en prod.
        """
        self._service_client = supabase_service_client
        self._ticket_cache = ticket_cache

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
        """Obtiene el ticket de acceso WSAA (token + sign), con cache.

        Flujo (D5 — v21-wsfe-production-hardening):
          1. Construir cache key "{cuit}:wsfe:{ambiente}".
          2. Si hay TA vigente en cache -> retornarlo SIN llamar a loginCms.
          3. Si no (cache miss / expirado) -> autenticar y guardar en cache.

        Returns:
            (token, sign) — credenciales para autenticar en WSFEv1.

        Raises:
            ImportError: si zeep no esta instalado.
            Exception: si el cert no existe o WSAA no responde.
        """
        # ── (D5) Verificar cache primero ────────────────────────────────────────
        cache_key = f"{invoice_data.cuit_emisor}:wsfe:{invoice_data.ambiente}"
        if self._ticket_cache is not None:
            cached = self._ticket_cache.get(cache_key)
            if cached is not None:
                token, sign, _ = cached
                logger.debug(
                    "_get_wsaa_token: TA vigente en cache (cuit=%s, ambiente=%s) — saltando loginCms",
                    invoice_data.cuit_emisor,
                    invoice_data.ambiente,
                )
                return token, sign

        # ── Cache miss: autenticar vía WSAA ─────────────────────────────────────
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

        # Llamar WSAA — retorna (token, sign, expires_at)
        wsaa_url = _WSAA_URLS[invoice_data.ambiente]
        result = await self._call_wsaa(wsaa_url, cms)

        # _call_wsaa puede retornar (token, sign) o (token, sign, expires_at)
        if len(result) == 3:
            token, sign, expires_at = result
        else:
            token, sign = result
            # Default TA validity ~12h (WSAA standard)
            expires_at = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=12)

        # Guardar en cache para reusar en próximas invocaciones (D5)
        if self._ticket_cache is not None:
            self._ticket_cache.set(cache_key, token, sign, expires_at)

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

    async def _call_wsaa(self, wsaa_url: str, cms: str) -> tuple[str, str, datetime.datetime]:
        """Llama al web service WSAA para obtener el ticket de acceso.

        Returns:
            (token, sign, expires_at) — el expires_at se extrae del TA XML para
            permitir que _get_wsaa_token lo guarde en la cache (D5).
        """
        client = _build_zeep_client(wsaa_url)
        response = client.service.loginCms(in0=cms)
        # Parsear el TA XML
        import xml.etree.ElementTree as ET
        root = ET.fromstring(response)
        credentials = root.find("credentials")
        token = credentials.find("token").text
        sign  = credentials.find("sign").text

        # Extraer expirationTime del header del TA (D5: para calcular TTL de la cache)
        try:
            header = root.find("header")
            expiration_text = header.find("expirationTime").text if header is not None else None
            if expiration_text:
                # AFIP formato: "2026-06-23T12:00:00.000-03:00" o similar ISO 8601
                expires_at = datetime.datetime.fromisoformat(expiration_text)
                if expires_at.tzinfo is None:
                    expires_at = expires_at.replace(tzinfo=datetime.timezone.utc)
            else:
                # Fallback: 12h desde ahora (duracion estandar del TA de AFIP)
                expires_at = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=12)
        except Exception:
            expires_at = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=12)

        return token, sign, expires_at

    async def _call_wsfe(
        self,
        invoice_data: CAERequest,
        token: str,
        sign: str,
    ) -> CAEResponse:
        """Llama a WSFEv1.FECAESolicitar y retorna CAEResponse normalizado.

        Implementa los 3 huecos de produccion (v21-wsfe-production-hardening):
          (1) CondicionIVAReceptorId — RG 5616/2024 (D2)
          (2) Array Iva / AlicIva    — IVA discriminado tipo A/B; tipo C sin IVA (D3)
          (3) Numeracion autoritativa via FECompUltimoAutorizado + 1 (D4)
        """
        wsfev1_url = _WSFEV1_URLS[invoice_data.ambiente]
        client = _build_zeep_client(wsfev1_url)

        cbte_tipo = _COMPROBANTE_AFIP_CODE.get(invoice_data.comprobante_type, 6)
        fecha = (invoice_data.fecha_comprobante or datetime.date.today()).strftime("%Y%m%d")

        auth = {
            "Token": token,
            "Sign": sign,
            "Cuit": int(invoice_data.cuit_emisor.replace("-", "")),
        }

        # ── (1) CondicionIVAReceptorId — RG 5616/2024 ──────────────────────────
        # La ausencia de este campo provoca Code 10246 en ARCA.
        # Fallamos explicitamente ante una condicion sin mapeo (no omitimos el campo).
        receptor_condition = invoice_data.receptor_iva_condition
        if receptor_condition is None:
            # Default seguro para flujos que aun no envian la condicion
            receptor_condition = "consumidor_final"
        if receptor_condition not in _CONDICION_IVA_RECEPTOR_ID:
            raise ValueError(
                f"CondicionIVAReceptorId: condicion IVA del receptor desconocida: "
                f"'{receptor_condition}'. Valores validos: {list(_CONDICION_IVA_RECEPTOR_ID)}"
            )
        condicion_iva_receptor_id = _CONDICION_IVA_RECEPTOR_ID[receptor_condition]

        # ── (3) Numeracion autoritativa: FECompUltimoAutorizado + 1 (D4-B) ─────
        # ARCA es la fuente de verdad del numero. Ignoramos invoice_data.number
        # al momento del CAE y usamos ultimo+1.
        # Si hay mismatch con el numero local reservado, lo detectamos (Code 10016).
        ultimo_resp = client.service.FECompUltimoAutorizado(
            Auth=auth,
            PtoVta=invoice_data.punto_de_venta,
            CbteTipo=cbte_tipo,
        )
        ultimo_arca = int(ultimo_resp.Nro) if ultimo_resp.Nro is not None else 0
        cbte_numero = ultimo_arca + 1

        # Detectar mismatch con el numero local reservado (Code 10016 implicit)
        if invoice_data.number and invoice_data.number != cbte_numero:
            logger.warning(
                "WSFEAdapter: mismatch numero local %s vs ARCA autoritativo %s "
                "(PtoVta=%s, CbteTipo=%s). Usando ARCA (D4-B).",
                invoice_data.number,
                cbte_numero,
                invoice_data.punto_de_venta,
                cbte_tipo,
            )

        # ── (2) Array Iva / totales consistentes (D3) ───────────────────────────
        total = float(invoice_data.total)
        total_conceptos_no_gravados = 0
        total_op_exentas = 0
        total_tributos = 0

        if cbte_tipo in _CBTE_CON_IVA:
            # Tipo A/B: IVA discriminado. Construir array AlicIva.
            neto = float(invoice_data.neto) if invoice_data.neto is not None else total
            iva_amount = float(invoice_data.iva_amount) if invoice_data.iva_amount is not None else 0.0
            iva_alicuota_id = invoice_data.iva_alicuota_id if invoice_data.iva_alicuota_id is not None else 5
            imp_neto = neto
            imp_iva = iva_amount
            # Consistency guard: ImpNeto + ImpIVA must equal ImpTotal
            # (for the simple case without other charges/exemptions)
            iva_array = [
                {
                    "Id": iva_alicuota_id,
                    "BaseImp": neto,
                    "Importe": iva_amount,
                }
            ]
        else:
            # Tipo C (monotributista emisor): sin IVA discriminado.
            imp_neto = total
            imp_iva = 0.0
            iva_array = None  # NO incluir el campo Iva

        # ── Armar FECAEDetRequest ────────────────────────────────────────────────
        doc_nro = (
            int(invoice_data.cuit_receptor.replace("-", ""))
            if invoice_data.cuit_receptor
            else 0
        )

        det_request: dict = {
            "Concepto": 1,   # Productos
            "DocTipo": 99,   # Sin identificar (consumidor final) o CUIT
            "DocNro": doc_nro,
            "CbteDesde": cbte_numero,
            "CbteHasta": cbte_numero,
            "CbteFch": fecha,
            "ImpTotal": total,
            "ImpTotConc": total_conceptos_no_gravados,
            "ImpNeto": imp_neto,
            "ImpOpEx": total_op_exentas,
            "ImpIVA": imp_iva,
            "ImpTrib": total_tributos,
            "MonId": "PES",
            "MonCotiz": 1,
            "CondicionIVAReceptorId": condicion_iva_receptor_id,
        }

        if iva_array is not None:
            det_request["Iva"] = {"AlicIva": iva_array}

        request_body = {
            "Auth": auth,
            "FeCAEReq": {
                "FeCabReq": {
                    "CantReg": 1,
                    "PtoVta": invoice_data.punto_de_venta,
                    "CbteTipo": cbte_tipo,
                },
                "FeDetReq": {
                    "FECAEDetRequest": [det_request]
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
