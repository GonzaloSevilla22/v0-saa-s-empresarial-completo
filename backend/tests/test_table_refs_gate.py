"""Tests for scripts/ci/check_backend_table_refs.py (CI gate).

Motivación (postmortem `organizations`): un repositorio consultaba una tabla
`organizations` que no existía en el schema real durante ~2 meses porque los
tests unitarios mockeaban la conexión asyncpg — nada ejecutaba la query real
contra un schema de verdad. Este gate escanea el texto fuente de `backend/`
en busca de referencias a tablas/vistas/funciones (FROM/JOIN/UPDATE/INSERT
INTO/DELETE FROM/TRUNCATE) y las valida contra `pg_class`/`pg_proc` de una DB
real (el schema de la cadena de migraciones, vía CI).

Estos tests cubren SOLO la lógica de extracción/clasificación (funciones
puras, texto en -> refs afuera) — no la llamada real a psql (`fetch_existing_objects`
se testea mockeando `subprocess.run`).
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

_SCRIPT_DIR = Path(__file__).resolve().parents[2] / "scripts" / "ci"
if str(_SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPT_DIR))

import check_backend_table_refs as gate  # noqa: E402


# ── FROM / JOIN / UPDATE / INSERT INTO / DELETE FROM ────────────────────────


def test_extracts_simple_from():
    src = 'x = "SELECT * FROM sales WHERE id = $1"\n'
    refs = gate.extract_refs(src)
    assert ("sales", "table") in [(r.name, r.kind) for r in refs]


def test_extracts_join():
    src = 'x = "SELECT * FROM sales s JOIN clients c ON c.id = s.client_id"\n'
    names = {r.name for r in gate.extract_refs(src)}
    assert "sales" in names
    assert "clients" in names


def test_extracts_update():
    src = 'x = "UPDATE products SET name = $1 WHERE id = $2"\n'
    refs = gate.extract_refs(src)
    assert ("products", "table") in [(r.name, r.kind) for r in refs]


def test_extracts_insert_into():
    src = 'x = "INSERT INTO clients (name) VALUES ($1)"\n'
    refs = gate.extract_refs(src)
    assert ("clients", "table") in [(r.name, r.kind) for r in refs]


def test_extracts_delete_from():
    src = 'x = "DELETE FROM operation_idempotency WHERE id = $1"\n'
    refs = gate.extract_refs(src)
    assert ("operation_idempotency", "table") in [(r.name, r.kind) for r in refs]


def test_extracts_truncate_with_optional_table_keyword():
    src1 = 'x = "TRUNCATE stock_movements"\n'
    src2 = 'x = "TRUNCATE TABLE stock_movements"\n'
    for src in (src1, src2):
        names = {r.name for r in gate.extract_refs(src)}
        assert "stock_movements" in names


# ── schema-prefix normalization ──────────────────────────────────────────


def test_strips_public_schema_prefix():
    src = 'x = "SELECT * FROM public.sales"\n'
    names = {r.name for r in gate.extract_refs(src)}
    assert names == {"sales"}


def test_preserves_non_public_schema_prefix():
    src = 'x = "SELECT * FROM auth.users"\n'
    names = {r.name for r in gate.extract_refs(src)}
    assert names == {"auth.users"}


def test_normalize_relation_name_lowercases_and_strips_public():
    assert gate.normalize_relation_name("Public.Sales") == "sales"
    assert gate.normalize_relation_name("SALES") == "sales"
    assert gate.normalize_relation_name("auth.Users") == "auth.users"


# ── function-call classification ─────────────────────────────────────────


def test_classifies_function_call_after_paren():
    src = 'x = "SELECT * FROM rpc_close_cash_session($1, $2)"\n'
    refs = gate.extract_refs(src)
    match = [r for r in refs if r.name == "rpc_close_cash_session"]
    assert match and match[0].kind == "function"


def test_classifies_table_when_followed_by_alias_not_paren():
    src = 'x = "SELECT * FROM sale_items si JOIN products p ON p.id = si.product_id"\n'
    refs = {r.name: r.kind for r in gate.extract_refs(src)}
    assert refs["sale_items"] == "table"
    assert refs["products"] == "table"


def test_insert_into_column_list_paren_is_not_a_function_call():
    # "INSERT INTO clients (name) VALUES (...)" — el paréntesis pegado al
    # nombre de tabla es la lista de columnas del INSERT, no una llamada a
    # función. Regresión: el heurístico "identificador seguido de ( = función"
    # solo debe aplicar a FROM/JOIN, nunca a INSERT INTO/UPDATE/DELETE FROM.
    src = 'x = "INSERT INTO clients (name, email) VALUES ($1, $2)"\n'
    refs = gate.extract_refs(src)
    match = [r for r in refs if r.name == "clients"]
    assert match and match[0].kind == "table"


def test_bare_select_rpc_call_without_from_is_classified_as_function():
    # Convención real del proyecto: los RPCs propios se llaman a menudo como
    # "SELECT rpc_x(...)" / "SELECT public.rpc_x(...)" sin FROM.
    src = 'x = "SELECT rpc_create_bank_account($1, $2)"\n'
    refs = gate.extract_refs(src)
    match = [r for r in refs if r.name == "rpc_create_bank_account"]
    assert match and match[0].kind == "function"


def test_bare_select_builtin_function_is_not_captured_as_a_reference():
    # COUNT/COALESCE/NOW/etc son funciones built-in de Postgres (viven en
    # pg_catalog, no en public) — el gate NO debe intentar validarlas: solo
    # dispara para identificadores con el prefijo real `rpc_`.
    src = 'x = "SELECT COUNT(*), COALESCE(SUM(amount), 0) FROM sales WHERE now() > created_at"\n'
    names = {r.name for r in gate.extract_refs(src)}
    assert names == {"sales"}


def test_classifies_schema_qualified_function_call():
    src = 'x = "SELECT * FROM public.rpc_reverse_stock_movement($1::uuid, $2, $3)"\n'
    refs = gate.extract_refs(src)
    match = [r for r in refs if r.name == "rpc_reverse_stock_movement"]
    assert match and match[0].kind == "function"


# ── CTE exclusion ─────────────────────────────────────────────────────────


def test_excludes_single_cte_name():
    src = (
        'x = """\n'
        "WITH op_page AS (\n"
        "  SELECT id FROM sales WHERE account_id = $1\n"
        ")\n"
        "SELECT * FROM op_page JOIN sales s ON s.id = op_page.id\n"
        '"""\n'
    )
    names = {r.name for r in gate.extract_refs(src)}
    assert "op_page" not in names
    assert "sales" in names


def test_excludes_comma_separated_cte_names():
    src = (
        'x = """\n'
        "WITH first_cte AS (\n"
        "  SELECT id FROM sales\n"
        "), second_cte AS (\n"
        "  SELECT id FROM first_cte\n"
        ")\n"
        "SELECT * FROM second_cte\n"
        '"""\n'
    )
    names = {r.name for r in gate.extract_refs(src)}
    assert "first_cte" not in names
    assert "second_cte" not in names
    assert "sales" in names


# ── subquery FROM ( skip ─────────────────────────────────────────────────


def test_skips_subquery_from_paren():
    src = (
        'x = """\n'
        "SELECT p.name\n"
        "FROM (SELECT $1::uuid AS product_id) AS item_ref\n"
        "LEFT JOIN public.products p ON p.id = item_ref.product_id\n"
        '"""\n'
    )
    names = {r.name for r in gate.extract_refs(src)}
    assert "item_ref" not in names
    assert "products" in names


# ── case-insensitivity ────────────────────────────────────────────────────


def test_case_insensitive_keywords():
    src = 'x = "select * from Sales s join Clients c on c.id = s.client_id"\n'
    names = {r.name for r in gate.extract_refs(src)}
    assert "sales" in names
    assert "clients" in names


# ── f-string SQL ───────────────────────────────────────────────────────────


def test_extracts_from_fstring_sql():
    src = (
        "cols = 'id, name'\n"
        'x = f"""\n'
        "SELECT {cols}\n"
        "FROM   client_addresses\n"
        "WHERE  id = $1\n"
        '"""\n'
    )
    names = {r.name for r in gate.extract_refs(src)}
    assert "client_addresses" in names


def test_extracts_from_dynamic_fstring_update_ignores_braced_table_var():
    # Nombre de tabla interpolado dinámicamente (p. ej. BaseRepository.soft_delete):
    # el regex no debe crashear ni inventar un nombre de tabla con las llaves.
    src = 'x = f"UPDATE {table} SET deleted_at = now() WHERE id = $1"\n'
    refs = gate.extract_refs(src)
    assert refs == []


# ── comments / docstrings must NOT leak false positives ────────────────────


def test_ignores_python_from_import_statement():
    # Regresión (hallazgo real escaneando backend/): "from X import Y" es
    # sintaxis de Python, no una cláusula SQL FROM — `from`/`import` ahí son
    # tokens NAME/keyword, nunca STRING. Un archivo con CERO strings (p.ej.
    # solo imports + anotaciones Pydantic, como backend/schemas/branches.py)
    # no debe filtrar sus imports como referencias a tabla.
    src = (
        "from __future__ import annotations\n"
        "\n"
        "from decimal import Decimal\n"
        "from pydantic import BaseModel\n"
        "\n"
        "\n"
        "class BranchCreate(BaseModel):\n"
        "    name: str\n"
    )
    refs = gate.extract_refs(src)
    assert refs == []


def test_ignores_from_import_even_when_file_has_unrelated_strings():
    src = (
        "from fastapi import APIRouter\n"
        "\n"
        'router = APIRouter(prefix="/branches")\n'
        'x = "SELECT * FROM branches"\n'
    )
    names = {r.name for r in gate.extract_refs(src)}
    assert names == {"branches"}


def test_ignores_table_like_word_in_hash_comment():
    src = (
        "# JOIN a mano al reves para preservar el 404\n"
        'x = "SELECT * FROM sales"\n'
    )
    names = {r.name for r in gate.extract_refs(src)}
    assert names == {"sales"}
    assert "a" not in names


def test_ignores_spanish_prose_in_docstring():
    src = (
        "def transition_quote():\n"
        '    """UPDATE del status del quote. Devuelve la fila actualizada."""\n'
        '    return "UPDATE public.quotes SET status = $2"\n'
    )
    names = {r.name for r in gate.extract_refs(src)}
    assert "quotes" in names
    assert "del" not in names


def test_ignores_for_update_skip_locked_clause():
    src = 'x = "SELECT * FROM fiscal_documents FOR UPDATE SKIP LOCKED"\n'
    names = {r.name for r in gate.extract_refs(src)}
    assert "skip" not in names
    assert "fiscal_documents" in names


def test_ignores_on_conflict_do_update_set_clause():
    src = (
        'x = """\n'
        "INSERT INTO public.fiscal_profiles (account_id, cuit)\n"
        "VALUES ($1, $2)\n"
        "ON CONFLICT (account_id) DO UPDATE\n"
        "  SET cuit = EXCLUDED.cuit\n"
        '"""\n'
    )
    names = {r.name for r in gate.extract_refs(src)}
    assert "set" not in names
    assert "fiscal_profiles" in names


def test_ignores_join_lateral_clause():
    # Regresión clientes-frecuentes-historial: `client_repository.py` usa
    # `LEFT JOIN LATERAL (subquery) agg ON TRUE` (design.md §4, agregados de
    # actividad). El regex de relación captura el identificador inmediato
    # después de JOIN — "LATERAL" — y como JOIN admite llamadas a función,
    # "LATERAL (" se clasifica como llamada a una función inexistente
    # 'lateral'. LATERAL es un modificador de JOIN de SQL estándar, no una
    # tabla ni una función — mismo tratamiento que SKIP LOCKED/SET (línea
    # 61, `_SQL_KEYWORD_NOISE`).
    src = (
        'x = """\n'
        "SELECT * FROM clients c\n"
        "LEFT JOIN LATERAL (\n"
        "    SELECT 1\n"
        ") agg ON TRUE\n"
        '"""\n'
    )
    names = {r.name for r in gate.extract_refs(src)}
    assert "lateral" not in names
    assert "clients" in names


def test_does_not_crash_on_ternary_expression_body_field():
    # Regresión: ast.IfExp también tiene un campo `.body`, pero es un único
    # nodo expresión (no una lista de statements) — tratarlo como docstring
    # holder revienta con TypeError al indexar body[0]. Este patrón aparece
    # seguido en f-strings con expresiones condicionales.
    src = (
        "def f(cond):\n"
        '    label = "activo" if cond else "inactivo"\n'
        '    return f"SELECT * FROM sales WHERE status = \'{label}\'"\n'
    )
    names = {r.name for r in gate.extract_refs(src)}
    assert "sales" in names


# ── line numbers ─────────────────────────────────────────────────────────


def test_lineno_points_to_the_line_with_the_keyword():
    src = (
        "x = 1\n"  # line 1
        "y = 2\n"  # line 2
        'z = "SELECT * FROM sales"\n'  # line 3
    )
    refs = gate.extract_refs(src)
    match = [r for r in refs if r.name == "sales"]
    assert match and match[0].lineno == 3


def test_lineno_correct_after_docstring_blanking_shifts_nothing():
    src = (
        "def f():\n"  # line 1
        '    """Some docstring about UPDATE del status here."""\n'  # line 2
        '    return "SELECT * FROM sales"\n'  # line 3
    )
    refs = gate.extract_refs(src)
    match = [r for r in refs if r.name == "sales"]
    assert match and match[0].lineno == 3


# ── allowlist / existence check ─────────────────────────────────────────


def test_is_known_true_for_table_in_existing_set():
    ref = gate.Ref(name="sales", lineno=1, kind="table")
    assert gate.is_known(ref, tables={"sales"}, functions=set())


def test_is_known_false_for_missing_table():
    ref = gate.Ref(name="organizations", lineno=1, kind="table")
    assert not gate.is_known(ref, tables={"sales"}, functions=set())


def test_is_known_respects_allowlist(monkeypatch):
    monkeypatch.setattr(gate, "ALLOWLIST", frozenset({"legacy_ghost_table"}))
    ref = gate.Ref(name="legacy_ghost_table", lineno=1, kind="table")
    assert gate.is_known(ref, tables=set(), functions=set())


# ── fetch_existing_objects (psql call, mocked) ───────────────────────────


def test_fetch_existing_objects_parses_psql_output():
    fake_stdout = (
        "T\tpublic\tsales\n"
        "T\tpublic\tv_products_with_stock\n"
        "T\tauth\tusers\n"
        "F\tpublic\trpc_close_cash_session\n"
    )
    completed = MagicMock(stdout=fake_stdout, returncode=0)
    with patch("check_backend_table_refs.subprocess.run", return_value=completed) as run:
        tables, functions = gate.fetch_existing_objects("postgresql://x/y")
    run.assert_called_once()
    assert "sales" in tables
    assert "public.sales" in tables
    assert "auth.users" in tables
    assert "users" not in tables  # non-public schema: no bare alias
    assert "rpc_close_cash_session" in functions
    assert "public.rpc_close_cash_session" in functions


def test_fetch_existing_objects_raises_on_psql_failure():
    with patch(
        "check_backend_table_refs.subprocess.run",
        side_effect=subprocess.CalledProcessError(1, ["psql"], stderr="connection refused"),
    ):
        with pytest.raises(subprocess.CalledProcessError):
            gate.fetch_existing_objects("postgresql://x/y")


# ── file discovery (excludes backend/tests) ──────────────────────────────


def test_iter_backend_files_excludes_tests_dir(tmp_path):
    (tmp_path / "repositories").mkdir()
    (tmp_path / "tests").mkdir()
    (tmp_path / "repositories" / "sales_repository.py").write_text("x = 1\n")
    (tmp_path / "tests" / "test_sales_repository.py").write_text("x = 1\n")
    files = gate.iter_backend_files(tmp_path)
    names = {p.name for p in files}
    assert "sales_repository.py" in names
    assert "test_sales_repository.py" not in names


def test_iter_backend_files_excludes_pycache(tmp_path):
    (tmp_path / "__pycache__").mkdir()
    (tmp_path / "__pycache__" / "sales_repository.cpython-313.pyc.py").write_text("x = 1\n")
    (tmp_path / "sales_repository.py").write_text("x = 1\n")
    files = gate.iter_backend_files(tmp_path)
    names = {p.name for p in files}
    assert "sales_repository.py" in names
    assert not any("__pycache__" in p.parts for p in files)
