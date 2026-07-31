## Context

### Estado actual verificado (auditoría de este propose)

`billing-pro-trial` (migración `20260817000001`, PR #313, mergeado en `620d9cc`) estableció `public.get_effective_plan(account_id)` como **la definición normativa única** del plan efectivo: `STABLE SECURITY DEFINER`, precedencia exención → trial vigente → `accounts.billing_plan` → `'gratis'` fail-closed, y deliberadamente **nunca lee `billing_status`**.

Tres archivos de Edge Functions quedaron fuera de esa unificación:

| Archivo | Qué hace hoy | Funciones afectadas |
|---|---|---|
| `supabase/functions/_shared/ai-quota.ts:31-45,57-59` | `getEffectivePlan(profile)` local sobre `profiles` | 8 (`ai-insights`, `ai-comparativo`, `ai-precio`, `ai-prediccion`, `ai-rentabilidad`, `ai-resumen`, `ai-simulador`, `fair-advisor`) |
| `supabase/functions/ai-precio/index.ts:129-155` | lógica de trial inline + `allowedPlans = ['avanzado','pro']` hardcodeado | 1 |
| `supabase/functions/generate-export/index.ts:24-37,180-190` | `getEffectivePlan(profile)` local sobre `profiles` | 1 |

Las tres implementan la variante **vieja** de la regla: `billing_status === 'trialing'` como condición del trial, sin `billing_exempt`. `billing-pro-trial` (D6) declaró `billing_status` descriptivo y no autoritativo, y agregó la exención con precedencia máxima.

### El hallazgo que define la severidad

`profiles.billing_plan` se creó en `20260605000001_billing_schema.sql:43` con `NOT NULL DEFAULT 'gratis'`. Un barrido sobre migraciones, `backend/` y `frontend/` no encontró **ni un solo `UPDATE` de esa columna**: sus únicas apariciones son el `ADD COLUMN`, su `CHECK` y un índice. La autoridad está en `accounts`:

- Webhook de pagos: `backend/services/payments.py:168` → `UPDATE ... SET billing_plan = $1, billing_status = 'active'` sobre `accounts`.
- Exención: `accounts.billing_exempt` (solo `accounts`).
- `get_effective_plan`: lee `accounts`.

Por lo tanto `profiles.billing_plan` vale `'gratis'` para todas las cuentas, siempre. El único motivo por el que el gating de IA no está roto para todos es que `set_new_user_trial()` sí escribe `profiles.trial_plan` + `billing_status='trialing'`, lo que hace coincidir la copia stale durante los 30 días de trial. Vencido el trial, o pagada la suscripción, la divergencia es total.

### Restricción central descubierta

`get_effective_plan(uuid)` tiene los permisos **revocados** para el rol con el que corren las Edge Functions:

```sql
REVOKE ALL ON FUNCTION public.get_effective_plan(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_effective_plan(uuid) TO supabase_auth_admin, service_role;
```

Las Edge Functions construyen su cliente con la **anon key + el header `Authorization` del usuario**, por lo que actúan como `authenticated`. Un `supabase.rpc('get_effective_plan', { p_account_id })` directo fallaría con *permission denied*. El pedido original ("migrar a `get_effective_plan` vía RPC") no es aplicable tal cual: hace falta una vía de invocación. Eso es la decisión D1.

## Goals / Non-Goals

**Goals:**
- Que las tres capas de Edge Function obtengan el plan efectivo de **la** definición normativa, sin reimplementarla.
- Que una cuenta que pagó, o exenta, reciba la cuota de IA y el límite de exportaciones que le corresponden.
- Que quede **una sola** vía de resolución del plan efectivo en `supabase/functions/`, testeada.
- Eliminar el último límite de plan hardcodeado en Edge Functions (`allowedPlans` en `ai-precio`).

**Non-Goals:**
- Migrar los contadores de uso a `accounts` (D3 / OQ-2).
- Tocar la renovación/suscripción de MercadoPago ni el webhook H-02 (change aparte, ya firmado).
- Tocar el cron de gracia.
- Alinear el backend Python (le corresponde a `v31-authz-token-hook`, vía claim del token).
- Tocar el frontend: `frontend/lib/plan-utils.ts` ya es el espejo correcto post-`billing-pro-trial`.
- Introducir "cuenta activa" seleccionable (pertenece a `v3-rbac-multirole`).

## Decisions

### D1 — Wrapper RPC `rpc_my_effective_plan()` sin argumentos

**Decisión:** agregar una función delgada que resuelve la cuenta del llamador y delega en `get_effective_plan`, con `EXECUTE` para `authenticated`:

```
public.rpc_my_effective_plan() RETURNS text
  STABLE SECURITY DEFINER, SET search_path = public, pg_temp
  → resuelve la cuenta del llamador vía la regla de D2
  → RETURN public.get_effective_plan(<esa cuenta>)
  → sin cuenta resoluble: RETURN 'gratis'   (fail-closed, igual que la normativa)
GRANT EXECUTE TO authenticated;
```

`get_effective_plan(uuid)` **no cambia**: conserva su firma congelada y sus grants revocados. Esto importa por la lección 42725 registrada en el repo — agregar un parámetro a una función existente crea un segundo overload; acá no se toca la firma de nada, solo se crea una función nueva con nombre propio.

**Alternativas consideradas:**
- **(A) Cliente `service_role` dentro de la Edge Function.** Funciona sin migración y `generate-export` ya crea uno para Storage. Rechazada como opción por defecto: propaga `service_role` a 8 funciones de IA que hoy no lo necesitan, y `service_role` bypasea toda la RLS — ampliar su superficie por una lectura de un `text` es desproporcionado. Queda como plan B si el PO prefiere cero DDL (OQ-1).
- **(C) `GRANT EXECUTE` de `get_effective_plan` a `authenticated`.** **Rechazada por seguridad**: la función es `SECURITY DEFINER` y recibe un `account_id` arbitrario, así que cualquier usuario autenticado podría sondear el plan de cualquier cuenta. Contradice explícitamente D2 de `billing-pro-trial`.

La ventaja estructural de (B) es que el llamador **no elige** la cuenta: la función la deriva de `auth.uid()`. Es imposible por construcción que devuelva el plan de una cuenta ajena.

### D2 — Resolución de la cuenta del llamador

El helper canónico ya existe: `public.current_account_ids()` (`20260606000001_tenant_tables.sql:108`), `STABLE SECURITY DEFINER`, `GRANT` a `authenticated`, devuelve `SETOF uuid` con las cuentas donde el usuario es miembro. `rpc_my_effective_plan()` lo reutiliza en vez de inventar una consulta nueva sobre `account_members`.

Regla determinista para el caso multi-cuenta: tomar la cuenta de la membresía **más antigua** (`account_members` ordenado por su fecha de alta, desempate por `account_id`), documentado en el `COMMENT` de la función. Esto reemplaza al `.single()` de `ai-precio:111-115`, que **lanza error** con 2+ membresías. Hoy no se dispara (los 34 miembros de prod son owner de exactamente una cuenta), pero deja de ser una bomba latente. La noción de "cuenta activa" elegible es de `v3-rbac-multirole`; acá solo se garantiza determinismo (OQ-4).

### D3 — Los contadores de uso quedan fuera

**Hallazgo:** no están rotos. `ai_queries_used`, `ai_advice_used`, `usage_reset_at` (`20260605000001:65-67`) y `exports_used` (`20260610000000:24`) viven **solo** en `profiles`; `accounts` no tiene columnas equivalentes. La fila de `profiles` existe para cada usuario (la inserta `handle_new_user`), `rpc_increment_ai_usage` (`20260606100000`) hace el `UPDATE` atómico y el cron mensual resetea. Todo eso funciona.

Lo que sí hay es una divergencia semántica: los contadores son **por usuario** mientras que el plan que fija el límite es **por cuenta**. Una cuenta de 3 miembros dispone de 3× la cuota nominal de su plan.

**Decisión: fuera de alcance.** Corregir el plan sin tocar los contadores es una mejora estricta y sin regresión: un usuario PRO pasa de comparar su contador contra 5 a compararlo contra 300. Migrar los contadores a `accounts` requiere migración de esquema + backfill + los 8 consumidores + el cron + los hooks del frontend — es un change propio. Se propone `billing-usage-counters-per-account` (OQ-2).

Consecuencia para el código: `checkAiQuota` **sigue leyendo el contador desde `profiles`**, pero deja de leer de ahí el plan. La consulta a `profiles` se reduce a las columnas de contador.

### D4 — Los límites ya son canónicos; se elimina el último hardcode

`plan_limits` es tabla con lectura pública por RLS (`plan_limits_public_read`) y ambas funciones ya la consultan en runtime — no hay límites numéricos hardcodeados que corregir. `billing-pro-trial` no introdujo una fuente de límites nueva; solo alineó `avanzado.max_products` a 2000.

La única excepción es `ai-precio:148` → `const allowedPlans = ['avanzado', 'pro']`. `plan_limits` ya tiene el flag exacto para eso: `has_price_suggestion`, sembrado en `true` para `avanzado` y `pro` (`20260605000001:153-156`). Se reemplaza el array por el flag, con lo que la Edge Function cumple el requisito ya vigente "Lectura de límites desde DB en runtime" y un cambio futuro de política de planes no requiere redeploy de la función.

### D5 — Fail-closed al resolver el plan, fail-open al leer los límites

Hoy `checkAiQuota` falla **abierto** en ambos pasos (`ai-quota.ts:64,75`). La regla normativa es fail-**closed** (`get_effective_plan` devuelve `'gratis'` ante cuenta inexistente y ante cualquier valor no reconocido, con el comentario explícito "nunca el plan más alto").

**Decisión:** espejar la DB — si el plan no se puede resolver, tratar como `'gratis'`; si `plan_limits` no se puede leer, conservar el fail-open actual (sin fila de límites no hay contra qué comparar, y bloquear sería un fallo de disponibilidad, no de autorización). El RPC ya devuelve `'gratis'` en vez de lanzar, así que el camino de error queda concentrado en un solo lugar.

Trade-off honesto: durante un error transitorio, un cliente que paga ve la cuota de gratis. Es el precio de no volver a conceder de más, y es la postura que el change padre ya fijó (OQ-3).

### D6 — Módulo compartido puro + tests con el runner que ya existe

**Hallazgo sobre testing:** el repo **no tiene** harness de Deno — no hay `deno.json`, ni archivos `*_test.ts` bajo `supabase/functions/`, ni `deno` en ninguno de los tres workflows (`KPI_Validation.yml`, `deploy.yml`, `keep-backend-warm.yml`). `supabase/tests/` contiene SQL, no Deno. La convención vigente para probar lógica de Edge Functions es **vitest desde `frontend/__tests__/`**, y `frontend/__tests__/ai-precio.test.ts:13-17` la documenta explícitamente: *no se puede importar desde `supabase/functions/`, así que se re-declaran las funciones puras*.

Duplicar la lógica en el test es exactamente la enfermedad que este change cura: un test que copia la regla no detecta que la Edge Function divergió de la DB.

**Decisión:** crear `supabase/functions/_shared/effective-plan.ts` con la resolución **pura e inyectable** — recibe el cliente Supabase como parámetro y **no referencia `Deno.*` en scope de módulo**. Esa única restricción lo vuelve importable por vitest mediante ruta relativa: vitest resuelve con esbuild en runtime y no depende del `tsconfig` que excluye `supabase/`. El test importa el archivo **real** y le inyecta un doble del cliente; si la Edge Function cambia de regla, el test lo ve.

No se propone un runner de Deno nuevo: agregarlo significaría un cuarto workflow y una segunda toolchain en CI para tres archivos. Si el PO prefiere Deno nativo, es un change de infraestructura aparte.

Cobertura en dos niveles:
- **vitest** (`frontend/__tests__/`): resolución del plan efectivo y su propagación a los tres puntos de decisión (cuota de IA, gate de `ai-precio`, gate de exportaciones), con dobles del cliente.
- **Gates SQL** embebidos en la migración (convención del repo: `v31-fsm-status-triggers`, `billing-pro-trial`): estructurales siempre; de comportamiento solo con `accounts` vacía (CI), con anchor sintético y limpieza best-effort.

### D7 — Sin cambio de contrato HTTP

Los códigos y cuerpos de respuesta se mantienen: `429 { ok:false, error:'quota_exceeded', resetAt, used, limit }`, `403 { ok:false, error:'plan_required', required_plan:'avanzado' }`, `403 { ok:false, error:'export_not_allowed', plan }`. Solo cambia **el valor del plan** con el que se decide. El frontend no requiere cambios.

## Risks / Trade-offs

- **[Un cliente que hoy accede pierde acceso]** → La auditoría descartó el escenario: `profiles.billing_plan` nunca supera su default `'gratis'`, así que la copia stale solo puede subestimar el plan, nunca sobreestimarlo. El único caso en que la copia stale es *más alta* es el trial, y ahí `accounts` tiene los mismos valores (`handle_new_user` los copia). Verificación explícita en tasks antes del deploy.

- **[El RPC nuevo se convierte en un camino caliente]** → `get_effective_plan` es `STABLE` y `rpc_my_effective_plan` también; es una lectura indexada por PK de `accounts` más una de `account_members` (índice `idx_account_members_user_id` ya existe). Se invoca una vez por request de Edge Function, en un camino que a continuación llama a OpenAI (segundos). Costo despreciable.

- **[Fail-closed degrada a un cliente que paga ante un error transitorio]** → D5. Mitigación: el RPC devuelve `'gratis'` en vez de lanzar, y se registra un `console.error` con el `account_id` para que la degradación sea observable en los logs de la función en vez de silenciosa.

- **[La divergencia vuelve a aparecer en una Edge Function futura]** → Un solo módulo compartido (`_shared/effective-plan.ts`) más el requisito de spec que prohíbe explícitamente a la capa Edge Function redefinir la regla. El test importa el módulo real, así que una reimplementación local no queda cubierta y se nota en review.

- **[Los contadores siguen siendo por usuario]** → Aceptado y documentado (D3/OQ-2). No es una regresión introducida por este change; es una deuda preexistente que este change deja explícita en vez de tapada.

- **[La migración se aplica dos veces]** → El pipeline de este proyecto aplica migraciones dos veces por diseño (integración GitHub de Supabase + `db push` de Actions). La migración usa `CREATE OR REPLACE` + `DROP FUNCTION IF EXISTS` de la firma previa y no hace backfill, por lo que es reaplicable sin efecto acumulativo.

## Migration Plan

1. Migración aditiva: `rpc_my_effective_plan()` + `GRANT` a `authenticated` + gates SQL. No toca datos ni la firma de `get_effective_plan`.
2. Edge Functions: módulo compartido nuevo y los tres archivos migrados a usarlo. Se despliegan con el pipeline habitual de funciones.
3. Orden: **la migración debe estar aplicada antes de desplegar las funciones**. Si las funciones salieran primero, el RPC no existiría y —por D5— toda cuenta caería a `'gratis'`, empeorando el bug durante la ventana. En tasks esto es un gate explícito de secuencia.
4. Verificación post-deploy (read-only): confirmar una sola definición de `rpc_my_effective_plan`, que `authenticated` tiene `EXECUTE`, que `get_effective_plan` **sigue** revocada para `authenticated`, y que la cuenta con pago reconciliado resuelve a su plan pagado.

**Rollback:** revertir los archivos de Edge Function y redesplegar (vuelven a leer `profiles`, restaurando el comportamiento actual). La función SQL puede quedar instalada sin efecto, o eliminarse con `DROP FUNCTION IF EXISTS public.rpc_my_effective_plan();`.

## Open Questions

Las cuatro OQ que requieren decisión del PO antes del apply están enumeradas con su recomendación en `proposal.md` § *Open Questions*: **OQ-1** vía de invocación (recomendado: wrapper RPC), **OQ-2** contadores de uso (recomendado: fuera de alcance), **OQ-3** fail-closed (recomendado: sí, espejando la DB), **OQ-4** usuario multi-cuenta (recomendado: regla determinista documentada, sin "cuenta activa").

Governance **CRÍTICO**: sin sign-off explícito del PO sobre las cuatro, `/opsx:apply` no debe ejecutarse.
