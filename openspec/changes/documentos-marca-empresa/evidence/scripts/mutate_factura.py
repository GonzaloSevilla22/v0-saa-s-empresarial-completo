"""Mutaciones del render de la Factura C: cada una DEBE hacer fallar al menos un test.
Uso (desde la raiz del worktree): python openspec/changes/documentos-marca-empresa/evidence/scripts/mutate_factura.py  -> una linea por mutacion."""
import os
import shutil
import subprocess
import sys

ROOT = os.getcwd()
TARGET = "backend/services/fiscal/invoice_pdf.py"
SERVICE = "backend/services/fiscal/invoice_print_service.py"
TESTS = ["backend/tests/test_invoice_pdf.py", "backend/tests/test_factura_fiscal_endpoint.py"]

MUTATIONS = [
    ("m1 el domicilio cambia de alto de renglón (sin marca el diseño se mueve)", TARGET,
     "lines.append(line(_latin1(view.issuer_address)))", "lines.append(line(_latin1(view.issuer_address), height=4.6))"),
    ("m2 el título ignora la paleta", TARGET,
     "pdf.set_text_color(*pdf.palette.heading)", "pdf.set_text_color(*_INK)"),
    ("m3 el cuerpo de la tabla hereda el color del texto de la banda", TARGET,
     "    pdf.ln(7)\n    pdf.set_text_color(*_INK)\n", "    pdf.ln(7)\n"),
    ("m4 el QR toma el acento", TARGET,
     "    pdf.set_fill_color(0, 0, 0)\n    for r, row in enumerate(rows):",
     "    pdf.set_fill_color(*pdf.palette.heading)\n    for r, row in enumerate(rows):"),
    ("m5 el recuadro no crece (alto fijo de 42 mm)", TARGET,
     "box_height = max(_BOX_MIN_H, left.height + 2 * _BOX_PAD, _right_height(view) + 2 * _BOX_PAD)",
     "box_height = _BOX_MIN_H"),
    ("m6 el contacto cae al teléfono del dueño", TARGET,
     "    if contact.phone:\n        lines.append(line(f\"Tel: {contact.phone}\"))",
     "    phone = contact.phone or (branding.issuer.phone if branding is not None else None)\n    if phone:\n        lines.append(line(f\"Tel: {phone}\"))"),
    ("m7 la banda ignora la paleta", TARGET,
     "pdf.set_fill_color(*palette.table_head_fill)", "pdf.set_fill_color(*_HEAD_FILL)"),
    ("m8 el recuadro de la letra toma el acento", TARGET,
     "    pdf.set_fill_color(255, 255, 255)\n    pdf.rect(mid - 8, box_top, 16, 15, style=\"DF\")",
     "    pdf.set_fill_color(*pdf.palette.heading)\n    pdf.rect(mid - 8, box_top, 16, 15, style=\"DF\")"),
    ("m9 el logo se dibuja sólo en la primera página", TARGET,
     "    draw_issuer_column(\n        pdf, _LEFT_X, box_top + _BOX_PAD, _LEFT_W, _issuer_block(view, pdf.branding), pdf.palette, _LOGO_BOX\n    )",
     "    draw_issuer_column(\n        pdf, _LEFT_X, box_top + _BOX_PAD, _LEFT_W, _issuer_block(view, pdf.branding if pdf.page_no() == 1 else None), pdf.palette, _LOGO_BOX\n    )"),
    ("m10 el servicio pide la marca antes de validar el comprobante", SERVICE,
     "    invoice = await doc_repo.get_invoice_lines(str(doc_id), account_id)",
     "    await _resolve_branding(branding_repo, account_id)\n    invoice = await doc_repo.get_invoice_lines(str(doc_id), account_id)"),
    ("m11 un error de la marca tumba la factura", SERVICE,
     "    except Exception:\n        logger.warning(", "    except ZeroDivisionError:\n        logger.warning("),
    ("m12 el servicio olvida la marca", SERVICE,
     "    branding = await _resolve_branding(branding_repo, account_id)\n    return render_invoice_pdf(view, branding), view.filename",
     "    return render_invoice_pdf(view), view.filename"),
    ("m13 la marca imprime la razón social de la marca", TARGET,
     "        name, name_size, name_height = _latin1(view.issuer_legal_name), 13.0, 6.0",
     "        name, name_size, name_height = _latin1((branding.issuer.legal_name if branding else None) or view.issuer_legal_name), 13.0, 6.0"),
    ("m14 el texto de la banda siempre blanco", TARGET,
     "pdf.set_text_color(*palette.table_head_text)", "pdf.set_text_color(255, 255, 255)"),
]


def run_tests() -> tuple[bool, str]:
    env = dict(os.environ, AUTH_ALLOW_HS256_FALLBACK="true")
    proc = subprocess.run(
        [os.path.join(ROOT, "backend", ".venv", "Scripts", "python.exe"), "-m", "pytest", *TESTS, "-q", "-x",
         "-p", "no:cacheprovider", "--tb=no", "-m", "not integration"],
        cwd=ROOT, env=env, capture_output=True, text=True,
    )
    out = (proc.stdout + proc.stderr).strip().splitlines()
    return proc.returncode == 0, (out[-1] if out else "")


survivors = []
for name, path, old, new in MUTATIONS:
    full = os.path.join(ROOT, path)
    original = open(full, encoding="utf-8", newline="").read()
    if original.count(old) != 1:
        print(f"SKIP  {name}: patrón no encontrado ({original.count(old)})")
        continue
    backup = full + ".mutbak"
    shutil.copyfile(full, backup)
    try:
        open(full, "w", encoding="utf-8", newline="").write(original.replace(old, new))
        passed, last = run_tests()
    finally:
        shutil.move(backup, full)
    verdict = "SOBREVIVE" if passed else "matada"
    print(f"{verdict:10} {name} | {last}")
    if passed:
        survivors.append(name)
print("sobrevivientes:", survivors or "ninguno")
