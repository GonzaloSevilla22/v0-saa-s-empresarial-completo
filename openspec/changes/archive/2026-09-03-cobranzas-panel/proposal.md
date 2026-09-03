## Why

El PO gestiona la cobranza entrando **cliente por cliente**: abre `/clientes`, elige uno, entra a `/clientes/[id]/cuenta` y recién ahí ve si debe y cuánto. No existe ninguna pantalla, endpoint ni KPI que responda la pregunta con la que arranca cualquier jornada de cobranza —**"¿quién me debe y cuánto?"**— de forma agregada. Con 11 deudores y $567.000 por cobrar hoy en producción el recorrido manual todavía es viable; la saga de cobranzas cerrada el 2026-09-02 (`caja-compras-cobranzas`, `cobranzas-reverso`, `cobranzas-catalogo-pagos`) dejó el **registro** del cobro completo y correcto en los cinco libros, pero nunca construyó la **visibilidad** de la deuda, que es lo que decide a quién llamar hoy.

Esta es la **Etapa A** del módulo de cobranzas: da visibilidad sin tocar el modelo de datos ni escribir dinero. La Etapa B —vencimientos por cargo, plazo de pago por cliente, aging FIFO por buckets y avisos automáticos— es un change futuro, ya en discusión con el PO, y es Non-Goal explícito acá.

## What Changes

- **Endpoint agregado de deudores** (nuevo): `GET /reports/receivables` (paginado, envelope estándar) y `GET /reports/receivables/summary` sobre un RPC `SECURITY DEFINER` nuevo, `rpc_receivables_report`, que devuelve los clientes del tenant con `balance > 0` con su saldo, los días desde el último cargo y los días desde el último cobro, derivados del ledger `customer_account_movements`. Molde de punta a punta: `rpc_payment_method_report` (RPC con guard de membresía `P0401` → repository → service → `report_router` → mapper puro en `lib/`).
- **Pantalla `/cobranzas`** (nueva) con entrada de sidebar en el grupo **Operaciones**: total por cobrar en cabecera, tabla de deudores ordenable (cliente, saldo, días de deuda, último cobro), acceso por fila a `/clientes/[id]/cuenta` y botón **Cobrar** que abre un `Dialog` con el `RegisterPaymentForm` **existente**, sin formulario nuevo. `EmptyState` cuando no hay deudores.
- **KPI "Por cobrar" en el Tablero**, en la grilla de tarjetas de hoy, enlazado a `/cobranzas`. `KpiCard` gana una prop `href` opcional (capa canónica) en vez de envolver la tarjeta en un `Link` ad-hoc en la página.
- **Columna "Saldo" y acceso directo a la cuenta corriente en `/clientes`**: el read-model de `GET /clients/activity` suma el saldo de cuenta corriente del cliente y el listado gana la columna más un botón de acceso por fila, nivelando con `/proveedores`, que ya lo tiene.

**Sin cambios de escritura de dinero.** El único botón que escribe (Cobrar) reutiliza el flujo existente —`useRegisterPayment` → `POST /customer-accounts/payments` → `rpc_register_payment_received`— sin modificarlo.

### Non-Goals (declarados)

- **Vencimientos, `due_date`, plazos de pago por cliente, aging por buckets y avisos/notificaciones**: Etapa B, change futuro. Nada de `pg_cron` acá.
- **Activar `clients.credit_limit`**: campo huérfano desde C-30, sigue huérfano.
- **Tocar RPCs de dinero, el ledger, o cualquier camino de escritura**: el change es 100% lectura agregada + navegación.
- **Backfill o corrección de datos históricos**: no hay dato que corregir; el agregado se deriva del ledger vivo.

## Capabilities

### New Capabilities

- `receivables-panel`: tablero agregado de cuentas por cobrar — read-model de deudores del tenant (saldo, antigüedad de la deuda, antigüedad del último cobro), su superficie en `/cobranzas` con acceso al cobro existente, y el KPI de total por cobrar en el Tablero.

### Modified Capabilities

- `client-activity`: el read-model del listado de clientes suma el **saldo de cuenta corriente** de cada cliente, y la lista lo muestra junto a un acceso directo a la cuenta corriente (hoy el listado no trae el saldo y no hay forma de llegar a la cuenta desde la fila).

## Impact

**Base de datos** (una migración nueva, sin DDL sobre tablas existentes):
- `rpc_receivables_report(p_account_id uuid)` `SECURITY DEFINER` con guard de membresía (`P0401`), `REVOKE ALL FROM PUBLIC` + `REVOKE EXECUTE FROM anon` + `GRANT EXECUTE TO authenticated` en el mismo archivo (gotcha conocido: `DROP`+`CREATE` resetea ACLs).
- Sin tablas, columnas, índices ni triggers nuevos. Sin backfill.

**Backend** (`backend/`):
- `repositories/customer_account_repository.py` — `list_receivables_page()` (sobre `paginate()`) y `get_receivables_summary()`.
- `services/customer_accounts.py`, `routers/customer_accounts.py` (`report_router` con prefijo `/reports/receivables`), `schemas/customer_accounts.py`.
- `repositories/client_repository.py` — el CTE compartido `_classified_activity_cte` suma el `LEFT JOIN` a `customer_accounts`; `schemas/clients.py` — `current_balance` en `ClientActivityOut`.
- `main.py` — registro del `report_router` nuevo.

**Frontend** (`frontend/`):
- Nuevos: `app/(dashboard)/cobranzas/page.tsx`, `lib/receivables.ts` (mapper puro + totales), `hooks/data/use-receivables.ts`.
- Modificados: `components/app-sidebar.tsx` (entrada en Operaciones), `lib/query-keys.ts`, `lib/types.ts`, `components/dashboard/kpi-card.tsx` (prop `href`), `app/(dashboard)/dashboard/page.tsx`, `app/(dashboard)/clientes/page.tsx`, `hooks/data/use-client-activity.ts`, `hooks/data/use-customer-account.ts` (invalidación de las claves nuevas), y el mapa de nombres del breadcrumb.

**Riesgo / governance**: **MEDIO-bajo**. Solo lectura agregada y navegación; ningún camino de escritura de dinero cambia. El tramo que justifica "medio" y no "bajo" es que toca `_classified_activity_cte`, el **hot path del listado de clientes** (una sola consulta por página, compartida por lista y detalle): una regresión ahí degrada `/clientes` completo, no solo la columna nueva.
