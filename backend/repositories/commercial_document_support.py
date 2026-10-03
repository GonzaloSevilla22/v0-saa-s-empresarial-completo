"""
Piezas de acceso a datos que comparten los repositorios de los documentos
comerciales no fiscales (presupuesto, remito): una sola definición de cada una
(regla del proyecto: reutilización antes que repetición).

  - `jsonb_value`: asyncpg devuelve `jsonb` como `str` cuando no hay codec.
  - `like_pattern`: `%texto%` con los comodines de LIKE escapados.
  - `CommercialIssuerMixin.get_commercial_issuer`: los datos del emisor del PDF
    vía `rpc_commercial_issuer` (definer, con guard de membresía). La política de
    `profiles` sólo deja ver el perfil propio, así que leerlo por la conexión
    del request devolvería vacío cuando descarga alguien que no es el dueño.
"""
from __future__ import annotations

import json
from typing import Any


def jsonb_value(value: Any) -> Any:
    """asyncpg devuelve jsonb como str cuando no hay codec registrado."""
    return json.loads(value) if isinstance(value, str) else value


def like_pattern(text: str | None) -> str | None:
    """`%texto%` con los comodines de LIKE escapados: el usuario busca "50%",
    no "cualquier cosa que empiece con 50"."""
    text = (text or "").strip()
    if not text:
        return None
    escaped = text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    return f"%{escaped}%"


class CommercialIssuerMixin:
    """Lectura del emisor del documento comercial. Requiere `self._conn`."""

    _conn: Any

    async def get_commercial_issuer(self, account_id: str) -> dict:
        """Datos del emisor para el PDF comercial vía `rpc_commercial_issuer`
        (definer, con guard de membresía): ver el docstring del módulo."""
        raw = await self._conn.fetchval("SELECT public.rpc_commercial_issuer($1::uuid)", account_id)
        return jsonb_value(raw)
