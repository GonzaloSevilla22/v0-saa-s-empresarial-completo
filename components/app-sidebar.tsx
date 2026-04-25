"use client"

import Link from "next/link"
import { useEffect } from "react"
import { usePathname } from "next/navigation"
import { useAuth } from "@/contexts/auth-context"
import {
  LayoutDashboard, ShoppingCart, ShoppingBag, Receipt,
  Package, Warehouse, Users, Sparkles, Calculator,
  MessageSquare, GraduationCap, Settings, LogOut, Zap, Crown,
  ShieldCheck, BarChart3, LayoutGrid, Bot
} from "lucide-react"
import {
  Sidebar, SidebarContent, SidebarFooter, SidebarGroup,
  SidebarGroupContent, SidebarGroupLabel, SidebarHeader,
  SidebarMenu, SidebarMenuBadge, SidebarMenuButton, SidebarMenuItem,
  SidebarSeparator, useSidebar,
} from "@/components/ui/sidebar"
import { Badge } from "@/components/ui/badge"
import { Avatar, AvatarFallback } from "@/components/ui/avatar"
import { ModeToggle } from "@/components/mode-toggle"

const navGroups = [
  {
    label: "Principal",
    items: [
      { title: "Tablero", href: "/dashboard", icon: LayoutDashboard, pro: false },
    ],
  },
  {
    label: "Operaciones",
    items: [
      { title: "Ventas", href: "/ventas", icon: ShoppingCart, pro: false },
      { title: "Compras", href: "/compras", icon: ShoppingBag, pro: false },
      { title: "Gastos", href: "/gastos", icon: Receipt, pro: false },
    ],
  },
  {
    label: "Catálogo",
    items: [
      { title: "Productos", href: "/productos", icon: Package, pro: false },
      { title: "Stock", href: "/stock", icon: Warehouse, pro: false },
      { title: "Clientes", href: "/clientes", icon: Users, pro: false },
    ],
  },
  {
    label: "Inteligencia",
    items: [
      { title: "Copiloto IA", href: "/copiloto-ia", icon: Zap, pro: true },
      { title: "Consejos AI", href: "/insights", icon: Sparkles, pro: false },
      { title: "Feria AI", href: "/ferias/ia", icon: LayoutGrid, pro: false },
      { title: "Simulador", href: "/simulador", icon: Calculator, pro: false },
    ],
  },
  {
    label: "Ecosistema",
    items: [
      { title: "Comunidad", href: "/comunidad", icon: MessageSquare, pro: false },
      { title: "Cursos", href: "/cursos", icon: GraduationCap, pro: false },
      { title: "Seguros", href: "/seguros", icon: ShieldCheck, pro: false },
    ],
  },
]

export function AppSidebar() {
  const pathname = usePathname()
  const { user, logout, isAdmin } = useAuth()
  const { isMobile, setOpenMobile } = useSidebar()

  // Close the mobile drawer whenever the user navigates to a new route
  useEffect(() => {
    if (isMobile) {
      setOpenMobile(false)
    }
  }, [pathname, isMobile, setOpenMobile])

  return (
    <Sidebar collapsible="icon" className="border-r border-sidebar-border">
      <SidebarHeader className="p-4">
        <Link href="/dashboard" className="flex items-center gap-2">
          <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg overflow-hidden">
            <img src="/aliadata-logo.png" alt="Logo" className="h-full w-full object-contain" />
          </div>
          <div className="flex flex-col group-data-[collapsible=icon]:hidden">
            <span className="text-sm font-bold text-sidebar-foreground">ALIADATA</span>
            <span className="text-[10px] text-sidebar-foreground/60">Emprender es Inteligente</span>
          </div>
        </Link>
      </SidebarHeader>

      <SidebarSeparator />

      <SidebarContent>
        {navGroups.map((group) => {
          // Hide operative modules for admins as requested
          if (isAdmin && (group.label === "Operaciones" || group.label === "Catálogo")) {
            return null
          }

          return (
            <SidebarGroup key={group.label}>
              <SidebarGroupLabel className="text-sidebar-foreground/50 uppercase text-[10px] tracking-wider">
                {group.label}
              </SidebarGroupLabel>
              <SidebarGroupContent>
                <SidebarMenu>
                  {group.items.map((item) => {
                    const isActive = pathname === item.href
                    return (
                      <SidebarMenuItem key={item.href}>
                        <SidebarMenuButton
                          asChild
                          isActive={isActive}
                          tooltip={item.title}
                        >
                          <Link href={item.href}>
                            <item.icon className="h-4 w-4" />
                            <span>{item.title}</span>
                          </Link>
                        </SidebarMenuButton>
                        {item.pro && user?.plan === "free" && (
                          <SidebarMenuBadge>
                            <Crown className="h-3 w-3 text-yellow-500" />
                          </SidebarMenuBadge>
                        )}
                      </SidebarMenuItem>
                    )
                  })}
                </SidebarMenu>
              </SidebarGroupContent>
            </SidebarGroup>
          )
        })}

        {isAdmin && (
          <SidebarGroup>
            <SidebarGroupLabel className="text-emerald-500 uppercase text-[10px] tracking-wider font-bold">
              Administración
            </SidebarGroupLabel>
            <SidebarGroupContent>
              <SidebarMenu>
                <SidebarMenuItem>
                  <SidebarMenuButton
                    asChild
                    isActive={pathname === "/admin/metricas"}
                    tooltip="Métricas Estratégicas"
                    className="text-emerald-500 hover:text-emerald-400 hover:bg-emerald-500/10"
                  >
                    <Link href="/admin/metricas">
                      <BarChart3 className="h-4 w-4" />
                      <span>Métricas Globales</span>
                    </Link>
                  </SidebarMenuButton>
                </SidebarMenuItem>

                <div className="px-4 py-2 grid grid-cols-2 gap-x-4 gap-y-1 border-l border-emerald-500/20 ml-4 mt-1">
                  <Link href="/admin/metricas/ventas" className="text-[11px] text-slate-400 hover:text-emerald-400 transition-colors">Ventas</Link>
                  <Link href="/admin/metricas/compras" className="text-[11px] text-slate-400 hover:text-emerald-400 transition-colors">Compras</Link>
                  <Link href="/admin/metricas/gastos" className="text-[11px] text-slate-400 hover:text-emerald-400 transition-colors">Gastos</Link>
                  <Link href="/admin/metricas/stock" className="text-[11px] text-slate-400 hover:text-emerald-400 transition-colors">Stock</Link>
                  <Link href="/admin/metricas/clientes" className="text-[11px] text-slate-400 hover:text-emerald-400 transition-colors">Clientes</Link>
                  <Link href="/admin/metricas/ai" className="text-[11px] text-slate-400 hover:text-emerald-400 transition-colors">Consejo IA</Link>
                  <Link href="/admin/metricas/simulador" className="text-[11px] text-slate-400 hover:text-emerald-400 transition-colors">Simulador</Link>
                  <Link href="/admin/metricas/comunidad" className="text-[11px] text-slate-400 hover:text-emerald-400 transition-colors">Comunidad</Link>
                  <Link href="/admin/metricas/cursos" className="text-[11px] text-slate-400 hover:text-emerald-400 transition-colors">Cursos</Link>
                </div>

                <SidebarMenuItem>
                  <SidebarMenuButton
                    asChild
                    isActive={pathname === "/admin/landing"}
                    tooltip="Gestionar Landing Page"
                  >
                    <Link href="/admin/landing">
                      <LayoutGrid className="h-4 w-4" />
                      <span>Gestionar Landing</span>
                    </Link>
                  </SidebarMenuButton>
                </SidebarMenuItem>

                <SidebarMenuItem>
                  <SidebarMenuButton
                    asChild
                    isActive={pathname === "/admin/cursos"}
                    tooltip="Gestionar Cursos"
                    className="text-emerald-500 hover:text-emerald-400 hover:bg-emerald-500/10"
                  >
                    <Link href="/admin/cursos">
                      <GraduationCap className="h-4 w-4" />
                      <span>Gestionar Cursos</span>
                    </Link>
                  </SidebarMenuButton>
                </SidebarMenuItem>

                <SidebarMenuItem>
                  <SidebarMenuButton
                    asChild
                    isActive={pathname === "/admin/seguros"}
                    tooltip="Gestionar Seguros"
                    className="text-emerald-500 hover:text-emerald-400 hover:bg-emerald-500/10"
                  >
                    <Link href="/admin/seguros">
                      <ShieldCheck className="h-4 w-4" />
                      <span>Gestionar Seguros</span>
                    </Link>
                  </SidebarMenuButton>
                </SidebarMenuItem>

                <SidebarMenuItem>
                  <SidebarMenuButton
                    asChild
                    isActive={pathname === "/admin/feria-ia"}
                    tooltip="Gestionar Feria IA"
                    className="text-emerald-500 hover:text-emerald-400 hover:bg-emerald-500/10"
                  >
                    <Link href="/admin/feria-ia">
                      <Sparkles className="h-4 w-4" />
                      <span>Gestionar Feria IA</span>
                    </Link>
                  </SidebarMenuButton>
                </SidebarMenuItem>

                <SidebarMenuItem>
                  <SidebarMenuButton
                    asChild
                    isActive={pathname === "/admin/copilot-ia"}
                    tooltip="Gestionar Copilot IA"
                    className="text-emerald-500 hover:text-emerald-400 hover:bg-emerald-500/10"
                  >
                    <Link href="/admin/copilot-ia">
                      <Bot className="h-4 w-4" />
                      <span>Gestionar Copilot IA</span>
                    </Link>
                  </SidebarMenuButton>
                </SidebarMenuItem>

                <SidebarMenuItem>
                  <SidebarMenuButton
                    asChild
                    isActive={pathname === "/admin/analytics"}
                    tooltip="Analiticas Técnicas"
                  >
                    <Link href="/admin/analytics">
                      <ShieldCheck className="h-4 w-4" />
                      <span>Panel Técnico</span>
                    </Link>
                  </SidebarMenuButton>
                </SidebarMenuItem>
              </SidebarMenu>
            </SidebarGroupContent>
          </SidebarGroup>
        )}
      </SidebarContent>

      <SidebarSeparator />

      <SidebarFooter className="p-2">
        <SidebarMenu>
          <SidebarMenuItem>
            <SidebarMenuButton asChild tooltip="Configuración">
              <Link href="/configuracion">
                <Settings className="h-4 w-4" />
                <span>Configuración</span>
              </Link>
            </SidebarMenuButton>
          </SidebarMenuItem>
          <SidebarMenuItem>
            <SidebarMenuButton
              onClick={() => {
                logout()
                window.location.href = "/"
              }}
              tooltip="Cerrar sesion"
            >
              <LogOut className="h-4 w-4" />
              <span>Cerrar sesión</span>
            </SidebarMenuButton>
          </SidebarMenuItem>
          <SidebarMenuItem>
            <div className="px-2 py-1 flex items-center justify-between group-data-[collapsible=icon]:justify-center">
              <span className="text-xs text-sidebar-foreground/60 group-data-[collapsible=icon]:hidden">Interfaz</span>
              <ModeToggle />
            </div>
          </SidebarMenuItem>
        </SidebarMenu>
        <SidebarSeparator />
        <div className="flex items-center gap-3 p-2 group-data-[collapsible=icon]:justify-center">
          <Avatar className="h-8 w-8 shrink-0">
            <AvatarFallback className="bg-primary/20 text-primary text-xs">
              {user?.name?.charAt(0)?.toUpperCase() || "E"}
            </AvatarFallback>
          </Avatar>
          <div className="flex flex-col group-data-[collapsible=icon]:hidden">
            <span className="text-xs font-medium text-sidebar-foreground truncate max-w-[120px]">
              {user?.name || "Usuario"}
            </span>
            <Badge
              variant="outline"
              className={`w-fit text-[10px] px-1.5 py-0 ${user?.role === "admin"
                ? "border-emerald-500/50 text-emerald-500"
                : "border-sidebar-border text-sidebar-foreground/60"
                }`}
            >
              {user?.role === "admin" ? "Administrador" : "Usuario"}
            </Badge>
          </div>
        </div>
      </SidebarFooter>
    </Sidebar>
  )
}
