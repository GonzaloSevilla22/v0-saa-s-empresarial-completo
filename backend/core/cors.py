"""auth-hardening-jwt-cookies D10 — la política de orígenes permitidos, en un
solo lugar.

**Por qué existe este módulo y no dos listas.** El hallazgo F5 de la auditoría
tiene dos mitades: el middleware de CORS reflejaba cualquier origen, y
`backend/core/errors.py` **reproducía la reflexión a mano** para los cuerpos
RFC 7807 (que salen del middleware de errores del servidor, por fuera de
`CORSMiddleware`, y por eso inyectan los encabezados por su cuenta). Arreglar
sólo una deja viva la otra. El requisito normativo lo dice explícito: *"los
cuerpos de error que se emiten fuera del middleware de CORS SHALL aplicar
exactamente el mismo criterio de origen permitido que el middleware"*. La
única forma de que no diverjan es que haya un solo criterio, acá.

**Por qué expresión regular y no lista.** Los despliegues de vista previa de
Vercel tienen host variable (uno por commit): enumerarlos es imposible.

**Desvío declarado respecto del design (D10), corregido por el hallazgo M1 de
la revisión adversarial del apply.** El design proponía
`^https://v0-saa-s-empresarial-completo-eie(-[a-z0-9-]+)?\\.vercel\\.app$`: el
slug del equipo (`eie`) va al FINAL del host, después del hash o de la rama, no
pegado al nombre del proyecto, así que esa forma no existe. Pero la primera
corrección de este archivo **invirtió la medición** —dejaba afuera el alias
vivo y adentro un host que no sirve la app—; las formas medidas anónimamente el
2026-09-16 son:

- `https://v0-saa-s-empresarial-completo-eie.vercel.app` → **200**, es el alias
  vivo del proyecto (`<title>Potenciá tu Negocio con ALIADATA</title>`);
- `https://v0-saa-s-empresarial-completo-git-main-eie.vercel.app` → **200**;
- `https://v0-saa-s-empresarial-completo-<hash>-eie.vercel.app` → el deploy
  puntual de cada commit;
- `https://v0-saa-s-empresarial-completo.vercel.app` → **404
  `DEPLOYMENT_NOT_FOUND`**: NO sirve esta app y, al no estar asignada, la podría
  reclamar un proyecto homónimo de otro equipo. Queda **fuera** de la
  allow-list, con su caso en la tabla de `lookalike` del test.

Por eso el sufijo `-eie` es obligatorio y la parte variable —hash o
`git-<rama>`— es la opcional: es el ancla que impide que entre un proyecto
ajeno con un nombre parecido. La consecuencia concreta de haberlo tenido al
revés: una sesión servida por el alias vivo perdía **todas** las llamadas al
backend (que es otro origen, `emprende-smart-backend.onrender.com`) en cuanto
este change retira la reflexión del comodín.
"""
from __future__ import annotations

import re

from backend.core.config import Settings, settings

# Dominio de producción, con y sin `www`. Verificado anónimamente el
# 2026-09-16: `https://www.aliadata.com.ar/` responde 200 y el ápice redirige
# ahí con 307.
_PRODUCTION_ORIGIN = r"https://(?:www\.)?aliadata\.com\.ar"
# Despliegues de vista previa del proyecto en Vercel — ver el desvío declarado
# en el docstring.
_VERCEL_PREVIEW_ORIGIN = (
    r"https://v0-saa-s-empresarial-completo(?:-[a-z0-9-]+)?-eie\.vercel\.app"
)

# Anclada en los dos extremos a propósito: sin `^`/`$` una allow-list de
# dominios acepta cualquier host que la CONTENGA
# (`https://www.aliadata.com.ar.evil.example`), que es la forma clásica de
# escribir una allow-list que no lo es. Hay test para cada variante.
CORS_ORIGIN_REGEX = rf"^(?:{_PRODUCTION_ORIGIN}|{_VERCEL_PREVIEW_ORIGIN})$"

_CORS_ORIGIN_RE = re.compile(CORS_ORIGIN_REGEX)

LOCAL_DEV_ORIGIN = "http://localhost:3000"


def allowed_origins(config: Settings | None = None) -> list[str]:
    """Orígenes admitidos de forma literal (los que no cubre la regex).

    `BACKEND_ALLOWED_ORIGIN` sigue siendo una salida útil —permite sumar un
    dominio desde el entorno sin tocar código— pero el comodín NUNCA entra a
    la lista: en producción el arranque lo rechaza (validator de `Settings`), y
    fuera de producción se ignora, porque `allow_origins=["*"]` combinado con
    credenciales es exactamente lo que producía la reflexión de F5.
    """
    config = settings if config is None else config
    origins: list[str] = []

    configured = (config.backend_allowed_origin or "").strip()
    if configured and configured != "*":
        origins.append(configured)

    # El origen de desarrollo no puede quedar admitido en producción.
    if config.app_env != "production":
        origins.append(LOCAL_DEV_ORIGIN)

    return sorted(set(origins))


def is_origin_allowed(origin: str, config: Settings | None = None) -> bool:
    """El criterio único. `CORSMiddleware` lo aplica por su cuenta a partir de
    `allowed_origins()` + `CORS_ORIGIN_REGEX`; todo lo que responda por fuera
    del middleware (los cuerpos de problema) pregunta acá."""
    if not origin:
        return False
    if origin in allowed_origins(config):
        return True
    return _CORS_ORIGIN_RE.fullmatch(origin) is not None
