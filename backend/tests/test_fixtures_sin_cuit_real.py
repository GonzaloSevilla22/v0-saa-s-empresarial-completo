"""
Privacidad de los fixtures (hallazgo del red team de factura-fiscal-imprimible,
2026-09-26): el CUIT real de una cliente en producción (un CUIT de persona
física contiene su DNI) se había copiado a los tests nuevos, asociado a un
nombre inventado. Los fixtures usan un CUIT SINTÉTICO con dígito verificador
válido (20-12345678-6, el mismo del e2e).

La guardia no contiene el CUIT: compara el SHA-256 de cada secuencia de 11
dígitos (con o sin guiones) de los archivos de test contra el hash del real.
Los documentos del change (propose/CHANGES) lo nombran a propósito y quedan
fuera: sólo se barren los directorios de tests.
"""
from __future__ import annotations

import hashlib
import pathlib
import re

REAL_CUIT_SHA256 = "c125e0b201ebade54f377fcbbcebe3f36042b303ed1437a145f6cfe0b35ae3fd"

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
TEST_DIRS = (
    "backend/tests",
    "frontend/__tests__",
    "frontend/components",
    "frontend/e2e",
    "supabase/tests",
)
SUFFIXES = {".py", ".ts", ".tsx", ".mjs", ".js", ".sql"}
CUIT_RE = re.compile(r"(?<!\d)(\d{2})-?(\d{8})-?(\d)(?!\d)")


def _test_files():
    for rel in TEST_DIRS:
        base = REPO_ROOT / rel
        if not base.exists():
            continue
        for path in base.rglob("*"):
            if path.suffix not in SUFFIXES or "node_modules" in path.parts:
                continue
            if rel == "frontend/components" and "__tests__" not in path.parts:
                continue
            yield path


def test_ningun_fixture_de_test_usa_el_cuit_real_de_una_cliente():
    offenders = []
    for path in _test_files():
        text = path.read_text(encoding="utf-8", errors="ignore")
        for match in CUIT_RE.finditer(text):
            digits = "".join(match.groups())
            if hashlib.sha256(digits.encode()).hexdigest() == REAL_CUIT_SHA256:
                line = text.count("\n", 0, match.start()) + 1
                offenders.append(f"{path.relative_to(REPO_ROOT)}:{line}")
    assert not offenders, "CUIT real en fixtures de test (usar 20-12345678-6): " + ", ".join(offenders)


def test_la_guardia_reconoce_el_cuit_con_y_sin_guiones():
    """Sin esto la guardia podría no matchear nunca y pasar por vacía."""
    real = "".join(str(d) for d in (2, 7, 2, 1, 3, 7, 9, 0, 3, 3, 7))
    formatted = f"{real[:2]}-{real[2:10]}-{real[10]}"
    for text in (real, formatted, f'"cuit": "{formatted}",'):
        match = CUIT_RE.search(text)
        assert match is not None
        assert hashlib.sha256("".join(match.groups()).encode()).hexdigest() == REAL_CUIT_SHA256
    synthetic = CUIT_RE.search("20-12345678-6")
    assert hashlib.sha256("".join(synthetic.groups()).encode()).hexdigest() != REAL_CUIT_SHA256
