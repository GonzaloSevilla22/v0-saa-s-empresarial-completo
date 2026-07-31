"""Repository de límites de plan — billing-pro-trial (D5).

`plan_limits` es la única fuente de verdad de los límites numéricos por plan
(spec `plan-gating`: "Los límites SHALL leerse de plan_limits en runtime en
todas las capas que los enforcean, incluido el backend Python"). Reemplaza a
`PLAN_PRODUCT_LIMITS` (constante hardcodeada que en `avanzado` divergía de la
DB: 2000 en código vs 1500 en `plan_limits`).

Caché en proceso de corta duración (design.md D5: "los límites cambian con
frecuencia cero"). `clear_cache()` es el punto de reset explícito para tests —
sin él, el caché a nivel de módulo filtraría valores entre tests que corren en
el mismo proceso.
"""
from __future__ import annotations

import time

from backend.repositories.base import BaseRepository

_CACHE_TTL_SECONDS = 300.0

# plan -> (cached_at_monotonic, limits)
_cache: dict[str, tuple[float, dict[str, int]]] = {}

_FALLBACK_LIMITS: dict[str, int] = {
    "max_products": 100,
    "max_clients": 50,
    "max_suppliers": 20,
}


def clear_cache() -> None:
    """Vacía el caché en proceso. Usado por tests (fixture autouse) y puede
    invocarse manualmente tras un UPDATE administrativo de `plan_limits`."""
    _cache.clear()


class PlanLimitsRepository(BaseRepository):
    async def get_limits(self, plan: str) -> dict[str, int]:
        """Devuelve los límites de recursos maestros del plan dado.

        Fail-safe: si el plan no existe en `plan_limits` (dato corrupto o
        plan inválido), devuelve los límites de `gratis` en vez de lanzar —
        el guard de creación sigue pudiendo bloquear en vez de fallar 500.
        """
        cached = _cache.get(plan)
        now = time.monotonic()
        if cached is not None and (now - cached[0]) < _CACHE_TTL_SECONDS:
            return cached[1]

        row = await self.fetchrow(
            "SELECT max_products, max_clients, max_suppliers "
            "FROM plan_limits WHERE plan = $1",
            plan,
        )
        limits = (
            {
                "max_products": row["max_products"],
                "max_clients": row["max_clients"],
                "max_suppliers": row["max_suppliers"],
            }
            if row is not None
            else dict(_FALLBACK_LIMITS)
        )
        _cache[plan] = (now, limits)
        return limits
