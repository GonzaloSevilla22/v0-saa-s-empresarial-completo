"""
documentos-marca-empresa — grupo 4: validación y normalización del logo
(tasks 4.1 RED, 4.2 GREEN, 4.3 triangulación).

Criterio de aceptación: spec `document-branding`, requirement "Logo validado y
normalizado por el servidor" (design D2).

Todas las imágenes se GENERAN en el test con Pillow (nada binario versionado).

Run: python -m pytest backend/tests/test_document_logo.py -q -p no:cacheprovider
"""
from __future__ import annotations

import hashlib
import io
import logging
import random
import struct
import zlib

import pytest
from PIL import Image, ImageDraw, ImageFile

from backend.services.commercial_documents import logo as logo_module
from backend.services.commercial_documents.logo import (
    MAX_PIXELS,
    MAX_SIDE,
    MAX_STORED_BYTES,
    MAX_UPLOAD_BYTES,
    LogoImage,
    LogoInvalid,
    LogoTooHeavy,
    LogoTooLarge,
    LogoUnsupportedType,
    fit_box,
    load_logo_for_render,
    normalize_logo,
)

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


# ── generadores de imágenes de prueba ─────────────────────────────────────────

def _png_bytes(img: Image.Image, **kwargs) -> bytes:
    buf = io.BytesIO()
    img.save(buf, "PNG", **kwargs)
    return buf.getvalue()


def _jpeg_bytes(img: Image.Image, **kwargs) -> bytes:
    buf = io.BytesIO()
    img.save(buf, "JPEG", **kwargs)
    return buf.getvalue()


def _drawn_logo(size: tuple[int, int], mode: str = "RGB") -> Image.Image:
    """Un 'logo' con formas y degradado: comprimible y con bordes reales."""
    width, height = size
    base = Image.linear_gradient("L").resize(size)
    img = Image.merge("RGB", (base, base.transpose(Image.Transpose.FLIP_TOP_BOTTOM), Image.new("L", size, 90)))
    draw = ImageDraw.Draw(img)
    draw.ellipse((width * 0.1, height * 0.1, width * 0.5, height * 0.9), fill=(200, 30, 30))
    draw.rectangle((width * 0.55, height * 0.3, width * 0.9, height * 0.7), fill=(20, 60, 160))
    return img.convert(mode)


def _transparent_png(size: tuple[int, int]) -> bytes:
    width, height = size
    img = Image.new("RGBA", size, (0, 0, 0, 0))                       # fondo transparente
    ImageDraw.Draw(img).ellipse((width * 0.1, height * 0.1, width * 0.6, height * 0.9), fill=(200, 30, 30, 255))
    return _png_bytes(img)


def _png_declaring(width: int, height: int) -> bytes:
    """Un PNG con CRC válido cuyo encabezado DECLARA width × height pero cuyos datos son un
    pixel: lo que un atacante manda para tumbar el decodificador (300 KB que 'pesan' 1 GB)."""
    def chunk(kind: bytes, data: bytes) -> bytes:
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)       # 8 bits, RGB
    idat = zlib.compress(b"\x00\xff\x00\x00")
    return PNG_SIGNATURE + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")


@pytest.fixture
def load_spy(monkeypatch):
    """Cuenta las llamadas a ImageFile.load (decodificar los píxeles)."""
    calls: list[int] = []
    original = ImageFile.ImageFile.load

    def spy(self, *args, **kwargs):
        calls.append(1)
        return original(self, *args, **kwargs)

    monkeypatch.setattr(ImageFile.ImageFile, "load", spy)
    return calls


def _open(result: LogoImage) -> Image.Image:
    img = Image.open(io.BytesIO(result.data))
    img.load()
    return img


# ── subida válida: PNG con transparencia ─────────────────────────────────────

def test_png_with_transparency_becomes_a_1000px_png_with_alpha():
    result = normalize_logo(_transparent_png((2400, 600)))
    assert isinstance(result, LogoImage)
    assert result.mime == "image/png"
    assert (result.width, result.height) == (1000, 250)
    img = _open(result)
    assert img.format == "PNG" and img.mode == "RGBA"
    assert img.size == (1000, 250)
    assert img.getchannel("A").getextrema() == (0, 255)          # la transparencia sobrevive
    assert img.getpixel((0, 0))[3] == 0
    assert len(result.data) <= MAX_STORED_BYTES


def test_sha256_is_the_hash_of_the_stored_bytes():
    result = normalize_logo(_transparent_png((300, 100)))
    assert result.sha256 == hashlib.sha256(result.data).hexdigest()
    assert len(result.sha256) == 64


def test_the_same_input_always_gives_the_same_fingerprint():
    raw = _transparent_png((500, 200))
    assert normalize_logo(raw).sha256 == normalize_logo(raw).sha256


def test_a_small_image_is_not_enlarged():
    result = normalize_logo(_transparent_png((300, 100)))
    assert (result.width, result.height) == (300, 100)


# ── subida válida: JPEG grande con EXIF ──────────────────────────────────────

def test_large_jpeg_with_exif_becomes_a_small_jpeg_without_metadata():
    exif = Image.Exif()
    exif[0x0112] = 1                      # orientación normal
    exif[0x010F] = "ACME Camera Corp"     # Make
    exif[0x0132] = "2026:10:11 10:00:00"  # DateTime
    raw = _jpeg_bytes(_drawn_logo((4000, 3000)), quality=95, exif=exif, icc_profile=b"\x00" * 160)
    assert b"ACME Camera Corp" in raw and b"ICC_PROFILE" in raw     # control: el original SÍ trae metadatos

    result = normalize_logo(raw)
    assert result.mime == "image/jpeg"
    assert (result.width, result.height) == (1000, 750)
    assert len(result.data) <= MAX_STORED_BYTES
    assert b"ACME Camera Corp" not in result.data and b"Exif" not in result.data and b"ICC_PROFILE" not in result.data
    img = _open(result)
    assert img.format == "JPEG" and img.mode == "RGB"
    assert len(img.getexif()) == 0
    assert "icc_profile" not in img.info


def test_exif_orientation_is_applied_before_the_metadata_is_dropped():
    """Una foto 400×200 'acostada' (Orientation=6: girar 90° a la derecha) queda 200×400."""
    exif = Image.Exif()
    exif[0x0112] = 6
    raw = _jpeg_bytes(_drawn_logo((400, 200)), exif=exif)
    result = normalize_logo(raw)
    assert (result.width, result.height) == (200, 400)
    assert len(_open(result).getexif()) == 0


def test_png_text_chunks_and_icc_profile_are_dropped():
    from PIL.PngImagePlugin import PngInfo

    info = PngInfo()
    info.add_text("Author", "Juan Perez")
    info.add_text("Comment", "ubicación secreta")
    raw = _png_bytes(
        Image.new("RGBA", (200, 100), (10, 20, 30, 128)), pnginfo=info, dpi=(300, 300), icc_profile=b"\x00" * 160
    )
    assert b"Juan Perez" in raw and b"iCCP" in raw and b"pHYs" in raw      # control: el original SÍ los trae
    out = normalize_logo(raw).data
    assert b"Juan Perez" not in out and b"tEXt" not in out and b"iTXt" not in out and b"zTXt" not in out
    assert b"iCCP" not in out and b"eXIf" not in out and b"pHYs" not in out


# ── otros formatos de entrada ────────────────────────────────────────────────

def test_webp_is_stored_as_png_or_jpeg():
    buf = io.BytesIO()
    _drawn_logo((600, 300)).save(buf, "WEBP")
    result = normalize_logo(buf.getvalue())
    assert result.mime in ("image/png", "image/jpeg")
    assert _open(result).format in ("PNG", "JPEG")
    assert (result.width, result.height) == (600, 300)


def test_webp_with_transparency_keeps_it_as_png():
    buf = io.BytesIO()
    Image.new("RGBA", (200, 100), (255, 0, 0, 0)).save(buf, "WEBP", lossless=True)
    result = normalize_logo(buf.getvalue())
    assert result.mime == "image/png"
    assert _open(result).mode == "RGBA"


def test_palette_png_with_transparency_becomes_rgba():
    img = Image.new("P", (200, 100))
    img.putpalette([0, 0, 0, 255, 0, 0] + [0, 0, 0] * 254)
    img.info["transparency"] = 0
    result = normalize_logo(_png_bytes(img, transparency=0))
    assert result.mime == "image/png"
    assert _open(result).mode == "RGBA"


def test_cmyk_jpeg_is_converted_to_rgb():
    raw = _jpeg_bytes(Image.new("CMYK", (300, 200), (0, 255, 255, 0)))
    result = normalize_logo(raw)
    assert result.mime == "image/jpeg"
    assert _open(result).mode == "RGB"


def test_grayscale_png_without_alpha_becomes_jpeg():
    result = normalize_logo(_png_bytes(Image.new("L", (200, 100), 128)))
    assert result.mime == "image/jpeg"
    assert _open(result).mode == "RGB"


# ── rechazos: tipo ───────────────────────────────────────────────────────────

SVG = b'<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><script>alert(1)</script></svg>'


@pytest.mark.parametrize(
    "name,raw",
    [
        ("svg", SVG),
        ("svg con encabezado xml", b'<?xml version="1.0"?>' + SVG),
        ("gif", b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff!\xf9\x04\x01\x00\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02D\x01\x00;"),
        ("bmp", b"BM" + b"\x00" * 60),
        ("texto", b"esto no es una imagen"),
        ("pdf", b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n"),
        ("vacío", b""),
        ("html", b"<html><body>hola</body></html>"),
    ],
)
def test_other_formats_are_unsupported_whatever_the_name_says(name, raw):
    with pytest.raises(LogoUnsupportedType) as info:
        normalize_logo(raw)
    assert info.value.code == "branding_logo_unsupported_type"
    assert info.value.status_code == 415


def test_gif_saved_by_pillow_is_unsupported():
    buf = io.BytesIO()
    Image.new("P", (20, 20)).save(buf, "GIF")
    with pytest.raises(LogoUnsupportedType):
        normalize_logo(buf.getvalue())


def test_tiff_saved_by_pillow_is_unsupported():
    buf = io.BytesIO()
    Image.new("RGB", (20, 20)).save(buf, "TIFF")
    with pytest.raises(LogoUnsupportedType):
        normalize_logo(buf.getvalue())


# ── rechazos: tamaño y bombas de descompresión ───────────────────────────────

def test_upload_over_2_mib_is_too_large():
    with pytest.raises(LogoTooLarge) as info:
        normalize_logo(PNG_SIGNATURE + b"\x00" * MAX_UPLOAD_BYTES)
    assert info.value.code == "branding_logo_too_large"
    assert info.value.status_code == 413


def test_png_that_declares_20000_by_20000_is_invalid_without_decoding(load_spy):
    raw = _png_declaring(20000, 20000)
    assert len(raw) < 1000                      # 300 KB en el ataque real; acá basta con un puñado de bytes
    with pytest.raises(LogoInvalid) as info:
        normalize_logo(raw)
    assert info.value.code == "branding_logo_invalid"
    assert info.value.status_code == 422
    assert load_spy == []                       # NUNCA decodificó los píxeles


def test_png_between_the_limit_and_pillows_own_bomb_check_is_invalid_without_decoding(load_spy):
    """6000×5000 = 30 millones de píxeles: Pillow lo abre sin chistar (su alarma salta a los
    89 M), así que el tope de 25 M lo pone el servicio y ANTES de decodificar."""
    assert 6000 * 5000 > MAX_PIXELS
    with pytest.raises(LogoInvalid):
        normalize_logo(_png_declaring(6000, 5000))
    assert load_spy == []


def test_image_exactly_at_the_pixel_limit_is_not_rejected_by_the_pixel_check(load_spy):
    """El borde: 5000×5000 = 25 M píxeles exactos pasa el chequeo de tamaño (y recién ahí se
    decodifica; este PNG sintético tiene datos de 1 píxel, así que falla DESPUÉS por corrupto)."""
    assert 5000 * 5000 == MAX_PIXELS
    with pytest.raises(LogoInvalid):
        normalize_logo(_png_declaring(5000, 5000))
    assert load_spy != []                       # llegó a decodificar: el rechazo no fue por el tope


def test_corrupt_bytes_after_a_valid_header_are_invalid():
    raw = _png_bytes(_drawn_logo((400, 300)))
    with pytest.raises(LogoInvalid):
        normalize_logo(raw[: len(raw) // 2])


def test_truncated_jpeg_is_invalid():
    raw = _jpeg_bytes(_drawn_logo((400, 300)))
    with pytest.raises(LogoInvalid):
        normalize_logo(raw[: len(raw) // 2])


def test_png_signature_with_garbage_is_not_a_picture():
    with pytest.raises((LogoInvalid, LogoUnsupportedType)):
        normalize_logo(PNG_SIGNATURE + b"basura" * 50)


# ── rechazos: demasiado pesado aun reducido ──────────────────────────────────

def _noise_png(side: int, seed: int = 7) -> bytes:
    """Ruido RGBA: incomprimible y con transparencia, así que se guarda como PNG."""
    rnd = random.Random(seed)
    return _png_bytes(Image.frombytes("RGBA", (side, side), rnd.randbytes(side * side * 4)))


def test_noise_that_does_not_fit_300kb_at_1000_nor_at_600px_is_too_heavy():
    raw = _noise_png(700)                        # ~1,9 MB: entra en el tope de subida
    assert len(raw) < MAX_UPLOAD_BYTES
    with pytest.raises(LogoTooHeavy) as info:
        normalize_logo(raw)
    assert info.value.code == "branding_logo_too_heavy"
    assert info.value.status_code == 422


def test_an_image_too_heavy_at_1000px_is_retried_at_600px(monkeypatch):
    """Se calibra el tope entre el peso de la versión de 1000 px y la de 600 px de una imagen
    con ruido suave, y se comprueba que el servicio reintenta más chico en vez de rechazar."""
    rnd = random.Random(11)
    img = _drawn_logo((1000, 1000))
    px = img.load()
    for _ in range(40000):
        x, y = rnd.randrange(1000), rnd.randrange(1000)
        px[x, y] = (rnd.randrange(256), rnd.randrange(256), rnd.randrange(256))
    raw = _png_bytes(img)

    def encoded(side: int) -> int:
        small = img.copy()
        small.thumbnail((side, side), Image.Resampling.LANCZOS)
        return len(_jpeg_bytes(small, quality=85, optimize=True))

    size_1000, size_600 = encoded(1000), encoded(600)
    assert size_600 < size_1000
    monkeypatch.setattr(logo_module, "MAX_STORED_BYTES", (size_1000 + size_600) // 2)

    result = normalize_logo(raw)
    assert max(result.width, result.height) == 600
    assert len(result.data) <= logo_module.MAX_STORED_BYTES


# ── load_logo_for_render: el render vuelve a comprobar ───────────────────────

def test_load_for_render_returns_the_image_for_a_normal_logo():
    stored = normalize_logo(_transparent_png((800, 200)))
    loaded = load_logo_for_render(stored.data, stored.mime)
    assert isinstance(loaded, LogoImage)
    assert (loaded.width, loaded.height) == (stored.width, stored.height)
    assert loaded.sha256 == stored.sha256 and loaded.mime == "image/png"
    assert loaded.data == stored.data


def test_load_for_render_rejects_a_stored_type_that_differs_from_the_content(caplog):
    png = normalize_logo(_transparent_png((200, 100))).data
    with caplog.at_level(logging.WARNING, logger=logo_module.logger.name):
        assert load_logo_for_render(png, "image/jpeg") is None
    assert any("logo" in r.getMessage().lower() for r in caplog.records)


def test_load_for_render_rejects_an_unsupported_mime():
    png = normalize_logo(_transparent_png((200, 100))).data
    assert load_logo_for_render(png, "image/gif") is None
    assert load_logo_for_render(png, "image/svg+xml") is None


def test_load_for_render_rejects_a_side_over_1000px():
    assert load_logo_for_render(_transparent_png((1200, 300)), "image/png") is None


def test_load_for_render_rejects_bytes_that_do_not_decode(caplog):
    broken = _png_bytes(_drawn_logo((300, 200)))[:300]
    with caplog.at_level(logging.WARNING, logger=logo_module.logger.name):
        assert load_logo_for_render(broken, "image/png") is None
    assert caplog.records


def test_load_for_render_rejects_a_declared_bomb_without_decoding(load_spy):
    assert load_logo_for_render(_png_declaring(20000, 20000), "image/png") is None
    assert load_spy == []


def test_load_for_render_rejects_garbage_and_empty():
    assert load_logo_for_render(b"", "image/png") is None
    assert load_logo_for_render(b"nada", "image/png") is None
    assert load_logo_for_render(SVG, "image/png") is None


def test_load_for_render_accepts_a_jpeg():
    stored = normalize_logo(_jpeg_bytes(_drawn_logo((1500, 600))))
    loaded = load_logo_for_render(stored.data, stored.mime)
    assert loaded is not None and loaded.mime == "image/jpeg"
    assert max(loaded.width, loaded.height) <= MAX_SIDE


# ── fit_box: el logo se dibuja sin deformarse ────────────────────────────────

def test_fit_box_horizontal_logo_is_limited_by_the_box_height():
    # 400×100 px (4:1) en 50×18 mm: ancho 50 → alto 12,5 (cabe) -> limita el ancho
    assert fit_box(400, 100, 50, 18) == pytest.approx((50.0, 12.5))


def test_fit_box_vertical_logo_is_limited_by_the_box_height():
    w, h = fit_box(100, 400, 50, 18)
    assert h == pytest.approx(18.0) and w == pytest.approx(4.5)


def test_fit_box_square_logo_uses_the_height():
    assert fit_box(200, 200, 50, 18) == pytest.approx((18.0, 18.0))


def test_fit_box_image_smaller_than_the_box_keeps_its_ratio_and_fits():
    w, h = fit_box(20, 10, 50, 18)
    assert (w, h) == pytest.approx((36.0, 18.0))
    assert w / h == pytest.approx(2.0)


@pytest.mark.parametrize("size", [(400, 100), (100, 400), (200, 200), (20, 10), (1000, 999), (3, 977)])
def test_fit_box_never_deforms_and_never_overflows_the_box(size):
    w, h = fit_box(size[0], size[1], 50, 18)
    assert w / h == pytest.approx(size[0] / size[1])
    assert w <= 50 + 1e-9 and h <= 18 + 1e-9


@pytest.mark.parametrize("bad", [(0, 10, 50, 18), (10, 0, 50, 18), (10, 10, 0, 18), (10, 10, 50, 0), (-1, 10, 50, 18)])
def test_fit_box_rejects_non_positive_dimensions(bad):
    with pytest.raises(ValueError):
        fit_box(*bad)


# ── memoria: el tope de píxeles no alcanza si cada copia cuesta lo mismo que la imagen ───────────
#
# Revisión adversarial (grupo 12): un PNG RGBA de 107 KiB que declara 25 millones de píxeles
# pasa todos los topes (2 MiB, 25 Mpx) y obligaba a Pillow a sostener ~4 copias de 100 MB
# (decodificada, transpuesta, convertida y la del reintento): +406 MiB de pico medido, que en la
# instancia free de Render (512 MB) la tumba. El pico tiene que quedar cerca de UNA copia.

import subprocess
import sys
import threading
import time
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parents[2]

_PEAK_PROBE = r'''
import sys

def peak_mib():
    if sys.platform == "win32":
        import ctypes
        import ctypes.wintypes as wt

        class PMC(ctypes.Structure):
            _fields_ = [("cb", wt.DWORD), ("PageFaultCount", wt.DWORD), ("PeakWorkingSetSize", ctypes.c_size_t),
                        ("WorkingSetSize", ctypes.c_size_t), ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                        ("QuotaPagedPoolUsage", ctypes.c_size_t), ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                        ("QuotaNonPagedPoolUsage", ctypes.c_size_t), ("PagefileUsage", ctypes.c_size_t),
                        ("PeakPagefileUsage", ctypes.c_size_t)]

        k32 = ctypes.WinDLL("kernel32")
        k32.GetCurrentProcess.restype = wt.HANDLE
        psapi = ctypes.WinDLL("psapi")
        psapi.GetProcessMemoryInfo.argtypes = [wt.HANDLE, ctypes.POINTER(PMC), wt.DWORD]
        pmc = PMC()
        pmc.cb = ctypes.sizeof(PMC)
        assert psapi.GetProcessMemoryInfo(k32.GetCurrentProcess(), ctypes.byref(pmc), pmc.cb)
        return pmc.PeakWorkingSetSize / 1048576
    import resource
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return peak / 1048576 if sys.platform == "darwin" else peak / 1024

from backend.services.commercial_documents.logo import normalize_logo

raw = sys.stdin.buffer.read()
before = peak_mib()
normalize_logo(raw)
print(peak_mib() - before)
'''


def _peak_growth_mib(raw: bytes) -> float:
    done = subprocess.run(
        [sys.executable, "-c", _PEAK_PROBE], input=raw, cwd=_REPO_ROOT,
        capture_output=True, timeout=120, check=True,
    )
    return float(done.stdout.decode().strip().splitlines()[-1])


@pytest.mark.parametrize("mode", ["RGBA", "RGB"])
def test_a_25_megapixel_image_does_not_multiply_its_memory_footprint(mode):
    """5000×5000 comprime a ~100 KiB y está EN el tope: normalizarla puede pedir, a lo sumo, una
    copia decodificada (RGBA = 100 MB) más el trabajo del decodificador y del redimensionado (~+216 MiB
    medidos con RGBA; antes del arreglo +406), nunca cuatro copias."""
    side = int(MAX_PIXELS ** 0.5)
    colour = (30, 90, 200, 255) if mode == "RGBA" else (30, 90, 200)
    raw = _png_bytes(Image.new(mode, (side, side), colour))
    assert len(raw) < MAX_UPLOAD_BYTES

    growth = _peak_growth_mib(raw)

    assert growth < 300, f"normalizar una imagen de {MAX_PIXELS} px sumó {growth:.0f} MiB de pico (tope razonable: 300)"


def test_normalizations_never_run_concurrently(monkeypatch):
    """Dos subidas a la vez duplicarían el pico de memoria: la normalización se serializa por proceso."""
    state = {"active": 0, "peak": 0}
    guard = threading.Lock()
    original = logo_module._normalize

    def spy(raw: bytes):
        with guard:
            state["active"] += 1
            state["peak"] = max(state["peak"], state["active"])
        time.sleep(0.05)
        try:
            return original(raw)
        finally:
            with guard:
                state["active"] -= 1

    monkeypatch.setattr(logo_module, "_normalize", spy)
    raw = _png_bytes(_drawn_logo((300, 200)))
    results: list[LogoImage] = []
    threads = [threading.Thread(target=lambda: results.append(normalize_logo(raw))) for _ in range(5)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    assert len(results) == 5
    assert state["peak"] == 1
