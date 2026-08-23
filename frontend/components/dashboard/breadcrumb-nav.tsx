"use client"

import { useState } from "react"
import { usePathname } from "next/navigation"
import { PlayCircle } from "lucide-react"
import { Separator } from "@/components/ui/separator"
import { SidebarTrigger } from "@/components/ui/sidebar"
import { Button } from "@/components/ui/button"
import {
  Breadcrumb,
  BreadcrumbItem,
  BreadcrumbList,
  BreadcrumbPage,
} from "@/components/ui/breadcrumb"
import { NotificationBell } from "@/components/dashboard/NotificationBell"
import { ResponsiveModal } from "@/components/shared/responsive-modal"
import { TutorialVideo } from "@/components/shared/TutorialVideo"
import { getTutorialByPathname, hasTutorialVideo } from "@/lib/tutorials"

const PAGE_NAMES: Record<string, string> = {
  "/dashboard":        "Tablero",
  "/ventas":           "Ventas",
  "/compras":          "Compras",
  "/gastos":           "Gastos",
  "/productos":        "Productos",
  "/stock":            "Stock",
  "/clientes":         "Clientes",
  "/proveedores":      "Proveedores",
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
  const [tutorialOpen, setTutorialOpen] = useState(false)

  const tutorialEntry = getTutorialByPathname(pathname)
  const tutorial = tutorialEntry && hasTutorialVideo(tutorialEntry) ? tutorialEntry : undefined

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
      <div className="ml-auto flex items-center gap-2">
        {tutorial && (
          <Button variant="outline" size="sm" onClick={() => setTutorialOpen(true)}>
            <PlayCircle className="h-4 w-4" />
            <span className="hidden sm:inline">Ver tutorial</span>
          </Button>
        )}
        <NotificationBell />
      </div>
      {tutorial && (
        <ResponsiveModal
          open={tutorialOpen}
          onOpenChange={setTutorialOpen}
          title={tutorial.title}
          contentClassName="sm:max-w-3xl"
        >
          <TutorialVideo youtubeVideoId={tutorial.youtubeVideoId} title={tutorial.title} />
        </ResponsiveModal>
      )}
    </header>
  )
}
