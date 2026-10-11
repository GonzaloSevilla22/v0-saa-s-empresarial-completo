"""Checkpoint 13.4, paso 3: sobre los PDF bajados del stack local verifica, por TEXTO, lo que la factura no puede
hacer nunca (el telefono del PERFIL del dueño y la leyenda al pie de la marca no se imprimen) y lo que si tiene que
tener (el contacto de la marca cuando la cuenta lo cargo; todo el contenido fiscal siempre).
Uso (con el venv del backend, que trae pypdf): python pdf_text_check.py <directorio con manifest.json>"""
import io
import json
import sys
from pathlib import Path

from pypdf import PdfReader

OWNER_PHONE = "2615550199"
FOOTER = "Alias para transferencias"
FISCAL = ("ORIGINAL", "FACTURA", "20-12345678-6", "PEREZ MARIA LAURA", "IVA RESPONSABLE MONOTRIBUTO", "0712345",
          "01/03/2019", "Consumidor Final", "Importe Total", "Comprobante Autorizado", "CAE", "Vto. de CAE")
WITH_CONTACT = {"neutro-logo-horizontal", "azul-logo-cuadrado", "bordo-logo-horizontal"}

src = Path(sys.argv[1])
manifest = json.loads((src / "manifest.json").read_text(encoding="utf-8"))
failures = []
for entry in manifest:
    reader = PdfReader(io.BytesIO((src / entry["file"]).read_bytes()))
    text = "\n".join(page.extract_text() or "" for page in reader.pages)
    variant = entry["variant"]
    checks = {
        "no imprime el telefono del perfil del dueño": OWNER_PHONE not in text,
        "no imprime la leyenda al pie de la marca": FOOTER not in text,
        "todo lo fiscal esta": all(word in text for word in FISCAL),
        "contacto completo si la marca lo cargo": (not (variant in WITH_CONTACT)) or all(
            word in text for word in ("Tel: 2617175072", "ventas@sumar.com.ar", "sumar.com.ar")),
        "sin marca no hay contacto": variant != "sin-marca" or not any(
            word in text for word in ("Tel:", "ventas@sumar.com.ar")),
        "solo email: sin telefono ni web": variant != "grafito-solo-email" or (
            "ventas@sumar.com.ar" in text and "Tel:" not in text),
        "imagenes embebidas": (
            sum(len(page.images) for page in reader.pages) == (0 if variant in ("sin-marca", "grafito-solo-email") else 1)
            or sum(len(page.images) for page in reader.pages) == len(reader.pages)),
    }
    bad = [name for name, ok in checks.items() if not ok]
    print(("OK    " if not bad else "FALLA ") + entry["file"] + ("" if not bad else "  -> " + "; ".join(bad)))
    if bad:
        failures.append(entry["file"])
print(f"{len(manifest) - len(failures)}/{len(manifest)} PDF correctos")
sys.exit(1 if failures else 0)
