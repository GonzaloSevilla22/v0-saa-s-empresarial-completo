from __future__ import annotations

import datetime
import uuid

from pydantic import BaseModel, ConfigDict, Field

# metodos-pago-operaciones (D2): vocabulario cerrado, superset del CHECK de
# sales_orders.payment_method y de la taxonomía de cobro/pago — espejo del
# CHECK de la tabla payment_methods en la migración 20260928000001.
PAYMENT_METHOD_KINDS = ("cash", "transfer", "card", "check", "wallet", "credit", "other")


class PaymentMethodCreate(BaseModel):
    """Payload for POST /payment-methods."""

    name: str = Field(..., min_length=1, description="Nombre de la forma de pago")
    kind: str = Field(..., description=f"Vocabulario cerrado: {', '.join(PAYMENT_METHOD_KINDS)}")
    sort_order: int = Field(0, description="Orden del selector (menor = primero)")


class PaymentMethodUpdate(BaseModel):
    """Payload for PATCH /payment-methods/{id}.

    pos-banco-movimientos (D7): `bank_account_id` es tri-estado por AUSENCIA,
    no por valor — se distingue con `model_fields_set` en el router/service,
    NUNCA por `is None` (mismo contrato que `payment_method_id` en
    SaleOperationUpdateIn). No incluir el campo = conservar el destino
    vigente; incluirlo con `null` = desasignar; incluirlo con un uuid =
    asignar/reasignar.
    """

    name: str = Field(..., min_length=1, description="Nuevo nombre de la forma de pago")
    sort_order: int | None = Field(None, description="Nuevo orden del selector")
    bank_account_id: uuid.UUID | None = Field(
        None, description="Destino bancario por defecto (tri-estado por ausencia — ver docstring)"
    )


class PaymentMethodOut(BaseModel):
    """Response schema for payment method CRUD endpoints."""

    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    account_id: uuid.UUID
    name: str
    kind: str
    is_active: bool
    sort_order: int
    created_at: datetime.datetime
    # pos-banco-movimientos (D7): destino bancario por defecto — NULL = "no
    # registra movimiento bancario" (estado inicial de todo método sembrado).
    bank_account_id: uuid.UUID | None = None


# ── Reporte de distribución por forma de pago ─────────────────────────────────

class PaymentMethodReportRow(BaseModel):
    """Una fila de GET /reports/payment-methods — espejo de CostCenterReportRow."""

    model_config = ConfigDict(from_attributes=True)

    payment_method_id: uuid.UUID | None = None
    payment_method_name: str
    payment_method_kind: str | None = None
    is_active: bool
    total_sold: float
    total_purchased: float
    # gastos-forma-pago (D14): 8ª columna de rpc_payment_method_report. El
    # response_model FILTRA la salida a los campos declarados acá: sin esta
    # línea el total gastado se descarta entre el service y el cliente, y
    # /reportes/formas-pago muestra $0,00 en la columna "Gastado" de todas las
    # filas, en el pie y en la serie del gráfico, mientras la RPC lo calcula
    # bien. Default 0.0 por si una lectura llega de una base sin la migración.
    total_spent: float = 0.0
    operation_count: int
