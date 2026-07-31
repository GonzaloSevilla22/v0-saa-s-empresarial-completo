> **Modo TDD estricto.** Cada tarea de código va precedida por su test (RED) y el test debe fallar por la razón esperada antes de escribir la implementación (GREEN). Ninguna tarea `[x]` sin ejecución real de la suite.
> **Governance CRÍTICO** — billing de 34 cuentas reales, una con un pago reconciliado. El agente prepara, migra y testea; **el backfill de producción (grupo 9) requiere OQ-1 resuelta** (confirmación por UUID de las cuentas exentas) y sign-off del PO.
> **Secuencia de cluster**: este change se mergea **antes** que `v31-authz-token-hook` — su claim `plan` consume `get_effective_plan` (ver `design.md` D2).

## 1. Red de seguridad y evidencia previa

- [ ] 1.1 Ejecutar la suite backend completa (`pytest backend/tests`) y la del frontend (`pnpm vitest run`), registrando ambos baselines exactos. Si algo ya falla, **NO** arreglarlo: reportarlo como fallo preexistente y detenerse para confirmar con el orquestador.
- [ ] 1.2 Baseline acotado de los archivos que este change toca: `test_products.py`, `test_clients.py`, `test_suppliers.py`, y los tests de `plan-utils` / `use-plan-limits` / `use-notifications` del frontend.
- [ ] 1.3 Re-verificar contra prod (read-only, MCP) los números que sostienen el diseño y pegarlos en el PR: distribución de `accounts.billing_plan`, cuentas con `trial_expires_at` vigente, `billing_status` de `accounts` vs `profiles`, y los conteos de productos/clientes/proveedores por cuenta. **Si el dimensionamiento del excedente cambió** respecto de `design.md` (§Context), detenerse y revisar D7/D8.
- [ ] 1.4 Confirmar con `pg_get_functiondef` que `expire_trials()` y `queue_trial_notifications()` siguen apuntando a `profiles` (la premisa del diseño). Registrar la definición vigente antes de tocarlas.
- [ ] 1.5 Confirmar con `pg_get_constraintdef` los CHECK vigentes en prod de `accounts` (`billing_plan`, `billing_status`, `trial_plan`) **antes** de escribir cualquier DDL sobre esa tabla (lección C3: enumerar siempre la unión vigente, no la del repo).
- [ ] 1.6 Barrido de lectores de `profiles.billing_*` en migraciones, backend, frontend y edge functions. Cualquier lector vivo que dependa de esas columnas para autorizar se documenta **antes** de declararlas legacy muertas.

## 2. `get_effective_plan` — la definición normativa (D1, D2)

- [ ] 2.1 **RED (DB)** — Escribir el gate de la migración con la tabla compartida de casos de D3: (a) exenta, (b) trial vigente, (c) trial vencido, (d) sin trial, (e) cuenta inexistente, (f) `billing_plan` sin valor útil. Ejecutar `npx supabase db reset` local: debe fallar porque `get_effective_plan` no existe.
- [ ] 2.2 **GREEN** — Migración idempotente que crea `public.get_effective_plan(p_account_id uuid) RETURNS text`, `STABLE SECURITY DEFINER SET search_path = public, pg_temp`, con la precedencia exención → trial vigente → `billing_plan` → `'gratis'`. Ejecutar el reset: el gate de 2.1 pasa.
- [ ] 2.3 **GREEN (permisos)** — En la misma migración: `REVOKE ALL FROM PUBLIC, anon, authenticated` + `GRANT EXECUTE TO supabase_auth_admin, service_role`. Verificar con `has_function_privilege` que `authenticated` **no** puede ejecutarla y que `supabase_auth_admin` sí.
- [ ] 2.4 **TRIANGULATE (DB)** — Caso explícito de fail-closed: una cuenta sin trial y sin `billing_plan` utilizable devuelve `'gratis'` y **nunca** `'pro'`. Verificar además que la función no lanza excepción con un `account_id` inexistente (devuelve `'gratis'`).
- [ ] 2.5 **TRIANGULATE (DB)** — Caso de independencia de `billing_status`: dos cuentas idénticas salvo `billing_status` (los 5 valores del CHECK) devuelven el mismo plan efectivo. Es el test que evita que alguien vuelva a atar el acceso al campo descriptivo (D6).
- [ ] 2.6 Verificar que la función quedó con **una sola** definición (`SELECT count(*) FROM pg_proc WHERE proname='get_effective_plan'` = 1) y documentar en la cabecera de la migración que la firma está congelada en un parámetro (lección 42725: agregar uno crea un overload; hay que `DROP FUNCTION` antes).

## 3. Exención de cortesía auditable (D4)

- [ ] 3.1 **RED (DB)** — Extender el gate: intentar `billing_exempt = true` con `billing_exempt_reason` en NULL debe fallar con violación de CHECK. Ejecutar: falla porque las columnas todavía no existen.
- [ ] 3.2 **GREEN** — En la misma migración: `ADD COLUMN IF NOT EXISTS` de `billing_exempt`, `billing_exempt_reason`, `billing_exempt_granted_at`, `billing_exempt_granted_by` (FK `auth.users`) + el CHECK `billing_exempt = false OR billing_exempt_reason IS NOT NULL`. Ejecutar: 3.1 pasa.
- [ ] 3.3 **GREEN** — `get_effective_plan` incorpora la exención con precedencia máxima. Extender el gate: cuenta exenta con `billing_plan='gratis'` y trial vencido devuelve `'pro'`.
- [ ] 3.4 **TRIANGULATE (DB)** — Verificar que no existe policy que permita a `authenticated` escribir `billing_exempt` sobre su propia cuenta (barrido de `pg_policies` sobre `accounts` + intento explícito de UPDATE bajo el rol `authenticated`).
- [ ] 3.5 **REFACTOR** — `COMMENT ON COLUMN` en las cuatro columnas explicando que la exención es un dato con autor y motivo, no un default, y por qué el CHECK existe.

## 4. Trial PRO de 30 días para cuentas nuevas (D8)

- [ ] 4.1 **RED (DB)** — Gate: una cuenta recién provisionada debe quedar con `trial_plan='pro'` y `trial_expires_at ≈ created_at + 30 días`, y `get_effective_plan` debe devolver `'pro'`. Ejecutar: falla (hoy siembra `'avanzado'`).
- [ ] 4.2 **GREEN** — `CREATE OR REPLACE FUNCTION public.set_new_user_trial()` (misma firma, sin riesgo de overload) con `trial_plan = 'pro'`. Ejecutar: 4.1 pasa.
- [ ] 4.3 **TRIANGULATE (DB)** — Verificar que la cuenta creada por `handle_new_user` **hereda** el trial correcto (la ruta real es `profiles` → `accounts`): registrar un usuario en el reset local y afirmar sobre `accounts`, no sobre `profiles`.
- [ ] 4.4 **TRIANGULATE (DB)** — Verificar que el seeding de sucursal/caja de `v3-provisioning-seed` sigue funcionando tras la redefinición (no regresionar el `EXCEPTION degrade-don't-fail` de esa migración).

## 5. Realineación de los dos cron a `accounts` (D6)

- [ ] 5.1 **RED (DB)** — Gate: tras correr `expire_trials()`, una **cuenta** con trial vencido debe quedar en `billing_status='expired'`. Ejecutar: falla (hoy actualiza `profiles`).
- [ ] 5.2 **GREEN** — `CREATE OR REPLACE FUNCTION public.expire_trials()` (misma firma) operando sobre `public.accounts`, con su `billing_events` de auditoría. Ejecutar: 5.1 pasa.
- [ ] 5.3 **GREEN** — `CREATE OR REPLACE FUNCTION public.queue_trial_notifications()` (misma firma) leyendo `accounts` para las ventanas de 7d y 1d, resolviendo el destinatario vía `account_members` → `auth.users`. Conservar el `ON CONFLICT DO NOTHING` de dedup de `email_logs`.
- [ ] 5.4 **TRIANGULATE (DB)** — (a) una cuenta con `billing_status='active'` o `'cancelled'` no transiciona; (b) una cuenta sin trial cuyo **perfil legacy** sí tiene `trial_expires_at` cargado **no** genera aviso (prueba de que se dejó de leer `profiles`); (c) re-ejecutar ambas funciones dos veces seguidas no duplica filas ni mails.
- [ ] 5.5 **REFACTOR** — `COMMENT ON FUNCTION` de `expire_trials()` declarando explícitamente que es un sweep **descriptivo** y que el gating NO depende de él. Es la lección de este change hecha documentación ejecutable.

## 6. Backend: límites reales desde `plan_limits` (D5)

- [ ] 6.1 **RED** — Test en `test_products.py`: con plan efectivo `avanzado`, el límite aplicado debe ser el de `plan_limits` (1500) y no el hardcodeado (2000). Debe fallar hoy.
- [ ] 6.2 **GREEN** — Repository de límites que lee `plan_limits` con caché en proceso; `backend/services/products.py` lo consume y `PLAN_PRODUCT_LIMITS` se elimina. Respetar las 3 capas (router inyecta, service decide, repository accede). Ejecutar: 6.1 pasa.
- [ ] 6.3 **RED** — Test: una cuenta con plan efectivo `gratis` y 50 clientes recibe 403 al crear el cliente 51. Debe fallar (no hay guard).
- [ ] 6.4 **GREEN** — Guard de límite en la creación de clientes, con el mismo predicado `current_count >= limit` de productos. Ejecutar: 6.3 pasa.
- [ ] 6.5 **GREEN** — Guard equivalente en la creación de proveedores, con su test RED previo.
- [ ] 6.6 **TRIANGULATE** — (a) excedente de un recurso **no** bloquea otro (513 clientes + 9 productos → crear producto se permite); (b) los recursos existentes por encima del límite se **listan y editan** sin error; (c) borrar por debajo del límite restablece la creación; (d) registrar una **venta** con `max_operations_per_month` superado **se permite** (D7).
- [ ] 6.7 **REFACTOR** — Verificar por barrido que no queda ninguna otra constante de límite de plan hardcodeada en el backend, y que ningún service recomputa el plan efectivo (sólo lee el claim — D3).

## 7. Frontend: espejo del plan efectivo y tipo de notificación (D3, D9)

- [ ] 7.1 **RED** — Test de paridad en Vitest con la **misma tabla de casos** del gate de 2.1: exenta, trial vigente, trial vencido, sin trial, cuenta inexistente, `billing_plan` ausente. Debe fallar en el caso "exenta" (el TS no conoce la exención).
- [ ] 7.2 **GREEN** — `frontend/lib/plan-utils.ts::getEffectivePlan` incorpora la exención con la misma precedencia. Ejecutar: 7.1 pasa.
- [ ] 7.3 **TRIANGULATE** — Prueba de que el test de paridad **detecta** la deriva: alterar deliberadamente la precedencia en el TS y verificar que la verificación falla identificando el caso; revertir. (Evita que el test de paridad sea una tautología.)
- [ ] 7.4 **RED** — Test del `NotificationBell`: una notificación `PlanLimitExceeded` se renderiza con etiqueta legible. Debe fallar (el tipo no existe en el union).
- [ ] 7.5 **GREEN** — Agregar `PlanLimitExceeded` a `NotificationType` en `frontend/lib/types.ts` y su entrada en `TYPE_LABELS`. Ejecutar: 7.4 pasa.
- [ ] 7.6 **REFACTOR** — Confirmar que el banner "Límite alcanzado" ya especificado en `plan-gating` cubre clientes y proveedores además de productos, **reutilizando** el componente existente. No se crea UI nueva.

## 8. Aviso de excedente por el Consumer 4 (D9)

- [ ] 8.1 **RED (DB)** — Gate: un evento `PlanLimitExceeded` procesado por el relay debe producir una fila en `notifications` con `severity='warning'`, audiencia = owners y payload con `resource`/`current`/`limit`/`plan`. Ejecutar: falla (el tipo no está en la lista en-scope).
- [ ] 8.2 **GREEN** — `CREATE OR REPLACE FUNCTION public._notification_from_event(public.events)` (**misma firma** — verificar que no se crea un segundo overload) agregando `PlanLimitExceeded` a la lista y su mapeo a target `ADMIN` + severidad `warning`. Ejecutar: 8.1 pasa.
- [ ] 8.3 **TRIANGULATE (DB)** — Los 5 tipos previos siguen despachando igual (regresión del Consumer 4) y un tipo fuera de la lista sigue siendo no-op.
- [ ] 8.4 **RED (DB)** — Gate del producer: el barrido detecta las cuentas en excedente y emite un evento por `(cuenta, recurso)`. Casos: cuenta con 101 productos y límite 100 → 1 evento; cuenta con 99 y límite 100 → 0 eventos.
- [ ] 8.5 **GREEN** — Producer del barrido que compara los conteos vivos contra `plan_limits` para el plan efectivo de cada cuenta e inserta en `events`. Programarlo con `pg_cron` (la extensión ya está instalada). Ejecutar: 8.4 pasa.
- [ ] 8.6 **TRIANGULATE (DB)** — Dedup: (a) segunda corrida a los 2 días no duplica el aviso del mismo recurso; (b) un recurso **distinto** sí genera aviso; (c) pasados 7 días vuelve a emitirse. Verificar con la cuenta de 2372 productos que en 7 días recibe **1** aviso y no 7.
- [ ] 8.7 **TRIANGULATE (DB)** — Prueba de independencia: con el barrido **desactivado**, una cuenta en excedente sigue recibiendo el rechazo al crear (el enforcement no depende del aviso — spec de `billing-trial-lifecycle`).

## 9. Backfill de producción — **gate OQ-1 + PO** (D4, D8)

- [ ] 9.1 **Gate OQ-1** — Entregar al PO la lista de exentas con UUID: `0f627a85-7d01-4323-8b3f-122bd834a4ab` (pagadora, `danielsevilla64@gmail.com`) y `3834e5d7-f3a9-4496-8fdd-84edf8a8b252` (cortesía, `susanacavagnola@gmail.com` / "Sumar Ropa Deportiva"), señalando que **el email del sign-off tiene un typo** y que las exenciones (2) y (3) son la misma cuenta. **Bloquea 9.3.** Registrar la confirmación por escrito.
- [ ] 9.2 **RED (DB)** — Gate del backfill: tras aplicarlo, exactamente N cuentas quedan exentas y el resto con `trial_plan='pro'`, `billing_plan='gratis'` y `trial_expires_at` a 30 días; y existe una fila de `billing_events` por cada cuenta tocada.
- [ ] 9.3 **GREEN** — Migración de backfill **separada** de la de esquema: marca las exentas (con motivo + `granted_by` + `billing_events` de tipo `exemption_granted`) y otorga el trial PRO al resto, acotada por `WHERE billing_exempt = false AND trial_plan IS DISTINCT FROM 'pro'`, con `billing_events` de tipo `trial_pro_granted` guardando el `billing_plan` anterior en `from_plan`.
- [ ] 9.4 **TRIANGULATE (idempotencia)** — Aplicar la migración de backfill **dos veces seguidas** en local y afirmar que `trial_expires_at` **no se mueve** en la segunda pasada y que no se duplican filas en `billing_events`. Es el riesgo #1 del change: el pipeline aplica las migraciones dos veces por diseño (integración GitHub + `db push` de Actions).
- [ ] 9.5 **Verificación en prod (read-only, tras el merge)** — Confirmar: 2 cuentas con `billing_exempt=true` y motivo escrito; 32 con `trial_plan='pro'` y vencimiento a 30 días; 34 filas nuevas en `billing_events`; y que `get_effective_plan` devuelve `'pro'` para las 34 (todas en trial o exentas) en ese instante.
- [ ] 9.6 Documentar el procedimiento de reversión concreto: el `UPDATE` que restaura `billing_plan` desde `billing_events.from_plan` y el que baja `billing_exempt`. Sin backups, sin DDL destructivo.

## 10. Cierre y handoff al cluster

- [ ] 10.1 Ejecutar las suites backend y frontend completas **dos veces seguidas** (descarta flake) y confirmar el conteo de tests nuevos respecto del baseline de 1.1.
- [ ] 10.2 Correr los advisors de Supabase y confirmar que `get_effective_plan` y las funciones redefinidas no abren hallazgos nuevos de `function_search_path_mutable` ni de RLS.
- [ ] 10.3 Verificar en prod que las funciones redefinidas quedaron con **una sola** definición cada una (`expire_trials`, `queue_trial_notifications`, `set_new_user_trial`, `_notification_from_event`, `get_effective_plan`) — el chequeo de overload duplicado que la lección C3/42725 exige.
- [ ] 10.4 Anotar en `v31-authz-token-hook` que su claim `plan` debe llamar a `get_effective_plan` y que, gracias a que es `SECURITY DEFINER`, **ya no necesita `GRANT SELECT` sobre `accounts`** para el hook — sólo `GRANT EXECUTE` sobre la función (D2). Ajustar sus tareas 3.2 y 3.3 en consecuencia.
- [ ] 10.5 Abrir el PR con la tabla de evidencia del ciclo TDD (tarea / archivo de test / safety net / RED / GREEN / TRIANGULATE / REFACTOR), los números de prod de 1.3, el dimensionamiento del excedente y la decisión del PO sobre OQ-1.
- [ ] 10.6 Registrar las Open Questions vivas (OQ-2 enforcement de contadores mensuales, OQ-3 trato de las 5 cuentas con trial `avanzado` en curso) donde el PO las vea, sin resolverlas en este change.
