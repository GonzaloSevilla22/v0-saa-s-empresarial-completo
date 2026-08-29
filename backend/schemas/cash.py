from __future__ import annotations

import datetime
import uuid
from decimal import Decimal
from enum import Enum
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

from backend.schemas.common import PageOut


# ── Enums ─────────────────────────────────────────────────────────────────────

class MovementType(str, Enum):
    sale             = "sale"
    purchase_payment = "purchase_payment"
    expense          = "expense"
    advance          = "advance"
    withdrawal       = "withdrawal"
    sale_reversal    = "sale_reversal"
    # banco-caja-historial-ajustes (D4): ajuste manual con motivo obligatorio
    # (ver RegisterMovementIn.validate_adjustment_reason). Signo libre —
    # sobrante (+) o faltante (-), a diferencia de los tipos de abajo que
    # tienen un signo esperado fijo.
    adjustment       = "adjustment"
    # gastos-forma-pago (D9): contra-movimiento AUTOMÁTICO del borrado de un
    # gasto en efectivo, emitido por rpc_delete_expense. Tipo propio, no
    # `adjustment`: el vocabulario de caja distingue la compensación
    # automática de la corrección manual, y `adjustment` además exige motivo.
    expense_reversal = "expense_reversal"


# Movement types that are expected to be income (positive amount).
# gastos-forma-pago (D9): expense_reversal entra ACÁ — revertir un egreso
# REPONE plata en el cajón, así que su signo esperado es POSITIVO. Ojo con el
# "espejo de sale_reversal": el espejo es de FAMILIA de UI (ambos van a la
# familia `reversal` del historial de caja), NO de signo — sale_reversal está
# en _EXPENSE_TYPES, o sea el signo opuesto. Las dos taxonomías son distintas
# y mezclarlas rompe el filtro "Reversas" o el validador de signo.
_INCOME_TYPES = {MovementType.sale, MovementType.advance, MovementType.expense_reversal}
# Movement types that are expected to be expenses (negative amount).
# sale_reversal entra acá por pedido del PO (2026-08-22, sucesor de PR #442): la spec
# cash-movement lo define como egreso con signo negativo esperado y la RPC de
# delete-guard-ledgers (el único productor real) lo inserta con
# -v_cash_amount. Había quedado fuera "a propósito" solo porque el validador
# era un no-op (ver PR #442) y nunca se lo había validado a nadie.
_EXPENSE_TYPES = {
    MovementType.purchase_payment,
    MovementType.expense,
    MovementType.withdrawal,
    MovementType.sale_reversal,
}
# adjustment queda FUERA de ambos conjuntos a propósito: es signado
# libremente (sobrante +/faltante -, D4 del design de
# banco-caja-historial-ajustes).


# ── Cashbox ───────────────────────────────────────────────────────────────────

class CashboxCreate(BaseModel):
    branch_id: uuid.UUID
    name: str
    currency: str = "ARS"


class CashboxOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    branch_id: uuid.UUID
    name: str
    currency: str
    created_at: datetime.datetime


# ── CashSession ───────────────────────────────────────────────────────────────

class OpenSessionIn(BaseModel):
    opening_balance: Decimal


class CloseSessionIn(BaseModel):
    counted_balance: Decimal
    # v3-api-standards §4: opcional+deprecado — la clave viaja preferentemente
    # por el header `Idempotency-Key` (D4/D5); fallback de body durante la
    # ventana de compatibilidad (OQ2).
    idempotency_key: str | None = None


class CashSessionOut(BaseModel):
    """Output schema for a cash session (open or closed)."""
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    cashbox_id: uuid.UUID
    status: str
    opening_balance: Decimal
    closing_balance: Decimal | None = None
    counted_balance: Decimal | None = None
    expected_balance: Decimal | None = None
    difference: Decimal | None = None
    opened_by: uuid.UUID
    closed_by: uuid.UUID | None = None
    opened_at: datetime.datetime
    closed_at: datetime.datetime | None = None
    # banco-caja-historial-ajustes (D5): snapshot persistido para sesiones
    # cerradas; el repository lo calcula al vuelo (Σ adjustment) para las
    # sesiones abiertas, donde la columna todavía no se materializó.
    adjustments_total: Decimal = Decimal("0")


class OpenSessionOut(BaseModel):
    """Output from rpc_open_cash_session (jsonb response)."""
    session_id: uuid.UUID
    cashbox_id: uuid.UUID
    status: str
    opening_balance: Decimal


class CloseSessionOut(BaseModel):
    """Output from rpc_close_cash_session (jsonb response)."""
    session_id: uuid.UUID
    status: str
    opening_balance: Decimal
    expected_balance: Decimal
    counted_balance: Decimal
    difference: Decimal
    closing_balance: Decimal
    # banco-caja-historial-ajustes (D5): expected_balance/difference NO
    # cambian de fórmula — siguen incluyendo los ajustes. adjustments_total
    # es el snapshot de Σ(adjustment) de la sesión; difference_before_
    # adjustments = difference + adjustments_total es la señal antifraude
    # (RN-95) que reconstruye lo que habría dado el arqueo sin los ajustes.
    adjustments_total: Decimal
    difference_before_adjustments: Decimal


# ── CashMovement ──────────────────────────────────────────────────────────────

class RegisterMovementIn(BaseModel):
    """
    Input para registrar un movimiento de efectivo.

    OQ-2 (resuelto): amount lleva signo (ingresos +, egresos −).
    La coherencia signo↔tipo se valida acá (service layer — no en DB CHECK).
    El DB CHECK valida solo que movement_type pertenece al enum.

    banco-caja-historial-ajustes (D4): `description` es el motivo del
    ajuste — obligatorio no vacío SOLO para movement_type='adjustment'
    (validado acá como primera red; el CHECK de DB
    cash_movements_adjustment_needs_reason es la autoridad final, D9 del
    design — el cliente/backend no reemplazan al servidor). Este mismo
    endpoint sirve para registrar el ajuste — no hay un camino paralelo
    (task 6.2).
    """
    # EL ORDEN IMPORTA: movement_type va ANTES que amount y description a
    # proposito. Pydantic v2 valida los campos en orden de declaracion y el
    # `info.data` de un field_validator solo trae los campos YA validados —
    # validate_sign_coherence (sobre amount) y validate_adjustment_reason
    # (sobre description) leen movement_type de ahi, asi que si alguien lo
    # mueve abajo vuelven a ser no-ops silenciosos. Fue un bug real: amount
    # iba primero y un `sale` con amount<0 llegaba a la RPC sin rechazo
    # (hallazgo de banco-caja-historial-ajustes, PR #440; corregido en
    # fix/caja-sign-coherence-validator). NO se usa model_validator porque
    # pierde el `loc` del error (el 422 RFC 7807 saldria con field="body" y
    # api-standards exige field = campo ofensor). Guardado por
    # test_cash_movement_sign_coherence.py, que asserta loc == ('amount',).
    movement_type: MovementType
    amount: Decimal
    reference_id: uuid.UUID | None = None
    # validate_default=True: Pydantic v2 SALTEA los field_validator de un
    # campo cuando el valor viene del DEFAULT (campo ausente del payload) en
    # vez de haber sido enviado explícitamente — el caso más común en la
    # práctica (un cliente que no manda `description` en absoluto, no que
    # mande `description: null`). Sin esto, validate_adjustment_reason NUNCA
    # se dispara para el payload real que un formulario manda al omitir el
    # campo — solo para el caso artificial de mandarlo explícitamente en null
    # (hallazgo del propio TDD de este change, ver test_banco_caja_historial_
    # ajustes.py).
    description: str | None = Field(default=None, validate_default=True)

    @field_validator("amount")
    @classmethod
    def validate_sign_coherence(cls, v, info):
        # movement_type ya esta validado (va antes en la clase, ver arriba).
        # Solo falta de info.data si el enum fallo — en ese caso Pydantic ya
        # reporta ese error y aca no agregamos un segundo.
        movement_type_value = info.data.get("movement_type")
        if movement_type_value is None:
            return v
        if movement_type_value in _INCOME_TYPES and v < 0:
            raise ValueError(
                f"movement_type '{movement_type_value}' es un ingreso: amount debe ser positivo."
            )
        if movement_type_value in _EXPENSE_TYPES and v > 0:
            raise ValueError(
                f"movement_type '{movement_type_value}' es un egreso: amount debe ser negativo."
            )
        # adjustment: signo libre (sobrante +/faltante -) — sin validación acá.
        return v

    @field_validator("description")
    @classmethod
    def validate_adjustment_reason(cls, v, info):
        movement_type_value = info.data.get("movement_type")
        if movement_type_value == MovementType.adjustment and (v is None or not v.strip()):
            raise ValueError(
                "un ajuste de caja requiere un motivo no vacío (description)."
            )
        return v


class RegisterMovementOut(BaseModel):
    """Output de rpc_register_cash_movement (jsonb response)."""
    movement_id: uuid.UUID


class CashMovementOut(BaseModel):
    """Output schema for a cash_movement row."""
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    session_id: uuid.UUID
    amount: Decimal
    movement_type: str
    reference_id: uuid.UUID | None = None
    balance_after: Decimal
    created_by: uuid.UUID
    created_at: datetime.datetime
    # banco-caja-historial-ajustes: motivo del movimiento (solo poblado para
    # 'adjustment' hoy; nullable para las 65 filas históricas y el resto de
    # tipos, que no lo exigen).
    description: str | None = None


# ── Historial paginado por cashbox (D2, ledger-movement-history) ──────────────

class CashMovementPageItem(CashMovementOut):
    """Fila del historial de una CAJA (no de una sesión) — D2 del design.

    Suma el contexto de sesión que el molde de Stock no necesita: en qué
    sesión cayó el movimiento y si esa sesión sigue abierta o ya cerró.
    """
    session_opened_at: datetime.datetime
    session_status: str


class CashMovementPageOut(PageOut[CashMovementPageItem]):
    """v3-api-standards §2: envelope estándar {items,total,page,pages}."""
