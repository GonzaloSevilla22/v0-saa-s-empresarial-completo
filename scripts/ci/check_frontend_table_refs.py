#!/usr/bin/env python3
"""Gate CI: valida que toda referencia a tabla/vista/función SQL hecha desde
supabase-js en el FRONTEND (`.from("tabla")` / `.rpc("fn")`) exista realmente
en el schema (cadena de migraciones de Supabase aplicada por `supabase start`
en CI).

Motivación (mismo postmortem `organizations` que motivó
`scripts/ci/check_backend_table_refs.py`, aplicado ahora al otro lado del
stack): el frontend le habla a Supabase vía PostgREST usando strings
literales (`supabase.from("tabla_fantasma")`), y ese error solo se descubre
en RUNTIME — ni TypeScript ni los tests unitarios (que mockean el cliente
supabase-js) lo detectan. Este script escanea `frontend/**/*.{ts,tsx}`
(excluyendo tests) en busca de esos strings literales y los valida contra
`pg_class` (tablas/vistas/vistas materializadas/particiones/foreign tables) y
`pg_proc` (funciones, para `.rpc(...)`) de una base Postgres real, pasada por
`--dsn`. Corre como paso adicional del mismo job de CI, inmediatamente
después del gate del backend.

Es un scanner de TEXTO, no un parser TypeScript completo: Python no trae en
stdlib un tokenizer para TS/TSX (a diferencia del gate del backend, que usa
`tokenize`/`ast` reales de Python), así que acá los comentarios se
"blanquean" con un regex que reconoce comentarios de línea (`//`), de bloque
(`/* */`) y los tres tipos de string literal de JS (`'`, `"`, `` ` ``) para
no confundir un comentario con código real, ni cortar un string a la mitad.
Ver `strip_comments` para el detalle. Deliberadamente NO se intentó un
approach "solo cortar `//` si no está dentro de un string" con un parser más
fino — el approach elegido (regex de alternancia con escaneo izquierda a
derecha, un string que abre antes de un `//` siempre gana esa carrera) ya
cubre el caso real encontrado en el repo (`frontend/lib/pagination-utils.ts`
tiene un comentario `// ... .from(table).select() ...` con una URL no, pero
si la tuviera con `//`, seguiría andando bien porque el comentario entero se
blanquea). Limitación conocida y aceptada: un literal de regex de JS
(`/patrón/flags`) que contenga `//` podría cortarse mal — no se detectó
ningún caso real en este repo al momento de escribir el gate.

Discriminadores para no generar falsos positivos (ver `_EXCLUDED_FROM_RECEIVERS`
y `extract_refs`):
- `Array.from(...)` / `Object.from(...)` (JS builtins, nada que ver con
  supabase-js) se excluyen por el identificador inmediatamente anterior al
  `.from(` — SIN esto, `Array.from({length: 6})` no matchea igual porque su
  argumento no es un string literal, pero `Array.from("abc")` (string
  literal, receptor `Array`) sí matchearía sin este filtro.
- `supabase.storage.from("bucket")` es un BUCKET de Storage, no una tabla —
  se excluye por el mismo mecanismo (receptor `storage`). En este repo, las
  4 llamadas reales a `storage.from(...)` usan una constante `BUCKET`
  (argumento dinámico), así que ya quedarían afuera solo por el chequeo de
  "argumento es un string literal" — el filtro por receptor queda como
  defensa en profundidad para cuando ese ya no sea el caso.
- Llamadas con argumento dinámico (`supabase.from(table)`, variable, o un
  template literal con interpolación `` `tabla_${x}` ``) no se pueden
  resolver de forma estática — se ignoran en silencio (no crashean, no
  generan falsos positivos), igual que el f-string dinámico del gate del
  backend. Caso real conocido: `updateItem` en
  `frontend/app/(dashboard)/admin/cursos/page.tsx`.

Resolución de nombres cross-schema: a diferencia del gate del backend (que
solo agrega el alias "bare" — sin prefijo de schema — para objetos del
schema `public`, porque el código Python SIEMPRE calificaba explícitamente
`auth.users` cuando quería salir de `public`), acá el alias bare se agrega
para TODOS los schemas. Motivo: supabase-js separa la selección de schema
(`.schema('community')`) del nombre de tabla/función en el string literal —
ese literal NUNCA lleva el prefijo de schema, así que `'course_modules'`
debe resolver aunque solo exista en `pg_class` como `community.course_modules`
(ver `fetch_existing_objects`).

Limitaciones conocidas (documentadas, no bugs):
- Nombres de tabla/función interpolados dinámicamente no se pueden resolver
  de forma estática (ver arriba).
- Valida contra el schema QUE ARMA LA CADENA DE MIGRACIONES EN CI, no contra
  producción directamente. Un gap entre CI y prod es una señal real pero
  separada (ver cross-check manual contra prod en la PR de este gate).
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from collections import namedtuple
from pathlib import Path

# ── Allowlist ────────────────────────────────────────────────────────────
# Vacía a propósito. Cada entrada debe llevar un comentario justificando
# POR QUÉ el gate no puede resolver esa referencia contra el schema real
# (p.ej. un gap confirmado entre el schema de CI y prod, con link al
# hallazgo).
ALLOWLIST: frozenset[str] = frozenset()

Ref = namedtuple("Ref", ["name", "lineno", "kind"])  # kind: "table" | "function"

# Identificador inmediatamente anterior a `.from(` que indica que NO es una
# llamada a supabase-js: `Array.from`/`Object.from` son builtins de JS, y
# `storage.from` apunta a un bucket de Supabase Storage, no a una tabla. Solo
# aplica al método `from` (no hay equivalente ambiguo para `.rpc(`).
_EXCLUDED_FROM_RECEIVERS = {"Array", "Object", "storage"}

# ── comentarios / strings ──────────────────────────────────────────────────

_TOKEN_RE = re.compile(
    r"""
    (?P<line_comment>//[^\n]*)
  | (?P<block_comment>/\*.*?\*/)
  | (?P<dq_string>"(?:[^"\\\n]|\\.)*")
  | (?P<sq_string>'(?:[^'\\\n]|\\.)*')
  | (?P<template_string>`(?:[^`\\]|\\.)*`)
    """,
    re.VERBOSE | re.DOTALL,
)


def _blank_comment(match: re.Match[str]) -> str:
    """Callback de `_TOKEN_RE.sub`: los comentarios se reemplazan por
    espacios (preservando saltos de línea, para no correr los números de
    línea del resto del archivo); los string literals se devuelven
    intactos — ahí es donde vive el `.from("tabla")` real que nos interesa.
    """
    if match.lastgroup in ("line_comment", "block_comment"):
        text = match.group(0)
        return "".join(ch if ch == "\n" else " " for ch in text)
    return match.group(0)


def strip_comments(source: str) -> str:
    """Devuelve `source` con los comentarios `//` y `/* */` blanqueados,
    dejando intacto cualquier string literal (incluido uno que contenga
    `//` o `/*`, p.ej. una URL) — el escaneo izquierda a derecha de
    `_TOKEN_RE` hace que, si un string abre antes de un posible comentario,
    el string gane esa carrera y se consuma como una sola unidad.
    """
    return _TOKEN_RE.sub(_blank_comment, source)


# ── extracción de llamadas .from( / .rpc( ──────────────────────────────────

# Llamada con argumento STRING LITERAL resoluble estáticamente. El receptor
# (identificador pegado antes del `.`) es opcional: para cadenas como
# `supabase.schema('community').from('x')`, el caracter justo antes de
# `.from(` es un `)` (cierre de `.schema(...)`), no un identificador — el
# grupo simplemente no matchea, sin bloquear el resto del patrón.
_STRING_ARG_RE = re.compile(
    r"""
    (?P<receiver>[A-Za-z_$][A-Za-z0-9_$]*)?
    \s*\.\s*
    (?P<method>from|rpc)
    \s*\(
    \s*
    (?:
        '(?P<sq>(?:[^'\\]|\\.)*)'
      | "(?P<dq>(?:[^"\\]|\\.)*)"
      | `(?P<bt>(?:[^`\\]|\\.)*)`
    )
    """,
    re.VERBOSE,
)

# Versión amplia: cualquier sitio de llamada `.from(`/`.rpc(`, sin importar
# el tipo de argumento — se usa solo para detectar (y contar, en el modo
# dry-run) los casos dinámicos que `_STRING_ARG_RE` no pudo resolver.
_CALL_SITE_RE = re.compile(
    r"""
    (?P<receiver>[A-Za-z_$][A-Za-z0-9_$]*)?
    \s*\.\s*
    (?P<method>from|rpc)
    \s*\(
    """,
    re.VERBOSE,
)


def normalize_relation_name(raw: str) -> str:
    """Lowercase; strips a leading `public.` schema qualifier (paridad con
    el gate del backend — en la práctica los literales del frontend casi
    nunca vienen calificados, pero no cuesta nada ser consistentes).
    """
    name = raw.strip().lower()
    if name.startswith("public."):
        name = name[len("public."):]
    return name


def _scan_calls(cleaned: str):
    """Única pasada sobre el texto (ya sin comentarios) que genera, para
    cada sitio de llamada `.from(`/`.rpc(` encontrado, una tupla
    `(start, lineno, method, receiver, literal)`. `literal` es el contenido
    del string cuando el argumento es un literal estático SIN interpolación
    (`${...}`); `None` cuando el argumento es dinámico (identificador,
    expresión, o un template literal que interpola). Fuente única de verdad
    para `extract_refs` (usa las entradas con `literal is not None`) y
    `count_dynamic_call_sites` (cuenta las que tienen `literal is None`) —
    evita tener el mismo regex de detección de llamada duplicado y
    potencialmente desincronizado entre las dos funciones.
    """
    # El número de línea reportado se calcula desde `m.start("method")` (la
    # posición del propio "from"/"rpc"), NO desde `m.start()` del match
    # completo: en una cadena multi-línea (`supabase\n  .from('x')`), el
    # receptor "supabase" puede estar una línea antes que el `.from(` real
    # — reportar esa línea sería apuntar al desarrollador al lugar
    # equivocado del archivo.
    seen_starts: set[int] = set()
    for m in _STRING_ARG_RE.finditer(cleaned):
        receiver = m.group("receiver")
        method = m.group("method").lower()
        literal = m.group("sq")
        if literal is None:
            literal = m.group("dq")
        if literal is None:
            literal = m.group("bt")
            if literal is not None and "${" in literal:
                literal = None  # template con interpolación -> dinámico
        lineno = cleaned.count("\n", 0, m.start("method")) + 1
        seen_starts.add(m.start())
        yield m.start(), lineno, method, receiver, literal

    for m in _CALL_SITE_RE.finditer(cleaned):
        if m.start() in seen_starts:
            continue
        receiver = m.group("receiver")
        method = m.group("method").lower()
        lineno = cleaned.count("\n", 0, m.start("method")) + 1
        yield m.start(), lineno, method, receiver, None


def extract_refs(source: str) -> list[Ref]:
    """Pure function: TS/TSX source text in, list of `Ref` out."""
    cleaned = strip_comments(source)
    refs: list[Ref] = []
    for _start, lineno, method, receiver, literal in _scan_calls(cleaned):
        if literal is None:
            continue
        if method == "from" and receiver in _EXCLUDED_FROM_RECEIVERS:
            continue
        name = normalize_relation_name(literal)
        if not name:
            continue
        kind = "function" if method == "rpc" else "table"
        refs.append(Ref(name=name, lineno=lineno, kind=kind))
    return sorted(set(refs), key=lambda r: (r.lineno, r.name, r.kind))


def count_dynamic_call_sites(source: str) -> int:
    """Cuenta llamadas `.from(`/`.rpc(` con argumento dinámico (no resoluble
    de forma estática) — solo para reporting/dry-run, el gate NO falla por
    estos casos (limitación documentada, igual que el backend con
    f-strings). Excluye los sitios que ya se descartan por receptor
    (`Array`/`Object`/`storage`): no son llamadas reales a supabase-js
    apuntando a una tabla, así que no deben inflar la métrica de "llamadas
    dinámicas que el gate no pudo resolver".
    """
    cleaned = strip_comments(source)
    count = 0
    for _start, _lineno, method, receiver, literal in _scan_calls(cleaned):
        if method == "from" and receiver in _EXCLUDED_FROM_RECEIVERS:
            continue
        if literal is None:
            count += 1
    return count


def is_known(ref: Ref, tables: set[str], functions: set[str]) -> bool:
    if ref.name in ALLOWLIST:
        return True
    pool = functions if ref.kind == "function" else tables
    return ref.name in pool


# ── existing-objects lookup (single psql call, stdlib subprocess only) ────

_EXISTING_OBJECTS_SQL = """
SELECT 'T', n.nspname, c.relname
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r','v','m','p','f')
UNION ALL
SELECT 'F', n.nspname, p.proname
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace;
"""


def fetch_existing_objects(dsn: str) -> tuple[set[str], set[str]]:
    """Returns (tables_and_views, functions) as normalized name sets.

    Cada objeto se agrega schema-calificado (`schema.name`) Y, a diferencia
    del gate del backend, TAMBIÉN bare (`name`) sin importar el schema — ver
    la nota "Resolución de nombres cross-schema" en el docstring del módulo.
    """
    result = subprocess.run(
        ["psql", "-At", "-F", "\t", dsn, "-c", _EXISTING_OBJECTS_SQL],
        capture_output=True,
        text=True,
        check=True,
    )
    tables: set[str] = set()
    functions: set[str] = set()
    for line in result.stdout.splitlines():
        if not line.strip():
            continue
        kind, schema, name = line.split("\t")
        schema = schema.strip().lower()
        name = name.strip().lower()
        target = tables if kind == "T" else functions
        target.add(f"{schema}.{name}")
        target.add(name)
    return tables, functions


# ── file discovery ─────────────────────────────────────────────────────────

# Directorios que nunca se recorren (rendimiento + ruido): `node_modules`
# puede tener miles de `.ts`/`.tsx` de definiciones de tipos, y `.next` es
# output de build.
_SKIP_DIRS = {"node_modules", ".next"}


def is_test_file(path: Path) -> bool:
    """True si `path` es un archivo de test y debe excluirse del scan:
    cualquier cosa bajo un directorio `__tests__/`, o nombrado
    `*.test.ts`/`*.test.tsx` — estos archivos mockean supabase-js con
    nombres de tabla/función inventados a propósito (fixtures), que nunca
    van a existir en el schema real por diseño.
    """
    if "__tests__" in path.parts:
        return True
    name = path.name
    return name.endswith(".test.ts") or name.endswith(".test.tsx")


def iter_frontend_files(root: Path) -> list[Path]:
    """All `*.ts`/`*.tsx` under `root`, excluding `node_modules/`, `.next/`
    y archivos de test (ver `is_test_file`).
    """
    files: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in _SKIP_DIRS]
        for fname in filenames:
            if not (fname.endswith(".ts") or fname.endswith(".tsx")):
                continue
            p = Path(dirpath) / fname
            if is_test_file(p):
                continue
            files.append(p)
    return sorted(files)


# ── CLI ──────────────────────────────────────────────────────────────────


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dsn",
        required=True,
        help="Postgres DSN, e.g. postgresql://postgres:postgres@127.0.0.1:54322/postgres",
    )
    parser.add_argument(
        "--root",
        default="frontend",
        help="Directorio a escanear (default: frontend)",
    )
    args = parser.parse_args(argv)

    root = Path(args.root)
    if not root.is_dir():
        print(f"ERROR: directorio no encontrado: {root}", file=sys.stderr)
        return 1

    files = iter_frontend_files(root)

    all_refs: list[tuple[Path, Ref]] = []
    dynamic_skipped = 0
    for f in files:
        source = f.read_text(encoding="utf-8")
        for ref in extract_refs(source):
            all_refs.append((f, ref))
        dynamic_skipped += count_dynamic_call_sites(source)

    try:
        tables, functions = fetch_existing_objects(args.dsn)
    except FileNotFoundError:
        print("ERROR: psql no está disponible en PATH", file=sys.stderr)
        return 1
    except subprocess.CalledProcessError as exc:
        print(
            f"ERROR: no se pudo consultar el schema real via psql: {exc.stderr}",
            file=sys.stderr,
        )
        return 1

    violations = [(f, ref) for f, ref in all_refs if not is_known(ref, tables, functions)]

    if violations:
        for f, ref in sorted(violations, key=lambda item: (str(item[0]), item[1].lineno)):
            kind_label = "función" if ref.kind == "function" else "tabla/vista"
            print(f"{f}:{ref.lineno}: referencia a {kind_label} desconocida: '{ref.name}'")
        print(
            f"\n{len(violations)} referencia(s) desconocida(s) en "
            f"{len(files)} archivo(s) escaneados.",
            file=sys.stderr,
        )
        return 1

    distinct = {ref.name for _, ref in all_refs}
    print(
        f"OK: {len(files)} archivos escaneados, {len(distinct)} "
        "relaciones/funciones distintas verificadas contra el schema real "
        f"({dynamic_skipped} llamada(s) dinámica(s) omitida(s))."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
