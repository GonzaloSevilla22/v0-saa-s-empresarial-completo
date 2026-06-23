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

from pydantic import BaseModel, ConfigDict


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
    """Schema de emisión directa de un comprobante pending_cae (OQ-3: maquinaria)."""

    comprobante_type: Literal["factura_a", "factura_b", "factura_c"]
    total: float
    client_id: uuid.UUID | None = None
    point_of_sale_id: uuid.UUID | None = None  # opcional — D11


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
