#!/usr/bin/env python3
"""Gate CI: valida que toda referencia a tabla/vista/función SQL en el
código del backend exista realmente en el schema (cadena de migraciones de
Supabase aplicada por `supabase start` en CI).

Motivación (postmortem `organizations`): un repositorio consultaba una tabla
`organizations` que nunca existió en el schema real durante ~2 meses — los
tests unitarios mockeaban `asyncpg`, así que nada ejecutaba la query contra
una base real y el bug quedó invisible hasta que alguien lo pisó en
producción. Este script escanea el texto fuente
de `backend/**/*.py` (excluyendo `backend/tests/**`) en busca de referencias
FROM / JOIN / UPDATE / INSERT INTO / DELETE FROM / TRUNCATE y las valida
contra `pg_class` (tablas/vistas/vistas materializadas/particiones/foreign
tables) y `pg_proc` (funciones, para llamadas RPC) de una base Postgres real,
pasada por `--dsn`.

Es un scanner de TEXTO, no un parser SQL/Python completo: usa `tokenize` y
`ast` (stdlib) solo para no confundir comentarios/docstrings en español con
SQL real (p.ej. "# JOIN a mano" o un docstring que dice "UPDATE del status"
no deben generarse como referencias). El resto es regex sobre el texto
fuente, incluyendo el contenido de f-strings (que siguen siendo texto
literal fuera de los `{...}`).

Limitaciones conocidas (documentadas, no bugs):
- Nombres de tabla/función interpolados dinámicamente (p.ej.
  `f"UPDATE {table} SET ..."` en BaseRepository.soft_delete) no se pueden
  resolver de forma estática — el regex requiere un identificador literal
  inmediatamente después de la keyword, así que estos casos se ignoran en
  silencio (no crashean, no generan falsos positivos).
- Valida contra el schema QUE ARMA LA CADENA DE MIGRACIONES EN CI, no contra
  producción directamente. Un gap entre CI y prod es una señal real pero
  separada (ver cross-check manual contra prod en la PR de este gate).
"""
from __future__ import annotations

import argparse
import ast
import io
import re
import subprocess
import sys
import tokenize
from collections import namedtuple
from pathlib import Path

# ── Allowlist ────────────────────────────────────────────────────────────
# Vacía a propósito. Cada entrada debe llevar un comentario justificando
# POR QUÉ el gate no puede resolver esa referencia contra el schema real
# (p.ej. un gap confirmado entre el schema de CI y prod, con link al hallazgo).
ALLOWLIST: frozenset[str] = frozenset()

# Palabras reservadas de SQL que el regex de relación puede capturar por
# error porque la gramática de Postgres permite `UPDATE` sin nombre de tabla
# a continuación en dos construcciones válidas:
#   - "... FOR UPDATE SKIP LOCKED" / "FOR UPDATE NOWAIT" (row locking)
#   - "INSERT ... ON CONFLICT (...) DO UPDATE SET ..." (upsert, sin repetir
#     el nombre de tabla tras DO UPDATE)
# y porque "TRUNCATE TABLE x" tiene la keyword opcional TABLE en el medio
# (ya manejada aparte en el regex, pero se blockea igual por defensa en
# profundidad si algún día cambia el regex).
_SQL_KEYWORD_NOISE = {"set", "skip", "locked", "nowait", "table"}

Ref = namedtuple("Ref", ["name", "lineno", "kind"])  # kind: "table" | "function"

_RELATION_RE = re.compile(
    r"""
    \b(?P<keyword>FROM|JOIN|UPDATE|INSERT\s+INTO|DELETE\s+FROM|TRUNCATE(?:\s+TABLE)?)\b
    \s+
    (?P<ident>[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?)
    """,
    re.IGNORECASE | re.VERBOSE,
)

# Solo FROM/JOIN admiten llamadas a función en SQL real (p.ej.
# `FROM rpc_x($1)`, `JOIN rpc_x($1) AS t`). INSERT INTO/UPDATE/DELETE
# FROM/TRUNCATE siempre toman un nombre de tabla — nunca una función — así
# que un paréntesis pegado ahí es la lista de columnas de un INSERT
# (`INSERT INTO clients (name) VALUES (...)`), no una llamada a función.
_KEYWORDS_ALLOWING_FUNCTION_CALL = {"FROM", "JOIN"}

_CTE_RE = re.compile(
    r"""
    (?: \bWITH(?:\s+RECURSIVE)?\s+ | , \s* )
    (?P<name>[A-Za-z_][A-Za-z0-9_]*)
    \s+AS\s*\(
    """,
    re.IGNORECASE | re.VERBOSE,
)

_FUNCTION_TAIL_RE = re.compile(r"[ \t]*\(")

# RPCs propios del proyecto se llaman con frecuencia como `SELECT rpc_x(...)`
# / `SELECT public.rpc_x(...)` — sin FROM. La keyword SELECT no se puede usar
# como disparador genérico ("SELECT identifier(" también matchea funciones
# built-in de Postgres como COUNT(*)/COALESCE(...)/NOW(), que no están en el
# schema `public` y romperían el gate con falsos positivos), así que en vez
# de eso se ancla a la convención de nombres real del proyecto: toda función
# propia acá se llama `rpc_*` (confirmado — ninguna función built-in de
# Postgres empieza así). Esto se busca en CUALQUIER posición del texto
# (no solo tras SELECT), así que también matchea `FROM rpc_x(...)` —
# duplicado inofensivo con `_RELATION_RE`, deduplicado en `extract_refs`.
_RPC_CALL_RE = re.compile(
    r"""
    \b(?P<ident>(?:public\.)?rpc_[A-Za-z0-9_]+)
    \s*\(
    """,
    re.IGNORECASE | re.VERBOSE,
)


def normalize_relation_name(raw: str) -> str:
    """Lowercase; strips a leading `public.` schema qualifier."""
    name = raw.strip().lower()
    if name.startswith("public."):
        name = name[len("public."):]
    return name


# tokenize.FSTRING_MIDDLE only exists on py3.12+ (PEP 701 re-tokenized
# f-strings into FSTRING_START/MIDDLE/END + regular expression tokens for
# the `{...}` parts). On 3.10/3.11 an f-string is a single STRING token,
# `{...}` included as literal text — still fine, since we only ever look
# for SQL keywords in the literal text, never inside `{...}`.
_STRING_TOKEN_TYPES = {tokenize.STRING}
if hasattr(tokenize, "FSTRING_MIDDLE"):
    _STRING_TOKEN_TYPES.add(tokenize.FSTRING_MIDDLE)

_Pos = tuple[int, int]  # (line, col) — 1-indexed line, 0-indexed col (ast/tokenize convention)
_Span = tuple[_Pos, _Pos]


def _string_literal_spans(source: str) -> list[_Span]:
    """Spans of actual Python string-literal CONTENT (STRING tokens, and on
    py3.12+ FSTRING_MIDDLE segments) — this is the only place real SQL can
    live in the source. Using `tokenize` instead of scanning raw text is
    what keeps Python's own `from X import Y` from being mistaken for a SQL
    `FROM` clause: `from`/`import` there are NAME/keyword tokens, never a
    STRING token, so they're simply never visited.
    """
    spans: list[_Span] = []
    try:
        for tok in tokenize.generate_tokens(io.StringIO(source).readline):
            if tok.type in _STRING_TOKEN_TYPES:
                spans.append((tok.start, tok.end))
    except (tokenize.TokenizeError, IndentationError, SyntaxError):
        pass
    return spans


def _docstring_spans(source: str) -> list[_Span]:
    """Spans of module/class/function docstrings — these ARE string
    literals too (same token type as real SQL), but they're prose, not SQL,
    and Spanish prose next to an SQL keyword (e.g. a docstring saying
    "UPDATE del status del quote...") must not be mistaken for a reference.
    """
    try:
        tree = ast.parse(source)
    except SyntaxError:
        return []

    spans: list[_Span] = []
    holders = (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)
    for node in ast.walk(tree):
        if not isinstance(node, holders):
            # NB: no usar `getattr(node, "body", None)` genérico acá —
            # ast.IfExp también tiene un campo `body`, pero es un único nodo
            # expresión (no una lista de statements); tratarlo como si
            # tuviera sub-statements revienta más abajo.
            continue
        body = node.body
        if not body:
            continue
        first = body[0]
        if (
            isinstance(first, ast.Expr)
            and isinstance(first.value, ast.Constant)
            and isinstance(first.value.value, str)
        ):
            n = first.value
            if n.end_lineno is not None and n.end_col_offset is not None:
                spans.append(((n.lineno, n.col_offset), (n.end_lineno, n.end_col_offset)))
    return spans


def _reveal_only(source: str, spans: list[_Span]) -> str:
    """Inverse of blanking: returns `source` with everything EXCEPT the
    given spans replaced by spaces — newlines are always preserved so line
    numbers of whatever remains stay identical to the original file.
    """
    lines = source.splitlines(keepends=True)
    canvas = []
    for line in lines:
        has_nl = line.endswith("\n")
        body_len = len(line) - (1 if has_nl else 0)
        canvas.append(" " * body_len + ("\n" if has_nl else ""))

    for (start_line, start_col), (end_line, end_col) in spans:
        if start_line == end_line:
            original, row = lines[start_line - 1], canvas[start_line - 1]
            canvas[start_line - 1] = row[:start_col] + original[start_col:end_col] + row[end_col:]
            continue
        first_orig, first_row = lines[start_line - 1], canvas[start_line - 1]
        canvas[start_line - 1] = first_row[:start_col] + first_orig[start_col:]
        for mid in range(start_line, end_line - 1):
            canvas[mid] = lines[mid]
        last_orig, last_row = lines[end_line - 1], canvas[end_line - 1]
        canvas[end_line - 1] = last_orig[:end_col] + last_row[end_col:]
    return "".join(canvas)


def strip_comments_and_docstrings(source: str) -> str:
    """Returns `source` with everything blanked out EXCEPT the content of
    real string literals that are not docstrings — i.e. only text that
    could plausibly be a SQL string passed to asyncpg survives. This is
    what excludes, in one pass: Python code (so `from fastapi import X`
    can't be mistaken for a SQL `FROM`), `#` comments (never a STRING
    token), and docstrings (subtracted explicitly). Best-effort: if the
    source doesn't tokenize/parse cleanly, falls back to the original text.
    """
    string_spans = _string_literal_spans(source)
    doc_spans = _docstring_spans(source)

    def _covered_by_a_docstring(span: _Span) -> bool:
        (s_start, s_end) = span
        return any(d_start <= s_start and s_end <= d_end for d_start, d_end in doc_spans)

    keep = [s for s in string_spans if not _covered_by_a_docstring(s)]
    return _reveal_only(source, keep)


def find_cte_names(source: str) -> set[str]:
    """Best-effort, file-wide (not per-query) collection of CTE names
    defined via `WITH x AS (` / `, y AS (` — these are local aliases, not
    real relations, and must be excluded from the ref set.
    """
    return {m.group("name").lower() for m in _CTE_RE.finditer(source)}


def extract_refs(source: str) -> list[Ref]:
    """Pure function: Python source text in, list of `Ref` out.

    Runs comment/docstring blanking first, then the relation regexes over
    the blanked text (line numbers are preserved 1:1 because blanking only
    replaces characters with spaces, never removes lines).
    """
    blanked = strip_comments_and_docstrings(source)
    cte_names = find_cte_names(blanked)

    refs: list[Ref] = []
    for match in _RELATION_RE.finditer(blanked):
        raw_ident = match.group("ident")
        name = normalize_relation_name(raw_ident)
        if name in _SQL_KEYWORD_NOISE or name in cte_names:
            continue
        keyword = re.sub(r"\s+", " ", match.group("keyword").strip().upper())
        tail = blanked[match.end():]
        is_function_call = (
            keyword in _KEYWORDS_ALLOWING_FUNCTION_CALL and _FUNCTION_TAIL_RE.match(tail)
        )
        kind = "function" if is_function_call else "table"
        lineno = blanked.count("\n", 0, match.start()) + 1
        refs.append(Ref(name=name, lineno=lineno, kind=kind))

    for match in _RPC_CALL_RE.finditer(blanked):
        name = normalize_relation_name(match.group("ident"))
        lineno = blanked.count("\n", 0, match.start()) + 1
        refs.append(Ref(name=name, lineno=lineno, kind="function"))

    # `_RPC_CALL_RE` overlaps `_RELATION_RE` for `FROM rpc_x(...)` /
    # `JOIN rpc_x(...)` — both produce the identical (name, lineno, kind)
    # entry in that case. Dedupe while keeping a stable, sorted order.
    return sorted(set(refs), key=lambda r: (r.lineno, r.name, r.kind))


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

    Each object is added both schema-qualified (`schema.name`) and, when its
    schema is `public`, bare (`name`) — mirroring `normalize_relation_name`,
    which only strips the `public.` prefix and leaves other schemas
    qualified (e.g. `auth.users`).
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
        if schema == "public":
            target.add(name)
    return tables, functions


# ── file discovery ─────────────────────────────────────────────────────────


def iter_backend_files(root: Path) -> list[Path]:
    """All `*.py` under `root`, excluding `tests/` and `__pycache__/`
    directories anywhere in the path (this is what keeps the gate's own
    test file, and anything under backend/tests/, out of the scan).
    """
    files = []
    for p in sorted(root.rglob("*.py")):
        if "tests" in p.parts or "__pycache__" in p.parts:
            continue
        files.append(p)
    return files


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
        default="backend",
        help="Directorio a escanear (default: backend)",
    )
    args = parser.parse_args(argv)

    root = Path(args.root)
    if not root.is_dir():
        print(f"ERROR: directorio no encontrado: {root}", file=sys.stderr)
        return 1

    files = iter_backend_files(root)

    all_refs: list[tuple[Path, Ref]] = []
    for f in files:
        source = f.read_text(encoding="utf-8")
        for ref in extract_refs(source):
            all_refs.append((f, ref))

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
        "relaciones/funciones distintas verificadas contra el schema real."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
