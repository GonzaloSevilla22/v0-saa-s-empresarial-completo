"""Repository del historial de ediciones de una operación (edicion-operaciones-con-dinero, tanda B, D14).

UN solo repositorio de lectura de auditoría para las tres operaciones (venta, compra y gasto): las tres RPCs de edición
dejan su rastro en `audit_logs` con `action` = `sale_operation.edited` | `purchase_operation.edited` | `expense.edited` y
`entity_id` = el identificador estable de la operación.

Tenencia: `audit_logs` sólo tiene una policy heredada por `company_id`, ninguna por cuenta, así que una lectura directa con
la RLS del usuario no devolvería nunca estas filas. La lectura va por `rpc_operation_edits` (SECURITY DEFINER), que filtra por
la cuenta ACTIVA de la sesión de forma explícita —nunca por un parámetro— y sólo para las tres acciones de edición.
"""
from __future__ import annotations

import json

from backend.repositories.base import BaseRepository


def _jsonb(value):
    """asyncpg entrega jsonb como `str` cuando no hay type codec registrado."""
    return json.loads(value) if isinstance(value, str) else value


class OperationEditRepository(BaseRepository):
    async def list_edits(self, action: str, entity_id: str, limit: int = 100) -> list[dict]:
        rows = await self._conn.fetch(
            "SELECT * FROM public.rpc_operation_edits($1::text, $2::uuid, $3::int)",
            action,
            entity_id,
            limit,
        )
        edits: list[dict] = []
        for row in rows:
            record = dict(row)
            metadata = _jsonb(record.pop("metadata", None)) or {}
            edits.append(
                {
                    **record,
                    "before": metadata.get("before"),
                    "after": metadata.get("after"),
                    "money": metadata.get("money"),
                    "voided_fiscal_document": metadata.get("voided_fiscal_document"),
                    "reason": metadata.get("reason"),
                }
            )
        return edits
