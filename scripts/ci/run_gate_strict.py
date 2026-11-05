#!/usr/bin/env python3
"""Corre un gate SQL de dinero con `psql -v ON_ERROR_STOP=1` y falla si DEGRADÓ en silencio.

Motivación (v31-money-integration-tests, H-34 / D6): casi todos los gates de `supabase/tests/` siguen el patrón
«degrade-don't-fail»: `IF v_account IS NULL THEN RAISE NOTICE 'GATE … degradando sin abortar.'; RETURN; END IF;`.
Si falta una precondición (la cuenta ancla no se aprovisionó, no hay caja ni forma de pago sembrada) el bloque
entero NO asierta nada y el paso termina en verde. Para los 33 gates de DINERO eso no es aceptable en CI.

Este wrapper NO edita ningún `.sql`:

1. ejecuta `psql -v ON_ERROR_STOP=1 <dsn> -f <gate>`, reenvía la salida tal cual al log y conserva el código de
   salida de psql (un `RAISE EXCEPTION` sigue fallando como siempre);
2. detecta las degradaciones SÓLO en las líneas `psql:<ese gate>:<n>: NOTICE:  <msg>`. Los NOTICE de las
   migraciones que un gate incluya con `\\i` y el ruido de los triggers del producto
   (`send_email_log_webhook … skipping`, `… does not exist, skipping`) no llevan ese prefijo de autor;
3. un mensaje es degradación si empieza con `GATE`, `SKIP` o `DEGRADE` y contiene alguna marca de degradación
   (ver `is_degradation`), salvo que sea un `PASSED` / `ninguno degradado` / `degrade-don't-fail`;
4. cada degradación debe figurar en la allow-list (`gate_degradation_allowlist.txt`, formato
   `<archivo.sql>|<subcadena del mensaje>|<motivo>`); si queda alguna sin permiso lista TODAS (archivo:línea:mensaje)
   y sale con 1. Sólo se admite como motivo una causa de ENTORNO, nunca «falta un dato sembrado».

Convención para los gates de dinero nuevos: toda rama de degradación emite un mensaje que EMPIEZA con `GATE`
y contiene `DEGRADED` o `degradado`; la prueba `backend/tests/test_gate_strict_detector.py` recorre los 33
gates y falla si aparece un `RAISE NOTICE` de degradación que el detector no reconocería.

Sólo librería estándar. Uso:

    python3 scripts/ci/run_gate_strict.py supabase/tests/test_x.sql [--dsn DSN] [--psql CMD] [--allowlist PATH]

`--dsn` por defecto es `$DATABASE_URL` o el stack local de CI. Sin `psql` en el PATH (p. ej. Windows): copiar
`supabase/` a un directorio del contenedor de la base y usar
`--psql "docker exec -i -w /tmp/w2/ <contenedor> psql -U postgres -d postgres" --dsn ""` (el directorio de trabajo
importa: algunos gates hacen `\\i supabase/migrations/…` con ruta relativa a la raíz del repo, así que el wrapper
no cambia el cwd de psql).
"""
from __future__ import annotations

import argparse
import os
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

DEFAULT_DSN = "postgresql://postgres:postgres@127.0.0.1:54322/postgres"
DEFAULT_ALLOWLIST = Path(__file__).with_name("gate_degradation_allowlist.txt")

# `psql:supabase/tests/x.sql:46: NOTICE:  GATE …` — el prefijo `psql:<archivo>:<línea>:` lo escribe psql sólo
# para las sentencias que vienen de un archivo (-f / \i); lo que emite un trigger lleva el mismo prefijo del
# archivo que lo disparó, por eso además se exige el mensaje de autor (ver `is_degradation`).
_NOTICE = re.compile(r"^psql:(?P<file>.+?):(?P<line>\d+): NOTICE:\s+(?P<msg>.*)$")

_AUTHOR_PREFIXES = ("GATE", "SKIP", "DEGRADE")
_DEGRADATION_MARKS = ("DEGRAD", "degradando", "SKIP", "se omite", "omitid", "sin abortar")
_NOT_DEGRADATION = ("PASSED", "ninguno degradado", "degrade-don't-fail")


@dataclass(frozen=True)
class Degradation:
    file: str
    line: int
    message: str


@dataclass(frozen=True)
class AllowEntry:
    file: str
    substring: str
    reason: str


def is_degradation(message: str) -> bool:
    """¿Este NOTICE es una rama de degradación de un gate? (la misma regla con la que se midieron las 202)."""
    msg = message.strip()
    if not msg.startswith(_AUTHOR_PREFIXES):
        return False
    if any(token in msg for token in _NOT_DEGRADATION):
        return False
    if "degradado" in msg.replace("degradado a", ""):
        return True
    return any(mark in msg for mark in _DEGRADATION_MARKS)


def parse_notice(line: str) -> tuple[str, int, str] | None:
    match = _NOTICE.match(line.rstrip("\r\n"))
    if not match:
        return None
    return match["file"], int(match["line"]), match["msg"].strip()


def _basename(path: str) -> str:
    return path.replace("\\", "/").rsplit("/", 1)[-1]


def find_degradations(lines: list[str], gate_path: str) -> list[Degradation]:
    """Degradaciones escritas por el propio gate (no por migraciones incluidas ni por triggers)."""
    gate = _basename(gate_path)
    found: list[Degradation] = []
    for raw in lines:
        parsed = parse_notice(raw)
        if parsed is None:
            continue
        file, line_no, message = parsed
        if _basename(file) == gate and is_degradation(message):
            found.append(Degradation(file, line_no, message))
    return found


def load_allowlist(path: Path) -> list[AllowEntry]:
    entries: list[AllowEntry] = []
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        text = raw.strip()
        if not text or text.startswith("#"):
            continue
        parts = [p.strip() for p in text.split("|", 2)]
        if len(parts) != 3 or not all(parts):
            raise ValueError(
                f"{path}:{number}: entrada inválida, se esperaba '<archivo.sql>|<subcadena>|<motivo de entorno>': {raw!r}"
            )
        entries.append(AllowEntry(*parts))
    return entries


def match_allowlist(degradation: Degradation, entries: list[AllowEntry]) -> AllowEntry | None:
    gate = _basename(degradation.file)
    for entry in entries:
        if entry.file == gate and entry.substring in degradation.message:
            return entry
    return None


def run_gate(gate: str, dsn: str, psql_cmd: list[str]) -> tuple[int, list[str]]:
    command = [*psql_cmd, "-v", "ON_ERROR_STOP=1"]
    if dsn:
        command.append(dsn)
    command += ["-f", gate]
    proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert proc.stdout is not None
    lines: list[str] = []
    for raw in proc.stdout:
        line = raw.decode("utf-8", errors="replace")
        lines.append(line)
        sys.stdout.write(line)
        sys.stdout.flush()
    return proc.wait(), lines


def main(argv: list[str] | None = None) -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("gate", help="ruta del gate, p. ej. supabase/tests/test_x.sql")
    parser.add_argument("--dsn", default=os.environ.get("DATABASE_URL", DEFAULT_DSN))
    parser.add_argument("--psql", default="psql", help="comando de psql (se parte como una shell)")
    parser.add_argument("--allowlist", type=Path, default=DEFAULT_ALLOWLIST)
    args = parser.parse_args(argv)

    try:
        entries = load_allowlist(args.allowlist)
    except (OSError, ValueError) as exc:
        print(f"run_gate_strict: allow-list ilegible: {exc}", file=sys.stderr)
        return 2

    code, lines = run_gate(args.gate, args.dsn, shlex.split(args.psql))
    degradations = find_degradations(lines, args.gate)
    blocked: list[Degradation] = []
    for degradation in degradations:
        entry = match_allowlist(degradation, entries)
        if entry is None:
            blocked.append(degradation)
        else:
            print(
                f"run_gate_strict: degradación PERMITIDA {degradation.file}:{degradation.line}: "
                f"{degradation.message} [motivo: {entry.reason}]"
            )

    if code != 0:
        print(f"run_gate_strict: psql terminó con código {code}", file=sys.stderr)
    if blocked and code == 0:
        code = 1
    if blocked:
        print(
            f"run_gate_strict: {len(blocked)} degradación(es) NO permitida(s) en {args.gate} — el gate no "
            "aseveró lo que dice verificar (una precondición no se cumplió):",
            file=sys.stderr,
        )
        for degradation in blocked:
            print(f"  {degradation.file}:{degradation.line}: {degradation.message}", file=sys.stderr)
    return code


if __name__ == "__main__":
    sys.exit(main())
