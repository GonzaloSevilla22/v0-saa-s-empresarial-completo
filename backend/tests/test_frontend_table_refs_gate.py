"""Tests for scripts/ci/check_frontend_table_refs.py (CI gate).

Motivación: mismo postmortem `organizations` que motivó
`scripts/ci/check_backend_table_refs.py` (ver `test_table_refs_gate.py`),
aplicado ahora al FRONTEND: el frontend le habla a Supabase vía PostgREST
usando strings literales (`supabase.from("tabla_fantasma")`), y ese error
solo se descubre en runtime — ni TypeScript ni los tests unitarios (que
mockean el cliente supabase-js) lo detectan. Este gate escanea el texto
fuente de `frontend/**/*.{ts,tsx}` en busca de `.from("x")` / `.rpc("fn")` y
los valida contra `pg_class`/`pg_proc` de una DB real.

Viven bajo `backend/tests/` (no `frontend/`) porque acá es donde corre la
suite de pytest en CI — mismo criterio que `test_table_refs_gate.py`.

Estos tests cubren SOLO la lógica de extracción/clasificación (funciones
puras, texto en -> refs afuera) — no la llamada real a psql
(`fetch_existing_objects` se testea mockeando `subprocess.run`).
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

import check_frontend_table_refs as gate  # noqa: E402


# ── .from( — comillas simples / dobles / backtick ───────────────────────────


def test_extracts_simple_from_double_quotes():
    src = 'const { data } = await supabase.from("sales").select("*")\n'
    refs = gate.extract_refs(src)
    assert ("sales", "table") in [(r.name, r.kind) for r in refs]


def test_extracts_simple_from_single_quotes():
    src = "const { data } = await supabase.from('clients').select('*')\n"
    refs = gate.extract_refs(src)
    assert ("clients", "table") in [(r.name, r.kind) for r in refs]


def test_extracts_simple_from_backtick_quotes():
    src = "const { data } = await supabase.from(`products`).select('*')\n"
    refs = gate.extract_refs(src)
    assert ("products", "table") in [(r.name, r.kind) for r in refs]


# ── multi-line chains ───────────────────────────────────────────────────────


def test_extracts_from_multiline_chain():
    src = (
        "const { data, error } = await supabase\n"
        "  .from('account_members')\n"
        "  .select('*')\n"
        "  .eq('account_id', accountId)\n"
    )
    names = {r.name for r in gate.extract_refs(src)}
    assert "account_members" in names


def test_lineno_points_to_the_from_line_in_multiline_chain():
    src = (
        "const query = supabase\n"  # line 1
        "  .from('branches')\n"  # line 2
        "  .select('*')\n"  # line 3
    )
    refs = gate.extract_refs(src)
    match = [r for r in refs if r.name == "branches"]
    assert match and match[0].lineno == 2


# ── Array.from / Object.from — JS builtins, NUNCA supabase-js ──────────────


def test_array_from_with_object_literal_is_excluded():
    src = "const rows = Array.from({ length: 6 }).map((_, i) => i)\n"
    refs = gate.extract_refs(src)
    assert refs == []


def test_array_from_with_string_literal_is_excluded():
    # Array.from admite un string como iterable — el argumento SÍ es un
    # string literal, pero el receptor es `Array`, no supabase-js: debe
    # excluirse igual. Regresión: sin el filtro por receptor, esto matchea
    # como si fuera una tabla llamada "abc".
    src = 'const chars = Array.from("abc")\n'
    refs = gate.extract_refs(src)
    assert refs == []


def test_array_from_new_set_is_excluded():
    src = "const periods = Array.from(new Set(data.map(d => d.period)))\n"
    refs = gate.extract_refs(src)
    assert refs == []


# ── storage.from( — bucket de Supabase Storage, no una tabla ───────────────


def test_storage_from_with_string_literal_bucket_is_excluded():
    src = 'const { data } = supabase.storage.from("avatars").getPublicUrl(path)\n'
    refs = gate.extract_refs(src)
    assert refs == []


def test_storage_from_with_dynamic_bucket_is_excluded():
    src = (
        "const { error } = await supabase.storage\n"
        "  .from(BUCKET)\n"
        "  .remove([storagePath])\n"
    )
    refs = gate.extract_refs(src)
    assert refs == []


# ── .schema('x').from('y') — community schema ───────────────────────────────


def test_extracts_schema_qualified_from_same_line():
    src = "await supabase.schema('community').from('course_modules').select('*')\n"
    names = {r.name for r in gate.extract_refs(src)}
    assert "course_modules" in names


def test_extracts_schema_qualified_from_multiline():
    src = (
        "const { data, error } = await supabase\n"
        "  .schema('community')\n"
        "  .from('courses')\n"
        "  .select('*')\n"
    )
    names = {r.name for r in gate.extract_refs(src)}
    assert "courses" in names


# ── .rpc( — funciones ────────────────────────────────────────────────────


def test_extracts_rpc_call_as_function():
    src = 'const { data, error } = await supabase.rpc("rpc_invite_member", { p_email: email })\n'
    refs = gate.extract_refs(src)
    match = [r for r in refs if r.name == "rpc_invite_member"]
    assert match and match[0].kind == "function"


def test_extracts_rpc_call_without_rpc_prefix():
    # A diferencia del gate del backend (que solo dispara para el prefijo
    # `rpc_*` porque necesita distinguir de builtins de Postgres como
    # COUNT/COALESCE en texto SQL crudo), acá el método `.rpc(` de
    # supabase-js ya es un ancla inequívoca — no hace falta el prefijo.
    src = "const { data } = await supabase.rpc('get_admin_activation_rate', {})\n"
    refs = gate.extract_refs(src)
    match = [r for r in refs if r.name == "get_admin_activation_rate"]
    assert match and match[0].kind == "function"


# ── llamadas dinámicas — no resolubles estáticamente ────────────────────────


def test_dynamic_from_with_variable_is_skipped():
    src = 'const updateItem = async (table) => { await supabase.from(table).update(x).eq("id", id) }\n'
    refs = gate.extract_refs(src)
    assert refs == []


def test_dynamic_from_variable_is_counted_as_dynamic_call_site():
    src = 'const updateItem = async (table) => { await supabase.from(table).update(x) }\n'
    assert gate.count_dynamic_call_sites(src) == 1


def test_template_literal_with_interpolation_is_skipped():
    src = "await supabase.from(`table_${suffix}`).select('*')\n"
    refs = gate.extract_refs(src)
    assert refs == []


def test_template_literal_with_interpolation_is_counted_as_dynamic():
    src = "await supabase.from(`table_${suffix}`).select('*')\n"
    assert gate.count_dynamic_call_sites(src) == 1


def test_array_from_and_storage_from_do_not_inflate_dynamic_count():
    # Ni Array.from ni storage.from son llamadas reales a una tabla — no
    # deben contarse como "dinámicas no resueltas" en el reporting.
    src = (
        "const rows = Array.from({ length: 6 })\n"
        "const { data } = supabase.storage.from(BUCKET).getPublicUrl(x)\n"
    )
    assert gate.count_dynamic_call_sites(src) == 0


# ── comentarios — no deben generar falsos positivos ─────────────────────────


def test_ignores_from_call_inside_line_comment():
    src = (
        "// Receives a query builder that already has .from('tabla_fantasma').select() applied\n"
        "export type ApplyFilters = (query: any) => any\n"
    )
    refs = gate.extract_refs(src)
    assert refs == []


def test_ignores_from_call_inside_block_comment():
    src = (
        "/*\n"
        " * legacy: await supabase.from('tabla_fantasma').select('*')\n"
        " */\n"
        "const x = 1\n"
    )
    refs = gate.extract_refs(src)
    assert refs == []


def test_does_not_strip_url_containing_double_slash_inside_string():
    # Un string que contiene "//" (una URL) no debe tratarse como el inicio
    # de un comentario de línea — el resto de la línea, incluido un
    # `.from(...)` real más adelante, debe seguir siendo visible.
    src = (
        'const url = "https://example.com/api"\n'
        'const { data } = await supabase.from("sales").select("*")\n'
    )
    names = {r.name for r in gate.extract_refs(src)}
    assert "sales" in names


def test_real_from_call_survives_next_to_jsx_block_comment():
    src = (
        "function Widget() {\n"
        "  return (\n"
        "    <div>\n"
        "      {/* placeholder */}\n"
        "    </div>\n"
        "  )\n"
        "}\n"
        "async function load() {\n"
        "  return supabase.from('branches').select('*')\n"
        "}\n"
    )
    names = {r.name for r in gate.extract_refs(src)}
    assert "branches" in names


# ── normalize_relation_name ─────────────────────────────────────────────────


def test_normalize_relation_name_lowercases_and_strips_public():
    assert gate.normalize_relation_name("Sales") == "sales"
    assert gate.normalize_relation_name("public.Sales") == "sales"


# ── allowlist / existence check ─────────────────────────────────────────────


def test_is_known_true_for_table_in_existing_set():
    ref = gate.Ref(name="sales", lineno=1, kind="table")
    assert gate.is_known(ref, tables={"sales"}, functions=set())


def test_is_known_false_for_missing_table():
    ref = gate.Ref(name="tabla_fantasma", lineno=1, kind="table")
    assert not gate.is_known(ref, tables={"sales"}, functions=set())


def test_is_known_respects_allowlist(monkeypatch):
    monkeypatch.setattr(gate, "ALLOWLIST", frozenset({"legacy_ghost_table"}))
    ref = gate.Ref(name="legacy_ghost_table", lineno=1, kind="table")
    assert gate.is_known(ref, tables=set(), functions=set())


# ── fetch_existing_objects (psql call, mocked) ──────────────────────────────


def test_fetch_existing_objects_adds_bare_alias_for_every_schema():
    # A diferencia del gate del backend, acá el alias bare se agrega para
    # TODOS los schemas (no solo `public`) — ver docstring del módulo:
    # supabase-js separa `.schema('community')` del nombre en el literal de
    # `.from(...)`, que nunca viene calificado.
    fake_stdout = (
        "T\tpublic\tsales\n"
        "T\tcommunity\tcourse_modules\n"
        "F\tpublic\trpc_invite_member\n"
        "F\tcommunity\tsome_community_fn\n"
    )
    completed = MagicMock(stdout=fake_stdout, returncode=0)
    with patch("check_frontend_table_refs.subprocess.run", return_value=completed) as run:
        tables, functions = gate.fetch_existing_objects("postgresql://x/y")
    run.assert_called_once()
    assert "sales" in tables
    assert "public.sales" in tables
    assert "course_modules" in tables
    assert "community.course_modules" in tables
    assert "rpc_invite_member" in functions
    assert "some_community_fn" in functions
    assert "community.some_community_fn" in functions


def test_fetch_existing_objects_raises_on_psql_failure():
    with patch(
        "check_frontend_table_refs.subprocess.run",
        side_effect=subprocess.CalledProcessError(1, ["psql"], stderr="connection refused"),
    ):
        with pytest.raises(subprocess.CalledProcessError):
            gate.fetch_existing_objects("postgresql://x/y")


# ── is_test_file (path filter, unit tested standalone) ──────────────────────


def test_is_test_file_true_for_dunder_tests_dir():
    assert gate.is_test_file(Path("frontend/__tests__/billing.test.ts"))
    assert gate.is_test_file(Path("frontend/__tests__/components/Foo.test.tsx"))


def test_is_test_file_true_for_dot_test_suffix_outside_tests_dir():
    assert gate.is_test_file(Path("frontend/lib/foo.test.ts"))
    assert gate.is_test_file(Path("frontend/lib/foo.test.tsx"))


def test_is_test_file_false_for_regular_source_file():
    assert not gate.is_test_file(Path("frontend/lib/services/insuranceService.ts"))
    assert not gate.is_test_file(Path("frontend/app/(dashboard)/dashboard/page.tsx"))


# ── file discovery (excludes __tests__, node_modules, .next) ───────────────


def test_iter_frontend_files_excludes_dunder_tests_dir(tmp_path):
    (tmp_path / "lib").mkdir()
    (tmp_path / "__tests__").mkdir()
    (tmp_path / "lib" / "service.ts").write_text("export const x = 1\n")
    (tmp_path / "__tests__" / "service.test.ts").write_text("export const x = 1\n")
    files = gate.iter_frontend_files(tmp_path)
    names = {p.name for p in files}
    assert "service.ts" in names
    assert "service.test.ts" not in names


def test_iter_frontend_files_excludes_test_suffix_anywhere(tmp_path):
    (tmp_path / "lib").mkdir()
    (tmp_path / "lib" / "service.ts").write_text("export const x = 1\n")
    (tmp_path / "lib" / "service.test.tsx").write_text("export const x = 1\n")
    files = gate.iter_frontend_files(tmp_path)
    names = {p.name for p in files}
    assert "service.ts" in names
    assert "service.test.tsx" not in names


def test_iter_frontend_files_excludes_node_modules_and_next(tmp_path):
    (tmp_path / "node_modules" / "some-pkg").mkdir(parents=True)
    (tmp_path / ".next" / "server").mkdir(parents=True)
    (tmp_path / "lib").mkdir()
    (tmp_path / "node_modules" / "some-pkg" / "index.ts").write_text("export const x = 1\n")
    (tmp_path / ".next" / "server" / "chunk.ts").write_text("export const x = 1\n")
    (tmp_path / "lib" / "service.ts").write_text("export const x = 1\n")
    files = gate.iter_frontend_files(tmp_path)
    names = {p.name for p in files}
    assert names == {"service.ts"}


def test_iter_frontend_files_includes_both_ts_and_tsx(tmp_path):
    (tmp_path / "lib").mkdir()
    (tmp_path / "lib" / "service.ts").write_text("export const x = 1\n")
    (tmp_path / "lib" / "Widget.tsx").write_text("export const Widget = () => null\n")
    files = gate.iter_frontend_files(tmp_path)
    names = {p.name for p in files}
    assert names == {"service.ts", "Widget.tsx"}
