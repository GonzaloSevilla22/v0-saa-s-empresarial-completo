"use client"

/**
 * sidebar-menu-grupos: arnés del menú lateral REAL.
 *
 * A diferencia de dev-harness/shell (que es una réplica estructural de
 * AppSidebar), acá se monta el `AppSidebar` de verdad dentro de un
 * `SidebarProvider` — la misma estructura que app/(dashboard)/layout.tsx
 * (SidebarProvider → AppSidebar → SidebarInset → header con SidebarTrigger).
 *
 * No hace falta ninguna sesión: el `AuthProvider` del layout raíz resuelve
 * "sin sesión" (usuario nulo, plan gratis, sin módulo de sucursales), que es
 * exactamente lo que se necesita para ver las seis categorías plegadas. Por eso
 * NO se toca el contexto de auth: `Sucursales`/`Por Sucursal` (módulo de
 * sucursales) y la sección Administración se cubren en jsdom
 * (__tests__/components/AppSidebarGroups.test.tsx), no acá.
 *
 * Los links reales navegan a rutas del dashboard, que sin sesión rebotan: los
 * specs aserten el cierre del grupo al tocar un módulo, no el destino.
 */

import { AppSidebar } from "@/components/app-sidebar"
import { SidebarInset, SidebarProvider, SidebarTrigger } from "@/components/ui/sidebar"
import { Separator } from "@/components/ui/separator"

export function SidebarHarness() {
  return (
    <SidebarProvider defaultOpen>
      <AppSidebar />
      <SidebarInset data-testid="inset">
        <header className="flex h-14 shrink-0 items-center gap-2 border-b border-border bg-background px-4">
          <SidebarTrigger
            data-testid="trigger-menu"
            className="-ml-1 text-muted-foreground hover:text-foreground"
          />
          <Separator orientation="vertical" className="mr-2 h-4" />
          <span className="font-medium text-foreground">Arnés — menú lateral por grupos</span>
        </header>
        <div className="min-w-0 flex-1 overflow-auto p-4 md:p-6">
          <h1 className="text-2xl font-bold text-foreground">Contenido de la pantalla</h1>
          <p className="mt-2 max-w-prose text-sm text-muted-foreground">
            El menú lateral de la izquierda es el componente real de la app. Las categorías arrancan
            cerradas; tocá una para desplegar sus módulos.
          </p>
        </div>
      </SidebarInset>
    </SidebarProvider>
  )
}
