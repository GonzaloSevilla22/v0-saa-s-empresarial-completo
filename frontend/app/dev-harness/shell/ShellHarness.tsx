"use client"

/**
 * qa-integral-modulos G2 (H2) + G13 (H18/H19): arnés del shell del dashboard.
 *
 * Replica la estructura EXACTA de app/(dashboard)/layout.tsx (SidebarProvider →
 * AppSidebar → SidebarInset → header con SidebarTrigger → div de contenido) con
 * los componentes reales de ui/sidebar.tsx, pero sin auth ni datos: el
 * contenido es un bloque deliberadamente más ancho que el viewport móvil
 * (columnas en px fijos, sin flex-wrap), el patrón que el informe midió en 12
 * pantallas. Si la cadena min-width del shell está sana, ese desborde queda
 * contenido en su propio contenedor con overflow y el documento NO se estira.
 *
 * Nota: el div de contenido lleva las MISMAS clases que layout.tsx:28 — si esa
 * línea cambia, actualizá este arnés en el mismo PR.
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
  SidebarTrigger,
} from "@/components/ui/sidebar"
import { Separator } from "@/components/ui/separator"
import { Button } from "@/components/ui/button"

const ITEMS = ["Tablero", "Ventas", "Compras", "Gastos", "Productos", "Stock"]

export function ShellHarness() {
  const [rows] = useState(() => Array.from({ length: 8 }, (_, i) => i + 1))

  return (
    <SidebarProvider defaultOpen>
      <Sidebar collapsible="icon" className="border-r border-sidebar-border" data-testid="sidebar-root">
        <SidebarContent>
          <SidebarGroup>
            <SidebarGroupLabel>Principal</SidebarGroupLabel>
            <SidebarGroupContent>
              <SidebarMenu>
                {ITEMS.map((title) => (
                  <SidebarMenuItem key={title}>
                    <SidebarMenuButton>{title}</SidebarMenuButton>
                  </SidebarMenuItem>
                ))}
              </SidebarMenu>
            </SidebarGroupContent>
          </SidebarGroup>
        </SidebarContent>
      </Sidebar>
      <SidebarInset data-testid="inset">
        {/* Header espejo de breadcrumb-nav.tsx (mismo trigger, mismas clases) */}
        <header className="flex h-14 shrink-0 items-center gap-2 border-b border-border bg-background px-4">
          <SidebarTrigger
            data-testid="trigger-menu"
            className="-ml-1 text-muted-foreground hover:text-foreground"
          />
          <Separator orientation="vertical" className="mr-2 h-4" />
          <span className="text-foreground font-medium">Arnés G2</span>
        </header>
        {/* Mismo contenedor que app/(dashboard)/layout.tsx:28 */}
        <div className="flex-1 min-w-0 overflow-auto p-4 md:p-6">
          <div className="flex flex-col gap-4">
            <div className="flex items-center justify-between gap-4">
              <h1 className="text-2xl font-bold text-foreground">Pantalla ancha</h1>
              <Button size="sm" data-testid="cta-primario">
                Acción primaria
              </Button>
            </div>
            {/* Tabla con columnas en px fijos, el contribuyente típico de H2.
                Las pantallas sanas la envuelven en su propio overflow-x-auto. */}
            <div className="rounded-md border border-border overflow-x-auto" data-testid="tabla-ancha">
              {rows.map((r) => (
                <div key={r} className="flex items-center gap-3 border-b border-border/50 px-2 py-2 last:border-0">
                  <span className="w-[160px] shrink-0 text-sm text-foreground">Fila {r}</span>
                  <span className="w-[220px] shrink-0 text-sm text-muted-foreground">
                    Descripción larga de la fila {r}
                  </span>
                  <span className="w-[140px] shrink-0 text-right text-sm tabular-nums">$ {r * 1000},00</span>
                  <span className="w-[140px] shrink-0 text-right text-sm tabular-nums">$ {r * 900},00</span>
                </div>
              ))}
            </div>
          </div>
        </div>
      </SidebarInset>
    </SidebarProvider>
  )
}
