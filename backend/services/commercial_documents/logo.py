"""
Logo de la cuenta para sus papeles (documentos-marca-empresa D2, capability
`document-branding`): validación y normalización en el servidor, y la
comprobación que repite quien dibuja un papel.

La imagen se guarda NORMALIZADA en `account_branding.logo_image` (no en un
bucket de Storage: ver el design D2 — la subida tiene que pasar por el backend
de todos modos y una escritura a Storage exigiría `service_role`). Por eso este
módulo es la frontera de confianza: el navegador no lo es.

`normalize_logo(raw)` (puro, sin I/O):

  - tope de la subida: 2 MiB (el router además corta el stream sin leerlo
    entero; acá se repite como defensa en profundidad -> 413);
  - el formato se reconoce por el CONTENIDO (PNG, JPEG o WebP; nunca el nombre
    ni el `Content-Type`), restringiendo los decodificadores que Pillow puede
    probar: SVG, GIF, BMP, TIFF, PDF y texto -> 415;
  - las dimensiones se leen del ENCABEZADO —`Image.open` es perezoso— y se
    rechaza (422) lo que supere 25 millones de píxeles ANTES de decodificar: un
    PNG de 300 KB puede declarar 20000×20000 (una bomba de descompresión que
    tumba la instancia free de Render, 512 MB). Pillow además lanza su propia
    `DecompressionBombError` por encima de los 178 M; se traduce igual;
  - se respeta la orientación EXIF (`exif_transpose`) y se descartan TODOS los
    metadatos (EXIF/GPS, texto PNG, perfil ICC, dpi) reconstruyendo la imagen
    sin su `info`;
  - PNG con transparencia (modo RGBA/LA o paleta con `transparency`) -> RGBA;
    sin transparencia -> RGB (CMYK, gris, 16 bits se convierten);
  - lado mayor <= 1000 px (nunca se agranda); PNG optimizado con transparencia,
    JPEG calidad 85 sin ella (fpdf2 incrusta el JPEG sin recodificar);
  - si el resultado supera 300 KB se reintenta a 600 px; si todavía supera -> 422
    `branding_logo_too_heavy`.

`load_logo_for_render(data, mime)`: el render vuelve a abrir la imagen guardada
—perezoso—, exige formato = tipo guardado y <= 1000 × 1000; ante CUALQUIER duda
devuelve `None` y loguea un warning, así que una fila escrita a mano por
PostgREST con bytes raros no rompe ningún papel: sale sin logo. NUNCA se le pasa
una URL a fpdf2 (acepta remotos): siempre bytes.

Pillow no figura en `requirements.txt` por sí mismo: lo trae `fpdf2` (su
dependencia declarada), igual que el resto del render de PDFs.
"""
from __future__ import annotations

import hashlib
import io
import logging
from dataclasses import dataclass

from PIL import Image, ImageOps

logger = logging.getLogger(__name__)

MAX_UPLOAD_BYTES = 2 * 1024 * 1024        # lo que se acepta de un navegador
MAX_PIXELS = 25_000_000                   # ancho × alto declarados en el encabezado
MAX_SIDE = 1000                           # lado mayor de la imagen guardada
FALLBACK_SIDE = 600                       # segundo intento si no entra en MAX_STORED_BYTES
MAX_STORED_BYTES = 300 * 1024             # = el CHECK account_branding_logo_size_check (307200)

_JPEG_QUALITY = 85
# Decodificadores que se le permite probar a Pillow. Un JPEG de varias imágenes
# (MPO, fotos de algunos celulares) entra por la fábrica de JPEG y queda con
# `format == "MPO"`: por eso "MPO" está en _MIME_FORMAT pero no acá.
_OPEN_FORMATS = ["PNG", "JPEG", "WEBP"]
_MIME_FORMAT = {"image/png": {"PNG"}, "image/jpeg": {"JPEG", "MPO"}}


class LogoError(Exception):
    """Un rechazo de la subida o del render, con el código estable de la API."""

    code = "branding_logo_invalid"
    status_code = 422
    message = "El logo no se pudo procesar."

    def __init__(self, message: str | None = None) -> None:
        super().__init__(message or self.message)
        self.detail = message or self.message


class LogoTooLarge(LogoError):
    code = "branding_logo_too_large"
    status_code = 413
    message = "El logo pesa más de 2 MB."


class LogoUnsupportedType(LogoError):
    code = "branding_logo_unsupported_type"
    status_code = 415
    message = "El logo tiene que ser una imagen PNG, JPEG o WebP."


class LogoInvalid(LogoError):
    code = "branding_logo_invalid"
    status_code = 422
    message = "La imagen del logo está dañada o es demasiado grande."


class LogoTooHeavy(LogoError):
    code = "branding_logo_too_heavy"
    status_code = 422
    message = "El logo pesa demasiado aun reducido. Probá con una imagen más simple o más chica."


@dataclass(frozen=True)
class LogoImage:
    """Un logo ya normalizado (o ya comprobado para dibujar)."""

    data: bytes
    mime: str
    width: int
    height: int
    sha256: str


def fit_box(width: float, height: float, max_width: float, max_height: float) -> tuple[float, float]:
    """Tamaño (en la unidad de la caja) con el que entra una imagen de
    `width × height` píxeles en `max_width × max_height` SIN deformarse: se escala
    por el lado que limita. Una imagen más chica que la caja también se ajusta a
    ella (la unidad de píxel del logo es arbitraria en el papel)."""
    if width <= 0 or height <= 0 or max_width <= 0 or max_height <= 0:
        raise ValueError("fit_box: todas las dimensiones deben ser positivas")
    scale = min(max_width / width, max_height / height)
    return width * scale, height * scale


def _has_alpha(img: Image.Image) -> bool:
    return img.mode in ("RGBA", "LA", "PA") or (img.mode == "P" and "transparency" in img.info)


def _encode(img: Image.Image, alpha: bool) -> tuple[bytes, str]:
    buf = io.BytesIO()
    if alpha:
        img.save(buf, "PNG", optimize=True)
        return buf.getvalue(), "image/png"
    img.save(buf, "JPEG", quality=_JPEG_QUALITY, optimize=True)
    return buf.getvalue(), "image/jpeg"


def _open_checked(raw: bytes) -> Image.Image:
    """Abre PERO NO DECODIFICA: valida formato por contenido y píxeles declarados."""
    try:
        img = Image.open(io.BytesIO(raw), formats=_OPEN_FORMATS)
    except Image.UnidentifiedImageError as exc:
        raise LogoUnsupportedType() from exc
    except (Image.DecompressionBombError, Image.DecompressionBombWarning) as exc:
        raise LogoInvalid("La imagen del logo es demasiado grande.") from exc
    except Exception as exc:  # encabezado ilegible / corrupto
        raise LogoInvalid() from exc
    width, height = img.size
    if width < 1 or height < 1 or width * height > MAX_PIXELS:
        raise LogoInvalid("La imagen del logo es demasiado grande.")
    return img


def normalize_logo(raw: bytes) -> LogoImage:
    """Valida y normaliza la imagen subida. Ver el docstring del módulo."""
    if len(raw) > MAX_UPLOAD_BYTES:
        raise LogoTooLarge()
    img = _open_checked(raw)
    try:
        if img.format in ("JPEG", "MPO"):
            # Decodificación a escala reducida (DCT): una foto de 12 Mpx no
            # necesita ocupar 36 MB para terminar en 1000 px.
            img.draft("RGB", (MAX_SIDE, MAX_SIDE))
        img.load()                                    # <- recién acá se decodifican los píxeles
        img = ImageOps.exif_transpose(img)
        alpha = _has_alpha(img)
        base = img.convert("RGBA" if alpha else "RGB")        # `convert` devuelve una copia nueva
        base.info = {}                                        # sin EXIF/ICC/texto PNG/dpi: Pillow los escribe desde `info`
    except LogoError:
        raise
    except Exception as exc:  # truncada, corrupta, modo exótico
        raise LogoInvalid() from exc

    for side in (MAX_SIDE, FALLBACK_SIDE):
        candidate = base.copy()
        candidate.thumbnail((side, side), Image.Resampling.LANCZOS)   # nunca agranda
        try:
            data, mime = _encode(candidate, alpha)
        except Exception as exc:
            raise LogoInvalid() from exc
        if len(data) <= MAX_STORED_BYTES:
            return LogoImage(
                data=data,
                mime=mime,
                width=candidate.width,
                height=candidate.height,
                sha256=hashlib.sha256(data).hexdigest(),
            )
    raise LogoTooHeavy()


def load_logo_for_render(data: bytes | None, mime: str | None) -> LogoImage | None:
    """El logo guardado, re-comprobado antes de dibujarlo; `None` ante cualquier
    duda (el papel sale sin logo, nunca falla)."""
    if not data or mime not in _MIME_FORMAT:
        if data:
            logger.warning("document-branding: logo con tipo guardado no soportado (%r); se dibuja sin logo", mime)
        return None
    try:
        img = Image.open(io.BytesIO(data), formats=_OPEN_FORMATS)
        if img.format not in _MIME_FORMAT[mime]:
            logger.warning(
                "document-branding: el logo guardado como %s es en realidad %s; se dibuja sin logo", mime, img.format
            )
            return None
        width, height = img.size
        if width < 1 or height < 1 or width > MAX_SIDE or height > MAX_SIDE:
            logger.warning("document-branding: logo de %sx%s px excede %s px; se dibuja sin logo", width, height, MAX_SIDE)
            return None
        img.load()                                    # comprueba que de verdad decodifica
    except Exception:
        logger.warning("document-branding: logo guardado ilegible; se dibuja sin logo", exc_info=True)
        return None
    return LogoImage(
        data=data, mime=mime, width=width, height=height, sha256=hashlib.sha256(data).hexdigest()
    )
