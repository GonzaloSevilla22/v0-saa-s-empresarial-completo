from __future__ import annotations

import datetime
import uuid
from decimal import Decimal

from pydantic import BaseModel, ConfigDict, field_validator

from backend.schemas.common import PageOut


class PurchaseItemIn(BaseModel):
    product_id: str
    quantity: Decimal
    amount: Decimal
    description: str | None = None
    unit_id: str | None = None


class PurchaseOperationIn(BaseModel):
    # v3-api-standards §3.2: opcional+deprecado (ver SaleOperationIn).
    idempotency_key: str | None = None
    org_id: str
    items: list[PurchaseItemIn]
    date: datetime.date | None = None
    # caja-compras-cobranzas (D3): sucursal de la operación. Bug preexistente
    # que este change cierra: la cadena entera la descartaba (0 de 507
    # compras con branch_id) — el frontend nunca la mandaba en el payload de
    # alta y el repository pasaba NULL literal a la RPC. Es el ancla de la
    # condición 2 del opt-in de caja de más abajo (sesión abierta en la
    # sucursal EFECTIVA de la compra).
    branch_id: uuid.UUID | None = None
    # cost-center-dimension: optional, shared by all lines of the operation
    cost_center_id: uuid.UUID | None = None
    # metodos-pago-operaciones: optional, shared by all lines of the operation
    payment_method_id: uuid.UUID | None = None
    # pos-banco-movimientos (D2): override explícito de la cuenta bancaria
    # destino del egreso. None = default del método (o no escribir nada).
    bank_account_id: uuid.UUID | None = None
    # compras-proveedor-cuenta-corriente (D4): atributo DE LA OPERACIÓN (no de
    # línea) — trailing en la RPC, igual que cost_center_id/payment_method_id/
    # bank_account_id. Si el payment_method imputado es kind='credit', la RPC
    # exige este campo (P0400 credit_requires_supplier) y postea el cargo real.
    supplier_id: uuid.UUID | None = None
    # caja-compras-cobranzas (D2): opt-in de caja. NULL = la compra no toca
    # caja. Si viene informado, la RPC valida las TRES condiciones del
    # formulario de venta/gasto (kind=cash, sesión abierta en la sucursal
    # efectiva, fecha=hoy local) y rechaza con P0422 si alguna falla.
    cash_session_id: uuid.UUID | None = None


class PurchaseOperationOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    operation_id: uuid.UUID
    operation_kind: str | None = None


class PurchaseOperationUpdateItemIn(BaseModel):
    product_id: str
    quantity: Decimal
    amount: Decimal
    # edicion-preserva-contexto (F1 §D7): unit_id viaja pegado a la línea —
    # espejo de SaleOperationUpdateItemIn.unit_id.
    unit_id: str | None = None


class PurchaseOperationUpdateIn(BaseModel):
    """Payload del editor de compras: reemplaza los ítems de una operación.
    Lo consume rpc_atomic_update_purchase_operation (REVERSE + APPLY sobre branch_stock).

    metodos-pago-operaciones (D5): `payment_method_id` es tri-estado por
    AUSENCIA, no por valor — se distingue con `model_fields_set` en el router/
    service, NUNCA por `is None`. No incluir el campo en el JSON = preservar el
    vigente; incluirlo con `null` = desimputar explícito ("Sin especificar");
    incluirlo con un uuid = reimputar. Ver PaymentMethodSelect (frontend).

    edicion-preserva-contexto (F1 §D3): `branch_id` usa el mismo contrato
    tri-estado — `model_fields_set`, nunca `is None`.

    compras-proveedor-cuenta-corriente (D7, OQ-5 opción A): `supplier_id` y
    `cost_center_id` entran al MISMO contrato tri-estado — cierra la OQ-1 de
    edicion-preserva-contexto, que los dejó "preservados pero no parámetro"
    porque el form de edición no tenía selector para ninguno de los dos. La
    edición NUNCA postea/revierte cargos de cuenta corriente (una compra con
    cargo posteado ya es inmutable, P0423) — reimputar acá es solo cambiar
    una FK.
    """
    purchase_ids: list[str]
    items: list[PurchaseOperationUpdateItemIn]
    date: datetime.date
    description: str | None = None
    payment_method_id: uuid.UUID | None = None
    branch_id: uuid.UUID | None = None
    supplier_id: uuid.UUID | None = None
    cost_center_id: uuid.UUID | None = None


class PurchaseItemOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    date: datetime.date
    product_id: uuid.UUID | None = None
    product_name: str | None = None
    operation_id: uuid.UUID | None = None
    quantity: Decimal
    amount: Decimal
    total: Decimal | None = None
    description: str | None = None
    # cost-center-dimension: optional analytic dimension (nullable)
    cost_center_id: uuid.UUID | None = None
    # cost-center-surface: nombre del centro para el badge del listado, resuelto
    # en el mismo query (LEFT JOIN cost_centers) — evita un round-trip extra.
    cost_center_name: str | None = None
    # metodos-pago-operaciones: forma de pago opcional (nullable), resuelta en
    # el mismo query (LEFT JOIN payment_methods) para el badge del listado.
    payment_method_id: uuid.UUID | None = None
    payment_method_name: str | None = None
    payment_method_kind: str | None = None
    # edicion-preserva-contexto (D11): branch_id/unit_id expuestos para
    # prefillear el form de edición (espejo de SaleItemOut).
    branch_id: uuid.UUID | None = None
    unit_id: uuid.UUID | None = None
    # compras-proveedor-cuenta-corriente (task 9.2): supplier_id + nombre
    # (LEFT JOIN suppliers), para el badge del listado y el prefill del
    # selector de edición — reemplaza el comentario D11 que decía "supplier_id
    # NO se expone" (era cierto hasta que este change agregó el selector).
    supplier_id: uuid.UUID | None = None
    supplier_name: str | None = None
    # pagos-cableados-restantes (D6): derivado de lectura (mismo predicado
    # que el guard P0423 de rpc_atomic_update_purchase_operation), para que
    # la lista deshabilite "Editar" con motivo visible ANTES de que el
    # usuario llegue al error del backend.
    is_payment_locked: bool = False
    # qa-integral-modulos G10 (H12): los dos EXISTS que `list_paginated_by_
    # operation` ya calcula por separado (repositories/purchase_repository.py)
    # tienen que DECLARARSE acá o Pydantic los descarta al serializar y el
    # diálogo de borrado nunca puede enumerar el cargo en cuenta corriente
    # (frontend/lib/delete-compensation.ts depende de hasAccountCharge, no de
    # is_payment_locked). Espejo de ExpenseItemOut; default False = una fila
    # sin el derivado se trata como "sin dinero posteado" y el servidor sigue
    # siendo la autoridad al borrar.
    has_account_charge: bool = False
    has_bank_movement: bool = False
    # caja-compras-cobranzas (D9): mismos dos derivados que ExpenseItemOut —
    # tienen que DECLARARSE en el modelo Pydantic o Pydantic los descarta al
    # serializar (lección G10/H12 de qa-integral-modulos). is_delete_blocked
    # = hay movimiento de caja Y no hay sesión abierta en esa caja (mismo
    # EXISTS que precede al P0426 de rpc_delete_purchase_operation).
    has_cash_movement: bool = False
    is_delete_blocked: bool = False

    @field_validator("date", mode="before")
    @classmethod
    def _coerce_datetime_to_date(cls, v: object) -> object:
        # purchases.date es `timestamptz`: las filas con hora ≠ 00:00 llegan como
        # datetime y Pydantic las rechaza contra `date` (date_from_datetime_inexact)
        # → 500. Tomamos la parte de fecha. Espejo de SaleItemOut.
        if isinstance(v, datetime.datetime):
            return v.date()
        return v


# v3-api-standards §2: envelope estándar {items,total,page,pages}, reemplaza
# el PurchasesPageOut previo ({items,total_operations}) — BREAKING sancionado
# (OQ1 PO), frontend migrado en el mismo change.
PurchasesPageOut = PageOut[PurchaseItemOut]
