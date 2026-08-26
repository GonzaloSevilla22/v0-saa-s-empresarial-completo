#!/usr/bin/env python3
"""Gate CI: valida que `AGENTS.md` sea una copia exacta de `CLAUDE.md`.

Motivación (auditoría de stack del 2026-08-26): el repo mantiene dos archivos
de instrucciones para agentes con el MISMO contenido — `CLAUDE.md`, que Claude
Code inyecta solo en su contexto, y `AGENTS.md`, que leen los demás agentes
(Codex y compañía). Nunca hubo nada que los mantuviera sincronizados: eran
copias manuales.

El resultado fue silencioso y grave. `AGENTS.md` quedó congelado alrededor del
2026-06-10: seguía anunciando `C-21` como "próximo change" y la Fase 7 como no
empezada, dos meses y ~15 changes después de que eso dejara de ser cierto. Un
agente que leyera ese archivo proponía trabajo ya hecho. Nadie lo notó porque
ningún gate comparaba los dos archivos, y el que edita `CLAUDE.md` no tiene
motivo para acordarse del otro.

Contrato que impone este gate:

    CLAUDE.md es la fuente de verdad. AGENTS.md se genera de él.

Editá `CLAUDE.md` y corré `python scripts/ci/check_docs_sync.py --fix`.

Los finales de línea se normalizan antes de comparar: el repo se clona en
Windows (CRLF) y corre en CI sobre Linux (LF), y un gate que falle por eso es
un gate que alguien va a terminar desactivando.
"""
from __future__ import annotations

import argparse
import difflib
import io
import sys
from pathlib import Path

SOURCE = "CLAUDE.md"
DERIVED = "AGENTS.md"


def _read(path: Path) -> str:
    """Lee normalizando finales de línea a LF (ver docstring del módulo)."""
    return io.open(path, encoding="utf-8", newline="").read().replace("\r\n", "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--fix",
        action="store_true",
        help=f"regenera {DERIVED} desde {SOURCE} en vez de solo verificar",
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[2],
        help="raíz del repo (por defecto, la que deduce del propio script)",
    )
    args = parser.parse_args()

    # El repo se desarrolla en Windows, donde la consola por defecto es cp1252 y
    # no sabe imprimir los acentos ni las flechas del propio diff. Sin esto, el
    # gate crashea con UnicodeEncodeError justo cuando encuentra algo — es decir,
    # exactamente cuando hace falta que se lea.
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):  # stdout redirigido a algo sin reconfigure
        pass

    source, derived = args.root / SOURCE, args.root / DERIVED

    for path in (source, derived):
        if not path.is_file():
            print(f"ERROR: no existe {path}", file=sys.stderr)
            return 2

    want = _read(source)
    got = _read(derived)

    if want == got:
        print(f"OK: {DERIVED} está sincronizado con {SOURCE}")
        return 0

    if args.fix:
        # Se escribe con los finales de línea nativos del archivo fuente para no
        # generar un diff de 200 líneas por un cambio de CRLF a LF.
        raw = io.open(source, encoding="utf-8", newline="").read()
        io.open(derived, "w", encoding="utf-8", newline="").write(raw)
        print(f"OK: {DERIVED} regenerado desde {SOURCE}")
        return 0

    diff = list(
        difflib.unified_diff(
            want.splitlines(), got.splitlines(),
            fromfile=SOURCE, tofile=DERIVED, lineterm="", n=1,
        )
    )
    print(f"ERROR: {DERIVED} divergió de {SOURCE} ({len(diff)} líneas de diff).")
    print(f"Arreglalo con:  python scripts/ci/check_docs_sync.py --fix\n")
    # Un diff completo acá es ruido: alcanza con el principio para ubicarse.
    for line in diff[:40]:
        print(line)
    if len(diff) > 40:
        print(f"... ({len(diff) - 40} líneas más)")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
