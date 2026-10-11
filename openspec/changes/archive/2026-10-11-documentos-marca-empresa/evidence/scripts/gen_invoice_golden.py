"""Congela el dibujo de la Factura C SIN marca en backend/tests/fixtures/invoice_pdf_sin_marca_layout.json.
Se corrio contra el render PREVIO a la tanda B (HEAD 8f0f98c2) y no se vuelve a correr: el fixture es la referencia
de "sin marca la factura queda como hoy". Uso: python gen_invoice_golden.py <salida.json> (con AUTH_ALLOW_HS256_FALLBACK=true)."""
import sys, io, json
sys.path.insert(0, '.')
from decimal import Decimal
from backend.tests.test_invoice_pdf import _view, sumar_doc, SNAPSHOT, LINE
from backend.services.fiscal.invoice_pdf import render_invoice_pdf
import pypdf

def layout(pdf_bytes):
    reader = pypdf.PdfReader(io.BytesIO(pdf_bytes))
    pages = []
    for page in reader.pages:
        items = []
        def visit(text, cm, tm, font, size):
            if text.strip():
                items.append([text, round(tm[4], 2), round(tm[5], 2), round(size, 2)])
        page.extract_text(visitor_text=visit)
        pages.append(items)
    return pages

cases = {
    "sumar_1_linea": render_invoice_pdf(_view()),
    "sumar_homologacion_duplicado": render_invoice_pdf(
        _view(sumar_doc(emisor_snapshot={**SNAPSHOT, "ambiente": "homologacion"}), copy="duplicado")),
    "sumar_sin_fantasia_55_lineas": render_invoice_pdf(_view(
        sumar_doc(emisor_snapshot={**SNAPSHOT, "nombre_fantasia": None}, total=Decimal("35750.00")),
        lines=[{**LINE, "name_snapshot": f"Producto {i:02d}", "price": Decimal("650.00"), "subtotal": Decimal("650.00")} for i in range(55)])),
}
out = {name: layout(pdf) for name, pdf in cases.items()}
lines = ["{"]
names = list(out)
for ni, name in enumerate(names):
    lines.append("  " + json.dumps(name) + ": [")
    for pi, page in enumerate(out[name]):
        lines.append("    [")
        for ii, item in enumerate(page):
            lines.append("      " + json.dumps(item, ensure_ascii=False) + ("," if ii < len(page) - 1 else ""))
        lines.append("    ]" + ("," if pi < len(out[name]) - 1 else ""))
    lines.append("  ]" + ("," if ni < len(names) - 1 else ""))
lines.append("}")
with open(sys.argv[1], "w", encoding="utf-8", newline="\n") as fh:
    fh.write("\n".join(lines) + "\n")
print({k: (len(v), sum(len(p) for p in v)) for k, v in out.items()})
