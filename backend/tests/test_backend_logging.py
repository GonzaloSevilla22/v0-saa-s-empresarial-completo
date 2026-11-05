"""
mp-cuota-acreditacion-resiliente 5.1 (D8) — el backend no configuraba
logging de aplicación: sin `basicConfig` ni `dictConfig`, los loggers
`backend.*` heredaban el root en WARNING y toda línea `logger.info` se
descartaba en Render. Por eso no se supo qué marcador detectó el pago
187789722328, y el requirement "Notification origin is observable" de
`payment-webhook` no se cumplía en prod.

Fija: tras importar `backend.main`, el logger `backend` emite INFO por un
handler propio a stdout, sin tocar el root ni los loggers de uvicorn, y la
configuración es idempotente (re-importar / re-configurar no duplica
handlers → no duplica líneas).
"""
from __future__ import annotations

import logging
import sys


def _own_handlers(logger: logging.Logger) -> list[logging.Handler]:
    return [h for h in logger.handlers if getattr(h, "_backend_app_handler", False)]


def test_backend_logger_emits_info_through_its_own_stdout_handler():
    import backend.main  # noqa: F401 — importarlo configura el logging

    backend_logger = logging.getLogger("backend")
    assert backend_logger.getEffectiveLevel() == logging.INFO
    assert logging.getLogger("backend.services.payments").isEnabledFor(logging.INFO)
    handlers = _own_handlers(backend_logger)
    assert len(handlers) == 1
    assert isinstance(handlers[0], logging.StreamHandler)
    assert handlers[0].stream is sys.stdout
    # propaga: pytest (caplog) y cualquier handler del root siguen viendo las líneas
    assert backend_logger.propagate is True


def test_configuration_is_idempotent_and_leaves_root_and_uvicorn_alone():
    from backend.main import configure_backend_logging

    root_level = logging.getLogger().level
    uvicorn_handlers = list(logging.getLogger("uvicorn").handlers)

    configure_backend_logging()
    configure_backend_logging()

    assert len(_own_handlers(logging.getLogger("backend"))) == 1
    assert logging.getLogger().level == root_level
    assert logging.getLogger("uvicorn").handlers == uvicorn_handlers


def test_handler_format_names_level_and_logger(capsys):
    """La línea en Render dice nivel y logger (para filtrar por módulo)."""
    import backend.main  # noqa: F401

    handler = _own_handlers(logging.getLogger("backend"))[0]
    record = logging.LogRecord("backend.services.payments", logging.INFO, __file__, 1, "hola %s", ("mundo",), None)
    assert handler.format(record) == "INFO backend.services.payments: hola mundo"
