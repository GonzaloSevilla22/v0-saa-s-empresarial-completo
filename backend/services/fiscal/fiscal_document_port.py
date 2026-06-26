"""
C-27 v21-fiscal-profile — FiscalDocumentPort: interfaz ACL del adaptador WSFE.

Design ref: D4 — port/adapter detrás de un ACL. El dominio y los services
conocen SOLO los tipos de esta capa; el SOAP/XML de AFIP permanece encapsulado
en WSFEAdapter y WSFEStubAdapter.

Implementaciones inyectables por DI (Depends en FastAPI):
  - WSFEStubAdapter — CAE ficticio determinístico (tests / dev)
  - WSFEAdapter     — WSAA + WSFEv1 real (homologación / producción)
"""
from __future__ import annotations

import datetime
from abc import ABC, abstractmethod
from dataclasses import dataclass


@dataclass
class CAERequest:
    """Datos del comprobante a presentar ante AFIP para obtener el CAE.

    Solo tipos de dominio: sin SOAP/XML. El adapter traduce a la estructura
    AFIP correspondiente.

    Campos nuevos (v21-wsfe-production-hardening):
      - receptor_iva_condition: condicion IVA del receptor (RG 5616, Hueco 1).
          Valores: "consumidor_final" | "responsable_inscripto" | "monotributista" | "exento"
      - neto: importe neto gravado (Hueco 2, array Iva para tipo A/B).
      - iva_amount: importe de IVA (Hueco 2).
      - iva_alicuota_id: id de la alicuota AFIP (5 = 21%, Hueco 2).
    """

    account_id: str
    fiscal_document_id: str
    comprobante_type: str      # "factura_a" | "factura_b" | "factura_c"
    punto_de_venta: int        # numero del PV ante AFIP
    number: int                # numero del comprobante (de rpc_next_document_number)
    total: float               # importe total del comprobante
    cuit_emisor: str           # CUIT del emisor (de fiscal_profiles.cuit)
    ambiente: str              # "homologacion" | "produccion"
    # Opcionales — se amplian en C-29 (quickSale)
    cuit_receptor: str | None = None
    fecha_comprobante: datetime.date | None = None
    # v21-wsfe-production-hardening (D1, D2, D3)
    receptor_iva_condition: str | None = None   # "consumidor_final" | "responsable_inscripto" | "monotributista" | "exento"
    neto: float | None = None                   # importe neto gravado (para array Iva tipo A/B)
    iva_amount: float | None = None             # importe de IVA
    iva_alicuota_id: int | None = None          # id de la alicuota AFIP (5 = 21%)
    # fiscal-receptor-iva-relay (D2): identificación del receptor (AFIP DocTipo/DocNro)
    receptor_doc_tipo: int | None = None        # 80=CUIT, 96=DNI, 99=sin identificar (None → derivar)
    receptor_doc_nro: str | None = None         # número de documento del receptor (sin guiones)


@dataclass
class CAEResponse:
    """Respuesta normalizada del adaptador WSFE.

    El service solo ve estos campos; nunca estructuras SOAP.
    """

    cae: str | None
    cae_due_date: datetime.date | None
    is_approved: bool
    error_code: str | None = None
    error_detail: str | None = None


class FiscalDocumentPort(ABC):
    """Port (interfaz de dominio) del adaptador WSFE.

    Implementar request_cae en WSFEStubAdapter y WSFEAdapter.
    El service recibe una instancia de FiscalDocumentPort por DI (Depends).
    """

    @abstractmethod
    async def request_cae(self, invoice_data: CAERequest) -> CAEResponse:
        """Solicitar el CAE al web service AFIP (o retornar uno ficticio en stub).

        Args:
            invoice_data: datos del comprobante a presentar.

        Returns:
            CAEResponse con el resultado (is_approved, cae, cae_due_date o error).
        """
        ...
