## Why

El hallazgo **H-34** de la auditoría (y la mitad pendiente de **H-04**) sigue abierto: la lógica de dinero vive en RPCs SQL, pero el camino **Python → Postgres** que las invoca sólo se prueba con `asyncpg` mockeado. Hay **12 archivos** de tests `-m integration` que ya ejecutan los repositorios y servicios contra un Postgres real (remitos, presupuestos, facturación, invitaciones, huella de dinero de la edición, aging emparejado, webhook de suscripciones de MercadoPago), pero **nunca corren en CI**: `Backend_Tests.yml` los excluye con `-m "not integration"`, y si no encuentran Postgres hacen `pytest.skip`. A esto se suma que **74 gates SQL** de `KPI_Validation.yml` tienen ramas que, si falta una precondición del entorno (cuenta ancla, sucursal, caja, forma de pago sembrada), **degradan a `RAISE NOTICE` y terminan en verde** sin haber asertado nada. 33 de esos gates son de dinero, con 202 ramas de ese tipo. Una regresión en el aprovisionamiento (`handle_new_user`, la siembra de catálogos) apagaría en silencio las aserciones de caja, banco, asiento y cuenta corriente. Hoy es el siguiente P1 del Roadmap v3.1, y `v4-backend-04` depende del fixture que construye este change.

## What Changes

- **Tier de integración en CI**: un paso nuevo en `KPI_Validation.yml`, sobre el stack de `supabase start` que ese job ya levanta, corre `pytest backend/tests -m "integration and not arca"` con `DATABASE_URL` apuntando a `127.0.0.1:54322`. Usa el mismo check que ya reporta en cada PR, sin filtro de rutas.
- **Fail-closed**: con `CI_REQUIRE_INTEGRATION=1`, un test de integración que se saltea **falla**, y la sesión de pytest aborta si Postgres no responde. En local, sin esa variable, se sigue salteando como hoy.
- **Marker `arca`**: los 3 tests que necesitan credenciales reales de ARCA (`test_c27_wsfe_adapter.py`, `test_c31_wsfe_homologacion_wiring.py`, `test_emit_invoice.py`) pasan a llevar también el marker `arca`. El tier los excluye explícitamente: no son de Postgres y su skip es legítimo.
- **Fixture canónico de integración**: `backend/tests/integration_db.py` (DSN, conexión con guardia de host local, claims del JWT, preflight). Los 12 archivos sólo migran donde el cambio es mecánico, y conservan su `world` propio de dominio.
- **Guardia de host**: el fixture rechaza cualquier `DATABASE_URL` que no apunte a `localhost`/`127.0.0.1`/`::1`. Los tests borran filas de `auth.users`.
- **Cobertura de los flujos que nombra H-34 y que no tienen ningún test de integración**: arqueo (cierre de sesión de caja), conciliación bancaria y partida doble (asiento generado por el dispatcher del outbox). Se suma un test de integración delgado por flujo, a través de los repositorios reales.
- **Gates de dinero estrictos**: un wrapper `supabase/tests/run_gate_strict.sh` corre cada uno de los 33 gates de dinero y falla si aparece una degradación en la salida. Las degradaciones propias del entorno (dblink sin TCP, GRANT base del entorno, `pg_default_acl`) quedan en una allow-list explícita y comentada. Ningún archivo `.sql` de gate cambia.
- **Cobertura**: el job hermético conserva su piso del 87% intacto. El tier de integración corre sin `--cov`.
- **Sin superficie frontend**: es un cambio de CI y tests. No hay pantalla, ruta ni menú que agregar, y nadie, usuario ni admin, ve nada distinto.

## Capabilities

### New Capabilities
- `integration-test-tier`: el tier de tests de integración del backend contra un Postgres real en CI. Cubre dónde corre, el fail-closed de los skips, el fixture canónico con la guardia de host, la exclusión de ARCA, la cobertura mínima de los flujos de dinero y la política de gates SQL de dinero que no pueden degradar en silencio.

### Modified Capabilities
_(ninguna: `python-backend` describe la app, no la estrategia de CI. La cláusula de que «los workflows declaran su camino de verificación» ya cubre el `AUTH_ALLOW_HS256_FALLBACK` que el paso nuevo declara.)_

## Impact

- **CI**: `.github/workflows/KPI_Validation.yml` (setup de Python con caché de pip, paso del tier de integración, 33 invocaciones de gate de dinero pasan por el wrapper). `Backend_Tests.yml` no cambia.
- **Backend tests**: `backend/pyproject.toml` (marker `arca`), `backend/tests/integration_guard.py` nuevo (hooks de fail-closed y preflight, re-exportados por `conftest.py`), `backend/tests/integration_db.py` nuevo, 3 tests nuevos de integración (caja, conciliación, asiento), marcado `arca` en 3 archivos, migración mecánica opcional de los 12 archivos al fixture.
- **SQL**: `supabase/tests/run_gate_strict.sh` + `supabase/tests/gate_degradation_allowlist.txt` nuevos. Ninguna migración y ningún cambio a `supabase/config.toml`.
- **Duración**: se suman alrededor de 11 s de instalación de Python (con caché) más la corrida del tier al job `validate-kpis`, que hoy tarda unos 8,4 min. Se mide en la primera corrida real.
- **Producción**: cero. No se toca dinero real, datos ni deploy.
- **Branch protection**: `main` hoy no tiene protección ni rulesets (medido el 2026-11-05). Volver obligatorio el check es un paso manual del PO.
