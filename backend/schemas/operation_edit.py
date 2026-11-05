"""edicion-operaciones-con-dinero (tanda B, grupo 10): contratos compartidos por la edición de ventas, compras y gastos.

El PLAN de dinero (D13) lo calcula la base (`_op_edit_plan`) y viaja tal cual al cliente, en vista previa y en la
respuesta de la edición real: acá sólo se TIPA. Ningún campo se recalcula en Python.

Cada libro de dinero —cuenta corriente de la parte, caja y banco— trae su `action` (`none`, `register`, `reverse`,
`both`) y el detalle de lo que compensa y registra. Los bloqueos de negocio (`P0426` sin sesión abierta, `P0425` saldo
final negativo, `P0424` período conciliado, `P0422` intención de caja, `P0403` rol, `P0400`, `P0412` y el fiscal `P0423`)
viajan en `blocks` como DATOS: en la vista previa no se levantan, en la edición real se levanta el primero.
"""
from __future__ import annotations

import datetime
import uuid
from decimal import Decimal

from pydantic import BaseModel, ConfigDict, Field


class VoidedFiscalDocumentOut(BaseModel):
    """venta-editable-sin-cae: comprobante que la edición ANULÓ (voided) porque su pedido todavía no había salido hacia
    ARCA. Lo devuelve `rpc_atomic_update_sale_operation` dentro de su jsonb."""

    model_config = ConfigDict(from_attributes=True)

    fiscal_document_id: uuid.UUID
    punto_de_venta: int
    number: int
    #: Etiqueta ya formateada por el servidor, p. ej. "0003-00000005".
    label: str


class EditBlockOut(BaseModel):
    """Un bloqueo de negocio del plan, como dato."""

    book: str
    code: str
    token: str
    message: str


class AccountReverseOut(BaseModel):
    ledger_id: uuid.UUID | None = None
    net: Decimal
    reference_id: uuid.UUID | None = None


class AccountRegisterOut(BaseModel):
    party_id: uuid.UUID | None = None
    amount: Decimal
    due_date: datetime.date | None = None
    reference_id: uuid.UUID | None = None


class AccountPlanOut(BaseModel):
    # `register` es un atributo de BaseModel: el campo se llama `register_` y viaja como `register` (alias).
    model_config = ConfigDict(populate_by_name=True)

    action: str = "none"
    party_kind: str | None = None
    party_id: uuid.UUID | None = None
    target_ledger: uuid.UUID | None = None
    register_: AccountRegisterOut | None = Field(default=None, alias="register")
    reverse: list[AccountReverseOut] = Field(default_factory=list)
    current_balance: Decimal | None = None
    projected_balance: Decimal | None = None
    current_due_date: datetime.date | None = None


class CashReverseOut(BaseModel):
    cashbox_id: uuid.UUID | None = None
    session_id: uuid.UUID | None = None
    net: Decimal
    reference_id: uuid.UUID | None = None
    movement_type: str | None = None


class CashRegisterOut(BaseModel):
    session_id: uuid.UUID | None = None
    cashbox_id: uuid.UUID | None = None
    amount: Decimal
    reference_id: uuid.UUID | None = None
    movement_type: str | None = None


class CashPlanOut(BaseModel):
    # `register` es un atributo de BaseModel: el campo se llama `register_` y viaja como `register` (alias).
    model_config = ConfigDict(populate_by_name=True)

    action: str = "none"
    register_: CashRegisterOut | None = Field(default=None, alias="register")
    reverse: list[CashReverseOut] = Field(default_factory=list)


class BankReverseOut(BaseModel):
    bank_account_id: uuid.UUID | None = None
    family: str | None = None
    net: Decimal
    mirror_type: str | None = None
    reference_id: uuid.UUID | None = None
    branch_id: uuid.UUID | None = None


class BankRegisterOut(BaseModel):
    bank_account_id: uuid.UUID | None = None
    amount: Decimal
    family: str | None = None
    reference_id: uuid.UUID | None = None
    value_date: datetime.date | None = None


class BankPlanOut(BaseModel):
    # `register` es un atributo de BaseModel: el campo se llama `register_` y viaja como `register` (alias).
    model_config = ConfigDict(populate_by_name=True)

    action: str = "none"
    register_: BankRegisterOut | None = Field(default=None, alias="register")
    reverse: list[BankReverseOut] = Field(default_factory=list)


class MoneyEditPlanOut(BaseModel):
    """El plan de dinero de una edición (D13)."""

    writes_money: bool = False
    blocks: list[EditBlockOut] = Field(default_factory=list)
    account: AccountPlanOut = Field(default_factory=AccountPlanOut)
    cash: CashPlanOut = Field(default_factory=CashPlanOut)
    bank: BankPlanOut = Field(default_factory=BankPlanOut)


class EditPreviewOut(BaseModel):
    """Respuesta de `POST .../edit-preview`: la misma validación que la edición, sin escribir nada."""

    dry_run: bool = True
    plan: MoneyEditPlanOut
    #: Sólo la venta: el comprobante pendiente que la edición real ANULARÍA (nada se anula en seco).
    voided_fiscal_document: VoidedFiscalDocumentOut | None = None


class OperationEditStateOut(BaseModel):
    """Lo que los tres listados exponen para decidir si se edita y para precargar el formulario (D15).

    `edit_locked_reason` es un token del SERVIDOR que falla cerrado: un token desconocido también deshabilita. Los demás
    campos salen de la huella neta (`op_money_footprint_state`): la parte y el vencimiento del cargo, la caja de la huella
    y su sesión abierta, y la cuenta bancaria de la huella. Defaults `None`: una fila sin el derivado = «sin dinero».
    """

    edit_locked_reason: str | None = None
    charge_due_date: datetime.date | None = None
    charge_party_id: uuid.UUID | None = None
    cash_cashbox_id: uuid.UUID | None = None
    cash_open_session_id: uuid.UUID | None = None
    bank_account_id: uuid.UUID | None = None


class OperationEditOut(BaseModel):
    """Una entrada del historial de ediciones de una operación (`audit_logs`, D14)."""

    id: uuid.UUID
    created_at: datetime.datetime
    user_id: uuid.UUID | None = None
    user_name: str | None = None
    action: str
    entity_type: str | None = None
    entity_id: uuid.UUID | None = None
    before: dict[str, object] | None = None
    after: dict[str, object] | None = None
    money: MoneyEditPlanOut | None = None
    voided_fiscal_document: VoidedFiscalDocumentOut | None = None
    reason: str | None = None
