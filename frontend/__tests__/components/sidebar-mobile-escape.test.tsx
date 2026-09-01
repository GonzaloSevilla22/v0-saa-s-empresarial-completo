/**
 * qa-integral-modulos G13 — H19 (residuo del re-QA del 2026-09-01).
 *
 * El re-QA midió sobre la app real que, con el drawer móvil abierto
 * (`data-state=open`), Escape NO lo cerraba — reproducido 2 veces, con el
 * foco visible en "Cerrar sesión" DENTRO del sheet. El arnés Playwright de
 * 13.3 pasaba porque monta `SidebarMenuButton` SIN la prop `tooltip`, que es
 * justo la diferencia con `AppSidebar` (todos sus ítems la pasan).
 *
 * Causa raíz: `SidebarMenuButton` montaba el `TooltipContent` siempre y lo
 * ocultaba con `hidden` cuando no correspondía (móvil, o riel expandido).
 * Radix Tooltip abre con `onFocus`, así que al enfocar cualquier ítem del
 * menú el contenido —invisible— montaba igual su `DismissableLayer`, que
 * pasaba a ser la capa más alta. `DismissableLayer` solo atiende Escape en
 * la capa más alta (`index === context.layers.size - 1`), de modo que el
 * Sheet del drawer, una capa por debajo, dejaba de recibirlo.
 *
 * Estos tests corren en jsdom porque el defecto es de composición de capas
 * (JS puro), no de layout: reproducen el fallo exacto sin navegador.
 */
import { describe, it, expect, beforeAll } from 'vitest'
import { render, screen, act, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import * as React from 'react'
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarHeader,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarProvider,
  SidebarTrigger,
} from '@/components/ui/sidebar'

const DRAWER = '[data-sidebar="sidebar"][data-mobile="true"]'

beforeAll(() => {
  // useIsMobile() lee window.innerWidth (< 768 = móvil).
  Object.defineProperty(window, 'innerWidth', { writable: true, value: 390 })
})

/** Réplica mínima de AppSidebar: ítems de menú CON tooltip, como en la app. */
function ShellWithTooltips({ defaultOpen = true }: { defaultOpen?: boolean }) {
  return (
    <SidebarProvider defaultOpen={defaultOpen}>
      <Sidebar collapsible="icon">
        <SidebarHeader>
          <a href="/dashboard">ALIADATA</a>
        </SidebarHeader>
        <SidebarContent>
          <SidebarMenu>
            {['Tablero', 'Ventas'].map((title) => (
              <SidebarMenuItem key={title}>
                <SidebarMenuButton asChild tooltip={title}>
                  <a href={`/${title.toLowerCase()}`}>{title}</a>
                </SidebarMenuButton>
              </SidebarMenuItem>
            ))}
          </SidebarMenu>
        </SidebarContent>
        <SidebarFooter>
          <SidebarMenu>
            <SidebarMenuItem>
              <SidebarMenuButton tooltip="Cerrar sesion">Cerrar sesion</SidebarMenuButton>
            </SidebarMenuItem>
          </SidebarMenu>
        </SidebarFooter>
      </Sidebar>
      <SidebarTrigger data-testid="trigger-menu" />
    </SidebarProvider>
  )
}

async function openDrawer() {
  const user = userEvent.setup()
  render(<ShellWithTooltips />)
  await user.click(screen.getByTestId('trigger-menu'))
  const drawer = document.querySelector(DRAWER)
  expect(drawer).not.toBeNull()
  return { user, drawer: drawer as HTMLElement }
}

async function focusInsideDrawer(drawer: HTMLElement, label: string) {
  const control = within(drawer).getByText(label).closest('button, a') as HTMLElement
  await act(async () => {
    control.focus()
  })
  // Radix Tooltip abre en el mismo tick del focus (delayDuration 0).
  await act(async () => {
    await new Promise((r) => setTimeout(r, 30))
  })
  return control
}

describe('G13/H19 — el drawer móvil cierra con Escape', () => {
  it('cierra con Escape con el foco en un ítem del menú', async () => {
    const { user, drawer } = await openDrawer()
    await focusInsideDrawer(drawer, 'Ventas')

    await user.keyboard('{Escape}')
    await act(async () => {
      await new Promise((r) => setTimeout(r, 60))
    })

    expect(document.querySelector(DRAWER)).toBeNull()
  })

  it('cierra con Escape con el foco en "Cerrar sesión" (el caso que capturó el re-QA)', async () => {
    const { user, drawer } = await openDrawer()
    await focusInsideDrawer(drawer, 'Cerrar sesion')

    await user.keyboard('{Escape}')
    await act(async () => {
      await new Promise((r) => setTimeout(r, 60))
    })

    expect(document.querySelector(DRAWER)).toBeNull()
  })

  it('en móvil el tooltip no monta contenido aunque el ítem tenga foco (la capa fantasma)', async () => {
    const { drawer } = await openDrawer()
    await focusInsideDrawer(drawer, 'Cerrar sesion')

    // El texto del ítem existe una sola vez: el del botón. Si el
    // TooltipContent se montara (aunque fuese con `hidden`), habría dos.
    expect(screen.getAllByText('Cerrar sesion')).toHaveLength(1)
  })

  it('el tooltip SIGUE mostrándose en escritorio con el riel colapsado (no se rompe la función)', async () => {
    Object.defineProperty(window, 'innerWidth', { writable: true, value: 1440 })
    try {
      const user = userEvent.setup()
      // defaultOpen=false ⇒ state="collapsed", que es cuando el riel muestra
      // solo íconos y el tooltip es la única forma de leer el nombre.
      render(<ShellWithTooltips defaultOpen={false} />)
      const item = screen.getByText('Ventas').closest('a') as HTMLElement
      await user.hover(item)
      await act(async () => {
        await new Promise((r) => setTimeout(r, 60))
      })

      expect(screen.getAllByText('Ventas').length).toBeGreaterThan(1)
    } finally {
      Object.defineProperty(window, 'innerWidth', { writable: true, value: 390 })
    }
  })
})
