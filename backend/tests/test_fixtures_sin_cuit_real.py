"""
Privacidad de los fixtures (hallazgo del red team de factura-fiscal-imprimible,
2026-09-26): el CUIT real de una cliente en producción (un CUIT de persona
física contiene su DNI) se había copiado a los tests nuevos, asociado a un
nombre inventado. Los fixtures usan CUITs SINTÉTICOS con dígito verificador
válido (20-12345678-6, el mismo del e2e, y otros ya usados en la suite).

La guardia NO contiene ningún CUIT real ni su hash: hashear un identificador
de 11 dígitos con SHA-256 no lo protege (11 dígitos son 10^11 combinaciones,
muchas menos si además tienen que respetar el dígito verificador — se
fuerza por diccionario en segundos), así que la única guardia segura es no
contenerlo bajo ninguna forma, ni siquiera reconstruido a partir de sus
dígitos por separado.

En su lugar, la guardia encuentra toda secuencia de 11 dígitos (con o sin
guiones) que pase el algoritmo del dígito verificador de CUIT y exige que
esté en una allow-list de CUITs sintéticos ya usados en los tests. Un CUIT
real filtrado a un fixture nuevo, sea el de esta cliente o el de cualquier
otra, dispara la guardia igual porque no puede estar en la allow-list.

Los documentos del change (propose/CHANGES) lo nombran a propósito y quedan
fuera: sólo se barren los directorios de tests.
"""
from __future__ import annotations

import pathlib
import re

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

# CUITs sintéticos ya usados en la suite (relevados con `git grep` del propio
# CUIT_RE sobre TEST_DIRS + filtro por dígito verificador válido). Todos son
# placeholders con dígito verificador válido, ninguno corresponde a una
# persona real. Agregar acá cualquier CUIT sintético nuevo que se necesite.
ALLOWED_SYNTHETIC_CUITS = frozenset(
    {
        "20000000001",
        "20055361682",
        "20111111112",
        "20123456786",  # 20-12345678-6 — el de frontend/e2e/fixtures/fiscal-e2e.ts
        "20123456980",
        "20422662457",
        "30000000007",
        "30712345671",
    }
)


def cuit_verifier_digit(base10: str) -> int:
    """Dígito verificador de CUIT (algoritmo módulo 11) sobre los primeros 10
    dígitos. Devuelve 10 cuando el resultado no es representable como un
    único dígito (esa base no forma un CUIT válido sin un ajuste de tipo)."""
    weights = (5, 4, 3, 2, 7, 6, 5, 4, 3, 2)
    total = sum(int(d) * w for d, w in zip(base10, weights))
    verifier = 11 - (total % 11)
    return 0 if verifier == 11 else verifier


def _is_valid_cuit(digits11: str) -> bool:
    verifier = cuit_verifier_digit(digits11[:10])
    if verifier == 10:
        return False
    return verifier == int(digits11[10])


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


def _find_cuit_offenders(text: str) -> list[tuple[int, str]]:
    """Toda secuencia de 11 dígitos con dígito verificador de CUIT válido que
    no esté en la allow-list sintética. Devuelve pares (línea, dígitos)."""
    offenders = []
    for match in CUIT_RE.finditer(text):
        digits = "".join(match.groups())
        if not _is_valid_cuit(digits) or digits in ALLOWED_SYNTHETIC_CUITS:
            continue
        line = text.count("\n", 0, match.start()) + 1
        offenders.append((line, digits))
    return offenders


def test_ningun_fixture_de_test_usa_un_cuit_fuera_de_la_allow_list_sintetica():
    offenders = []
    for path in _test_files():
        text = path.read_text(encoding="utf-8", errors="ignore")
        for line, digits in _find_cuit_offenders(text):
            offenders.append(f"{path.relative_to(REPO_ROOT)}:{line} ({digits})")
    assert not offenders, (
        "CUIT con dígito verificador válido fuera de la allow-list sintética "
        "(si es un placeholder legítimo nuevo, sumarlo a ALLOWED_SYNTHETIC_CUITS; "
        "si es un CUIT real filtrado, reemplazarlo por 20-12345678-6): "
        + ", ".join(offenders)
    )


def test_la_guardia_detecta_un_cuit_no_permitido_con_digito_verificador_valido(tmp_path):
    """Control positivo: sin esto la guardia podría no matchear nunca (regex
    rota, allow-list demasiado amplia, etc.) y pasar por vacía. Genera en
    runtime un CUIT sintético NUEVO —con dígito verificador válido, pero que
    no está en la allow-list— y confirma que se detecta."""
    base10 = "3071234569"
    verifier = cuit_verifier_digit(base10)
    assert 0 <= verifier <= 9
    candidate_digits = base10 + str(verifier)
    assert candidate_digits not in ALLOWED_SYNTHETIC_CUITS
    candidate_formatted = f"{base10[:2]}-{base10[2:]}-{verifier}"

    offending_file = f'export const CUIT_DE_PRUEBA = "{candidate_formatted}"\n'
    offenders = _find_cuit_offenders(offending_file)
    assert offenders == [(1, candidate_digits)]

    # También debe detectarlo sin guiones.
    offending_file_no_dashes = f'export const CUIT_DE_PRUEBA = "{candidate_digits}"\n'
    offenders_no_dashes = _find_cuit_offenders(offending_file_no_dashes)
    assert offenders_no_dashes == [(1, candidate_digits)]


def test_la_guardia_deja_pasar_el_cuit_sintetico_permitido():
    ok_file = 'export const CUIT_DE_PRUEBA = "20-12345678-6"\n'
    assert _find_cuit_offenders(ok_file) == []


def test_la_guardia_ignora_secuencias_de_digitos_con_verificador_invalido():
    """Una secuencia de 11 dígitos que no es un CUIT (no pasa el dígito
    verificador) no debe generar ruido ni falsos positivos."""
    not_a_cuit = "12345678901"
    assert not _is_valid_cuit(not_a_cuit)
    text = f'const ALGUN_ID = "{not_a_cuit}"\n'
    assert _find_cuit_offenders(text) == []
