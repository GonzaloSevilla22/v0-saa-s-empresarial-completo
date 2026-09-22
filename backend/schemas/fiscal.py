"""
C-27 v21-fiscal-profile — Pydantic v2 schemas para fiscal (FiscalProfile + PointOfSale + FiscalDocument).
C-31 v21-wsfe-homologacion-wiring — schemas de upload del certificado AFIP.
v22-afip-delegation-billing — delegacion_autorizada + platform_representante_cuit en FiscalProfileOut.

Design ref: D9 (RLS), D10 (multi-PV), D11 (P0422 ambiguous), spec fiscal-profile/spec.md
C-31 Design ref: W1 (dos PEM separados), W2 (signed PUT, .key nunca devuelta)
v22 Design ref: D6 (flag atestación), D8 (UI onboarding), spec afip-platform-credential/spec.md
"""
from __future__ import annotations

import datetime
import uuid
from typing import Literal

from pydantic import BaseModel, ConfigDict, model_validator


def _check_receptor_coherente(tipo: int | None, nro: str | None) -> None:
    """Valida que receptor_doc_tipo/receptor_doc_nro viajen JUNTOS o NINGUNO.

    fiscal-emision-segura (m-2 minor, red team 2026-09-22): compartida por
    EmitPendingCAERequest (venta directa) y EmitSubscriptionPaymentRequest
    (pago de suscripción) — antes SOLO la segunda la tenía, así que una venta
    con `receptor_doc_tipo=80` y `receptor_doc_nro` vacío/ausente pasaba el
    schema, y `WSFEAdapter._resolve_receptor_doc` la resolvía como consumidor
    final (cae a 99/0 sin `doc_nro_raw`): la fila local decía "CUIT 80" y a
    ARCA iba consumidor final — receptor local y receptor real DIVERGÍAN.
    Reutilización antes que repetición (regla PO 2026-08-02): un solo lugar
    para esta coherencia, no dos copias que puedan divergir entre sí.
    """
    nro_clean = (nro or "").strip()
    if tipo is not None and not nro_clean:
        raise ValueError(
            "receptor_doc_nro es obligatorio cuando se informa receptor_doc_tipo "
            "(un DocTipo 80/96 sin número es inconsistente ante ARCA). Para "
            "emitir a consumidor final, omitir los dos campos."
        )
    if tipo is None and nro_clean:
        raise ValueError(
            "receptor_doc_tipo es obligatorio cuando se informa receptor_doc_nro "
            "(80=CUIT, 96=DNI)."
        )


# ── FiscalProfile schemas ────────────────────────────────────────────────────

class FiscalProfileCreate(BaseModel):
    """Schema de creación/update del perfil fiscal.

    Valida iva_condition y ambiente con Literal (rechazo 422 antes de tocar la DB).

    v22: agrega delegacion_autorizada (atestación del usuario sobre la relación ARCA).
    """

    cuit: str
    iva_condition: Literal[
        "responsable_inscripto",
        "monotributista",
        "exento",
        "consumidor_final",
    ]
    iibb_condition: str | None = None
    ambiente: Literal["homologacion", "produccion"] = "homologacion"
    certificado_afip_path: str | None = None
    # v22: flag de atestación de delegación (OQ-4 — solo owner/admin, guard en el service)
    delegacion_autorizada: bool = False


class FiscalProfileUpdate(BaseModel):
    """Schema de actualización parcial del perfil fiscal."""

    cuit: str | None = None
    iva_condition: Literal[
        "responsable_inscripto",
        "monotributista",
        "exento",
        "consumidor_final",
    ] | None = None
    iibb_condition: str | None = None
    ambiente: Literal["homologacion", "produccion"] | None = None
    certificado_afip_path: str | None = None


class FiscalProfileOut(BaseModel):
    """Schema de respuesta del perfil fiscal.

    Expone solo el path del certificado, nunca su contenido (D7).
    v22: agrega delegacion_autorizada + platform_representante_cuit para guiar el onboarding.
    El material criptográfico del representante NUNCA aparece aquí.
    """

    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    account_id: uuid.UUID
    cuit: str
    iva_condition: str
    iibb_condition: str | None = None
    certificado_afip_path: str | None = None
    ambiente: str
    created_at: datetime.datetime
    # v22: delegación ARCA
    delegacion_autorizada: bool = False
    # v22: CUIT del representante de plataforma (de config, no de la cuenta)
    # Expuesto para guiar al usuario en el onboarding ARCA. Solo el CUIT, nunca el cert/key.
    platform_representante_cuit: str | None = None


# ── PointOfSale schemas ──────────────────────────────────────────────────────

class PointOfSaleCreate(BaseModel):
    """Schema de creación de un punto de venta AFIP."""

    numero: int  # número ante AFIP, entero positivo
    branch_id: uuid.UUID | None = None


class PointOfSaleDeactivate(BaseModel):
    """Schema para desactivar un punto de venta."""

    is_active: Literal[False] = False


class PointOfSaleOut(BaseModel):
    """Schema de respuesta de un punto de venta."""

    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    fiscal_profile_id: uuid.UUID
    account_id: uuid.UUID
    branch_id: uuid.UUID | None = None
    numero: int
    is_active: bool
    created_at: datetime.datetime


# ── FiscalDocument schemas ───────────────────────────────────────────────────

class EmitPendingCAERequest(BaseModel):
    """Schema de emisión directa de un comprobante pending_cae (OQ-3: maquinaria).

    v22-admin: agrega receptor_doc_tipo + receptor_doc_nro para identificar al
    receptor cuando no es consumidor final (e.g. pagos de suscripción con CUIT/DNI).
    Mapeo AFIP: CUIT→DocTipo 80, DNI→DocTipo 96.
    subscription_payment_id: referencia idempotente para pagos de suscripción.
    """

    comprobante_type: Literal["factura_a", "factura_b", "factura_c"]
    total: float
    client_id: uuid.UUID | None = None
    point_of_sale_id: uuid.UUID | None = None  # opcional — D11
    # v22-admin: receptor identificado (CUIT=80, DNI=96)
    receptor_doc_tipo: Literal[80, 96] | None = None  # 80=CUIT, 96=DNI
    receptor_doc_nro: str | None = None               # sin guiones
    # fiscal-receptor-iva-relay: desglose de IVA para Factura A/B (lo provee la venta, OQ-2)
    neto: float | None = None                         # neto gravado
    iva_amount: float | None = None                   # IVA discriminado
    iva_alicuota_id: int | None = None                # id de alícuota AFIP (5 = 21%)
    # v22-admin: referencia idempotente de pago de suscripción
    subscription_payment_id: str | None = None

    @model_validator(mode="after")
    def _receptor_coherente(self) -> "EmitPendingCAERequest":
        _check_receptor_coherente(self.receptor_doc_tipo, self.receptor_doc_nro)
        return self


class EmitSubscriptionPaymentRequest(BaseModel):
    """Schema para emitir Factura C por un pago de suscripción (flujo admin).

    El admin Aliadata (CUIT 20422662457, monotributista) emite una Factura C
    al cliente de SaaS por el pago de su plan. El receptor se identifica con
    CUIT o DNI capturado en el dialog (PO decision 2026-06-24).
    Governance: CRÍTICO — solo admin puede llamar este endpoint.

    fiscal-emision-segura (G5/H3): el receptor pasa a ser OPCIONAL —
    "consumidor final sin identificar". El bloqueo era sólo de esta capa: la RPC
    ya acepta `p_receptor_doc_tipo DEFAULT 99` con `NULLIF(..., 99)` y el adapter
    ya resuelve un receptor no identificado como DocTipo=99 / DocNro=0 (el mismo
    caso de una factura de mostrador). ARCA exige identificar al receptor a
    partir del umbral de RG 5824/2026 (`afip_consumidor_final_threshold`), muy
    por encima de un pago de suscripción; ese umbral lo verifica el adapter.

    Los dos campos viajan JUNTOS o NINGUNO: un DocTipo=80 con DocNro vacío es un
    comprobante inconsistente ante ARCA, y relajar el schema sin este validador
    abriría exactamente esa puerta.
    """

    receipt_id: str                     # ID del PaymentReceipt (idempotency key)
    point_of_sale_id: uuid.UUID | None = None
    receptor_doc_tipo: Literal[80, 96] | None = None  # 80=CUIT, 96=DNI, None=consumidor final
    receptor_doc_nro: str | None = None               # sin guiones, validado en el service

    @model_validator(mode="after")
    def _receptor_coherente(self) -> "EmitSubscriptionPaymentRequest":
        _check_receptor_coherente(self.receptor_doc_tipo, self.receptor_doc_nro)
        return self


# ── CertUpload schemas (C-31) ─────────────────────────────────────────────────

class CertUploadUrlRequest(BaseModel):
    """Request para obtener una signed upload URL del bucket privado afip-certs.

    kind ∈ {cert, key}:
      - cert → path canónico {account_id}/afip.crt
      - key  → path canónico {account_id}/afip.key

    El path siempre se deriva server-side del account_id del JWT (W1, W2 — el
    cliente NO decide la ruta; la decide el backend para evitar rutas de otras cuentas).
    """

    filename: str
    content_type: str
    kind: Literal["cert", "key"]


class CertUploadUrlOut(BaseModel):
    """Respuesta del endpoint cert-upload-url.

    uploadUrl: signed PUT URL de Supabase Storage (expira en minutos).
    path: ruta canónica del objeto en el bucket (para correlacionar en el PUT
          posterior de cert-path).

    La .key NUNCA se devuelve en ningún GET posterior (invariante OQ-2 / W2).
    """

    uploadUrl: str
    path: str


class CertPathUpdate(BaseModel):
    """Request para persistir el path del certificado .crt en fiscal_profiles.

    Solo el .crt dispara este PUT (el upload de la .key no toca este campo —
    la .key no se refleja en la API, W2).
    """

    path: str


# ── FiscalDocument schemas ───────────────────────────────────────────────────

class FiscalDocumentOut(BaseModel):
    """Schema de respuesta de un comprobante fiscal."""

    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    account_id: uuid.UUID
    fiscal_profile_id: uuid.UUID
    point_of_sale_id: uuid.UUID
    comprobante_type: str
    punto_de_venta: int
    number: int
    status: str
    cae: str | None = None
    cae_due_date: datetime.date | None = None
    attempts: int
    next_attempt_at: datetime.datetime | None = None
    last_error: str | None = None
    total: float
    created_at: datetime.datetime
    # v22-admin: referencia al pago de suscripción (para idempotencia)
    subscription_payment_id: str | None = None
