"""
v3-api-standards §2 — Contrato de paginación estándar del backend.

`PageOut[T]` es el envelope único que todos los listados paginados
SHALL usar: `{items, total, page, pages}`. Reemplaza los shapes previos
divergentes (`SalesPageOut`/`PurchasesPageOut` con `total_operations`,
`PaymentReceiptsPageOut` con `total`, y las listas planas de
customer_accounts/supplier_accounts/journal_entries).
"""
from __future__ import annotations

from typing import Generic, TypeVar

from pydantic import BaseModel

T = TypeVar("T")


class PageOut(BaseModel, Generic[T]):
    """Envelope estándar de paginación.

    `page` es 0-based. `pages = ceil(total / size)`, con `pages = 0` cuando
    `total == 0` (sin división por cero).
    """

    items: list[T]
    total: int
    page: int
    pages: int
