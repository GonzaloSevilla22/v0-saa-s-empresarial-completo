"""
multiusuario-operativo TANDA C (grupo 15) — schemas Pydantic v2 de la invitación a una cuenta.

El email del invitado se valida acá con la misma forma conservadora que la base
(`rpc_invite_member` -> P0400 `invalid_email`): el destinatario del email de invitación
sale de la fila, así que no puede ser `all_users`, ni llevar espacios o saltos de línea.
El token NUNCA está en `InvitationOut` (el listado no lo expone); sólo la creación y el
reenvío lo devuelven, para el «Copiar link» del invitador (OQ-6).
"""
from __future__ import annotations

import datetime
import re
import uuid

from pydantic import BaseModel, ConfigDict, Field, field_validator

# Misma forma que la base: una sola @, sin espacios ni caracteres de control, con un punto en el dominio.
_EMAIL = re.compile(r"^[^\s@\x00-\x1f\x7f]+@[^\s@\x00-\x1f\x7f]+\.[^\s@\x00-\x1f\x7f]+$")
_ROLE_CODE = re.compile(r"^[a-z][a-z_]{0,31}$")

# Un token de invitación es hex de 64 caracteres (32 bytes). Se acepta un rango razonable para no
# acoplarse al largo exacto, pero lo que no tenga forma de token ni llega a la base.
TOKEN_PATTERN = re.compile(r"^[A-Za-z0-9_-]{32,128}$")


class InvitationCreateRequest(BaseModel):
    """Payload de POST /members/invitations."""

    email: str = Field(..., min_length=3, max_length=254, description="Email al que se envía la invitación")
    roles: list[str] = Field(
        default_factory=list,
        max_length=8,
        description="Conjunto de roles del catálogo con que se incorpora; vacío = Observador (solo lectura)",
    )

    @field_validator("email")
    @classmethod
    def _email_valido(cls, value: str) -> str:
        email = value.strip().lower()
        if not _EMAIL.match(email):
            raise ValueError("El email no es válido")
        return email

    @field_validator("roles")
    @classmethod
    def _roles_validos(cls, value: list[str]) -> list[str]:
        for code in value:
            if not _ROLE_CODE.match(code):
                raise ValueError("Código de rol inválido")
        # Sin duplicados, conservando el orden en que se declararon.
        return list(dict.fromkeys(value))


class InvitationSent(BaseModel):
    """Respuesta de crear o reenviar: la invitación y el link para copiar (token vigente)."""

    id: uuid.UUID
    email: str
    roles: list[str]
    expires_at: datetime.datetime
    token: str
    email_queued: bool = True


class InvitationOut(BaseModel):
    """Una invitación del listado. NUNCA lleva el token."""

    model_config = ConfigDict(from_attributes=True, extra="ignore")

    id: uuid.UUID
    email: str
    roles: list[str]
    role_labels: list[str]
    state: str = Field(..., description="pending | expired | revoked")
    created_at: datetime.datetime
    expires_at: datetime.datetime
    invited_by: uuid.UUID | None = None
    invited_by_name: str | None = None
    last_sent_at: datetime.datetime | None = None
    send_count: int = 0


class InvitationRevoked(BaseModel):
    id: uuid.UUID
    status: str


class InvitationPreview(BaseModel):
    """Vista previa para el invitado que ya inició sesión (ligada a su identidad en la base)."""

    account_id: uuid.UUID
    account_display_name: str
    inviter_name: str
    roles: list[str]
    role_labels: list[str]
    expires_at: datetime.datetime
    already_member: bool


class InvitationAccepted(BaseModel):
    """Resultado de aceptar: la membresía creada y la cuenta que quedó activa."""

    account_member_id: uuid.UUID
    account_id: uuid.UUID
    active_account_id: uuid.UUID
    role: str
    roles: list[str]
