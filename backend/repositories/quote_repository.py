"""
Repositorio del presupuesto (C-29 v21-quote-salesorder; reescrito por
presupuestos-modulo D2/D12).

Arquitectura 3 capas: sólo acceso a datos, sin lógica de negocio.

  - TODA escritura va por una RPC `SECURITY DEFINER` (`rpc_create_quote`,
    `rpc_update_quote`, `rpc_transition_quote`, `rpc_delete_quote`,
    `rpc_set_default_quote_validity`). NO hay `INSERT`/`UPDATE`/`DELETE` sobre
    `quotes` ni `quote_items`: desde la migración 20261067000001 no existen
    políticas de escritura y el rol de la aplicación ni siquiera tiene el
    privilegio. Un test (`test_quotes_module.py`) falla si un método vuelve a
    escribir esas tablas directo.
  - Las lecturas son `SELECT` con `account_id` EXPLÍCITO además de la RLS
    (regla dura desde el incidente de fuga multi-tenant #446: el pool corre con
    la RLS como red, nunca como único guard).
  - Los datos del emisor para el PDF vienen de `rpc_commercial_issuer`: la
    política de `profiles` sólo deja ver el perfil propio, así que leerlo por la
    conexión del request devolvería vacío cuando descarga alguien que no es el
    dueño.
  - JWT-passthrough vía `BaseRepository`: la conexión ya trae los claims.
"""
from __future__ import annotations

import datetime
import json
from typing import Any

from backend.repositories.base import BaseRepository

# Abierto con la validez ya pasada (día de negocio ART): el barrido todavía no
# lo marcó `expired`, pero para el usuario ya venció (design D7). Un único
# fragmento: lo usan la columna derivada y el filtro por estado del listado, de
# modo que no puedan divergir. COALESCE: sin validez no hay "vencido" (y `NOT
# NULL` excluiría la fila de la pestaña "Borradores").
_IS_EXPIRED = (
    "COALESCE(q.status IN ('draft', 'sent') AND q.valid_until < public.reporting_local_today(), false)"
)

_QUOTES_FROM = """
    FROM public.quotes q
    LEFT JOIN public.clients c
           ON c.id = q.client_id AND c.account_id = q.account_id
"""

# Estado EFECTIVO para las pestañas del listado: "Vencidos" junta los marcados
# `expired` y los abiertos ya vencidos; "Borradores" y "Enviados" excluyen a
# estos últimos. Así las pestañas no se solapan y coinciden con el badge.
_LIST_FILTERS = f"""
    WHERE q.account_id = $1::uuid
      AND ($2::uuid IS NULL OR q.client_id = $2::uuid)
      AND ($3::text IS NULL OR CASE $3::text
            WHEN 'expired' THEN (q.status = 'expired' OR {_IS_EXPIRED})
            WHEN 'draft'   THEN (q.status = 'draft' AND NOT {_IS_EXPIRED})
            WHEN 'sent'    THEN (q.status = 'sent' AND NOT {_IS_EXPIRED})
            ELSE q.status = $3::text
          END)
      AND ($4::text IS NULL
           OR c.name ILIKE $4::text
           OR c.legal_name ILIKE $4::text
           OR ($5::bigint IS NOT NULL AND q.number = $5::bigint))
"""

_LIST_PROJECTION = f"""
    q.id, q.branch_id, q.client_id,
    c.name AS client_name, c.phone AS client_phone,
    q.status, q.valid_until, {_IS_EXPIRED} AS is_expired,
    q.total, q.number, q.revision, q.created_at, q.sent_at, q.updated_at
"""


def _jsonb(value: Any) -> Any:
    """asyncpg devuelve jsonb como str cuando no hay codec registrado."""
    return json.loads(value) if isinstance(value, str) else value


def _like_pattern(text: str | None) -> str | None:
    """`%texto%` con los comodines de LIKE escapados: el usuario busca "50%",
    no "cualquier cosa que empiece con 50"."""
    text = (text or "").strip()
    if not text:
        return None
    escaped = text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    return f"%{escaped}%"


class QuoteRepository(BaseRepository):
    """Presupuestos y sus líneas — escritura por RPC, lectura con tenencia."""

    # ── Escrituras (una RPC por operación) ───────────────────────────────────

    async def create_quote(
        self,
        *,
        client_id: str,
        branch_id: str | None,
        valid_until: datetime.date | None,
        notes: str | None,
        items: list[dict],
    ) -> dict:
        """`rpc_create_quote`: alta en `draft`, número por disparador, total del
        servidor. La RPC resuelve la cuenta por el cliente. Devuelve el
        presupuesto con sus líneas (`id` y `account_id` incluidos)."""
        raw = await self._conn.fetchval(
            "SELECT public.rpc_create_quote($1::uuid, $2::uuid, $3::date, $4::text, $5::jsonb)",
            client_id,
            branch_id,
            valid_until,
            notes,
            json.dumps(items, default=str),
        )
        return _jsonb(raw)

    async def update_quote(
        self,
        quote_id: str,
        *,
        expected_revision: int,
        client_id: str,
        branch_id: str | None,
        valid_until: datetime.date,
        notes: str | None,
        items: list[dict],
    ) -> dict:
        """`rpc_update_quote`: reemplazo completo bajo `FOR UPDATE`. Rechaza una
        versión vieja (`quote_changed`) y un presupuesto convertido
        (`quote_locked_converted`)."""
        raw = await self._conn.fetchval(
            "SELECT public.rpc_update_quote("
            "$1::uuid, $2::integer, $3::uuid, $4::uuid, $5::date, $6::text, $7::jsonb)",
            quote_id,
            expected_revision,
            client_id,
            branch_id,
            valid_until,
            notes,
            json.dumps(items, default=str),
        )
        return _jsonb(raw)

    async def transition_quote(self, quote_id: str, to_status: str, reason: str | None) -> dict:
        """`rpc_transition_quote`: sólo `sent` y `rejected` (la RPC rechaza el
        resto). `sent` sobre un enviado es un no-op idempotente."""
        raw = await self._conn.fetchval(
            "SELECT public.rpc_transition_quote($1::uuid, $2::text, $3::text)",
            quote_id,
            to_status,
            reason,
        )
        return _jsonb(raw)

    async def delete_quote(self, quote_id: str) -> None:
        """`rpc_delete_quote`: sólo un borrador nunca enviado, decidido bajo lock."""
        await self._conn.fetchval("SELECT public.rpc_delete_quote($1::uuid)", quote_id)

    async def set_default_validity_days(self, days: int) -> int:
        """`rpc_set_default_quote_validity`: owner/admin, rango 1..365."""
        return await self._conn.fetchval("SELECT public.rpc_set_default_quote_validity($1::integer)", days)

    # ── Lecturas (SELECT con account_id explícito) ────────────────────────────

    async def get_quote(self, quote_id: str, account_id: str) -> dict | None:
        """Presupuesto con cliente, líneas (con el símbolo de su unidad) e
        historial. `None` si no existe O es de otra cuenta: el mismo resultado
        en los dos casos, para no revelar si el id existe en otro tenant."""
        header = await self._conn.fetchrow(
            f"""
            SELECT q.*,
                   {_IS_EXPIRED} AS is_expired,
                   c.name AS client_name, c.phone AS client_phone, c.tax_id AS client_tax_id,
                   (SELECT so.id
                      FROM public.sales_orders so
                     WHERE so.source_quote_id = q.id AND so.account_id = q.account_id
                     ORDER BY so.created_at DESC
                     LIMIT 1) AS sales_order_id
            {_QUOTES_FROM}
            WHERE q.id = $1::uuid AND q.account_id = $2::uuid
            """,
            quote_id,
            account_id,
        )
        if header is None:
            return None

        items = await self._conn.fetch(
            """
            SELECT qi.*, u.symbol AS unit_symbol
            FROM public.quote_items qi
            LEFT JOIN public.units_of_measure u ON u.id = qi.unit_id
            WHERE qi.quote_id = $1::uuid AND qi.account_id = $2::uuid
            ORDER BY qi.line_no NULLS LAST, qi.id
            """,
            quote_id,
            account_id,
        )
        history = await self._conn.fetch(
            """
            SELECT h.from_status, h.to_status, h.performed_by, h.reason, h.occurred_at
            FROM public.document_status_history h
            WHERE h.document_type = 'quote'
              AND h.document_id = $1::uuid
              AND h.account_id = $2::uuid
            ORDER BY h.occurred_at, h.id
            """,
            quote_id,
            account_id,
        )
        return {**dict(header), "items": [dict(i) for i in items], "history": [dict(h) for h in history]}

    async def list_quotes(
        self,
        account_id: str,
        *,
        page: int,
        page_size: int,
        status: str | None,
        client_id: str | None,
        text: str | None,
        number: int | None,
    ) -> tuple[list[dict], int]:
        """Listado paginado (`page` es 0-based). El COUNT usa EXACTAMENTE los
        mismos filtros y parámetros que la página: si divergen, `total` miente.

        `text` busca por nombre del cliente; `number` (que el service extrae
        del texto del buscador: "P-12", "12" o "00000012") por número de
        documento. Se cumple cualquiera de los dos.
        """
        args = (
            account_id,
            client_id,
            status,
            _like_pattern(text),
            number,
        )
        total: int = await self._conn.fetchval(
            f"SELECT COUNT(*) {_QUOTES_FROM} {_LIST_FILTERS}", *args
        ) or 0
        rows = await self._conn.fetch(
            f"""
            SELECT {_LIST_PROJECTION}
            {_QUOTES_FROM}
            {_LIST_FILTERS}
            ORDER BY q.created_at DESC, q.id
            LIMIT $6 OFFSET $7
            """,
            *args,
            page_size,
            page * page_size,
        )
        return [dict(r) for r in rows], total

    async def get_default_validity_days(self, account_id: str) -> int | None:
        """Validez por defecto de la cuenta. Lectura directa (RLS aplica); la
        escritura va SIEMPRE por la RPC con guard de rol."""
        return await self._conn.fetchval(
            "SELECT default_quote_validity_days FROM public.accounts WHERE id = $1::uuid",
            account_id,
        )

    async def get_commercial_issuer(self, account_id: str) -> dict:
        """Datos del emisor para el PDF comercial vía `rpc_commercial_issuer`
        (definer, con guard de membresía): ver el docstring del módulo."""
        raw = await self._conn.fetchval("SELECT public.rpc_commercial_issuer($1::uuid)", account_id)
        return _jsonb(raw)
