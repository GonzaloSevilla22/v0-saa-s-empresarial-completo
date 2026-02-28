"use client"

import Link from "next/link"
import { usePathname } from "next/navigation"
import { useAuth } from "@/contexts/auth-context"
import {
  LayoutDashboard, ShoppingCart, ShoppingBag, Receipt,
  Package, Warehouse, Users, Sparkles, Calculator,
  MessageSquare, GraduationCap, Settings, LogOut, Zap, Crown,
} from "lucide-react"
import {
  Sidebar, SidebarContent, SidebarFooter, SidebarGroup,
  SidebarGroupContent, SidebarGroupLabel, SidebarHeader,
  SidebarMenu, SidebarMenuBadge, SidebarMenuButton, SidebarMenuItem,
  SidebarSeparator,
} from "@/components/ui/sidebar"
import { Badge } from "@/components/ui/badge"
import { Avatar, AvatarFallback } from "@/components/ui/avatar"
import { ModeToggle } from "@/components/mode-toggle"

const navGroups = [
  {
    label: "Principal",
    items: [
      { title: "Dashboard", href: "/dashboard", icon: LayoutDashboard, pro: false },
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
      { title: "Insights AI", href: "/insights", icon: Sparkles, pro: false },
      { title: "Simulador", href: "/simulador", icon: Calculator, pro: false },
    ],
  },
  {
    label: "Ecosistema",
    items: [
      { title: "Comunidad", href: "/comunidad", icon: MessageSquare, pro: false },
      { title: "Cursos", href: "/cursos", icon: GraduationCap, pro: false },
    ],
  },
]

export function AppSidebar() {
  const pathname = usePathname()
  const { user, logout } = useAuth()

  return (
    <Sidebar collapsible="icon" className="border-r border-sidebar-border">
      <SidebarHeader className="p-4">
        <Link href="/dashboard" className="flex items-center gap-2">
          <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-primary">
            <Zap className="h-4 w-4 text-primary-foreground" />
          </div>
          <div className="flex flex-col group-data-[collapsible=icon]:hidden">
            <span className="text-sm font-bold text-sidebar-foreground">EIE</span>
            <span className="text-[10px] text-sidebar-foreground/60">Emprender es Inteligente</span>
          </div>
        </Link>
      </SidebarHeader>

      <SidebarSeparator />

      <SidebarContent>
        {navGroups.map((group) => (
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
        ))}
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
                window.location.href = "/login"
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
              className={`w-fit text-[10px] px-1.5 py-0 ${user?.plan === "pro"
                ? "border-yellow-500/50 text-yellow-500"
                : "border-sidebar-border text-sidebar-foreground/60"
                }`}
            >
              {user?.plan === "pro" ? "PRO" : "FREE"}
            </Badge>
          </div>
        </div>
      </SidebarFooter>
    </Sidebar>
  )
}
