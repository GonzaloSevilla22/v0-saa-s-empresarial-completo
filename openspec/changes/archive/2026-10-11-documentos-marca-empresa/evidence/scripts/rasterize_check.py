"""documentos-marca-empresa, tanda B, checkpoint 13.4, paso 2: rasteriza los PDF de `invoice_variants.py` a PNG (para
revisarlos a ojo) y verifica el QR de ARCA SOBRE LA IMAGEN, no sobre el vector:

  - el QR se ubica por los rectangulos negros del PDF (PyMuPDF `get_drawings`) y se rasteriza a 8 px por modulo;
  - cada modulo se muestrea en su centro: los oscuros tienen que ser NEGRO PURO (0,0,0) y los claros, blancos (luminancia
    >= 220: el blanco del papel o la marca de agua gris clara "COMPROBANTE DE PRUEBA" de la homologacion, que ya existia y
    cruza el QR segun donde caiga), nunca un color de la paleta;
  - la zona de silencio (4 modulos alrededor, salvo el borde de anti-alias de 1 modulo) tiene que ser clara con el mismo
    criterio: nada coloreado se superpone al QR;
  - la grilla muestreada de CADA variante es identica a la de la factura SIN MARCA del mismo comprobante (la marca
    no mueve ni un modulo) y a la que reconstruyen los rectangulos vectoriales.

Corre con un Python que tenga PyMuPDF + numpy + Pillow (el venv del backend no los trae): `python rasterize_check.py
<directorio con manifest.json> <directorio de PNG>`. No decodifica el QR (no hay decodificador instalado); que la
grilla es la del texto exacto de ARCA lo prueban los tests del backend (`test_invoice_pdf.py::TestQR` y
`test_el_qr_dibujado_es_modulo_a_modulo_el_de_segno`).
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import fitz  # PyMuPDF
import numpy as np

DPI_PAGE = 110          # para revisar a ojo
PX_PER_MODULE = 8       # para muestrear el QR
QUIET_MODULES = 4
LIGHT_MIN_LUMINANCE = 220


def qr_geometry(page: fitz.Page):
    """(x0, y0, lado_modulo, n) del QR en puntos, desde los rectangulos negros del PDF."""
    rects = []
    for drawing in page.get_drawings():
        fill = drawing.get("fill")
        if drawing.get("type") != "f" or fill is None or tuple(fill) != (0.0, 0.0, 0.0):
            continue
        for item in drawing["items"]:
            if item[0] == "re":
                rects.append(item[1])
    if not rects:
        return None
    # el modulo es el alto mas frecuente de los rectangulos negros
    heights = sorted(round(r.height, 3) for r in rects)
    module = max(set(heights), key=heights.count)
    qr = [r for r in rects if abs(r.height - module) < 0.01]
    x0 = min(r.x0 for r in qr)
    y0 = min(r.y0 for r in qr)
    x1 = max(r.x1 for r in qr)
    n = round((x1 - x0) / module)
    return x0, y0, module, n, qr


def sample_grid(page: fitz.Page, geometry):
    x0, y0, module, n, _ = geometry
    zoom = PX_PER_MODULE / module
    q = QUIET_MODULES * module
    clip = fitz.Rect(x0 - q, y0 - q, x0 + n * module + q, y0 + n * module + q)
    pix = page.get_pixmap(matrix=fitz.Matrix(zoom, zoom), clip=clip, colorspace=fitz.csRGB, alpha=False)
    img = np.frombuffer(pix.samples, dtype=np.uint8).reshape(pix.height, pix.width, 3)
    side = (n + 2 * QUIET_MODULES) * PX_PER_MODULE
    assert abs(img.shape[0] - side) <= 2 and abs(img.shape[1] - side) <= 2, (img.shape, side)
    grid = np.zeros((n, n), dtype=bool)
    impure = 0
    for r in range(n):
        for c in range(n):
            cy = int((QUIET_MODULES + r + 0.5) * PX_PER_MODULE)
            cx = int((QUIET_MODULES + c + 0.5) * PX_PER_MODULE)
            px = tuple(int(v) for v in img[cy, cx])
            if px == (0, 0, 0):
                grid[r, c] = True
            elif _luminance(px) < LIGHT_MIN_LUMINANCE:
                impure += 1                       # ni negro puro ni claro: un color o un gris dentro del QR
    quiet = np.ones(img.shape[:2], dtype=bool)
    lo = (QUIET_MODULES - 1) * PX_PER_MODULE      # el ultimo modulo de la zona de silencio absorbe el anti-alias
    quiet[lo:img.shape[0] - lo, lo:img.shape[1] - lo] = False
    ring = img[quiet].astype(float)
    luminance = 0.2126 * ring[:, 0] + 0.7152 * ring[:, 1] + 0.0722 * ring[:, 2]
    return grid, impure, bool((luminance >= LIGHT_MIN_LUMINANCE).all())


def _luminance(px) -> float:
    return 0.2126 * px[0] + 0.7152 * px[1] + 0.0722 * px[2]


def vector_grid(geometry):
    x0, y0, module, n, rects = geometry
    grid = np.zeros((n, n), dtype=bool)
    for rect in rects:
        row = round((rect.y0 - y0) / module)
        c0 = round((rect.x0 - x0) / module)
        for col in range(c0, c0 + round(rect.width / module)):
            grid[row, col] = True
    return grid


def main() -> None:
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    dst.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((src / "manifest.json").read_text(encoding="utf-8"))
    reference: dict[str, np.ndarray] = {}
    failures = 0
    rows = []
    for entry in sorted(manifest, key=lambda e: (e["document"], e["variant"] != "sin-marca", e["variant"])):
        pdf = fitz.open(src / entry["file"])
        stem = Path(entry["file"]).stem
        qr_page = None
        for number, page in enumerate(pdf, start=1):
            page.get_pixmap(dpi=DPI_PAGE).save(dst / f"{stem}__p{number}.png")
            if qr_page is None and qr_geometry(page) is not None:
                qr_page = page
        if qr_page is None:
            print("FALLA sin QR:", stem)
            failures += 1
            continue
        geometry = qr_geometry(qr_page)
        grid, impure, quiet_ok = sample_grid(qr_page, geometry)
        same_as_vector = bool((grid == vector_grid(geometry)).all())
        if entry["variant"] == "sin-marca":
            reference[entry["document"]] = grid
        same_as_plain = bool((grid == reference[entry["document"]]).all())
        ok = impure == 0 and quiet_ok and same_as_vector and same_as_plain
        failures += 0 if ok else 1
        rows.append({
            "pdf": entry["file"], "paginas": len(pdf), "modulos": geometry[3], "modulos_ni_negros_ni_claros": impure,
            "zona_de_silencio_clara": quiet_ok, "igual_al_vector": same_as_vector, "igual_a_sin_marca": same_as_plain,
            "ok": ok,
        })
        print(("OK    " if ok else "FALLA ") + json.dumps(rows[-1], ensure_ascii=False))
    (dst / "qr_check.json").write_text(json.dumps(rows, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"{len(rows) - failures}/{len(rows)} PDF con el QR integro")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
