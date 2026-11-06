"""v31-money-integration-tests (task 4.1) — el detector de degradaciones de `scripts/ci/run_gate_strict.py`.

Hermético: no necesita psql ni red (el wrapper se prueba con un «psql» falso). Fija:

* que el detector reconoce CADA rama de degradación de los 36 gates de dinero (la regla con la que se midieron
  las 202 ramas del `design.md`) y ninguna línea `PASS`/`PASSED`/`degrade-don't-fail`;
* que el ruido que no escribe el gate (triggers del producto, `DROP … IF EXISTS`, migraciones incluidas) no cuenta;
* la allow-list (archivo + subcadena, motivo obligatorio);
* el cableado de `KPI_Validation.yml`: las 36 invocaciones pasan por el wrapper y ninguna sigue con `psql` directo.

Si este test falla porque apareció un `RAISE NOTICE` de degradación nuevo que el detector no reconoce, la
degradación se escribió con una redacción que el wrapper no vería: empezala con `GATE` y que contenga
`DEGRADED` o `degradado`.
"""
from __future__ import annotations

import importlib.util
import re
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
MODULE_PATH = REPO / "scripts" / "ci" / "run_gate_strict.py"

# Los 36 gates de dinero (los 33 de design.md §«Hechos medidos» + test_document_lines_consistency, H-15, + test_mp_cuota_reconciliacion_cron,
# mp-cuota-acreditacion-resiliente, + test_productos_padre_variantes, productos-padre-variantes), en orden alfabético.
MONEY_GATES = [
    "test_asiento_contable_gastos", "test_asiento_venta_formulario", "test_banco_caja_historial_ajustes",
    "test_bank_default_destination", "test_c30_party_movement_helpers_acl", "test_cash_movement_types",
    "test_charge_due_date", "test_cobranzas_reverso", "test_cobranzas_vencimientos_schema",
    "test_compras_gastos_sucursal_por_defecto", "test_compras_proveedor_cuenta_corriente",
    "test_cuenta_corriente_party_guard", "test_cuentas_billetera_tipo", "test_delete_guard_ledgers",
    "test_document_lines_consistency", "test_expense_import_batch", "test_gastos_forma_pago",
    "test_mp_cuota_reconciliacion_cron", "test_operacion_party_guard",
    "test_pagos_cableados_restantes", "test_party_payment_cash", "test_payment_method_operations",
    "test_payment_method_report", "test_payment_methods_catalog", "test_payment_methods_seed",
    "test_pos_banco_movimientos", "test_pos_confirm_payment_method", "test_pos_payment_vocabulary",
    "test_productos_padre_variantes",
    "test_purchase_cash_optin", "test_purchase_delete_cash_compensation", "test_receipts_subscription_charges",
    "test_receivables_aging_fifo", "test_receivables_overdue_digest", "test_receivables_report",
    "test_tenancy_guard_caja_outbox",
]


def _load():
    spec = importlib.util.spec_from_file_location("run_gate_strict", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules["run_gate_strict"] = module  # los @dataclass necesitan el módulo registrado
    spec.loader.exec_module(module)
    return module


rgs = _load()

# La regla de MEDICIÓN del design: un RAISE NOTICE cuyo mensaje no empieza en PASS/OK y contiene alguna marca.
_RAISE_NOTICE = re.compile(r"RAISE\s+NOTICE\s+'((?:[^']|'')*)'", re.S)
_MEASURE_MARKS = re.compile(r"SKIP|DEGRAD|degradando|degradado|se omite|omitido|sin abortar")


def _read_gate(name: str) -> str:
    return (REPO / "supabase" / "tests" / f"{name}.sql").read_text(encoding="utf-8").replace("\r\n", "\n")


def _measured_branches(name: str) -> list[str]:
    out = []
    for raw in _RAISE_NOTICE.findall(_read_gate(name)):
        msg = raw.replace("''", "'").strip()
        if not msg.startswith(("PASS", "OK")) and _MEASURE_MARKS.search(msg):
            out.append(msg)
    return out


# ── (a) el detector reconoce todas las ramas de degradación de los 36 gates ──────────────────────


@pytest.mark.parametrize("gate", MONEY_GATES)
def test_every_degradation_branch_of_the_money_gates_is_detected(gate: str):
    unrecognised = [m for m in _measured_branches(gate) if not rgs.is_degradation(m)]
    assert unrecognised == [], f"{gate}: ramas de degradación que el detector no ve: {unrecognised}"


def test_the_corpus_is_the_one_the_design_measured():
    branches = [m for g in MONEY_GATES for m in _measured_branches(g)]
    # 202 ramas medidas el 2026-11-05; D7 retiró una (el «no hay cuentas en el stack» de test_payment_methods_seed),
    # así que hoy son 201. Sólo pueden crecer: si baja de ahí, el extractor dejó de ver gates.
    assert len(branches) >= 201
    assert sum(1 for m in branches if m.startswith("DEGRADE")) >= 2
    assert sum(1 for m in branches if m.startswith(("GATE", "SKIP"))) >= 199


def test_the_thirty_six_money_gates_exist():
    assert len(MONEY_GATES) == 36 and len(set(MONEY_GATES)) == 36
    for gate in MONEY_GATES:
        assert (REPO / "supabase" / "tests" / f"{gate}.sql").is_file(), gate


# ── (b) lo que NO es una degradación ─────────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    "message",
    [
        "PASS (1): las 6 cuentas existentes tienen las 7 formas de pago sembradas.",
        "PASSED: test_receipts_subscription_charges — ninguno degradado.",
        "GATE CASH-MOVEMENT-TYPES PASSED (degrade-don't-fail: ninguno degradado en este entorno)",
        "GATE X PASSED con degrade-don't-fail aplicado",
        "GATE X PASSED: 3 bloques, SKIP de entorno no aplica",
        "OK (3): omitido el paso opcional",
        "send_email_log_webhook: Vault secrets not configured — skipping HTTP call for email_logs.id=1",
        "relation \"foo\" does not exist, skipping",
        "FASE 0b: cuerpo vivo de rpc_create_bank_account capturado (md5=abc).",
        "GATE X (2) degradado a solo lectura se conserva",  # `degradado a` no es una degradación de gate
        "",
    ],
)
def test_non_degradation_messages_are_not_flagged(message: str):
    assert rgs.is_degradation(message) is False


@pytest.mark.parametrize(
    "message",
    [
        "GATE POS-BANCO-MOVIMIENTOS: branch/catálogo no disponible para el anchor — degradando sin abortar.",
        "GATE PAYMENT-METHODS-SEED (1) degradado: no hay cuentas en el stack — nada que verificar.",
        "SKIP: sin cuenta ancla",
        "DEGRADE (2): auth.uid() no resuelve al anchor",
        "GATE X: se omiten los asserts que invocan las RPCs.",
        "GATE X DEGRADED: sin caja",
    ],
)
def test_degradation_messages_are_flagged(message: str):
    assert rgs.is_degradation(message) is True


# ── (c) qué líneas de psql cuentan ───────────────────────────────────────────────────────────────

GATE = "supabase/tests/test_x.sql"
OWN = "psql:supabase/tests/test_x.sql:46: NOTICE:  GATE X (1) degradado: no hay cuentas — nada que verificar."


def test_parse_notice_extracts_file_line_and_message():
    assert rgs.parse_notice(OWN + "\r\n") == (
        "supabase/tests/test_x.sql", 46, "GATE X (1) degradado: no hay cuentas — nada que verificar.",
    )
    assert rgs.parse_notice("NOTICE:  sin prefijo de archivo") is None
    assert rgs.parse_notice("psql:a.sql:3: ERROR:  boom") is None


def test_only_notices_written_by_the_gate_itself_count():
    lines = [
        OWN,
        "psql:supabase/tests/test_x.sql:50: NOTICE:  send_email_log_webhook: Vault secrets not configured — skipping HTTP call",
        'psql:supabase/tests/test_x.sql:51: NOTICE:  relation "t" does not exist, skipping',
        "psql:supabase/tests/test_x.sql:60: NOTICE:  PASS (1): ok",
        # NOTICE de una migración incluida con \\i: el prefijo es el de ese archivo, no el del gate.
        "psql:supabase/migrations/2026_x.sql:9: NOTICE:  GATE migración degradando sin abortar",
        # Otro gate (otro archivo) no cuenta para éste.
        "psql:supabase/tests/test_y.sql:3: NOTICE:  GATE Y degradado: nada",
    ]
    found = rgs.find_degradations(lines, GATE)
    assert [(d.line, d.message) for d in found] == [(46, "GATE X (1) degradado: no hay cuentas — nada que verificar.")]


def test_find_degradations_reports_every_branch_not_just_the_first():
    lines = [
        "psql:supabase/tests/test_x.sql:10: NOTICE:  GATE X (1) degradado: a",
        "psql:supabase/tests/test_x.sql:20: NOTICE:  SKIP (2): b",
        "psql:supabase/tests/test_x.sql:30: NOTICE:  DEGRADE (3): c",
    ]
    assert [d.line for d in rgs.find_degradations(lines, GATE)] == [10, 20, 30]


def test_windows_style_gate_paths_match_by_basename():
    lines = ["psql:supabase\\tests\\test_x.sql:5: NOTICE:  GATE X degradado: a"]
    assert len(rgs.find_degradations(lines, "supabase/tests/test_x.sql")) == 1


# ── (d) la allow-list ────────────────────────────────────────────────────────────────────────────


def test_allowlist_matches_by_file_and_substring(tmp_path: Path):
    allow = tmp_path / "allow.txt"
    allow.write_text(
        "# comentario\n\ntest_x.sql|el entorno no otorga GRANT base|GRANT ausente en el stack\n", encoding="utf-8"
    )
    entries = rgs.load_allowlist(allow)
    assert len(entries) == 1 and entries[0].reason == "GRANT ausente en el stack"

    permitted = rgs.Degradation("supabase/tests/test_x.sql", 3, "GATE X (6) degradado: el entorno no otorga GRANT base de authenticated")
    other_text = rgs.Degradation("supabase/tests/test_x.sql", 4, "GATE X (1) degradado: no hay cuentas")
    other_file = rgs.Degradation("supabase/tests/test_y.sql", 3, "GATE Y: el entorno no otorga GRANT base")
    assert rgs.match_allowlist(permitted, entries) is entries[0]
    assert rgs.match_allowlist(other_text, entries) is None
    assert rgs.match_allowlist(other_file, entries) is None


@pytest.mark.parametrize("bad", ["test_x.sql|solo dos campos", "test_x.sql||sin subcadena", "test_x.sql|texto|", "sin separadores"])
def test_allowlist_rejects_entries_without_a_reason(tmp_path: Path, bad: str):
    allow = tmp_path / "allow.txt"
    allow.write_text(bad + "\n", encoding="utf-8")
    with pytest.raises(ValueError):
        rgs.load_allowlist(allow)


def test_the_shipped_allowlist_has_the_single_environment_entry():
    entries = rgs.load_allowlist(rgs.DEFAULT_ALLOWLIST)
    assert [(e.file, e.substring) for e in entries] == [("test_payment_methods_catalog.sql", "el entorno no otorga GRANT base")]
    assert "entorno" in entries[0].reason or "GRANT" in entries[0].reason
    # La entrada tiene que seguir apuntando a un mensaje que el gate realmente emite.
    assert any(entries[0].substring in m for m in _measured_branches("test_payment_methods_catalog"))
    # Y ese mensaje es una degradación reconocida (sino la allow-list no serviría de nada).
    assert any(rgs.is_degradation(m) for m in _measured_branches("test_payment_methods_catalog") if entries[0].substring in m)


# ── (e) el wrapper de punta a punta, con un «psql» falso que devuelve salida enlatada ─────────────


FAKE_PSQL = """
import os, sys
args = sys.argv[1:]
path = args[args.index("-f") + 1]
sys.stdout.write(open(path, encoding="utf-8").read())
sys.exit(int(os.environ.get("FAKE_PSQL_RC", "0")))
"""


@pytest.fixture
def fake_psql(tmp_path: Path):
    script = tmp_path / "fake_psql.py"
    script.write_text(FAKE_PSQL, encoding="utf-8")
    return f'"{sys.executable}" "{script}"'


def _run(tmp_path: Path, fake_psql: str, output: str, monkeypatch: pytest.MonkeyPatch, rc: int = 0, allow: str | None = None):
    gate = tmp_path / "test_x.sql"
    gate.write_text(output.replace("{gate}", "supabase/tests/test_x.sql"), encoding="utf-8")
    allowlist = tmp_path / "allow.txt"
    allowlist.write_text(allow or "# vacía\n", encoding="utf-8")
    monkeypatch.setenv("FAKE_PSQL_RC", str(rc))
    return rgs.main([str(gate), "--dsn", "", "--psql", fake_psql, "--allowlist", str(allowlist)])


def test_a_clean_gate_passes(tmp_path, fake_psql, monkeypatch, capsys):
    out = "psql:{gate}:5: NOTICE:  PASS (1): ok\npsql:{gate}:9: NOTICE:  send_email_log_webhook: Vault secrets not configured — skipping HTTP call\n"
    assert _run(tmp_path, fake_psql, out, monkeypatch) == 0
    assert "PASS (1): ok" in capsys.readouterr().out  # la salida se reenvía tal cual


def test_a_degraded_gate_fails_and_lists_every_branch(tmp_path, fake_psql, monkeypatch, capsys):
    out = (
        "psql:{gate}:5: NOTICE:  GATE X (1) degradado: no hay cuentas\n"
        "psql:{gate}:6: NOTICE:  PASS (2): ok\n"
        "psql:{gate}:7: NOTICE:  GATE X: no se pudo resolver cuenta — degradando sin abortar.\n"
    )
    assert _run(tmp_path, fake_psql, out, monkeypatch) == 1
    err = capsys.readouterr().err
    assert "2 degradación(es) NO permitida(s)" in err
    assert ":5: GATE X (1) degradado: no hay cuentas" in err and ":7: GATE X: no se pudo resolver cuenta" in err


def test_an_allowlisted_degradation_passes_and_is_reported(tmp_path, fake_psql, monkeypatch, capsys):
    out = "psql:{gate}:5: NOTICE:  GATE X (6) degradado: el entorno no otorga GRANT base de authenticated\n"
    allow = "test_x.sql|el entorno no otorga GRANT base|el stack no replica el GRANT\n"
    assert _run(tmp_path, fake_psql, out, monkeypatch, allow=allow) == 0
    assert "degradación PERMITIDA" in capsys.readouterr().out


def test_the_psql_exit_code_is_preserved(tmp_path, fake_psql, monkeypatch):
    assert _run(tmp_path, fake_psql, "psql:{gate}:5: ERROR:  boom\n", monkeypatch, rc=3) == 3


def test_a_failing_gate_that_also_degraded_keeps_the_psql_code(tmp_path, fake_psql, monkeypatch):
    out = "psql:{gate}:5: NOTICE:  GATE X (1) degradado: a\npsql:{gate}:6: ERROR:  boom\n"
    assert _run(tmp_path, fake_psql, out, monkeypatch, rc=3) == 3


def test_a_broken_allowlist_is_a_loud_error(tmp_path, fake_psql, monkeypatch):
    assert _run(tmp_path, fake_psql, "psql:{gate}:5: NOTICE:  PASS (1)\n", monkeypatch, allow="sin|motivo\n") == 2


# ── (f) el cableado de KPI_Validation.yml ────────────────────────────────────────────────────────

WORKFLOW = (REPO / ".github" / "workflows" / "KPI_Validation.yml").read_text(encoding="utf-8").replace("\r\n", "\n")


def test_exactly_the_thirty_six_money_gates_run_through_the_wrapper():
    wrapped = re.findall(r"run: python3 scripts/ci/run_gate_strict\.py supabase/tests/(\w+)\.sql\s*$", WORKFLOW, re.M)
    assert sorted(wrapped) == sorted(MONEY_GATES)
    assert len(wrapped) == 36


@pytest.mark.parametrize("gate", MONEY_GATES)
def test_no_money_gate_is_still_invoked_with_plain_psql(gate: str):
    direct = re.findall(rf"psql [^\n]*supabase/tests/{gate}\.sql", WORKFLOW)
    assert direct == [], f"{gate} sigue con psql directo en KPI_Validation.yml"
