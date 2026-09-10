from __future__ import annotations

import datetime
import uuid
from decimal import Decimal

from pydantic import BaseModel, ConfigDict, Field, field_validator

from backend.schemas.common import PageOut

# importador-gastos-transaccional (D8): tope de filas por lote, verificado en
# el SERVIDOR (acá y de nuevo en la RPC — el cliente lo aplica antes de subir,
# pero no es la autoridad). Trocear está PROHIBIDO por diseño (D8 del design):
# no es este número el que decide, es "no partir en sub-lotes".
EXPENSE_IMPORT_MAX_ROWS = 500


class ExpenseCreate(BaseModel):
    category: str
    # gastos-forma-pago: el importe es ESTRICTAMENTE POSITIVO, en las tres
    # capas (Pydantic → P0400 de la RPC → CHECK expenses_amount_positive). El
    # signo del movimiento lo pone el caller —caja postea `-importe`—, así que
    # un importe negativo escribe un movimiento 'expense' POSITIVO (un gasto
    # que suma plata al cajón) y desactiva en silencio la compensación del
    # borrado. Acá corta antes de tocar la base, con 422 y `loc = ("amount",)`.
    amount: Decimal = Field(gt=0)
    description: str | None = None
    date: datetime.date
    # cost-center-dimension: optional analytic dimension
    cost_center_id: uuid.UUID | None = None
    # ── gastos-forma-pago ────────────────────────────────────────────────────
    # Los cuatro campos de abajo son PASSTHROUGH OPT-IN: ausencia = no-op.
    # Las condiciones se validan en rpc_create_expense (SECURITY DEFINER),
    # NUNCA acá — el backend no evalúa guards de negocio (DEC-24).
    #
    # payment_method_id (D7): imputación opcional al catálogo de la cuenta.
    #   Nullable a propósito: los 175 gastos históricos quedan "Sin imputar".
    # branch_id (D6): la RPC lo resuelve con COALESCE(p_branch_id,
    #   c26_default_branch(cuenta)) — el mismo COALESCE que la venta.
    # cash_session_id (D1): opt-in de caja. NULL = el gasto no toca caja. Si
    #   viene informado, la RPC valida las TRES condiciones del formulario de
    #   venta (kind=cash, sesión abierta en la sucursal efectiva, fecha = hoy
    #   local) y rechaza con P0422 si alguna falla.
    # bank_account_id (D5): override explícito de la cuenta bancaria de la que
    #   sale el dinero. NULL = usar el default de la forma de pago; si tampoco
    #   hay y la organización TIENE bancos activos, la RPC exige elegir una
    #   (P0412 → 422 con field, D19).
    payment_method_id: uuid.UUID | None = None
    branch_id: uuid.UUID | None = None
    cash_session_id: uuid.UUID | None = None
    bank_account_id: uuid.UUID | None = None


class ExpenseUpdate(BaseModel):
    """Payload de edición de un gasto.

    gastos-forma-pago (D12): `payment_method_id`, `branch_id` y
    `cost_center_id` son TRI-ESTADO **por AUSENCIA**, no por valor — se
    distinguen con `model_fields_set` en el service, NUNCA por `is None`:

      · clave ausente del JSON  → preservar el valor vigente
      · clave con `null`        → desimputar explícito
      · clave con uuid          → reimputar

    Mismo contrato que `SaleOperationUpdateIn` / `rpc_atomic_update_purchase_
    operation`. El `UPDATE ... SET` compuesto en Python que había antes
    filtraba los `None` y por eso borraba el centro de costo en cada edición,
    en silencio (bug pre-existente que este change cierra).

    La firma NO acepta `cash_session_id` ni `bank_account_id`: la edición no
    postea movimientos (D11/D13). Un gasto que ya movió plata es inmutable
    (P0423); uno que no, sólo cambia de etiqueta.
    """

    category: str | None = None
    # Espejo del alta: ausente = "no cambia" (la RPC lo resuelve con COALESCE),
    # pero un valor presente tiene que ser positivo — sin esto la edición sería
    # el bypass del guard del alta.
    amount: Decimal | None = Field(default=None, gt=0)
    description: str | None = None
    date: datetime.date | None = None
    # cost-center-dimension: optional analytic dimension
    cost_center_id: uuid.UUID | None = None
    payment_method_id: uuid.UUID | None = None
    branch_id: uuid.UUID | None = None


class ExpenseOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    user_id: uuid.UUID
    category: str
    amount: Decimal
    description: str | None
    date: datetime.date
    created_at: datetime.datetime
    # cost-center-dimension: optional analytic dimension (nullable)
    cost_center_id: uuid.UUID | None = None
    # gastos-forma-pago (D6/D7): imputación del gasto. El NOMBRE lo resuelve el
    # servidor por LEFT JOIN al catálogo (sin filtrar is_active/deleted_at: una
    # forma dada de baja tiene que seguir nombrándose), nunca un Map en cliente.
    payment_method_id: uuid.UUID | None = None
    payment_method_name: str | None = None
    payment_method_kind: str | None = None
    branch_id: uuid.UUID | None = None
    # ── Derivados de lectura (D11/D18) ───────────────────────────────────────
    # Espejo literal de SaleItemOut.is_payment_locked: se calculan en el
    # servidor con los MISMOS `EXISTS` que evalúan los guards de la edición
    # (P0423) y del borrado (P0426), para que la lista deshabilite el control
    # con el motivo visible ANTES de que el usuario llegue al error.
    # Default False: un gasto que llega sin el derivado (lectura vieja) se
    # trata como NO bloqueado y el servidor sigue siendo la autoridad.
    is_payment_locked: bool = False
    has_cash_movement: bool = False
    has_bank_movement: bool = False
    is_delete_blocked: bool = False

    @field_validator("date", mode="before")
    @classmethod
    def _coerce_datetime_to_date(cls, v: object) -> object:
        # expenses.date es `timestamptz`: las filas con hora ≠ 00:00 llegan como
        # datetime y Pydantic las rechaza contra `date` (date_from_datetime_inexact)
        # → 500. Tomamos la parte de fecha. Espejo de SaleItemOut/PurchaseItemOut.
        if isinstance(v, datetime.datetime):
            return v.date()
        return v


# gastos-forma-pago D18 — BREAKING de API interna sancionado: `GET /expenses`
# deja de devolver una lista plana y adopta el envelope estándar
# {items,total,page,pages} de v3-api-standards §2, igual que `GET /sales`.
ExpensesPageOut = PageOut[ExpenseOut]


# ── importador-gastos-transaccional ─────────────────────────────────────────
#
# El lote es UNA SOLA unidad de trabajo de servidor (rpc_import_expenses,
# SECURITY DEFINER, DEC-24) que invoca rpc_create_expense por fila — este
# módulo NO evalúa ninguna regla de negocio nueva (D1 del design): sólo
# valida la FORMA del payload (lo que Pydantic ya hace bien) y delega.


class ExpenseImportRowIn(BaseModel):
    """Una fila del archivo, ya parseada por el cliente.

    `amount` reutiliza la MISMA restricción que `ExpenseCreate.amount`
    (`gt=0`, D1 de gastos-forma-pago) — no una segunda definición de "importe
    válido". Las tres columnas de catálogo son SIEMPRE opcionales (D4): una
    celda vacía cae al default del lote (o a rpc_create_expense, que no
    imputa nada); un nombre que NO resuelve es error de fila, nunca un
    default silencioso — eso lo decide la RPC, no este schema.
    """

    row_no: int = Field(gt=0)
    description: str
    category: str
    amount: Decimal = Field(gt=0)
    date: datetime.date
    payment_method_name: str | None = None
    branch_name: str | None = None
    cost_center_name: str | None = None


class ExpenseImportIn(BaseModel):
    """Payload de `POST /expenses/import`.

    `idempotency_key` es el fallback deprecado del body (v3-api-standards
    §3) — el header `Idempotency-Key` tiene precedencia, resuelta en el
    router con `require_idempotency_key` (igual que bank-reconciliation).
    """

    idempotency_key: str | None = None
    file_name: str
    file_hash: str
    dry_run: bool = False
    default_payment_method_id: uuid.UUID | None = None
    default_branch_id: uuid.UUID | None = None
    default_cost_center_id: uuid.UUID | None = None
    fallback_bank_account_id: uuid.UUID | None = None
    rows: list[ExpenseImportRowIn] = Field(min_length=1, max_length=EXPENSE_IMPORT_MAX_ROWS)


class ExpenseImportErrorOut(BaseModel):
    row: int
    code: str
    message: str


class ExpenseImportNoticeOut(BaseModel):
    row: int
    code: str
    message: str


class ExpenseImportOut(BaseModel):
    """Reporte del lote — SIEMPRE `200`, aplicado o rechazado (D11 del design).

    Un lote rechazado no es un error de protocolo: es un resultado de negocio
    con estructura. Los `4xx` quedan para lo que sí lo es (payload
    malformado, tope excedido, sin rol de escritura, sin clave de
    idempotencia).
    """

    committed: bool
    import_id: uuid.UUID | None
    imported: int
    errors: list[ExpenseImportErrorOut]
    notices: list[ExpenseImportNoticeOut]
    replayed: bool
    dry_run: bool
