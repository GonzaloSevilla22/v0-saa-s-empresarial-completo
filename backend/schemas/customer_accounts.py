"""
Schemas Pydantic v2 para C-30 — CustomerAccount / PaymentReceived.
bank-payment-routing C2: PaymentReceivedIn gana payment_method + bank_account_id
(taxonomía {cash,transfer,card,check}, default cash, retrocompatible).

cobranzas-catalogo-pagos (D1/D2): payment_method (str) → payment_method_id
(uuid, opcional). El kind (y por lo tanto la taxonomía aceptada — 6 de 7,
credit rechazado) se DERIVA en el servidor desde el catálogo bajo el
account_id del tenant — Pydantic ya no puede validarlo sin consultar la DB, así
que las dos validaciones que dependían del texto (payment_method en la
taxonomía, bank_account_id exigido para un kind bancario, cash_session_id
exigido con kind=cash) se retiran de acá: la RPC ya las tiene y son la única
autoridad posible sin duplicar una consulta al catálogo desde el schema.

Enums:
  CustomerMovementType: sale | payment_received | credit_note | adjustment

Models:
  CustomerAccountOut       — fila de customer_accounts
  AccountMovementOut       — fila de customer_account_movements
  PaymentReceivedIn        — payload de rpc_register_payment_received
  PaymentReceivedOut       — respuesta de rpc_register_payment_received
  CreateCustomerAccountOut — respuesta de rpc_create_customer_account
"""
from __future__ import annotations

import datetime
import uuid
from decimal import Decimal
from enum import Enum

from pydantic import BaseModel, ConfigDict, field_validator

from backend.schemas.common import PageOut


class CustomerMovementType(str, Enum):
    sale             = "sale"
    payment_received = "payment_received"
    credit_note      = "credit_note"
    adjustment       = "adjustment"


class CustomerAccountOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id:         uuid.UUID
    account_id: uuid.UUID
    client_id:  uuid.UUID
    balance:    Decimal
    created_at: datetime.datetime


class AccountMovementOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id:                   uuid.UUID
    customer_account_id:  uuid.UUID
    account_id:           uuid.UUID
    amount:               Decimal
    balance_after:        Decimal
    movement_type:        str
    reference_id:         uuid.UUID | None = None
    created_by:           uuid.UUID
    created_at:           datetime.datetime
    # caja-compras-cobranzas (OQ-1, task 8.5): resuelto por LEFT JOIN a
    # payments_received cuando movement_type='payment_received'. NULL para
    # todo el resto de los tipos y para los cobros históricos (sin backfill).
    # cobranzas-catalogo-pagos (D3/task 6.5): el JOIN pasa de
    # payments_received.payment_method (texto crudo del kind) a
    # payment_methods.name (el nombre que el usuario configuró) — se
    # conserva el NOMBRE del campo para no romper el frontend, que ya lo
    # consume como "la forma de pago del cobro".
    payment_method:       str | None = None
    # cobranzas-reverso (D12, task 8.2): derivados en el SERVIDOR con EXISTS
    # — nunca columnas denormalizadas (regla D5 de delete-guard-ledgers).
    # is_reversible: el movimiento es 'payment_received' Y su documento sigue
    # vivo en payments_received. is_reversal_blocked: el cobro tiene
    # movimiento de caja Y no hay sesión abierta en esa caja — el MISMO EXISTS
    # que evalúa rpc_reverse_payment_received. Default False: un movimiento
    # sin resolver esos EXISTS (p.ej. en un test que no los provee) nunca
    # ofrece la acción por default.
    is_reversible:        bool = False
    is_reversal_blocked:  bool = False
    # cobranzas-reverso (task 9.2): mismo molde que PurchaseOperationOut
    # (has_cash_movement/has_bank_movement) — el diálogo de anulación los
    # necesita para enumerar sólo las patas que aplican a ESTE pago.
    has_cash_movement:    bool = False
    has_bank_movement:    bool = False


# v3-api-standards §2.7: envelope estándar {items,total,page,pages} para
# GET /customer-accounts/{id}/movements — reemplaza la lista plana de
# limit/offset. BREAKING sancionado (OQ1 PO).
AccountMovementPageOut = PageOut[AccountMovementOut]


class ReceivableRowOut(BaseModel):
    """cobranzas-panel (task 3.4): fila del read-model de cuentas por cobrar.

    Las antigüedades son `int | None` — NULL cuando no existe ningún
    movimiento del tipo (OQ-4: deuda nacida de adjustment), y la superficie
    lo muestra como ausencia, nunca como 0."""

    client_id:               uuid.UUID
    client_name:             str
    balance:                 Decimal
    days_since_last_charge:  int | None = None
    days_since_last_payment: int | None = None
    last_payment_date:       datetime.date | None = None


# Envelope estándar {items,total,page,pages} (api-standards §2).
ReceivablePageOut = PageOut[ReceivableRowOut]


class ReceivablesSummaryOut(BaseModel):
    """cobranzas-panel (D2): total por cobrar + cantidad de deudores,
    derivados del MISMO RPC que el listado. El importe NO viaja en el
    envelope de paginación (cuyo `total` es cantidad de filas)."""

    total_receivable: Decimal
    debtor_count:     int


class CreateCustomerAccountOut(BaseModel):
    customer_account_id: uuid.UUID
    client_id:           uuid.UUID
    balance:             Decimal


class PaymentReceivedIn(BaseModel):
    # v3-api-standards §3.2: opcional+deprecado (D4).
    idempotency_key:    str | None = None
    client_id:          uuid.UUID
    amount:             Decimal
    reference_sale_id:  uuid.UUID | None = None
    # cobranzas-catalogo-pagos (D1/D2): identificador del catálogo — el kind
    # (y por lo tanto si es bancario, si es cash, si es credit) se DERIVA en
    # el servidor bajo el account_id del tenant. NULL = sin imputar (no
    # rompe nada: los cobros anteriores a este cambio quedaron así, sin
    # backfill, D3).
    payment_method_id:  uuid.UUID | None = None
    bank_account_id:    uuid.UUID | None = None
    # caja-compras-cobranzas (D5): opt-in de caja. NULL = el cobro no toca
    # caja. Con sesión informada, la RPC valida DOS condiciones (no tres: el
    # cobro no tiene fecha ni sucursal propias) y rechaza con P0422 si alguna
    # falla.
    cash_session_id:    uuid.UUID | None = None

    @field_validator("amount")
    @classmethod
    def validate_positive(cls, v: Decimal) -> Decimal:
        if v <= 0:
            raise ValueError("amount debe ser > 0")
        return v

    # cobranzas-catalogo-pagos (task 6.3/6.4): las dos validaciones que vivían
    # acá — "bank_account_id exigido si el método es bancario" y
    # "cash_session_id exigido sólo con kind=cash" — dependían de leer el
    # kind directamente del payload (payment_method era texto). Con
    # payment_method_id como uuid, Pydantic NO conoce el kind sin consultar
    # el catálogo, y consultarlo desde el schema duplicaría la fuente de
    # verdad que ya vive en la RPC (regla de reutilización, PO 2026-08-02).
    # Las dos validaciones se retiran EN LUGAR de reimplementarse a medias:
    # la RPC ya las tiene (P0400 bank_account_required / P0412 para la
    # primera, P0422 cash_optin_requires_cash_kind para la segunda) y sigue
    # siendo, como siempre, la única autoridad real — este schema nunca fue
    # más que una defensa en profundidad que ahorraba un round-trip.


class PaymentReceivedOut(BaseModel):
    payment_id:           uuid.UUID | None
    customer_account_id:  uuid.UUID | None
    balance_after:        Decimal | None
    replayed:             bool
    operation_id:         uuid.UUID | None = None


class PaymentReversalIn(BaseModel):
    """cobranzas-reverso (D1 apply, OQ-2): motivo OPCIONAL — se muestra en el
    diálogo y viaja al `description` del contra-movimiento de caja y al
    payload del evento, pero nunca es exigido (rpc_reverse_payment_received
    no lo requiere; D9: la anulación es idempotente por ausencia del
    documento, sin p_idempotency_key)."""
    reason: str | None = None


class PaymentReversalOut(BaseModel):
    """Respuesta de rpc_reverse_payment_received (jsonb)."""
    payment_id:           uuid.UUID
    reversed:              bool
    account_movement_id:  uuid.UUID
    cash_reversal_id:      uuid.UUID | None = None
    bank_reversals:        int = 0
