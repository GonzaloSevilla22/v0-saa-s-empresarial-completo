> **Modo TDD estricto activo.** Todo grupo que escriba código de producción sigue el ciclo
> SAFETY NET → RED → GREEN → TRIANGULATE → REFACTOR, y el apply devuelve la tabla de evidencia
> por task. Ninguna task de implementación se marca `[x]` sin su test escrito **antes**.
>
> Governance: **MEDIO-bajo** (lectura agregada + navegación). El único tramo sensible es el
> grupo 6: `_classified_activity_cte` es el hot path de `/clientes`.

## 1. Checkpoints previos (antes de escribir una línea)

- [x] 1.1 Verificar que no exista ya una función `rpc_receivables_report` (ni un nombre cercano) viva en prod: `SELECT proname FROM pg_proc JOIN pg_namespace n ON n.oid = pronamespace WHERE nspname='public' AND proname ILIKE '%receivable%' OR proname ILIKE '%cobranz%'`. Si existe, parar y reportar antes de seguir (regla de integridad de función).
- [x] 1.2 Confirmar el número de migración libre: `MAX(version)` de `supabase_migrations.schema_migrations` en prod y el último archivo de `supabase/migrations/`. El design asume `20261021000001`; si otro PR se lo llevó, renumerar (precedente: el doble renumerado de `cuenta-corriente-party-guard`).
- [x] 1.3 Registrar el **baseline de producción** para la verificación final: `SELECT count(*), COALESCE(SUM(balance),0) FROM customer_accounts ca JOIN clients c ON c.id = ca.client_id WHERE ca.balance > 0 AND c.deleted_at IS NULL` (exploración 2026-09-02: 11 deudores, $567.000).
- [x] 1.4 Medir el conteo de **deudores con cliente dado de baja** (D5): `... WHERE ca.balance > 0 AND c.deleted_at IS NOT NULL`. Esperado 0. Si es > 0, anotarlo como hallazgo para el PO en el resumen del apply — no resolverlo dentro de este change.
- [x] 1.5 SAFETY NET del grupo 6: correr los tests existentes del read-model de actividad de clientes (`backend/tests/` que ejerciten `list_activity_page` / `get_activity_for` y `frontend/__tests__/` de `/clientes`) y anotar el conteo verde. Un fallo previo se reporta como pre-existente y NO se arregla acá.
- [x] 1.6 Grep de reutilización antes de crear nada: `receivable|cobranz|por cobrar` en `backend/`, `frontend/lib`, `frontend/hooks`, `frontend/components` y `supabase/migrations/`. Confirmar que no hay hook, mapper, componente ni RPC previo que haga esto (o casi).

## 2. Migración: RPC agregado de deudores

- [x] 2.1 RED — Gate SQL `supabase/tests/test_receivables_report.sql`: la función existe, es `SECURITY DEFINER`, tiene `search_path` fijado, y sus ACLs son exactas (`anon` sin `EXECUTE`, `authenticated` con `EXECUTE`, `PUBLIC` revocado). Debe fallar antes de escribir la migración.
- [x] 2.2 GREEN — `supabase/migrations/20261021000001_receivables_report.sql`: `rpc_receivables_report(p_account_id uuid)` `SECURITY DEFINER`, `SET search_path TO 'public'`, guard de membresía contra `account_members` con `P0401` **como primera sentencia**, molde textual de `rpc_payment_method_report`. Devuelve `client_id`, `client_name`, `balance`, `days_since_last_charge`, `days_since_last_payment`, `last_payment_date`, ordenado por `balance DESC`.
- [x] 2.3 GREEN — En el **mismo archivo**: `REVOKE ALL ON FUNCTION ... FROM PUBLIC`, `REVOKE EXECUTE ... FROM anon`, `GRANT EXECUTE ... TO authenticated`, más `COMMENT ON FUNCTION` que nombre el change y las decisiones D4/D5 (tipos de movimiento contados y filas excluidas).
- [x] 2.4 TRIANGULATE — Casos SQL: deudor con saldo positivo aparece; saldo cero no aparece; cliente `deleted_at IS NOT NULL` no aparece; deudor de otro tenant no aparece; no miembro recibe `P0401`; deuda nacida sólo de `adjustment` aparece con antigüedad de cargo nula.
- [x] 2.5 TRIANGULATE — Casos SQL de D4: `payment_received_reversal` no rejuvenece la antigüedad de cobro; `credit_note` y `adjustment` no cuentan como cargo; el día se toma en calendario argentino (cargo de las 22:00 ART cae en el día D).
- [x] 2.6 REFACTOR — Verificar idempotencia ante reaplicación (`supabase db reset` local dos veces) y que el archivo no rompa los gates existentes de ACL (`test_function_acl_gate.sql`) ni el de ERRCODE de 5 caracteres.

## 3. Backend: endpoints de cuentas por cobrar

- [x] 3.1 RED — `backend/tests/test_receivables_report.py`: el repository devuelve el envelope estándar `{items,total,page,pages}` para el listado y `{total_receivable, debtor_count}` para el resumen. Tests contra `asyncpg` mockeado siguiendo el patrón de los tests de `payment_method_repository`.
- [x] 3.2 GREEN — `backend/repositories/customer_account_repository.py`: `list_receivables_page(account_id, *, page, size, sort, sort_dir)` usando el helper canónico `paginate()` con `SELECT * FROM public.rpc_receivables_report($1::uuid)` y su `COUNT`; el orden se traduce por diccionario a columna, nunca por interpolación.
- [x] 3.3 GREEN — `get_receivables_summary(account_id)` agregando **sobre el mismo RPC** (`SUM(balance)`, `COUNT(*)`) — D2, sin un segundo RPC ni un segundo predicado.
- [x] 3.4 GREEN — `backend/schemas/customer_accounts.py`: `ReceivableRowOut`, `ReceivablePageOut`, `ReceivablesSummaryOut` (Pydantic v2, `Decimal` para dinero, `int | None` para las antigüedades).
- [x] 3.5 GREEN — `backend/services/customer_accounts.py`: `list_receivables` y `get_receivables_summary`, sin gate de plan (D10), delegando la autorización de tenant en el `P0401` del RPC.
- [x] 3.6 GREEN — `backend/routers/customer_accounts.py`: `report_router = APIRouter(prefix="/reports/receivables")` con `GET ""` (paginado) y `GET "/summary"`; `sort`/`sort_dir` tipados como `Literal`. Registrar el router en `backend/main.py` junto a los otros `/reports/*`.
- [x] 3.7 TRIANGULATE — Casos de router: página fuera de rango devuelve `items: []` con `total` correcto (no 404); `size` sobre el máximo devuelve 422 problem+json; `sort` fuera del `Literal` devuelve 422 sin ejecutar consulta; `P0401` del RPC se traduce a la respuesta RFC 7807 correspondiente.
- [x] 3.8 TRIANGULATE — Caso del resumen: el `total_receivable` coincide con la suma de los saldos de todas las páginas del listado (el escenario "el total cierra contra la lista" de la spec).
- [ ] 3.9 REFACTOR — Cobertura del módulo nuevo por encima del umbral de CI (≥87%); sin duplicar el predicado de deudor en ningún lado.

## 4. Frontend: capa canónica (mapper, tipos, claves, hooks)

- [x] 4.1 RED — `frontend/__tests__/lib/receivables.test.ts`: el mapper convierte la fila cruda (snake_case, dinero como string) al tipo del dominio; `null` en las antigüedades se preserva como `null` y NO degrada a `0`; el sumador de totales cierra.
- [x] 4.2 GREEN — `frontend/lib/receivables.ts`: `mapReceivableRow`, `sumReceivables`, tipos `ReceivableRow`/`ReceivablesSummary`. **Sin `any`** — tipos explícitos, molde de `lib/payment-method-report.ts`.
- [x] 4.3 GREEN — `frontend/lib/types.ts` y `frontend/lib/query-keys.ts`: tipos del dominio y claves `receivables.list(accountId, page, size, sort, sortDir)` / `receivables.summary(accountId)`.
- [x] 4.4 RED+GREEN — `frontend/hooks/data/use-receivables.ts`: `useReceivables()` y `useReceivablesSummary()` sobre `pythonClient` + `useQuery`, con sus tests.
- [x] 4.5 RED — Test de regresión de D8: registrar un cobro invalida **también** las claves de `receivables`. Debe fallar antes del cambio.
- [x] 4.6 GREEN — Agregar la invalidación de `receivables.*` dentro de `useRegisterPayment` y `useReversePayment` (`hooks/data/use-customer-account.ts`) y en las mutaciones que crean deuda a crédito (formulario de venta y POS). **En el hook, no en la pantalla** (D8).

## 5. Frontend: pantalla `/cobranzas`, sidebar y KPI

- [x] 5.1 RED — Test de la pantalla: renderiza el total en cabecera, una fila por deudor con saldo y antigüedades, `EmptyState` sin deudores, y la antigüedad ausente se muestra como `—` y no como `0`.
- [x] 5.2 GREEN — `frontend/app/(dashboard)/cobranzas/page.tsx`: cabecera con el total (estructura de `CustomerAccountBalance` pero con **tokens semánticos**, D14 — nada de `text-yellow-400`), tabla en `Card` con `overflow-x-auto` + `min-w`, `min-w-0` en la cadena de flex, orden por columna delegado al servidor (D3), paginación estándar.
- [x] 5.3 GREEN — Acción por fila hacia `/clientes/[id]/cuenta` con nombre accesible, y botón **Cobrar** que abre un `Dialog` con el `RegisterPaymentForm` existente — sin prop nueva y sin formulario propio (D8).
- [x] 5.4 GREEN — Nota al pie y rótulos de columna conforme al requirement "El panel no promete mora": "Días desde el último cargo", nunca "mora"/"vencido"; aviso explícito de que el sistema aún no registra vencimientos.
- [x] 5.5 RED+GREEN — `frontend/components/app-sidebar.tsx`: entrada "Cobranzas" en el grupo **Operaciones** (D11), sin `pro`/`proOnly`. Actualizar `__tests__/components/app-sidebar-nav-groups.test.ts` (el test declara los grupos esperados — es el gate de esta task).
- [x] 5.6 GREEN — Nombre de `/cobranzas` en el mapa del breadcrumb de la barra superior.
- [x] 5.7 RED+GREEN — `frontend/components/dashboard/kpi-card.tsx`: prop `href` opcional que convierte la tarjeta en enlace con foco visible (D7), con test; sin romper las cuatro tarjetas existentes que no la pasan.
- [x] 5.8 GREEN — `frontend/app/(dashboard)/dashboard/page.tsx`: 5ª tarjeta "Por cobrar" alimentada por `useReceivablesSummary`, con `href="/cobranzas"`; grilla a `grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-5` (D6).
- [x] 5.9 TRIANGULATE — Test de que el `BranchFilter` del Tablero **no** altera el total por cobrar (OQ-3) y de que el bloque mensual `KpiSummaryBlock` conserva sus 5 tarjetas sin incorporar la nueva.

## 6. Frontend + Backend: saldo y acceso en `/clientes` (tramo sensible)

- [ ] 6.1 RED — Test del read-model: `list_activity_page` devuelve `current_balance` por cliente; el cliente sin cuenta corriente devuelve `0` y no `None`; **el `total` del envelope y la cantidad de filas por página no cambian** respecto del baseline de 1.5.
- [ ] 6.2 GREEN — `backend/repositories/client_repository.py`: `LEFT JOIN public.customer_accounts ca ON ca.account_id = c.account_id AND ca.client_id = c.id` dentro de `_classified_activity_cte` (compartido por lista y detalle, D9), proyectando `COALESCE(ca.balance, 0)::numeric AS current_balance`.
- [ ] 6.3 GREEN — `backend/schemas/clients.py`: `current_balance: Decimal = Decimal("0")` en `ClientActivityOut`.
- [ ] 6.4 TRIANGULATE — Correr el SAFETY NET de 1.5 completo y exigir el mismo verde. Cualquier fallo nuevo bloquea el grupo.
- [ ] 6.5 RED+GREEN — `frontend/hooks/data/use-client-activity.ts` y `frontend/lib/types.ts`: `currentBalance` en el tipo mapeado, con test del mapeo.
- [ ] 6.6 RED+GREEN — `frontend/app/(dashboard)/clientes/page.tsx`: columna "Saldo" (desktop y móvil) + botón de acceso a la cuenta corriente por fila con ícono `Landmark`, `data-testid` y `aria-label`, copiando el patrón de `/proveedores`. El acceso NO debe disparar la activación de la fila que abre el detalle (`stopPropagation`).
- [ ] 6.7 TRIANGULATE — Test de que activar el acceso a la cuenta navega a la cuenta corriente y **no** al detalle del cliente.

## 7. Verificación

- [ ] 7.1 Suite completa de backend en verde (`pytest`), con la cobertura por encima del umbral de CI.
- [ ] 7.2 Suite completa de frontend en verde (`pnpm vitest run`) y `tsc` sin errores nuevos. **Cero `any`** en el código nuevo.
- [ ] 7.3 `supabase db reset` local limpio con la migración nueva, y los gates de `KPI_Validation.yml` en el orden real del workflow (anotar los fallos pre-existentes conocidos en vez de "arreglarlos" en este PR).
- [ ] 7.4 Verificación visual de `/cobranzas`, del Tablero y de `/clientes` en las **cuatro** combinaciones (claro/oscuro × móvil/escritorio), con capturas. Confirmar que ninguna columna desaparece en móvil y que el documento no desborda horizontalmente.
- [ ] 7.5 Pasada de accesibilidad sobre la superficie nueva: nombre accesible de los accesos por fila, foco visible en la tarjeta enlazada del Tablero, contraste ≥4,5:1 en los importes.
- [ ] 7.6 `openspec validate cobranzas-panel --strict` en verde.

## 8. Post-merge (producción)

- [ ] 8.1 `MAX(version)` de `supabase_migrations.schema_migrations` = la migración de este change; ACLs vivas de `rpc_receivables_report` (anon sin `EXECUTE`).
- [ ] 8.2 Contrastar el panel contra el baseline de 1.3: cantidad de deudores y total por cobrar coinciden con la consulta directa a `customer_accounts`.
- [ ] 8.3 Re-medir 1.4 (deudores con cliente dado de baja) y reportar el resultado.
- [ ] 8.4 Humo real con el PO: abrir `/cobranzas`, cobrar a un deudor desde la fila, verificar que sale del panel y que el KPI del Tablero baja; cobrar a otro desde `/clientes/[id]/cuenta` y verificar que el panel se refresca solo (D8).
- [ ] 8.5 Recoger el sign-off de **OQ-1** (¿pestaña espejo "Por pagar"?) y de las OQ-2/3/4; registrar la respuesta en `CHANGES.md`.

## 9. Documentación

- [ ] 9.1 Entrada del change en `CHANGES.md` con las decisiones D1-D14, las OQs y su resolución, y los hallazgos de 1.4 / 8.3.
- [ ] 9.2 Actualizar el puntero "próximo change recomendado" de `CLAUDE.md` y correr `python scripts/ci/check_docs_sync.py --fix` en el **mismo PR** (gate `Docs Sync`).
- [ ] 9.3 Anotar como candidatos, sin resolverlos: refactor de `CustomerAccountBalance` a tokens semánticos (D14) y la Etapa B del módulo de cobranzas (vencimientos, aging, avisos).
