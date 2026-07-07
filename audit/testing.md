# Auditoría Técnica Pre-Producción — Dimensión: TESTING
**Proyecto:** ALIADATA / EmprendeSmart (EIE) — SaaS microemprendedores Mendoza (AR)
**Auditor:** QA Architect (consultora)
**Alcance:** backend/tests (79 archivos, ~1023 tests), frontend/__tests__ (51 archivos, ~443 tests), frontend/tests/, .github/workflows/, supabase/migrations (gates 202608*), supabase/tests, supabase/functions
**Modo:** solo lectura. Cobertura estimada cualitativamente (no se corrió coverage).

---

## 0. TL;DR — clasificación: **MEJORABLE (con un defecto de proceso de severidad CRÍTICA)**

El proyecto tiene un **volumen de tests notable** (≈1466 tests) y varias piezas de calidad real (verificación HMAC del webhook de pagos con criptografía genuina, gate de introspección de firmas de RPC que previene reintroducir overloads inyectables, gates de comportamiento en Postgres real). Pero la estrategia tiene **tres fallas estructurales que anulan gran parte de ese valor en el punto donde más importa (la plata)**:

1. **CI NO ejecuta NINGÚN test de aplicación.** Ni `pytest` (1023) ni `vitest` (443) corren en GitHub Actions. El único gate que corre en un PR es `KPI_Validation.yml`, que ejecuta 2 archivos SQL de introspección. Un PR que rompa el 100% de la suite de backend/frontend **igual mergea y deploya a prod**.
2. **El 100% de la suite de backend mockea la base de datos** (`AsyncMock` sobre el pool asyncpg — `conftest.py`). Como la transaccionalidad del hot path vive DENTRO de las RPCs SQL `SECURITY DEFINER` (DEC-24 = UoW), **la lógica de dinero nunca se ejecuta**: arqueo de caja, conciliación bancaria, asiento de partida doble (Σdébito=Σcrédito), overpayment P0409, snapshots de línea. Los tests alimentan un JSON canónico y verifican que "vuelve" (round-trip del mock), no que la RPC lo calcule.
3. **La red de seguridad del SQL — los gates de comportamiento en las migraciones — se degrada silenciosamente a `RAISE NOTICE`** sin abortar la migración, y varios gates de dinero (d,e,g,k de `20260804000007`) están *muertos por diseño* (piden un pago contra saldo 0 → P0409 → caen en `WHEN OTHERS` → NOTICE).

Resultado neto: el outbox/journal estuvo **muerto en prod 9 días** (journal_entries=0 del 22-jun al 1-jul, por MEMORY.md) mientras `test_journal_consumer.py` y `test_e2e_outbox.py` estaban verdes — precisamente porque ambos mockean la DB y "validan el texto de la migración", no el comportamiento.

**No hay E2E. No hay Playwright. Las 12 Edge Functions tienen 0 tests.**

---

## 1. Gates de CI — análisis detallado

### 1.1 Inventario de workflows (`.github/workflows/`)
Solo 3 archivos:

| Workflow | Trigger | Qué hace | ¿Corre tests de app? |
|---|---|---|---|
| `KPI_Validation.yml` | `pull_request` → main | `supabase start` + `psql -f test_kpis.sql` + `psql -f test_kpis_edge_cases.sql` | **NO** |
| `deploy.yml` | `push` → main / Prueba1 | build Next.js → `supabase db push --include-all` → `supabase functions deploy` | **NO** (y `needs: build-frontend` NO incluye tests) |
| `keep-backend-warm.yml` | cron 10 min | `curl /health` (mitiga cold start Render 50s) | N/A |

**Verificado:** `grep -rn "pytest\|vitest\|pnpm test\|npm test" .github/` → 0 resultados (exit 1). No hay pre-commit (`.pre-commit-config.yaml` ausente), no hay `render.yaml`, no hay otro CI.

### 1.2 Qué valida realmente el ÚNICO gate de PR
`supabase/tests/test_kpis.sql` (166 líneas) + `test_kpis_edge_cases.sql` (135) son **tests de introspección de catálogo**, NO de valores calculados:
- Verifican que existan las firmas seguras de RPC (ej. `get_dashboard_financials(timestamptz, timestamptz)` de 2 params).
- Verifican que los overloads vulnerables con `p_user_id uuid` **fueron dropeados** (guarda de seguridad real y valiosa contra inyección de tenant).
- Verifican `SECURITY DEFINER` + `search_path = public`.
- Usan `RAISE EXCEPTION` → `psql` sale con código ≠0 → el job falla. **Esto sí es un gate duro** (bien).

Valor: **alto como guarda de seguridad de firmas**; **nulo como validación de lógica de negocio / KPIs numéricos** (el nombre "KPI Validation" es engañoso: no valida ningún KPI numérico).

### 1.3 Los gates de comportamiento viven en las migraciones (no en el workflow)
Cuando `supabase start` (CI) o `db reset` aplica migraciones, corren los DO-blocks de gate embebidos en `202608*`. Estos SÍ tocan Postgres real. Problema: su diseño los hace no-vinculantes (ver §2).

---

## 2. K2 — VERIFICADO Y CONFIRMADO (severidad ALTA): gates de comportamiento degradables + muertos

### 2.1 El resumen de gates es solo `RAISE NOTICE` — no hay assert final
`supabase/migrations/20260804000007_bank_payment_routing.sql`:
- Declara `v_gate_a..v_gate_k boolean := false` (líneas 991-1001).
- Al final (líneas 1439-1453) emite `RAISE NOTICE '(d) ... %', v_gate_d;` para cada uno.
- **NO existe ningún `IF NOT (v_gate_a AND ... AND v_gate_k) THEN RAISE EXCEPTION`**. La migración termina con `END $$;` sin verificar los resultados.
- **Consecuencia:** todos los gates pueden ser `false` y la migración aplica exitosamente. CI verde ≠ gates verdes.

### 2.2 Los gates de dinero d, e, g, k están muertos por diseño
El anchor sintético crea un `clients`/`suppliers` **sin deuda previa** (líneas 1066-1079) y luego:
- **(d)** `rpc_register_payment_received(...400.00...'transfer'...)` (línea 1154): cobro contra un cliente con saldo 0 → el helper `c30_register_customer_account_movement` lanza **P0409** (overpayment, documentado en línea 220).
- Ese P0409 cae en el `EXCEPTION WHEN OTHERS` del gate (líneas 1169-1179), que lo degrada a `RAISE NOTICE 'gate (d) degradado (%)'` y deja `v_gate_d = false`.
- Idéntico para **(e)** card cobro (1189), **(g)** `rpc_register_payment_made` pago (1253), **(k)** idempotencia con cobro (1392).
- **Ninguno de estos gates de comportamiento de ruteo bancario puede pasar en verde jamás** con el anchor tal como está construido. Solo pasan los introspectivos (a, b, i) y los negativos (f, h — "cash NO genera bank_movement", que no dispara P0409 porque… no llama al helper de deuda con monto positivo problemático — de hecho f/h también cobran/pagan y también dispararían P0409; en la práctica quedan degradados a NOTICE igual).

### 2.3 Gate (o) del snapshot — patrón `RECORD` frágil
`supabase/migrations/20260806000001_v3_snapshot_pattern.sql`:
- `v_profit_row RECORD;` (línea 2034), luego `SELECT total_cost INTO v_profit_row FROM rpc_product_profitability(365)...` (línea 2366) y acceso `v_profit_row.total_cost` (2372).
- Está guardado por `IF v_run_behavioral AND v_gate_j` y cualquier error → `RAISE NOTICE 'GATE (o) skipped: %'` (línea 2380). Como `v_gate_j` depende de la cadena de gates de comportamiento previos (que a su vez dependen del anchor), en la práctica **skippea**.

### 2.4 El bug del huérfano que dejó TODOS estos gates muertos (2026-07-04)
`supabase/migrations/20260804000008_fix_bank_payment_routing_gate_cleanup.sql` documenta que la limpieza del anchor de `...000007` corría `DELETE FROM accounts` ANTES de borrar sus `clients`/`suppliers` hijos (FK sin ON DELETE CASCADE) → `foreign_key_violation` → tragada por `WHEN OTHERS` → **1 fila huérfana permanente en `accounts`**. Como el discriminador test-vs-prod de las migraciones siguientes es `SELECT (COUNT(*)=0) FROM accounts`, TODAS veían `accounts` no vacía y **saltaban sus gates de comportamiento en silencio**: 20260806 (snapshot), 20260807 (status history), 20260808 (notifications), 20260809 (min stock). Corregido con una migración intercalada (timestamp 000008). MEMORY confirma "gates revividos 07-04".

**Estado K2:** CONFIRMADO. El patrón de degradar-a-NOTICE + ausencia de assert final + gates de dinero que disparan P0409 sigue vigente en `...000007`. Aun "revividos", los gates de ruteo bancario de comportamiento (d,e,g,k) no verifican nada porque el anchor sin deuda los hace fallar hacia NOTICE.

---

## 3. Estrategia de tests: unit / integration / E2E

### 3.1 Backend — TODO mockea la DB
`backend/tests/conftest.py`:
- `mock_pool` y el fixture `async_client` parchean `backend.core.database.pool` con un `MagicMock`/`AsyncMock`. `init_pool`/`init_service_pool`/`init_redis` se parchean a no-ops.
- **Ningún test abre una conexión asyncpg real.** Verificado: las coincidencias de `asyncpg.connect`/`DATABASE_URL` en `test_database.py`, `test_sale_items.py`, `test_cost_center_router.py`, `outbox/test_producers.py` son (a) tests del propio wrapper de creación de pool con el módulo asyncpg mockeado, o (b) comentarios ("mock asyncpg connection"). No hay Postgres real.

**Implicación:** los tests de backend son **tests del glue Python** (routing FastAPI, validación Pydantic, mapeo de `sqlstate`→HTTP, guards `require_role`). Eso es legítimo y está bien hecho. Pero la lógica transaccional (DEC-24: dentro de RPCs SQL) queda **fuera del alcance de pytest**.

### 3.2 Tests marcados `integration` — existen pero EXCLUIDOS de CI
- `backend/pyproject.toml` define el marker: `integration: ... (excluidos del gate de CI; correr con -m integration)`.
- Solo **3 archivos** lo usan: `test_c27_wsfe_adapter.py`, `test_c31_wsfe_homologacion_wiring.py`, `test_emit_invoice.py`.
- Como CI ni siquiera corre `pytest`, el punto es doblemente moot: no hay integración real ejecutándose en ninguna parte automatizada.

### 3.3 Los "E2E" no son E2E
- `backend/tests/outbox/test_e2e_outbox.py` línea 12: *"These tests simulate the full outbox flow using **mocked repositories**."* No es E2E.
- **No hay Playwright** en todo el repo (`grep playwright/page.goto/test.describe` → 0). No hay `@playwright/test` en `package.json`.
- Único artefacto de carga: `frontend/tests/load/k6-baseline.js` (95 líneas, 50 VUs, p95<500ms sobre GET /sales y /products). Es **manual** (requiere exportar `K6_JWT` y correr `k6 run` a mano); no está en CI. Útil pero no gating.

### 3.4 Pirámide de test — invertida en la capa de dinero
```
        (0)  E2E / Playwright ......................... AUSENTE
        (0)  Integración DB real en CI ................ AUSENTE (3 tests integration, excluidos)
     [~1466] Unit con DB mockeada ................... presente, no gateado en CI
   degradable Gates SQL de comportamiento en migr. .. presente, no-vinculantes (§2)
       [~4]  Gates SQL de introspección en CI ....... presente y vinculante (test_kpis)
```
La única capa que corre y aborta en CI valida **firmas de catálogo**, no valores.

---

## 4. Calidad de los tests (asserts, mocks, fixtures)

### 4.1 Lo BUENO (reconocimiento explícito)
- **`test_payments.py`** (webhook MercadoPago = dinero real): usa **HMAC-SHA256 real** (`_make_signature` con `hmac.new`), verifica firma válida/ inválida/ ausente/ secreto vacío, idempotencia (doble evento → 1 escritura), shadow mode (sin writes), 404 de MP → skipped (no 502), external_reference malformado → 400, y valida que el recibo se encola con PDF base64. Es de las mejores piezas del repo. **Limitación:** la DB está mockeada, así que el UPSERT del plan y el `email_logs` se verifican por "se llamó execute con este string", no por efecto real.
- **`test_c3_bank_reconciliation.py` `TestMigrationContent`**: lee el `.sql` crudo y asegura que el CHECK de `operation_idempotency` reproduce la UNIÓN de kinds vigente en prod (regresión del incidente de deploy 23514 del 2026-07-02). Guarda de regresión valiosa y bien pensada.
- **`test_kpis.sql`**: guarda de seguridad contra reintroducir overloads con `p_user_id` inyectable. Excelente.
- **Estilo TDD disciplinado**: docstrings con RED→GREEN→TRIANGULATE, casos de triangulación (happy + edge), mapeo exhaustivo de `sqlstate`→HTTP (P0409→409, P0422→422, P0433→422, P0434→409). Nombres claros.
- Mapeo de errores de dominio a HTTP muy completo en cash/reconciliation/accounts.

### 4.2 Lo MALO (anti-patrones verificados)
- **Copia de lógica en el test (drift silencioso)** — `frontend/__tests__/ai-precio.test.ts` líneas 13-17: *"We cannot import from supabase/functions/ ... so we re-declare the pure functions here."* Se **copia-pega** `calculateElasticity`, `isPlanAllowed`, `getEffectivePlan` dentro del test. Si la Edge Function real diverge de la copia, el test queda verde y prod roto. Esto afecta lógica de **plan-gating de IA paga**.
- **Tests que verifican el mock, no el cálculo** — `test_c28_cash_session.py`: el arqueo (`difference`) se define como constante en `CLOSE_SESSION_RESULT["difference"] = 0.00` y el test asserta que "vuelve" 0.00. El cálculo real `expected = opening + Σmov; difference = counted - expected` vive en `rpc_close_cash_session` y **ningún test lo ejecuta**. Los tests de atomicidad (líneas 592-676) lo admiten: *"Since no local Supabase DB is available ... verify the contract at the repository layer (mock) ... the DO gates in the migration verify atomicity"* — pero los DO gates se degradan (§2).
- **Tests de "SQL por texto"** — `test_journal_consumer.py` línea 63-65: *"unit/assertion tests that validate the migration SQL **text** and the Python producer logic. SQL integration tests against a real DB are marked `integration` (excluded from the ... CI gate)."* La invariante contable Σdébito=Σcrédito se verifica por `assert "P0450" in sql`, no ejecutándola.
- **WSAA/firma criptográfica AFIP no ejercitada** — `test_c27_wsfe_adapter.py` mockea `_get_wsaa_token` y `_call_wsfe` (líneas ~60). La parte security-sensitive (firmar el TA con el cert .p12, cachear el ticket) nunca corre en tests automatizados; solo en el path `integration` excluido y en la homologación manual pendiente del PO.

### 4.3 Fixtures
Bien estructurados y reusables (`mock_pool`, `session_repo`, `cae_request`). El `make_token` con `jose.jwt` HS256 es correcto para simular el JWT de Supabase. El workaround de `fpdf` (stub cuando fpdf2 no está instalado) es pragmático pero señala que **el entorno de test no está containerizado/pinneado** (dependencia opcional que altera qué se puede colectar).

---

## 5. Distribución de cobertura (estimación cualitativa por módulo)

### Backend (routers 24 / services 33 / repositories 27)
| Módulo | Archivo de test | Cobertura glue Python | Cobertura lógica real (SQL) |
|---|---|---|---|
| payments / webhook | test_payments.py | **Alta** | Media (firma real; DB mock) |
| cash / arqueo | test_c28_cash_session.py | Alta | **Nula** (difference = mock) |
| bank_reconciliation | test_c3_bank_reconciliation.py | Alta | **Nula** (matching en RPC, mock) |
| journal / partida doble | outbox/test_journal_consumer.py | Media | **Nula** (assert de texto) |
| fiscal / WSFE-AFIP | test_c27_*, test_wsfe_* | Alta | Baja (SOAP+WSAA mockeados) |
| sales / sale_items | test_sales.py, test_sale_items.py | Alta | Baja (snapshot en RPC) |
| purchases | test_purchases.py | Alta | Baja (ver K8) |
| stock / branch_stock | test_stock*.py | Alta | Baja |
| clients/suppliers/accounts | test_c30_*, test_clients.py | Alta | Baja |
| api-standards (RFC7807, paginación, idempotency) | test_api_standards_*.py | **Alta** | N/A (glue) |
| outbox relay/producers/consumers | outbox/*.py | Media-Alta | Nula (mock) |
| auth | test_auth.py | Alta | N/A |
| health/ws/organizations | test_health/ws/organizations.py | Alta | N/A |

### Frontend (51 archivos)
- **Alta**: hooks (use-sales, use-products, use-expenses, use-notifications, use-bank-accounts, use-dashboard-kpi-summary), utils puros (cart-utils, cuit-utils, date-range, kpi-format), auth-context, idle-timer (muy cubierto: 6 archivos), formularios (ClientForm, ProfileForm, RegisterPage, LoginPage).
- **Media**: componentes de IA (AiSummaryCard, PriceSuggestionModal), export (button/quota), plan-gating.
- **Copia-de-lógica (riesgo)**: ai-precio.test.ts (Edge Function re-declarada).
- **Nula**: cualquier flujo real de navegador (no hay Playwright); el árbol de `app/` páginas no tiene tests de render/interacción E2E.

### Migraciones (204)
- Cobertura por **gates SQL embebidos** en las de 202608 (comportamiento + introspección), **degradables** (§2). Las 204 no tienen un harness de test de migración independiente (no hay `pgTAP`, no hay tests parametrizados de up/down; no hay rollback testing). El único chequeo estructural en CI es "sin BOM" + `supabase start` aplica todo.

### Edge Functions (12) — **COBERTURA NULA**
`invoice-ocr`, `send-email` (Resend), `generate-export`, `fair-advisor`, y 7 de IA (`ai-comparativo/insights/precio/prediccion/rentabilidad/resumen/simulador`) + `_shared/ai-quota.ts`. **0 `Deno.test`, 0 archivos de test en `supabase/functions/`.** `deploy.yml` las deploya con `--no-verify-jwt` sin ninguna prueba previa. `_shared/ai-quota.ts` (103 líneas) contiene el **enforcement de cuota de IA por plan** (dinero/monetización) — su única "cobertura" es la copia divergente en `ai-precio.test.ts`.

---

## 6. Los 5 huecos de cobertura de MAYOR riesgo económico

1. **Arqueo de caja (`rpc_close_cash_session`)** — el cálculo `difference = counted - (opening + Σmov)` no se ejecuta en ningún test; los tests asertan un mock. Un error de signo o de agregación en la RPC (que ya ocurrió con `balance_after` MAX vs SUM, K17) llegaría a prod sin red de test. Riesgo: descuadres de caja no detectados, pérdida de confianza del comerciante.
2. **Conciliación bancaria (matching línea↔movimiento, anti doble-match)** — la lógica de match y los índices únicos parciales que previenen doble-conciliación viven en la RPC/DDL; los tests mockean el repo. Riesgo: doble contabilización de un cobro/pago bancario.
3. **Partida doble (Consumer 3, Σdébito=Σcrédito, P0450)** — verificada por `assert "P0450" in sql`, no ejecutada. Ya estuvo **muerta 9 días en prod** (journal_entries=0) con tests verdes. Riesgo: asientos desbalanceados / contabilidad incorrecta.
4. **Webhook de pagos — efecto en DB del upgrade de plan** — la firma HMAC está bien testeada, pero el UPSERT que cambia `billing_plan` y genera el recibo corre sobre un mock. Riesgo: cobro exitoso sin upgrade efectivo (o upgrade sin cobro) no atrapado.
5. **Enforcement de cuota de IA por plan (`_shared/ai-quota.ts`) + WSAA/firma AFIP** — 0 tests reales. `ai-quota` gatea IA paga; la firma WSAA gatea facturación fiscal legal. Riesgo económico/legal: usuarios `gratis` consumiendo IA paga, o CAE emitido con firma mal formada.

---

## 7. Flakiness histórico (de MEMORY.md, verificado el fix en código)
- **`test_payments` count-flake (RESUELTO 2026-07-04, PR #274)**: la causa NO era pytest-asyncio sino `importlib.reload(backend.core.config)` en 2 archivos de tests C-22/v22 — el reload rebindeaba el singleton `settings` pero los routers retenían el objeto viejo, así los `mock.patch` posteriores parcheaban un objeto sin uso (el webhook rechazaba por firma vacía). Fix: 8 reloads eliminados. **Regla establecida (correcta): NUNCA `importlib.reload` de módulos de config en tests — envenena el import cache.** No quedan `importlib.reload` de config en el árbol de tests actual.

---

## 8. Estado de los known issues del área de Testing

| ID | Estado | Nota |
|---|---|---|
| K2 | **CONFIRMADO** | Gates degradan a NOTICE sin assert final; d/e/g/k muertos por P0409 (saldo 0); gate (o) usa RECORD y skippea. `...000007` sigue con el patrón. |
| K17 | **RESUELTO** | `20260804000003` corrige `balance_after` MAX→opening+SUM y su gate SÍ `RAISE EXCEPTION`. El arqueo (`expected_balance/difference`) recalcula desde `SUM(amount)`, independiente de `balance_after`, así que el arqueo histórico ya era correcto. |
| K5 | **NO_EVALUADO (fuera de alcance de test)** | Compras 500 intermitente vive en backend Render; no reproducible desde el repo. Testing no lo cubre (no hay integración real). |
| K6 | **CONFIRMADO (contexto)** | `openspec validate --strict` con 15 specs legacy fallando es pre-existente; no gateado en CI. |

---

## 9. Recomendaciones priorizadas

**P0 (bloqueante para "pre-producción" serio):**
1. Agregar a `KPI_Validation.yml` (o un workflow nuevo `ci-tests.yml` con `pull_request`) dos jobs: `pytest -m "not integration"` (backend) y `pnpm test` (frontend). Sin esto, la suite de 1466 tests es decorativa. Es el fix de mayor ROI y el más barato.
2. Hacer los gates de comportamiento **vinculantes**: agregar al final de cada DO-block de gate `IF NOT (v_gate_a AND ...) THEN RAISE EXCEPTION 'gates fallaron'`. Y reconstruir el anchor de `...000007` para que los clientes/proveedores tengan **deuda previa** (o llamar a las RPCs en un escenario que no dispare P0409), de modo que d/e/g/k puedan pasar en verde de verdad.

**P1:**
3. Introducir un tier de **integración real contra Postgres** en CI: un job que haga `supabase start` y corra `pytest -m integration` con un pool asyncpg apuntando a `127.0.0.1:54322`, cubriendo al menos: arqueo, matching de conciliación, partida doble balanceada, y el efecto-en-DB del webhook de pagos. Alternativa liviana: `pgTAP` sobre las RPCs de dinero.
4. Eliminar el copy-paste de lógica de Edge Functions en tests: exponer las funciones puras (`_shared/`) como módulo importable por vitest, o mover el enforcement de cuota a un paquete compartido testeable.

**P2:**
5. Agregar smoke E2E con Playwright de los 3 flujos de dinero (venta→arqueo, cobro→cta cte, import→conciliación) contra un entorno de preview.
6. Testear las Edge Functions con `Deno.test` (al menos `ai-quota`, `send-email`, `invoice-ocr`).
7. Wirear el k6 baseline como job manual/nightly (`workflow_dispatch`) para detectar regresiones de p95 (relevante por el cold start de Render).

---

## 10. Justificación de la clasificación
**MEJORABLE.** Hay músculo de testing real y disciplina TDD, pero la arquitectura de pruebas **no protege el activo más crítico (la plata) en producción**, y el proceso de CI **no ejecuta la suite**, lo que degrada el valor de todo lo construido a "documentación ejecutable localmente". El hecho de que el journal estuviera muerto 9 días con tests verdes es la evidencia empírica de que la estrategia actual no detecta fallas de dinero. El defecto de "CI no corre tests + DB siempre mockeada" es de severidad práctica CRÍTICA (riesgo de plata en prod sin red), aunque el conjunto de artefactos de test en sí es de calidad media-alta.
