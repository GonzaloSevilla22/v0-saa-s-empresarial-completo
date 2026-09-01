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
