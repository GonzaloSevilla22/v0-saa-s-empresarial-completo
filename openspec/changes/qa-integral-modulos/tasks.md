# Tasks: qa-integral-modulos

> TDD estricto por grupo: RED primero (el test que reproduce el hallazgo Y, para los componentes compartidos, el test del comportamiento existente sano), GREEN mínimo, triangulación, refactor. Governance por grupo en la matriz de `design.md`. Los grupos son independientes salvo donde se indica; G2 conviene antes que la verificación visual del resto.

## 0. Preparación y checkpoint de integridad

- [x] 0.1 Checkpoint de integridad de función (regla del proyecto, ANTES de escribir SQL): capturar `pg_get_functiondef` VIVO de prod de `rpc_branch_report`, `rpc_product_profitability` y `rpc_create_expense`; hashear y comparar contra el último archivo de migración de cada una; si divergen, el baseline es el cuerpo vivo
  > **Evidencia (2026-08-31)**: baselines byte-exactos en `baseline/*.live.sql` (md5 local == md5 de prod, ver `baseline/BASELINE.md`). `rpc_branch_report` `fd21f886…` y `rpc_create_expense` `b58ac4d2…` = idénticos a su último archivo de migración; **`rpc_product_profitability` `eb254459…` DIVERGE del archivo** (`20260814000001` L153 dice `'P403'`, el vivo dice `'P0403'` — reescritura in-place posterior; única diferencia). Prod `MAX(version)=20261015000001` (264 migraciones, local idéntico) ⇒ **`20261016000001` sigue válida sin renumerar**. Safety net (en origin/main limpio): pytest backend **1664 passed / 3 skipped**; `tsc` **10 errores preexistentes** (los conocidos, en tests ajenos); gates SQL del workflow **26/34 PASS** — los 8 FAIL son ambientales de la DB local compartida sucia (usuarios ancla `*-gate@test.local` de corridas previas en admin_kpis/pagos_cableados/pos_banco/asiento_venta/delete_guard/banco_caja_historial/compras_proveedor + `\i` relativo de cuentas_billetera irresoluble vía docker exec), no regresiones; el `db reset` de 17.1 los limpiará (ojo: también borra los seeds del QA que D10 reutiliza — re-seedear antes de la verificación visual). Vitest frontend: **1558 passed / 1558** (194 archivos).
- [ ] 0.2 Levantar el stack local (Supabase Docker + Next dev + FastAPI) y reconstruir el método de verificación visual desde `qa/INFORME.md` §4 (Playwright, cookies inyectadas, táctil real por CDP; el kit original fue eliminado del scratchpad — ver D10)

## 1. G1 — Popover dentro de modal (H1, bug del PO) [MEDIUM]

- [x] 1.1 RED **(navegador real — Playwright/CDP reusando la infraestructura de 0.2, NO vitest/jsdom)**: test que monta un selector (searchable-select/product-picker) dentro de un Dialog, despacha `wheel` sobre la lista abierta y espera `scrollTop > 0` (hoy falla: el gesto se cancela). jsdom no implementa layout ni scroll ante `wheel`, así que ahí el assert fallaría también DESPUÉS del fix — el contrato solo discrimina en navegador
  > **Evidencia (2026-08-31)**: infraestructura nueva — arnés `frontend/app/dev-harness/popover` (solo dev, `notFound()` en prod) + project `harness` en `playwright.config.ts` (sin auth/seeds; corre en el CI de E2E) + spec `frontend/e2e/harness/g1-popover-modal.spec.ts`. RED ejecutado: `scrollTop` quedó en 0 tras `wheel` (Dialog) y tras `touchmove` real por CDP (Dialog y Sheet) — 6 casos rojos, el bug exacto del informe (gesto cancelado, lista scrolleable).
- [x] 1.2 RED sano **(navegador real, mismo runner que 1.1)**: test del comportamiento EXISTENTE fuera de modal — popover portalizado a `document.body`, cierra por click afuera y por Escape (protege contra la regresión del fix)
  > **Evidencia**: caso "portaliza a document.body, scrollea con la rueda y cierra por clic afuera y Escape" — verde ANTES y DESPUÉS del fix (fuera de modales el contexto es null y no cambia nada).
- [x] 1.3 GREEN: `DialogContent` (`ui/dialog.tsx`) y `SheetContent` (`ui/sheet.tsx`) publican su nodo de contenido en `DialogContainerContext`; `ui/popover.tsx` pasa ese nodo como `container` del `PopoverPrimitive.Portal` cuando existe (D1)
  > **Evidencia (2026-08-31) — R1 CONFIRMADO y plan C promovido a plan A (pre-autorizado por D1/R1)**: la variante `container` del Portal se implementó y se corrió en el arnés — el Sheet quedó verde pero en el Dialog el popper `fixed` quedó recortado en el borde del `DialogContent` (transform = containing block + `overflow-y-auto` = clipping; captura en el run), y la mitigación (i) exigiría reestructurar el scroll de `DialogContent`, del que 20+ callers dependen como SU contenedor de layout (`flex flex-col p-0`, `max-h-[90vh]`…) — radio de explosión inaceptable; la (ii) no existe en la API pública de Radix. **Plan C final**: `DialogContent`/`SheetContent` publican su nodo en `DialogContainerContext` y `ui/popover.tsx` activa `modal` en el Root de Radix Popover SOLO cuando ese contexto existe — el camino modal de Radix monta su propio `RemoveScroll` con el popper como shard (API pública, sin parchear nada); el Portal sigue yendo a `document.body` siempre. 7/7 verdes, incluido "el último producto es alcanzable y visible (sin recorte)".
- [x] 1.4 Eliminar el `modal={false}` mal ubicado de `frontend/components/shared/product-picker.tsx:199` y `frontend/components/ui/searchable-select.tsx:135` (atributo DOM espurio; advertencia de React)
  > **Evidencia**: retirados con su `@ts-expect-error`; comentario en su lugar.
- [x] 1.5 TRIANGULAR: mismo contrato con gesto táctil, y en los tres modales del informe (venta/editar venta, nueva compra, ajustar stock — este último usa otro contenedor)
  > **Evidencia**: triangulado en el arnés sobre los DOS contenedores reales de esos modales (Dialog directo — el de ajustar stock — y Sheet bottom con las clases de ResponsiveModal — el de venta/compra en móvil), con rueda Y táctil real por CDP, y con `searchable-select` Y `product-picker` montados de verdad; además Escape/clic-afuera dentro del Dialog no cierran el Dialog. La pasada sobre las pantallas reales queda en 1.6 (fase visual D10).
- [ ] 1.6 Verificación visual (método D10): selector de producto y de cliente scrollean con el dedo en 390x844 dentro de los tres modales; sin recorte del desplegable en escritorio 1440 (R1); POS intacto como control positivo

## 2. G2 — Shell sin min-w-0 (H2, 12 pantallas) [MEDIUM]

- [x] 2.1 RED **(navegador real — Playwright reusando la infraestructura de 0.2, NO vitest/jsdom)**: test de layout — shell montado con contenido más ancho que el viewport en 390 px, `scrollWidth` del documento no supera el viewport (hoy falla en navegador; en jsdom `scrollWidth` es siempre 0 y pasaría trivialmente ANTES del fix — verde falso). PROHIBIDO el RED alternativo de assertear `min-w-0` en el string de `className`: es la aserción trivial que el modo TDD estricto veta
  > **Evidencia (2026-08-31)**: arnés `frontend/app/dev-harness/shell` (SidebarProvider/Sidebar/SidebarInset reales + réplica exacta del div de `(dashboard)/layout.tsx:28` + tabla de columnas en px fijos) + spec `frontend/e2e/harness/g2-shell-overflow.spec.ts`. RED ejecutado: `scrollWidth` 746 > 390 (el CTA primario afuera del viewport), el desborde del informe reproducido. GREEN: 390 exacto, CTA visible, la tabla scrollea en su propio `overflow-x-auto`.
- [x] 2.2 RED sano **(navegador real, mismo runner)**: test del sidebar/inset en desktop 1440 — dimensiones y colapso sin cambios
  > **Evidencia**: control desktop 1440 — sidebar 256 px expandido / 48 px colapsado (`collapsible="icon"`, el modo de AppSidebar, ±1 px por el border-r) e inset ocupando el resto, idéntico antes y después del fix.
- [x] 2.3 GREEN: `min-w-0` en el `<main>` de `SidebarInset` (`ui/sidebar.tsx:334`) y en el contenedor de `app/(dashboard)/layout.tsx:28`
  > **Evidencia**: ambos aplicados (el arnés replica el div del layout y quedó espejado — nota en el propio arnés).
- [x] 2.4 Contribuyentes por pantalla: `flex-wrap` en las barras de acciones de `product-catalog.tsx:358`, `stock/page.tsx:160`, `compras/page.tsx:51-58` y `BranchList.tsx:105` (quitando `shrink-0`); `flex-wrap` en la fila de acciones del detalle expandido de `sale-operations-list.tsx:496`
  > **Evidencia**: los 5 aplicados (en stock/compras también el contenedor del encabezado, que era parte del mínimo de 479 px). Verificación por pantalla en 2.8 (fase visual).
- [x] 2.5 Colapso responsive de la etiqueta del `ExportButton` (`ExportButton.tsx:113-135`, patrón `hidden sm:inline` de sus hermanos)
  > **Evidencia**: `hidden sm:inline` para la etiqueta larga + "Exportar" en `sm:hidden`; el contador de cuota también colapsa.
- [x] 2.6 Alinear el span de productos de `purchase-operations-list.tsx:335-336` al patrón de ventas ("primer producto · +N más", `sale-operations-list.tsx:404-408`)
  > **Evidencia**: aplicado en las DOS filas de compras (móvil L334 y desktop L368 — el espejo de ventas ya lo hacía bien en ambas).
- [x] 2.7 Scroll horizontal propio (`overflow-x-auto`) o apilado bajo `sm` en `LedgerMovementsPanel.tsx:77-111` y `stock-movements-panel.tsx:111-160` (columnas en px fijos + hijo `display:table` del ScrollArea)
  > **Evidencia**: elegido `overflow-x-auto` — wrapper alrededor de cabecera + ScrollArea con `min-w-[420px]` interno en ambos paneles: el hijo `display:table` de Radix queda acotado a ese mínimo y el desborde scrollea dentro del panel, no estira la página.
- [ ] 2.8 Verificación visual de las 12 pantallas de la tabla de H2 en 390x844 (CTAs y acciones de fila dentro del viewport, tacho de `/productos` alcanzable) + `/gastos`, `/ventas`, `/compras`, `/productos`, `/clientes` en 768 y 1024 (tablet, absorbe el candidato de `CHANGES.md`) + control desktop 1440

## 3. G3 — Comparativo invertido (H3) [LOW]

- [ ] 3.1 RED: test de la página con datos sintéticos donde los gastos del mes en curso superan a los del anterior — el badge de gastos debe mostrar signo positivo en rojo (hoy: negativo en verde). Hoy no existe NINGÚN test de `rpc_period_comparison` ni de la página
- [ ] 3.2 GREEN: invertir los defaults de `reportes/comparativo/page.tsx:152-155` (A = mes anterior = base, B = mes en curso, contrato `(B−A)/A` de la RPC — NO tocar la RPC ni `ai-comparativo`)
- [ ] 3.3 Rotular el badge de delta (qué mide: evolución de A a B) en `DeltaBadge`
- [ ] 3.4 TRIANGULAR: las 4 tarjetas con series que suben y que bajan; casos `invertColors` (gastos/compras) donde la doble inversión no se cancela; delta NULL → "N/A"
- [ ] 3.5 Verificación visual en las 4 combinaciones (390/1440 × claro/oscuro)

## 4. G4 — Reporte por sucursal muerto (H4) [MEDIUM]

- [x] 4.1 RED (pgTAP/SQL): `rpc_branch_report` sobre fixture con 2 sucursales y ventas/gastos en rango debe devolver filas — hoy falla con `42702 branch_id is ambiguous`
  > **Evidencia (2026-08-31)**: RED ejecutado contra la DB local ANTES de la migración — `rpc_branch_report` reprodujo `42702 column reference "branch_id" is ambiguous` con sesión de miembro real vía `request.jwt.claims`. Gate versionado nuevo `supabase/tests/test_qa_integral_fixes.sql` §(1) con tenant sintético propio; **control negativo ejecutado**: con los cuerpos del baseline restaurados en una transacción (rollback), el gate aborta con el 42702.
- [x] 4.2 GREEN: migración `20261016000001` — reescribir `rpc_branch_report` desde el baseline vivo (0.1) calificando `branch_id` en el CTE `all_branch_ids`; re-aplicar ACLs vigentes en el mismo archivo; sin ERRCODEs nuevos
  > **Evidencia**: `supabase/migrations/20261016000001_qa_integral_fixes.sql` §1 — diff contra `baseline/rpc_branch_report.live.sql` = SOLO los dos `branch_id` calificados en `all_branch_ids` (+comentario); probado en local que el `ORDER BY total_sales` no necesita calificación. ACLs reafirmadas = estado vivo de prod (`postgres/authenticated/service_role`, sin PUBLIC/anon). Gate §(1) asserta EFECTO: 500/1234/1 por sucursal. Aplicada ×2 en local con fingerprint md5 idéntico (cuerpos+proacl+conteos). El warning tolerante de `test_gastos_forma_pago` (6.5b) se auto-fortaleció: ahora PASS con la llamada real. Cadena de reapply de `KPI_Validation.yml`: agregada como último eslabón + gate propio como paso nuevo; YAML validado.
- [ ] 4.3 RED (frontend): la página con sesión válida debe pedir el reporte con la cuenta resuelta por `account_members`; y ante un error del RPC debe mostrar la rama de error (hoy: silencio en ambos)
- [ ] 4.4 GREEN: `reportes/sucursal/page.tsx:80-82` — tenant por el canon de `auth-context` (`account_members`), eliminar la lectura de `user_metadata.account_id`; agregar rama de error visible distinguible de "sin datos"
- [ ] 4.5 TRIANGULAR: rango sin datos → "sin datos" (no error); RPC caído → error visible; verificación de que `rpc_cost_center_report` (espejo sano) no se toca
- [ ] 4.6 Verificación visual con el seed local (2 sucursales con ventas y gastos) en las 4 combinaciones

## 5. G5 — Campana sin scroll (H5) [LOW]

- [ ] 5.1 RED **(navegador real — Playwright reusando la infraestructura de 0.2; la alcanzabilidad por scroll no es observable en jsdom)**: test del panel con 15 notificaciones — el último ítem es alcanzable por scroll (hoy: recortado a 6, `overflow-y: hidden`)
- [ ] 5.2 GREEN: `NotificationBell.tsx:92` — mover el límite de alto del root del `ScrollArea` al viewport interno
- [ ] 5.3 Verificación visual: rueda y dedo llegan a la notificación 15 en ambos viewports

## 6. G6 — Arqueo autodestruido (H6) [MEDIUM]

- [ ] 6.1 RED: test que cierra sesión con diferencia y resuelve el refetch de `current-session` a "sin sesión" — el panel de resultado debe seguir montado (hoy: se desmonta en 56–181 ms)
- [ ] 6.2 GREEN: subir `<CloseSessionDialog>` fuera del ternario de `caja/page.tsx:216-232`, con estado `open` propio a nivel página (mismo patrón que `LedgerAdjustmentDialog` en L298); sin tocar `use-cash-session.ts`
- [ ] 6.3 TRIANGULAR: arqueo exacto y con sobrante también persisten; "Listo" cierra el panel y la pantalla queda en "sin sesión abierta"
- [ ] 6.4 Verificación visual: cierre real con faltante en local — el panel queda hasta que el usuario lo cierra, en ambos viewports

## 7. G7 — Toasts fantasma del export (H7) [MEDIUM]

- [ ] 7.1 RED: test de `ExportButton` con la Edge Function fallando — el usuario ve un toast de error por `sonner` (hoy: nada, el Toaster de shadcn no está montado en ningún layout)
- [ ] 7.2 GREEN: migrar las 5 ramas de `ExportButton.tsx` de `@/hooks/use-toast` a `sonner` (D5 — NO montar un segundo `<Toaster />`)
- [ ] 7.3 TRIANGULAR: rama de éxito y rama de cuota agotada visibles; si `hooks/use-toast` queda sin consumidores, anotarlo como candidato de limpieza (no borrarlo acá)
- [ ] 7.4 Verificación visual en `/ventas`, `/gastos` y `/compras`

## 8. G8 — Backend roto en silencio [MEDIUM]

- [x] 8.1 `GET /sales-orders`: RED con fixture de órdenes sembradas (hoy 500: `SalesOrderOut.payment_method` requerido vs `SELECT` sin la columna, `schemas/sales_orders.py:101` + `sales_order_repository.py:144`); GREEN alineando proyección SQL y contrato Pydantic mirando el DDL vivo (D6); TRIANGULAR con orden sin forma de pago
  > **Evidencia (2026-08-31)**: RED ejecutado — `backend/tests/test_sales_orders_payment_method_contract.py` reprodujo el 500 exacto (`ResponseValidationError: missing payment_method`) con la fila TAL CUAL la devuelve hoy la tabla (DDL vivo verificado: `sales_orders` sin columna `payment_method`, 0 en `information_schema`). GREEN: el repo DERIVA `pm.kind AS payment_method` vía LEFT JOIN a `payment_methods` en `list_orders` y `get_order`, y `SalesOrderOut.payment_method` pasa a `Optional` (+`payment_method_id` expuesto) — orden sin imputación es legal (None). TRIANGULADO: fila sin la clave → 200/None; fila imputada → serializa el kind; detalle usa el mismo contrato; proyección validada con EXPLAIN contra la DB local. 4 tests nuevos + los 58 de `test_c29_quote_salesorder.py` en verde.
- [x] 8.2 `rpc_product_profitability`: RED SQL que hoy reproduce el `42804` (`last_sale_date date` vs `MAX(s.date)` timestamptz); GREEN en `20261016000001` con cast consciente de zona — `(MAX(s.date) AT TIME ZONE 'America/Argentina/Mendoza')::date` o el patrón de `reporting_local_today()`, NUNCA `::date` desnudo (reintroduciría el off-by-one de RN-D5; conserva la firma, D6), baseline vivo + ACLs re-aplicadas; verificación de `/rentabilidad` cargando datos
  > **Evidencia (2026-08-31)**: RED ejecutado — `42804 structure of query does not match function result type` reproducido en local ANTES de la migración. GREEN en `20261016000001` §2: única diferencia con `baseline/rpc_product_profitability.live.sql` = `(MAX(s.date) AT TIME ZONE 'America/Argentina/Mendoza')::date` (+comentario); firma y RETURNS TABLE intactos, `'P0403'` vivo conservado. Gate `test_qa_integral_fixes.sql` §(2) con **triangulación de zona**: venta sembrada a las 23:30 ART (=02:30 UTC del día siguiente) debe fechar en su día LOCAL — un `::date` desnudo regresivo falla el assert. ACLs reafirmadas. GREEN local sobre datos reales: 25 filas, `last_sale_date` en fecha ART. ⚠️ La verificación visual de `/rentabilidad` queda para la fase D10/17.3 (requiere stack completo).
- [x] 8.3 Embed `account_members→profiles` (PGRST200): cambiar la query de `/organizacion/roles` y miembros de sucursales al patrón que ya funciona en otra pantalla (D6 — sin FK nueva); RED del hook con el 400 actual; verificación de Equipo mostrando los miembros reales (hoy "0 / 10 usuarios")
  > **Evidencia (2026-08-31)**: RED ejecutado — `frontend/__tests__/hooks/use-team-members.test.ts` con mock que replica el transporte PostgREST (select con `profiles(` → error PGRST200 literal): 5 fallos pre-fix. GREEN: `use-team-members.ts` pasa a dos queries + join en cliente (patrón de `/organizacion/invitar`: `account_members` SIN embed; `profiles` por `.in("id", …)` — RLS decide qué perfiles se ven, perfil invisible → `null` con fallback existente de `resolveMemberName`); si profiles falla, degrada sin romper la lista. `/organizacion/roles` deja su copia inline y consume el hook canónico (reutilización). 6/6 verde; sin FK nueva; consumidores: TeamSection (Equipo), BranchList, roles. ⚠️ La verificación visual de Equipo queda para D10/17.3.

## 9. G9 — Proveedor con deuda (H10, H14, H22) [MEDIUM]

- [x] 9.1 RED (backend): borrar proveedor con `supplier_accounts.balance ≠ 0` debe responder 409 con el saldo en el detalle (hoy: soft delete sin advertencia) — según resolución de OQ-1 (recomendada: bloquear)
  > **Evidencia (2026-08-31)**: OQ-1 aplicada por su recomendación (bloquear). RED ejecutado — `backend/tests/test_supplier_delete_balance_guard.py`: 3 fallos pre-fix (409 con monto, saldo negativo también bloquea, query scopeada); los 2 casos "sigue borrando" pasaban pre-fix (protegen la regresión).
- [x] 9.2 GREEN: guard en `backend/services/suppliers.py:53-61` (consulta el saldo antes del soft delete; 409 RFC 7807; sin ERRCODE nuevo — `P0409` si baja a SQL)
  > **Evidencia**: `SupplierRepository.get_account_balance` (scopeado supplier_id+account_id; `None` = sin cuenta) + guard en `delete_supplier`: saldo ≠ 0 (incl. negativo = a favor) → `ProblemHTTPException(409, code="P0409")` con el monto formato AR en el detail; saldo 0 o sin cuenta siguen borrando; doble borrado sigue 404 (mock del test existente ajustado al transporte nuevo: un fetchrow más por delete). 5 tests nuevos + 43 de las suites de suppliers en verde. Sin ERRCODE nuevo, sin SQL.
- [x] 9.3 Frontend: el diálogo de borrado traduce el 409 con el monto; TRIANGULAR: saldo 0 y sin cuenta siguen borrando; doble borrado sigue 404
  > **Evidencia**: la tubería ya existía (`pythonClient` lanza `Error(detail)` → `getErrorMessage` → toast) — test de contrato agregado en `ProveedoresPage.test.tsx` que fija que el detail del 409 (con `$ 116.550,00`) llega al usuario tal cual, no el fallback genérico. Los TRIANGULAR de saldo 0/sin cuenta/doble borrado viven en el backend (9.2).
- [x] 9.4 H14: encabezado de `/proveedores/{id}/cuenta` con el nombre del proveedor (mismo patrón que la pantalla de cliente); RED del render con el nombre
  > **Evidencia**: RED ejecutado (título genérico → fallo). GREEN: hook nuevo `useSupplier(id)` en `hooks/data/use-suppliers.ts` (espejo de `useClient`, capa canónica; `GET /suppliers/{id}` ya existía) + h1 = nombre con "Cargando…"/fallback "Proveedor", subtítulo "Cuenta corriente — saldo y movimientos". Tests en `ProveedorAccountPage.test.tsx`.
- [x] 9.5 H22: el 404 de cuenta inexistente degrada a estado "sin cuenta aún / $0" sin banner destructivo (mismo trato que ya le da el formulario de compra); RED del estado
  > **Evidencia**: RED ejecutado en hook y página. GREEN: `useSupplierAccount` degrada el 404 "Cuenta corriente no encontrada" a `data: null` SIN error (`__tests__/hooks/use-supplier-account.test.ts`, 3 casos: degrade / cuenta real mapea / error real sigue siendo error); la página muestra aviso neutro "todavía no tiene movimientos… Saldo actual: $ 0" y conserva la rama de error para errores reales.
- [x] 9.6 Auditoría de daño histórico (D7): re-medir en prod proveedores soft-deleteados con `supplier_accounts.balance ≠ 0` (medido 0 el 2026-08-31); si aparece alguno, decidir con el PO (restaurar o saldar) antes de dar por cerrado el grupo
  > **Evidencia (2026-08-31, apply)**: re-medido en prod (SELECT vía MCP): **0 filas** — sin daño histórico que reparar; cerrada por ausencia de datos.
- [ ] 9.7 Verificación visual de listado y cuenta corriente en las 4 combinaciones

## 10. G10 — Textos y avisos (H8, H12, H21, H25, H26) [LOW]

- [ ] 10.1 H8: reescribir la rama `credit` con `context` de compra de `PaymentMethodSupportText` (`PaymentMethodSelect.tsx:183`) — el cargo SÍ se postea desde `compras-proveedor-cuenta-corriente`; corregir también el comentario desactualizado de L158-160; RED: test del texto que declara el cargo (el spec `payment-method` ya lo exige)
- [ ] 10.2 H12: el diálogo de borrado de compra enumera la compensación (reversión del cargo y reposición de stock), copiando el patrón que ya usa `/gastos`; RED del contenido del diálogo (el spec `operation-delete-compensation` ya lo exige)
- [ ] 10.3 H21a: traducir los `detail` crudos a mensajes de usuario en borrado de producto con stock (RN-B4…), conciliación (`amounts_mismatch`, `periodo_invalido`) — reutilizar el patrón existente de `operation-errors.ts`, no crear otro mapa
- [ ] 10.4 H21b: deshabilitar "Conciliar selección" cuando la propia pantalla ya muestra "Las sumas no coinciden" (hoy el `disabled` solo mira la cantidad de ítems)
- [ ] 10.5 H21c: `app/api/billing/preferences/route.ts` propaga el detalle del backend en lugar del 500 genérico; el botón de suscripción muestra estado de carga y no invita al reintento en loop
- [ ] 10.6 H25: pluralización "operación/operaciones" (`sale-operations-list.tsx:292` y el patrón copiado en `purchase-operations-list.tsx:222`) y "1 clientes registrados" del subtítulo de `/clientes` (unificar con el criterio que ya acierta en esa misma pantalla)
- [ ] 10.7 H26: formato del negativo en "Diferencia (previa)" del cierre de caja → "-$ 37.200,00" (mismo formato que el historial de sesiones)

## 11. G11 — Estado de formularios (H9, H13, H15) [LOW]

- [ ] 11.1 H9: `ProfileForm.tsx:45-49` — distinguir "no enviado" de "enviado vacío" en los 5 campos opcionales (mandar `null` explícito o el equivalente de `model_fields_set` del backend); RED: vaciar un campo persiste el vacío tras recargar (hoy: reaparece el valor viejo con toast de éxito)
- [ ] 11.2 H13: el "Limpiar filtro" del popover de fechas de `/gastos` limpia SOLO el rango de fechas (hoy llama al `clearFilters()` global de `useExpenses`); RED: buscador y filtros sobreviven
- [ ] 11.3 H15: `reset()` al cerrar/descartar en `LedgerAdjustmentDialog` y `BankAccountFormDialog` (hoy solo en submit exitoso, `BankAccountFormDialog.tsx:82`), y al cambiar de `kind` (banco→billetera); RED: reabrir tras Escape muestra formulario limpio

## 12. G12 — Gráficos y visualización (H16, H23, H27) [LOW]

- [ ] 12.1 H16: leyenda + un color fijo por serie (sin `Cell` con paleta rotativa que colisiona con el fill de otra serie) en `/reportes/formas-pago`, `centros-costo/page.tsx:128-133` y `sucursal/page.tsx:159-164` — respetar la skill de dataviz del proyecto
- [ ] 12.2 H23: tabla de `/reportes/formas-pago` en móvil — reemplazar `hidden sm:table-cell` (L161-163, L180-182, L190-192) por el `overflow-x-auto` que el contenedor ya tiene; aclarar que la fila "Total del período" es de lo vendido
- [ ] 12.3 H27: KPI "Margen por Canal" del dashboard con `title`/tooltip accesible que revele el valor completo truncado
- [ ] 12.4 Verificación visual de los 3 reportes y el dashboard en las 4 combinaciones

## 13. G13 — Navegación móvil (H17, H18, H19) [MEDIUM por sidebar.tsx]

- [x] 13.1 H17: completar `PAGE_NAMES` de `breadcrumb-nav.tsx:21-42` con las 11 rutas faltantes + fallback legible desde el último segmento (spec `responsive-shell`); RED: `/caja` muestra "Caja", ruta no mapeada no muestra solo "ALIADATA"
  > **Evidencia (2026-08-31)**: RED ejecutado — `__tests__/components/breadcrumb-nav-page-names.test.tsx`, 15 fallos pre-fix (las 11 rutas del informe + comparativo/sucursal + fallback). GREEN: PAGE_NAMES completo (nombres = entrada de menú/h1) + `nameFromLastSegment` ("/x/detalle-final" → "Detalle final"); 18/18 verdes (los 3 del botón de tutorial intactos).
- [x] 13.2 H18: área de toque ≥24 px (objetivo 44) en botón de menú, acciones de fila de Configuración/Sucursales, píldoras y controles del historial; fila entera clickeable en el tablero de conciliación (hoy solo el `<Checkbox>` de 16x16)
  > **Evidencia (2026-08-31)**: (a) fila entera clickeable en `ReconciliationBoard` (extracto Y panel de sistema; checkbox y "Anotar" sin doble-toggle) — RED/GREEN/TRIANGULATE en `__tests__/components/ReconciliationBoardRowTap.test.tsx` (4 casos); (b) botón de menú 28→44 en móvil (`ui/sidebar.tsx` SidebarTrigger, `h-11 w-11 md:h-7 md:w-7` — único consumidor breadcrumb-nav) medido ≥44 por Playwright en el arnés; (c) acciones de fila a 44 en móvil / compactas desde md en `CostCenterManager`, `PaymentMethodManager`, `BranchList` y el tacho de `DeactivateBranchDialog`; (d) píldoras y controles del historial (`LedgerMovementsPanel` + `stock-movements-panel`): píldoras `py-2` (~36 px), buscador/select `h-9`, botones de ícono `h-11 min-w-11` — todo `md:` compacto como hoy. La medición pantalla por pantalla queda en 13.4 (fase visual).
- [x] 13.3 H19: drawer móvil del sidebar (`ui/sidebar.tsx:204-220`) cierra con Escape y muestra la X (quitar el `[&>button]:hidden` de L210 o proveer botón propio); RED sano: el sidebar desktop no cambia
  > **Evidencia (2026-08-31)**: RED ejecutado (X invisible por `[&>button]:hidden`). GREEN: se retiró esa clase y la X del `SheetContent` ganó `p-2 -m-2` (área táctil 16→32 px sin mover su posición). Playwright en el arnés: X visible ≥24, cierra con la X y **cierra con Escape**; el RED sano del desktop lo cubre el control 1440 de `g2-shell-overflow.spec.ts` (mismo arnés). Nota: con la X ya visible, Escape cerró también en el arnés — la confirmación sobre la app real (donde el informe lo midió fallando) queda para 13.4.
- [ ] 13.4 Verificación visual táctil real en 390x844

## 14. G14 — CTA de /planes (H20) [MEDIUM]

- [ ] 14.1 Test del discriminante del CTA en ambos estados: sin suscripción viva → habilitado (comportamiento ESPECIFICADO por `planes-suscribirse-plan-vigente`, no regresionarlo); con suscripción viva del mismo tier → deshabilitado/sin CTA
- [x] 14.2 Verificar que el backend rechaza el alta de suscripción duplicada del mismo tier con suscripción viva; si el guard no existe, agregarlo en el service de payments con 409 + test (OQ-2, D8)
  > **Evidencia (2026-08-31)**: OQ-2 verificada — **el guard YA existe**: `create_subscription_intent` (`backend/services/subscriptions.py:85-87`) corta con 409 "Ya existe una suscripción viva para esta cuenta" ante `find_live_subscription`, y ya tenía test (`test_rejects_when_live_subscription_exists`). Se agregó `test_duplicate_same_tier_blocks_before_persisting_anything` (mismo tier + suscripción viva → 409 con detail y `create_intent` NO awaited: nada queda escrito). Sin código de producción nuevo; el discriminante del CTA de /planes NO se tocó (D8). 27/27 verde.

## 15. G15 — CSV de compras (H24) [LOW]

- [ ] 15.1 Agregar "Forma de pago" y "Proveedor" al CSV client-side de `/compras` (los dos badges con los que el usuario filtra en pantalla; contraste: el de gastos ya lleva forma de pago); RED del contenido del CSV

## 16. G16 — Motivo de los movimientos de gasto (H11) [MEDIUM]

- [ ] 16.1 RED (SQL): crear gasto en efectivo con opt-in y gasto por transferencia — los movimientos de caja y banco deben llevar la descripción del gasto como `description` (hoy: NULL en ambos)
- [ ] 16.2 GREEN: en `20261016000001`, reescribir `rpc_create_expense` desde el baseline vivo (0.1) pasando la descripción en el 5º parámetro de `c28_register_cash_movement` y en `p_description` de `_pay_register_operation_bank_movement`; misma descripción en las reversas del borrado; ACLs re-aplicadas
- [x] 16.3 Backfill idempotente de los movimientos históricos de gastos con motivo vacío (OQ-3, recomendado; acotado por referencia al gasto y `description IS NULL`)
  > **Evidencia (2026-08-31)**: `20261016000001` §3 — dos `UPDATE … FROM public.expenses` acotados por referencia (`cash_movements.reference_id` con `movement_type IN ('expense','expense_reversal')`; `bank_movements.source_doc_ref` con `source_doc_type='expense'`) y `description IS NULL`. En local: 1 fila de caja + 2 de banco backfilleadas (los 2 movimientos de caja restantes referencian gastos ya borrados — `rpc_delete_expense` hace DELETE físico, no hay fuente de la que copiar el motivo; quedan como están por diseño). Re-apply = `UPDATE 0` + fingerprint idéntico. Medido en prod (solo SELECT, 2026-08-31): 4 filas de caja y 0 de banco con motivo NULL esperando el backfill del deploy.
- [ ] 16.4 Verificación en historiales de `/caja` y `/banco`: la fila del gasto nombra el gasto

## 17. Cierre transversal

- [ ] 17.1 Suites completas: vitest frontend, pytest backend (≥87%), gates SQL locales (`db reset` con la migración nueva; ningún `P0001`, ningún ERRCODE nuevo)
- [ ] 17.2 `tsc` sin errores nuevos; barrido de accesibilidad sobre los componentes tocados
- [ ] 17.3 Verificación visual final: re-correr las pantallas afectadas por el método D10 (390x844 táctil + 1440x900, tema claro y oscuro) y archivar las capturas en el scratchpad (no se versionan)
- [ ] 17.4 `openspec validate --changes --strict` en verde
- [ ] 17.5 Actualizar `CHANGES.md` (resultado del apply) y verificar que el candidato absorbido del desborde de `/gastos` quede marcado
