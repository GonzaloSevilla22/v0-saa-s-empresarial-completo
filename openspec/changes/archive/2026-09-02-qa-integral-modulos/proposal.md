# Proposal: qa-integral-modulos

## Why

El QA integral del 2026-08-30 (5 frentes en paralelo, escritorio 1440x900 + móvil 390x844 con táctil real, tema claro y oscuro, cada hallazgo grave verificado adversarialmente) cerró con **27 hallazgos confirmados** (5 altos, 14 medios, 8 bajos; 1 candidato adicional quedó refutado y descartado): el informe completo vive en `qa/INFORME.md` dentro de este change y es la fuente de verdad. La buena noticia está en la concentración: **dos defectos de componentes compartidos del design system explican 17 de los 27 síntomas** — el popover portalizado fuera del shard de scroll del modal (`ui/popover.tsx`) y el `<main>` sin `min-w-0` (`ui/sidebar.tsx`). Este change agrupa los 27 hallazgos por **causa raíz** (no por síntoma) y los cierra todos, incluido el bug que reportó el PO (H1: ningún desplegable scrollea dentro de un modal — 23 de 32 productos inalcanzables al cargar una venta).

## What Changes

Dieciséis grupos de causa raíz (matriz completa hallazgo→grupo→task en `design.md`):

- **G1 — Popover dentro de modal (H1, bug del PO)**: el `PopoverContent` deja de quedar fuera del shard de `react-remove-scroll` del Dialog/Sheet; el mecanismo elegido (portal con `container` dentro del contenido del diálogo vía contexto) se decide en design. `ui/popover.tsx` es compartido por toda la app: el fix NO altera los popovers fuera de modales.
- **G2 — Shell sin `min-w-0` (H2, 12 pantallas)**: `min-w-0` en el `<main>` de `SidebarInset` y en el contenedor del layout del dashboard + los contribuyentes por pantalla (barras de acciones sin `flex-wrap`, etiqueta del `ExportButton` sin colapso, span de compras sin truncado efectivo, panel de movimientos con columnas fijas). **Absorbe el candidato ya anotado en `CHANGES.md`**: "desborde horizontal de `/gastos` por debajo de ~1372px".
- **G3 — Comparativo invertido (H3)**: los defaults de período de `/reportes/comparativo` pasan a respetar el contrato de la RPC (A = base = mes anterior); el badge se rotula. Solo frontend; la RPC no se toca.
- **G4 — Reporte por sucursal muerto (H4)**: tenant por el canon `account_members` (no `user_metadata.account_id`, que nada escribe), fix del `42702 branch_id is ambiguous` en `rpc_branch_report` (migración bajo regla de integridad de función), y rama de error visible en la página.
- **G5 — Campana sin scroll (H5)**: el `max-h` pasa del root del `ScrollArea` al viewport interno.
- **G6 — Arqueo autodestruido (H6)**: `CloseSessionDialog` sale de la rama condicional de sesión; el panel de arqueo persiste hasta que el usuario lo cierre.
- **G7 — Toasts fantasma (H7)**: `ExportButton` migra a `sonner` (el único sistema de toast montado de la app); no se agrega un segundo `<Toaster />`.
- **G8 — Backend roto en silencio**: `GET /sales-orders` 500 (`SalesOrderOut.payment_method` requerido vs `SELECT` sin la columna), `rpc_product_profitability` 42804 (`last_sale_date date` vs `MAX(s.date)` timestamptz — migración bajo regla de integridad), y el 400 `PGRST200` del embed `account_members→profiles` (módulo Equipo / roles / miembros de sucursal).
- **G9 — Proveedor con deuda (H10, H14, H22)**: guard de baja de proveedor con saldo abierto (OQ-1: bloquear vs advertir; recomendación en design), nombre del proveedor en su pantalla de cuenta corriente, y 404 de cuenta inexistente tratado como estado vacío, no como error.
- **G10 — Textos y avisos que mienten o exponen (H8, H12, H21, H25, H26)**: texto de ayuda de compra a crédito desactualizado (el spec ya exige lo contrario), diálogo de borrado de compra sin enumerar compensación (idem), errores crudos del servidor traducidos, pluralizaciones, formato del signo negativo.
- **G11 — Estado de formularios (H9, H13, H15)**: vaciar campos del perfil que no persiste, "Limpiar filtro" de fechas que borra todo, borradores descartados que reaparecen.
- **G12 — Gráficos y visualización (H16, H23, H27)**: leyenda + colores fijos por serie en los 3 reportes, columnas móviles por scroll en vez de `display:none`, tooltip en el KPI truncado.
- **G13 — Navegación móvil (H17, H18, H19)**: breadcrumb con nombre en las 11 rutas faltantes, objetivos táctiles al piso WCAG, drawer del sidebar cerrable por Escape y con X.
- **G14 — CTA de /planes (H20)**: verificación contra el spec vigente de `billing-ui` (que deliberadamente habilita contratar el tier vigente sin suscripción viva — `planes-suscribirse-plan-vigente`); se deshabilita solo con suscripción viva del mismo tier y se cubre el guard backend de alta duplicada (OQ-2).
- **G15 — CSV de compras incompleto (H24)**: columnas forma de pago y proveedor.
- **G16 — Movimientos de gasto sin motivo (H11)**: `rpc_create_expense` pasa la descripción del gasto a las dos llamadas de libros (migración bajo regla de integridad; backfill barato de los movimientos existentes, OQ-3).

**Sin superficie frontend nueva**: no hay pantallas ni rutas nuevas — todo extiende pantallas existentes. **Sin ERRCODEs nuevos** (`P0001` prohibido; el guard de G9, si bloquea, usa `P0409` ya mapeado). **Sin breaking changes.**

## Capabilities

### New Capabilities
- `responsive-shell`: contrato de layout y gestos del shell del dashboard — el contenido nunca desborda horizontalmente el viewport, los desplegables dentro de un modal scrollean, los paneles de overlay con listas largas scrollean, objetivos táctiles mínimos en móvil, el drawer móvil cierra por las vías estándar y el breadcrumb nombra la pantalla actual. Cubre H1, H2, H5, H17, H18, H19.

### Modified Capabilities
- `comparative-reports`: los defaults de período de la página pasan a respetar el contrato `(B−A)/A` de la RPC (A = período anterior como base) y el badge de delta queda rotulado (H3).
- `reporting-invariants`: el reporte por sucursal ejecuta de verdad (columna calificada en `rpc_branch_report`), resuelve el tenant por el canon `account_members` y la página tiene rama de error visible (H4).
- `cash-session`: el resultado del arqueo de cierre persiste en pantalla hasta que el usuario lo cierre (H6).
- `data-export`: la superficie de exportación informa el resultado (éxito, cuota, error) por el sistema de toast canónico de la app (H7).
- `supplier-directory`: la baja de un proveedor con saldo abierto queda guardada (H10) y la pantalla de cuenta corriente identifica al proveedor y trata la cuenta inexistente como estado vacío (H14, H22).
- `expense-operation`: los movimientos de caja y banco que genera un gasto llevan su descripción como motivo (H11).

Sin delta (implementación que ya viola el spec vigente, se corrige contra el spec existente): `payment-method` (H8 — el requirement "La superficie de compra declara el efecto de la cuenta corriente" ya exige lo contrario del texto actual), `operation-delete-compensation` (H12 — "Diálogo de borrado que enumera la compensación" ya lo exige para toda operación), `sales-order` y `product-profitability` (G8 — el spec ya declara endpoints/RPC funcionales), `billing-ui` (H20 — el comportamiento observado es el especificado; solo se agrega cobertura).

## Impact

- **Frontend** (mayoría): `components/ui/{popover,sidebar,dialog,sheet,scroll-area}.tsx` (compartidos, alto radio — governance MEDIUM), `components/ui/searchable-select.tsx`, `components/shared/product-picker.tsx`, `components/export/ExportButton.tsx`, `components/dashboard/{NotificationBell,breadcrumb-nav}.tsx`, `components/cash/*` + `app/(dashboard)/caja/page.tsx`, `components/ledger/LedgerMovementsPanel.tsx`, `components/bank-accounts/BankAccountFormDialog.tsx`, `components/ledger/LedgerAdjustmentDialog.tsx`, `components/settings/ProfileForm.tsx`, `components/payment-methods/PaymentMethodSelect.tsx`, `components/compras/purchase-operations-list.tsx`, `components/ventas/sale-operations-list.tsx`, `components/products/product-catalog.tsx`, `components/branches/BranchList.tsx`, páginas de `/reportes/{comparativo,sucursal,formas-pago,centros-costo}`, `/gastos`, `/stock`, `/compras`, `/planes`, `app/api/billing/preferences/route.ts`, `app/globals.css`, `app/(dashboard)/layout.tsx`.
- **Backend Python**: `backend/schemas/sales_orders.py` + repositorio de sales orders (G8), `backend/services/suppliers.py` (G9, si OQ-1 resuelve bloquear).
- **DB**: una migración (`20261016000001`) con tres reescrituras de función bajo la regla de integridad (baseline vivo por `pg_get_functiondef`): `rpc_branch_report` (G4), `rpc_product_profitability` (G8), `rpc_create_expense` (G16). Sin tablas nuevas, sin cambios de RLS/ACL.
- **Sin cambios** en Edge Functions, auth, webhook de pagos, outbox ni contabilidad.
- **Evidencia**: informe copiado a `qa/INFORME.md`; las ~120 capturas NO se versionan (precedente del proyecto) y viven en el scratchpad de la sesión de QA (`…/scratchpad/qa/*.png`).
