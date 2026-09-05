"""
Guard estático de regresión (H4 hotfix, 2026-09-04) — sqlstate 42P18.

Bug real de producción: `backend/services/subscriptions.py::_apply_approved_charge`
pasaba `amount` y `plan_expires_at` a un INSERT de `email_logs` DENTRO de
`jsonb_build_object(VARIADIC "any")` SIN cast explícito — el ÚNICO lugar de
toda la sentencia donde esos parámetros ($5/$6) aparecían. Postgres no puede
inferir el tipo de un parámetro que solo se usa en un contexto polimórfico
("any"): sqlstate 42P18 ("could not determine data type of parameter"),
reproducido contra la DB local de Supabase. `asyncpg_error_handler` no tiene
ese sqlstate mapeado, así que degradaba a un 500 genérico sin dejar rastro en
los logs (ver también el fix de logging en `backend/core/errors.py`).

Este gate escanea el texto crudo de `backend/services/` y
`backend/repositories/` buscando cada llamada a `jsonb_build_object(...)` y
verifica que TODO parámetro bind (`$N`) que aparezca dentro de sus paréntesis
esté inmediatamente casteado (`$N::tipo`). Un literal `$N` sin cast ahí
adentro es exactamente la forma del bug — no importa si hoy "funciona por
suerte" (otro uso del mismo parámetro en la sentencia podría fijarle el tipo
en otras query, pero DENTRO de jsonb_build_object nunca hay ese contexto).
"""
from __future__ import annotations

import pathlib
import re

BACKEND_ROOT = pathlib.Path(__file__).resolve().parent.parent
SCAN_DIRS = [BACKEND_ROOT / "services", BACKEND_ROOT / "repositories"]

_CALL_NAME_RE = re.compile(r"jsonb_build_object\s*\(", re.IGNORECASE)
_PARAM_RE = re.compile(r"\$(\d+)")
_CAST_AFTER_RE = re.compile(r"^::\s*[A-Za-z_][A-Za-z0-9_]*")


def _find_call_spans(text: str) -> list[tuple[int, int]]:
    """Devuelve (inicio, fin) del contenido ENTRE los paréntesis de cada
    llamada a jsonb_build_object(...) en `text`, respetando balanceo de
    paréntesis (para no cortar en el primer ')' de un caso anidado)."""
    spans: list[tuple[int, int]] = []
    for match in _CALL_NAME_RE.finditer(text):
        start = match.end()  # justo después del '(' de apertura
        depth = 1
        i = start
        while i < len(text) and depth > 0:
            if text[i] == "(":
                depth += 1
            elif text[i] == ")":
                depth -= 1
            i += 1
        end = i - 1  # posición del ')' de cierre
        spans.append((start, end))
    return spans


def find_uncast_params_in_jsonb_build_object(text: str) -> list[str]:
    """Devuelve una lista de mensajes describiendo cada `$N` encontrado
    DENTRO de un `jsonb_build_object(...)` que no está seguido inmediatamente
    de `::tipo`. Lista vacía == todo casteado == seguro."""
    violations: list[str] = []
    for start, end in _find_call_spans(text):
        span_text = text[start:end]
        for param_match in _PARAM_RE.finditer(span_text):
            after = span_text[param_match.end():]
            if not _CAST_AFTER_RE.match(after):
                # número de línea aproximado dentro del archivo completo
                line_no = text.count("\n", 0, start + param_match.start()) + 1
                violations.append(
                    f"line {line_no}: ${param_match.group(1)} sin cast explícito "
                    f"dentro de jsonb_build_object(...) — sqlstate 42P18 (could not "
                    f"determine data type of parameter)"
                )
    return violations


def _iter_source_files():
    for directory in SCAN_DIRS:
        yield from sorted(directory.rglob("*.py"))


# ── RED (guard real) ─────────────────────────────────────────────────────

def test_no_uncast_params_inside_jsonb_build_object_in_services_and_repositories():
    failures: dict[str, list[str]] = {}
    for path in _iter_source_files():
        text = path.read_text(encoding="utf-8")
        violations = find_uncast_params_in_jsonb_build_object(text)
        if violations:
            failures[str(path.relative_to(BACKEND_ROOT.parent))] = violations

    assert not failures, (
        "Parámetro(s) bind sin cast explícito dentro de jsonb_build_object(...) "
        "— Postgres no puede inferir su tipo en ese contexto polimórfico y "
        "revienta con sqlstate 42P18 en producción (caso real: "
        "_apply_approved_charge / subscriptions.id "
        "fa624f9b-32e5-4b5c-ad0d-fc64e6dc16b1). Agregá el cast (::numeric, "
        "::timestamptz, ::text, etc.) inmediatamente después de cada $N.\n"
        + "\n".join(f"{f}:\n  " + "\n  ".join(v) for f, v in failures.items())
    )


# ── TRIANGULATE (el detector realmente atrapa el bug, no es un tautología) ──

class TestDetectorCatchesTheRealBug:
    """Prueba el detector contra fixtures que reproducen exactamente la forma
    del bug real (antes del fix) y su forma corregida — para que este gate no
    sea un cheque vacío que siempre pasa."""

    def test_flags_the_exact_buggy_shape_from_apply_approved_charge(self):
        buggy_snippet = '''
        await conn.execute(
            """
            INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
            SELECT a.owner_user_id, 'subscription_payment_approved', u.email,
                   'Renovamos tu suscripción — ALIADATA',
                   jsonb_build_object(
                       'preapproval_id', $2::text, 'authorized_payment_id', $3::text,
                       'plan', $4::text, 'amount', $5, 'plan_expires_at', $6
                   )
            FROM public.accounts a
            JOIN auth.users u ON u.id = a.owner_user_id
            WHERE a.id = $1
            ON CONFLICT DO NOTHING
            """,
        )
        '''
        violations = find_uncast_params_in_jsonb_build_object(buggy_snippet)
        assert len(violations) == 2
        assert any("$5" in v for v in violations)
        assert any("$6" in v for v in violations)

    def test_does_not_flag_the_fixed_shape(self):
        fixed_snippet = '''
        jsonb_build_object(
            'preapproval_id', $2::text, 'authorized_payment_id', $3::text,
            'plan', $4::text, 'amount', $5::numeric, 'plan_expires_at', $6::timestamptz
        )
        '''
        assert find_uncast_params_in_jsonb_build_object(fixed_snippet) == []

    def test_catches_real_pre_fix_subscriptions_service_from_git_main(self):
        """Regresión directa: el archivo tal como estaba en `main` ANTES de
        este hotfix (H4) tenía 4 ocurrencias sin cast — $5/$6 en
        `_apply_approved_charge` (el bug raíz, 42P18 reproducido) y `$3`
        (plan_expires_at) en `cancel_subscription` (x2, sin ejercitar
        todavía en prod) y en la rama de cancelación de
        `process_subscription_preapproval_notification` — deuda latente que
        este mismo hotfix corrigió de paso. Si este test empieza a fallar
        porque `git show main:...` ya no existe o cambió de forma, no lo
        borres sin revisar primero si `main` avanzó (rebase) — el punto es
        documentar que el detector atrapaba el bug REAL, no uno inventado."""
        import subprocess

        try:
            result = subprocess.run(
                ["git", "show", "main:backend/services/subscriptions.py"],
                cwd=BACKEND_ROOT.parent,
                capture_output=True,
                timeout=10,
            )
        except (OSError, subprocess.SubprocessError):
            import pytest
            pytest.skip("git no disponible en este entorno")

        if result.returncode != 0:
            import pytest
            pytest.skip("no se pudo leer backend/services/subscriptions.py desde 'main' (rama ausente en este checkout)")

        # decode explícito UTF-8: el archivo tiene em-dashes/acentos y el
        # codec por default de Windows (cp1252) revienta con ellos.
        pre_fix_text = result.stdout.decode("utf-8")
        violations = find_uncast_params_in_jsonb_build_object(pre_fix_text)
        # Si `main` ya tiene este hotfix mergeado (branch vieja quedó atrás),
        # este test degrada a skip en vez de falso-fallar — el punto es
        # documentar el hallazgo, no bloquear un checkout ya arreglado.
        if not violations:
            import pytest
            pytest.skip("'main' ya no contiene la forma pre-fix (¿este hotfix ya se mergeó?)")
        assert len(violations) >= 4
