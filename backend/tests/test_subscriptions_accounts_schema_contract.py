"""
HOTFIX subscription-webhook-idempotency-contract (2026-09-04, dinero real).

Bug secundario descubierto durante el diagnóstico del incidente de
tubecoventas6@gmail.com: public.accounts NO tiene columna `updated_at`
(verificado en prod vía Supabase MCP — columnas reales: id, billing_plan,
billing_status, trial_plan, trial_started_at, trial_expires_at,
owner_user_id, created_at, plan_expires_at, billing_exempt,
billing_exempt_reason, billing_exempt_granted_at, billing_exempt_granted_by,
default_payment_terms_days). backend/services/subscriptions.py tenía 5
`UPDATE public.accounts ... SET ..., updated_at = now()` que habrían
explotado con asyncpg.exceptions.UndefinedColumnError (42703 → 500 vía
asyncpg_error_handler) apenas el 422 de idempotencia (bug primario, cerrado
por la migración 20261027000001) se destrabara. Como get_service_conn NO
abre una transacción explícita alrededor de estos handlers, un 42703 a
mitad de la función deja escrituras parciales (p.ej. la fila de
`subscriptions` ya creada, la cuenta sin activar).

Este test es la red de seguridad ESTÁTICA: escanea el código fuente del
módulo por cada `UPDATE public.accounts` y assertea que ninguno mencione
`updated_at`. RED confirmado manualmente contra el código pre-fix (los 5
bloques literales SET ..., updated_at = now()); GREEN con el fix (columna
retirada, comentario "H1 hotfix" agregado). Nota: `public.subscriptions`
(otra tabla, en subscriptions_repository.py) SÍ tiene `updated_at` — ese uso
es correcto y no debe tocarse; por eso el scan se limita a
`UPDATE public.accounts`, no a `updated_at` en general.
"""
from __future__ import annotations

import inspect
import re

from backend.services import subscriptions as subscriptions_module

# Captura desde "UPDATE public.accounts" hasta el cierre de la triple-comilla
# que abre cada sentencia SQL embebida (todas están escritas como
# `""" ... """,` seguidas por los parámetros posicionales).
_ACCOUNTS_UPDATE_RE = re.compile(r"UPDATE public\.accounts\b.*?(?=\"\"\")", re.DOTALL)


def _accounts_update_statements() -> list[str]:
    source = inspect.getsource(subscriptions_module)
    return _ACCOUNTS_UPDATE_RE.findall(source)


class TestAccountsUpdatedAtContract:
    def test_module_contains_the_five_known_accounts_updates(self):
        """Ancla de no-regresión: si alguien agrega o quita un UPDATE sobre
        accounts, este número cambia a propósito — no en silencio. Los 5
        sitios conocidos: cancel_subscription, resolve_ambiguous_subscription,
        process_subscription_preapproval_notification (match automático +
        cancelación reportada por MP) y
        process_subscription_authorized_payment_notification (cobro
        aprobado)."""
        statements = _accounts_update_statements()
        assert len(statements) == 5, (
            f"se esperaban 5 sentencias UPDATE public.accounts en "
            f"subscriptions.py, se encontraron {len(statements)} — revisar "
            f"si el cambio es intencional (y si agrega otro sitio que "
            f"también deba respetar este contrato)"
        )

    def test_no_update_on_accounts_references_updated_at(self):
        """GREEN (H1 hotfix): ningún UPDATE public.accounts de este módulo
        menciona updated_at — la columna no existe en la tabla real."""
        statements = _accounts_update_statements()
        offending = [s for s in statements if "updated_at" in s]
        assert not offending, (
            "UPDATE public.accounts referencia updated_at, columna "
            "inexistente en prod (42703 → 500): "
            + " | ".join(offending)
        )

    def test_subscriptions_table_updates_still_use_updated_at(self):
        """Control negativo: el scan no debe volverse tan amplio que borre
        el updated_at legítimo de OTRA tabla. public.subscriptions (en
        subscriptions_repository.py, no en este módulo) sí tiene esa
        columna — confirmamos que este test no lo tocó ni lo tocaría si
        viviera acá."""
        from backend.repositories import subscriptions_repository

        repo_source = inspect.getsource(subscriptions_repository)
        subscriptions_updates = re.findall(
            r"UPDATE public\.subscriptions\b.*?(?=\"\"\")", repo_source, re.DOTALL
        )
        assert subscriptions_updates, "esperaba encontrar UPDATEs sobre public.subscriptions"
        assert any("updated_at" in s for s in subscriptions_updates), (
            "public.subscriptions SÍ tiene updated_at (ver migración "
            "20260829000001) — este control negativo debe seguir viendo "
            "esa columna ahí"
        )
