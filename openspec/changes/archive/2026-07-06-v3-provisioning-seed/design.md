# Design — v3-provisioning-seed

## Context

El modelo V3 §7.5 (`modelo-dominio-aliadata-v3.md`) define el "comando de provisioning" de un tenant nuevo: Branch "Casa Central", Cashbox default, lista de precios default, plan de cuentas mínimo, unidades de medida, formas de pago. Criterio de aceptación: **un tenant recién creado puede vender en menos de 5 minutos** (registro → quickSale sin configuración manual).

**Estado actual verificado contra las migraciones reales** (el gap-analysis de CHANGES.md tenía imprecisiones — cada punto de abajo fue confirmado leyendo el SQL):

| Estructura | Estado real | Fuente |
|---|---|---|
| `handle_new_user` | AFTER INSERT sobre `auth.users`, SECURITY DEFINER. Crea: profile → account → membership `owner` → 2 email_logs. **NO crea branch ni cashbox.** Última definición deployada: `20260801000003_register_province_admin_email.sql` (NO la de `20260800000003`) | migraciones listadas |
| Branch default "Casa Central" | Se crea **perezosamente**, solo en el primer movimiento de stock (`c21_apply_branch_stock_delta`, `20260625000001` L186: `INSERT ... ON CONFLICT (account_id, name) DO NOTHING`). Un tenant que nunca movió stock NO tiene branch | `20260625000001_c26_branch_as_root.sql` |
| `cashboxes` | Existe (C-28): `id, branch_id NOT NULL FK, name, currency default 'ARS', created_at`. **Sin `is_default`, sin UNIQUE de nombre, sin auto-creación en ningún lado.** RLS solo SELECT; escritura vía RPCs DEFINER | `20260701000001_c28_cash_session.sql` |
| `price_lists` | **NO existe la tabla** (0 `CREATE TABLE`) | grep exhaustivo |
| Formas de pago | **NO hay tabla ni enum.** Única representación: CHECK `payment_method IN ('cash','other')` en `sales_orders` (C-29) — ni siquiera los 4 valores del V3 | `20260702000001` |
| Plan de cuentas | **NO hay tabla** — diferido explícitamente a V2.6; los códigos ('1100', '4100'…) están hardcodeados en `_journal_post_from_event`; hay un test que PROHÍBE crear la tabla (`backend/tests/outbox/test_journal_consumer.py` D1) | `20260803000001` |
| `units_of_measure` | Existe con `user_id` nullable + `account_id` + `is_system`. **Las unidades sistema YA fueron seedeadas globalmente** (Unidad, Docena, Ciento, Gramo, Kilogramo, Tonelada, Mililitro, Litro, Milímetro, Centímetro, Metro — `20260509211504`) y la RLS `uom_account_select` (`is_system = true OR account_id IN current_account_ids()`) las hace **visibles a todo tenant nuevo sin seed adicional** | `20260509211504`, `20260606000004` L196-198 |

**El gap real es exactamente dos piezas**: branch default eager + cashbox default. Todo lo demás del §7.5 o ya está resuelto (unidades) o no existe como estructura seedable (listas de precios, formas de pago, plan de cuentas).

Restricciones duras del proyecto que condicionan el diseño:

1. **Supabase GitHub integration auto-aplica migraciones al mergear a main, ANTES del `db push` de Actions** (confirmado 2× el 2026-07-06) → la migración debe ser idempotente / both-worlds-safe.
2. **CI (`validate-kpis`) corre las migraciones sobre una DB vacía** — los behavior gates degradan con `RAISE NOTICE`, nunca abortan en prod.
3. **Insertar un `auth.users` sintético dispara `handle_new_user`**, que auto-crea account+membership → los gates NUNCA insertan accounts a mano; resuelven vía `account_members` y limpian hijo→padre por email del anchor, dejando `accounts=0` al final del reset. Este change modifica el trigger mismo, así que su gate es doblemente sensible.
4. Governance **MEDIO**: `handle_new_user` es el camino de registro — si el trigger raisea, el signup falla.

## Goals / Non-Goals

**Goals:**

- Tenant nuevo = branch "Casa Central" + cashbox default creados **en el mismo signup** (eager), sin configuración manual.
- Backfill idempotente de las ~29 cuentas existentes: solo lo que falte, conflict-safe.
- El seed **no puede romper el registro**: cualquier fallo degrada, no aborta.
- Gate de comportamiento en la migración que verifica el criterio "puede vender en <5 min" a nivel DB, auto-limpiante.

**Non-Goals:**

- **Lista de precios default**: la tabla `price_lists` no existe. Crear la tabla + seed es OTRO change (violaría el principio de este: completar provisioning de estructuras EXISTENTES). Queda como nota para el roadmap V3.
- **Formas de pago (EFECTIVO/TRANSFERENCIA/MERCADOPAGO/CTA_CTE)**: no hay tabla ni enum que seedear; hoy es un CHECK de 2 valores en `sales_orders`. Convertirlo en catálogo es un change propio (impacta C-29, journal routing y UI). FUERA.
- **Plan de cuentas mínimo**: diferido a V2.6 por decisión previa (D1 de journal-entry-outbox); un test lo prohíbe activamente. FUERA — exactamente como anticipaba CHANGES.md ("probablemente queda FUERA con nota").
- **Unidades de medida**: ya provisionadas globalmente vía `is_system=true` + RLS. No hay nada per-tenant que seedear. FUERA (verificado, no supuesto).
- Tocar backend Python/FastAPI o frontend: el provisioning es 100% DB-side; no se expone API nueva.
- `is_default` en `cashboxes` o `branches`: la convención existente es "la más antigua activa" (`c26_default_branch`); no se agrega columna.

## Decisions

### D1 — Qué se siembra: branch "Casa Central" + cashbox "Caja Principal" (ARS), nada más

Alternativas: (a) seedear todo el §7.5 literal → imposible, las estructuras no existen (ver tabla de Context); (b) crear las tablas faltantes en este change → explota el alcance y contradice KISS; (c) **elegida**: seedear las dos estructuras existentes que forman el camino crítico de venta (branch → cashbox → cash session → quickSale). El resto queda documentado como Non-Goal con justificación verificada.

### D2 — Seed eager DENTRO de `handle_new_user` (no en un RPC aparte, no lazy)

Alternativas: (a) extender el lazy-create existente a cashboxes → no cumple el criterio V3 (el tenant sigue sin poder abrir caja hasta mover stock); (b) RPC de onboarding llamado por el frontend → agrega un paso frágil fuera de la transacción del signup y requiere deploy coordinado de frontend; (c) **elegida**: extender el trigger, que ya es el punto único de provisioning (patrón establecido por `20260800000003`). El INSERT directo a `cashboxes` desde el trigger es legítimo: `handle_new_user` es SECURITY DEFINER, igual que los RPCs de C-28.

### D3 — El seed degrada, no aborta (sub-bloque `BEGIN … EXCEPTION WHEN OTHERS THEN RAISE WARNING … END`)

El trigger corre dentro del signup de Supabase Auth: un raise = registro roto (incidente CRÍTICO, como el bug de 2026-06-24). Alternativas: (a) inline sin protección, confiando en `ON CONFLICT` → un fallo imprevisto (p.ej. cambio futuro de schema en `branches`) rompería TODOS los registros; (b) **elegida**: el bloque branch+cashbox va aislado en un sub-bloque con `EXCEPTION WHEN OTHERS`, que loguea `RAISE WARNING` y deja seguir. La red de seguridad lazy-create de `c21_apply_branch_stock_delta` sigue existiendo aguas abajo, así que la degradación es recuperable. El core del provisioning (profile/account/membership) queda FUERA del sub-bloque: si eso falla, el signup DEBE fallar (comportamiento actual, correcto).

### D4 — Backfill SÍ, en la misma migración, espejo de `20260800000003` (Parte A backfill + Parte B trigger)

El criterio V3 habla de tenants nuevos, pero dejar ~29 cuentas sin caja genera carga de soporte y un estado bimodal difícil de razonar. Alternativas: (a) solo signups nuevos → soporte manual para los existentes; (b) script manual del PO → se olvida; (c) **elegida**: backfill idempotente en la misma migración. Conflict-safe en dos pasos: (A.1) branch "Casa Central" solo para cuentas con CERO branches (`NOT EXISTS`) — muchas ya tienen "Casa Central"/"Principal" del lazy-create y el UNIQUE `(account_id, name)` + `ON CONFLICT DO NOTHING` protege el resto; (A.2) cashbox default solo para cuentas cuya branch default (via `c26_default_branch`) no tenga ninguna cashbox (`NOT EXISTS` sobre `cashboxes.branch_id` de las branches de la cuenta — `cashboxes` no tiene UNIQUE, el guard es obligatorio).

### D5 — Idempotencia total / both-worlds-safe

Por la lección del auto-apply de Supabase (la migración puede correr 2 veces o en orden distinto al esperado): `CREATE OR REPLACE FUNCTION`, todos los INSERT con `ON CONFLICT DO NOTHING` o guard `NOT EXISTS`, cero DDL de schema (no se agregan columnas ni tablas), cero asunciones de orden. La nueva definición del trigger se basa en la **última versión deployada** (`20260801000003_register_province_admin_email.sql` — profile con name/last_name/terms/opt-in/province + account + membership + 2 emails), NO en la de `20260800000003`; solo se agrega el bloque de seed. Regla dura aprendida: enumerar la definición vigente antes de reemplazar (mismo patrón que la lección del CHECK de `operation_idempotency`).

### D6 — Verificación del criterio "<5 minutos para vender": gate SQL de comportamiento, NO E2E Playwright

El proyecto valida migraciones únicamente en CI `validate-kpis` (DB vacía, sin Docker local); no existe lane de E2E Playwright para migraciones, y montarlo para este change sería desproporcionado. **Elegida**: DO-block gate en la migración, patrón establecido (`20260808000001`, `20260804000008`, `20260809000001`):

1. Inserta anchor sintético `auth.users` (email `*@test.local`, `ON CONFLICT DO NOTHING`) → dispara el trigger real.
2. Resuelve la account vía `account_members` (NUNCA la inserta a mano).
3. **Asserts del criterio**: (i) existe exactamente 1 branch "Casa Central" activa para esa account; (ii) existe ≥1 cashbox sobre esa branch con `currency='ARS'`; (iii) re-ejecutar el seed no duplica (idempotencia). El encadenamiento branch→cashbox ES el prerequisito DB de quickSale + sesión de caja: si el gate pasa, el tenant puede operar sin setup manual — esa es la verificación realista del criterio a este nivel.
4. Limpieza hijo→padre por email del anchor (cashboxes → branches → account_members → accounts → profiles → auth.users), `accounts=0` al final.
5. Si el contexto no permite el gate (p.ej. prod sin permisos de insert en `auth.users`, o datos ausentes): `RAISE NOTICE` y salir — nunca abortar.

Complemento manual (task de verificación post-deploy, no bloqueante): registrar un usuario de prueba en prod y cronometrar registro → venta quickSale (T3 manual, mismo espíritu que el de `20260800000003`).

### D7 — Sin cambios de RLS ni de RPCs

`branches` y `cashboxes` ya tienen RLS y sus caminos de escritura DEFINER. El trigger es DEFINER y bypasea RLS por diseño (patrón establecido). No se toca ninguna policy.

## Risks / Trade-offs

- **[El trigger es el camino de registro]** → El seed va en sub-bloque EXCEPTION que degrada a WARNING (D3); el core provisioning queda intacto fuera del sub-bloque; el gate de CI ejercita el trigger real en cada reset; queda el lazy-create como red aguas abajo.
- **[Doble aplicación de la migración (auto-apply + db push)]** → Idempotencia total (D5): `ON CONFLICT`/`NOT EXISTS` en todos los INSERT, `CREATE OR REPLACE` para el trigger, sin DDL.
- **[El gate modifica estado en prod si corre ahí]** → El anchor usa email `*@test.local` reservado de CI; en prod el gate se autolimita (NOTICE + salida temprana si el insert del anchor no procede) y su limpieza borra únicamente lo colgado del email del anchor.
- **[Backfill sobre cuentas reales (~29)]** → Solo INSERT aditivos con guards `NOT EXISTS`; cero UPDATE/DELETE; una cuenta ya provisionada es no-op comprobado por el escenario "Backfill is a no-op". Ejecutable mentalmente contra los 3 estados posibles: sin branch / branch sin cashbox / completa.
- **[Sobrescribir la definición del trigger puede perder cambios recientes]** → D5: la base es la última versión deployada (`20260801000003`); el diff se limita a AGREGAR el bloque de seed. Task explícita de verificación línea-a-línea contra esa versión.
- **[`cashboxes` sin UNIQUE → riesgo de duplicados si el guard falla]** → El guard `NOT EXISTS` corre dentro de la misma transacción del trigger/backfill; la ventana de carrera es teórica (un signup no compite consigo mismo). Se documenta; agregar un UNIQUE parcial queda fuera (tocaría C-28).
- **[El nombre "Casa Central" está acoplado por convención]** → Ya es la convención del lazy-create y de 5 migraciones previas; este change la consolida, no la introduce.

## Migration Plan

1. Una sola migración nueva: `20260812000001_v3_provisioning_seed.sql` (siguiente a la última `20260811000004`).
   - **Parte A — Backfill idempotente** (cuentas existentes): A.1 branch para cuentas sin branches; A.2 cashbox para cuentas sin cashboxes.
   - **Parte B — Trigger**: `CREATE OR REPLACE FUNCTION public.handle_new_user()` basada en `20260801000003` + bloque de seed en sub-bloque EXCEPTION.
   - **Parte C — Behavior gate** auto-limpiante (D6).
2. Deploy: merge a main → auto-apply de Supabase + `db push` de Actions (ambos órdenes seguros por D5). NUNCA MCP `apply_migration`.
3. Verificación post-deploy en prod (SQL read-only): 0 cuentas sin branch; 0 cuentas sin cashbox; T3 manual de registro→venta.
4. **Rollback**: restaurar `handle_new_user` a la versión de `20260801000003` (el archivo ya la contiene). El backfill NO se revierte (branches/cashboxes creadas son datos legítimos e inocuos; borrarlas rompería FKs si ya tienen sesiones).

## Open Questions

- **PO — nombre de la caja default**: "Caja Principal" (propuesto) vs "Caja Casa Central". Decisión cosmética, no bloquea el apply; default propuesto: "Caja Principal".
- **PO — backfill de las 29 cuentas**: el diseño lo recomienda e incluye (D4). Si el PO prefiere solo-nuevos, se elimina la Parte A sin tocar el resto (los artefactos lo aíslan a propósito).
- **Roadmap (no de este change)**: cuándo entra el catálogo de formas de pago y la tabla `price_lists` — ambos quedaron FUERA con justificación (Non-Goals); si el PO los quiere, son changes nuevos del roadmap V3.
