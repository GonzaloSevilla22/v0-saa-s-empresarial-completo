# integration-test-tier Specification

## Purpose
Define el tier de tests de integración reales contra Postgres que corre en CI en cada pull request, y los gates SQL de dinero que lo acompañan en modo estricto. Garantiza que los flujos que mueven dinero se ejerciten contra la base real con la cadena completa de migraciones, falle cerrado si el tier no corre, y que una rama de degradación nueva no pase inadvertida.
## Requirements
### Requirement: Los tests de integración contra Postgres corren en CI en cada PR
El CI SHALL ejecutar en cada pull request contra `main` todos los tests del backend marcados `integration` que no estén marcados `arca`, contra un Postgres real levantado con `supabase start` y con la cadena completa de migraciones aplicada, en un paso con nombre propio de un workflow sin filtro de rutas, para que el check reporte en todo PR. Ese paso SHALL correr aunque un paso anterior del mismo job haya fallado, salvo que la corrida se cancele.

#### Scenario: Un PR cualquiera ejecuta el tier de integración
- **WHEN** se abre un pull request contra `main`, aunque sólo toque archivos de `frontend/`
- **THEN** el job `validate-kpis` de `KPI_Validation.yml` ejecuta el paso del tier de integración con `pytest backend/tests -m "integration and not arca"` contra `127.0.0.1:54322`, y el resultado de ese paso queda visible con su propio nombre en el log

#### Scenario: Un gate SQL anterior falla
- **WHEN** un gate SQL de `KPI_Validation.yml` falla antes del paso del tier de integración
- **THEN** el paso del tier de integración igual se ejecuta y reporta su propio resultado en la misma corrida

#### Scenario: Una regresión en un repositorio de dinero rompe un test de integración
- **WHEN** un PR cambia la firma o el SQL que un repositorio de dinero envía a la base, de modo que la llamada real falla contra Postgres
- **THEN** el test de integración que ejercita ese repositorio falla y el job queda en rojo, aunque los tests herméticos con `asyncpg` mockeado sigan en verde

### Requirement: En CI un test de integración no puede saltearse en silencio
Cuando la variable de entorno `CI_REQUIRE_INTEGRATION` vale `1`, la suite del backend SHALL tratar como falla todo test marcado `integration` y no marcado `arca` que termine salteado, en cualquier fase (setup, llamada o teardown). SHALL abortar la sesión con código distinto de cero si la base no responde antes de recolectar los tests, y si la selección no contiene ningún test `integration`. Ningún test de este tier SHALL llevar `xfail`. Sin esa variable, el comportamiento SHALL ser el actual: el test se saltea cuando no hay Postgres local.

#### Scenario: Postgres no está disponible en CI
- **WHEN** el paso corre con `CI_REQUIRE_INTEGRATION=1` y `DATABASE_URL` apunta a un Postgres que no responde
- **THEN** la sesión de pytest termina con código distinto de cero, con un mensaje que nombra el DSN sin credenciales y la causa, antes de ejecutar ningún test

#### Scenario: Un test de integración se saltea en CI
- **WHEN** con `CI_REQUIRE_INTEGRATION=1` un test marcado `integration` ejecuta `pytest.skip(...)`, directamente o desde un fixture
- **THEN** el reporte de ese test es `failed` e incluye el motivo original del skip

#### Scenario: Corrida local sin Postgres
- **WHEN** un desarrollador corre `pytest -m integration` sin `CI_REQUIRE_INTEGRATION` y sin `supabase start`
- **THEN** los tests de integración contra Postgres se saltean con el motivo «Postgres local no disponible», sin errores de conexión

#### Scenario: La expresión de selección no encuentra ningún test
- **WHEN** con `CI_REQUIRE_INTEGRATION=1` la expresión `-m` no selecciona ningún test marcado `integration`
- **THEN** la sesión termina con código distinto de cero en lugar de reportar «0 tests» en verde

### Requirement: Los tests que necesitan ARCA real se distinguen y nunca corren en CI
Los tests que requieren credenciales o el servicio real de ARCA SHALL llevar el marker `arca`, declarado en `backend/pyproject.toml`, además de `integration`. El tier de integración de CI SHALL excluirlos por expresión, y su skip SHALL quedar exento de la conversión a falla.

#### Scenario: Test de homologación de WSFE
- **WHEN** el tier de CI recolecta `backend/tests/test_c31_wsfe_homologacion_wiring.py`
- **THEN** el test de homologación real (§7.1) no se selecciona por llevar `arca`, y los tests sin marker del mismo archivo siguen corriendo en el job hermético

### Requirement: El fixture canónico de integración sólo opera contra una base local
Los tests de integración contra Postgres SHALL obtener el DSN y abrir la conexión con el módulo canónico `backend/tests/integration_db.py`. Ese módulo SHALL rechazar, al conectar y en el preflight de la sesión, cualquier DSN cuyo host no sea `localhost`, `127.0.0.1` o `::1`. Importar el módulo SHALL NOT validar ni conectar, para no afectar la recolección del job hermético.

#### Scenario: DATABASE_URL apunta a un host remoto
- **WHEN** `DATABASE_URL` apunta a un host distinto de `localhost`, `127.0.0.1` o `::1` y un test de integración intenta conectar
- **THEN** la conexión se rechaza con un error explícito antes de abrir ningún socket, y en CI la sesión aborta en el preflight

#### Scenario: El job hermético recolecta con un DATABASE_URL remoto en el entorno
- **WHEN** el job `Backend Tests` (`-m "not integration"`) recolecta los módulos de integración con un `DATABASE_URL` remoto exportado
- **THEN** la recolección no falla y ningún test hermético se ve afectado

#### Scenario: Un test nuevo de integración reutiliza el fixture
- **WHEN** se agrega un test de integración contra Postgres
- **THEN** importa `DSN`, `connect` y, si inyecta claims, `set_claims` de `backend/tests/integration_db.py`, en lugar de redefinir el DSN o llamar a `asyncpg.connect` directamente

### Requirement: Los flujos de dinero de H-34 tienen un test de integración a través de su repositorio
El tier de integración SHALL incluir al menos un test por cada flujo de dinero de H-34 que se ejecute a través del repositorio real del backend contra Postgres, con una cuenta sintética propia y residuo cero al terminar: arqueo de caja, conciliación bancaria, partida doble generada por el dispatcher del outbox y webhook de suscripciones. Sus aserciones SHALL leer los valores calculados por la base y SHALL NOT depender de conteos globales de otras cuentas.

#### Scenario: Arqueo con faltante
- **WHEN** el test abre una sesión de caja con saldo inicial, registra un movimiento de efectivo y la cierra con un conteo menor que el esperado vía `CashSessionRepository`
- **THEN** la sesión cerrada tiene `expected_balance`, `counted_balance` y `difference` calculados por la base con el faltante exacto, y un segundo cierre de la misma sesión se rechaza

#### Scenario: Conciliación con match deshecho
- **WHEN** el test importa un extracto, abre una sesión de conciliación, crea un match de una línea, lo deshace y cierra la sesión vía `BankReconciliationRepository`
- **THEN** cada RPC devuelve el estado esperado y la línea del match deshecho vuelve a estar disponible para conciliar

#### Scenario: Asiento balanceado e idempotente desde el outbox
- **WHEN** el test registra una venta y ejecuta `OutboxRepository.run_dispatch()` dos veces
- **THEN** existe exactamente un asiento para esa venta, la suma del debe de sus líneas es igual a la suma del haber, y la segunda corrida no agrega asientos para ese evento

#### Scenario: Webhook de suscripción
- **WHEN** corre el tier de integración
- **THEN** los tests de `test_subscriptions_webhook_handlers_integration.py` y `test_subscriptions_apply_approved_charge_integration.py` se ejecutan contra la base real

### Requirement: Los gates SQL de dinero no pueden degradar en silencio en CI
Los gates SQL de dinero (caja, banco, asiento, outbox, cuenta corriente, cobranzas, formas de pago, compras y gastos con dinero, suscripciones), enumerados en el `design.md` de este change, SHALL ejecutarse en CI con `scripts/ci/run_gate_strict.py`. El wrapper SHALL conservar el código de salida de `psql -v ON_ERROR_STOP=1` y además SHALL fallar si la salida del gate contiene un `NOTICE` de degradación escrito por ese gate que no figure en `scripts/ci/gate_degradation_allowlist.txt`. Toda entrada de la allow-list SHALL declarar un motivo de entorno; la falta de un dato sembrado o de una cuenta ancla SHALL NOT ser un motivo admitido. Toda rama de degradación nueva en un gate de dinero SHALL emitir un mensaje que empiece con `GATE` y contenga `DEGRADED` o `degradado`.

#### Scenario: Un gate de dinero degrada por falta de precondición
- **WHEN** en CI un gate de dinero emite `NOTICE:  GATE … degradando sin abortar.` porque no pudo aprovisionar su cuenta ancla
- **THEN** el paso falla y el log lista el archivo, la línea y el mensaje de cada degradación encontrada

#### Scenario: Degradación de entorno declarada
- **WHEN** un gate de dinero emite una degradación cuyo archivo y subcadena figuran en la allow-list con un motivo de entorno
- **THEN** el paso no falla por esa línea y el wrapper la reporta como degradación permitida

#### Scenario: Ruido que no escribe el gate
- **WHEN** la salida del gate contiene `NOTICE`s de triggers del producto (`send_email_log_webhook: … skipping`), de `DROP … IF EXISTS` (`does not exist, skipping`) o de migraciones incluidas
- **THEN** el wrapper no los cuenta como degradaciones

#### Scenario: El detector reconoce todas las ramas existentes
- **WHEN** corre la prueba unitaria del detector sobre los `RAISE NOTICE` de degradación de los gates de dinero
- **THEN** cada uno de ellos es reconocido como degradación y ninguna línea `PASS`/`PASSED` lo es

#### Scenario: El gate de siembra de formas de pago ejercita su bloque (1)
- **WHEN** `test_payment_methods_seed.sql` corre en CI con el wrapper estricto
- **THEN** su bloque (1) verifica la siembra sobre al menos una cuenta creada por el propio gate y no emite la degradación «no hay cuentas en el stack»

### Requirement: El tier de integración no altera el piso de cobertura del job hermético
El paso del tier de integración SHALL NOT medir cobertura ni combinarla con la del job `Backend Tests`. El piso del 87% SHALL seguir midiéndose sólo sobre la suite hermética (`-m "not integration"`).

#### Scenario: Corre el tier de integración
- **WHEN** se ejecuta el paso del tier de integración en `KPI_Validation.yml`
- **THEN** el comando no incluye `--cov`, y el umbral `--cov-fail-under=87` de `Backend_Tests.yml` no cambia

