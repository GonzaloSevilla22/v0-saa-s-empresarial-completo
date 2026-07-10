"""
v3-api-standards §3 — Idempotency-Key por header en mutaciones no-idempotentes.

D4 (design.md): la clave de idempotencia viaja preferentemente por el header
HTTP `Idempotency-Key`. Durante una ventana de compatibilidad, el body sigue
aceptando `idempotency_key` como fallback deprecado (OQ2: se difiere la
limpieza del fallback a un change posterior). El header tiene precedencia
si ambos están presentes. Si ninguno está, 422 `idempotency_key_required`.

Uso en un router:

    @router.post("/sales-orders/{id}/confirm")
    async def confirm_order(
        sales_order_id: str,
        payload: ConfirmIn,
        idempotency_key: str = Depends(require_idempotency_key_from(payload_attr="idempotency_key")),
        ...
    ):
        ...

En la práctica, como FastAPI resuelve las dependencies antes de tener acceso
directo al modelo ya parseado de otro parámetro, el patrón usado en los
routers de este change es invocar `require_idempotency_key` directamente
dentro del handler, pasándole el `Request` (para leer el header) y el valor
`payload.idempotency_key` (fallback ya parseado por Pydantic).
"""
from __future__ import annotations

from fastapi import Request
from fastapi.exceptions import RequestValidationError

IDEMPOTENCY_HEADER = "Idempotency-Key"


async def require_idempotency_key(
    request: Request,
    idempotency_key_body: str | None,
) -> str:
    """Resuelve la clave de idempotencia: header > body > 422.

    - Si el header `Idempotency-Key` está presente (no vacío), se usa esa.
    - Si no, cae al `idempotency_key_body` (valor ya parseado del body,
      fallback deprecado — OQ2).
    - Si ninguno está presente (o el que está es cadena vacía), levanta
      `RequestValidationError` con `code=idempotency_key_required` (422
      problem+json vía el handler de main.py).
    """
    header_value = request.headers.get(IDEMPOTENCY_HEADER)
    if header_value:
        return header_value

    if idempotency_key_body:
        return idempotency_key_body

    raise RequestValidationError(
        [
            {
                "type": "idempotency_key_required",
                "loc": ("header", IDEMPOTENCY_HEADER),
                "msg": (
                    "Falta la clave de idempotencia: enviar el header "
                    f"'{IDEMPOTENCY_HEADER}' (o, en su defecto, "
                    "'idempotency_key' en el body)."
                ),
                "input": None,
            }
        ]
    )
