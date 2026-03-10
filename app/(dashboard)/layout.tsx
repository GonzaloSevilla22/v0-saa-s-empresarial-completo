"use client"

import { DataProvider } from "@/contexts/data-context"
import { SidebarProvider, SidebarInset, SidebarTrigger } from "@/components/ui/sidebar"
import { AppSidebar } from "@/components/app-sidebar"
import { Separator } from "@/components/ui/separator"
import {
  Breadcrumb, BreadcrumbItem, BreadcrumbList, BreadcrumbPage,
} from "@/components/ui/breadcrumb"
import { usePathname } from "next/navigation"

const pageNames: Record<string, string> = {
  "/dashboard": "Tablero",
  "/ventas": "Ventas",
  "/compras": "Compras",
  "/gastos": "Gastos",
  "/productos": "Productos",
  "/stock": "Stock",
  "/clientes": "Clientes",
  "/insights": "Consejos AI",
  "/simulador": "Simulador de Precios",
  "/comunidad": "Comunidad",
  "/cursos": "Cursos",
  "/configuracion": "Configuración",
  "/admin/cursos": "Gestión de Cursos",
  "/admin/metricas": "Métricas Globales",
  "/admin/analytics": "Panel Técnico",
  "/admin/landing": "Gestionar Landing",
}

export default function DashboardLayout({ children }: { children: React.ReactNode }) {
  const pathname = usePathname()
  const currentPageName = pageNames[pathname] || "ALIADA"

  return (
    <DataProvider>
      <SidebarProvider>
        <AppSidebar />
        <SidebarInset>
          <header className="flex h-14 shrink-0 items-center gap-2 border-b border-border bg-background px-4">
            <SidebarTrigger className="-ml-1 text-muted-foreground hover:text-foreground" />
            <Separator orientation="vertical" className="mr-2 h-4" />
            <Breadcrumb>
              <BreadcrumbList>
                <BreadcrumbItem>
                  <BreadcrumbPage className="text-foreground font-medium">
                    {currentPageName}
                  </BreadcrumbPage>
                </BreadcrumbItem>
              </BreadcrumbList>
            </Breadcrumb>
          </header>
          <div className="flex-1 overflow-auto p-4 md:p-6">
            {children}
          </div>
        </SidebarInset>
      </SidebarProvider>
    </DataProvider>
  )
}
