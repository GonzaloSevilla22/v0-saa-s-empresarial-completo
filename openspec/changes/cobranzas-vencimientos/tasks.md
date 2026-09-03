> **Modo TDD estricto activo.** Todo grupo que escriba código de producción sigue el ciclo
> SAFETY NET → RED → GREEN → TRIANGULATE → REFACTOR, y el apply devuelve la tabla de evidencia
> por task. Ninguna task de implementación se marca `[x]` sin su test escrito **antes**.
>
> **Governance por grupo** (design.md §Context): G2 (grupo 3) es **ALTO** — escribe dinero real
> en cuentas corrientes por los tres caminos de alta a la vez. Los grupos 2, 4 y 5 son MEDIO;
> los grupos 6, 7, 8 y 9 son BAJO.
>
> **Dependencia dura**: `cobranzas-panel` debe estar mergeado y su migración viva en producción
> antes de arrancar. Este change extiende su RPC, su pantalla y su entrada de menú.

## 1. Checkpoints previos (antes de escribir una línea)

- [x] 1.1 Confirmar que `cobranzas-panel` está mergeado y que `rpc_receivables_report` existe viva en prod. Si no, **parar**: no hay nada que extender.
- [x] 1.2 Confirmar el número de migración libre: `MAX(version)` de `supabase_migrations.schema_migrations` en prod y el último archivo de `supabase/migrations/`. El design asume `20261022000001` (Etapa A reserva `20261021000001`); si otro PR se lo llevó, renumerar — hay precedente de doble renumerado (`cuenta-corriente-party-guard`).
- [x] 1.3 **Gate de integridad de función**: capturar y hashear el `pg_get_functiondef` **vivo de prod** de las siete funciones que este change reescribe — `_pay_register_party_charge`, `c30_register_customer_account_movement`, `c30_register_supplier_account_movement`, `rpc_create_sale_operation`, `_c29_confirm_order_core`, `rpc_create_purchase_operation`, `rpc_receivables_report` — más `_notification_from_event`. Pegar los hashes en la cabecera de la migración. **Toda reescritura parte de ese cuerpo vivo, nunca del último archivo de migración** (ya divergió una vez: `metodos-pago-operaciones`).
- [x] 1.4 Capturar las **ACLs vigentes** de `_pay_register_party_charge` (esperado: `PUBLIC` y `anon` revocados **y `authenticated` también**, por el hotfix `20261010000001`). Recrearla con el `GRANT ... TO authenticated` de su archivo original reabriría una escritura cross-tenant ya cerrada.
- [x] 1.5 Grep de reutilización antes de crear nada: `due_date|payment_terms|plazo|vencimiento|aging|overdue` en `backend/`, `frontend/lib`, `frontend/hooks`, `frontend/components` y `supabase/migrations/`. Confirmar que no existe ningún helper, hook, mapper o RPC previo que haga esto (o casi).
- [x] 1.6 Registrar el **baseline de producción** para la verificación final: cantidad de deudores y saldo por cobrar (exploración 2026-09-02: 11 y $567.000), cantidad de cuentas de proveedor con saldo (esperado 1, saldo 0), y conteo de movimientos por tipo en las dos tablas de ledger.
- [x] 1.7 Medir el conteo de **deudores con cliente dado de baja** (OQ-2). Esperado 0. Si es > 0, anotarlo como hallazgo para el PO en el resumen del apply — no resolverlo dentro de este change.
- [x] 1.8 SAFETY NET del grupo 3: correr los tests existentes de los tres caminos de alta (venta desde formulario, POS, compra) y del helper de cargo, y anotar el conteo verde. Un fallo previo se reporta como pre-existente y **no** se arregla acá.

## 2. Migración — parte 1: columnas de plazo y de vencimiento

- [x] 2.1 RED — Gate SQL `supabase/tests/test_cobranzas_vencimientos_schema.sql`: las cinco columnas existen con el tipo y la nulabilidad esperados, las tres de plazo tienen `CHECK (>= 0)`, y ninguna tiene `DEFAULT`. Debe fallar antes de escribir la migración.
- [x] 2.2 GREEN — `supabase/migrations/20261022000001_cobranzas_vencimientos.sql`, bloque 1: `ADD COLUMN IF NOT EXISTS` de `accounts.default_payment_terms_days smallint`, `clients.payment_terms_days smallint`, `suppliers.payment_terms_days smallint` (las tres nullable, con `CHECK (... >= 0)` agregado idempotentemente), y `customer_account_movements.due_date date` + `supplier_account_movements.due_date date`. `COMMENT ON COLUMN` en las cinco, diciendo que la ausencia significa "sin plazo" / "sin vencimiento" y **no** cero.
- [x] 2.3 TRIANGULATE — Casos SQL: un plazo negativo es rechazado por el CHECK en cada uno de los tres niveles; las filas históricas de ambos ledgers quedan con `due_date` nulo; una segunda aplicación de la migración no reescribe ninguna fila ni falla.

## 3. Migración — parte 2: helpers de cargo y los tres caminos de alta (**GOVERNANCE ALTA**)

- [x] 3.1 RED — Gate SQL: cada una de las tres funciones de cargo tiene **exactamente una** definición (`42725`), con el argumento de vencimiento **trailing**, y sus ACLs son las capturadas en 1.4 — en particular `_pay_register_party_charge` **sin** `authenticated`.
- [x] 3.2 GREEN — `DROP FUNCTION` + `CREATE` de `c30_register_customer_account_movement` y `c30_register_supplier_account_movement` con `p_due_date date DEFAULT NULL` como 5º argumento, escribiéndolo en el `INSERT` del ledger. `REVOKE`/`GRANT` reafirmados **en el mismo archivo** (un `DROP`+`CREATE` resetea las ACLs).
- [x] 3.3 GREEN — `DROP FUNCTION` + `CREATE` de `_pay_register_party_charge` con `p_due_date date DEFAULT NULL` como 7º argumento. **La cascada se resuelve acá** (D3): cuando el parámetro llega nulo, deriva `COALESCE(<parte>.payment_terms_days, accounts.default_payment_terms_days)` y calcula `due_date = <fecha local del cargo> + plazo`; cuando el plazo efectivo es nulo, `due_date` queda nulo. Guard `P0400` si el vencimiento explícito es anterior a la fecha del cargo. ACLs exactas de 1.4 — **sin `authenticated`**.
- [x] 3.4 GREEN — `CREATE OR REPLACE` (misma firma) de los tres callers de alta, partiendo del cuerpo vivo de 1.3, para transportar el vencimiento hasta el helper: `rpc_create_sale_operation` (parámetro nuevo trailing opcional), `_c29_confirm_order_core` (el POS **no** recibe override — pasa nulo y deja que el helper resuelva, D11) y `rpc_create_purchase_operation` (parámetro nuevo trailing opcional). **Ninguno resuelve la cascada por su cuenta.**
- [x] 3.5 TRIANGULATE — Casos SQL de cascada: plazo de la parte gana sobre el de la cuenta; parte sin plazo hereda el de la cuenta; sin plazo en ningún nivel el cargo se postea con `due_date` nulo **sin fallar**; plazo `0` produce vencimiento igual a la fecha del cargo.
- [x] 3.6 TRIANGULATE — Casos SQL del override: el vencimiento explícito gana sobre la cascada; un vencimiento anterior a la fecha del cargo aborta con `P0400` y **no** deja venta ni movimiento; un vencimiento ya cumplido pero posterior al cargo se acepta.
- [x] 3.7 TRIANGULATE — Caso SQL de simetría: la misma venta a crédito cargada desde el formulario y desde el POS, el mismo día y sin override, produce **el mismo vencimiento** (la regresión que D3 existe para impedir).
- [x] 3.8 TRIANGULATE — Caso SQL del lado proveedor: el cargo de compra a crédito lee el plazo del **proveedor**, no el del cliente, y escribe en `supplier_account_movements`.
- [x] 3.9 REFACTOR — Correr el SAFETY NET de 1.8 completo y exigir el mismo verde. Cualquier fallo nuevo **bloquea el grupo**.

## 4. Migración — parte 3: derivación FIFO y read-models

- [x] 4.1 RED — Gate SQL `supabase/tests/test_receivables_aging_fifo.sql` con el **invariante de cierre**: para una cuenta sintética con cargos, cobros, notas de crédito y una anulación, `SUM(importe abierto) = customer_accounts.balance`. Debe fallar antes de escribir la derivación.
- [x] 4.2 GREEN — Derivación FIFO por línea de flotación (design.md D4): cargos = `sale`/`purchase` + `adjustment` positivo, ordenados por `(COALESCE(due_date, created_at en día argentino), created_at, id)`; crédito disponible = suma negada, **con su propio signo**, de todos los demás movimientos. Sin tabla de imputaciones, sin columna de aplicado.
- [x] 4.3 GREEN — `DROP FUNCTION` + `CREATE` de `rpc_receivables_report(p_account_id uuid)` con el tipo de retorno extendido: `overdue_total`, los cinco tramos, `oldest_due_date` y `days_overdue_max`, **conservando** las columnas de la Etapa A y su guard `P0401` como primera sentencia. Un `CREATE OR REPLACE` con `RETURNS TABLE` distinto falla con `42P13`. ACLs re-emitidas en el mismo archivo.
- [x] 4.4 GREEN — `CREATE` de `rpc_payables_report(p_account_id uuid)`, molde textual del anterior sobre `supplier_accounts`/`suppliers`, con el mismo guard, las mismas exclusiones y las mismas ACLs.
- [x] 4.5 GREEN — `CREATE` de `rpc_set_default_payment_terms(p_days smallint)` `SECURITY DEFINER` con guard `is_account_writer` (`P0401`) y `CHECK` de no negatividad (`P0400`); ACLs con `GRANT` sólo a `authenticated`.
- [x] 4.6 TRIANGULATE — Casos SQL de imputación: un cobro cancela el cargo más viejo; un cobro parcial deja un cargo parcialmente abierto; **anular un cobro reabre exactamente los cargos que había cancelado, en orden inverso**; una nota de crédito consume como un cobro.
- [x] 4.7 TRIANGULATE — Casos SQL de tramos: vencimiento hoy cae en "al día"; ayer cae en 1-30; las fronteras 30/31 y 60/61 caen donde corresponde; un cargo sin vencimiento de hace 200 días cae en "sin vencimiento" y **nunca** en un tramo de vencido; los cinco tramos suman el saldo.
- [x] 4.8 TRIANGULATE — Caso SQL de las dos reglas separadas (D5): un cargo **sin** vencimiento y más viejo se cancela **primero** (orden de imputación) y aun así, mientras está abierto, se clasifica en "sin vencimiento" (clasificación).
- [x] 4.9 TRIANGULATE — Caso SQL de día calendario argentino: un vencimiento de hoy evaluado a las 22:00 ART (ya día siguiente en UTC) sigue clasificando como al día. Usar `reporting_local_today()`, **nunca** `now()` ni `CURRENT_DATE`.
- [x] 4.10 TRIANGULATE — Caso SQL de robustez del vocabulario: un movimiento de un tipo no clasificado como cargo entra al pozo de crédito con su signo, no genera ítem abierto, y el invariante de cierre se sigue cumpliendo.

## 5. Migración — parte 4: barrido diario y avisos

- [x] 5.1 RED — Gate SQL: existe el job de `pg_cron`, el barrido no es ejecutable por `anon`/`authenticated`, y `_notification_from_event` tiene **una sola** definición con los dos tipos nuevos en su lista en alcance.
- [x] 5.2 GREEN — `CREATE OR REPLACE FUNCTION public._produce_receivables_overdue_digest()`, molde textual de `_produce_plan_expiring_soon` (`20260830000002`): CTE de candidatos por cuenta con `overdue_total > 0` **y** predicado explícito `NOT EXISTS (... metadata->>'as_of' = reporting_local_today())` (D8, segunda capa de dedup), `INSERT` en `email_logs` con `ON CONFLICT DO NOTHING`, e `INSERT` en `public.events` **sólo para las filas que el `INSERT` de email realmente insertó**. Dos ramas en la misma función: por cobrar y por pagar.
- [x] 5.3 GREEN — `CREATE OR REPLACE` de `_notification_from_event` sobre la **misma firma** (`public.events`), sumando los dos tipos nuevos a la lista en alcance con target `ADMIN`, severidad `warning` y `branch_id` nulo. Partir del cuerpo vivo de 1.3.
- [x] 5.4 GREEN — `cron.unschedule` + `cron.schedule` del job diario `'0 12 * * *'` (~09:00 Mendoza), patrón `v3-notifications-realtime` §4.2.
- [x] 5.5 TRIANGULATE — Casos SQL del barrido: una cuenta con deuda vencida recibe **un** aviso con la cifra agregada; una segunda corrida el mismo día **no** duplica, ni siquiera con importes distintos; al día siguiente vuelve a avisar; una cuenta sin deuda vencida no recibe nada; una cuenta con deuda sólo "sin vencimiento" tampoco.
- [x] 5.6 TRIANGULATE — Casos SQL de los dos canales: el evento se crea **sólo** cuando el registro de correo fue insertado; los dos lados (por cobrar y por pagar) se deduplican de forma independiente.
- [x] 5.7 TRIANGULATE — **Gate del invariante D13**: el conjunto canónico de `event_type` del Consumer 3 sigue teniendo **once** elementos y ninguno de los dos tipos nuevos aparece en él; el gate `test_journal_event_types_canonical` (o equivalente vigente) sigue verde. Un evento de digest procesado por el relay **no** produce asiento contable.
- [x] 5.8 TRIANGULATE — Caso SQL del escenario que más importa hoy: con las 5 cuentas de producción **sin plazo configurado**, el barrido devuelve **0 filas** y no produce ningún aviso.
- [x] 5.9 REFACTOR — Verificar idempotencia de la migración completa (`supabase db reset` local dos veces) y que no rompa los gates existentes: `test_function_acl_gate.sql` (los 5 chequeos), el de ERRCODEs de 5 caracteres y el de integridad de función.

## 6. Edge Function: plantilla de correo

- [x] 6.1 RED — Test de la plantilla en `supabase/functions/send-email/`: el cuerpo del resumen renderiza cantidad de partes, importe vencido y el acceso a `/cobranzas`, tomados de `metadata`.
- [x] 6.2 GREEN — Dos ramas nuevas en `supabase/functions/send-email/index.ts` (`receivables_overdue_digest` y `payables_overdue_digest`), con el layout de marca existente y textos distintos por lado.
- [x] 6.3 TRIANGULATE — Un `event_type` desconocido sigue cayendo en el comportamiento genérico; las ~17 plantillas existentes conservan asunto y cuerpo.

## 7. Backend: read-models, historial y configuración

- [x] 7.1 RED — `backend/tests/test_receivables_aging.py`: el repository devuelve los tramos y el importe vencido en el envelope estándar; la suma de los cinco tramos de cada fila es igual a su saldo. Mocks de `asyncpg` con el patrón de los tests de `payment_method_repository`.
- [x] 7.2 GREEN — `customer_account_repository.py`: los campos de aging en `list_receivables_page`/`get_receivables_summary`, y el filtro por tramo resuelto **en el servidor**, traducido por diccionario a predicado y nunca por interpolación.
- [x] 7.3 RED — Test de regresión de D7: los derivados de vencimiento (`due_date`, `is_overdue`, `days_overdue`, `open_amount`) viajan por **`list_movements` Y `list_movements_page`**. El test debe fallar si sólo se agrega a una — es el defecto exacto que se comió `cobranzas-reverso`.
- [x] 7.4 GREEN — Derivados de vencimiento en las **dos** consultas de `customer_account_repository.py` y en las **dos** espejo de `supplier_account_repository.py`.
- [x] 7.5 GREEN — `supplier_account_repository.py` + service + router: `list_payables_page` / `get_payables_summary` y el `report_router` de `/reports/payables`, molde exacto del de la Etapa A. Registrar en `backend/main.py`.
- [x] 7.6 GREEN — Schemas Pydantic v2 (`Decimal` para dinero, `date | None` para vencimientos, `int | None` para días); `Literal` para el filtro de tramo en la firma del router, para que un valor fuera del dominio ni llegue al service.
- [x] 7.7 RED+GREEN — `payment_terms_days` en `ClientCreate`/`ClientUpdate`/`ClientOut` y sus espejos de proveedor, con `client_repository.py` y `supplier_repository.py`. **Test primero de D14**: un `PUT` que omite el plazo **no** lo pone en `NULL` (preservación por `model_fields_set`, mismo patrón que `metodos-pago-operaciones`).
- [x] 7.8 RED+GREEN — `GET`/`PATCH` del plazo por defecto de la cuenta sobre `rpc_set_default_payment_terms`, con su test de `P0401` traducido a RFC 7807.
- [x] 7.9 TRIANGULATE — Casos de router: filtro de tramo fuera del `Literal` → 422 sin ejecutar consulta; página fuera de rango → `items: []` con `total` correcto; `P0401` y `P0400` traducidos al problem+json correspondiente.
- [x] 7.10 REFACTOR — Cobertura del backend por encima del umbral de CI (≥87%), sin duplicar el predicado de deudor ni la clasificación de tramos en ningún lado.

## 8. Frontend: capa canónica

- [x] 8.1 RED — `frontend/__tests__/lib/receivables-aging.test.ts`: el mapper convierte la fila cruda (snake_case, dinero como string) al tipo del dominio; `null` en vencimientos y días se preserva y **no** degrada a `0`; el clasificador de tramo devuelve "sin vencimiento" para vencimiento ausente, nunca "al día".
- [x] 8.2 GREEN — `frontend/lib/receivables-aging.ts`: tipos, mapper, rótulos de tramo y el formateador de estado en texto. **Sin `any`**, tipos explícitos.
- [x] 8.3 RED+GREEN — `frontend/lib/debt-reminder.ts`: función **pura** que arma el texto del recordatorio de WhatsApp (nombre, saldo, importe vencido, tramo más viejo), con sus tests. Reutiliza `buildWhatsAppUrl` de `lib/phone-utils.ts` — **no** se escribe un normalizador nuevo.
- [x] 8.4 GREEN — `frontend/lib/types.ts` y `frontend/lib/query-keys.ts`: tipos del dominio y claves de `payables.*` y del filtro de tramo.
- [x] 8.5 RED+GREEN — `frontend/hooks/data/use-payables.ts` y la extensión de `use-receivables.ts`, con sus tests.
- [x] 8.6 RED — Test de regresión de invalidación: registrar/anular un **pago a proveedor** invalida también las claves de `payables`. Debe fallar antes del cambio (la Etapa A sólo cableó las de `receivables`).
- [x] 8.7 GREEN — Invalidación de `payables.*` dentro de `use-supplier-account.ts` (registro y anulación de pago) y en las mutaciones que crean deuda de compra a crédito. **En el hook, no en la pantalla.**

## 9. Frontend: superficies

- [x] 9.1 RED — Test de `/cobranzas`: columna de importe vencido y tramo por fila **en texto**; el deudor sin vencimiento se presenta como tal y no como al día; la cabecera muestra total por cobrar **y** total vencido; el filtro de tramo se envía al servidor y no reordena en el cliente.
- [x] 9.2 GREEN — `/cobranzas`: columnas de vencimiento, filtro por tramo, y retiro de la nota al pie de la Etapa A que declaraba que el sistema no registra vencimientos (delta `REMOVED`), sustituida por el aviso de "sin plazos configurados" con acceso a Configuración cuando corresponda.
- [x] 9.3 RED+GREEN — Pestañas "Por cobrar" / "Por pagar" en la misma pantalla, con la tabla, los tramos y el filtro compartidos; acción de pago por fila abriendo el formulario de pago **existente**, sin formulario nuevo; `EmptyState` propio del lado proveedor.
- [x] 9.4 RED+GREEN — Botón de recordatorio por WhatsApp en la fila del deudor, con nombre accesible; caso del cliente sin teléfono utilizable (abre la mensajería sin destinatario resuelto, no queda inoperante).
- [x] 9.5 RED+GREEN — Campo de vencimiento en el **bloque de cuenta corriente que ya existe** del formulario de venta (el que muestra saldo actual y proyectado con `kind='credit'`), pre-cargado con el vencimiento resuelto y editable. **Ningún bloque nuevo, y el POS sin campo** (D11).
- [x] 9.6 RED+GREEN — Campo "Plazo de pago (días)" en `client-form.tsx` y `supplier-form.tsx`, con el vacío rotulado como "usa el plazo de la cuenta" y **no** como `0`.
- [x] 9.7 RED+GREEN — Pestaña "Cobranzas" en `/configuracion` (`TabsList` de `lg:grid-cols-8` a `lg:grid-cols-9`) con el formulario del plazo por defecto de la cuenta.
- [x] 9.8 RED+GREEN — Vencimiento, estado y saldo abierto por movimiento en el historial de cuenta corriente de cliente **y** de proveedor. Verificar sobre la **pantalla real**, no sólo sobre el test del endpoint paginado (D7).
- [x] 9.9 GREEN — Rótulos legibles de los dos tipos de notificación nuevos en el `TYPE_LABELS` de `NotificationBell.tsx`.

## 10. Verificación

- [x] 10.1 Suite completa de backend en verde (`pytest`), con la cobertura por encima del umbral de CI.
- [x] 10.2 Suite completa de frontend en verde (`pnpm vitest run`) y `tsc` sin errores nuevos. **Cero `any`** en el código nuevo.
- [x] 10.3 `supabase db reset` local limpio con la migración nueva, aplicada **dos veces**, y los gates de `KPI_Validation.yml` corridos en el orden real del workflow. Anotar los fallos pre-existentes conocidos (`test_sales_order_payment_method_drop.sql`, el paso de reaplicación de idempotencia) en vez de "arreglarlos" en este PR.
- [ ] 10.4 Verificación visual de `/cobranzas` (las dos pestañas), del formulario de venta a crédito, de los formularios de cliente y proveedor, de `/configuracion` y de los dos historiales de cuenta corriente, en las **cuatro** combinaciones (claro/oscuro × móvil/escritorio), con capturas. Confirmar que ninguna columna desaparece en móvil, que el documento no desborda horizontalmente y que la `TabsList` de 9 pestañas sigue siendo usable.
- [x] 10.5 Pasada de accesibilidad sobre la superficie nueva: nombre accesible del botón de recordatorio y de los accesos por fila, foco visible, contraste ≥4,5:1 en los importes y en los rótulos de tramo. **Tokens semánticos, cero colores hardcodeados** (D15).
- [x] 10.6 `openspec validate cobranzas-vencimientos --strict` en verde.

## 11. Post-merge (producción)

- [ ] 11.1 `MAX(version)` de `supabase_migrations.schema_migrations` = la migración de este change; **una sola definición** de cada una de las funciones reescritas.
- [ ] 11.2 ACLs vivas: `_pay_register_party_charge` **sin** `authenticated` (1.4); `rpc_receivables_report`, `rpc_payables_report` y `rpc_set_default_payment_terms` con `anon` sin `EXECUTE` y `authenticated` con `EXECUTE`; el barrido sin `EXECUTE` para ningún rol de aplicación.
- [ ] 11.3 Job de `pg_cron` programado y con su horario correcto; primera corrida devolviendo **0** filas (ninguna cuenta tiene plazo configurado todavía).
- [ ] 11.4 Conteo de cargos con `due_date` no nulo: esperado **0** hasta que alguien configure un plazo. Conteo de movimientos históricos reescritos: esperado **0**.
- [ ] 11.5 El total por cobrar del panel cierra contra la suma de los cinco tramos y contra el baseline de 1.6.
- [ ] 11.6 Demo real al PO: configurar un plazo, registrar una venta a crédito, verificar el vencimiento en el historial, registrar un cobro parcial y ver la imputación FIFO, anular el cobro y ver los cargos reabrirse, y disparar el recordatorio por WhatsApp.
- [x] 11.7 Actualizar `CHANGES.md` y el puntero de `CLAUDE.md` (con `python scripts/ci/check_docs_sync.py --fix` en el mismo PR), registrando las OQs que queden abiertas.
