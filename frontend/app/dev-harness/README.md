# dev-harness — páginas de arnés para los tests de navegador (qa-integral-modulos)

Páginas **solo de desarrollo** (`notFound()` en producción) que montan los
componentes compartidos del design system (`ui/popover.tsx`, `ui/dialog.tsx`,
`ui/sheet.tsx`, `ui/sidebar.tsx`) en aislamiento, para que los specs de
Playwright del proyecto `harness` (`e2e/harness/*.spec.ts`) puedan fijar su
comportamiento en un navegador real sin sesión ni datos sembrados.

Motivo: los contratos de G1 (scroll de popover dentro de modal) y G2
(`min-w-0` del shell) **no son observables en jsdom** — jsdom no implementa
layout ni scroll ante `wheel`/`touchmove` (RED de `tasks.md` 1.1/2.1).

- `/dev-harness/popover` — G1: selector dentro de Dialog / Sheet / fuera de modal.
- `/dev-harness/shell` — G2 + G13: SidebarProvider + SidebarInset con contenido
  ancho, trigger del menú y drawer móvil.
- `/dev-harness/bell` — G5: campana de notificaciones (`NotificationBellView`)
  con 15 notificaciones sintéticas + control sano de 3.
- `/dev-harness/tablet-filters?route=ventas|gastos|compras|clientes` —
  tablet-filtros-cta: barra de controles (filtros + acciones) de `/ventas`,
  `/gastos`, `/compras` y `/clientes`, con el mismo contenedor y las mismas
  clases de wrap que las páginas reales.
- `/dev-harness/expense-import` — importador-gastos-transaccional (task 9.6):
  `ExpenseImportDialog` real (sin mocks de componente), con un intercept de
  `window.fetch` hacia `/payment-methods`, `/cost-centers`, `/bank-accounts` y
  `/expenses/import` (catálogos sintéticos + heurística mínima para ejercitar
  ok/aviso/error del paso 2), para la pasada visual de los tres pasos sin
  sesión ni backend real.
- `/dev-harness/venta-editable?theme=light|dark&view=list|form` —
  venta-editable-sin-cae: el listado REAL (`SaleOperationsList`) con las cinco
  clases de venta que el change distingue (sin comprobante / pendiente
  anulable / enviado a ARCA / autorizado / anulado) y, con `view=form`, el
  formulario de edición con el comprobante pendiente anulable —para capturar el
  banner de aviso y el `AlertDialog` de "Guardar y anular"—. Las pantallas
  reales (`/ventas`) exigen sesión y backend; acá no hace falta ninguno de los
  dos: el estado fiscal viaja por props y `window.fetch` hacia el backend se
  intercepta devolviendo vacío. Gotcha aprendido en su spec: el listado
  renderiza la MISMA fila dos veces (bloque `sm:hidden` de móvil + bloque
  `hidden sm:grid` de desktop), así que todo texto/control de la fila resuelve
  a DOS elementos y `.first()` toma el de móvil —invisible en desktop—; hay que
  filtrar por visibilidad (`filter({ visible: true })`), no por posición.
- `/dev-harness/emitir-suscripcion?theme=light|dark` — fiscal-emision-segura
  (G5/H3): `EmitirSuscripcionDialog` real con props sintéticas, para la pasada
  visual de las 4 combinaciones (1366 / 375 × claro / oscuro) y para fijar que
  el CTA primario entra en el viewport de un teléfono. El diálogo vive en
  `/admin/pagos`, que exige sesión de admin y backend; acá no hace falta
  ninguno de los dos. Gotcha aprendido en su spec: con el diálogo abierto,
  Radix marca `aria-hidden` el resto de la página, así que el `<h1>` del arnés
  NO existe para el árbol de accesibilidad — esperar el diálogo, no el heading.
- `/dev-harness/facturar-venta?theme=light|dark&error=out_of_sync|inconsistent` —
  venta-editable-vs-promocion-legacy: el listado REAL con una venta cargada a
  mano sin comprobante y `window.fetch` interceptado hacia el backend, para la
  pasada visual de los dos rechazos de "Facturar" que el e2e real
  (`e2e/facturar-venta-manual.spec.ts`, stack local + relay con el stub) no
  puede provocar a demanda: la emisión rechazada por `sales_order_out_of_sync`
  (la fila tiene que volver a "Facturar") y la preparación rechazada por
  `operation_inconsistent`. Los toasts los pinta el `<Toaster>` del layout raíz.
- `/dev-harness/unidades?theme=light|dark&view=stock|form` —
  ventas-unidades-conversion (task 6.4): las columnas REALES de `/stock`
  (`buildColumns` + `DataTable` + el mismo `mobileCard`) y filas REALES del
  historial (`MovementRow`) sobre productos en kilos, litros y por unidades
  ("0.550 kg", "12 uds", "-0.450 kg"); y el formulario de venta REAL con un
  catálogo sintético servido por intercept de `window.fetch` (`/products` del
  backend y `/rest/v1/units_of_measure` de Supabase), para capturar el selector
  de unidad compatible (un producto en kg ofrece kg/g/tn, uno sin unidad base
  sólo unidades base).
