"""v31-money-integration-tests (task 3.2) — los hooks fail-closed de `integration_guard.py`.

Hermético: cada caso corre una sesión de pytest aislada con `pytester` (`-p backend.tests.integration_guard`)
sobre tests sintéticos; no abre sockets (el preflight se reemplaza o se prueba con un `asyncpg.connect`
falso). Fija el contrato del requirement «En CI un test de integración no puede saltearse en silencio» y
su control negativo: un skip pasa a `failed` sólo con `CI_REQUIRE_INTEGRATION=1`, un test que falla sigue
fallando, y los `arca` quedan exentos.
"""
from __future__ import annotations

import pytest

from backend.tests import integration_db, integration_guard

pytest_plugins = ["pytester"]

INI = """
[pytest]
markers =
    integration: tests de integración
    arca: requiere ARCA real
"""

BASE_ARGS = ("-p", "backend.tests.integration_guard", "-p", "no:cacheprovider")


@pytest.fixture
def ci_env(monkeypatch: pytest.MonkeyPatch):
    """`CI_REQUIRE_INTEGRATION=1` con el preflight neutralizado (probado aparte, abajo)."""
    monkeypatch.setenv("CI_REQUIRE_INTEGRATION", "1")
    monkeypatch.setattr(integration_guard, "preflight", lambda: None)


def _run(pytester: pytest.Pytester, source: str, *extra: str) -> pytest.RunResult:
    pytester.makeini(INI)
    pytester.makepyfile(source)
    return pytester.runpytest_inprocess(*BASE_ARGS, *extra)


# ── (a) el skip de un test de integración pasa a failed con el motivo original ───────────────────


def test_a_skipped_integration_test_becomes_failed_in_ci(pytester: pytest.Pytester, ci_env):
    result = _run(
        pytester,
        """
        import pytest

        @pytest.mark.integration
        def test_needs_db():
            pytest.skip("Postgres local no disponible (simulado)")
        """,
    )
    result.assert_outcomes(failed=1)
    assert result.ret != 0
    result.stdout.fnmatch_lines(["*CI_REQUIRE_INTEGRATION=1*Motivo original: Postgres local no disponible (simulado)*"])


def test_without_the_variable_the_same_skip_stays_skipped(pytester: pytest.Pytester, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.delenv("CI_REQUIRE_INTEGRATION", raising=False)
    result = _run(
        pytester,
        """
        import pytest

        @pytest.mark.integration
        def test_needs_db():
            pytest.skip("Postgres local no disponible (simulado)")
        """,
    )
    result.assert_outcomes(skipped=1)
    assert result.ret == 0


def test_the_variable_only_counts_when_it_is_exactly_one(pytester: pytest.Pytester, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("CI_REQUIRE_INTEGRATION", "0")
    result = _run(
        pytester,
        """
        import pytest

        @pytest.mark.integration
        def test_needs_db():
            pytest.skip("sin base")
        """,
    )
    result.assert_outcomes(skipped=1)


# ── (b) los `arca` quedan exentos ────────────────────────────────────────────────────────────────


def test_an_arca_test_stays_skipped_in_ci(pytester: pytest.Pytester, ci_env):
    result = _run(
        pytester,
        """
        import pytest

        @pytest.mark.integration
        @pytest.mark.arca
        def test_needs_arca():
            pytest.skip("requiere credenciales de ARCA")

        @pytest.mark.integration
        def test_runs():
            assert True
        """,
    )
    result.assert_outcomes(passed=1, skipped=1)
    assert result.ret == 0


# ── (c) el skip desde un fixture también cuenta; las otras fases y resultados no se tocan ────────


def test_a_skip_raised_from_a_fixture_is_also_a_failure(pytester: pytest.Pytester, ci_env):
    result = _run(
        pytester,
        """
        import pytest

        @pytest.fixture
        def conn():
            pytest.skip("Postgres local no disponible (fixture)")

        @pytest.mark.integration
        def test_uses_fixture(conn):
            assert conn
        """,
    )
    result.assert_outcomes(errors=1)  # una falla en la fase setup se informa como error
    assert result.ret != 0
    result.stdout.fnmatch_lines(["*Postgres local no disponible (fixture)*"])


def test_a_failing_integration_test_stays_failed_and_a_passing_one_passes(pytester: pytest.Pytester, ci_env):
    result = _run(
        pytester,
        """
        import pytest

        @pytest.mark.integration
        def test_fails():
            assert 1 == 2

        @pytest.mark.integration
        def test_passes():
            assert 1 == 1
        """,
    )
    result.assert_outcomes(passed=1, failed=1)


def test_an_unmarked_skip_is_not_touched(pytester: pytest.Pytester, ci_env):
    result = _run(
        pytester,
        """
        import pytest

        @pytest.mark.integration
        def test_present():
            assert True

        def test_hermetic_skip():
            pytest.skip("no es de integración")
        """,
    )
    result.assert_outcomes(passed=1, skipped=1)
    assert result.ret == 0


def test_an_xfail_is_not_rewritten(pytester: pytest.Pytester, ci_env):
    result = _run(
        pytester,
        """
        import pytest

        @pytest.mark.integration
        @pytest.mark.xfail(reason="conocido", strict=False)
        def test_known():
            assert False

        @pytest.mark.integration
        def test_present():
            assert True
        """,
    )
    result.assert_outcomes(passed=1, xfailed=1)
    assert result.ret == 0


# ── (d) una selección sin tests de integración sale distinta de cero ─────────────────────────────


def test_a_selection_without_integration_tests_exits_nonzero(pytester: pytest.Pytester, ci_env):
    result = _run(
        pytester,
        """
        def test_hermetic():
            assert True
        """,
        "-m",
        "integration",
    )
    assert result.ret == 1
    result.stdout.fnmatch_lines(["*la selección no contiene ningún test marcado `integration`*"])


def test_a_selection_with_integration_tests_is_not_aborted(pytester: pytest.Pytester, ci_env):
    result = _run(
        pytester,
        """
        import pytest

        @pytest.mark.integration
        def test_present():
            assert True
        """,
        "-m",
        "integration and not arca",
    )
    result.assert_outcomes(passed=1)
    assert result.ret == 0


def test_an_empty_selection_without_the_variable_is_not_this_hooks_business(
    pytester: pytest.Pytester, monkeypatch: pytest.MonkeyPatch
):
    monkeypatch.delenv("CI_REQUIRE_INTEGRATION", raising=False)
    result = _run(
        pytester,
        """
        def test_hermetic():
            assert True
        """,
        "-m",
        "integration",
    )
    assert result.ret == 5  # el «no se recolectó nada» estándar de pytest


# ── (e) el preflight: DSN remoto o inalcanzable aborta antes de ejecutar nada ────────────────────


def test_a_remote_dsn_aborts_in_the_preflight(pytester: pytest.Pytester, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("CI_REQUIRE_INTEGRATION", "1")
    monkeypatch.setattr(integration_db, "DSN", "postgresql://postgres:s3cr3t@db.example.com:5432/postgres")
    result = _run(
        pytester,
        """
        import pytest

        @pytest.mark.integration
        def test_present():
            assert True
        """,
    )
    assert result.ret == 1
    out = result.stdout.str()
    assert "preflight" in out and "db.example.com" in out
    assert "s3cr3t" not in out
    assert "passed" not in out  # no se ejecutó ningún test


def test_an_unreachable_database_aborts_with_dsn_and_cause(pytester: pytest.Pytester, monkeypatch: pytest.MonkeyPatch):
    async def _refused(*_a, **_k):
        raise ConnectionRefusedError("conexión rechazada (simulada)")

    monkeypatch.setenv("CI_REQUIRE_INTEGRATION", "1")
    monkeypatch.setattr(integration_db, "DSN", "postgresql://postgres:s3cr3t@127.0.0.1:54322/postgres")
    monkeypatch.setattr(integration_guard.asyncpg, "connect", _refused)
    result = _run(
        pytester,
        """
        import pytest

        @pytest.mark.integration
        def test_present():
            assert True
        """,
    )
    assert result.ret == 1
    out = result.stdout.str()
    assert "127.0.0.1:54322" in out and "ConnectionRefusedError" in out
    assert "s3cr3t" not in out
    assert "passed" not in out


def test_a_reachable_local_database_lets_the_session_run(pytester: pytest.Pytester, monkeypatch: pytest.MonkeyPatch):
    closed: list[bool] = []

    class _Conn:
        async def close(self):
            closed.append(True)

    async def _ok(*_a, **_k):
        return _Conn()

    monkeypatch.setenv("CI_REQUIRE_INTEGRATION", "1")
    monkeypatch.setattr(integration_db, "DSN", "postgresql://postgres:postgres@127.0.0.1:54322/postgres")
    monkeypatch.setattr(integration_guard.asyncpg, "connect", _ok)
    result = _run(
        pytester,
        """
        import pytest

        @pytest.mark.integration
        def test_present():
            assert True
        """,
    )
    result.assert_outcomes(passed=1)
    assert closed == [True]  # abre y cierra la conexión del preflight


def test_the_preflight_does_nothing_without_the_variable(pytester: pytest.Pytester, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.delenv("CI_REQUIRE_INTEGRATION", raising=False)
    monkeypatch.setattr(integration_db, "DSN", "postgresql://postgres:x@db.example.com:5432/postgres")
    result = _run(
        pytester,
        """
        import pytest

        @pytest.mark.integration
        def test_present():
            assert True
        """,
    )
    result.assert_outcomes(passed=1)
    assert result.ret == 0
