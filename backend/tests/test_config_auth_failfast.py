"""auth-hardening-jwt-cookies Parte A, grupo 3 (D9) — la rama HS256 deja de
ser alcanzable por omisión, y una configuración de auth incoherente impide el
arranque.

**El riesgo que cierra.** Hoy la elección de rama es por prefijo de string
(`supabase_url.startswith("http")`, `backend/core/auth.py`) sobre defaults
`supabase_jwt_secret="dev-secret"` y `supabase_url=""`. Un `SUPABASE_URL` mal
puesto en Render no degrada de forma visible: cae a HS256 con un secreto que
está publicado en el repo, así que da 401 a todo el tráfico legítimo **y
acepta cualquier token forjado con ese secreto** — y el `sub` forjado es
`auth.uid()` aguas abajo (`backend/core/database.py:116`), es decir
impersonación completa. Que el proceso no levante convierte un incidente de
seguridad latente en un despliegue que falla ruidosamente.

**Por qué los tests construyen `Settings()` a mano.** `settings = Settings()`
corre en el **import** del módulo (última línea de `backend/core/config.py`),
así que el validator no se puede ejercitar con un fixture: ya sería tarde.
"""
from __future__ import annotations

import os
import pathlib
import subprocess
import sys
from unittest.mock import patch

import pytest
from fastapi import HTTPException
from pydantic import ValidationError

from backend.core.auth import _decode_supabase_jwt
from backend.core.config import Settings

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
VALID_URL = "https://gxdhpxvdjjkmxhdkkwyb.supabase.co"


def _settings(**overrides) -> Settings:
    """Construye `Settings` con valores explícitos.

    Los kwargs de inicialización tienen prioridad sobre el entorno y sobre
    `.env` en pydantic-settings, así que el caso queda determinado por lo que
    el test declara y no por lo que haya en la máquina que lo corre.
    """
    values = {
        "supabase_url": "",
        "auth_allow_hs256_fallback": False,
        "app_env": "development",
        "backend_allowed_origin": "*",
    }
    values.update(overrides)
    return Settings(**values)


def _clean_env() -> dict[str, str]:
    """El entorno de CI real: sin ninguna variable de auth definida.

    `.github/workflows/Backend_Tests.yml` no declaraba **ninguna** variable
    antes de este change, así que éste es exactamente el entorno en el que
    corre el gate.
    """
    return {
        k: v
        for k, v in os.environ.items()
        if not k.startswith(("AUTH_ALLOW_HS256", "SUPABASE_"))
    }


# ── 3.1 / 3.2 — fail-fast de arranque ────────────────────────────────────


def test_startup_fails_without_supabase_url_and_without_flag():
    """3.1 RED: hoy esto construye `Settings` sin chistar y deja la rama HS256
    con `"dev-secret"` esperando al primer request."""
    with pytest.raises(ValidationError):
        _settings(supabase_url="", auth_allow_hs256_fallback=False)


def test_startup_error_names_the_missing_variable():
    """3.2 RED: "configuración inválida" no le sirve a nadie a las 3 de la
    mañana. El mensaje tiene que nombrar la variable **y** la salida."""
    with pytest.raises(ValidationError) as exc:
        _settings(supabase_url="", auth_allow_hs256_fallback=False)

    message = str(exc.value)
    assert "SUPABASE_URL" in message
    assert "AUTH_ALLOW_HS256_FALLBACK" in message


def test_non_https_url_is_rejected_even_when_present():
    """3.1 TRIANGULATE (D9, "un staging sobre http:// también aborta"): un
    JWKS servido por HTTP plano no es una fuente de claves confiable. La
    ausencia de la variable no es el único estado inválido."""
    with pytest.raises(ValidationError) as exc:
        _settings(supabase_url="http://gxdhpxvdjjkmxhdkkwyb.supabase.co")

    assert "SUPABASE_URL" in str(exc.value)


def test_startup_succeeds_with_https_url_and_flag_off():
    """3.1 TRIANGULATE (el caso de producción): con la URL bien puesta y la
    palanca apagada, el arranque es normal. Sin este caso, un validator que
    rechazara SIEMPRE pasaría los dos tests de arriba."""
    settings = _settings(supabase_url=VALID_URL, auth_allow_hs256_fallback=False)

    assert settings.supabase_url == VALID_URL
    assert settings.auth_allow_hs256_fallback is False


def test_startup_succeeds_without_url_when_flag_is_on():
    """3.1 TRIANGULATE (el caso de dev/CI): la palanca explícita es la salida
    documentada, y funciona."""
    settings = _settings(supabase_url="", auth_allow_hs256_fallback=True)

    assert settings.auth_allow_hs256_fallback is True


def test_the_flag_is_off_by_default():
    """3.1 TRIANGULATE: el default **es** el control. Si alguien lo invirtiera,
    todos los tests de arriba seguirían pasando y el change no valdría nada."""
    assert Settings.model_fields["auth_allow_hs256_fallback"].default is False


# ── 3.3 — la rama HS256 exige la palanca ─────────────────────────────────


@pytest.mark.asyncio
async def test_hs256_branch_requires_explicit_flag():
    """3.3 RED: hoy, con `supabase_url=""`, la rama HS256 se ejecuta sola —
    la elección es por prefijo de string, sin ninguna palanca de por medio."""
    import jwt

    secret = "test-secret-key-de-32-bytes-o-mas!!"
    token = jwt.encode(
        {"sub": "user-123", "aud": "authenticated", "exp": 9_999_999_999},
        secret,
        algorithm="HS256",
    )

    with patch("backend.core.auth.settings") as mock_settings:
        mock_settings.supabase_url = ""
        mock_settings.supabase_jwt_secret = secret
        mock_settings.auth_allow_hs256_fallback = False
        with pytest.raises(HTTPException) as exc:
            _decode_supabase_jwt(token)

    assert exc.value.status_code == 401


@pytest.mark.asyncio
async def test_hs256_branch_runs_when_the_flag_is_on():
    """3.3 TRIANGULATE: el control negativo del anterior. La palanca encendida
    sí habilita la rama — si no, el rechazo de arriba sería por cualquier otro
    motivo y el test no probaría nada sobre la palanca."""
    import jwt

    secret = "test-secret-key-de-32-bytes-o-mas!!"
    token = jwt.encode(
        {"sub": "user-123", "aud": "authenticated", "exp": 9_999_999_999},
        secret,
        algorithm="HS256",
    )

    with patch("backend.core.auth.settings") as mock_settings:
        mock_settings.supabase_url = ""
        mock_settings.supabase_jwt_secret = secret
        mock_settings.auth_allow_hs256_fallback = True
        payload = _decode_supabase_jwt(token)

    assert payload["sub"] == "user-123"


# ── 3.4 / 3.4b — la suite sigue recolectándose desde un entorno limpio ────


def test_importing_config_from_a_clean_environment_aborts():
    """3.4b, mitad negativa: prueba que el fail-fast es REAL en el punto donde
    duele — el import del módulo, no una función que alguien llama después.
    Se corre en un subproceso porque en este proceso el módulo ya está
    importado y `Settings()` ya se construyó."""
    result = subprocess.run(
        [sys.executable, "-c", "import backend.core.config"],
        cwd=REPO_ROOT,
        env=_clean_env(),
        capture_output=True,
        text=True,
    )

    assert result.returncode != 0, (
        "importar la config sin SUPABASE_URL y sin la palanca debe abortar; "
        "si no aborta, el validator no está cubriendo el arranque real"
    )
    assert "SUPABASE_URL" in result.stderr


def test_pytest_still_collects_from_a_clean_environment():
    """3.4b, la mitad que IMPORTA (bloqueante B2 de la revisión adversarial):
    con el fail-fast puesto y `Backend_Tests.yml` sin una sola variable de
    entorno, la suite entera moría **en la recolección** — 0 tests
    recolectados y `--cov-fail-under=87` nunca evaluado, es decir CI y local
    en rojo por una razón que no es un test fallando.

    Lo que salva la recolección es `os.environ.setdefault(...)` en el **tope**
    de `conftest.py`, por encima de los imports. Un fixture correría
    demasiado tarde: `settings = Settings()` es la última línea de
    `config.py` y se ejecuta al importar. Este test es ese candado.
    """
    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "pytest",
            "backend/tests/test_auth.py",
            "--collect-only",
            "-q",
            "--no-cov",
        ],
        cwd=REPO_ROOT,
        env=_clean_env(),
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, (
        f"la recolección falló desde un entorno limpio:\n"
        f"--- stdout ---\n{result.stdout}\n--- stderr ---\n{result.stderr}"
    )
    assert "error" not in result.stdout.lower()


# ── 3.4c — TODOS los workflows que arrancan el proceso, no sólo uno ──────
#
# Hallazgo B1 de las dos revisiones adversariales del apply (2026-09-16), y la
# regla del proyecto que lo explica: **al endurecer un contrato, migrar TODOS
# los callers**. La task 3.4 migró el `env:` de `Backend_Tests.yml` y el design
# no nombraba el otro caller: `E2E_Tests.yml` levanta `uvicorn backend.main:app`
# con `SUPABASE_URL=$API_URL` del Supabase local, que es **`http://`**
# 127.0.0.1:54321 — y sin la palanca el validator de D9 aborta el arranque, así
# que el paso "Wait for backend health" moría a los 60 s. Un workflow que lanza
# el proceso es un caller del contrato de `Settings`.
#
# El criterio es deliberadamente **estático y visible**: sirve lo que está
# escrito en el archivo del workflow, no lo que un paso anterior haya escrito
# en `$GITHUB_ENV` (que es justamente cómo el valor `http://` entraba sin que
# nadie lo viera). Si el valor no se puede leer en el workflow, hay que
# declarar la palanca.

WORKFLOWS_DIR = REPO_ROOT / ".github" / "workflows"

# Marcadores de "este paso importa `backend.core.config`" — que es donde corre
# el validator de D9, porque `settings = Settings()` es la última línea del
# módulo.
_BACKEND_BOOT_MARKERS = (
    "backend.main:app",
    "pytest backend/tests",
    "import backend.core",
)

_TRUTHY = {"true", "1", "yes", "on"}


def _boots_the_backend(run: str) -> bool:
    return any(marker in run for marker in _BACKEND_BOOT_MARKERS)


def _declares_a_verification_path(*envs: dict | None) -> bool:
    """¿El entorno declarado ALCANZA para que `Settings()` no aborte?

    Dos formas válidas, las dos explícitas: la palanca de D9 encendida, o un
    `SUPABASE_URL` literal `https://` escrito en el propio workflow.
    """
    merged: dict[str, object] = {}
    for env in envs:
        if env:
            merged.update(env)

    if str(merged.get("AUTH_ALLOW_HS256_FALLBACK", "")).strip().lower() in _TRUTHY:
        return True
    return str(merged.get("SUPABASE_URL", "")).strip().startswith("https://")


def workflow_steps_missing_a_verification_path(workflow: dict) -> list[str]:
    """Pasos que arrancan el backend sin declarar cómo verifica los tokens.

    Función pura sobre el YAML ya parseado: así la matriz de evasión del
    detector se ejercita con workflows sintéticos, sin tocar los reales.
    """
    offenders: list[str] = []
    workflow_env = workflow.get("env")
    for job_name, job in (workflow.get("jobs") or {}).items():
        job_env = (job or {}).get("env")
        for step in (job or {}).get("steps") or []:
            run = str((step or {}).get("run") or "")
            if not _boots_the_backend(run):
                continue
            if _declares_a_verification_path(workflow_env, job_env, (step or {}).get("env")):
                continue
            offenders.append(f"{job_name} / {(step or {}).get('name') or run.strip()[:60]}")
    return offenders


def test_every_workflow_that_boots_the_backend_declares_its_verification_path():
    """3.4c RED (hallazgo B1): hoy `E2E_Tests.yml` arranca el backend sin la
    palanca y con una `SUPABASE_URL` de `http://` que le llega por
    `$GITHUB_ENV` — el proceso no levanta y el gate E2E queda en rojo."""
    import yaml  # llega con uvicorn[standard], que ya es dependencia del backend

    offenders: dict[str, list[str]] = {}
    workflows = sorted(WORKFLOWS_DIR.glob("*.yml")) + sorted(WORKFLOWS_DIR.glob("*.yaml"))
    assert workflows, "no se encontró ningún workflow: el detector no puede probar nada"

    for path in workflows:
        workflow = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        missing = workflow_steps_missing_a_verification_path(workflow)
        if missing:
            offenders[path.name] = missing

    assert offenders == {}, (
        "estos pasos arrancan el backend sin declarar cómo verifica los tokens "
        "(palanca AUTH_ALLOW_HS256_FALLBACK o un SUPABASE_URL https:// literal "
        f"en el propio workflow): {offenders}"
    )


def test_the_boot_detector_catches_the_ways_of_evading_it():
    """3.4c TRIANGULATE — matriz de evasión del detector, EJECUTADA (lección
    registrada del proyecto: un detector sin su matriz no prueba nada).

    Los cinco primeros casos deben disparar; los tres últimos, no.
    """
    def _wf(step_env=None, job_env=None, top_env=None, run="python -m uvicorn backend.main:app"):
        return {
            "env": top_env,
            "jobs": {"j": {"env": job_env, "steps": [{"name": "boot", "run": run, "env": step_env}]}},
        }

    # Dispara: sin nada declarado.
    assert workflow_steps_missing_a_verification_path(_wf()) != []
    # Dispara: la palanca en "false" no es una declaración válida.
    assert workflow_steps_missing_a_verification_path(
        _wf(step_env={"AUTH_ALLOW_HS256_FALLBACK": "false"})
    ) != []
    # Dispara: una URL de `http://` (el caso REAL del Supabase local) no alcanza.
    assert workflow_steps_missing_a_verification_path(
        _wf(step_env={"SUPABASE_URL": "http://127.0.0.1:54321"})
    ) != []
    # Dispara: el valor que llega por $GITHUB_ENV no es visible en el archivo,
    # y es exactamente así como el `http://` se colaba sin que nadie lo viera.
    assert workflow_steps_missing_a_verification_path(
        _wf(step_env={"SUPABASE_URL": "${{ env.API_URL }}"})
    ) != []
    # Dispara también cuando lo que arranca es pytest (mismo import, mismo validator).
    assert workflow_steps_missing_a_verification_path(
        _wf(run="python -m pytest backend/tests -q")
    ) != []

    # No dispara: la palanca encendida, en cualquiera de los tres niveles.
    assert workflow_steps_missing_a_verification_path(
        _wf(step_env={"AUTH_ALLOW_HS256_FALLBACK": "true"})
    ) == []
    assert workflow_steps_missing_a_verification_path(
        _wf(job_env={"AUTH_ALLOW_HS256_FALLBACK": "true"})
    ) == []
    assert workflow_steps_missing_a_verification_path(
        _wf(top_env={"AUTH_ALLOW_HS256_FALLBACK": "TRUE"})
    ) == []
    # No dispara: una URL `https://` literal es la otra declaración válida.
    assert workflow_steps_missing_a_verification_path(
        _wf(step_env={"SUPABASE_URL": VALID_URL})
    ) == []
    # No dispara: un paso que no arranca el backend queda fuera de alcance.
    assert workflow_steps_missing_a_verification_path(
        _wf(run="pnpm -C frontend exec playwright test")
    ) == []


# ── 4.6 — el comodín está prohibido en producción ────────────────────────


def test_wildcard_origin_forbidden_in_production():
    """4.6 RED: `backend_allowed_origin` tiene default `"*"` y `app_env` se
    declara pero HOY no se lee en ninguna línea de la app. Un despliegue de
    producción que no defina la variable queda con el comodín activo, que es
    exactamente el estado que produjo F5."""
    with pytest.raises(ValidationError) as exc:
        _settings(
            supabase_url=VALID_URL, app_env="production", backend_allowed_origin="*"
        )

    assert "BACKEND_ALLOWED_ORIGIN" in str(exc.value)


def test_wildcard_origin_allowed_outside_production():
    """4.6 TRIANGULATE: fuera de producción el default no rompe el arranque
    (aunque tampoco se use como origen — ver test_cors_allowlist.py)."""
    settings = _settings(
        supabase_url=VALID_URL, app_env="development", backend_allowed_origin="*"
    )

    assert settings.backend_allowed_origin == "*"


def test_production_starts_with_a_concrete_origin():
    """4.6 TRIANGULATE: producción con un origen concreto arranca normal — sin
    este caso, un validator que rechazara SIEMPRE en producción pasaría."""
    settings = _settings(
        supabase_url=VALID_URL,
        app_env="production",
        backend_allowed_origin="https://www.aliadata.com.ar",
    )

    assert settings.app_env == "production"


# ── 4.7 — el DEFAULT del campo, no un valor que el test elige ────────────
#
# Hallazgo B2 de la revisión adversarial del apply: el default del campo era
# `"*"`, y el validator de 4.6 prohíbe justamente ese valor en producción. La
# combinación producía un backend que **no levanta** en el estado que el
# design, el proposal y la task 4.7 declaran como el real de Render
# (`BACKEND_ALLOWED_ORIGIN` sin definir) si `APP_ENV=production` — con un
# mensaje que además mandaba a "dejá la variable sin definir", que es el estado
# que lo disparaba. Los tests de CORS esquivaban la interacción construyendo el
# doble con `""` en vez del default real.


def test_production_starts_with_the_field_default_origin(monkeypatch):
    """4.7 RED (B2): sin `BACKEND_ALLOWED_ORIGIN` en el entorno y con
    `APP_ENV=production`, el arranque tiene que ser normal — los orígenes
    reales ya están en la allow-list de `backend/core/cors.py`. Hoy explota."""
    monkeypatch.delenv("BACKEND_ALLOWED_ORIGIN", raising=False)

    settings = Settings(supabase_url=VALID_URL, app_env="production")

    assert settings.app_env == "production"
    assert settings.backend_allowed_origin != "*"


def test_the_default_origin_is_not_the_wildcard():
    """4.7 TRIANGULATE (B2): el default **es** la parte que importa. Sin esta
    aserción, alguien puede volver a poner `"*"` y el test de arriba se
    "arregla" pasando un valor explícito, que es exactamente el atajo que la
    revisión encontró."""
    assert Settings.model_fields["backend_allowed_origin"].default == ""


def test_the_wildcard_is_still_rejected_when_written_by_hand():
    """4.7 TRIANGULATE (B2): sacar el comodín del default NO afloja el control
    de 4.6 — escribirlo a mano en producción sigue abortando el arranque."""
    with pytest.raises(ValidationError) as exc:
        _settings(
            supabase_url=VALID_URL, app_env="production", backend_allowed_origin="*"
        )

    assert "BACKEND_ALLOWED_ORIGIN" in str(exc.value)
