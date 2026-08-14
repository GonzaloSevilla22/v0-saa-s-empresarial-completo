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

- [ ] 6.1 **RED** — `frontend/__tests__/hooks/use-client-activity.test.ts` (nuevo): `useClientActivityList` mapea el envelope y los agregados; `useClientPurchases` mapea el historial. Mockear `pythonClient`.
- [ ] 6.2 **GREEN** — crear `frontend/hooks/data/use-client-activity.ts` con ambos hooks vía `pythonClient` + React Query, agregando las claves necesarias a `lib/query-keys.ts`.
- [ ] 6.3 **TRIANGULATE** — respuesta vacía; cliente sin compras (`lastPurchaseAt` nulo); numerics que llegan como `string` desde Postgres se convierten a `number`.
- [ ] 6.4 Verificar que el frontend **no** reimplementa la clasificación: `grep` de los literales `3`, `90`, `60` como umbrales en `frontend/` debe volver vacío; el badge se renderiza desde `activity_status`.

## 7. Lista de clientes

- [ ] 7.1 **RED** — test del componente `ClientActivityBadge`: renderiza texto visible para cada uno de los 4 estados (no sólo color).
- [ ] 7.2 **GREEN** — crear `frontend/components/clientes/ClientActivityBadge.tsx` con `cva` sobre tokens semánticos. **No** replicar el `statusColors` hardcodeado (`emerald-500`/`yellow-500`/`red-500`) de la página actual.
- [ ] 7.3 Migrar `frontend/app/(dashboard)/clientes/page.tsx` de `usePaginatedQuery({table:"clients"})` a `useClientActivityList`, conservando búsqueda, paginación (`PaginationBar`), export CSV, límite de plan y los diálogos de alta/edición/importación.
- [ ] 7.4 Agregar el control de filtro por estado de actividad y el de orden (`name` / `last_purchase` / `total_spent` / `purchase_count`).
- [ ] 7.5 **RED→GREEN** — test: la fila del cliente navega a `/clientes/[id]` al accionarla, y los botones de editar/borrar **detienen la propagación** y no navegan (`client-purchase-history` §"Acciones de la fila no navegan").
- [ ] 7.6 Accesibilidad: el disparador del detalle es un elemento accionable real, alcanzable por teclado, con foco visible y activable con Enter.
- [ ] 7.7 Mostrar en la fila los agregados útiles (última compra y total comprado) sin romper el layout de escritorio ni el de móvil.

## 8. Detalle del cliente

- [ ] 8.1 Crear `frontend/app/(dashboard)/clientes/[id]/layout.tsx`: cabecera con nombre del cliente (vía `GET /clients/{id}`, ya existente), botón de volver y navegación por pestañas `Historial de compras` / `Cuenta corriente`.
- [ ] 8.2 Ajustar `frontend/app/(dashboard)/clientes/[id]/cuenta/page.tsx` para no duplicar la cabecera que ahora aporta el layout. **No** tocar `CustomerAccountBalance`, `CustomerAccountHistory` ni `RegisterPaymentForm`.
- [ ] 8.3 **RED** — tests de `ClientSummaryCards` y `ClientPurchaseHistory`: resumen y listado por operación.
- [ ] 8.4 **GREEN** — crear `frontend/app/(dashboard)/clientes/[id]/page.tsx` con las tarjetas de resumen (cantidad de compras, total comprado, última compra + días) y el historial paginado.
- [ ] 8.5 **TRIANGULATE** — estado vacío ("este cliente todavía no compró"); estado de carga; estado de error.
- [ ] 8.6 Rotular el total como **"Total comprado"** con la aclaración de que no descuenta notas de crédito, y dejar el acceso a la cuenta corriente visible desde el resumen (`client-purchase-history` §"El total comprado es bruto").
- [ ] 8.7 **RED→GREEN** — test: el resumen no cambia al paginar el historial (se calcula sobre el total, no sobre la página).

## 9. Índice de soporte

- [ ] 9.1 Crear la migración con `CREATE INDEX CONCURRENTLY IF NOT EXISTS` sobre `sales(account_id, client_id, date DESC)`. **Idempotente** — la integración GitHub de Supabase auto-aplica al mergear.
- [ ] 9.2 Verificar el timestamp contra el `MAX` real de las migraciones en producción antes de nombrar el archivo (sesiones paralelas colisionan).

## 10. Verificación visual (regla PO — obligatoria antes del merge)

- [ ] 10.1 Verificar `/clientes` en desktop y mobile, tema claro y oscuro: badges legibles, contraste suficiente, la tabla no desborda.
- [ ] 10.2 Verificar `/clientes/[id]` y `/clientes/[id]/cuenta` en desktop y mobile, tema claro y oscuro: pestañas utilizables con el pulgar, historial sin scroll horizontal, montos con `tabular-nums`.
- [ ] 10.3 Confirmar que ningún componente nuevo usa colores literales de Tailwind para estado — todo por tokens semánticos vía `cva`.
- [ ] 10.4 Recorrido completo por teclado: lista → detalle → pestaña de cuenta corriente → volver.

## 11. Cierre

- [ ] 11.1 Suite backend completa verde y coverage ≥87%; suite frontend completa verde. Comparar contra el baseline de 1.1–1.3.
- [ ] 11.2 Confirmar que `/clientes/[id]/cuenta` dejó de ser una superficie huérfana: existe una ruta de navegación desde la lista.
- [ ] 11.3 `openspec validate "clientes-frecuentes-historial" --strict` en verde.
- [ ] 11.4 Registrar en el PR las OQ abiertas (umbrales, bruto vs. neto, `clients.status`, orden por defecto) para el sign-off del PO.
