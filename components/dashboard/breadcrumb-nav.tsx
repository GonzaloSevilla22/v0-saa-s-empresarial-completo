"use client"

import { usePathname } from "next/navigation"
import { Separator } from "@/components/ui/separator"
import { SidebarTrigger } from "@/components/ui/sidebar"
import {
  Breadcrumb,
  BreadcrumbItem,
  BreadcrumbList,
  BreadcrumbPage,
} from "@/components/ui/breadcrumb"

const PAGE_NAMES: Record<string, string> = {
  "/dashboard":        "Tablero",
  "/ventas":           "Ventas",
  "/compras":          "Compras",
  "/gastos":           "Gastos",
  "/productos":        "Productos",
  "/stock":            "Stock",
  "/clientes":         "Clientes",
  "/insights":         "Consejos AI",
  "/simulador":        "Simulador de Precios",
  "/comunidad":        "Comunidad",
  "/cursos":           "Cursos",
  "/configuracion":    "Configuración",
  "/copiloto-ia":      "Copiloto IA",
  "/ferias":           "Ferias",
  "/seguros":          "Seguros",
  "/admin/cursos":     "Gestión de Cursos",
  "/admin/metricas":   "Métricas Globales",
  "/admin/analytics":  "Panel Técnico",
  "/admin/landing":    "Gestionar Landing",
}

export function BreadcrumbNav() {
  const pathname = usePathname()
  const name = PAGE_NAMES[pathname] ?? "ALIADATA"

  return (
    <header className="flex h-14 shrink-0 items-center gap-2 border-b border-border bg-background px-4">
      <SidebarTrigger className="-ml-1 text-muted-foreground hover:text-foreground" />
      <Separator orientation="vertical" className="mr-2 h-4" />
      <Breadcrumb>
        <BreadcrumbList>
          <BreadcrumbItem>
            <BreadcrumbPage className="text-foreground font-medium">
              {name}
            </BreadcrumbPage>
          </BreadcrumbItem>
        </BreadcrumbList>
      </Breadcrumb>
    </header>
  )
}
