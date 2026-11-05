## Context

H-34 (ALTO, P1 del Roadmap v3.1) más la mitad de H-04 que `v31-ci-test-gate` dejó explícitamente para P1: el camino Python → Postgres de la lógica de dinero no se ejecuta en CI contra una base real, y una parte de los gates SQL puede terminar en verde sin haber asertado nada.

### Hechos medidos (2026-11-05, sobre `main` = `465e801e`)

**Tests de integración del backend.** `grep pytest.mark.integration backend/tests` devuelve **15 archivos**, no los 9 que traía el pedido:

| Grupo | Archivos | Tests aprox. | Comportamiento sin Postgres |
|---|---|---|---|
| **Postgres real** (12) | `test_aging_reversal_pairing.py` (2 de 4 marcados), `test_delivery_note_convert_integration.py` (15), `test_delivery_note_purchase_convert_integration.py` (21), `test_delivery_notes_module_integration.py` (35), `test_factura_fiscal_tenencia_integration.py` (1), `test_facturar_venta_manual_integration.py` (2), `test_invitations_integration.py` (6), `test_op_money_footprint_projection.py` (3 de 5 marcados), `test_products_scale_plu_integration.py` (2), `test_quotes_module_integration.py` (32), `test_subscriptions_apply_approved_charge_integration.py` (2), `test_subscriptions_webhook_handlers_integration.py` (8) | ~128 | 8 archivos hacen `pytest.skip("Postgres local no disponible…")`. 3 (`products_scale_plu`, los dos de `subscriptions_*`) llaman a `asyncpg.connect(DSN)` sin `try` y **dan error**. Los 2 `delivery_note_*_convert` importan el fixture `conn`/`world` de `test_delivery_notes_module_integration.py` |
| **ARCA real** (3) | `test_c27_wsfe_adapter.py` (clase `TestWSFEAdapterRealHomologacion`), `test_c31_wsfe_homologacion_wiring.py` (§7.1), `test_emit_invoice.py` (L405) | 3 | `pytest.skip` incondicional o por falta de credenciales de ARCA: es legítimo y no tiene nada que ver con Postgres |

- El DSN se repite en los 12 archivos: `os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@127.0.0.1:54322/postgres")`. Los claims se inyectan con `set_config('request.jwt.claims', $1, true)` más `request.jwt.claim.sub`, dentro de `conn.transaction()`. El aislamiento es por **cuenta sintética propia** (uuid nuevo) con limpieza explícita (`session_replication_role = replica` + `DELETE` por `account_id`, **incluido `DELETE FROM auth.users`**) o por `transaction()` más `rollback()`. Ninguno lee env files.
- `Backend_Tests.yml` corre `-m "not integration"` (hermético, unos 2 min de pared, piso de cobertura del 87%) con filtro de rutas `backend/**`, su propio workflow y `supabase/migrations/**`.
- El marker está declarado en `backend/pyproject.toml` como *"tests de integración contra servicios externos"*, así que mezcla Postgres local con ARCA.

**Infra de CI disponible.**
- `KPI_Validation.yml` (job `validate-kpis`, **sin filtro de rutas**, **sin `timeout-minutes`**) hace `supabase start` con el CLI `2.105.0`, la cadena de reaplicación con `supabase db reset` intermedios y luego **211** invocaciones de `psql -v ON_ERROR_STOP=1`. Corrida verde 41982888027: **8 min 23 s** de pared; `Start Supabase` 1 min 32 s.
- `E2E_Tests.yml` usa `actions/setup-python@v5` con caché de pip más `pip install -r backend/requirements.txt`: **11 s** en la corrida 41982888006. Exporta `DATABASE_URL=$DB_URL` desde `supabase status -o env` y declara `AUTH_ALLOW_HS256_FALLBACK=true`.
- `main` **no tiene branch protection ni rulesets** (`gh api …/branches/main/protection` → 404, `…/rulesets` → `[]`). Hoy no existe ningún check obligatorio en sentido técnico.

**Degradaciones de los gates SQL.** `grep -il "RAISE NOTICE.*(SKIP|degrad|omit)" supabase/tests/*.sql` devuelve 75 archivos. Uno es falso positivo (`test_multiusuario_cuenta_activa.sql`, sólo verbos de dominio en líneas `PASS`). Quedan **74 archivos con 392 ramas reales de degradación**, contando los `RAISE NOTICE` cuyo mensaje no empieza en `PASS`/`OK` y contiene SKIP/DEGRAD/degradando/degradado/se omite/omitido/sin abortar:

| Categoría | Archivos | Ramas | Por entorno | Nota |
|---|---|---|---|---|
| **Dinero** (caja, banco, asiento, outbox, cuenta corriente, cobranzas, formas de pago, compras/gastos con dinero, suscripciones) | **33** | **202** | 1 (`test_payment_methods_catalog.sql` (6): "el entorno no otorga GRANT base") | Los 33 están cableados en `KPI_Validation.yml`. 200 de los 202 mensajes empiezan con `GATE`/`SKIP` y 2 con `DEGRADE (` (`test_receipts_subscription_charges.sql`) |
| Resto (membresías, roles, productos, importadores, estadísticas, fiscal, sucursal, analytics) | 41 | 190 | 6 | Fuera de alcance (Non-Goal) |

Los 33 gates de dinero: `test_asiento_contable_gastos` (23), `test_asiento_venta_formulario` (4), `test_banco_caja_historial_ajustes` (3), `test_bank_default_destination` (4), `test_c30_party_movement_helpers_acl` (4), `test_cash_movement_types` (2), `test_charge_due_date` (3), `test_cobranzas_reverso` (12), `test_cobranzas_vencimientos_schema` (3), `test_compras_gastos_sucursal_por_defecto` (1), `test_compras_proveedor_cuenta_corriente` (5), `test_cuenta_corriente_party_guard` (4), `test_cuentas_billetera_tipo` (4), `test_delete_guard_ledgers` (4), `test_expense_import_batch` (32), `test_gastos_forma_pago` (29), `test_operacion_party_guard` (4), `test_pagos_cableados_restantes` (3), `test_party_payment_cash` (8), `test_payment_method_operations` (3), `test_payment_method_report` (2), `test_payment_methods_catalog` (3), `test_payment_methods_seed` (3), `test_pos_banco_movimientos` (3), `test_pos_confirm_payment_method` (3), `test_pos_payment_vocabulary` (1), `test_purchase_cash_optin` (8), `test_purchase_delete_cash_compensation` (12), `test_receipts_subscription_charges` (2), `test_receivables_aging_fifo` (2), `test_receivables_overdue_digest` (1), `test_receivables_report` (2), `test_tenancy_guard_caja_outbox` (5). (`test_stock_ledger_solo_rpc` entra por el nombre «ledger», pero es de stock: queda en «resto».)

El mecanismo es casi siempre el mismo: `IF v_account IS NULL THEN RAISE NOTICE 'GATE … degradando sin abortar.'; RETURN; END IF;`. Si falta una precondición (`handle_new_user` no aprovisionó la cuenta, no hay caja o forma de pago sembrada), **el bloque entero no aserta nada y el paso termina en verde**.

**¿Disparan hoy en CI?** Se grepeó el log completo de la corrida verde 41982888027 (2.421 `NOTICE`), descontando el ruido que no escribe ningún gate: `send_email_log_webhook: Vault secrets not configured — skipping`, `… does not exist, skipping` de los `DROP IF EXISTS`, las migraciones reaplicadas y las líneas `PASSED`. Resultado: **disparan 4 degradaciones** y **una es de dinero**:
- `test_payment_methods_seed.sql:46` → *"GATE PAYMENT-METHODS-SEED (1) degradado: no hay cuentas en el stack — nada que verificar."* El bloque (1), que verifica la siembra del catálogo de formas de pago por cuenta, **no se ejecuta nunca en CI**. Es exactamente el modo de falla que describe H-34.
- Fuera de alcance: `test_custom_access_token_hook_account_roles.sql` bloque 5 (límite documentado del entorno: no hay membresía `supabase_auth_admin`) y dos `SKIP-CANDADO` de `test_sucursal_guard_vaciado.sql` (CHECKs que hoy impiden construir el caso).

**Repositorios de los flujos que nombra H-34.** Arqueo: `CashSessionRepository.open_session`/`close_session` → `rpc_open_cash_session`/`rpc_close_cash_session`. Conciliación: `BankReconciliationRepository` (`rpc_import_bank_statement`, `rpc_open_reconciliation_session`, `rpc_create_reconciliation_match`, `rpc_undo_reconciliation_match`, `rpc_close_reconciliation_session`). Partida doble: `OutboxRepository.run_dispatch` → `rpc_process_outbox_dispatch` → `journal_entries`/`journal_entry_lines`. Webhook: ya lo cubren los dos `test_subscriptions_*_integration.py`. Ninguno de los 12 archivos ejercita el arqueo, la conciliación ni el asiento a través de su repositorio.

## Goals / Non-Goals

**Goals:**
- Que los tests de integración contra Postgres corran en **cada PR**, en un check que siempre reporte, y que **no puedan saltearse en silencio** en CI.
- Un fixture canónico de integración que reutilice lo que los 12 archivos ya hacen, con guardia de host local, y que `v4-backend-04` pueda heredar.
- Cubrir con un test de integración por flujo los tres flujos de H-34 que no tienen ninguno: arqueo, conciliación y partida doble.
- Que los 33 gates SQL de dinero **no puedan degradar a NOTICE en CI** salvo por una causa de entorno declarada en una allow-list.
- No tocar el piso de cobertura del job hermético ni producción.

**Non-Goals:**
- E2E con Playwright de los flujos de dinero y k6 nightly. Eso es `v31-e2e-money-flows` (P3).
- Endurecer las 190 degradaciones de los 41 gates que no son de dinero. Queda como candidato, y el mismo wrapper sirve el día que se quiera.
- Generalizar el harness a routers que no son de dinero y los contract tests de firmas. Eso es `v4-backend-04`.
- Reescribir los 12 archivos o sus `world` de dominio: sólo se migran DSN y conexión, que es lo mecánico.
- Configurar branch protection. No tenemos permiso, y queda como paso manual del PO.
- Cambiar `supabase/config.toml`, la versión del CLI, el job hermético o cualquier migración.

## Decisions

### D1. El tier corre como paso final de `KPI_Validation.yml`, sobre el stack que ya está levantado

Se agregan tres pasos al final del job `validate-kpis`: `actions/setup-python@v5` (3.12, caché de pip sobre `backend/requirements.txt`), la instalación de `backend/requirements.txt` más `pytest pytest-asyncio`, y **"Run backend integration tests (Postgres real)"**. Este último declara `if: ${{ !cancelled() }}` y `timeout-minutes: 10`, con el entorno `DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres`, `CI_REQUIRE_INTEGRATION=1`, `AUTH_ALLOW_HS256_FALLBACK=true`, `REDIS_URL=''` y `WSFE_ADAPTER_MODE=stub`, y corre `python -m pytest backend/tests -m "integration and not arca" -p no:cacheprovider -q`.

- **Costo**: la instalación cuesta unos 11 s medidos y los tests se estiman entre 1 y 3 min (se mide en la primera corrida, task 5.2). No hay un segundo `supabase start`, que cuesta 1 min 32 s medido.
- **Señal legible**: es un paso con nombre propio, así que un rojo ahí se lee como «integración», no como un gate SQL. Con `!cancelled()` corre aunque haya fallado un gate anterior, de modo que en la misma corrida se ven las dos señales.
- **Siempre reporta**: `KPI_Validation.yml` no tiene filtro de rutas, así que el check aparece en todo PR. Un workflow con `paths:` que se marca como obligatorio queda «Expected — waiting» para siempre en los PRs que no tocan esas rutas, y bloquea el merge.
- **Alternativas descartadas**: (a) un job `pytest-integration` en `Backend_Tests.yml`: cuesta unos 2 min más de runner por PR (otro `supabase start`), hereda el filtro de rutas con el problema de arriba y obliga a mantener una segunda receta de stack. (b) Un workflow nuevo: el mismo costo, sin ganar nada. (c) Correrlo justo después de `Start Supabase`: la base está prístina, pero un rojo cancela los ~208 gates siguientes y se pierde esa señal.
- **Estado de la base**: el paso corre después de los gates. Los tests ya se aíslan por cuenta sintética propia, y la mayoría de los gates asertan residuo cero. Si el checkpoint 0.4 demuestra acoplamiento real (un test que falla sólo después de los gates), se antepone `supabase db reset` (unos 60 a 90 s) y queda anotado. No se decide a ciegas.

### D2. Fail-closed por variable de entorno, en el `conftest.py` raíz y sin tocar cada test

Con `CI_REQUIRE_INTEGRATION=1` actúan tres hooks, que viven en `backend/tests/integration_guard.py` y que `backend/tests/conftest.py` re-exporta con un import explícito (se los puede probar aislados con `pytester`):
1. `pytest_sessionstart`: preflight. Valida el host del DSN (D4) y abre y cierra una conexión. Si falla, `pytest.exit(…, returncode=1)` con un mensaje claro. Así no se recolectan 128 skips para descubrir que no hay base.
2. `pytest_collection_finish`: si no quedó **ningún** item con marker `integration` (por ejemplo, una expresión `-m` mal escrita), sale con 1.
3. `pytest_runtest_makereport` (hookwrapper): un item con `integration` y **sin** `arca` cuyo reporte, en cualquier fase, sale `skipped` se reescribe a `failed` con el motivo original. Cubre a la vez los `pytest.skip` de los 8 archivos, los de fixtures y cualquier skip futuro.

Sin la variable, los hooks no hacen nada: en local los tests se siguen salteando sin Postgres, y el job hermético no cambia de comportamiento.

- **Alternativa descartada**: cambiar el `pytest.skip` de cada archivo por un helper condicional. Son 8 sitios ahora y cualquier test nuevo puede olvidarlo; el hook atrapa también lo que no conocemos.
- Un `xfail` no cuenta como skip, porque no lo reescribe. La regla es que ningún test de este tier lleva `xfail` (spec, requirement de fail-closed).

### D3. Marker `arca` para los tests contra servicios externos reales

Se declara el marker `arca` en `backend/pyproject.toml` (*"requiere credenciales/servicio real de ARCA; nunca corre en CI"*) y se aplica a los 3 tests de ARCA, que conservan además `integration` porque su documentación y su comando manual lo usan. El texto del marker `integration` se corrige a *"requiere Postgres local (supabase start) o un servicio externo; el tier de CI corre `integration and not arca`"*. El tier los excluye por expresión, y el hook de D2 los exceptúa como segunda capa.

- **Alternativa descartada**: renombrar el marker de los 12 a `postgres`. Rompe los comandos documentados en los docstrings de los 12 archivos, y `v4-backend-04` ya habla de «extender el marker `integration`».

### D4. Fixture canónico `backend/tests/integration_db.py` con guardia de host

Es un módulo de helpers, no un `conftest` en un subdirectorio: los 12 archivos viven planos en `backend/tests/` y moverlos rompe `from backend.tests.test_delivery_notes_module_integration import …`. Contiene:
- `DSN`: la misma resolución que hoy (`DATABASE_URL` o el default `127.0.0.1:54322`).
- `assert_local_dsn(dsn)`: rechaza cualquier host que no sea `localhost`, `127.0.0.1` o `::1`. Los tests borran filas de `auth.users`, y un `DATABASE_URL` exportado contra el pooler de producción sería un incidente. Se evalúa **al conectar y en el preflight**, nunca al importar: el job hermético importa estos módulos al recolectar (la deselección por `-m` ocurre después), y un raise a nivel de import lo rompería.
- `async def connect()`: guardia, después `asyncpg.connect(DSN)`, y ante `OSError`/`ConnectionRefusedError` un `pytest.skip("Postgres local no disponible…")`. Ese skip lo convierte en falla el hook de D2 cuando corre en CI.
- `async def set_claims(conn, user_id, extra=None)`: los dos `set_config(..., true)` que los 12 archivos repiten.

**Migración mecánica**: en los 12 archivos se reemplaza la constante `DSN` por el import y `asyncpg.connect(DSN)` por `connect()`, incluidos los bloques `try/except → pytest.skip`. Así los 3 archivos que hoy dan error sin Postgres pasan a saltearse en local, igual que los demás. Los `world`, `_auth`, `_as` y las limpiezas de dominio **no se tocan**; `set_claims` lo adoptan sólo los helpers cuyo cuerpo es literalmente esos dos `set_config`.

### D5. Un test de integración por flujo de H-34 sin cobertura: `backend/tests/test_money_flows_integration.py`

Los tests van a través de los repositorios reales, con una cuenta sintética propia y limpieza explícita, sobre el molde de `test_products_scale_plu_integration.py::_seed_account`, que reutilizan:
- **Arqueo**: `CashSessionRepository.open_session(cashbox, 1000)`, un movimiento de efectivo por la RPC vigente y `close_session(session, counted)` con un faltante. Asserta `expected_balance`, `counted_balance` y `difference` **calculados por la base**, y que una sesión cerrada no admite un segundo cierre.
- **Conciliación**: `import_statement` con dos líneas, `open_session`, `create_match` de una línea contra un movimiento bancario, `undo_match` y `close_session`. Asserta los estados que devuelven las RPCs y que el match deshecho libera la línea.
- **Partida doble**: una venta en efectivo por la RPC de alta vigente y `OutboxRepository.run_dispatch()`. Asserta que existe el asiento de la venta, que `SUM(debe) = SUM(haber)` en sus líneas y que una segunda corrida del dispatcher no duplica el asiento.

Los parámetros exactos (firmas vivas, RPC de alta, cuentas del plan) se toman del código de los repositorios y de las RPCs al implementar (checkpoint 0.3), no de este documento.

### D6. Gates de dinero estrictos con un wrapper que lee la salida de psql, sin editar ningún `.sql`

`scripts/ci/run_gate_strict.py <gate.sql>` (hay precedente: `scripts/ci/check_*_table_refs.py` corre en el mismo job con `python3`):
1. Ejecuta `psql -v ON_ERROR_STOP=1 <DSN> -f <gate>`, reenvía stdout y stderr tal cual al log y conserva el exit code de psql. Un `RAISE EXCEPTION` sigue fallando como hoy.
2. Detecta degradaciones sólo en las líneas `psql:<ese gate>:<n>: NOTICE:  <msg>`. Las de migraciones que un gate incluya con `\i` y el ruido de triggers del producto (`send_email_log_webhook`, `does not exist, skipping`) quedan fuera porque no empiezan con el prefijo de autor.
3. Una línea es degradación si `<msg>` empieza con `GATE`, `SKIP` o `DEGRADE` **y** contiene `DEGRAD`/`degradando`/`degradado` (pero no `degradado a`)/`SKIP`/`se omite`/`omitid`/`sin abortar`, **excepto** si contiene `PASSED`, `ninguno degradado` o `degrade-don't-fail`. Esa regla es la misma con la que se midieron las 202 ramas, y una prueba unitaria la fija contra todas ellas (task 4.2).
4. Si hay alguna degradación que no está en la allow-list, imprime la lista (archivo:línea:mensaje) y sale con 1.

`scripts/ci/gate_degradation_allowlist.txt` lleva una entrada por línea con el formato `<archivo.sql>|<subcadena del mensaje>|<motivo>`. Arranca con **una sola** entrada de dinero: `test_payment_methods_catalog.sql|el entorno no otorga GRANT base|GRANT base de authenticated ausente en entornos sin el rol estándar; en el stack de CI no dispara`. Cada entrada nueva necesita un motivo de entorno, nunca «falta un dato sembrado».

En `KPI_Validation.yml`, las 33 invocaciones de gate de dinero cambian de `psql -v ON_ERROR_STOP=1 … -f supabase/tests/X.sql` a `python3 scripts/ci/run_gate_strict.py supabase/tests/X.sql`. Las otras ~178 no cambian.

- **Alternativa descartada**: convertir en el SQL, con `IF current_setting('gates.strict', true) = 'on' THEN RAISE EXCEPTION`, o con un helper `pg_temp.gate_degrade()` incluido por `\ir`. Son 202 ediciones manuales en 33 archivos, con riesgo de CRLF/CR y de romper el formato de `%` en `RAISE` frente a `format()`. Un gate nuevo puede olvidar el helper. El wrapper no toca ningún gate, y además lista **todas** las degradaciones de una corrida, no sólo la primera.
- **Riesgo aceptado**: un gate de dinero que degrade con una redacción nueva, que no empiece con `GATE`/`SKIP`/`DEGRADE`, escapa al detector. Se mitiga con la convención de la spec (toda degradación nueva empieza con `GATE … DEGRADED`) y con la prueba unitaria que recorre los 33 archivos: si aparece un `RAISE NOTICE` de degradación que el detector no reconocería, la prueba falla.

### D7. El gate de siembra de formas de pago deja de degradar

La única degradación de dinero que dispara hoy en CI es `test_payment_methods_seed.sql` (1), «no hay cuentas en el stack». Con D6 se pondría en rojo en cuanto se active. El arreglo es que el bloque cree **su propia** cuenta ancla, igual que el resto de los gates de dinero (insertar un usuario sintético en `auth.users`, que dispara `handle_new_user`, y limpiarlo al final). Así deja de depender de que exista una cuenta previa. Es una corrección de gate, no de producto. Si al ejercitarlo de verdad el bloque falla, se encontró un bug real de la siembra y **se detiene y se reporta**: no se silencia.

### D8. Cobertura: el tier corre sin `--cov`

El paso de integración **no** pasa `--cov`. El piso del 87% sigue midiéndose sólo en `Backend_Tests.yml` y sobre la misma suite. Combinar las dos coberturas (`coverage combine`) subiría el número con código ejercitado contra la base real, pero mezclaría dos señales y volvería el piso dependiente del stack. Si se quiere después, es un candidato.

### D9. Documentación del tier

Se actualiza el comentario de cabecera de `Backend_Tests.yml`, que hoy dice *"los tests -m integration quedan fuera del gate por diseño"*, para que apunte al paso nuevo de `KPI_Validation.yml`. Los docstrings de los 12 archivos que dicen *"excluido del gate de CI"* se corrigen con un reemplazo mecánico de esa frase. `CHANGES.md` (ficha y registro) lo agrega el orquestador al abrir el PR, fuera de este artefacto.

## Risks / Trade-offs

- **[Tests podridos]** Los ~128 tests nunca corrieron en CI y algunos pueden fallar contra la base de hoy → el checkpoint 0.2 los corre en local antes de cablear. Si un fallo es deriva del test (por ejemplo, un fixture que ya no coincide con el schema), se arregla en el test. Si destapa un bug de producto en un camino de dinero, **se detiene y se reporta al orquestador**: no se marca `xfail` ni `skip`, porque eso es justo lo que el change prohíbe.
- **[Acoplamiento de estado con los gates]** → D1, checkpoint 0.4 y, si hace falta, `supabase db reset` previo con su costo anotado.
- **[Flaky por concurrencia]** Los tests no comparten cuentas, pero `run_dispatch` procesa eventos de **todas** las cuentas → el test de asiento asserta sobre **su** evento y **su** asiento (filtrando por `account_id`/`source_id`), nunca sobre conteos globales.
- **[Duración]** El job pasa de unos 8,4 min a una cifra estimada entre 9,5 y 11,5 → se mide (task 5.2). Si supera los 12 min se reevalúa la alternativa (a) de D1 antes de volver obligatorio el check.
- **[Detector por texto]** → D6, riesgo aceptado con su mitigación.
- **[Check obligatorio]** `main` no tiene protección, así que «obligatorio» hoy depende de la disciplina de mergear sólo en verde → task [PO] 5.5.
- **[DSN apuntando a producción]** → D4, la guardia de host evaluada al conectar y en el preflight.

## Migration Plan

1. Fixture y hooks (D2 a D4) más la migración mecánica de los 12 archivos. Corre en local con y sin `supabase start`, y con y sin `CI_REQUIRE_INTEGRATION`.
2. Tests nuevos de D5 y el arreglo de D7, en local.
3. Wrapper y allow-list (D6) con su prueba unitaria. Las 33 invocaciones se reemplazan en `KPI_Validation.yml`.
4. Pasos del tier (D1) en `KPI_Validation.yml`. El PR mide la duración real.
5. **Rollback**: revertir el PR. No hay migración ni estado de producción involucrado. Como palanca parcial sin revertir, quitar `CI_REQUIRE_INTEGRATION` del paso devuelve los skips a no bloqueantes, y volver una invocación a `psql` directo desactiva el modo estricto de ese gate.

## Open Questions

Todas resueltas por la opción recomendada (ver «Sign-off del PO»):

- **OQ-1**: ¿Dónde corre el tier? Opciones: (a) un paso final de `KPI_Validation.yml`, (b) un job nuevo en `Backend_Tests.yml`, (c) un workflow nuevo. **Recomendada: (a)** (D1).
- **OQ-2**: ¿Cómo se fuerza el fail-closed? (a) Una variable `CI_REQUIRE_INTEGRATION=1` más hooks en el `conftest` raíz, (b) un helper por archivo. **Recomendada: (a)** (D2).
- **OQ-3**: ¿Qué se hace con los tests de ARCA? (a) Un marker `arca` excluido por expresión, (b) renombrar el marker de los de Postgres. **Recomendada: (a)** (D3).
- **OQ-4**: ¿Cómo se vuelven estrictas las degradaciones? (a) Un wrapper sobre la salida de psql con allow-list, (b) una conversión dentro del SQL. **Recomendada: (a)** (D6).
- **OQ-5**: ¿Cuál es el alcance del modo estricto? (a) Los 33 gates de dinero, (b) los 74. **Recomendada: (a)**. Los 41 restantes quedan como candidato.
- **OQ-6**: ¿Qué cobertura mide el tier? (a) Ninguna, (b) un `coverage combine`. **Recomendada: (a)** (D8).
- **OQ-7**: ¿Hasta dónde se migran los 12 archivos al fixture? (a) Sólo DSN y conexión (mecánico), (b) también los `world`. **Recomendada: (a)** (D4).
- **OQ-8**: ¿Qué se hace con `test_payment_methods_seed` (1)? (a) Arreglar el gate con un ancla propia, (b) agregarlo a la allow-list. **Recomendada: (a)** (D7).

## Sign-off del PO

Por **mandato permanente del PO del 2026-11-04** («siempre la opción recomendada»), las ocho OQs quedan resueltas por su opción recomendada: OQ-1 (a), OQ-2 (a), OQ-3 (a), OQ-4 (a), OQ-5 (a), OQ-6 (a), OQ-7 (a) y OQ-8 (a). Governance **MEDIO** (CI y proceso: no escribe dinero real, no toca producción ni datos). Volver obligatorio el check en branch protection queda como paso manual del PO (task 5.5), porque el agente no tiene permiso sobre la configuración del repositorio.
