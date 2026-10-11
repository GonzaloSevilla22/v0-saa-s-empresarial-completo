"""
documentos-marca-empresa (D1/D9): contrato HTTP de `/document-branding`.

La entrada (`DocumentBrandingIn`) es la PRIMERA capa de validación de la marca —
la segunda son los CHECKs de `account_branding`—: recorta los textos, convierte lo
vacío en `null` (nunca texto en blanco), acota los largos, exige la forma del
email, del CUIT (con su dígito verificador), del sitio web y del color, el
catálogo cerrado de paletas y la coherencia paleta/color. El contraste del color
personalizado NO se valida acá: lo decide el service con la aritmética de
`palette.py` (422 `branding_accent_low_contrast`).

La salida trae lo guardado, lo que se IMPRIME (el emisor resuelto por la cascada
única, con el origen de cada dato), los datos fiscales de sólo lectura, el
respaldo del perfil del dueño (para la vista previa en vivo), la paleta resuelta
en hex y el catálogo. Nunca la imagen del logo ni un email de acceso.
"""
from __future__ import annotations

import datetime
import re
import uuid
from typing import Literal

from pydantic import BaseModel, Field, field_validator, model_validator

from backend.services.fiscal.comprobante import format_cuit, is_valid_cuit

PaletteKey = Literal["neutro", "azul", "verde", "grafito", "bordo", "personalizado"]

# Mismas formas que los CHECKs de la tabla (account_branding_email_check, _website_check).
_EMAIL = re.compile(r'^[^\s@<>"]+@[^\s@<>"]+\.[^\s@<>"]+$')
_WEBSITE_FORBIDDEN = re.compile(r'[\s<>"]')
_ACCENT = re.compile(r"^#[0-9a-f]{6}$")


def _blank_to_none(value: object) -> object:
    """Recorta un texto; lo vacío o en blanco es "sin dato" (`None`)."""
    if value is None:
        return None
    if isinstance(value, str):
        stripped = value.strip()
        return stripped or None
    return value


class DocumentBrandingIn(BaseModel):
    """`PUT /document-branding`: REEMPLAZA los datos y la paleta de la marca (el logo no
    cambia). Un campo ausente o vacío queda sin dato."""

    display_name: str | None = Field(default=None, max_length=80)
    legal_name: str | None = Field(default=None, max_length=120)
    tax_id: str | None = None
    address: str | None = Field(default=None, max_length=200)
    phone: str | None = Field(default=None, max_length=40)
    email: str | None = Field(default=None, max_length=120)
    website: str | None = Field(default=None, max_length=120)
    footer_note: str | None = Field(default=None, max_length=280)
    palette_preset: PaletteKey = "neutro"
    accent_color: str | None = None

    @field_validator(
        "display_name", "legal_name", "tax_id", "address", "phone", "email", "website", "footer_note",
        "accent_color", mode="before",
    )
    @classmethod
    def _trim(cls, value: object) -> object:
        return _blank_to_none(value)

    @field_validator("email")
    @classmethod
    def _email_shape(cls, value: str | None) -> str | None:
        if value is not None and not _EMAIL.match(value):
            raise ValueError("El email del negocio no tiene forma de dirección de correo.")
        return value

    @field_validator("tax_id")
    @classmethod
    def _cuit(cls, value: str | None) -> str | None:
        if value is None:
            return None
        if not is_valid_cuit(value):
            raise ValueError("El CUIT no es válido (formato 20-12345678-6 con su dígito verificador).")
        return format_cuit(value)                          # se guarda siempre con guiones

    @field_validator("website")
    @classmethod
    def _website_shape(cls, value: str | None) -> str | None:
        if value is not None and _WEBSITE_FORBIDDEN.search(value):
            raise ValueError("El sitio web no puede tener espacios ni caracteres como < > \".")
        return value

    @field_validator("accent_color", mode="after")
    @classmethod
    def _accent_shape(cls, value: str | None) -> str | None:
        if value is None:
            return None
        lowered = value.lower()
        if not _ACCENT.match(lowered):
            raise ValueError("El color tiene que ser #rrggbb.")
        return lowered

    @model_validator(mode="after")
    def _palette_and_color_agree(self) -> DocumentBrandingIn:
        if self.palette_preset == "personalizado" and self.accent_color is None:
            raise ValueError("accent_color: la paleta personalizada necesita un color (#rrggbb).")
        if self.palette_preset != "personalizado" and self.accent_color is not None:
            raise ValueError("accent_color: sólo la paleta personalizada lleva un color propio.")
        return self


# ── salida ───────────────────────────────────────────────────────────────────

class BrandingSettingsOut(BaseModel):
    display_name: str | None = None
    legal_name: str | None = None
    tax_id: str | None = None
    address: str | None = None
    phone: str | None = None
    email: str | None = None
    website: str | None = None
    footer_note: str | None = None
    palette_preset: PaletteKey = "neutro"
    accent_color: str | None = None


class LogoDescriptorOut(BaseModel):
    sha256: str
    mime: str
    width: int
    height: int


class IssuerOut(BaseModel):
    """El emisor tal como se imprime en los papeles (cascada única)."""

    name: str
    legal_name: str | None = None
    cuit: str | None = None
    iva_legend: str | None = None
    address: str | None = None
    phone: str | None = None
    email: str | None = None
    website: str | None = None


class FiscalOut(BaseModel):
    """Lo que viene del perfil fiscal (AFIP): se muestra de sólo lectura."""

    razon_social: str | None = None
    nombre_fantasia: str | None = None
    cuit: str | None = None
    domicilio_comercial: str | None = None
    iva_condition: str | None = None


class OwnerFallbackOut(BaseModel):
    """El respaldo del perfil del dueño (nombre del negocio y teléfono)."""

    business_name: str | None = None
    phone: str | None = None


class PaletteOut(BaseModel):
    """La paleta resuelta, en `#rrggbb` (para la vista previa y el HTML imprimible)."""

    key: str
    accent: str | None = None
    ink: str
    muted: str
    rule: str
    surface: str
    heading: str
    strong_rule: str
    table_head_fill: str
    table_head_text: str
    total: str
    accepted_stamp: str


class PaletteChoiceOut(BaseModel):
    key: str
    label: str
    accent: str | None = None


class DocumentBrandingOut(BaseModel):
    settings: BrandingSettingsOut
    # True cuando la cuenta nunca guardó su marca (valores por defecto: Neutro, sin logo).
    is_default: bool
    logo: LogoDescriptorOut | None = None
    issuer: IssuerOut
    sources: dict[str, str]
    fiscal: FiscalOut | None = None
    owner_fallback: OwnerFallbackOut
    footer_note: str | None = None
    palette: PaletteOut
    palettes: list[PaletteChoiceOut]
    updated_at: datetime.datetime | None = None
    updated_by: uuid.UUID | None = None


class LogoUploadOut(BaseModel):
    logo: LogoDescriptorOut
