# Tasks — clientes-frecuentes-historial

> **Governance: MEDIUM** (lógica de negocio + superficie frontend). Implementar por pasos, exponiendo las decisiones no obvias.
> **Strict TDD obligatorio**: cada grupo sigue RED → GREEN → TRIANGULATE → REFACTOR. No se escribe código de producción sin un test que falle antes.
> **Suites base**: frontend 983 · backend 1269 con coverage ≥87%.

## 1. Safety net (antes de tocar nada)

- [x] 1.1 Ejecutar `pytest backend/tests/test_clients.py backend/tests/test_c30_customer_supplier_accounts.py -v` y registrar el baseline (`N passed`). Si algo falla, DETENER y reportar como fallo preexistente — no arreglarlo dentro de este change.
- [x] 1.2 Ejecutar `pnpm vitest run __tests__/ClientForm.test.tsx __tests__/hooks/use-clients-purchases-branches-stock-orgs.test.ts __tests__/c30-customer-supplier-accounts.test.ts` y registrar el baseline. Mismo criterio ante fallos preexistentes.
- [x] 1.3 Registrar el baseline de las suites completas (`pytest` backend, `pnpm vitest run` frontend) para poder demostrar al cierre que no se rompió nada.

## 2. Umbrales canónicos y clasificación (backend)

- [x] 2.1 **RED** — `backend/tests/test_client_activity.py` (nuevo): tests de `classify_activity(ops_total, ops_window, days_since_last)` para los 4 estados. Referenciar `client-activity` §"Estados de actividad comercial del cliente". El módulo aún no existe.
- [x] 2.2 **GREEN** — crear `backend/core/client_activity.py` con `FRECUENTE_MIN_OPS = 3`, `FRECUENTE_WINDOW_DAYS = 90`, `INACTIVO_MIN_DAYS = 60` y `classify_activity(...)`. Mínimo para pasar.
- [x] 2.3 **TRIANGULATE** — agregar casos de borde: cliente sin compras con antigüedad alta (→ `sin_compras`, nunca `inactivo`); solapamiento frecuente+inactivo (→ `inactivo`, precedencia de `client-activity` §"Precedencia determinística"); exactamente 3 operaciones en ventana (→ `frecuente`); exactamente 60 días (→ `inactivo`); 59 días (→ `activo`). Generalizar la implementación hasta que todos pasen.
- [x] 2.4 **REFACTOR** — extraer el enum de estados a un `Literal`/`StrEnum` reutilizable por los schemas; verificar que los umbrales no estén repetidos en ningún otro archivo (`grep`).

## 3. Agregados de actividad (repository)

- [x] 3.1 **RED** — tests de `ClientRepository.list_activity_page(...)`: envelope `{items,total,page,pages}`, agregados por cliente, exclusión de soft-deleted, aislamiento por `account_id`.
- [x] 3.2 **GREEN** — implementar `list_activity_page` en `backend/repositories/client_repository.py` con el `LEFT JOIN LATERAL` de `design.md` §4, reutilizando `BaseRepository.paginate()` y `not_deleted_clause()`. Umbrales y día de referencia como **parámetros** de la consulta, nunca interpolados.
- [x] 3.3 **TRIANGULATE** — casos: operación con 3 líneas cuenta como 1 compra; fila sin `operation_id` cuenta como operación propia; ventas con `client_id` NULL no se atribuyen; cliente sin ventas devuelve 0 / NULL; monto de línea `COALESCE(si.subtotal, s.total, s.amount)` con `quantity > 1` (guardia contra la subvaluación de RN-D).
- [x] 3.4 **RED→GREEN** — `ClientRepository.get_activity_for(client_id)`: **reutiliza la misma SQL de agregados** filtrada a un cliente (una sola definición para lista y detalle, `client-purchase-history` §"Resumen acumulado"). Test que verifica que lista y detalle devuelven los mismos números para el mismo cliente.
- [x] 3.5 **RED→GREEN** — `ClientRepository.list_purchases_page(client_id, page, size)`: una fila por operación con fecha, cantidad de ítems y total, orden por fecha descendente, envelope estándar.
- [x] 3.6 **TRIANGULATE** — página fuera de rango devuelve `items` vacío conservando `total`/`pages`; cliente de otra organización no devuelve datos.
- [x] 3.7 **REFACTOR** — extraer el fragmento SQL de `op_key` + monto canónico a una constante compartida por los tres métodos; verificar que no se duplicó `COALESCE(operation_id::text, id::text)` en varias cadenas.

## 4. Timezone argentino

- [x] 4.1 **RED** — test de `days_since_last_purchase` con una venta registrada a las 22:00 ART (01:00 UTC del día siguiente): debe resolver al día D, no a D+1. Referencia: `client-activity` §"Días y ventanas en día calendario argentino".
- [x] 4.2 **GREEN** — usar `reporting_local_today()` como día de referencia y `(date AT TIME ZONE 'America/Argentina/Mendoza')::date` para el día de cada operación.
- [x] 4.3 **TRIANGULATE** — ventana de frecuencia inclusiva: operación en el día D−89 entra, en D−90 no entra.
- [x] 4.4 Verificar por `grep` que no quedó ningún `now() - interval` ni resta directa sobre `now()` en las consultas nuevas.

## 5. Service y endpoints

- [x] 5.1 **RED** — `backend/tests/test_clients.py`: tests de `GET /clients/activity` (envelope, filtro `activity_status`, `search`, `sort`/`sort_dir`, paginación) y de `GET /clients/{id}/purchases`.
- [x] 5.2 **GREEN** — implementar en `backend/services/clients.py` (lógica + guards) y `backend/routers/clients.py` (validación + DI). Schemas `ClientActivityOut`, `ClientPurchaseOut`, `ClientPurchaseSummaryOut` en `backend/schemas/clients.py`, con `PageOut[T]` de `backend/schemas/common.py`.
- [x] 5.3 **TRIANGULATE** — `sort` fuera del conjunto admitido → error de validación RFC 7807 sin ejecutar la consulta; `GET /clients/{id}/purchases` con cliente inexistente o de otra organización → 404 RFC 7807; orden por última compra deja los clientes sin compras al final.
- [x] 5.4 **REGRESIÓN** — test explícito de que `GET /clients` conserva su lista plana (`data-api-endpoints` §"Compatibilidad del listado plano"). Es el guardarraíl de los 6 consumidores de selectores.
- [x] 5.5 **REFACTOR** — asegurar que el router no contiene lógica de negocio (3 capas) y que la whitelist de `sort` vive en el service, no en el router.
- [x] 5.6 Verificar coverage backend ≥87% con `--cov-config` explícito.

## 6. Hooks de datos (frontend)

- [x] 6.1 **RED** — `frontend/__tests__/hooks/use-client-activity.test.ts` (nuevo): `useClientActivityList` mapea el envelope y los agregados; `useClientPurchases` mapea el historial. Mockear `pythonClient`.
- [x] 6.2 **GREEN** — crear `frontend/hooks/data/use-client-activity.ts` con ambos hooks vía `pythonClient` + React Query, agregando las claves necesarias a `lib/query-keys.ts`.
- [x] 6.3 **TRIANGULATE** — respuesta vacía; cliente sin compras (`lastPurchaseAt` nulo); numerics que llegan como `string` desde Postgres se convierten a `number`.
- [x] 6.4 Verificar que el frontend **no** reimplementa la clasificación: `grep` de los literales `3`, `90`, `60` como umbrales en `frontend/` debe volver vacío; el badge se renderiza desde `activity_status`.

## 7. Lista de clientes

- [x] 7.1 **RED** — test del componente `ClientActivityBadge`: renderiza texto visible para cada uno de los 4 estados (no sólo color).
- [x] 7.2 **GREEN** — crear `frontend/components/clientes/ClientActivityBadge.tsx` con `cva` sobre tokens semánticos. **No** replicar el `statusColors` hardcodeado (`emerald-500`/`yellow-500`/`red-500`) de la página actual.
- [x] 7.3 Migrar `frontend/app/(dashboard)/clientes/page.tsx` de `usePaginatedQuery({table:"clients"})` a `useClientActivityList`, conservando búsqueda, paginación (`PaginationBar`), export CSV, límite de plan y los diálogos de alta/edición/importación.
- [x] 7.4 Agregar el control de filtro por estado de actividad y el de orden (`name` / `last_purchase` / `total_spent` / `purchase_count`).
- [x] 7.5 **RED→GREEN** — test: la fila del cliente navega a `/clientes/[id]` al accionarla, y los botones de editar/borrar **detienen la propagación** y no navegan (`client-purchase-history` §"Acciones de la fila no navegan").
- [x] 7.6 Accesibilidad: el disparador del detalle es un elemento accionable real, alcanzable por teclado, con foco visible y activable con Enter.
- [x] 7.7 Mostrar en la fila los agregados útiles (última compra y total comprado) sin romper el layout de escritorio ni el de móvil.

## 8. Detalle del cliente

- [x] 8.1 Crear `frontend/app/(dashboard)/clientes/[id]/layout.tsx`: cabecera con nombre del cliente (vía `GET /clients/{id}`, ya existente), botón de volver y navegación por pestañas `Historial de compras` / `Cuenta corriente`.
- [x] 8.2 Ajustar `frontend/app/(dashboard)/clientes/[id]/cuenta/page.tsx` para no duplicar la cabecera que ahora aporta el layout. **No** tocar `CustomerAccountBalance`, `CustomerAccountHistory` ni `RegisterPaymentForm`.
- [x] 8.3 **RED** — tests de `ClientSummaryCards` y `ClientPurchaseHistory`: resumen y listado por operación.
- [x] 8.4 **GREEN** — crear `frontend/app/(dashboard)/clientes/[id]/page.tsx` con las tarjetas de resumen (cantidad de compras, total comprado, última compra + días) y el historial paginado.
- [x] 8.5 **TRIANGULATE** — estado vacío ("este cliente todavía no compró"); estado de carga; estado de error.
- [x] 8.6 Rotular el total como **"Total comprado"** con la aclaración de que no descuenta notas de crédito, y dejar el acceso a la cuenta corriente visible desde el resumen (`client-purchase-history` §"El total comprado es bruto").
- [x] 8.7 **RED→GREEN** — test: el resumen no cambia al paginar el historial (se calcula sobre el total, no sobre la página).

## 9. Índice de soporte

- [x] 9.1 Crear la migración con `CREATE INDEX CONCURRENTLY IF NOT EXISTS` sobre `sales(account_id, client_id, date DESC)`. **Idempotente** — la integración GitHub de Supabase auto-aplica al mergear.
- [x] 9.2 Verificar el timestamp contra el `MAX` real de las migraciones en producción antes de nombrar el archivo (sesiones paralelas colisionan).

## 10. Verificación visual (regla PO — obligatoria antes del merge)

- [x] 10.1 Verificado en vivo contra stack local (Supabase local + backend local en `127.0.0.1:8010` + `next dev` en `:3010`, `NEXT_PUBLIC_PLAYWRIGHT_LOCAL=true`), con un usuario QA (`qa-visual@example.com`) y 4 clientes fixture que cubren los 4 estados (`Frecuente`/`Activo`/`Inactivo`/`Sin compras`, ya sembrados en el Postgres local de una sesión previa). Desktop 1280×800: tabla con 5 columnas, sin overflow horizontal (`document.body.scrollWidth === innerWidth`). Badges verificados por `getComputedStyle` en ambos temas (alternando la clase `dark`/`light` en `<html>`, mismo mecanismo que el theme toggle real de la app): `Frecuente`→`bg-success/15 text-success`, `Inactivo`→`bg-warning/15 text-warning`, `Activo`→`bg-secondary text-secondary-foreground`, `Sin compras`→`border-border bg-transparent text-muted-foreground` — todos tokens semánticos, cero literales. **Hallazgo honesto (no bloqueante para este change)**: en tema claro, el contraste texto/fondo de los badges `text-success`/`text-warning` sobre `bg-*/15` calculó ~1.4:1 (warning) y ~2.0:1 (success) — por debajo de WCAG AA (3:1 UI / 4.5:1 texto). No es un defecto introducido por este change: el mismo par de tokens (`text-success`/`text-warning` sobre `bg-*/15`) ya se usa sin tocar en 13 componentes existentes (`kpi-card`, `ai-alerts`, `product-catalog`, `TrialBanner`, etc. — `grep` verificado). `ClientActivityBadge` reutilizó correctamente el patrón establecido del design system (regla de reutilización); el contraste es un problema sistémico de los tokens, fuera del alcance de este change. Se deja anotado para issue de design system aparte.
- [x] 10.2 `/clientes/[id]` y `/clientes/[id]/cuenta` verificados en desktop (1280×800) y en un viewport angosto (~454×984 — el preset "mobile" del pane reportó 375×812 pero el `window.innerWidth` real dentro de esta sesión de Browser pane headless resultó 454; igualmente por debajo del breakpoint `sm` de 768 usado en el código, así que ejercita el mismo layout mobile). Ambos anchos: sin overflow horizontal, cabecera compartida por el `layout.tsx` (no duplicada, confirmado navegando `Historial de compras` → `Cuenta corriente` y viendo el mismo nombre de cliente en ambas), pestañas son `<a href>` reales (no sólo JS), historial de compras con montos en `tabular-nums` (verificado con `getComputedStyle` sobre las 5 celdas de monto: resumen + 4 filas). Cuenta corriente renderiza `CustomerAccountBalance`/`CustomerAccountHistory`/`RegisterPaymentForm` sin tocar, con saldo $0,00 correcto para el fixture (sin movimientos).
- [x] 10.3 `grep` sobre los 6 archivos nuevos/tocados por este change (`ClientActivityBadge.tsx`, `ClientPurchaseHistory.tsx`, `ClientSummaryCards.tsx`, `clientes/page.tsx`, `clientes/[id]/layout.tsx`, `clientes/[id]/page.tsx`) por `emerald-|yellow-[0-9]|red-[0-9]|amber-|rose-|green-[0-9]|bg-\[#|text-\[#`: **cero coincidencias**. (Sí aparecen en `client-import-dialog.tsx`, pre-existente y explícitamente fuera de alcance — "se reutiliza sin tocar" en `design.md` §Context.)
- [x] 10.4 Recorrido por teclado verificado parcialmente en vivo + confirmado por código y tests: la fila de la lista es `<div role="button" tabIndex={0}>` con `focus-visible:ring-2` — foco confirmado visible (`boxShadow` con ring de 2px al enfocar por `.focus()`). Las pestañas del detalle son `<a href>` nativos (navegables con Tab + Enter por semántica HTML estándar, sin necesidad de JS). **Limitación honesta**: el Browser pane de esta sesión corre headless sin compositing de frames (`screenshot` y clicks por coordenadas fallan con "pane no se muestra"), así que el disparo de `Enter`/click sintético contra la fila no pudo confirmarse end-to-end por esa vía en esta sesión. Se verificó en su lugar leyendo `frontend/app/(dashboard)/clientes/page.tsx` (`handleRowKeyDown`: `e.key === "Enter" || e.key === " "` → `goToDetail`) y confirmando que los tests RTL de 7.5/7.6 (`ClientesPage.test.tsx`: "clicking a client row navigates...", "the row is keyboard-focusable and activates with Enter") están verdes dentro de la suite completa (1018 passed). El botón de editar/borrar dentro de la fila confirmado con `stopPropagation` por código y test dedicado.

## 11. Cierre

- [x] 11.1 Backend: `pytest backend/tests -m "not integration"` → **1318 passed, 3 deselected, 0 failed** (baseline 1.1–1.3: 1269 → creció con los tests nuevos de los grupos 2–9). Coverage `--cov=backend --cov-config=.coveragerc`: **96% total** (≥87% exigido); módulos nuevos de este change: `core/client_activity.py` 100%, `routers/clients.py` 100%, `schemas/clients.py` 100%, `repositories/client_repository.py` 98%, `services/clients.py` 91%. Frontend: `pnpm -C frontend test` → **1018 passed, 1 failed** (baseline 1.1–1.3: 983 → creció igual). El único fallo (`SuscripcionesAmbiguasPage.test.tsx` §1) es ajeno a este change (módulo de suscripciones, no tocado) y **pasa en aislamiento** (`pnpm vitest run __tests__/SuscripcionesAmbiguasPage.test.tsx` → 11/11 verde) — flake de contaminación de estado entre archivos de test (probable `window.location` no reseteado), fallo preexistente, no se toca dentro de este change.
- [x] 11.2 Confirmado en vivo contra stack local: la fila de `/clientes` navega a `/clientes/[id]` (código + tests 7.5/7.6), y desde ahí la pestaña `Cuenta corriente` es un `<a href="/clientes/[id]/cuenta">` real que renderiza `CustomerAccountBalance`/`CustomerAccountHistory`/`RegisterPaymentForm` sin tocar. `/clientes/[id]/cuenta` deja de ser una superficie huérfana: tiene una ruta de navegación real desde la lista de clientes.
- [x] 11.3 `openspec validate "clientes-frecuentes-historial" --strict` → **"Change 'clientes-frecuentes-historial' is valid"**.
- [x] 11.4 OQ-1 (umbrales `≥3/90d` frecuente, `≥60d` inactivo), OQ-2 (total bruto vs. neto de NC), OQ-3 (destino de `clients.status`), OQ-4 (orden por defecto alfabético) van en el cuerpo del PR para sign-off del PO — ver `design.md` §"Open Questions".
