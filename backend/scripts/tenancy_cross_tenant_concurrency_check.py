"""v31-tenancy-pool-rls — prueba de concurrencia cross-tenant.

Condición 2 de "Probado bajo carga" (design.md) y tasks.md 5.2 / 8.4:

    Un script con asyncio + httpx (ya en el proyecto) que dispara al menos
    50 requests concurrentes intercalando DOS usuarios de cuentas
    distintas contra endpoints de lectura, y afirma que NINGUNA respuesta
    contiene datos de la otra cuenta y que NINGUNA falla por claims
    ausentes. Se ejecuta contra el entorno desplegado, no contra mocks.

Este script queda guardado en el repo para reutilizarse sin cambios en el
grupo 8 (corte del Paso 2, tasks.md 8.4) — la única diferencia entre las dos
corridas es si la RLS está realmente evaluándose (Paso 2 activo) o si el
aislamiento depende sólo de que cada query filtre por cuenta (Paso 1).

NO se ejecuta como parte de la suite pytest (no hay entorno desplegado ni
cuentas reales en CI) — se corre a mano contra el backend real, con dos
usuarios de dos cuentas distintas ya existentes.

Uso:

    TENANCY_CHECK_BASE_URL=https://<backend-real>.onrender.com \
    TENANCY_CHECK_TOKEN_A=<jwt de un usuario de la cuenta A> \
    TENANCY_CHECK_TOKEN_B=<jwt de un usuario de la cuenta B> \
    TENANCY_CHECK_MARKER_A=<substring que SOLO debe aparecer en respuestas de A> \
    TENANCY_CHECK_MARKER_B=<substring que SOLO debe aparecer en respuestas de B> \
    python -m backend.scripts.tenancy_cross_tenant_concurrency_check

Los "markers" son, por ejemplo, el nombre de un producto o cliente que sólo
existe en esa cuenta — si aparece en una respuesta autenticada como la OTRA
cuenta, es una fuga cross-tenant real, no un falso positivo. El endpoint por
defecto es `GET /products` (account-scoped, sin efectos secundarios);
puede cambiarse con TENANCY_CHECK_PATH.

Exit code 0 = todo OK. Exit code != 0 = fuga cross-tenant o claims ausentes
detectados (ver stdout para el detalle) — no ejecutar el Paso 2 (o, si ya
está activo, apagar la palanca) hasta entender la causa.
"""
from __future__ import annotations

import asyncio
import os
import sys
from dataclasses import dataclass, field

import httpx

DEFAULT_REQUEST_COUNT = 60  # >= 50 exigido por la condición 2
DEFAULT_PATH = "/products"
CLAIMS_MISSING_STATUS = 403  # "No active account found" — get_account_id


@dataclass
class CheckResult:
    total: int = 0
    ok: int = 0
    claims_missing: int = 0  # 403 anómalo — el síntoma de claims ausentes
    other_errors: list[tuple[int, int]] = field(default_factory=list)  # (idx, status)
    leaks: list[tuple[int, str, str]] = field(default_factory=list)  # (idx, caller, leaked_marker)

    @property
    def ok_fraction(self) -> float:
        return self.ok / self.total if self.total else 0.0


async def _fire_one(
    client: httpx.AsyncClient,
    idx: int,
    *,
    path: str,
    token: str,
    caller_label: str,
    own_marker: str,
    forbidden_marker: str,
    result: CheckResult,
) -> None:
    try:
        resp = await client.get(path, headers={"Authorization": f"Bearer {token}"})
    except httpx.HTTPError as exc:  # noqa: BLE001 - se reporta, no se re-lanza
        result.other_errors.append((idx, -1))
        print(f"  [{idx}] {caller_label}: ERROR de red — {exc!r}")
        return

    result.total += 1
    body_text = resp.text

    if resp.status_code == CLAIMS_MISSING_STATUS and "No active account found" in body_text:
        result.claims_missing += 1
        print(f"  [{idx}] {caller_label}: 403 'No active account found' — claims ausentes")
        return

    if resp.status_code != 200:
        result.other_errors.append((idx, resp.status_code))
        print(f"  [{idx}] {caller_label}: status inesperado {resp.status_code}")
        return

    if forbidden_marker and forbidden_marker in body_text:
        result.leaks.append((idx, caller_label, forbidden_marker))
        print(f"  [{idx}] {caller_label}: *** FUGA CROSS-TENANT *** — apareció {forbidden_marker!r}")
        return

    result.ok += 1


async def run_check() -> CheckResult:
    base_url = os.environ["TENANCY_CHECK_BASE_URL"]
    token_a = os.environ["TENANCY_CHECK_TOKEN_A"]
    token_b = os.environ["TENANCY_CHECK_TOKEN_B"]
    marker_a = os.environ["TENANCY_CHECK_MARKER_A"]
    marker_b = os.environ["TENANCY_CHECK_MARKER_B"]
    path = os.environ.get("TENANCY_CHECK_PATH", DEFAULT_PATH)
    n = int(os.environ.get("TENANCY_CHECK_REQUEST_COUNT", DEFAULT_REQUEST_COUNT))

    if n < 50:
        raise ValueError("La condición 2 de design.md exige >= 50 requests concurrentes")

    result = CheckResult()
    print(f"Disparando {n} requests concurrentes contra {base_url}{path} (2 cuentas intercaladas)...")

    async with httpx.AsyncClient(base_url=base_url, timeout=30.0) as client:
        tasks = []
        for i in range(n):
            if i % 2 == 0:
                caller, token, own_marker, forbidden = "cuenta_A", token_a, marker_a, marker_b
            else:
                caller, token, own_marker, forbidden = "cuenta_B", token_b, marker_b, marker_a
            tasks.append(
                _fire_one(
                    client,
                    i,
                    path=path,
                    token=token,
                    caller_label=caller,
                    own_marker=own_marker,
                    forbidden_marker=forbidden,
                    result=result,
                )
            )
        await asyncio.gather(*tasks)

    return result


def _print_summary(result: CheckResult) -> None:
    print()
    print("=== Resumen — prueba de concurrencia cross-tenant (design.md condición 2) ===")
    print(f"Total:            {result.total}")
    print(f"OK:               {result.ok}")
    print(f"Claims ausentes:  {result.claims_missing}  (debe ser 0)")
    print(f"Otros errores:    {len(result.other_errors)}  (debe ser 0)")
    print(f"Fugas cross-tenant: {len(result.leaks)}  (debe ser 0 — CUALQUIER valor > 0 es CRÍTICO)")


def main() -> int:
    result = asyncio.run(run_check())
    _print_summary(result)

    if result.leaks:
        print()
        print("FALLO: se detectó al menos una fuga cross-tenant. NO activar/continuar el Paso 2.")
        return 2
    if result.claims_missing:
        print()
        print("FALLO: hubo requests con claims ausentes (403 anómalo). Revisar antes de continuar.")
        return 1
    if result.other_errors:
        print()
        print("ADVERTENCIA: hubo errores no relacionados con tenancy/claims. Revisar igual.")
        return 1

    print()
    print("OK: ninguna fuga cross-tenant, ninguna falla por claims ausentes.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
