"use client"

/**
 * tablet-filtros-cta: arnés del contrato "el CTA de filtros entra en el
 * viewport inicial en tablet" (openspec/specs/responsive-shell/spec.md).
 *
 * A 1024px con el riel del sidebar expandido, las barras de FILTROS de
 * /ventas, /gastos, /compras y /clientes no wrappeaban (a diferencia de la
 * barra de ACCIONES, que qa-integral-modulos G2/2.4 ya había arreglado) y
 * empujaban el CTA primario fuera del viewport inicial.
 *
 * Igual que ShellHarness (G2): NO importa las páginas reales (login + datos
 * sembrados + hooks de cuenta) — reproduce, en aislamiento, el MISMO
 * contenedor y las MISMAS clases de las 4 páginas reales, con placeholders del
 * mismo ancho que los selectores/botones reales (search / date-popover-button
 * / selects de catálogo), para que el contrato de wrap sea observable en un
 * navegador real sin sesión ni seeds. Si el markup de la barra de controles
 * de alguna de las 4 páginas cambia, actualizá este arnés en el mismo PR.
 */

import { useState } from "react"
import {
  Sidebar,
  SidebarContent,
  SidebarGroup,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarInset,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarProvider,
} from "@/components/ui/sidebar"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"

const NAV_ITEMS = ["Tablero", "Ventas", "Compras", "Gastos", "Clientes"]

type RouteName = "ventas" | "gastos" | "compras" | "clientes"

const CTA_LABEL: Record<RouteName, string> = {
  ventas: "Nueva venta",
  gastos: "Nuevo gasto",
  compras: "Nueva compra",
  clientes: "Nuevo cliente",
}

// Cuántos placeholders de filtro tiene cada barra en el código real:
//  - ventas: buscador + botón "Filtrar fechas" + 1 select (forma de pago)
//  - compras/gastos: buscador + "Filtrar fechas" + 2 selects (centro de costo + forma de pago)
//  - clientes: buscador + 2 selects nativos (estado + orden)
const FILTER_COUNT: Record<RouteName, number> = {
  ventas: 1,
  gastos: 2,
  compras: 2,
  clientes: 2,
}

function ControlsBar({ route }: { route: RouteName }) {
  const [search, setSearch] = useState("")
  const extraSelects = FILTER_COUNT[route]

  return (
    // Mismo contenedor post-fix que sale/purchase-operations-list.tsx,
    // gastos/page.tsx y clientes/page.tsx: lg:flex-wrap en el contenedor +
    // flex-wrap en el grupo de filtros — paridad verificada por
    // __tests__/lib/tablet-filters-wrap-gate.test.ts vía los mismos
    // data-testid="filters-bar"/"filters-group" que las 4 páginas reales.
    <div className="flex flex-col gap-3 lg:flex-row lg:flex-wrap lg:items-center lg:justify-between" data-testid="filters-bar">
      <div className="flex flex-col gap-2 sm:flex-row sm:flex-wrap sm:items-center sm:gap-3" data-testid="filters-group">
        <div className="w-full sm:w-64">
          <Input
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Buscar..."
            className="bg-background border-border text-foreground"
            data-testid="filtro-buscar"
          />
        </div>
        <Button variant="outline" size="sm" className="shrink-0 border-border text-foreground">
          Filtrar fechas
        </Button>
        {Array.from({ length: extraSelects }).map((_, i) => (
          <div key={i} className="w-full sm:w-56">
            {/* Placeholder del ancho real de CostCenterSelect/PaymentMethodSelect
                (sm:w-56) — no se importan los componentes reales para no
                depender de datos de cuenta en este arnés sin sesión. */}
            <select
              aria-label={`filtro-${i}`}
              className="h-9 w-full rounded-md border border-border bg-background px-3 text-sm text-foreground"
              defaultValue=""
            >
              <option value="">Todas las opciones</option>
            </select>
          </div>
        ))}
      </div>

      <div className="flex items-center gap-2 flex-wrap">
        <span className="text-sm text-muted-foreground tabular-nums mr-auto lg:mr-0">0 operaciones</span>
        <Button variant="outline" size="sm" className="border-border text-foreground">
          Exportar
        </Button>
        <Button size="sm" className="gap-2" data-testid="cta-primario">
          {CTA_LABEL[route]}
        </Button>
      </div>
    </div>
  )
}

export function TabletFiltersHarness({ route }: { route: RouteName }) {
  return (
    <SidebarProvider defaultOpen>
      <Sidebar collapsible="icon" className="border-r border-sidebar-border" data-testid="sidebar-root">
        <SidebarContent>
          <SidebarGroup>
            <SidebarGroupLabel>Principal</SidebarGroupLabel>
            <SidebarGroupContent>
              <SidebarMenu>
                {NAV_ITEMS.map((title) => (
                  <SidebarMenuItem key={title}>
                    <SidebarMenuButton tooltip={title}>{title}</SidebarMenuButton>
                  </SidebarMenuItem>
                ))}
              </SidebarMenu>
            </SidebarGroupContent>
          </SidebarGroup>
        </SidebarContent>
      </Sidebar>
      <SidebarInset data-testid="inset">
        <div className="flex-1 min-w-0 overflow-auto p-4 md:p-6">
          <div className="flex flex-col gap-4">
            <h1 className="text-2xl font-bold text-foreground">Arnés tablet-filtros-cta ({route})</h1>
            <ControlsBar route={route} />
          </div>
        </div>
      </SidebarInset>
    </SidebarProvider>
  )
}
