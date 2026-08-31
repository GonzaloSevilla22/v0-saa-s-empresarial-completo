# Design: qa-integral-modulos

## Context

Fuente de verdad: `qa/INFORME.md` (copiado a este change; capturas NO versionadas, en el scratchpad de la sesión de QA). 27 hallazgos confirmados (H1–H27) + 3 defectos de backend registrados por consola/red durante la misma corrida (§4 del informe y evidencia del kit). El QA corrió íntegramente sobre el stack local; producción intacta. El principio rector de este change es **agrupar por causa raíz**: 17 de los 27 síntomas colapsan en dos archivos del design system.

Restricciones del proyecto que gobiernan este diseño:
- **Reutilización antes que repetición**: `ui/popover.tsx` y `ui/sidebar.tsx` son compartidos por toda la app — se extienden, no se duplican ni se arregla pantalla por pantalla.
- **Regla de integridad de función**: toda reescritura de RPC parte del `pg_get_functiondef` VIVO de prod (no del último archivo de migración) — checkpoint previo obligatorio.
- **Sin ERRCODEs nuevos; `P0001` prohibido** (el gate de `20260804000003` lo re-lanza y aborta `db reset`). El guard de G9 usa `P0409`, ya mapeado.
- **Superficie frontend**: no hay pantallas nuevas — todo extiende pantallas existentes (declarado en proposal).

## Matriz de trazabilidad (los 27 hallazgos → grupo → tasks)

| Hallazgo | Sev. | Grupo | Tasks | Governance |
|---|---|---|---|---|
| H1 — desplegables no scrollean dentro de modales | Alto | G1 | 1.x | MEDIUM |
| H2 — 12 pantallas desbordan (main sin `min-w-0`) | Alto | G2 | 2.x | MEDIUM |
| H3 — comparativo con deltas invertidos | Alto | G3 | 3.x | LOW |
| H4 — /reportes/sucursal vacío (2 defectos apilados) | Alto | G4 | 4.x | MEDIUM |
| H5 — campana muestra 6/15 y no scrollea | Alto | G5 | 5.x | LOW |
| H6 — arqueo de cierre se autodestruye en <200 ms | Medio | G6 | 6.x | MEDIUM |
| H7 — ExportButton mudo (Toaster no montado) | Medio | G7 | 7.x | MEDIUM |
| H8 — texto "credit no genera cargo" miente | Medio | G10 | 10.1 | LOW |
| H9 — vaciar campo del perfil no persiste | Medio | G11 | 11.1 | LOW |
| H10 — borrar proveedor con deuda sin advertencia | Medio | G9 | 9.1–9.3 | MEDIUM |
| H11 — movimientos de gasto sin motivo | Medio | G16 | 16.x | MEDIUM |
| H12 — borrar compra no enumera compensación | Medio | G10 | 10.2 | LOW |
| H13 — "Limpiar filtro" de fechas borra todo | Medio | G11 | 11.2 | LOW |
| H14 — cuenta de proveedor sin nombre | Medio | G9 | 9.4 | LOW |
| H15 — diálogos reabren con borrador descartado | Medio | G11 | 11.3 | LOW |
| H16 — gráficos sin leyenda, colores repetidos | Medio | G12 | 12.1 | LOW |
| H17 — breadcrumb "ALIADATA" en 11 rutas | Medio | G13 | 13.1 | LOW |
| H18 — objetivos táctiles < mínimo | Medio | G13 | 13.2 | LOW |
| H19 — drawer móvil sin Escape ni X | Medio | G13 | 13.3 | MEDIUM (toca `ui/sidebar.tsx`) |
| H20 — CTA del plan vigente habilitado | Bajo | G14 | 14.x | MEDIUM |
| H21 — errores crudos del servidor en pantalla | Bajo | G10 | 10.3–10.5 | LOW |
| H22 — cuenta de proveedor sin movimientos = banner rojo | Bajo | G9 | 9.5 | LOW |
| H23 — formas-pago oculta 3 columnas en móvil | Bajo | G12 | 12.2 | LOW |
| H24 — CSV de compras sin forma de pago ni proveedor | Bajo | G15 | 15.1 | LOW |
| H25 — "21 operaciónes", "1 clientes" | Bajo | G10 | 10.6 | LOW |
| H26 — "$-37.200,00" | Bajo | G10 | 10.7 | LOW |
| H27 — KPI truncado sin tooltip | Bajo | G12 | 12.3 | LOW |
| (consola) GET /sales-orders 500 | — | G8 | 8.1 | MEDIUM |
| (consola) rpc_product_profitability 42804 | — | G8 | 8.2 | MEDIUM |
| (consola) PGRST200 embed account_members→profiles | — | G8 | 8.3 | MEDIUM |

Ninguno de los 27 queda sin destino; no hay hallazgos fuera de alcance. Los tres ítems "(consola)" no llevan número H: salieron de la escucha de consola/red de la misma corrida y del briefing del QA, y se cierran acá porque comparten pantalla y causa con lo auditado.

## Goals / Non-Goals

**Goals:** cerrar los 27 hallazgos + los 3 defectos de backend por causa raíz; que los componentes compartidos arreglados NO regresionen sus usos sanos (popover fuera de modales, sidebar en desktop); dejar cobertura de regresión donde hoy no existe ninguna (comparativo, branch report, scroll de popover en modal).

**Non-Goals:**
- Rediseño responsive de tablas/pantallas más allá de eliminar el desborde y hacer alcanzable lo oculto (la pasada dedicada a tablet 768–1024 que recomienda el informe queda para otro change).
- El backlog de "qué quedó sin probar" del informe (§4): AFIP E2E, Edge Functions de IA, roles no-owner, concurrencia — no son hallazgos, son cobertura futura.
- El selector de pago a proveedor con 4 métodos fijos (anotado al pasar en §4 del informe, sin reportar por no probado) — candidato aparte.
- Asiento contable de gastos (D10 de `gastos-forma-pago`, diferido a V2.6).

## Decisions

### D1 — G1: portal del popover al contenedor del diálogo vía contexto (no `modal` en el root, no des-portalizar a secas)

Tres mecanismos candidatos (informe §H1 "Qué habría que tocar"):

1. **`modal` (true) en el `<Popover>` raíz** — una línea, pero convierte el popover en modal (monta su propio `RemoveScroll`, cambia foco y outside-click) y `ui/popover.tsx` es global: cambiaría el comportamiento de TODOS los popovers de la app, incluidos los sanos fuera de modales. Descartado por radio de explosión.
2. **No portalizar cuando vive dentro de un modal** — es el equivalente permanente de la contraprueba causal del QA (reparentado ⇒ 0/11 gestos cancelados), pero renderizar en el lugar del árbol expone al `overflow-hidden` del contenido del diálogo (recorte en escritorio, advertido por el propio informe).
3. **Registrar el popper como shard del `RemoveScroll` del Dialog** — el más correcto conceptualmente, pero exige parchear el Dialog de Radix o su contexto interno no público. Demasiado invasivo.

**Elegido: variante de (2) que conserva el portal — `PopoverPrimitive.Portal` con `container`.** `DialogContent` (`ui/dialog.tsx`) y `SheetContent` (`ui/sheet.tsx`) publican su nodo de contenido en un contexto React propio (`DialogContainerContext`); `ui/popover.tsx` lo consume y, si existe, pasa ese nodo como `container` del Portal. Resultado: dentro de un modal el popover cuelga del subárbol del contenido → queda dentro del shard de `react-remove-scroll` → el gesto no se cancela (exactamente lo que probó la contraprueba). Fuera de modales el contexto es `null` y el Portal sigue yendo a `document.body`: **cero cambio de comportamiento para los popovers sanos**. Al seguir portalizado (aunque a otro container), el popper conserva su posicionamiento `fixed` de Radix, que no es recortado por `overflow-hidden` del ancestro en la práctica — igual se verifica el recorte en escritorio como parte de la verificación visual (riesgo R1).

Además, y aparte: se elimina el `modal={false}` mal ubicado de `product-picker.tsx:199` y `searchable-select.tsx:135` (hoy se filtra como atributo DOM espurio y React lo advierte; y aunque estuviera bien ubicado es el default de Radix — no arregla nada, informe §H1 (a)/(b)).

**RED del grupo**: (i) test que reproduce el bug — selector abierto dentro de un Dialog, `wheel`/`touch` despachado, `scrollTop > 0` esperado (hoy falla); (ii) test del comportamiento EXISTENTE sano — popover fuera de modal sigue portalizado a `document.body`, cierra por click-afuera y Escape (hoy pasa, protege contra la regresión).

### D2 — G2: `min-w-0` en el shell + contribuyentes por pantalla, en ese orden

Arreglo de raíz primero (verificado en vivo por el QA: `scrollWidth` 670→390 en `/compras`, 453→390 en `/productos`, 762→390 en `/caja` con solo ese atributo): `min-w-0` en el `<main>` de `SidebarInset` (`ui/sidebar.tsx:334` — el resto del archivo ya lo usa en L433/504/702/734, al inset se le pasó) y en el contenedor de `app/(dashboard)/layout.tsx:28`. Después, los contribuyentes que siguen empujando ancho localmente: `flex-wrap` en las 4 barras de acciones (`product-catalog.tsx:358`, `stock/page.tsx:160`, `compras/page.tsx:51-58`, `BranchList.tsx:105` quitando el `shrink-0`), colapso responsive de la etiqueta del `ExportButton` (patrón `hidden sm:inline` que ya usan sus hermanos), span de compras alineado al patrón de ventas ("primer producto · +N más", `purchase-operations-list.tsx:335-336` vs `sale-operations-list.tsx:404-408`), `flex-wrap` en la fila de acciones del detalle expandido de ventas (`sale-operations-list.tsx:496`), y scroll horizontal propio (`overflow-x-auto`) para `LedgerMovementsPanel` y `stock-movements-panel` (columnas en px fijos). `globals.css:184` (`overflow-x-hidden` del body) NO se toca: con el shell contenido deja de tener efecto dañino y quitarlo re-abriría el paneo lateral en cualquier regresión futura.

**Absorbe el candidato de `CHANGES.md`** "desborde horizontal de `/gastos` por debajo de ~1372px": la causa es la misma cadena `min-width:auto` (el QA midió `/gastos` desbordando en tablet 768–1024 igual que `/compras`).

**RED del grupo**: (i) test de layout que monta el shell y afirma `min-w-0` presente / `scrollWidth <= innerWidth` en un viewport de 390 con contenido ancho (hoy falla); (ii) test del comportamiento EXISTENTE en desktop — el sidebar colapsable y el inset no cambian de dimensiones a 1440 (protege el layout sano).

### D3 — G3: invertir los defaults en el frontend, NO tocar la RPC

La RPC calcula `(B−A)/A` con A como base (migración `20260606120000_period_comparison.sql:104-111`) y la Edge Function `ai-comparativo` rotula "vs período A" con la misma convención. Invertir la fórmula en la RPC obligaría a tocar también la Edge Function y cualquier consumidor futuro; invertir los defaults de `page.tsx:152-155` (A = mes anterior = base, B = mes en curso) arregla signo y color de las 4 tarjetas de una vez y deja a la IA consumiendo la cronología correcta sin tocarla. Se rotula el badge (qué mide: "evolución de A a B") porque hoy nada lo dice. Cobertura: hoy NO existe ningún test (frontend, backend ni pgTAP) sobre `rpc_period_comparison` ni la página — el RED fija el contrato con datos sintéticos (gastos suben ⇒ badge rojo y signo +).

### D4 — G4: dos fixes apilados + rama de error, porque el primero venía tapando al segundo

1. Tenant por `account_members` (canon de `auth-context.tsx:94-97`), no `user_metadata.account_id` (nada lo escribe — la pantalla nunca funcionó para nadie desde C-06).
2. `rpc_branch_report`: calificar `branch_id` en el CTE `all_branch_ids` (42702 contra el parámetro OUT homónimo; definición viva arrastrada desde `20260607000000_sucursales_module.sql:304` hasta `20260814000001_v3_reporting_invariants.sql:408`). Reescritura en migración `20261016000001` partiendo del `pg_get_functiondef` vivo (checkpoint previo). Alcance acotado: un único consumidor; el espejo `rpc_cost_center_report` NO tiene el bug (verificado por el QA).
3. Rama de error visible en la página: sin ella, el fix (1) solo habría convertido "vacío silencioso" en "400 silencioso".

### D5 — G7: unificar hacia `sonner`, no montar el segundo Toaster

El único `<Toaster />` montado es el de `sonner` (`app/layout.tsx`); el resto de la app ya emite por `sonner`. Montar el `<Toaster />` de shadcn haría convivir dos sistemas de toast (deuda declarada). `ExportButton` migra sus 5 ramas a `sonner` y `hooks/use-toast` queda con un consumidor menos (si queda huérfano, se anota como candidato de limpieza, no se borra acá).

### D6 — G8: tres fixes puntuales de contrato

- `GET /sales-orders`: `SELECT *` del repositorio (L140) no trae `payment_method` que `SalesOrderOut` (schemas/sales_orders.py:101) exige. Fix mínimo: el repositorio proyecta/deriva la columna que el schema declara (o el schema la vuelve `Optional` si la columna no existe en la tabla — decidir en apply mirando el DDL vivo; el criterio es que el contrato Pydantic y la proyección SQL queden consistentes y el listado devuelva 200 con datos sembrados).
- `rpc_product_profitability`: 42804 (`last_sale_date date` en el `RETURNS TABLE` vs `MAX(s.date)` timestamptz). Elegido: **cast en el SELECT** (`MAX(s.date)::date`) — conserva la firma y el tipo que los consumidores ya esperan; cambiar el tipo de la firma rompería al frontend que formatea fecha. Misma migración `20261016000001`, baseline vivo.
- `PGRST200` del embed `account_members→profiles` (roles / miembros de sucursal / Equipo "0/10 usuarios"): elegido **cambiar la query del frontend al patrón que ya funciona** en otra pantalla (dos queries + join en cliente, o el endpoint del backend que ya expone miembros), NO crear una FK real hacia `profiles` — una FK nueva a una tabla de otro dominio para alimentar un embed de PostgREST es un cambio de modelo de datos desproporcionado para un fix de lectura.

### D7 — G9: bloqueo con `P0409` (recomendado) — queda como OQ-1

Dos opciones para la baja de proveedor con saldo abierto:
- **(a) Bloquear con 409 (`P0409`)** mientras `supplier_accounts.balance ≠ 0`: consistente con el patrón de inmutabilidad ya establecido (compra con cargo posteado es inmutable, `P0423`); la deuda nunca se vuelve invisible; el usuario primero salda o ajusta, después borra. El diálogo muestra el saldo y el porqué.
- **(b) Advertir con el saldo** en el diálogo y permitir el borrado: menos fricción, pero deja viva la trampa de fondo — la cuenta corriente solo se alcanza desde la fila del proveedor, así que la deuda queda inalcanzable desde la UI (los $116.550 del QA).

**Recomendación: (a)**, porque (b) exigiría además construir una vista de "cuentas de proveedores borrados" para que la deuda siga siendo operable, que es más superficie que el guard. Implementación: guard en `backend/services/suppliers.py` (capa service, consulta el saldo antes del soft delete) → 409 RFC 7807 con el saldo en el `detail`; el frontend lo traduce. Sin ERRCODE nuevo. Si el PO elige (b), el guard se degrada a advertencia con el mismo dato ya consultado.

### D8 — G14: no contradecir a `planes-suscribirse-plan-vigente`

El CTA habilitado del tier vigente **es el comportamiento especificado** cuando la cuenta no tiene suscripción viva (`billing-ui`, change 2026-08-29 — era exactamente el caso de Daniel). El QA local corrió sin suscripción viva, así que H20 en sí no es un bug de spec sino un riesgo residual: el caso "suscripción viva del mismo tier" debe deshabilitar el CTA (eso el spec ya lo implica con su discriminante) y el backend debe rechazar el alta duplicada. Tasks: test frontend del discriminante en ambos estados + test backend del guard de alta duplicada (hoy no verificado, informe §H20). Si el guard backend no existe, se agrega en el service de payments con 409. OQ-2 para el PO solo si aparece tensión real al implementar.

### D9 — G16: motivo del gasto + backfill barato

`rpc_create_expense` ya llama a `c28_register_cash_movement` (sin el 5º parámetro `p_description`) y a `_pay_register_operation_bank_movement` (con `NULL` literal en `p_description`). Fix: pasar `p_descripcion` del gasto en ambas llamadas (dos argumentos), reescritura desde el baseline vivo en `20261016000001`. **Backfill recomendado (OQ-3)**: los movimientos afectados existen solo desde el 2026-08-30 (el change `gastos-forma-pago` es de ese día) — un `UPDATE … SET description = e.descripcion FROM expenses e WHERE … AND description IS NULL` idempotente y acotado por `reference_type` cierra el histórico por centavos. Si el PO lo rechaza, se omite el bloque del backfill sin tocar el resto.

### D10 — Verificación visual con el método del kit de QA

Toda pantalla tocada se re-verifica en móvil 390x844 **con emulación táctil real** (`hasTouch` + `isMobile`, gestos por CDP `Input.dispatchTouchEvent` — clics simulados no reproducen H1) y escritorio 1440x900, tema claro y oscuro, con el método documentado en `qa/INFORME.md` §4 ("Cobertura y qué quedó sin probar") y en la memoria del proyecto (`project_frontend_verification_gotchas.md`); el kit de scripts original se eliminó del scratchpad al cerrar el QA (§5), así que el apply lo reconstruye desde esa documentación (Playwright + cookies de sesión inyectadas + los seeds que quedaron en la DB local).

### D11 — Una sola migración, tres funciones, regla de integridad

`20261016000001_qa_integral_fixes.sql` reescribe `rpc_branch_report`, `rpc_product_profitability` y `rpc_create_expense`. Checkpoint obligatorio ANTES de escribir SQL: hashear el `pg_get_functiondef` vivo de prod de las tres (lección de `compras-proveedor-cuenta-corriente`: el archivo de migración puede haber divergido del cuerpo vivo por reescrituras in-place). `DROP+CREATE` resetea ACLs → re-aplicar los `GRANT`/`REVOKE` vigentes en el mismo archivo (lección advisor 0028). Sin `RAISE` nuevos con ERRCODEs no mapeados; nada de `P0001`.

## Risks / Trade-offs

- **[R1] El portal con `container` dentro del DialogContent podría recortarse por `overflow-hidden` en escritorio** → el popper de Radix posiciona `fixed`; igual se verifica visualmente en las 4 combinaciones y, si recorta, se cae al plan C del informe (shard) solo para ese caso, documentándolo.
- **[R2] `min-w-0` en el shell podría encoger contenido que dependía del estiramiento** (tablas que hoy "se ven bien" en desktop gracias al desborde) → el RED de G2 incluye el control desktop 1440; la verificación visual de D10 recorre las 12 pantallas listadas en H2.
- **[R3] Tres reescrituras de RPC en una migración**: si una diverge del cuerpo vivo, el checkpoint la frena antes de escribir SQL (D11) — no se avanza con baseline de archivo.
- **[R4] El guard de G9 puede frustrar una baja legítima con deuda que el PO quiera condonar** → el flujo existente de ajuste/pago en la cuenta corriente permite saldarla primero; queda dicho en OQ-1.
- **[R5] Migrar ExportButton a sonner cambia la apariencia de esos toasts** → es la apariencia canónica del resto de la app; deliberado.
- **[R6] `flex-wrap` en barras de acciones cambia el orden visual percibido en anchos intermedios** → verificación visual en 390/768/1440.

## Migration Plan

1. Migración `20261016000001` (D11) — se aplica con el merge por el pipeline normal (`supabase db push` en deploy).
2. Frontend y backend en el mismo PR; sin flags — todos los fixes son correcciones de comportamiento ya especificado o contratos nuevos de `responsive-shell`.
3. Rollback: revert del PR; la migración es re-runnable (CREATE OR REPLACE + backfill idempotente) y no destruye datos.

## Open Questions

- **OQ-1 (no bloqueante)** — Baja de proveedor con saldo abierto: ¿bloquear con `P0409` (recomendado, D7) o advertir con el saldo y permitir? Si el PO no responde, se aplica la recomendación (precedente del proyecto).
- **OQ-2 (no bloqueante)** — /planes: ¿confirmar que el backend rechaza el alta de suscripción duplicada del mismo tier con suscripción viva? Recomendación: test + guard 409 si falta (D8), sin tocar el discriminante del CTA especificado por `planes-suscribirse-plan-vigente`.
- **OQ-3 (no bloqueante)** — ¿Backfillear el motivo de los movimientos de caja/banco de gastos ya creados desde el 30-08? Recomendación: sí, bloque idempotente en la misma migración (D9).
