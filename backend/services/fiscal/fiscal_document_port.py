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
from collections.abc import Awaitable, Callable
from dataclasses import dataclass

# fiscal-riesgos-residuales (R1): hook que el relay inyecta por documento. El
# adapter lo AWAITEA con el número que está por pedirle a ARCA, justo antes del
# FECAESolicitar. Si levanta, el envío NO sale.
SubmitStartHook = Callable[[int], Awaitable[None]]


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
    # ── fiscal-riesgos-residuales (R1): la marca ANTES del envío ──────────────
    # El adapter lo awaitea con el número que va a pedirle a ARCA
    # (FECompUltimoAutorizado + 1), FUERA del try del FECAESolicitar e
    # inmediatamente antes. Si levanta, el envío NO sale: es lo que sostiene la
    # invariante "un FECAESolicitar nunca sale sin una marca commiteada".
    #
    # Viaja en el CAERequest y NO como parámetro nuevo de `request_cae` a
    # propósito: así la firma del port queda intacta y ninguno de los ~20 mocks
    # de adapter de backend/tests/ se rompe. El precio es un Callable dentro de
    # un dataclass de dominio (roza el ACL del D4); el beneficio es no tocar
    # seis archivos de test por una cuestión de forma.
    on_submit_start: SubmitStartHook | None = None


@dataclass
class CAEResponse:
    """Respuesta normalizada del adaptador WSFE.

    El service solo ve estos campos; nunca estructuras SOAP.

    fiscal-emision-segura (G3/G4):
      - number: el número que ARCA CONFIRMÓ (`det.CbteDesde` de la respuesta
        aprobada). Hasta este change se descartaba: el adapter pedía el CAE con
        `FECompUltimoAutorizado+1` y en la base quedaba el número local
        reservado, que puede ser OTRO (ARCA numera por (CUIT, PtoVta, CbteTipo)
        y `document_sequences` por point_of_sale_id). None = el adapter no lo
        informa (respuesta rechazada, o un adapter viejo).
      - submitted: True SOLO si el `FECAESolicitar` ya salió y su resultado
        NUNCA se confirmó. Con `is_approved=False` y `submitted=True` el
        comprobante PUEDE tener un CAE real emitido en ARCA sin registro local:
        reintentar pediría `ultimo+1` otra vez y emitiría una SEGUNDA factura.
        El relay congela el documento en vez de reintentar.
    """

    cae: str | None
    cae_due_date: datetime.date | None
    is_approved: bool
    error_code: str | None = None
    error_detail: str | None = None
    number: int | None = None
    submitted: bool = False


@dataclass
class ReconcileResponse:
    """Qué dice ARCA sobre un comprobante que YA se le pidió.

    fiscal-riesgos-residuales (R1). La devuelve `reconcile_submitted` cuando el
    relay reclama un documento con la marca de envío puesta: es la única fuente
    que puede desbloquearlo, porque pedirle un CAE nuevo emitiría una segunda
    factura real.

    `outcome`:
      - "authorized" — ARCA lo tiene con `Resultado='A'`: se adopta su CAE.
      - "not_found"  — ARCA demostró que NO existe (602) **y** su último
        autorizado todavía no llegó a ese número. Es la ÚNICA salida que
        habilita re-emitir, y por eso exige el cross-check: el 602 también
        aparece cuando el PtoVta/CbteTipo de la consulta no matchea.
      - "rejected"   — existe pero con `Resultado='R'`. El processor lo trata
        como "unknown": un FECAESolicitar rechazado no consume el número, así
        que un comprobante "existente pero rechazado" es una respuesta que no
        sabemos interpretar.
      - "unknown"    — TODO lo demás: timeout, transporte, HTML en vez de
        envelope, Fault, fecha deforme, librerías ausentes. Es el DEFAULT del
        dataclass a propósito — nunca "not_found" por omisión.
    """

    outcome: str = "unknown"   # "authorized" | "not_found" | "rejected" | "unknown"
    cae: str | None = None
    cae_due_date: datetime.date | None = None
    number: int | None = None
    ultimo_autorizado: int | None = None   # cross-check del 602
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

    async def reconcile_submitted(
        self, invoice_data: CAERequest, requested_number: int
    ) -> ReconcileResponse:
        """¿Qué pasó con el comprobante `requested_number` que ya se envió?

        fiscal-riesgos-residuales (R1). NO es @abstractmethod a propósito: si lo
        fuera, cada fake de la suite tendría que implementarla y —peor— un
        adapter futuro incompleto explotaría en runtime, dentro del relay.

        El default es FAIL-CLOSED: `unknown`. Un adapter que no la implemente
        hace que el documento reintente la consulta y termine CONGELADO; nunca
        que se emita un CAE nuevo sobre un envío que puede haber salido.
        """
        return ReconcileResponse(
            outcome="unknown",
            error_code="RECONCILE_NOT_IMPLEMENTED",
            error_detail=(
                f"{type(self).__name__} no implementa reconcile_submitted: no se "
                "puede demostrar qué pasó con el envío, así que no se emite nada."
            ),
        )
