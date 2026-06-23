"""
v21-wsfe-production-hardening — TicketCache port (D5).

Interface para la cache del Ticket de Acceso (TA) de WSAA.

El TA dura ~12h; WSAA rechaza un nuevo loginCms dentro de ~10 min
("el CUIT ya posee un TA valido"). La cache DEBE sobrevivir entre
invocaciones del relay (pg_cron + background = procesos separados).

La implementacion concreta (Postgres) vive en wsaa_ticket_cache.py.
Los tests usan FakeTicketCache (in-memory) — ver test_wsfe_ta_cache.py.

Cache key: "{cuit_emisor}:wsfe:{ambiente}"  (incluye el servicio 'wsfe')

Design ref: D5 (PO sign-off: Postgres, 2026-06-23)
"""
from __future__ import annotations

import datetime
from abc import ABC, abstractmethod


class TicketCache(ABC):
    """Puerto de cache del TA de WSAA.

    El adapter inyecta una implementacion concreta de este puerto para
    reusar el TA vigente sin llamar a loginCms en cada invocacion.
    """

    @abstractmethod
    def get(self, key: str) -> tuple[str, str, datetime.datetime] | None:
        """Retornar (token, sign, expires_at) si el TA esta vigente, None si no.

        Args:
            key: cache key en formato "{cuit}:wsfe:{ambiente}".

        Returns:
            (token, sign, expires_at) si existe y no expirado, None en otro caso.
            La implementacion es responsable de chequear la expiracion.
        """
        ...

    @abstractmethod
    def set(
        self,
        key: str,
        token: str,
        sign: str,
        expires_at: datetime.datetime,
    ) -> None:
        """Persistir el TA con su expiracion.

        Args:
            key: cache key en formato "{cuit}:wsfe:{ambiente}".
            token: token del TA de WSAA.
            sign: sign del TA de WSAA.
            expires_at: datetime de expiracion (con timezone UTC).
        """
        ...
