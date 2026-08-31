# Tasks: qa-integral-modulos

> TDD estricto por grupo: RED primero (el test que reproduce el hallazgo Y, para los componentes compartidos, el test del comportamiento existente sano), GREEN mínimo, triangulación, refactor. Governance por grupo en la matriz de `design.md`. Los grupos son independientes salvo donde se indica; G2 conviene antes que la verificación visual del resto.

## 0. Preparación y checkpoint de integridad

- [ ] 0.1 Checkpoint de integridad de función (regla del proyecto, ANTES de escribir SQL): capturar `pg_get_functiondef` VIVO de prod de `rpc_branch_report`, `rpc_product_profitability` y `rpc_create_expense`; hashear y comparar contra el último archivo de migración de cada una; si divergen, el baseline es el cuerpo vivo
- [ ] 0.2 Levantar el stack local (Supabase Docker + Next dev + FastAPI) y reconstruir el método de verificación visual desde `qa/INFORME.md` §4 (Playwright, cookies inyectadas, táctil real por CDP; el kit original fue eliminado del scratchpad — ver D10)

## 1. G1 — Popover dentro de modal (H1, bug del PO) [MEDIUM]

- [ ] 1.1 RED: test que monta un selector (searchable-select/product-picker) dentro de un Dialog, despacha `wheel` sobre la lista abierta y espera `scrollTop > 0` (hoy falla: el gesto se cancela)
- [ ] 1.2 RED sano: test del comportamiento EXISTENTE fuera de modal — popover portalizado a `document.body`, cierra por click afuera y por Escape (protege contra la regresión del fix)
- [ ] 1.3 GREEN: `DialogContent` (`ui/dialog.tsx`) y `SheetContent` (`ui/sheet.tsx`) publican su nodo de contenido en `DialogContainerContext`; `ui/popover.tsx` pasa ese nodo como `container` del `PopoverPrimitive.Portal` cuando existe (D1)
- [ ] 1.4 Eliminar el `modal={false}` mal ubicado de `frontend/components/shared/product-picker.tsx:199` y `frontend/components/ui/searchable-select.tsx:135` (atributo DOM espurio; advertencia de React)
- [ ] 1.5 TRIANGULAR: mismo contrato con gesto táctil, y en los tres modales del informe (venta/editar venta, nueva compra, ajustar stock — este último usa otro contenedor)
- [ ] 1.6 Verificación visual (método D10): selector de producto y de cliente scrollean con el dedo en 390x844 dentro de los tres modales; sin recorte del desplegable en escritorio 1440 (R1); POS intacto como control positivo

## 2. G2 — Shell sin min-w-0 (H2, 12 pantallas) [MEDIUM]

- [ ] 2.1 RED: test de layout — shell montado con contenido más ancho que el viewport en 390 px, `scrollWidth` del documento no supera el viewport (hoy falla)
- [ ] 2.2 RED sano: test del sidebar/inset en desktop 1440 — dimensiones y colapso sin cambios
- [ ] 2.3 GREEN: `min-w-0` en el `<main>` de `SidebarInset` (`ui/sidebar.tsx:334`) y en el contenedor de `app/(dashboard)/layout.tsx:28`
- [ ] 2.4 Contribuyentes por pantalla: `flex-wrap` en las barras de acciones de `product-catalog.tsx:358`, `stock/page.tsx:160`, `compras/page.tsx:51-58` y `BranchList.tsx:105` (quitando `shrink-0`); `flex-wrap` en la fila de acciones del detalle expandido de `sale-operations-list.tsx:496`
- [ ] 2.5 Colapso responsive de la etiqueta del `ExportButton` (`ExportButton.tsx:113-135`, patrón `hidden sm:inline` de sus hermanos)
- [ ] 2.6 Alinear el span de productos de `purchase-operations-list.tsx:335-336` al patrón de ventas ("primer producto · +N más", `sale-operations-list.tsx:404-408`)
- [ ] 2.7 Scroll horizontal propio (`overflow-x-auto`) o apilado bajo `sm` en `LedgerMovementsPanel.tsx:77-111` y `stock-movements-panel.tsx:111-160` (columnas en px fijos + hijo `display:table` del ScrollArea)
- [ ] 2.8 Verificación visual de las 12 pantallas de la tabla de H2 en 390x844 (CTAs y acciones de fila dentro del viewport, tacho de `/productos` alcanzable) + `/gastos`, `/ventas`, `/compras`, `/productos`, `/clientes` en 768 y 1024 (tablet, absorbe el candidato de `CHANGES.md`) + control desktop 1440

## 3. G3 — Comparativo invertido (H3) [LOW]

- [ ] 3.1 RED: test de la página con datos sintéticos donde los gastos del mes en curso superan a los del anterior — el badge de gastos debe mostrar signo positivo en rojo (hoy: negativo en verde). Hoy no existe NINGÚN test de `rpc_period_comparison` ni de la página
- [ ] 3.2 GREEN: invertir los defaults de `reportes/comparativo/page.tsx:152-155` (A = mes anterior = base, B = mes en curso, contrato `(B−A)/A` de la RPC — NO tocar la RPC ni `ai-comparativo`)
- [ ] 3.3 Rotular el badge de delta (qué mide: evolución de A a B) en `DeltaBadge`
- [ ] 3.4 TRIANGULAR: las 4 tarjetas con series que suben y que bajan; casos `invertColors` (gastos/compras) donde la doble inversión no se cancela; delta NULL → "N/A"
- [ ] 3.5 Verificación visual en las 4 combinaciones (390/1440 × claro/oscuro)

## 4. G4 — Reporte por sucursal muerto (H4) [MEDIUM]

- [ ] 4.1 RED (pgTAP/SQL): `rpc_branch_report` sobre fixture con 2 sucursales y ventas/gastos en rango debe devolver filas — hoy falla con `42702 branch_id is ambiguous`
- [ ] 4.2 GREEN: migración `20261016000001` — reescribir `rpc_branch_report` desde el baseline vivo (0.1) calificando `branch_id` en el CTE `all_branch_ids`; re-aplicar ACLs vigentes en el mismo archivo; sin ERRCODEs nuevos
- [ ] 4.3 RED (frontend): la página con sesión válida debe pedir el reporte con la cuenta resuelta por `account_members`; y ante un error del RPC debe mostrar la rama de error (hoy: silencio en ambos)
- [ ] 4.4 GREEN: `reportes/sucursal/page.tsx:80-82` — tenant por el canon de `auth-context` (`account_members`), eliminar la lectura de `user_metadata.account_id`; agregar rama de error visible distinguible de "sin datos"
- [ ] 4.5 TRIANGULAR: rango sin datos → "sin datos" (no error); RPC caído → error visible; verificación de que `rpc_cost_center_report` (espejo sano) no se toca
- [ ] 4.6 Verificación visual con el seed local (2 sucursales con ventas y gastos) en las 4 combinaciones

## 5. G5 — Campana sin scroll (H5) [LOW]

- [ ] 5.1 RED: test del panel con 15 notificaciones — el último ítem es alcanzable por scroll (hoy: recortado a 6, `overflow-y: hidden`)
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

- [ ] 8.1 `GET /sales-orders`: RED con fixture de órdenes sembradas (hoy 500: `SalesOrderOut.payment_method` requerido vs `SELECT` sin la columna, `schemas/sales_orders.py:101` + repositorio L140); GREEN alineando proyección SQL y contrato Pydantic mirando el DDL vivo (D6); TRIANGULAR con orden sin forma de pago
- [ ] 8.2 `rpc_product_profitability`: RED SQL que hoy reproduce el `42804` (`last_sale_date date` vs `MAX(s.date)` timestamptz); GREEN en `20261016000001` con cast `::date` en el SELECT (conserva la firma, D6), baseline vivo + ACLs re-aplicadas; verificación de `/rentabilidad` cargando datos
- [ ] 8.3 Embed `account_members→profiles` (PGRST200): cambiar la query de `/organizacion/roles` y miembros de sucursales al patrón que ya funciona en otra pantalla (D6 — sin FK nueva); RED del hook con el 400 actual; verificación de Equipo mostrando los miembros reales (hoy "0 / 10 usuarios")

## 9. G9 — Proveedor con deuda (H10, H14, H22) [MEDIUM]

- [ ] 9.1 RED (backend): borrar proveedor con `supplier_accounts.balance ≠ 0` debe responder 409 con el saldo en el detalle (hoy: soft delete sin advertencia) — según resolución de OQ-1 (recomendada: bloquear)
- [ ] 9.2 GREEN: guard en `backend/services/suppliers.py:53-61` (consulta el saldo antes del soft delete; 409 RFC 7807; sin ERRCODE nuevo — `P0409` si baja a SQL)
- [ ] 9.3 Frontend: el diálogo de borrado traduce el 409 con el monto; TRIANGULAR: saldo 0 y sin cuenta siguen borrando; doble borrado sigue 404
- [ ] 9.4 H14: encabezado de `/proveedores/{id}/cuenta` con el nombre del proveedor (mismo patrón que la pantalla de cliente); RED del render con el nombre
- [ ] 9.5 H22: el 404 de cuenta inexistente degrada a estado "sin cuenta aún / $0" sin banner destructivo (mismo trato que ya le da el formulario de compra); RED del estado
- [ ] 9.6 Verificación visual de listado y cuenta corriente en las 4 combinaciones

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

- [ ] 13.1 H17: completar `PAGE_NAMES` de `breadcrumb-nav.tsx:21-42` con las 11 rutas faltantes + fallback legible desde el último segmento (spec `responsive-shell`); RED: `/caja` muestra "Caja", ruta no mapeada no muestra solo "ALIADATA"
- [ ] 13.2 H18: área de toque ≥24 px (objetivo 44) en botón de menú, acciones de fila de Configuración/Sucursales, píldoras y controles del historial; fila entera clickeable en el tablero de conciliación (hoy solo el `<Checkbox>` de 16x16)
- [ ] 13.3 H19: drawer móvil del sidebar (`ui/sidebar.tsx:204-220`) cierra con Escape y muestra la X (quitar el `[&>button]:hidden` de L210 o proveer botón propio); RED sano: el sidebar desktop no cambia
- [ ] 13.4 Verificación visual táctil real en 390x844

## 14. G14 — CTA de /planes (H20) [MEDIUM]

- [ ] 14.1 Test del discriminante del CTA en ambos estados: sin suscripción viva → habilitado (comportamiento ESPECIFICADO por `planes-suscribirse-plan-vigente`, no regresionarlo); con suscripción viva del mismo tier → deshabilitado/sin CTA
- [ ] 14.2 Verificar que el backend rechaza el alta de suscripción duplicada del mismo tier con suscripción viva; si el guard no existe, agregarlo en el service de payments con 409 + test (OQ-2, D8)

## 15. G15 — CSV de compras (H24) [LOW]

- [ ] 15.1 Agregar "Forma de pago" y "Proveedor" al CSV client-side de `/compras` (los dos badges con los que el usuario filtra en pantalla; contraste: el de gastos ya lleva forma de pago); RED del contenido del CSV

## 16. G16 — Motivo de los movimientos de gasto (H11) [MEDIUM]

- [ ] 16.1 RED (SQL): crear gasto en efectivo con opt-in y gasto por transferencia — los movimientos de caja y banco deben llevar la descripción del gasto como `description` (hoy: NULL en ambos)
- [ ] 16.2 GREEN: en `20261016000001`, reescribir `rpc_create_expense` desde el baseline vivo (0.1) pasando la descripción en el 5º parámetro de `c28_register_cash_movement` y en `p_description` de `_pay_register_operation_bank_movement`; misma descripción en las reversas del borrado; ACLs re-aplicadas
- [ ] 16.3 Backfill idempotente de los movimientos históricos de gastos con motivo vacío (OQ-3, recomendado; acotado por referencia al gasto y `description IS NULL`)
- [ ] 16.4 Verificación en historiales de `/caja` y `/banco`: la fila del gasto nombra el gasto

## 17. Cierre transversal

- [ ] 17.1 Suites completas: vitest frontend, pytest backend (≥87%), gates SQL locales (`db reset` con la migración nueva; ningún `P0001`, ningún ERRCODE nuevo)
- [ ] 17.2 `tsc` sin errores nuevos; barrido de accesibilidad sobre los componentes tocados
- [ ] 17.3 Verificación visual final: re-correr las pantallas afectadas por el método D10 (390x844 táctil + 1440x900, tema claro y oscuro) y archivar las capturas en el scratchpad (no se versionan)
- [ ] 17.4 `openspec validate --changes --strict` en verde
- [ ] 17.5 Actualizar `CHANGES.md` (resultado del apply) y verificar que el candidato absorbido del desborde de `/gastos` quede marcado
