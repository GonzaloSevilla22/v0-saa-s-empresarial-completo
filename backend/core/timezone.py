"""
Zona horaria del negocio (Argentina).

factura-fiscal-imprimible (OQ-7, firmada por el PO el 2026-09-26): la fecha
del comprobante que se le pide a ARCA (`CbteFch`) es la del día en Argentina,
no la del reloj del servidor — Render corre en UTC, así que una factura pedida
entre las 21:00 y las 23:59 salía fechada al día siguiente, y esa fecha va
impresa en la factura y codificada en su QR.

La zona es `America/Argentina/Mendoza`, la misma que el resto del backend usa
en SQL para "el día de negocio" (`AT TIME ZONE 'America/Argentina/Mendoza'`).

`zoneinfo` necesita la base de zonas del sistema o el paquete `tzdata`. Linux
(Render, CI) la trae; Windows (el entorno local) no. Sin base de zonas se cae a
UTC−3 fijo, que ES la regla vigente de Argentina (sin horario de verano desde
2009): no se suma `tzdata` como dependencia por una regla de offset fijo.
"""
from __future__ import annotations

import datetime
import zoneinfo

ARGENTINA_TZ_NAME = "America/Argentina/Mendoza"

_ARGENTINA_FIXED_OFFSET = datetime.timezone(datetime.timedelta(hours=-3), "UTC-03")


def _utcnow() -> datetime.datetime:
    """Reloj del proceso, en UTC. Punto único para fijarlo en los tests."""
    return datetime.datetime.now(datetime.timezone.utc)


def argentina_tz() -> datetime.tzinfo:
    """La zona de Argentina; UTC−3 fijo si el entorno no tiene base de zonas."""
    try:
        return zoneinfo.ZoneInfo(ARGENTINA_TZ_NAME)
    except zoneinfo.ZoneInfoNotFoundError:
        return _ARGENTINA_FIXED_OFFSET


def today_in_argentina(now: datetime.datetime | None = None) -> datetime.date:
    """La fecha del día en Argentina para el instante `now` (default: ahora).

    Un `now` sin zona horaria se rechaza: es ambiguo y adivinar su zona es
    exactamente el error que esta función existe para evitar.
    """
    instant = now if now is not None else _utcnow()
    if instant.tzinfo is None or instant.utcoffset() is None:
        raise ValueError(
            "today_in_argentina: el instante no tiene zona horaria (datetime naive); "
            "pasá un datetime con tzinfo."
        )
    return instant.astimezone(argentina_tz()).date()
