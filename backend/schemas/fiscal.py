"""
C-27 v21-fiscal-profile — Pydantic v2 schemas para fiscal (FiscalProfile + PointOfSale + FiscalDocument).

Design ref: D9 (RLS), D10 (multi-PV), D11 (P0422 ambiguous), spec fiscal-profile/spec.md
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
