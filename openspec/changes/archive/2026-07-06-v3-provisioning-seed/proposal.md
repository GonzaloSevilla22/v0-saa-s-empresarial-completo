## Why

Hoy un tenant recién registrado NO tiene sucursal ni caja: `handle_new_user` solo crea el profile, la account, la membership `owner` y los emails de bienvenida/aviso. La sucursal "Casa Central" se crea de forma **perezosa**, únicamente cuando ocurre el primer movimiento de stock (helper `c21_apply_branch_stock_delta`). Un tenant que se registra y quiere vender/operar caja sin tocar stock queda **bloqueado**: sin sucursal no puede abrir una caja ni operar POS de efectivo. El modelo de dominio V3 §7.5 exige que un tenant nuevo pueda **vender en menos de 5 minutos sin configuración manual**.

## What Changes

- Extender `handle_new_user` para que, en el mismo paso de provisioning del signup, siembre de forma **eager** una sucursal default **"Casa Central"** (`ON CONFLICT (account_id, name) DO NOTHING`) y una **caja default** ("Caja Principal") colgada de esa sucursal.
- El bloque de seed se aísla en un sub-bloque `BEGIN...EXCEPTION WHEN OTHERS THEN RAISE WARNING...END` para que un fallo del seed **degrade** (loguea) sin abortar el registro del usuario — la red de seguridad del create-perezoso sigue existiendo aguas abajo.
- **Backfill idempotente** en la misma migración (Parte A backfill + Parte B extensión del trigger, espejando la estructura de `20260800000003`): las ~29 cuentas existentes reciben la sucursal + caja que les falte, conflict-safe (muchas ya tienen "Casa Central"/"Principal" por el create-perezoso; a esas solo se les agrega la caja si no tienen ninguna).
- **Behavior gate** (DO-block) en la migración que simula el signup (inserta un anchor sintético en `auth.users` → dispara el trigger → asserta que existen sucursal default Y caja default para esa cuenta), siguiendo el patrón auto-limpiante / `RAISE NOTICE ... RETURN` establecido, dejando `accounts=0` al final.

Fuera de alcance (justificado en design.md, todo verificado contra las migraciones reales): **listas de precios** (la tabla `price_lists` no existe), **métodos de pago** (no hay tabla ni enum; solo un CHECK de 2 valores `cash|other` en `sales_orders`), **plan de cuentas** (diferido a V2.6; códigos hardcodeados en el journal helper y un test prohíbe crear la tabla) y **unidades de medida** (ya provisionadas globalmente: las 11 unidades sistema se seedearon en `20260509211504` con `is_system=true` y la RLS `uom_account_select` las hace visibles a todo tenant nuevo — no hay nada per-tenant que seedear).

## Capabilities

### New Capabilities

<!-- Ninguna capability nueva: el seed extiende el trigger de registro existente. -->

### Modified Capabilities

- `user-registration`: se modifica el requisito "Signup metadata propagation via trigger" para reflejar que el provisioning del tenant ahora también siembra la sucursal default y la caja default; y se agrega un requisito "Tenant provisioning seed" que fija el comportamiento eager + degradación + backfill idempotente. (El comportamiento de creación de sucursal/caja como tal vive en `branches` y `cash-session`; acá solo se especifica el **acto de sembrarlos en el signup**, sin duplicar sus requisitos de ciclo de vida.)

## Impact

- **DB / migración**: una sola migración SQL nueva (próximo número después de `20260811000004`) que hace `CREATE OR REPLACE FUNCTION public.handle_new_user()` (mantiene `SECURITY DEFINER`) + backfill + behavior gate. Idempotente / both-worlds-safe (Supabase auto-apply corre la migración ANTES del `db push` de Actions).
- **Trigger crítico del signup**: `handle_new_user` es la ruta de registro. Governance **MEDIO** (toca el signup path); el seed no debe poder romper el registro.
- **Tablas afectadas (solo INSERT de seed, sin DDL de schema)**: `branches` (sucursal default), `cashboxes` (caja default). Ambas ya tienen RLS.
- **CI**: nuevo behavior gate en el job `validate-kpis` (DB vacía, sin Docker local, sin Playwright E2E en este lane). Cobertura pytest donde se toque una ruta de backend (no aplica: el provisioning es 100% DB-side).
- **Docs**: checkbox en `CHANGES.md` §"Roadmap Modelo V3".
