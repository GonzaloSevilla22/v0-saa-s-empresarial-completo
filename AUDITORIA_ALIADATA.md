# Auditoría Técnica Integral Pre-Producción — ALIADATA (EmprendeSmart / EIE)

**Informe final de consultoría · Firma del Principal Consultant**

---

## Portada y metadata

| Campo | Detalle |
|---|---|
| **Proyecto** | ALIADATA / EmprendeSmart (EIE) — SaaS ERP + IA accionable para microemprendedores de Mendoza (Argentina) |
| **Tipo de informe** | Auditoría técnica integral pre-producción (10 dimensiones) |
| **Fecha de emisión** | *(sin fecha asignada por el orquestador)* |
| **Estado del producto** | MVP en producción con usuarios reales (29 cuentas); objetivo comercial de crecimiento: junio 2026 |
| **Proyecto Supabase auditado (PROD, read-only)** | `gxdhpxvdjjkmxhdkkwyb` |
| **Firma** | Principal Consultant (consolidación, ponderación y priorización global) |

### Alcance auditado

Repositorio completo del monorepo, con verificación en vivo (solo lectura) contra la base de datos de producción:

- **Frontend**: 433 archivos TS/TSX (Next.js 16 App Router + React 19 + TypeScript 5.7, ~58.500 líneas).
- **Backend**: 205 archivos Python (FastAPI, arquitectura 3 capas: 24 routers / 33 services / 27 repositories / 22 schemas, ~12.700 líneas).
- **Base de datos**: 204 migraciones SQL; schema real de producción (68 tablas `public` + 16 `community` = 84 tablas).
- **Edge Functions**: 11 funciones Deno (8 de IA/insights + `invoice-ocr` con visión + `generate-export` + `send-email`) más `_shared`.
- **Knowledge Base**: 11 documentos (10 canónicos KB 01–10 + modelos de dominio V2/V3).
- **Especificaciones**: 62 capabilities OpenSpec.
- **DB de producción**: acceso estrictamente read-only (SELECT + advisors + metadata; cero escrituras).

### Metodología

1. **Diez auditores especializados**, uno por dimensión: Arquitectura, Código Backend, Código Frontend, Base de Datos, Seguridad (OWASP), Performance, UX/UI, IA y preparación para agentes, Testing, Documentación.
2. **Verificación adversarial independiente** de cada hallazgo de severidad CRÍTICA y ALTA. Cada uno lleva un veredicto de verificación: `CONFIRMADO`, `AJUSTADO` (severidad corregida), `REFUTADO` (descartado) o `NO_REQUERIDA` (severidades menores). En esta auditoría **ningún hallazgo resultó REFUTADO**; varios ALTA fueron AJUSTADOS a MEDIA/BAJA tras contrastar la explotabilidad real contra la DB de producción.
3. **Contexto histórico del proyecto**: se cruzó cada hallazgo con el registro de 20 known issues (K1–K20) documentados por el equipo, la memoria de sesiones, `CHANGES.md` y las decisiones DEC-01..24.
4. **Verificación contra prod**: los auditores ejecutaron consultas de solo lectura (`pg_roles`, `pg_policies`, `pg_proc`, `pg_stat_activity`, `pg_class`, `get_advisors`, `list_edge_functions`, EXPLAIN, conteos) para confirmar o descartar cada hipótesis.

---

## 1. Resumen Ejecutivo

**Veredicto general: APTO PARA PRODUCCIÓN CONDICIONAL.** ALIADATA es un producto de **calidad de ingeniería muy por encima de la media de un MVP**: arquitectura de monolito modular con tres capas reales, RPC-as-Unit-of-Work aplicado con disciplina, outbox transaccional in-DB con consumers idempotentes, puerto/adaptador hexagonal para AFIP, snapshots inmutables, FSM-como-datos, RLS al 100% de las tablas, historial de 204 migraciones perfectamente sincronizado repo↔prod, y una base documental (KB + modelos V2/V3 + 62 specs + 24 decisiones trazables) que la mayoría de los equipos senior no logra sostener. Esa madurez es real y está verificada.

Sin embargo, la auditoría identificó **un patrón dominante y repetido en cinco dimensiones independientes**: existe una brecha entre lo que la documentación declara como red de seguridad y lo que está efectivamente desplegado en producción, y esa brecha se concentra en los dominios de **dinero, fiscalidad y aislamiento entre inquilinos** — exactamente donde el proyecto no puede permitirse fallar. El sistema "funciona hoy" porque el volumen es bajo (29 cuentas, baja concurrencia, 0 usuarios multi-cuenta, ~0 facturación fiscal real), pero varios caminos peligrosos **ya están armados** y se disparan con el primer incremento de tráfico o con la primera factura real.

### Los 8 hallazgos que más importan

1. **[H-01 · CRÍTICO] El fire-and-forget fiscal usa siempre el adapter STUB.** La próxima factura emitida por `/fiscal/documents/emit*` queda marcada `authorized` con un **CAE fabricado (falso)** que AFIP nunca emitió, en estado terminal que el cron con el certificado real nunca corrige. Riesgo fiscal/legal directo.

2. **[H-02 · CRÍTICO] Webhook de MercadoPago del upgrade roto de punta a punta.** El route handler de Next.js que recibe el pago usa cliente Supabase anónimo + cookies; la RLS de prod bloquea el `UPDATE accounts` y el `INSERT billing_events`. **Ningún pago acredita el plan automáticamente**: ya hubo un pago real de $69.900 que el PO tuvo que reconciliar a mano. Pérdida directa de ingresos.

3. **[H-03 · CRÍTICO] Edge Function `send-email` totalmente abierta con `service_role`.** Sin firma, sin JWT, sin secreto: cualquiera con la URL pública puede spoofear correos desde el dominio verificado `no-reply@aliadata.com.ar` a cualquier destinatario o a los 29 usuarios (`recipient="all_users"`). Phishing + spam masivo explotable hoy.

4. **[H-04 · CRÍTICO/proceso] CI no ejecuta ninguna suite de tests + toda la lógica de dinero se testea con la DB mockeada.** Un PR que rompa los ~1.466 tests igual mergea y deploya a prod; la aritmética de arqueo, conciliación y partida doble vive en RPCs SQL que ningún test ejecuta. Evidencia empírica: el journal contable estuvo **muerto 9 días en prod con los tests en verde**.

5. **[H-05 · CRÍTICO/ALTO] Aislamiento multi-tenant roto: el pool corre como `postgres` con `BYPASSRLS`.** La "RLS como última línea de defensa" que invocan los docstrings **no aplica al backend**. Varios endpoints by-id (quotes, sales-orders, settings de organización, cajas, cta cte) no filtran por `account_id` → IDOR de lectura y escritura cross-tenant conociendo un UUID.

6. **[H-06 · ALTO] Tres endpoints usados por el frontend devuelven 500 en prod** por leer claves inexistentes del dict `auth` (`sub`/`account_id`). Presupuestos y consulta de cuenta corriente cliente/proveedor están caídos; los 1.023 tests no lo detectan porque los overrides usan un shape falso.

7. **[H-07 · ALTO] Capa de autorización de aplicación ficticia + `cost_centers` muerta.** El rol nunca viaja en el JWT (hook no habilitado): `require_role(["user","admin"])` es no-op, `require_role(["owner","admin"])` bloquea a todos, y `require_plan` nunca se invoca. La feature de centros de costo devuelve 403 universal (0 filas en prod); el gating de plan del backend es fail-open (todos "pro").

8. **[H-08 · ALTO] Cinco RPCs admin `SECURITY DEFINER` ejecutables por `anon`** sin guard `is_admin()`: cualquiera con la anon key pública obtiene KPIs confidenciales de negocio (conversión, activación, MRR proxy) e incluso dispara funciones de mantenimiento con efectos (`expire_trials`, `process_cancellations`).

### Aptitud para producción

El sistema **ya está en producción** y opera correctamente a la escala actual gracias a mitigantes reales (bajo volumen, UUIDs no enumerables, tenancy manual `WHERE account_id` consistente en el muestreo, outbox al día). **No hay corrupción de datos activa ni fuga cross-tenant demostrada**. Pero **cuatro hallazgos CRÍTICOS tocan dinero, fiscalidad, contabilidad o comunicaciones con el usuario**, y deben remediarse **antes de crecer en usuarios o de activar la facturación fiscal a volumen**. Con el bloque P0 resuelto (esfuerzo estimado agregado: 2–3 semanas de un equipo pequeño, la mayoría fixes de bajo esfuerzo sobre infraestructura ya existente), el producto pasa de "apto condicional" a "apto pleno".

---

## 2. Estado general del proyecto — clasificación por área

| # | Área | Clasificación | Justificación resumida |
|---|---|---|---|
| 1 | **Arquitectura** | Mejorable | Diseño superior a la media (3 capas reales, RPC-as-UoW, outbox in-DB, hexagonal AFIP), pero el JWT-passthrough con RLS como red de seguridad **no funciona en prod** (postgres BYPASSRLS sobre pooler transaction-mode) y la 2ª capa de autorización está degenerada. Con H-05/H-07 resueltos sería "Muy buena". |
| 2 | **Código — Backend Python** | Mejorable | Layering disciplinado y hot path transaccional bien resuelto, pero 2 CRÍTICOS confirmados (CAE falso; aislamiento multi-tenant) y 3 endpoints rotos en prod enmascarados por tests con shape equivocado. |
| 3 | **Código — Frontend React/Next** | Mejorable | Base moderna sólida (hooks React Query tipados, middleware de auth ejemplar, POS con idempotencia), pero 1 CRÍTICO de dinero (webhook upgrade roto) + violación sistemática de la regla "NUNCA any" (~150) + doble vía de lectura + capa de hooks muerta. |
| 4 | **Base de datos (PostgreSQL/Supabase)** | Muy buena | Fundamentos verificados: 0 tablas sin PK, 0 sin RLS sobre 84 tablas, 204 migraciones sincronizadas (md5 idéntico), ledgers serializados correctos, outbox sano. Baja de "Excelente" por 5 RPCs admin legacy expuestos a `anon` y la inconsistencia estructural de líneas de documento. |
| 5 | **Seguridad (OWASP)** | Mejorable | Base sólida (RLS universal, `getUser()`, HMAC del webhook MP, secretos fuera del repo), pero 1 CRÍTICO vivo (`send-email` abierta) + drift `verify_jwt` + sin rate limiting + CORS `*`+credentials + hook de rol inerte. |
| 6 | **Performance** | Buena | Hot path bien construido (RPCs UoW, outbox con SKIP LOCKED, pool listo para pgBouncer, cta cte bien indexada). Defectos de **escala latente**, no de corrupción: patrón RLS que fuerza Seq Scan, endpoints sin paginar, bundle sin code-splitting. |
| 7 | **UX/UI** | Mejorable | Base real (shadcn/ui con criterio, POS ejemplar, empty states, es-AR consistente), con tres brechas transversales de alto conteo: accesibilidad de botones-ícono, tokens de color saltados (883 clases hardcodeadas), y RHF+Zod ausente en las formas financieras núcleo. |
| 8 | **IA y preparación para agentes** | Mejorable | Grounding sólido (métricas locales → LLM) y gating de cuota bien pensado, pero `invoice-ocr` sin techo de costo, superficie de prompt injection, cero telemetría de tokens/costo/calidad y cero evals, y outbox no extensible para automatizaciones de IA. |
| 9 | **Testing** | Mejorable | Volumen notable (~1.466 tests) y piezas de calidad real (HMAC del webhook, gate de firmas de RPC, TDD disciplinado), anuladas por tres fallas estructurales de proceso sobre el hot path de dinero (CI no corre tests, DB mockeada, gates SQL degradables). |
| 10 | **Documentación** | Buena | Documentación de decisiones y arquitectura-objetivo de calidad profesional (KB 09, modelos V2/V3, 62 specs, CLAUDE.md vivo), pero la capa descriptiva del sistema actual (KB 02/03/04, README raíz, AGENTS.md) arrastra un desfase estructural con la realidad de prod. |

**Lectura consolidada:** ninguna dimensión es "Crítica" como área (el aislamiento estructural por RLS a nivel DB está íntegro y no se halló fuga cross-tenant activa ni secreto de prod comprometido), y solo dos alcanzan "Muy buena"/"Buena" (DB y Performance, las capas más maduras). Las siete "Mejorable" comparten la misma causa raíz: **la ejecución en producción diverge de la excelente documentación de diseño**, concentrando la divergencia en los dominios de gobernanza CRÍTICA.

---

## 3. Puntos fuertes (consolidados, con evidencia)

1. **Arquitectura de capas real y disciplinada.** En 7+ slices muestreados por dos auditores independientes (arquitectura y backend): cero lógica de negocio en routers, cero SQL en services, mapeo service→repository 1:1 limpio. La regla "NO business logic in routers" del docstring de `cash.py` se cumple de verdad en ~24 routers.

2. **RPC-as-Unit-of-Work (DEC-24) consistente en el hot path.** Ventas, compras, caja, conciliación y cta cte se crean/editan/cierran vía RPCs `SECURITY DEFINER` con idempotencia (`operation_idempotency`), guards internos (`is_account_writer`) y ERRCODEs tipados P0xxx mapeados centralizadamente a RFC 7807.

3. **Fundamentos de base de datos verificados contra prod.** 0 tablas sin PK, 0 sin RLS sobre 84 tablas; 204/204 migraciones idénticas repo↔prod (md5 `9df1d95…`); ledgers append-only con `FOR UPDATE` + `opening+SUM` (no MAX), `balance_after` persistido y CHECKs de dominio; outbox con 0 eventos pendientes; 0 huérfanos en todos los spot checks de integridad referencial.

4. **Puerto/adaptador hexagonal para AFIP de libro.** `FiscalDocumentPort` (ABC + dataclasses de dominio) con `WSFEAdapter` real y `WSFEStubAdapter` inyectables por DI; el SOAP jamás cruza el ACL; relay CAE fail-closed con lease anti-doble-CAE y backstop `pg_cron`. Manejo cuidadoso del certificado (`repr`/`str` seguros, key nunca logueada).

5. **Outbox transaccional in-DB robusto.** Producers en la misma transacción del RPC (DEC-20), idempotencia por `(event_id, consumer_type)`, `FOR UPDATE SKIP LOCKED`, aislamiento por evento y autonomía total de Render (relay pure-SQL vía `pg_cron`).

6. **Middleware de auth frontend ejemplar.** `getUser()` server-side (nunca `getSession()` para decisiones de auth, documentado explícitamente), security headers completos + CSP, idle enforcement server-side con loop-safety, y gate de admin contra DB. Cero referencias a `SERVICE_ROLE` en el frontend; secretos fuera del repo (los `eyJ…` del historial son claves demo estándar de Supabase local).

7. **Firma del webhook MercadoPago robusta.** HMAC-SHA256 con `hmac.compare_digest` en tiempo constante, fail-closed sin secret/firma/request-id, idempotencia por `mercadopago_payment_id` con índice único verificado. (La implementación backend es correcta; el problema es que el flujo de upgrade aún apunta al webhook legacy de Next.js — ver H-02.)

8. **Grounding de IA correcto.** Las métricas (revenue, márgenes, elasticidad de Pearson, rotación) se precalculan en código y solo se pasan números al LLM; los prompts exigen citar números reales. El gating de cuota corre antes del costo, con incremento DB-side atómico y trial-aware.

9. **Documentación y trazabilidad excepcionales.** KB de 10 archivos + modelos V2/V3 con auditoría del código real + 24 decisiones con trade-offs y reversiones + `CHANGES.md` con árbol de dependencias + 62 specs + migraciones con governance/rationale/rollback/decisiones de PO fechadas. Memoria institucional inusual y valiosa como activo en sí mismo.

10. **Strangler fig avanzado y honesto.** Los dominios de dinero (ventas, compras, caja, bancos, cta cte, fiscal) ya viven detrás del backend; el equipo demuestra capacidad sistemática de retirar deuda (30/30 changes numerados + V2.5 + V3 al ~80%).

---

## 4. Debilidades (consolidadas)

1. **La red de seguridad multi-tenant documentada no existe para el backend.** El pool corre como `postgres` con `rolbypassrls=true` (verificado en `pg_roles`); la RLS "última línea de defensa" (DEC-13/KB-08) es inerte. La tenancy descansa exclusivamente en el filtro manual `WHERE account_id`, que falta en varios endpoints by-id.

2. **La capa de autorización de aplicación es ficticia.** El rol de app nunca viaja en el JWT (custom access token hook existe en DB pero no está habilitado en Auth de prod): todos los `require_role` son no-op o bloqueo total, `require_plan` es dead code, y el gating de plan es fail-open ("pro" para todos).

3. **Caminos "dead-but-armed" en dominios críticos.** El fire-and-forget fiscal con stub, el relay Python del outbox desincronizado (2 de 4 consumers, disparable por cualquier JWT), los endpoints de mutación de branches muertos, y `rpc_mark_event_processed` ejecutable por `authenticated` sin guard: código muerto que un llamado accidental o malicioso reactiva con consecuencias irreversibles.

4. **La estrategia de tests no protege el activo crítico.** CI no ejecuta ninguna suite de aplicación; el backend mockea la DB al 100%, dejando la lógica de dinero (que vive en RPCs SQL) sin ejecución en test; los gates de comportamiento SQL se degradan a `NOTICE` sin assert final.

5. **Erosión de la frontera del modelo híbrido.** 140 `supabase.from` + 31 `.rpc` directos desde el browser, incluyendo mutaciones ERP (branches, ajustes de stock) con endpoints backend muertos: el service layer no es choke point, y los estándares de plataforma V3 son evadibles desde el cliente.

6. **Incumplimiento de las propias reglas duras del proyecto.** "NUNCA any" violado ~150 veces en frontend; PascalCase incumplido en 87/161 componentes; RHF+Zod y Zustand declarados en el stack pero casi/nunca usados; `float` para dinero en fronteras de service pese a schemas `Decimal`.

7. **Sin observabilidad de producción.** Cero telemetría de errores del cliente (0 Sentry), cero telemetría de tokens/costo/calidad de IA, cero rate limiting en backend y Edge Functions. Los incidentes de prod (como el bug abierto K5 de compras 500) no dejan traza para triangular.

8. **Deuda de consistencia de datos en las líneas de documento.** `purchase_items` congelada mid-history (37/37 compras de julio sin líneas), `sale_items` aún no universal (flag off en 3/29 cuentas, 50 `name_snapshot` NULL, 293 `iva_rate_snapshot` NULL): dos fuentes de verdad conviviendo que bloquean C-20 Grupo 10.

---

## 5. Matriz de riesgos

| Riesgo | Probabilidad | Impacto | Mitigación |
|---|---|---|---|
| **R1 · Facturas con CAE falso ante AFIP** (H-01) | Alta (al activar facturación real) | Crítico (legal/fiscal) | Construir el adapter con `build_cae_adapter_from_settings()` en el background; gate defensivo anti-stub en producción. |
| **R2 · Pérdida de ingresos por upgrades no acreditados** (H-02) | Alta (100% de upgrades hoy) | Crítico (dinero/churn) | Apuntar `notification_url` al webhook backend funcional o mover la creación de preferencias al backend; E2E webhook→upgrade. |
| **R3 · Phishing/spam masivo desde dominio verificado** (H-03) | Media (requiere descubrir URL pública) | Crítico (reputacional/legal) | Verificar secreto de DB Webhook en `send-email`; nunca aceptar `recipient` arbitrario; fail-closed. |
| **R4 · Regresión de dinero llega a prod sin red de test** (H-04) | Media-Alta (ya ocurrió: journal muerto 9 días) | Alto | Wirear pytest+vitest en gate de PR; tier de integración real contra Postgres para arqueo/conciliación/partida doble. |
| **R5 · Fuga/manipulación cross-tenant conociendo un UUID** (H-05) | Baja hoy (UUID no enumerables, 0 multi-cuenta) → Media a escala | Crítico (confidencialidad) | Pool con rol sin BYPASSRLS + policies, o barrer todos los repos exigiendo `account_id`; test de arquitectura. |
| **R6 · 500 intermitentes en operaciones de dinero** (H-05 fail-closed / K5) | Media (crece con concurrencia) | Alto | Transacción explícita + `set_config(...,true)` transaction-local, o migrar a session pooler. |
| **R7 · Features de presupuestos y cta cte caídas** (H-06) | Certeza (roto hoy) | Alto | Fix de una línea por endpoint (`auth["user_id"]` / `Depends(get_account_id)`) + smoke E2E. |
| **R8 · Fuga de inteligencia de negocio a `anon`** (H-08) | Alta (endpoint público) | Alto | REVOKE anon/authenticated + guard `is_admin()` + `search_path` en las 5 legacy. |
| **R9 · Supresión silenciosa de asientos contables** (H-09 outbox) | Baja (dead code, sin trigger) | Alto | Eliminar/proteger el endpoint Python y `rpc_mark_event_processed`. |
| **R10 · Corrupción del ledger inmutable por borrados** (H-10) | Media (rutas activas alcanzables) | Alto | Mover el borrado a RPC con ajuste compensatorio + evento de audit/reversa. |
| **R11 · Costo OpenAI descontrolado / abuso** (H-11, sin rate limit) | Media | Medio | Quota en `invoice-ocr`; rate limiting por user_id; budget guard. |
| **R12 · Degradación de performance a escala** (H-14) | Alta (hacia junio 2026) | Medio | `.eq(account_id)` explícito en rutas Supabase-directas; índices `(account_id, date DESC)`; paginar catálogos. |
| **R13 · Descuadres de centavos por `float` en dinero** (H-16) | Baja-Media | Medio | `Decimal` end-to-end; lint que prohíba `float(` sobre montos. |
| **R14 · Cooldown de WSAA bloquea facturación a volumen** (H-13) | Media (al escalar facturación) | Medio | Implementar e inyectar `PlatformPostgresTicketCache`. |

---

## 6. Inventario de Technical Debt

### 6.1 Registro de known issues verificados (K1–K20)

Consolidación de los veredictos de los auditores sobre el registro histórico del equipo (`CONFIRMADO` = defecto vigente verificado; `RESUELTO` = ya corregido; `NO_EVALUADO` = fuera del foco de las dimensiones que lo miran).

| ID | Estado | Descripción y nota consolidada |
|---|---|---|
| **K1** | CONFIRMADO | `bank_accounts`/`cashboxes` con RLS solo-SELECT (escritura vía RPC, append-only por diseño); falta policy/RPC para UPDATE/DELETE cuando la UI lo exponga. Con el pool BYPASSRLS la policy hoy ni aplica al backend. |
| **K2** | CONFIRMADO | Gates de comportamiento en migraciones aplicadas con bugs latentes: `v_profit_row RECORD` (snapshot) y gates d–k de ruteo bancario que degradan a `NOTICE` sin abortar. Falso verde parcial en cada `db reset` de CI; sin efecto en datos de prod. |
| **K3** | CONFIRMADO | 23 `sale_items` + 18 `purchase_items` con `account_id` NULL (legacy mar-abr 2026). Backfill pendiente de decisión PO. |
| **K4** | CONFIRMADO | Flag `sale_items_rpc_v2` habilitado en 26/29 cuentas; 3 sin flag → sus ventas no escriben `sale_items` ni snapshots de línea. |
| **K5** | CONFIRMADO (abierto) | Compras 500 intermitente. Nueva hipótesis de causa raíz consistente: GUC de sesión sobre pooler transaction-mode → `auth.uid()` NULL intermitente → RPC aborta antes de escribir (encaja con "no llega a la DB"). Ver H-05. |
| **K6** | CONFIRMADO | 15/62 specs fallan `openspec validate --specs --strict` por formato legacy (falta `## Purpose`/`## Requirements`). No gateado en CI. |
| **K7** | CONFIRMADO | `products.min_stock` DEPRECATED sin DROP; el umbral real vive en `branch_stock.min_stock` per-branch. Dual-write en el importador. |
| **K8** | CONFIRMADO | `rpc_create_purchase_operation` NO escribe `purchase_items` (header plano, RN-97 vigente); `rpc_create_sale_operation` sí escribe `sale_items`. Asimetría ventas vs compras. |
| **K9** | CONFIRMADO | `account_members.role` CHECK = `('owner','admin','member')`; `allowed_role` de la FSM inerte; roles funcionales V3 (SELLER/CASHIER) inexistentes en DB. Agravado por el hook de rol no habilitado. |
| **K10** | CONFIRMADO | Backend vía Supavisor en transaction mode (`statement_cache_size=0`, 1 conn de servidor para pool min 2). Cold start de Render ~50s mitigado de facto por el cron CAE cada minuto y el keep-warm de GitHub Actions. |
| **K11** | CONFIRMADO | Enum real `units_of_measure.type` = `unit\|weight\|volume\|length\|custom` ≠ canónico V3 (`peso\|volumen\|contable`). Rename BREAKING, pendiente PO (OQ1). |
| **K12** | CONFIRMADO | `iva_rate_snapshot` NULL en 293/293 `sale_items` (`products` no tiene columna de IVA). |
| **K13** | CONFIRMADO (agravado) | Endpoints `/cuenta` sin paginación estándar por decisión de scope — pero además ROTOS en prod (`account_id=''` → 500, ver H-06). A nivel DB la paginación de movimientos sí está bien indexada. |
| **K14** | CONFIRMADO | Endpoints fiscales sin `require_idempotency_key`; idempotencia por clave natural (TOCTOU teórico benigno). |
| **K15** | CONFIRMADO (ampliado) | FSM sin enforcement DB: sin trigger BEFORE UPDATE en quotes/sales_orders/fiscal_documents; `quotes_update` permite cambiar status por UPDATE directo sin historial ni CAS. `document_status_history` = 0 filas. |
| **K16** | CONFIRMADO | Audiencia de notificaciones delegada a RLS server-side; frontend filtra solo por `account_id`. Colapso de audiencia a owners es efecto DB/RBAC. |
| **K17** | **RESUELTO** | `c28_register_cash_movement` usa `opening_balance + SUM(amount)` bajo `FOR UPDATE` (fix `20260804000003`); el arqueo nunca dependió de `balance_after`. Su gate SÍ hace `RAISE EXCEPTION` (vinculante). |
| **K18** | CONFIRMADO | `audit_logs.company_id`/`entity_type` nullable (DROP NOT NULL drift-tolerant); el Consumer 1 inserta sin esos campos. |
| **K19** | CONFIRMADO | Dos proyectos Supabase (prod `gxdhpxvdjjkmxhdkkwyb` auditado; preview `pudaxiwqhwsxuaofsqda` fuera de scope). Riesgo de drift persiste. Prod↔repo sin drift (204/204). |
| **K20** | CONFIRMADO | Pendientes externos del PO: homologación ARCA + config de verificación de email en Supabase + leaked-password protection deshabilitada. No bloquean código. |

### 6.2 Deuda técnica adicional (no capturada en K1–K20)

| Ítem | Área | Nota |
|---|---|---|
| Endpoints FastAPI muertos (mutaciones de branches, `POST /outbox/process-pending`, `OutboxRelayService`) | Arquitectura/Backend | Podar o cablear; el relay Python solo tiene 2 de 4 consumers. |
| `PurchaseRepository.create_operation_with_event` dead code | Backend | El producer vive en SQL desde `20260803000002`. |
| Redis inicializado sin consumidores; sin rate limiting | Backend/Seguridad | Infra provisionada sin retorno; retirar o implementar. |
| `pyproject.toml` (python-jose) desalineado con `requirements.txt`/código (PyJWT); sin ruff/mypy/import-linter | Backend | El enforcement de fronteras V2 declarado no existe como tooling. |
| Duplicación estructural sales/purchases y customer/supplier (~200 líneas espejo) | Backend | Extraer `OperationRepository` base. |
| Mapeo P0xxx→HTTP quintuplicado e inconsistente | Backend | Un mismo ERRCODE devuelve códigos HTTP distintos según la ruta. |
| Capa de hooks genéricos muerta (18/23 sin importadores) + `useIsMobile` duplicado + `lib/supabase/services.ts` muerto | Frontend | Limpieza de ~20 archivos, cero riesgo funcional. |
| Wizards de importación copy-paste (parseCSVText 3×, StepIndicator 4×) | Frontend | ~1.500 líneas duplicadas pese a existir `lib/import/parser.ts`. |
| Zustand declarado con 0 usos; RHF+Zod solo en 8 forms; dos sistemas de toast | Frontend | Stack declarado ≠ real. |
| 48 FKs sin índice de cobertura + 55 índices sin uso (legacy tenancy) | DB/Performance | Nulo hoy; relevante a escala. DROP de legacy sin riesgo. |
| Policy legacy company-based en `suppliers` conviviendo en OR con account-based | DB/Seguridad | Bypass silencioso latente si se repuebla `company_users` (5 filas vivas). |
| Journal de partida doble sin backfill histórico (8 entries vs ~550 documentos) | DB | Documentar fecha de corte; no usable como fuente contable histórica. |
| `_shared` de Edge Functions casi vacío: cliente OpenAI + helpers duplicados en 9 funciones | IA | Prerequisito de modularidad para V3. |
| Outbox dispatch con consumers hardcodeados (`IF event_type IN`) | IA/Arquitectura | Agregar un consumer requiere reescribir la RPC `SECURITY DEFINER`. |
| KB 02/03/04 + README raíz + AGENTS.md desactualizados | Documentación | 68 tablas vs 23–55 documentadas; README no-operativo; AGENTS.md ~4 semanas stale. |
| Directorio `undefined/` versionado por placeholder de path no resuelto | Documentación/Higiene | Consolidar outputs en `audit/`. |

---

## 7. Problemas encontrados y hallazgos importantes, por área

Los hallazgos están numerados globalmente (H-01…) y ordenados por severidad ponderada. Cada uno integra las perspectivas de todas las dimensiones que lo detectaron y refleja la severidad **post-verificación** (los AJUSTADOS ya llevan su severidad corregida).

> **Convención de severidad global:** los cuatro CRÍTICOS de dinero/fiscalidad/comunicaciones (H-01 a H-04) encabezan el orden por su impacto de negocio directo. H-05 es un CRÍTICO de área confidencialidad que fue AJUSTADO a ALTA en la dimensión Arquitectura por su modo de falla demostrable (fail-closed), pero se mantiene su gravedad CRÍTICA en la dimensión Backend por el IDOR cross-tenant; se lo trata como P0.

---

### ÁREA: Backend Python / Fiscal (gobernanza CRÍTICA)

#### H-01 · CRÍTICO · El fire-and-forget fiscal usa siempre el adapter STUB → CAE falso
- **Severidad:** CRÍTICA · **Prioridad:** P0 · **Verificación:** CONFIRMADO
- **Evidencia:** `backend/services/fiscal/fiscal_profile_service.py:437-441` instancia incondicionalmente `WSFEStubAdapter()` en `process_doc_by_id_background`; `wsfe_stub_adapter.py:39-45` retorna `is_approved=True` con un CAE fabricado por SHA-256 del `fiscal_document_id`; `cae_relay_processor.py:95-102` hace `update_authorized` incondicional; disparado por `routers/fiscal.py:273` (`/emit`) y `:301` (`/emit-subscription-payment`). En prod: 1 doc `authorized` con CAE real `86251075197091` ≠ CAE stub esperado `55125492133097` → ese doc obtuvo CAE real vía el path cron, previo al wiring del fire-and-forget.
- **Descripción:** El `BackgroundTask` corre inmediatamente tras el commit y le gana al `pg_cron` (que sí usa el adapter real). El stub aprueba con un CAE inexistente y deja el documento en estado terminal (`WHERE status='pending_cae'` en `update_authorized`/`claim_pending`), de modo que el cron con el certificado real **nunca lo reprocesa**. El comentario "si el stub falla, el cron lo reintenta" es falso: el stub nunca falla.
- **Recomendación:** construir el adapter con `build_cae_adapter_from_settings()` (mismo gate que el cron) dentro del background, o eliminar el fire-and-forget. Agregar gate defensivo en `CAERelayProcessor`: nunca `update_authorized` si `ambiente='produccion'` con adapter stub.
- **Riesgo si no se implementa:** facturas electrónicas con CAE inexistente ante AFIP/ARCA — comprobantes fiscalmente inválidos, incumplimiento regulatorio, contingencia legal/impositiva para la plataforma y los usuarios representados.
- **Impacto estimado:** toda emisión futura por esos dos endpoints (incluye la facturación de suscripciones del admin) hasta que se toque una línea.

---

### ÁREA: Frontend / Billing (gobernanza CRÍTICA)

#### H-02 · CRÍTICO · Webhook de MercadoPago del upgrade roto: pago real reconciliado a mano
- **Severidad:** CRÍTICA · **Prioridad:** P0 · **Verificación:** CONFIRMADO
- **Evidencia:** `frontend/components/billing/PlanComparison.tsx:34` → `POST /api/billing/preferences`; `preferences/route.ts:85` fija `notification_url` al webhook legacy de Next.js; `webhook/route.ts:123` usa `createClient()` anon+cookies (una llamada server-to-server de MP no trae sesión). RLS prod verificada: `account_members` SELECT exige `auth.uid()`, `accounts` UPDATE `accounts_owner_update` exige owner authenticated, `billing_events` write solo admin. En `billing_events`: un único `plan_upgraded` con reason "Reconciliacion manual: pago aprobado en MercadoPago pero el webhook no impacto… Honrado por el PO 2026-06-13" (pago real de $69.900). El backend ya tiene el webhook correcto (`backend/routers/payments.py:58`), pero el corte C-17 sigue pendiente.
- **Descripción:** El flujo de upgrade (Checkout Pro) crea preferencias cuyo webhook apunta al route handler anon; sin sesión, la RLS org-based impide leer membresía, actualizar `billing_plan` e insertar el evento. Ningún pago acredita el plan automáticamente. (La causa está sobredeterminada: el gate de firma HMAC del route legacy también puede rechazar antes de tocar RLS; el resultado observable es idéntico.)
- **Recomendación (gobernanza CRÍTICA, requiere sign-off PO):** apuntar `notification_url` al endpoint del backend (`{BACKEND_URL}/payments/webhook`) o mover la creación de preferencias al backend; retirar `app/api/billing/webhook` (o 410); verificar el secret HMAC en cada lado; E2E webhook→upgrade.
- **Riesgo si no se implementa:** cada venta de plan pagada por MP queda sin acreditar hasta reconciliación manual del PO — pérdida directa de ingresos, riesgo de contracargos, proceso insostenible al escalar.
- **Impacto estimado:** 100% de los upgrades pagos dependen de intervención manual (ya ocurrió 1 caso real). Fix de bajo esfuerzo (~1-2 días con E2E) al existir el webhook backend.

---

### ÁREA: Seguridad / Edge Functions

#### H-03 · CRÍTICO · `send-email` abierta con `service_role`: spoofing + spam masivo
- **Severidad:** CRÍTICA · **Prioridad:** P0 · **Verificación:** CONFIRMADO
- **Evidencia:** `supabase/functions/send-email/index.ts` — `Deno.serve` (l.66) sin `getUser` ni verificación de firma; solo valida `payload.type==='INSERT' && payload.table==='email_logs' && record.status==='pending'` (todo controlable por el atacante); usa `SUPABASE_SERVICE_ROLE_KEY`; `recipient` crudo del payload (l.250); `recipient='all_users'` (l.241-248) llama `auth.admin.listUsers()`. `config.toml:438-440` y `list_edge_functions` en prod: `verify_jwt=false`, ACTIVE. Inyección de HTML arbitrario vía `metadata.title`/`metadata.url` sin escape.
- **Descripción:** cualquier POST no autenticado a la URL pública envía correos marca ALIADATA desde el dominio verificado `no-reply@aliadata.com.ar` a cualquier destinatario, o a todos los usuarios, y escribe estados en `email_logs`. No hay rate-limit, secreto compartido ni firma en ningún punto.
- **Recomendación:** verificar un secreto de DB Webhook (comparación constante) o restringir a `service_role` autenticado; nunca aceptar `recipient` arbitrario; fail-closed si el secreto no coincide; escapar el HTML de `metadata`.
- **Riesgo si no se implementa:** phishing dirigido desde dominio verificado, spam masivo a los 29 usuarios reales, blacklisting del dominio de correo, agotamiento de cuota Resend.
- **Impacto estimado:** reputacional/legal alto; explotable hoy por cualquiera que conozca la URL pública.

---

### ÁREA: Testing / Proceso de CI

#### H-04 · CRÍTICO · CI no ejecuta tests + toda la lógica de dinero se testea con DB mockeada
- **Severidad:** CRÍTICA (defecto de proceso) · **Prioridad:** P0 · **Verificación:** CONFIRMADO
- **Evidencia:** `.github/workflows/` tiene 3 archivos; el único con trigger `pull_request` (`KPI_Validation.yml`) corre solo `psql -f test_kpis.sql`/`test_kpis_edge_cases.sql` (introspección de firmas de RPC); `deploy.yml` hace `supabase db push` + `functions deploy` a prod con `needs: build-frontend` sin tests. `grep pytest\|vitest .github/` = 0. `backend/tests/conftest.py` parchea el pool con `AsyncMock`; la transaccionalidad vive en RPCs SQL (DEC-24) que ningún test ejecuta (`test_c28_cash_session.py:592-614` lo admite: "no local Supabase DB… verify the contract at the repository layer (mock)"; `test_journal_consumer.py:63-65` valida el texto SQL, no el comportamiento).
- **Descripción:** un PR que rompa el 100% de los ~1.466 tests igual mergea y deploya a prod mientras pasen los 2 SQL. La aritmética de arqueo (`difference = counted - (opening + Σmov)`), el matching de conciliación, y el balance de partida doble (`Σdébito=Σcrédito`, P0450) nunca se ejecutan en test. **Evidencia empírica del riesgo:** el outbox→JournalEntry estuvo muerto 9 días en prod (`journal_entries=0` del 22-jun al 1-jul) con `test_journal_consumer` y `test_e2e_outbox` en verde. No hay E2E/Playwright; las 11 Edge Functions tienen 0 tests (incluido el enforcement de cuota de IA paga).
- **Recomendación:** (P0) agregar un job `pull_request` que corra `pytest -m 'not integration'` + `pnpm test` como required check. (P1) tier de integración real contra Postgres en CI (`supabase start` + pool asyncpg a `127.0.0.1:54322`) para arqueo, conciliación, partida doble y efecto-en-DB del webhook. Hacer vinculantes los gates SQL (`IF NOT (…) THEN RAISE EXCEPTION`).
- **Riesgo si no se implementa:** regresiones de dinero llegan a prod sin detección; el activo de ~1.466 tests queda decorativo.
- **Impacto estimado:** afecta todo cambio a main; la única red efectiva son 2 SQL de firmas + gates de migración degradables.

---

### ÁREA: Arquitectura / Backend — Aislamiento multi-tenant

#### H-05 · CRÍTICO/ALTO · El pool corre como `postgres` BYPASSRLS y varios endpoints no filtran por cuenta
- **Severidad:** CRÍTICA (Backend, por el IDOR) / ALTA (Arquitectura, AJUSTADO por el modo de falla demostrable) · **Prioridad:** P0 · **Verificación:** CONFIRMADO (Backend); AJUSTADO (Arquitectura)
- **Evidencia:** `pg_roles`: `postgres.rolbypassrls=true`; `pg_class`: tablas de negocio con `owner=postgres`, `relforcerowsecurity=false`. `backend/core/database.py:52-60` inyecta claims con `set_config(...,false)` (scope SESIÓN) fuera de transacción; `openspec/specs/asyncpg-pool/spec.md` exige `SET LOCAL` (transaccional). Endpoints sin scoping: `quote_repository.py:102-131` (GET/transition WHERE id=$1), `sales_order_repository.py:129-134`, `organization_repository.py:15-25` (UPDATE settings WHERE id=$1), `customer_account_repository.py:72-97`, `cashbox_repository.py:46-61` (INSERT en branch ajeno). Prod vía Supavisor transaction-mode verificado (`statement_cache_size=0`, 1 conn de servidor para pool min 2).
- **Descripción:** la "RLS como red de seguridad" (DEC-13/KB-08) es inerte para el backend. Dos consecuencias: **(a) IDOR cross-tenant** — un autenticado puede leer/mutar recursos de otra cuenta (transición de quote ajeno, UPDATE de settings de otra org, INSERT de caja en sucursal ajena) conociendo un UUID, sin barrera; **(b) interleave del pooler** — el GUC de sesión sobre transaction-mode puede aterrizar en otra conn de servidor → fail-closed (`auth.uid()` NULL → 500/403 intermitente, encaja con K5) o, en el peor caso especulativo, fail-open cross-tenant. El verificador de Arquitectura reencuadró el modo de falla demostrable como fail-CLOSED intermitente y bajó esa arista a ALTA; el IDOR de endpoints sin filtro se mantiene CRÍTICO.
- **Recomendación:** decisión de plataforma — pool con rol SIN BYPASSRLS + policies para el backend, o declarar formalmente que la única defensa es el filtro explícito y barrer todos los repos exigiendo `account_id` en todo WHERE de SELECT/UPDATE by-id; envolver cada request en transacción explícita con `set_config(...,true)` transaction-local (patrón PostgREST) o migrar a session pooler. Test de arquitectura que falle si un método interpola un id de path sin `account_id`. Probar bajo carga concurrente con dos JWTs.
- **Riesgo si no se implementa:** fuga/manipulación de datos entre cuentas (presupuestos, cta cte, cajas, settings) con solo conocer un UUID, y/o 500 intermitentes en operaciones de dinero. Escala con el tráfico previsto para junio 2026.
- **Impacto estimado:** compromete el aislamiento de las 29 cuentas y toda cuenta futura; mitigado hoy por UUID v4 no enumerables (pero los ids circulan en exports/PDFs/URLs/logs) y 0 usuarios multi-cuenta.

---

### ÁREA: Backend — Contrato de auth

#### H-06 · ALTO · Tres endpoints usados por el frontend devuelven 500 en prod por shape inválido del dict `auth`
- **Severidad:** ALTA · **Prioridad:** P0 · **Verificación:** CONFIRMADO
- **Evidencia:** `core/auth.py:63-67` retorna `{user_id, role, plan}` (no `sub` ni `account_id`); `routers/quotes.py:60` (`created_by=auth.get('sub','')` → `''::uuid` → 22P02 → 500), `routers/customer_accounts.py:61` y `supplier_accounts.py:61` (`account_id = auth.get('account_id') or auth.get('sub','')` → `''` → 500). El frontend los llama (`use-quotes.ts`, `use-customer-account.ts`, `use-supplier-account.ts`). Los 1.023 tests no lo detectan: los overrides usan `{sub, role}` (shape que el código real nunca produce) y mockean el pool, evitando el cast contra DB real.
- **Descripción:** `POST /quotes` inserta `created_by=''` → cast a uuid falla → 500 en cada alta; `GET /clientes|proveedores/{id}/cuenta` derivan `account_id=''` → 500. El suite verde da falsa confianza y oculta el drift test-double vs contrato real (relación directa con H-04).
- **Recomendación:** fix por sitio (`created_by=auth['user_id']`, `account_id` vía `Depends(get_account_id)`); `TypedDict AuthContext` + fixture única con el shape real para todos los overrides; smoke E2E de estos endpoints contra el Postgres del CI.
- **Riesgo si no se implementa:** presupuestos y consulta de cuenta corriente cliente/proveedor caídos en producción para todos los usuarios.
- **Impacto estimado:** 3 endpoints inoperativos hoy; features de quotes y ctas ctes bloqueadas.

---

### ÁREA: Base de datos / Seguridad

#### H-08 · ALTO · Cinco RPCs admin `SECURITY DEFINER` ejecutables por `anon` sin guard ni search_path
- **Severidad:** ALTA · **Prioridad:** P0 · **Verificación:** CONFIRMADO
- **Evidencia:** `pg_proc`: `get_admin_paid_conversion_rate`, `get_admin_activation_rate`, `get_admin_umv_rate`, `get_admin_insights_breakdown`, `get_admin_community_interactions` son `SECURITY DEFINER`, sin `is_admin()` en el cuerpo, sin `proconfig` search_path, ejecutables por `anon` y `authenticated` (advisor `anon_security_definer_function_executable`). Contraste: la camada nueva `rpc_admin_*` sí tiene guard + search_path. Las funciones de mantenimiento `expire_trials`, `process_cancellations`, `queue_trial_notifications` (con efectos reales: UPDATE profiles/accounts, INSERT email_logs) también son invocables por anon.
- **Descripción:** cualquier poseedor de la anon key pública (embebida en el frontend) invoca `POST /rest/v1/rpc/get_admin_*` y obtiene KPIs confidenciales de negocio (conversión free→pro, activación, UMV, MRR proxy) sin autenticarse, y puede disparar jobs de mantenimiento a voluntad.
- **Recomendación:** `REVOKE EXECUTE FROM anon, authenticated` sobre las 5 `get_admin_*` y las funciones de mantenimiento; agregar `IF NOT is_admin(auth.uid()) THEN RAISE` y `SET search_path=''`; auditar la lista completa con criterio deny-by-default (el proyecto ya tiene el patrón).
- **Riesgo si no se implementa:** exposición continua de inteligencia de negocio a internet sin autenticación; abuso de funciones con efectos.
- **Impacto estimado:** fuga de métricas de negocio a competidores/actores hostiles. Remediación: horas, sin downtime.

---

### ÁREA: Arquitectura / Backend — Autorización

#### H-07 · ALTO · Capa de autorización de aplicación ficticia; `cost_centers` muerta; gating de plan fail-open
- **Severidad:** ALTA (consolida H2 de Arquitectura, H5 de Backend AJUSTADO a MEDIA, H-05 de Seguridad) · **Prioridad:** P1 · **Verificación:** CONFIRMADO (Arquitectura); AJUSTADO (Backend, ALTA→MEDIA para la arista de plan)
- **Evidencia:** `core/auth.py:56-61` — el rol de app se deriva del JWT con fallback `'user'`; el `custom_access_token_hook` EXISTE en DB pero NO está activado en Auth de prod (`config.toml:267-272` lo dice; 29 usuarios, 0 con claim de rol). `cost_centers.py:34,51,70` usa `require_role(['owner','admin'])` → 403 universal (0 filas en prod pese a "V2.5 completa"). `require_plan` (`guards.py:14`) definido y jamás invocado; `products.py:35-36` da límite 999999 a todos ("pro"). Los tests pasan porque inyectan `auth={'role':'owner'}` a mano.
- **Descripción:** de las tres capas de autorización documentadas (KB-08), la capa 1 no resuelve rol/plan reales, la capa 2 es no-op (para user/admin) o bloqueo total (owner/admin en cost_centers), y la capa 3 (RLS) está apagada para el backend por H-05. La única protección efectiva es el filtro manual `WHERE account_id`. `require_platform_admin` sí verifica contra DB (patrón correcto). El verificador aclaró que `require_role` no es no-op universal (se hace valer para allowlists que excluyen `user`), pero el fail-open de plan y `cost_centers` rota son reales.
- **Recomendación:** definir la fuente de verdad del rol (habilitar el hook que copie `account_members.role` al JWT, o lookup en DB como `require_platform_admin`) y reescribir los guards; arreglar `cost_centers` de inmediato (no debe esperar a `v3-rbac-multirole`); derivar el plan de `accounts.billing_plan` con default `'gratis'` (fail-closed); eliminar o implementar `require_plan`.
- **Riesgo si no se implementa:** feature de centros de costo inutilizable; ausencia real de control de acceso por rol/plan en el backend; un usuario de plan gratis puede exceder límites llamando el backend directo (pérdida de ingresos).
- **Impacto estimado:** feature V2.5 muerta para las 29 cuentas; defensa en profundidad de autorización inexistente hasta RBAC.

---

### ÁREA: Arquitectura / Backend — Outbox

#### H-09 · ALTO · Relay Python del outbox desincronizado y RPC de relay ejecutable por cualquier usuario
- **Severidad:** ALTA (Arquitectura) / BAJA (Backend, AJUSTADO a "dead code latente") · **Prioridad:** P1 · **Verificación:** CONFIRMADO (Arquitectura); AJUSTADO (Backend)
- **Evidencia:** dispatch canónico in-DB `rpc_process_outbox_dispatch` (pg_cron cada minuto) con 4 consumers; trigger Python `POST /outbox/process-pending` (`routers/outbox.py:32-44`, solo `get_current_user`) → `OutboxRelayService` con solo 2 consumers (AuditLog+Email) que marca `processed_at`. `rpc_mark_event_processed(uuid)` es `SECURITY DEFINER` con `GRANT EXECUTE TO authenticated` sin guard interno. Frontend no llama el endpoint (grep limpio). El relay real corre 100% en SQL vía pg_cron.
- **Descripción:** dos vectores: **(A)** cualquier autenticado invoca el endpoint Python; como el pool es BYPASSRLS, procesa eventos pending de cualquier cuenta con solo 2/4 consumers y los marca processed → JournalEntry (Consumer 3) y Notification (Consumer 4) se pierden silenciosa e irreversiblemente (idempotencia impide reprocesar); requiere ganar la carrera contra el cron. **(B, más grave)** `rpc_mark_event_processed` es llamable directo vía PostgREST desde el browser sobre cualquier `event_id` legible por el usuario → puede suprimir la contabilización de sus propias operaciones sin que corra ningún consumer, sin race ni backend. Es la misma clase de bug que costó 9 días de journal muerto (#248).
- **Recomendación:** eliminar el endpoint Python y `OutboxRelayService` (o degradarlos a admin-only con `require_platform_admin` + secret de máquina); agregar guard interno a `rpc_mark_event_processed` o revocarla de `authenticated` dejándola solo para el cron.
- **Riesgo si no se implementa:** un usuario logueado puede corromper el pipeline contable/de notificaciones (eventos marcados procesados sin asiento) sin dejar rastro.
- **Impacto estimado:** integridad de la contabilidad devengada y de las notificaciones, potencialmente cross-tenant.

---

### ÁREA: Backend — Ledger inmutable

#### H-10 · ALTO · Los write-paths de borrado violan DEC-24 (UoW en RPC) y DEC-07 (ledger inmutable)
- **Severidad:** ALTA · **Prioridad:** P1 · **Verificación:** CONFIRMADO
- **Evidencia:** `sales_repository.py:86-177` y `purchase_repository.py:88-182` (`delete_by_id`/`delete_by_operation`) abren `async with self._conn.transaction()` y ejecutan `DELETE FROM stock_movements` + reversa de stock + DELETE de sales/purchases + limpieza de `operation_idempotency`. Rutas alcanzables por HTTP (`routers/sales.py:111,140`, `routers/purchases.py:43,53`). En prod: `stock_movements` tiene 79 huecos de `movement_number` (max 953, 874 filas). 5/6 `journal_entries` de 'Purchase' apuntan a compras vivas vía `source_doc_ref` sin FK; el borrado no toca journal ni emite reversa.
- **Descripción:** son las únicas rutas de escritura del hot path fuera del patrón RPC-as-UoW: implementan transacción multi-paso en Python y borran físicamente el ledger inmutable (DEC-07), dejando huecos y destruyendo trazabilidad fiscal. No emiten evento de audit ni asiento compensatorio → contabilidad con asiento de una operación inexistente. El verificador aclaró que el huérfano contable se materializa hoy sobre todo para COMPRAS (coherente con la DB).
- **Recomendación:** mover el borrado a un RPC `SECURITY DEFINER` que use ajuste compensatorio en vez de DELETE, emita evento para audit+reversa y valide estado FSM (no borrar ventas con CAE). Mínimo: reemplazar el DELETE del ledger por movimiento compensatorio y emitir el evento en la misma transacción.
- **Riesgo si no se implementa:** ledger de stock corrupto (huecos), descuadre entre operaciones borradas y asientos ya generados, posible borrado de ventas facturadas ante AFIP.
- **Impacto estimado:** integridad del inventario y de la contabilidad; trazabilidad fiscal comprometida.

---

### ÁREA: Seguridad / IA — Recursos y costo

#### H-11 · ALTO · Ausencia total de rate limiting; `invoice-ocr` sin quota ni gating de plan
- **Severidad:** ALTA · **Prioridad:** P1 · **Verificación:** CONFIRMADO
- **Evidencia:** `backend/core/redis_client.py:17` ("rate limiting unavailable"); grep de rate-limit/slowapi = 0; `main.py` sin middleware; `/payments/webhook` es endpoint público gateado solo por HMAC (flood golpea Render). Edge Functions solo con cuota mensual fail-open (`_shared/ai-quota.ts`, fail open en errores). `invoice-ocr` (la llamada más cara: visión `detail:high`, 2000 tokens) NO importa `ai-quota`, no gatea plan; el guard 409 por-documento se evade creando un documento nuevo por llamada.
- **Descripción:** ningún endpoint ni función limita requests por ventana corta: fuerza bruta, flood del webhook, abuso de OCR/IA (costo OpenAI), DoS del backend Render free (cold start ~50s). `invoice-ocr` es el único vector de IA sin techo de costo, abusable ilimitadamente por cualquier autenticado.
- **Recomendación:** habilitar `REDIS_URL` (Upstash previsto) y montar rate-limiter por IP y por `user_id`; aplicar `checkAiQuota` (o contador `ocr` dedicado) en `invoice-ocr` antes de descargar el archivo; cuota por ventana corta en las Edge Functions de IA; budget guard global.
- **Riesgo si no se implementa:** costo OpenAI/infra descontrolado, DoS del backend, facilitación de fuerza bruta.
- **Impacto estimado:** OWASP API4:2023 (Unrestricted Resource Consumption); impacto económico y de disponibilidad.

---

### ÁREA: Arquitectura / Backend — Frontera del híbrido

#### H-12 · MEDIA · Frontera del modelo híbrido erosionada: datos ERP fluyen directo browser→DB
- **Severidad:** MEDIA (AJUSTADO de ALTA) · **Prioridad:** P1 · **Verificación:** AJUSTADO
- **Evidencia:** 140 `supabase.from` en 53 archivos + 31 `.rpc` en 17 archivos del frontend. Incluye ERP núcleo: `use-branches.ts:96-154` muta branches por `supabase.rpc` directo mientras `backend/routers/branches.py:47-86` expone los mismos POST como endpoints muertos; `stock-adjustment-modal.tsx` y `stock-import-adjustment-dialog.tsx` ajustan stock por RPC directo.
- **Descripción:** el service layer FastAPI no es choke point para esas rutas: los estándares de plataforma V3 (Idempotency-Key, RFC 7807, paginación, soft-delete filtering) y cualquier regla futura solo-Python (rate limit, RBAC) quedan evadibles. Dos write-paths para el mismo agregado (Branch) garantizan deriva. El verificador acotó el alcance: la erosión es localizada a Branch y ajustes/transferencias de stock; el patrón dominante (clientes, productos, compras, gastos, quotes, cost-centers, caja, banco, fiscal) sí pasa por FastAPI. Mitigante: los RPCs contienen las invariantes, así que ambos caminos convergen.
- **Recomendación:** inventariar las llamadas directas por dominio; migrar las mutaciones ERP restantes al backend (branches y ajustes de stock ya tienen endpoint); borrar los endpoints muertos; documentar la lista blanca de dominios que legítimamente hablan directo con Supabase.
- **Riesgo si no se implementa:** los estándares de plataforma y futuras reglas de seguridad/negocio quedan evadibles desde el browser; el strangler fig no cierra.
- **Impacto estimado:** gobernabilidad del contrato de datos y consistencia de comportamiento en el dominio ERP (localizado).

---

### ÁREA: Frontend — Cliente HTTP y doble vía de lectura

#### H-13 · MEDIA · Cliente HTTP no consume RFC 7807 ni maneja cold start; doble vía de lectura Supabase-directo vs FastAPI
- **Severidad:** MEDIA (AJUSTADO de ALTA en ambos sub-hallazgos) · **Prioridad:** P1 · **Verificación:** AJUSTADO
- **Evidencia:** `lib/api/python-client.ts:25-42` lee solo `body.detail` y descarta `code`/`field`/`status`; sin `AbortSignal`/timeout; `query-provider.tsx:18` decide retry por `error.message.includes(...)`. Doble vía: `clientes/page.tsx` y `gastos/page.tsx` leen `table:'clients'/'expenses'` vía `usePaginatedQuery` (Supabase directo, fuera de React Query) mientras mutan vía FastAPI; `invalidateQueries` no refresca esas listas. El envelope `{items,total,page,pages}` solo está en sales/purchases. Bonus: `use-paginated-query.ts:148-150` crea `AbortController` que nunca se pasa a la query.
- **Descripción:** el backend emite problem+json completo pero el cliente lo aplana a un `Error` de string, así la UI no puede mapear P04xx ni marcar el campo ofensor; los componentes hacen matching de strings. Tras el cold start de Render un fetch puede colgar sin feedback (mitigado por un keep-warm cron en GitHub Actions que el auditor no consideró — su afirmación "ningún ping a /health" aplica solo al frontend). El verificador quitó VENTAS del alcance (mal atribuido): la doble vía se limita a clientes y gastos.
- **Recomendación:** `ApiError extends Error` parseando problem+json; `AbortSignal.timeout` con UX de cold start; retry por `status>=500`; migrar clientes/gastos a endpoints FastAPI paginados y retirar `usePaginatedQuery`; extender el envelope estándar a los listados restantes.
- **Riesgo si no se implementa:** UX de errores genérica en flujos de dinero; listas desincronizadas tras mutaciones; doble mantenimiento de contratos.
- **Impacto estimado:** robustez/mantenibilidad/UX; afecta los módulos que consumen FastAPI y las 2 pantallas de listado con doble vía.

---

### ÁREA: Performance

#### H-14 · MEDIA · El patrón RLS `account_id IN (SELECT current_account_ids())` fuerza Seq Scan y no escala
- **Severidad:** MEDIA (AJUSTADO de ALTA) · **Prioridad:** P1 · **Verificación:** AJUSTADO
- **Evidencia:** `pg_policies`: sales/clients/expenses/purchases con `qual = account_id IN (SELECT current_account_ids())`; EXPLAIN sobre expenses → Seq Scan + Memoize semijoin (no usa `idx_expenses_account_id`). Contadores prod: 679.570 seq scans en sales, 909.414 en clients, 251.982 en purchases, 145.314 en expenses; `idx_expenses_account_id` con idx_scan=0. Las rutas FastAPI están a salvo (filtran `account_id=$1` explícito, EXPLAIN muestra Index Scan).
- **Descripción:** las lecturas Supabase-directas confían solo en RLS sin filtrar `account_id`; el planner escanea toda la tabla. Barato hoy (95–1.121 filas) pero el costo crece con el total global de la tabla. Deuda de escalabilidad latente, no un problema presente.
- **Recomendación:** `.eq('account_id', accountId)` explícito en las rutas Supabase-directas; evaluar reescribir la policy a `= ANY(current_account_ids())` o GUC cacheada; índices `(account_id, date DESC)` en sales/purchases/expenses.
- **Riesgo si no se implementa:** a las pocas miles de filas por cuenta, dashboard y listados degradan a >1-2s y el pool de 10 conexiones se agota bajo concurrencia moderada hacia junio 2026.
- **Impacto estimado:** degradación lineal con el volumen global; hoy latente.

---

### ÁREA: Base de datos — Líneas de documento

#### H-15 · ALTO · `sale_items` todavía no es fuente única; snapshots incompletos
- **Severidad:** ALTA · **Prioridad:** P1 · **Verificación:** CONFIRMADO
- **Evidencia:** `account_feature_flags`: `sale_items_rpc_v2` habilitado en 26/29 cuentas; 3 ventas desde 2026-07-02 sin `sale_items`; 50/293 `name_snapshot` NULL (backfill no cubrió productos inexistentes: los 50 tienen `product_id` NULL); 293/293 `iva_rate_snapshot` NULL (K12); 23 con `account_id` NULL (K3). En paralelo, `purchase_items` congelada mid-history (K8/H-BD): 37/37 compras de julio sin líneas (decisión D2 intencional, pero deja tabla mixta con 244 filas legacy).
- **Descripción:** el objetivo V3 "línea inmutable como única fuente de verdad" no es aún invariante de datos. El sistema lo tolera porque los RPCs de reporting leen headers con `COALESCE(total, amount)` (RN-97 + RN-D verificadas), pero C-20 Grupo 10 (drop del header plano) está bloqueado. La convivencia de dos modelos ya costó un bug de revenue del 17,53% en prod.
- **Recomendación:** activar el flag en las 3 cuentas restantes (decisión PO); backfillear los 50 `name_snapshot` NULL; decidir la fuente de `iva_rate_snapshot` (columna de IVA en products o tasa por defecto documentada); decidir el destino de `purchase_items` (backfill+reactivar vs deprecación dura con COMMENT + lint).
- **Riesgo si no se implementa:** C-20 Grupo 10 bloqueado indefinidamente; snapshots NULL rompen la promesa de inmutabilidad documental (relevante para AFIP); reportes futuros sobre datos parciales.
- **Impacto estimado:** deuda estructural que ya costó un bug de revenue en prod; cada mes agrega filas a backfillear.

---

### ÁREA: Backend — Precisión monetaria

#### H-16 · MEDIA · Dinero degradado a `float` en fronteras de service
- **Severidad:** MEDIA · **Prioridad:** P2 · **Verificación:** NO_REQUERIDA
- **Evidencia:** schemas usan `Decimal` pero los services convierten a `float`: `cash.py:52,63,95` (arqueo), `customer_accounts.py:95` (cta cte), `wsfe_adapter.py:475,531-532` y `cae_relay_processor.py:80-88` (montos AFIP). Contraste correcto: `quotes.py:49-52` usa `str(Decimal)`.
- **Descripción:** asyncpg encodea `Decimal→numeric` nativamente; el `float()` intermedio arrastra el error binario. En arqueo de caja al centavo (campo `difference`) y totales con IVA presentados a AFIP, es fuente de descuadres de $0.01 y discrepancias fiscales.
- **Recomendación:** pasar `Decimal` end-to-end; lint/CI que prohíba `float(` sobre campos `amount|total|balance|price|subtotal`.
- **Riesgo si no se implementa:** descuadres de centavos en arqueos y diferencias en importes fiscales frente a AFIP.
- **Impacto estimado:** precisión contable y fiscal en caja, cuentas corrientes y facturación.

---

### ÁREA: Base de datos — FSM

#### H-17 · MEDIA · FSM sin enforcement a nivel DB (UPDATE directo de status permitido)
- **Severidad:** MEDIA · **Prioridad:** P1 · **Verificación:** NO_REQUERIDA (verificado en detalle por DB)
- **Evidencia:** la policy `quotes_update` tiene `with_check is_account_writer(account_id)` sin restricción de columnas ni de transición; no existe trigger BEFORE UPDATE en quotes/sales_orders/fiscal_documents; `document_status_history` = 0 filas; el catálogo `document_status_transitions` tiene 18 filas. La FSM está cableada en 11 RPCs pero solo como convención (K9/K15).
- **Descripción:** un writer puede hacer `UPDATE quotes SET status='accepted'` directo vía PostgREST, saltando la validación de transición y sin dejar historial. La maquinaria está sin ejercitar en prod (quotes=0), así que su primer uso real será en producción sin datos previos que la validen.
- **Recomendación:** trigger BEFORE UPDATE OF status que valide la transición contra `document_status_transitions` y registre en `document_status_history` (o rechace cambios de status por UPDATE plano, forzando el paso por RPC).
- **Riesgo si no se implementa:** estados inconsistentes sin auditoría (quote aceptada sin orden ni stock comprometido); historial append-only que nace con huecos.
- **Impacto estimado:** bajo hoy por uso casi nulo; alto en cuanto quotes/POS se activen comercialmente.

---

### ÁREA: Backend / Fiscal — WSAA

#### H-18 · MEDIA · La cache del TA de WSAA nunca se inyecta: loginCms por cada CAE
- **Severidad:** MEDIA (AJUSTADO de ALTA) · **Prioridad:** P1 · **Verificación:** AJUSTADO
- **Evidencia:** `PostgresTicketCache` sin instanciación fuera de docstrings (0 usos); `routers/fiscal.py:323,366` construyen adapter con `ticket_cache=None` ⇒ loginCms en cada `request_cae`; la clase quedó en el modelo per-account pre-v22 (constructor y `_parse_key` desalineados).
- **Descripción:** WSAA rechaza un loginCms nuevo mientras hay TA vigente (~12h): a partir del segundo comprobante del día `request_cae` falla, consume attempts y puede dejar docs `rejected` sin causa real. El verificador bajó a MEDIA: el impacto no se materializa hoy (facturación bloqueada tras paso manual del PO + 1 solo `fiscal_document` en toda la DB); es un bug latente pre-cableado.
- **Recomendación:** implementar `PlatformPostgresTicketCache` (asyncpg) sobre `wsaa_platform_tickets` (migración ya existe) e inyectarla en los 2 relay points y en el fix de H-01.
- **Riesgo si no se implementa:** con más de un comprobante por día por ambiente, la emisión de CAE falla por cooldown de WSAA; incompatible con facturación en volumen.
- **Impacto estimado:** bloquea escalar la facturación electrónica real; hoy no duele por volumen ~0.

---

### ÁREA: Backend / Billing — Webhook MP (atomicidad)

#### H-19 · MEDIA · Webhook MercadoPago sin transacción y con carreras de idempotencia
- **Severidad:** MEDIA (AJUSTADO de ALTA) · **Prioridad:** P1 · **Verificación:** AJUSTADO
- **Evidencia:** `services/payments.py:104-232`: `UPDATE accounts` (165) + `INSERT billing_events` (175) + `INSERT email_logs` (220) sin `conn.transaction()`; idempotencia por SELECT previo (TOCTOU); `member_row` sin ORDER BY/LIMIT. Índice único `idx_billing_events_mp_payment_id` verificado.
- **Descripción:** un fallo entre el UPDATE de plan y el INSERT del evento deja el plan activado sin recibo/auditoría. El verificador corrigió: 23505 mapea a 409 (no 500), el índice único previene doble evento, el UPDATE re-aplicado es idempotente; el defecto real y materializable es la falta de atomicidad. La arista multi-cuenta es latente (0 usuarios multi-cuenta hoy).
- **Recomendación:** envolver el flujo en `async with conn.transaction()`; mover el INSERT de billing_events antes del UPDATE (o `ON CONFLICT DO NOTHING` + early return); resolver la cuenta determinísticamente con ORDER BY.
- **Riesgo si no se implementa:** plan activo sin recibo si falla entre UPDATE e INSERT (dominio billing, dinero real).
- **Impacto estimado:** dominio de billing (CRÍTICO); afecta activaciones de plan y auditoría de pagos.

---

### ÁREA: IA — Telemetría y prompt injection

#### H-20 · ALTO · Cero telemetría de costo/calidad de IA y ausencia total de evals
- **Severidad:** ALTA · **Prioridad:** P1 · **Verificación:** CONFIRMADO
- **Evidencia:** ninguna de las 9 funciones lee `aiData.usage` (tokens); solo `invoice-ocr` guarda `processing_ms`. No hay tabla de telemetría de IA, ni registro de costo por llamada, ni dataset de evaluación (verificado en DB: cero columnas de tokens/costo). SUP-06 y DEC-03 definen señales de revisión de calidad/costo no medibles con la instrumentación actual.
- **Descripción:** el equipo no puede saber cuánto cuesta la IA, qué función es más cara, si la calidad degrada, ni A/B-testear prompts/modelos. Punto ciego crítico para un producto cuya tesis de valor (SUP-03) depende de la IA con presupuesto $0.
- **Recomendación:** capturar `usage.total_tokens` + latencia + modelo + función en una tabla `ai_telemetry` por llamada; construir un set mínimo de evals golden (OCR etiquetado + insights esperados) antes de tocar el modelo.
- **Riesgo si no se implementa:** decisiones de modelo/costo/calidad a ciegas; imposible cumplir las señales de SUP-06/DEC-03.
- **Impacto estimado:** bloquea toda gestión informada de costo y calidad de IA; prerequisito de V3.

> **Sub-hallazgos de IA de menor severidad** (AJUSTADOS a BAJA en verificación): prompt injection en `ai-simulador` (texto libre a temperature 0.7, blast radius intra-tenant), prompt injection indirecta vía contenido OCR (gate humano obligatorio), y outbox no extensible para automatizaciones de IA (limitación de extensibilidad a futuro, fase V3 no iniciada). Base de métricas inconsistente entre funciones (3 leen header legacy, 2 leen `v_sales_flat`) — MEDIA, agrava K4. Duplicación masiva (`_shared` casi vacío, 9 copias del cliente OpenAI) — MEDIA, prerequisito de V3.

---

### ÁREA: UX/UI

#### H-21 · MEDIA · Brechas transversales de accesibilidad, design tokens y formularios
- **Severidad:** MEDIA (los tres sub-hallazgos AJUSTADOS de ALTA) · **Prioridad:** P1-P2 · **Verificación:** AJUSTADO
- **Evidencia:** 59 botones `size="icon"` fuera de `ui/` con solo 2 `aria-label` (WCAG 4.1.2), incl. editar/eliminar de todas las tablas y toggle de contraseña del login. 883 clases de color hardcodeadas + ~59 hex literales que saltan los tokens `--success`/`--warning` (ni mapeados en `tailwind.config.ts`). RHF+Zod: 7 forms lo usan, pero las 5 formas legacy núcleo (sale/purchase/expense/product/client) validan por `toast.error` global sin errores inline ni `aria-invalid`.
- **Descripción:** base sólida (POS ejemplar, empty states, es-AR consistente) con inconsistencia de ejecución a escala. El verificador corrigió que RHF+Zod no está globalmente ausente (adopción parcial) y que las acciones destructivas están respaldadas por AlertDialog. Deuda adicional MEDIA: dos `globals.css` divergentes, breadcrumb incompleto (mapea 19 de ~35 rutas), dos spinners, 7 `confirm()` nativos sobre datos financieros, formato de moneda inconsistente (43 `formatMoney` vs 47 `toLocaleString` vs 43 crudos), 108 `any`.
- **Recomendación:** aria-label en los 59 botones-ícono (centralizar en `data-table` e `IconButton`); tokenizar color con lint anti-hex; migrar las 5 formas núcleo a RHF+zodResolver; unificar spinner + `loading.tsx` por ruta; reemplazar `confirm()` por AlertDialog; enrutar toda moneda por `formatMoney`.
- **Riesgo si no se implementa:** falla WCAG para usuarios de tecnología asistiva; theming/dark mode incoherentes; mayor tasa de datos mal cargados en el hot path financiero.
- **Impacto estimado:** transversal a casi todas las pantallas; impacto individual medio, acumulativo alto.

---

### ÁREA: Documentación

#### H-22 · MEDIA · README raíz no-operativo, KB descriptiva desactualizada y dos fuentes de instrucción divergentes
- **Severidad:** MEDIA (AJUSTADO de ALTA en los 3 sub-hallazgos) · **Prioridad:** P1-P2 · **Verificación:** AJUSTADO
- **Evidencia:** README.md es un entregable académico sin setup/install/run y afirma "sin billing real / no pasarela de pagos" pese a `backend/services/payments.py` (MercadoPago) y C-17 ✅. KB 04 documenta ~25 de 68 tablas con ERD rooteado en el modelo de tenancy `user_id` retirado y `profiles` sin las columnas billing/IA reales. KB 02 muestra arquitectura Supabase-directo sin FastAPI, "Realtime no usado" (ya en prod), estructura app-en-raíz (ya monorepo), "10 EF"/"~60 migraciones" (real 11/204). AGENTS.md (Jun 12) se detiene en V2, marca la Fase 5 backend como planificada (ya en prod), no menciona V3. 15/62 specs fallan strict (K6).
- **Descripción:** la documentación de decisiones y arquitectura-objetivo es fuerte y viva; la capa descriptiva del sistema actual arrastra un desfase estructural. El verificador bajó a MEDIA: sin impacto de runtime/seguridad/datos, y el onboarding técnico real está cubierto por CLAUDE.md/KB/CHANGES.md actualizados. No hay errores que pongan plata/datos en riesgo desde la doc.
- **Recomendación:** reescribir README.md como guía de onboarding operativa (mover el entregable a `docs/entrega-final.md`); refrescar KB 02/03/04 contra la DB de prod con ERD mermaid (accounts como raíz); unificar AGENTS.md y CLAUDE.md en una sola fuente; migrar las 15 specs legacy al formato estricto; retirar §7.4 imágenes de producto del set adoptado del modelo V3 (descartado por PO); consolidar outputs de auditoría en `audit/` y remover `undefined/`.
- **Riesgo si no se implementa:** onboarding roto; agentes operando sobre supuestos obsoletos; afirmaciones falsas sobre el alcance en producción.
- **Impacto estimado:** onboarding de devs y coherencia de trabajo de agentes; sin impacto en runtime.

---

### Hallazgos de severidad BAJA (registro sintético)

Se documentan para completitud; ninguno bloquea producción.

| ID | Área | Hallazgo | Prioridad |
|---|---|---|---|
| H-23 | Backend/Seguridad | CORS default `*` con `allow_credentials=True` + reflejo manual de origin en errores (fail-open si el env queda sin setear en Render) | P3 |
| H-24 | Backend | Higiene de plataforma: drift pyproject↔requirements (python-jose vs PyJWT), enforcement de fronteras declarado y ausente, dead code | P3 |
| H-25 | Backend | Bordes de config y dead code peligroso: HS256 con secret default ante misconfig, `AttributeError` latente en cert-upload deprecado, SOAP sync en el event loop, WS sin tenancy | P3 |
| H-26 | Seguridad | `platform_wsaa_tickets` con GRANT SELECT a anon/authenticated (protegido hoy solo por default-deny de RLS) | P2 |
| H-27 | Seguridad | `search_path` mutable en 8 funciones, incl. `custom_access_token_hook` | P2 |
| H-28 | Seguridad | CSV formula injection en `generate-export`; CORS `*` fijo en las 11 EF; leaked-password protection deshabilitado + buckets públicos listables | P3 |
| H-29 | DB/Performance | 48 FKs sin índice de cobertura + 55 índices sin uso (legacy tenancy) + 67 policies permisivas duplicadas + 8 `auth_rls_initplan` | P2/P3 |
| H-30 | DB | Residuo de tenancy legacy: policy company-based en `suppliers` en OR con account-based; journal sin backfill histórico | P2/P3 |
| H-31 | Frontend | 33 componentes >300 líneas (sale-form 785, purchase-form 707 sin tests); wizards de importación copy-paste; capa de hooks muerta; PascalCase incumplido; sin telemetría de errores (0 Sentry); fetch-all sin paginación en catálogos | P2/P3 |
| H-32 | Performance | Bundle sin code-splitting (d3+recharts, `next/dynamic` ausente); `SalesChart` grafica solo la primera página de 25 ventas (correctitud); N+1 en `quote_items` | P2/P3 |
| H-33 | UX | POS sin selector de sucursal en cuentas multi-sucursal; bug de colSpan en empty state del data-table | P2/P3 |
| H-34 | Testing | Gates de comportamiento SQL degradables (K2); copia de lógica en tests (drift); sin E2E/Playwright; Edge Functions sin tests; WSAA/AFIP mockeado | P1/P2 |

---

## 8. Inconsistencias documentación ↔ código (consolidado)

Consolidación de todas las dimensiones, con protagonismo de Documentación. Se agrupan por gravedad.

### Inconsistencias que afectan la comprensión del núcleo de seguridad/consistencia (graves)

1. **`openspec/specs/asyncpg-pool/spec.md` exige `SET LOCAL` (transaccional); `core/database.py` usa `set_config(...,false)` (sesión).** La spec describe el diseño correcto, el código el incorrecto (raíz de H-05).
2. **DEC-13 / KB-08: "la RLS org-based sigue activa como red de seguridad" — falso en prod:** el backend corre como `postgres` con `rolbypassrls=true`. Repetido en docstrings de `outbox_repository.py`, `billing_repository.py`, `cost_centers.py`.
3. **KB-08 "tres capas de autorización" — las tres están degradadas:** capa 1 sin claims de rol/plan, capa 2 no-op/bloqueo total, capa 3 apagada para el backend.
4. **DEC-07 "stock_movements solo-inserción, ningún movimiento puede borrarse" vs `DELETE FROM stock_movements`** en sales/purchase repositories (H-10).
5. **DEC-24 "los services nunca abren ni comitean transacciones" vs transacciones explícitas multi-paso** en los repositories de deletes.
6. **`fiscal_profile_service.py:429-430`: "si el stub falla, el cron lo reintenta" — falso:** el stub nunca falla, aprueba con CAE falso (H-01).

### Inconsistencias de estado del sistema (KB descriptiva)

7. **KB 04: "la DB real tiene 55 tablas"** (README de la KB: "23+"); prod tiene 68 en `public` + 16 en `community`. ~20 tablas V2.5/V3 sin documentar. ERD rooteado en el modelo de tenancy `user_id` ya retirado.
8. **`profiles.plan` es ENUM con `billing_plan`/`trial_plan`/`ai_queries_used`/`ai_advice_used`/`usage_reset_at`; KB 03/04 documentan "plan TEXT free|pro" + solo `insights_used`.**
9. **KB 02: "Realtime Supabase no usado en MVP"** — en prod desde 2026-07-04 (`useNotifications`/`NotificationBell`). "10 Edge Functions" (real 11); "~60 migraciones" (real 204); estructura app-en-raíz (ya monorepo `frontend/`+`backend/`).
10. **KB 08 marca el backend FastAPI como "Fase 5 pendiente/planificado"; CHANGES.md marca C-15..C-18 ✅** y el backend está en prod con 24 routers.
11. **README raíz: "sin billing real / no pasarela de pagos"** — existen `backend/routers/payments.py` + `services/payments.py` (MercadoPago) y C-17 ✅ (H-02/H-22).
12. **AGENTS.md ("15 decisiones", Fase 5 planificada, sin V3) vs KB 09 (DEC-01..24) y CLAUDE.md (V3 completo).**

### Inconsistencias de reglas duras del propio proyecto (incumplidas por el código)

13. **"NUNCA usar `any`"** incumplida ~150 veces en frontend + 108 en UX, sin lint que la haga cumplir.
14. **"PascalCase en componentes React — archivos también"** incumplida en 87/161 archivos.
15. **Stack declara "Estado global: Zustand"** — 0 usos en el código. **"Formularios: RHF+Zod"** — solo 8 componentes; las formas núcleo usan estado manual.
16. **CLAUDE.md: "coverage mínimo verificado en CI (pytest-coverage)" y "gate validate-kpis con gates de comportamiento en Postgres real"** — CI no corre pytest ni mide coverage, y los gates no son vinculantes (H-04).

### Inconsistencias menores / internas de la KB

17. **KB 10 lista como abiertas preguntas ya resueltas** (PA-23 naming, INC-01 plan default, PA-11 tests). RN-05 describe en futuro un split de contadores IA ya implementado.
18. **Modelo V3 §7.4/decisión #12 lista "imágenes de producto" como ADOPTADO** pese al descarte del PO (2026-07-04).
19. **CHANGES.md/CLAUDE.md no advierten que COMPRAS sigue con header plano** (K8) ni el gating por `sale_items_rpc_v2` (K4).
20. **Docstrings de `outbox.py`/`OutboxRelayService`: "Called by the pg_cron job"** — falso desde el pivot in-DB; el cron llama a `rpc_process_outbox_dispatch` (H-09).

---

## 9. Plan de recomendaciones priorizado

Esfuerzo: **S** (horas–1 día) · **M** (días) · **L** (semana+). Impacto: qué desbloquea o protege. Ref: hallazgos que atiende.

### P0 — Antes de crecer en usuarios / activar facturación fiscal (bloqueante)

| # | Acción | Esfuerzo | Impacto | Ref |
|---|---|---|---|---|
| P0-1 | Construir el adapter fiscal con `build_cae_adapter_from_settings()` en el fire-and-forget + gate defensivo anti-stub en prod | S | Elimina el riesgo de CAE falso ante AFIP | H-01 |
| P0-2 | Apuntar `notification_url` del upgrade al webhook backend funcional (o mover preferencias al backend) + E2E webhook→upgrade (requiere sign-off PO) | M | Recupera 100% de los upgrades pagos automáticos | H-02 |
| P0-3 | Cerrar `send-email`: secreto de DB Webhook, sin `recipient` arbitrario, fail-closed, escapar HTML | S | Cierra el vector de phishing/spam masivo | H-03 |
| P0-4 | Wirear `pytest`+`vitest` en un gate de `pull_request` como required check | S | Convierte ~1.466 tests en red real | H-04 |
| P0-5 | Decidir el modelo de tenancy del pool (rol sin BYPASSRLS + policies, o barrer repos exigiendo `account_id` en by-id) + transacción explícita con GUC transaction-local | L | Cierra el IDOR cross-tenant y los 500 intermitentes (K5) | H-05 |
| P0-6 | Fix de los 3 endpoints 500 (`auth['user_id']` / `Depends(get_account_id)`) + fixture de auth con shape real + smoke E2E | S | Restaura presupuestos y cta cte cliente/proveedor | H-06 |
| P0-7 | REVOKE anon/authenticated + guard `is_admin()` + `search_path` en las 5 RPCs admin legacy y las funciones de mantenimiento | S | Cierra la fuga de inteligencia de negocio | H-08 |

### P1 — Próximo trimestre

| # | Acción | Esfuerzo | Impacto | Ref |
|---|---|---|---|---|
| P1-1 | Habilitar el custom access token hook + arreglar `cost_centers` + gating de plan fail-closed | M | Restaura autorización y feature V2.5 | H-07 |
| P1-2 | Eliminar/proteger el endpoint Python del outbox y `rpc_mark_event_processed` | S | Cierra la supresión de asientos contables | H-09 |
| P1-3 | Mover el borrado de ventas/compras a RPC con ajuste compensatorio + evento de reversa | M | Protege el ledger inmutable y la contabilidad | H-10 |
| P1-4 | Rate limiting por user_id + quota en `invoice-ocr` + budget guard | M | Contiene costo OpenAI y DoS | H-11 |
| P1-5 | Tier de integración real contra Postgres en CI (arqueo, conciliación, partida doble, webhook) + gates SQL vinculantes | L | Red de test sobre la lógica de dinero | H-04, H-34 |
| P1-6 | Activar `sale_items_rpc_v2` en las 3 cuentas + backfill snapshots + decidir destino de `purchase_items` | M | Desbloquea C-20 Grupo 10; cierra deuda de líneas | H-15 |
| P1-7 | Telemetría de IA (tokens/costo/latencia) + set mínimo de evals | M | Gestión informada de costo/calidad de IA | H-20 |
| P1-8 | Migrar mutaciones ERP de branches/stock al backend + borrar endpoints muertos | M | Cierra la frontera del híbrido | H-12 |
| P1-9 | Trigger BEFORE UPDATE de status en quotes/sales_orders/fiscal_documents | S | FSM como invariante real antes de activar POS/quotes | H-17 |
| P1-10 | Implementar e inyectar `PlatformPostgresTicketCache` (WSAA) | M | Desbloquea facturación a volumen | H-18 |
| P1-11 | Envolver el webhook MP en transacción + lookup determinista | S | Atomicidad del billing | H-19 |
| P1-12 | `ApiError` tipado (RFC 7807) + timeout/cold-start + migrar clientes/gastos a FastAPI paginado | M | UX de errores y coherencia de caché | H-13 |
| P1-13 | Aria-label en botones-ícono + migrar formas de dinero a RHF+Zod | M | Accesibilidad y calidad de captura | H-21 |
| P1-14 | Reescribir README raíz + unificar AGENTS.md/CLAUDE.md | S | Onboarding y coherencia de agentes | H-22 |

### P2 — Backlog cercano

| # | Acción | Esfuerzo | Impacto | Ref |
|---|---|---|---|---|
| P2-1 | `.eq('account_id')` explícito en rutas Supabase-directas + índices `(account_id, date DESC)` | M | Escalabilidad de lecturas | H-14 |
| P2-2 | `Decimal` end-to-end en dinero + lint anti-`float(` | M | Precisión contable/fiscal | H-16 |
| P2-3 | Índices en las 48 FKs del hot path + DROP de índices/policies legacy de tenancy | M | Performance a escala; seguridad latente | H-29, H-30 |
| P2-4 | REVOKE de `platform_wsaa_tickets` + `search_path` en las 8 funciones | S | Higiene de credenciales fiscales | H-26, H-27 |
| P2-5 | Consolidar `_shared` de Edge Functions (cliente OpenAI + helpers) + unificar fuente de métricas de IA | M | Prerequisito de V3; coherencia de datos | H-20 |
| P2-6 | Refrescar KB 02/03/04 con ERD mermaid + migrar 15 specs legacy a formato estricto | M | Fuente de verdad confiable | H-22 |
| P2-7 | Tokenizar color (883 clases) + unificar spinner/moneda + AlertDialog en confirmaciones | M | Consistencia del design system | H-21, H-33 |
| P2-8 | Telemetría de errores del cliente (Sentry) | S | Observabilidad de prod (ayuda K5) | H-31 |

### P3 — Deuda de fondo

| # | Acción | Esfuerzo | Impacto | Ref |
|---|---|---|---|---|
| P3-1 | Fail-fast de CORS/HS256 en startup si `app_env=production` con defaults inseguros | S | Defensa en profundidad | H-23, H-25 |
| P3-2 | Alinear pyproject↔requirements + ruff/import-linter + podar dead code | M | Mantenibilidad; enforcement de fronteras | H-24 |
| P3-3 | Neutralizar CSV formula injection + CORS por origin en EF + leaked-password protection | S | Superficie residual OWASP | H-28 |
| P3-4 | Code-splitting de charts (`next/dynamic`) + `SalesChart` sobre RPC agregado + paginar catálogos | M | Performance frontend; correctitud del gráfico | H-32 |
| P3-5 | Purgar hooks muertos + descomponer sale-form/purchase-form + renombrado PascalCase | M | Mantenibilidad frontend | H-31 |
| P3-6 | E2E Playwright de los 3 flujos de dinero + k6 como job nightly | L | Cobertura de la juntura híbrida | H-34 |

---

## 10. Conclusión final

**ALIADATA es un producto de arquitectura y disciplina de ingeniería notables, actualmente APTO PARA PRODUCCIÓN DE FORMA CONDICIONAL.** El sistema ya opera en producción con 29 cuentas reales y lo hace correctamente a esa escala; los fundamentos —RLS universal, migraciones sincronizadas, ledgers serializados, outbox transaccional, hexagonal AFIP, middleware de auth ejemplar, documentación de decisiones profesional— son reales y colocan al proyecto por encima de la media de su categoría. Nada de lo hallado indica corrupción de datos activa, fuga cross-tenant demostrada ni secreto de producción comprometido.

**La condición para el paso a producción plena es cerrar el bloque P0.** La auditoría, con verificación adversarial contra la DB de producción, encontró que la brecha entre la excelente documentación de diseño y lo efectivamente desplegado se concentra —de forma sistemática y en cinco dimensiones independientes— en los dominios de gobernanza CRÍTICA: fiscalidad (CAE fabricado por el stub), billing (upgrades no acreditados, ya con un caso real reconciliado a mano), comunicaciones (Edge Function de email abierta), contabilidad (lógica de dinero sin red de test, con evidencia empírica de 9 días de journal muerto) y aislamiento multi-tenant (pool con BYPASSRLS + endpoints sin filtro de cuenta). Ninguno de estos es un defecto de diseño de fondo: son caminos "dead-but-armed" o cortes de migración inconclusos que se remedian con fixes acotados sobre infraestructura que en su mayoría **ya existe** (el webhook backend correcto, el adapter real, el hook de rol, el dispatch SQL de 4 consumers).

**Próximos pasos recomendados, en orden:**

1. **Semana 1-2 (P0):** cerrar los siete ítems P0. La mayoría son de esfuerzo S/M y desactivan riesgos de dinero, fiscalidad y confidencialidad. En particular, no emitir facturas fiscales reales a volumen hasta resolver H-01 y H-18, y no habilitar campañas de upgrade masivas hasta resolver H-02.
2. **Trimestre (P1):** restaurar la capa de autorización real, la red de test sobre la lógica de dinero, y cerrar la deuda de líneas de documento que bloquea el roadmap V3. Estos ítems condicionan tanto la operación segura como la continuidad del roadmap.
3. **Continuo (P2/P3):** performance a escala, precisión monetaria, consolidación de la plataforma de IA y refresco de la documentación descriptiva.
4. **Pendientes externos del PO (K20):** homologación ARCA y configuración de verificación de email en Supabase — no bloquean código pero son prerequisitos operativos para la facturación fiscal y el onboarding.

Con el bloque P0 cerrado y verificado bajo carga concurrente, ALIADATA queda en condiciones de escalar hacia el objetivo comercial de junio 2026 sobre una base que ya es, en lo estructural, sólida.

---

*Fin del informe. Los hallazgos H-01…H-34 están referenciados desde el plan de recomendaciones; el detalle exhaustivo por dimensión vive en `audit/` (arquitectura, código backend, código frontend, base de datos, seguridad, performance, ux-ui, ia, testing, documentación).*
