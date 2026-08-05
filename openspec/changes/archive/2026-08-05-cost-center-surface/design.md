## Context

`cost-center-dimension` (2026-06-27, migración `20260802000001`) dejó en producción la tabla `cost_centers` con RLS, el CRUD de 3 capas en `/cost-centers`, la columna nullable `cost_center_id` en `expenses` y `purchases`, la validación de pertenencia en `rpc_create_purchase_operation` y la propagación al asiento contable (`journal_lines.cost_center_id` en la línea 5100 de compra, migración `20260803000001`). Todo eso funciona y tiene tests.

Lo que no existe es la superficie:

- `frontend/components/cost-centers/CostCenterManager.tsx` está escrito y **no lo importa ninguna página** — verificado por búsqueda en `frontend/app/`. Sin pantalla de alta, `cost_centers` está vacía para todas las cuentas y el `CostCenterSelect` que sí está montado en `expense-form-v2.tsx:120` y `purchase-form.tsx:509` se renderiza siempre con la única opción "Sin centro de costo".
- No hay ningún read-model que agregue por centro de costo. El reporting fue diferido explícitamente en el proposal original.

Restricciones del contexto actual que condicionan el diseño:

- **El patrón de reportes vigente** es RPC `SECURITY DEFINER` en Postgres invocado con `supabase.rpc` desde un client component con React Query + Recharts (`rpc_branch_report` ← `/reportes/sucursal`, `rpc_period_comparison` ← `/reportes/comparativo`). Ningún reporte pasa por FastAPI.
- **`reporting-invariants` (RN-D1..D5)** es transversal y obligatorio para todo read-model financiero nuevo. La auditoría de `v3-reporting-invariants` encontró revenue subvaluado 17,53% en producción por sumar `amount` (precio unitario) en vez de `COALESCE(total, amount)`; el read-model nuevo nace con esos predicados.
- **`usePaginatedQuery` tiene un set de filtros cerrado.** `applyFilters` se guarda en un ref (`applyFiltersRef`) y las deps de `fetchPage` son `[supabase, table, select, page, pageSize, debSearch, dateFrom, dateTo, sortKey, sortDir]`. Un filtro nuevo capturado en el closure del caller actualizaría el ref pero **no dispararía refetch**: el filtro se aplicaría recién en la próxima búsqueda o cambio de página. Es un bug latente para cualquier filtro que se agregue desde afuera, no solo para este change.
- **Gastos y compras leen por caminos distintos**: gastos van directo a Supabase vía `usePaginatedQuery` (`select("*")`, así que `cost_center_id` ya viaja en la fila); compras van por `GET /purchases` en FastAPI, con paginación *por operación* (`COUNT(DISTINCT COALESCE(operation_id, id))` y una CTE `op_page`).
- **La integración GitHub de Supabase auto-aplica migraciones al mergear**, antes del `db push` de Actions: toda migración debe ser idempotente y re-ejecutable.

## Goals / Non-Goals

**Goals:**

- Que un `owner`/`admin` pueda crear su primer centro de costo navegando por la aplicación, sin tocar la API.
- Que los costos imputados se puedan leer agregados por centro, con lo **no imputado** visible como una fila más (para que el total del reporte cierre contra el costo del período).
- Que del agregado se pueda bajar al detalle filtrando gastos y compras por centro.
- Arreglar en la **capa canónica** la limitación de filtros de `usePaginatedQuery`, en vez de esquivarla en la pantalla de gastos.

**Non-Goals:**

- Imputar centro de costo a **ventas** o calcular margen por centro. La dimensión es de costos; las ventas no llevan `cost_center_id` (decisión vigente de `cost-center-dimension`, y `journal_lines` de venta lo escribe `NULL` explícitamente).
- Reporte **contable** por centro sobre `journal_lines` (ver Decisión 1).
- Jerarquías de centros, distribución porcentual, o edición del centro de una compra ya registrada.
- Backfill de imputaciones históricas: las filas previas se quedan en `NULL` y se ven bajo "Sin centro de costo".

## Decisions

### Decisión 1 — El reporte lee documentos operativos (`expenses` + `purchases`), no `journal_lines`

**Alternativa considerada:** leer el libro diario, que ya lleva `cost_center_id` en la línea 5100.

**Rechazada** por dos razones verificadas en el código: (a) el consumer del journal despacha exactamente 5 tipos de evento — `SaleConfirmed`, `PurchaseCreated`, `PaymentReceived`, `PaymentMade`, `CreditNoteIssued` — y **no existe ningún evento de gasto**, así que un reporte sobre el diario mostraría compras y omitiría silenciosamente todos los gastos, que es justo donde la dimensión más se usa; (b) el asiento se genera **async por outbox**, de modo que el reporte quedaría atado a la salud del dispatcher y mostraría números que se mueven solos (el outbox ya estuvo muerto entre el 22-jun y el 01-jul).

Consecuencia asumida: si más adelante se quiere un reporte estrictamente contable por centro, será **otro** read-model sobre `journal_lines`, no una evolución de éste.

### Decisión 2 — RPC `SECURITY DEFINER` invocado desde el cliente, no endpoint FastAPI

Espejo exacto de `rpc_branch_report`: `CREATE OR REPLACE FUNCTION public.rpc_cost_center_report(p_account_id uuid, p_start date, p_end date)`, `SECURITY DEFINER`, `SET search_path TO 'public'`, verificación de membership contra `account_members` con `RAISE EXCEPTION ... USING ERRCODE = 'P0401'`, `REVOKE` a `anon` + `GRANT EXECUTE` a `authenticated` (exigido por el gate de ACLs `test_function_acl_gate.sql` que corre en cada PR).

**Alternativa considerada:** endpoint en FastAPI. **Rechazada**: rompería el patrón de todos los reportes existentes, y el backend en Render (free tier) tiene cold start de ~50s — inaceptable para una pantalla de lectura que hoy resuelve Postgres en un round-trip.

### Decisión 3 — Invariantes RN-D horneados desde el día uno

El cuerpo del RPC nace con los cuatro predicados que la auditoría tuvo que retrofitear en las otras cuatro RPCs:

| Invariante | Aplicación en `rpc_cost_center_report` |
|---|---|
| Revenue/costo de línea | compras: `SUM(COALESCE(p.total, p.amount))` — nunca `amount` solo |
| Conteo de operaciones | compras: `COUNT(DISTINCT COALESCE(p.operation_id, p.id))`; gastos: una unidad por fila (no tienen `operation_id`) |
| Bordes de período (RN-D5) | `date >= p_start::timestamptz AND date < (p_end + 1)::timestamptz` |
| Dinero `NUMERIC` (RN-D4) | todas las columnas monetarias de salida son `numeric`, ninguna `float` |

La migración incluye **gates de introspección** (verifican que el cuerpo publicado contenga esos predicados; corren siempre, también en prod) y **gates de comportamiento** con anchor sintético vía `handle_new_user` y cleanup hijo→padre (solo DB vacía/CI, degradan con `NOTICE` en prod), siguiendo el patrón de `20260814000001`.

### Decisión 4 — La fila "Sin centro de costo" es parte del contrato, no un detalle de UI

El `FULL`/`UNION` de claves incluye `NULL` y se etiqueta `'Sin centro de costo'` en SQL (espejo de `COALESCE(b.name, 'Sin sucursal')` en `rpc_branch_report`). Motivo: la imputación es opcional y, en la práctica, la mayoría de las filas históricas están sin imputar. Un reporte que filtre los `NULL` mostraría un total muy inferior al costo real del período y le haría creer al usuario que gastó menos de lo que gastó — el mismo tipo de error que la auditoría de reporting acaba de corregir. Que el total del reporte cierre contra el costo del período es un requirement, no una preferencia estética.

### Decisión 5 — `extraFilters` en `usePaginatedQuery`, en la capa canónica

Se extiende el hook compartido con `extraFilters?: Record<string, string | null>`, que (a) viaja dentro de `FilterParams` hacia `applyFilters` y (b) entra en las deps de `fetchPage` serializado, de modo que cambiarlo dispara refetch y resetea a página 0. Retrocompatible: es opcional, y los dos únicos consumidores actuales (`/gastos` y `/clientes`) no cambian de comportamiento si no lo pasan.

**Alternativas consideradas:** (a) remontar el hook con `key` distinto por filtro — pierde estado de paginación y ordenamiento, y es un workaround por pantalla; (b) un hook nuevo paralelo — duplicaría la lógica de paginación, exactamente lo que prohíbe la regla de reutilización antes que repetición; (c) dejar el filtro client-side sobre la página actual — daría totales de paginación mentirosos (filtraría 25 filas de N).

### Decisión 6 — El filtro de compras se aplica en la CTE de operaciones

En `list_paginated_by_operation`, el `cost_center_id` opcional se aplica **dentro de** la subconsulta que arma `op_page` y en el `COUNT` — no en el join final. Motivo: la paginación de compras es por operación y el centro de costo es un atributo *de la operación* (todas las líneas comparten el mismo valor). Filtrarlo en el join final devolvería operaciones parciales y descuadraría el `total`.

Patrón de parámetro idéntico al de las fechas ya presentes: `AND ($4::uuid IS NULL OR cost_center_id = $4::uuid)`.

### Decisión 7 — Sin gate de plan (decisión PO)

El reporte va al sidebar con `pro: false, proOnly: false`. Coherente con la decisión explícita ya tomada en `CostCenterSelect` ("no plan-gating since the cost center catalog is available on all plans"): gatear el único consumidor de la dimensión dejaría al plan free imputando datos que nunca puede leer. Revisable con datos de uso.

### Decisión 8 — Séptimo tab en `/configuracion`, con la grilla ajustada

El `TabsList` pasa de `grid-cols-3 sm:grid-cols-6` a `grid-cols-3 sm:grid-cols-4 lg:grid-cols-7`: en mobile quedan 3 filas de 3/3/1 (ya era multi-fila con 6), en tablet 4+3, y la fila única de 7 se reserva para `lg`, donde hay ancho real. Evita el apretujamiento que produciría forzar 7 columnas desde `sm`. El componente montado es `CostCenterManager` **sin modificaciones**.

### Decisión 9 — El filtro lista centros inactivos; el alta no

`useCostCenters(includeInactive)` ya distingue ambos casos y se reutiliza tal cual: el selector de alta usa `false` (no se imputa a un centro dado de baja) y el selector de filtro usa `true` (sí se consulta el histórico de un centro dado de baja). Sin componente nuevo salvo un envoltorio mínimo de filtro que agrega la opción "Todos".

## Risks / Trade-offs

- **[El reporte muestra costos y no margen]** → Un usuario podría esperar "rentabilidad por centro". Se mitiga con el copy de la pantalla ("Costos por centro de costo en el período") y está declarado como Non-Goal: las ventas no llevan la dimensión, así que el margen por centro es estructuralmente imposible hoy.
- **[`extraFilters` toca un hook compartido]** → Riesgo de regresión en `/gastos` y `/clientes`. Mitigación: el parámetro es opcional y el path sin él queda idéntico; test de vitest que cubre (a) que cambiar `extraFilters` dispara refetch y resetea a página 0 y (b) que sin `extraFilters` el comportamiento previo no cambia.
- **[Performance del agregado sin índice dedicado]** → El reporte escanea `expenses` y `purchases` por `account_id` + rango de fechas y agrupa por `cost_center_id`. Es el mismo perfil de acceso que `rpc_branch_report`, que corre sin índice por `branch_id`, sobre volúmenes de un tenant de microemprendedor. No se agrega índice ahora; si el volumen crece, el índice natural es `(account_id, date)` — que sirve a todos los reportes, no solo a éste.
- **[La respuesta de compras cambia de forma]** → Se agregan campos (`cost_center_id`, nombre del centro); no se quita ni se renombra ninguno. El mapeo del frontend es campo a campo, así que la ventana entre deploy de backend y de frontend es segura en ambos sentidos.
- **[7 tabs en configuración]** → Riesgo estético en pantallas intermedias. Mitigación: verificación explícita en desktop y mobile, tema claro y oscuro, como exige la regla PO, con el breakpoint `lg` para la fila única.
- **[Migración auto-aplicada por la integración de Supabase antes que Actions]** → `CREATE OR REPLACE FUNCTION` + `REVOKE`/`GRANT` son 100% re-ejecutables; sin DDL de tablas, sin backfill. Rollback = `DROP FUNCTION IF EXISTS public.rpc_cost_center_report(uuid, date, date)`; el frontend sin la función simplemente no tiene datos que mostrar en una pantalla nueva (ninguna pantalla existente depende de ella).

## Migration Plan

1. Migración `CREATE OR REPLACE FUNCTION` + ACLs + gates, datada por encima de la última migración vigente. Se aplica sola al mergear (Actions: build + deploy Vercel + `db push`). **Nunca** con el MCP `apply_migration`.
2. Backend y frontend viajan en el mismo merge; el orden real de llegada no importa porque todos los cambios son aditivos.
3. Rollback: `DROP FUNCTION IF EXISTS public.rpc_cost_center_report(uuid, date, date)` y revertir el tab (el resto son filtros opcionales que degradan a "sin filtro").

## Open Questions

- **OQ1 — ¿El reporte necesita exportación a CSV?** `/gastos` y otras pantallas usan `exportToCSV` y `ExportButton`. Default asumido: **no** en este change (el reporte es de lectura y el detalle ya se exporta desde Gastos). Se agrega si el PO lo pide; costo marginal bajo.
- **OQ2 — ¿Se siembran centros de costo por defecto al crear una cuenta?** `handle_new_user` ya siembra sucursal "Casa Central" y caja "Caja Principal" (`v3-provisioning-seed`). Sembrar un set inicial ("Administración", "Comercial", "Producción") reduciría la fricción del primer uso, pero mete opinión de negocio en el provisioning y ensucia cuentas que no usan la dimensión. Default asumido: **no sembrar**; el estado vacío de `CostCenterManager` ya invita a crear el primero.
